--[[
Test harness: loads the addon's non-UI files into isolated environments with
stubbed WoW APIs, a shared virtual clock and a simulated guild network.
Each logged-in character gets its own environment (its own `ns`), exactly like
separate game clients. Runs on stock Lua 5.1-5.4.
]]
local H = {}

local ROOT = (arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]")) or "."
H.ADDON_DIR = ROOT .. "/GuildTradebook/"

H.FILES = {
	"Locales/enUS.lua",
	"Core/Init.lua",
	"Core/Util.lua",
	"Data/Store.lua",
	"Data/Roster.lua",
	"Scan/Scanner.lua",
	"Sync/Codec.lua",
	"Sync/Protocol.lua",
	"Search/Index.lua",
	"Search/Upgrades.lua",
	"Core/Boot.lua",
}

local function loadInto(path, env)
	local chunk, err
	if setfenv then -- Lua 5.1
		chunk, err = loadfile(path)
		if chunk then setfenv(chunk, env) end
	else
		chunk, err = loadfile(path, "t", env)
	end
	if not chunk then error(err) end
	return chunk
end

function H.DeepCopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do
		out[H.DeepCopy(k)] = H.DeepCopy(x)
	end
	return out
end

-- Virtual clock and timers -----------------------------------------------------

function H.NewClock(start)
	local clock = { t = start or 1000000, timers = {}, nextId = 0 }

	function clock:Add(delay, fn, owner, interval)
		self.nextId = self.nextId + 1
		local timer = { due = self.t + delay, fn = fn, owner = owner, interval = interval, id = self.nextId }
		function timer:Cancel() self.cancelled = true end
		table.insert(self.timers, timer)
		return timer
	end

	function clock:Advance(seconds)
		local stop = self.t + seconds
		while true do
			local best, bestIndex
			for i, timer in ipairs(self.timers) do
				if not best or timer.due < best.due or (timer.due == best.due and timer.id < best.id) then
					best, bestIndex = timer, i
				end
			end
			if not best or best.due > stop then break end
			table.remove(self.timers, bestIndex)
			self.t = math.max(self.t, best.due)
			if not best.cancelled and not (best.owner and best.owner.dead) then
				if best.interval then
					best.due = self.t + best.interval
					table.insert(self.timers, best)
				end
				best.fn()
			end
		end
		self.t = stop
	end

	return clock
end

-- World ------------------------------------------------------------------------

--[[
A world is one guild. Characters:
  char = { guid, name, class, level, account, profs = { [sl] = {rank, maxRank, name, recipes = {[rid]=itemID}} },
           partition = 1, restricted = false }
Accounts own SavedVariables, so alts on one account share them.
]]
function H.NewWorld(opts)
	opts = opts or {}
	local world = {
		clock = H.NewClock(),
		chars = {},        -- by guid
		order = {},        -- guild roster order
		accounts = {},     -- [account] = saved DB table (or nil)
		online = {},       -- [guid] = client
		messages = 0,
		latency = opts.latency or 0.2,
		guildName = opts.guildName or "Testguild",
		serverProfs = {},  -- [guid] = {id1, id2} as the club API reports
		log = {},
	}

	function world:AddChar(c)
		c.realm = c.realm or "Realm"
		c.name = c.name .. "-" .. c.realm
		c.class = c.class or "MAGE"
		c.level = c.level or 60
		c.account = c.account or c.name
		c.profs = c.profs or {}
		c.partition = c.partition or 1
		c.inGuild = true
		self.chars[c.guid] = c
		table.insert(self.order, c.guid)
		return c
	end

	function world:RemoveFromGuild(guid)
		self.chars[guid].inGuild = false
		for i, g in ipairs(self.order) do
			if g == guid then table.remove(self.order, i) break end
		end
		for _, client in pairs(self.online) do
			client:Fire("GUILD_ROSTER_UPDATE")
		end
	end

	function world:Members()
		local list = {}
		for _, guid in ipairs(self.order) do
			list[#list + 1] = self.chars[guid]
		end
		return list
	end

	world.byType = {}
	world.sentBy = {}
	function world:Deliver(from, msg, channel, target)
		self.messages = self.messages + 1
		self.byType[msg.t] = (self.byType[msg.t] or 0) + 1
		self.sentBy[from.char.name] = (self.sentBy[from.char.name] or 0) + 1
		for guid, client in pairs(self.online) do
			local c = self.chars[guid]
			local ok = guid ~= from.guid and c.partition == from.char.partition and c.inGuild
			if channel == "WHISPER" then
				ok = ok and c.name == target
			end
			if ok then
				local copy = H.DeepCopy(msg)
				self.clock:Add(self.latency, function()
					client.ns.Protocol.Handle(copy, channel, from.char.name)
				end, client.env)
			end
		end
	end

	function world:Login(guid)
		local char = self.chars[guid]
		local client = H.NewClient(self, char)
		self.online[guid] = client
		client:Boot()
		for _, other in pairs(self.online) do
			if other ~= client then other:Fire("GUILD_ROSTER_UPDATE") end
		end
		return client
	end

	function world:Logout(guid)
		local client = self.online[guid]
		if not client then return end
		self.accounts[client.char.account] = client.env.GuildTradebookDB
		client.env.dead = true
		self.online[guid] = nil
	end

	function world:ResetCounters()
		self.messages, self.byType, self.sentBy = 0, {}, {}
	end

	function world:Run(seconds)
		self.clock:Advance(seconds)
	end

	-- Live truth of an owner: the record its own client (or saved DB) holds.
	function world:OwnerRecord(guid)
		local char = self.chars[guid]
		local client = self.online[guid]
		local db = client and client.env.GuildTradebookDB or self.accounts[char.account]
		local gd = db and db.guilds[self.guildName .. "-Realm"]
		return gd and gd.chars[guid]
	end

	return world
end

-- Client (one logged-in game client) --------------------------------------------

function H.NewClient(world, char)
	local client = { world = world, char = char, guid = char.guid, frames = {} }
	local env = setmetatable({}, { __index = _G })
	client.env = env
	local clock = world.clock

	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
		table.insert(world.log, char.name .. ": " .. table.concat(parts, " "))
	end
	env.GetLocale = function() return "enUS" end
	env.GetBuildInfo = function() return "1.60.1", "70245" end
	env.GetTime = function() return clock.t end
	env.GetServerTime = function() return math.floor(clock.t) end
	env.C_Timer = {
		NewTimer = function(sec, fn) return clock:Add(sec, fn, env) end,
		NewTicker = function(sec, fn) return clock:Add(sec, fn, env, sec) end,
		After = function(sec, fn) clock:Add(sec, fn, env) end,
	}
	env.CreateFrame = function()
		local frame = { events = {} }
		function frame:RegisterEvent(e) self.events[e] = true end
		function frame:SetScript(_, fn) self.onEvent = fn end
		table.insert(client.frames, frame)
		return frame
	end
	env.UnitGUID = function(unit) return unit == "player" and char.guid or nil end
	env.UnitName = function() return (char.name:gsub("%-.*$", "")) end
	env.UnitClass = function() return char.class, char.class end
	env.UnitLevel = function() return char.level end
	env.GetNormalizedRealmName = function() return char.realm end
	env.Ambiguate = function(name) return (name:gsub("%-.*$", "")) end
	env.RAID_CLASS_COLORS = {}
	env.SlashCmdList = {}

	-- Guild
	env.IsInGuild = function() return char.inGuild end
	env.GetGuildInfo = function() if char.inGuild then return world.guildName, "Member", 1, nil end end
	env.GetNumGuildMembers = function() return char.inGuild and #world.order or 0 end
	env.GetGuildRosterInfo = function(i)
		local c = world.chars[world.order[i]]
		if not c then return nil end
		return c.name, "Member", 1, c.level, c.class, "", "", "", world.online[c.guid] ~= nil, 0, c.class,
			0, 0, false, false, 0, c.guid
	end
	env.GetGuildRosterLastOnline = function() return 0, 0, 1, 0 end
	env.C_GuildInfo = {
		GuildRoster = function()
			clock:Add(0.5, function() client:Fire("GUILD_ROSTER_UPDATE") end, env)
		end,
	}
	env.C_Club = {
		GetGuildClubId = function() return 1 end,
		GetClubMembers = function()
			local ids = {}
			for i = 1, #world.order do ids[i] = i end
			return ids
		end,
		GetMemberInfo = function(_, memberId)
			local guid = world.order[memberId]
			local sp = world.serverProfs[guid]
			return { guid = guid, profession1ID = sp and sp[1], profession2ID = sp and sp[2] }
		end,
	}
	env.C_ChatInfo = {
		AreOutgoingAddonChatMessagesRestricted = function() return char.restricted end,
	}

	-- Professions
	-- Like the real API: prim1, prim2, then secondary slots (nil where empty).
	-- Professions flagged `secondary` go into the secondary slots.
	env.GetProfessions = function()
		local primary, secondary = {}, {}
		for sl, p in pairs(char.profs) do
			table.insert(p.secondary and secondary or primary, sl)
		end
		table.sort(primary)
		table.sort(secondary)
		return primary[1], primary[2], secondary[1], secondary[2], secondary[3], secondary[4], secondary[5]
	end
	env.GetProfessionInfo = function(sl)
		local p = char.profs[sl]
		-- spellOffset + 1 encodes the skill line, see C_SpellBook below.
		return p.name or ("Prof" .. sl), 0, p.rank, p.maxRank, 0, sl - 1, sl
	end
	env.C_SpellBook = {
		GetSpellBookItemInfo = function(slot) return { spellID = slot } end,
	}
	env.Enum = {}
	env.C_TradeSkillUI = {
		IsTradeSkillReady = function() return client.openSkill ~= nil end,
		CanTradeSkillShowCraftingUI = function(spellID)
			local p = char.profs[spellID]
			return p ~= nil and not p.noCraftingUI
		end,
		IsTradeSkillLinked = function() return false end,
		IsTradeSkillGuild = function() return false end,
		IsNPCCrafting = function() return false end,
		GetBaseProfessionInfo = function() return { professionID = client.openSkill } end,
		GetAllRecipeIDs = function()
			local ids = {}
			local p = char.profs[client.openSkill]
			for rid in pairs(p and p.recipes or {}) do ids[#ids + 1] = rid end
			table.sort(ids)
			return ids
		end,
		GetRecipeInfo = function(rid) return { recipeID = rid, learned = true } end,
		GetRecipeSchematic = function(rid)
			for _, p in pairs(char.profs) do
				if p.recipes and p.recipes[rid] then
					return { outputItemID = p.recipes[rid], reagentSlotSchematics = {
						{ reagents = { { itemID = 2589 } }, quantityRequired = 2, required = true },
					} }
				end
			end
		end,
		GetProfessionInfoByRecipeID = function(rid)
			for sl, p in pairs(char.profs) do
				if p.recipes and p.recipes[rid] then return { professionID = sl, parentProfessionID = 0 } end
			end
		end,
	}

	function client:Fire(event, ...)
		for _, frame in ipairs(self.frames) do
			if frame.events[event] and frame.onEvent then
				frame.onEvent(frame, event, ...)
			end
		end
	end

	function client:Boot()
		local ns = {}
		self.ns = ns
		env.GuildTradebookDB = H.DeepCopy(world.accounts[char.account])
		for _, file in ipairs(H.FILES) do
			loadInto(H.ADDON_DIR .. file, env)("GuildTradebook", ns)
		end
		ns.Tooltip = { Start = function() end }
		ns.UI = { Toggle = function() end, Show = function() end }
		ns.Protocol.transport = function(msg, channel, target)
			world:Deliver(client, msg, channel, target)
		end
		self:Fire("ADDON_LOADED", "GuildTradebook")
		self:Fire("PLAYER_LOGIN")
	end

	-- Simulates opening the profession window.
	function client:OpenTradeSkill(skillLine)
		self.openSkill = skillLine
		self:Fire("TRADE_SKILL_SHOW")
	end

	function client:CloseTradeSkill()
		self.openSkill = nil
	end

	function client:GuildData()
		return self.env.GuildTradebookDB.guilds[world.guildName .. "-Realm"]
	end

	function client:Record(guid)
		local gd = self:GuildData()
		return gd and gd.chars[guid]
	end

	return client
end

function H.Describe(counts)
	local keys = {}
	for k in pairs(counts) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. counts[k] end
	return "(" .. table.concat(parts, " ") .. ")"
end

-- Mini test framework ------------------------------------------------------------

H.results = { passed = 0, failed = 0 }

function H.test(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		H.results.passed = H.results.passed + 1
		print("  ok   " .. name)
	else
		H.results.failed = H.results.failed + 1
		print("  FAIL " .. name .. "\n" .. tostring(err))
	end
end

function H.eq(actual, expected, msg)
	if actual ~= expected then
		error((msg or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

function H.truthy(v, msg)
	if not v then error(msg or "expected truthy value", 2) end
end

function H.falsy(v, msg)
	if v then error((msg or "expected falsy value") .. ": got " .. tostring(v), 2) end
end

-- Loads only the pure modules into a fresh namespace (for unit tests).
function H.LoadPure()
	local ns = {}
	local env = setmetatable({
		CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end,
		GetLocale = function() return "enUS" end,
		GetTime = function() return 0 end,
	}, { __index = _G })
	for _, file in ipairs({ "Locales/enUS.lua", "Core/Init.lua", "Core/Util.lua", "Data/Store.lua", "Search/Upgrades.lua" }) do
		loadInto(H.ADDON_DIR .. file, env)("GuildTradebook", ns)
	end
	return ns
end

return H
