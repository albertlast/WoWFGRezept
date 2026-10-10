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
	"Sync/Versions.lua",
	"Search/Index.lua",
	"Search/Categories.lua",
	"Search/Upgrades.lua",
	"Features/Wishlist.lua",
	"Features/Reagents.lua",
	"Features/ChatResponder.lua",
	"Features/Link.lua",
	"Features/Export.lua",
	"Core/Boot.lua",
}

-- Behave like WoW's Lua: string.format("%d") only accepts 32-bit signed
-- integers there ("integer overflow attempting to store"); stock Lua 5.3+
-- accepts 64-bit and would hide such bugs.
do
	local format = string.format
	string.format = function(spec, ...)
		local args, i = { ... }, 0
		for flagsAndType in spec:gmatch("%%([%-+ #0]*%d*%.?%d*%a)") do
			i = i + 1
			local conv = flagsAndType:sub(-1)
			if (conv == "d" or conv == "i") and type(args[i]) == "number"
				and (args[i] > 2147483647 or args[i] < -2147483648) then
				error("integer overflow attempting to store " .. format("%.0f", args[i]), 2)
			end
		end
		return format(spec, ...)
	end
end

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

-- Timers fire in order of (due, id): earliest first, then in creation
-- order. A binary heap keeps that fast with thousands of pending timers
-- (load simulation).
local function earlier(a, b)
	return a.due < b.due or (a.due == b.due and a.id < b.id)
end

function H.NewClock(start)
	local clock = { t = start or 1000000, timers = {}, nextId = 0 }

	local function push(heap, timer)
		heap[#heap + 1] = timer
		local i = #heap
		while i > 1 do
			local parent = math.floor(i / 2)
			if not earlier(heap[i], heap[parent]) then break end
			heap[i], heap[parent] = heap[parent], heap[i]
			i = parent
		end
	end

	local function pop(heap)
		local top, last = heap[1], table.remove(heap)
		if #heap > 0 then
			heap[1] = last
			local i, n = 1, #heap
			while true do
				local l, r, smallest = 2 * i, 2 * i + 1, i
				if l <= n and earlier(heap[l], heap[smallest]) then smallest = l end
				if r <= n and earlier(heap[r], heap[smallest]) then smallest = r end
				if smallest == i then break end
				heap[i], heap[smallest] = heap[smallest], heap[i]
				i = smallest
			end
		end
		return top
	end

	function clock:Add(delay, fn, owner, interval)
		self.nextId = self.nextId + 1
		local timer = { due = self.t + delay, fn = fn, owner = owner, interval = interval, id = self.nextId }
		function timer:Cancel() self.cancelled = true end
		push(self.timers, timer)
		return timer
	end

	function clock:Advance(seconds)
		local stop = self.t + seconds
		while true do
			local best = self.timers[1]
			if not best or best.due > stop then break end
			pop(self.timers)
			self.t = math.max(self.t, best.due)
			if not best.cancelled and not (best.owner and best.owner.dead) then
				if best.interval then
					best.due = self.t + best.interval
					push(self.timers, best)
				end
				best.fn()
			end
		end
		self.t = stop
	end

	return clock
end

-- Estimated wire size of a message ---------------------------------------------
-- CBOR size of the table (as C_EncodingUtil.SerializeCBOR writes it), plus
-- AceComm/ChatThrottleLib overhead (40 bytes per 255-byte chunk). Deflate
-- then Base64 roughly cancel out for records (measured on real records:
-- 524 bytes CBOR -> 520 bytes on the wire), so the CBOR size stands for the
-- payload.
local function cborHead(n)
	if n < 24 then return 1 elseif n < 256 then return 2 elseif n < 65536 then return 3
	elseif n < 2 ^ 32 then return 5 end
	return 9
end

local function cborSize(v)
	local kind = type(v)
	if kind == "number" then
		if v ~= math.floor(v) then return 9 end
		return cborHead(math.abs(v))
	elseif kind == "string" then
		return cborHead(#v) + #v
	elseif kind == "table" then
		local n, size = #v, 0
		local count = 0
		for _ in pairs(v) do count = count + 1 end
		if count == n then
			for i = 1, n do size = size + cborSize(v[i]) end
			return cborHead(n) + size
		end
		for k, x in pairs(v) do size = size + cborSize(k) + cborSize(x) end
		return cborHead(count) + size
	end
	return 1
end

-- Real encoding for the load simulation (H.realSizes = true): CBOR as the
-- game writes it, raw Deflate (LibDeflate, test-only copy in tests/vendor),
-- Base64. Slower, but it sees what Deflate makes of repeated content.
local function cborHeader(major, n)
	local m = major * 32
	if n < 24 then return string.char(m + n) end
	if n < 256 then return string.char(m + 24, n) end
	if n < 65536 then return string.char(m + 25, math.floor(n / 256), n % 256) end
	if n < 2 ^ 32 then
		return string.char(m + 26, math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
	end
	local hi, lo = math.floor(n / 2 ^ 32), n % 2 ^ 32
	return string.char(m + 27, math.floor(hi / 16777216) % 256, math.floor(hi / 65536) % 256, math.floor(hi / 256) % 256, hi % 256,
		math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256, math.floor(lo / 256) % 256, lo % 256)
end

local function cborEncode(v, out)
	local kind = type(v)
	if kind == "number" then
		if v ~= math.floor(v) then
			out[#out + 1] = string.char(0xfb) .. string.rep("\0", 8)
		elseif v >= 0 then
			out[#out + 1] = cborHeader(0, v)
		else
			out[#out + 1] = cborHeader(1, -1 - v)
		end
	elseif kind == "string" then
		out[#out + 1] = cborHeader(3, #v) .. v
	elseif kind == "boolean" then
		out[#out + 1] = string.char(v and 0xf5 or 0xf4)
	elseif kind == "table" then
		local n, count = #v, 0
		for _ in pairs(v) do count = count + 1 end
		if count == n then
			out[#out + 1] = cborHeader(4, n)
			for i = 1, n do cborEncode(v[i], out) end
		else
			out[#out + 1] = cborHeader(5, count)
			local keys = {}
			for k in pairs(v) do keys[#keys + 1] = k end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do
				cborEncode(k, out)
				cborEncode(v[k], out)
			end
		end
	else
		out[#out + 1] = string.char(0xf6)
	end
end

function H.CBOR(v)
	local out = {}
	cborEncode(v, out)
	return table.concat(out)
end

local deflate
function H.WireSize(msg)
	local payload
	if H.realSizes then
		deflate = deflate or dofile(ROOT .. "/tests/vendor/LibDeflate/LibDeflate.lua")
		local packed = deflate:CompressDeflate(H.CBOR(msg), { level = 9 })
		payload = math.ceil(#packed / 3) * 4
	else
		payload = cborSize(msg)
	end
	return payload + 40 * math.ceil(payload / 255)
end

-- World ------------------------------------------------------------------------

--[[
A world is one guild. Characters:
  char = { guid, name, class, level, account, profs = { [sl] = {rank, maxRank, name, recipes = {[rid]=itemID}} },
           partition = 1, restricted = false, noChatPosting = false }
  restricted     chat messaging lockdown (addon messages wait in the outbox)
  noChatPosting  AreOutgoingAddonChatMessagesRestricted() is true (as on the
                 Forever beta realm, where everything still works)
Accounts own SavedVariables, so alts on one account share them.
]]
function H.NewWorld(opts)
	opts = opts or {}
	local world = {
		clock = H.NewClock(),
		chars = {},        -- by guid
		order = {},        -- guild roster order
		accounts = {},     -- [account] = saved DB table (or nil)
		charDBs = {},      -- [guid] = per-character saved DB
		chat = {},         -- guild chat lines { from, text }
		online = {},       -- [guid] = client
		messages = 0,
		badWhispers = 0,   -- whispers to a name no online character has
		repeatedFailures = 0, -- failed whispers sent after the sender already got "No player named" for that name
		failedAt = {},     -- ["sender>target"] = time the first failure was reported back
		latency = opts.latency or 0.2,
		-- slowRoster: like the real server, the roster changes only when a
		-- client asks for it (GuildRoster); logins and logouts are announced
		-- right away by a system message.
		slowRoster = opts.slowRoster,
		-- bandwidth (bytes/s, e.g. 800 like ChatThrottleLib): each sender's
		-- messages go through a ChatThrottleLib-like queue (world:Enqueue)
		-- by their wire size (H.WireSize). Off by default: delivery after
		-- latency.
		bandwidth = opts.bandwidth,
		burst = opts.burst or 4000,
		bytes = 0, bytesByType = {}, recvBytes = {}, senders = {}, maxQueueDelay = 0, queueDelayByPrio = {},
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

	function world:AddToGuild(guid)
		self.chars[guid].inGuild = true
		table.insert(self.order, guid)
		for _, client in pairs(self.online) do
			client:Fire("GUILD_ROSTER_UPDATE")
		end
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
	-- Like the server: a whisper reaches the online character of that name
	-- ("Name" means the sender's realm). It fails with "No player named ..."
	-- for unwhisperable characters, and for names with a space unless
	-- world.spaceWhispers (whether Forever allows that is not known yet).
	-- addressee: a GUILD message for one GUID (Protocol's whisper fallback);
	-- everyone receives it, only the addressee reads it.
	world.addressed = 0
	--[[
	Send queue per sender, like ChatThrottleLib: bandwidth refills at
	`bandwidth` bytes/s up to `burst`; a message goes out at once while the
	queues are empty and the bandwidth suffices. Otherwise it waits in the
	queue of its priority (ALERT, NORMAL, BULK). The bandwidth is shared
	equally among the priorities that have something queued, so a small
	ALERT is not stuck behind a large BULK transfer. Messages travel in
	pieces of at most 255 bytes (AceComm), 40 bytes overhead each; a message
	is delivered when its last piece is out.
	]]
	local PRIOS = { "ALERT", "NORMAL", "BULK" }
	local PIECE = 255

	function world:Enqueue(from, wire, prio, onSent)
		local s = self.senders[from.guid]
		local now = self.clock.t
		if not s then
			s = { avail = self.burst, last = now, queues = { ALERT = {}, NORMAL = {}, BULK = {} }, share = {} }
			self.senders[from.guid] = s
		end
		s.avail = math.min(self.burst, s.avail + (now - s.last) * self.bandwidth)
		s.last = now
		local idle = #s.queues.ALERT + #s.queues.NORMAL + #s.queues.BULK == 0
		if idle and s.avail >= wire then
			s.avail = s.avail - wire
			onSent(0, prio)
			return
		end
		local q = s.queues[prio] or s.queues.NORMAL
		local pieces = math.ceil(math.max(1, wire) / (PIECE + 40))
		local size = wire / pieces
		for p = 1, pieces do
			q[#q + 1] = { size = size, last = p == pieces, onSent = onSent, at = now, prio = prio }
		end
		if not s.pumping then
			s.pumping = true
			self.clock:Add(0.1, function() self:Pump(from, s) end)
		end
	end

	function world:Pump(from, s)
		local now = self.clock.t
		local gained = (now - s.last) * self.bandwidth
		s.last = now
		local active = {}
		for _, prio in ipairs(PRIOS) do
			if #s.queues[prio] > 0 then active[#active + 1] = prio end
		end
		if #active == 0 then
			s.pumping = false
			return
		end
		-- Equal shares of the new bandwidth (and of the burst left over).
		local pool = gained + s.avail
		s.avail = 0
		for _, prio in ipairs(active) do
			s.share[prio] = math.min(self.burst, (s.share[prio] or 0) + pool / #active)
		end
		for _, prio in ipairs(active) do
			local q = s.queues[prio]
			while q[1] and s.share[prio] >= q[1].size do
				local piece = table.remove(q, 1)
				s.share[prio] = s.share[prio] - piece.size
				if piece.last then piece.onSent(now - piece.at, prio) end
			end
			if #q == 0 then
				-- An empty priority hands its rest back.
				s.avail = math.min(self.burst, s.avail + s.share[prio])
				s.share[prio] = 0
			end
		end
		self.clock:Add(0.1, function() self:Pump(from, s) end)
	end

	function world:Deliver(from, msg, channel, target, addressee, prio)
		self.messages = self.messages + 1
		self.byType[msg.t] = (self.byType[msg.t] or 0) + 1
		self.sentBy[from.char.name] = (self.sentBy[from.char.name] or 0) + 1
		local wire = H.WireSize(msg)
		self.bytes = self.bytes + wire
		-- Records sent, one per REC and each one inside a BATCH.
		self.records = (self.records or 0) + (msg.t == "R" and 1 or msg.t == "B" and #msg.l or 0)
		self.bytesByType[msg.t] = (self.bytesByType[msg.t] or 0) + wire
		if self.bandwidth then
			self:Enqueue(from, wire, prio or "NORMAL", function(waited, p)
				if waited > self.maxQueueDelay then self.maxQueueDelay = waited end
				local byPrio = self.queueDelayByPrio
				if waited > (byPrio[p] or 0) then byPrio[p] = waited end
				if not from.env.dead then self:Fanout(from, msg, channel, target, addressee, wire) end
			end)
			return
		end
		self:Fanout(from, msg, channel, target, addressee, wire)
	end

	function world:Fanout(from, msg, channel, target, addressee, wire)
		if channel == "WHISPER" then
			local found = false
			local full = target:find("-", 1, true) and target or (target .. "-" .. from.char.realm)
			for guid in pairs(self.online) do
				local c = self.chars[guid]
				if c.name == full and not c.unwhisperable and (self.spaceWhispers or not c.name:find(" ")) then
					found = true
				end
			end
			if not found then
				self.badWhispers = self.badWhispers + 1
				local key = from.char.name .. ">" .. target
				local reported = self.failedAt[key]
				if reported and reported <= self.clock.t then
					self.repeatedFailures = self.repeatedFailures + 1
				end
				self.failedAt[key] = reported or (self.clock.t + self.latency)
				self.clock:Add(self.latency, function()
					from:Fire("CHAT_MSG_SYSTEM", ("No player named '%s' is currently playing."):format(target))
				end, from.env)
				return
			end
		end
		if addressee then
			self.addressed = self.addressed + 1
		end
		for guid, client in pairs(self.online) do
			local c = self.chars[guid]
			local ok = guid ~= from.guid and c.partition == from.char.partition and c.inGuild
			if channel == "WHISPER" then
				local full = target:find("-", 1, true) and target or (target .. "-" .. from.char.realm)
				ok = ok and c.name == full
			end
			if addressee then
				ok = ok and guid == addressee
			end
			-- 0.1.0 knows neither BATCH nor the bucket list in HELLO.
			if ok and c.v010 and msg.t == "B" then ok = false end
			if ok then
				local copy = H.DeepCopy(msg)
				if c.v010 then copy.o = nil end
				self.recvBytes[guid] = (self.recvBytes[guid] or 0) + wire
				self.clock:Add(self.latency, function()
					client.ns.Protocol.Handle(copy, addressee and "WHISPER" or channel, from.char.name)
				end, client.env)
			end
		end
	end

	-- A guild chat line, seen by every online client (like CHAT_MSG_GUILD).
	-- A chat whisper (not an addon message). Recorded in world.whispers and
	-- delivered as CHAT_MSG_WHISPER if the target is online ("Name" means the
	-- sender's realm).
	world.whispers = {}
	function world:Whisper(fromName, target, text)
		local realm = fromName:match("%-([^%-]+)$") or "Realm"
		local full = target:find("-", 1, true) and target or (target .. "-" .. realm)
		table.insert(self.whispers, { from = fromName, to = full, text = text, at = self.clock.t })
		local fromGUID
		for guid, c in pairs(self.chars) do
			if c.name == fromName then fromGUID = guid end
		end
		for guid, client in pairs(self.online) do
			if self.chars[guid].name == full then
				self.clock:Add(self.latency, function()
					client:Fire("CHAT_MSG_WHISPER", text, fromName, "", "", fromName, "", 0, 0, "", 0, 0, fromGUID)
				end, client.env)
			end
		end
	end

	-- The 12th event value is the sender's GUID. world.chatNameFormats: each
	-- client sees the sender's name in another form (realm suffix or not).
	function world:GuildChat(fromName, text)
		table.insert(self.chat, { from = fromName, text = text })
		local fromGUID
		for guid, c in pairs(self.chars) do
			if c.name == fromName then fromGUID = guid end
		end
		for guid, client in pairs(self.online) do
			local shown = fromName
			if self.chatNameFormats and guid ~= fromGUID then
				shown = fromName:gsub("%-.*$", "") .. "-" .. guid
			end
			self.clock:Add(self.latency, function()
				client:Fire("CHAT_MSG_GUILD", text, shown, "", "", shown, "", 0, 0, "", 0, 0, fromGUID)
			end, client.env)
		end
	end

	function world:Login(guid)
		local char = self.chars[guid]
		local client = H.NewClient(self, char)
		self.online[guid] = client
		client:Boot()
		char.wasOnline = true
		for _, other in pairs(self.online) do
			if other ~= client then
				other:Fire("CHAT_MSG_SYSTEM", "|Hplayer:" .. char.name .. "|h[" .. char.name .. "]|h has come online.")
				if not self.slowRoster then other:Fire("GUILD_ROSTER_UPDATE") end
			end
		end
		return client
	end

	function world:Logout(guid)
		local client = self.online[guid]
		if not client then return end
		self.accounts[client.char.account] = client.env.GuildTradebookDB
		self.charDBs[guid] = client.env.GuildTradebookCharDB
		client.env.dead = true
		self.online[guid] = nil
		-- quietLogout: no "has gone offline" message reaches the others.
		if not client.char.quietLogout then
			for _, other in pairs(self.online) do
				other:Fire("CHAT_MSG_SYSTEM", client.char.name .. " has gone offline.")
			end
		end
	end

	function world:ResetCounters()
		self.messages, self.byType, self.sentBy, self.badWhispers = 0, {}, {}, 0
		self.repeatedFailures = 0
		self.bytes, self.bytesByType, self.recvBytes, self.maxQueueDelay = 0, {}, {}, 0
		self.queueDelayByPrio = {}
		self.records = 0
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
	-- char.locale (default enUS): German clients see recipe names as "Rezept <id>".
	env.GetLocale = function() return char.locale or "enUS" end
	-- Chat filters (client.chatFilters[event] = the last one registered).
	env.ChatFrame_AddMessageEventFilter = function(event, fn)
		client.chatFilters = client.chatFilters or {}
		client.chatFilters[event] = fn
	end
	-- char.version / char.build: what this client's TOC says.
	env.C_AddOns = {
		GetAddOnMetadata = function(_, field)
			if field == "Version" then return char.version or (char.v010 and "0.1.0" or "0.2.0-dev") end
			if field == "X-Build" then return tostring(char.build or 0) end
		end,
	}
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
	-- Forever: first name and surname come back as two values.
	env.UnitName = function()
		local base = char.name:gsub("%-.*$", "")
		local first, surname = base:match("^(%S+) (.+)$")
		if first then return first, surname end
		return base
	end
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
		-- rosterName: a roster name that differs from the name the server
		-- puts on the character's messages (robustness against formats).
		-- staleRoster: the roster keeps showing the character online after
		-- a logout (the server's roster is behind).
		local online = world.online[c.guid] ~= nil or (c.staleRoster and c.wasOnline) or false
		return c.rosterName or c.name, "Member", 1, c.level, c.class, "", "", "", online, 0, c.class,
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
		AreOutgoingAddonChatMessagesRestricted = function() return char.noChatPosting end,
		IsAddonMessagePrefixRegistered = function() return true end,
		-- Raw sends (diagnostics). Like the server, GUILD messages also come
		-- back to the sender. char.deaf: this client receives nothing.
		SendAddonMessage = function(prefix, text, channel, target)
			local reached = false
			local full = target and (target:find("-", 1, true) and target or (target .. "-" .. char.realm))
			for guid, other in pairs(world.online) do
				local c = world.chars[guid]
				local ok
				if channel == "GUILD" then
					ok = c.inGuild and c.partition == char.partition
				else
					ok = c.name == full and not c.unwhisperable and (world.spaceWhispers or not c.name:find(" "))
				end
				if ok and not c.deaf then
					reached = true
					clock:Add(world.latency, function()
						other.ns.Protocol.OnComm(prefix, text, channel, char.name)
					end, other.env)
				end
			end
			if channel == "WHISPER" and not reached then
				clock:Add(world.latency, function()
					client:Fire("CHAT_MSG_SYSTEM", ("No player named '%s' is currently playing."):format(target))
				end, env)
			end
			return 0
		end,
		InChatMessagingLockdown = function() return char.restricted end,
		SendChatMessage = function(text, chatType, _, target)
			if chatType == "GUILD" then
				world:GuildChat(char.name, text)
			elseif chatType == "WHISPER" then
				world:Whisper(char.name, target, text)
			end
		end,
	}
	env.C_Spell = {
		GetSpellName = function(id)
			return ((char.locale or "enUS"):sub(1, 2) == "de" and "Rezept " or "Recipe ") .. id
		end,
	}
	-- world.bindTypes[itemID] = 1 (BoP) / 2 (BoE); missing = not loaded yet.
	env.C_Item = {
		GetItemNameByID = function(id)
			return ((char.locale or "enUS"):sub(1, 2) == "de" and "Gegenstand " or "Item ") .. id
		end,
		GetItemCount = function(id) return (char.bags or {})[id] or 0 end,
		GetItemInfo = function(id)
			local bind = (world.bindTypes or {})[id]
			if not bind then return nil end
			return "Item " .. id, "|Hitem:" .. id .. "|h[Item " .. id .. "]|h", 2, 20, 10, "Armor", "Cloth", 1,
				"INVTYPE_CHEST", 1, 0, 4, 1, bind
		end,
		RequestLoadItemDataByID = function() end,
	}
	client.sounds = {}
	-- Popups: shown ones are recorded; tests answer them via client:Answer.
	client.popups = {}
	env.StaticPopupDialogs = {}
	env.StaticPopup_Show = function(which, text1, text2, data)
		table.insert(client.popups, { which = which, text1 = text1, data = data })
	end
	env.YES, env.NO = "Yes", "No"
	function client:Answer(which, accept)
		for i, popup in ipairs(self.popups) do
			if popup.which == which then
				table.remove(self.popups, i)
				local dialog = self.env.StaticPopupDialogs[which]
				local fn = accept and dialog.OnAccept or dialog.OnCancel
				if fn then fn(nil, popup.data) end
				return true
			end
		end
		return false
	end
	env.PlaySound = function(id, channel)
		table.insert(client.sounds, { id = id, channel = channel })
		return true, 1
	end
	env.SOUNDKIT = { TELL_MESSAGE = 1 }

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
			-- char.staleTabSwitch: the first read after a tab switch still
			-- returns the previous profession's list (seen in the beta).
			local skill = client.openSkill
			if char.staleTabSwitch and client.staleSkill then
				skill, client.staleSkill = client.staleSkill, nil
			end
			local p = char.profs[skill]
			for rid in pairs(p and p.recipes or {}) do ids[#ids + 1] = rid end
			table.sort(ids)
			return ids
		end,
		-- char.recipeCats[rid] = categoryID; the game names categories in the
		-- client's language ("Category 10" / "Kategorie 10").
		GetRecipeInfo = function(rid) return { recipeID = rid, learned = true, categoryID = (char.recipeCats or {})[rid] } end,
		GetCategoryInfo = function(id)
			local de = (char.locale or "enUS"):sub(1, 2) == "de"
			return { categoryID = id, name = (de and "Kategorie " or "Category ") .. id, parentCategoryID = 0, uiOrder = id }
		end,
		-- char.cooldowns[rid] = seconds remaining (0 = ready but has a cooldown)
		GetRecipeCooldown = function(rid)
			local cd = (char.cooldowns or {})[rid]
			if cd and cd > 0 then return cd, true, 0, 0 end
		end,
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
		env.GuildTradebookCharDB = H.DeepCopy(world.charDBs[char.guid])
		for _, file in ipairs(H.FILES) do
			loadInto(H.ADDON_DIR .. file, env)("GuildTradebook", ns)
		end
		ns.Tooltip = { Start = function() end }
		ns.Settings = { Register = function() end, Open = function() end }
		ns.MinimapButton = { Start = function() end, SetShown = function() end }
		ns.UI = { Toggle = function() end, Show = function() end }
		local transport
		transport = function(msg, channel, target, prio, addressee)
			if char.v010 and msg.t == "B" then
				-- 0.1.0 sends no batches: one REC per record.
				for _, wire in ipairs(msg.l) do
					local single = H.DeepCopy(msg)
					single.t, single.l, single.r = "R", nil, wire
					transport(single, channel, target, prio, addressee)
				end
				return
			end
			if char.v010 and msg.t == "R" and type(msg.r) == "table" then
				-- 0.1.0 reads and relays only the first 8 record slots, and the
				-- first 8 of each profession.
				msg.r[9], msg.r[10] = nil, nil
				for _, prof in ipairs(type(msg.r[8]) == "table" and msg.r[8] or {}) do
					if type(prof) == "table" then prof[9] = nil end
				end
			end
			if char.v010 then msg.bt = nil end
			if char.legacy then
				-- A build from before the sender GUID and version fields; it
				-- knows nothing about version requests either.
				if msg.t == "V" or msg.t == "N" then return end
				msg.u, msg.av, msg.ab = nil, nil, nil
			end
			world:Deliver(client, msg, channel, target, addressee, prio)
		end
		ns.Protocol.transport = transport
		self:Fire("ADDON_LOADED", "GuildTradebook")
		self:Fire("PLAYER_LOGIN")
	end

	-- Simulates opening the profession window.
	function client:OpenTradeSkill(skillLine)
		self.staleSkill = self.openSkill
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
		GetNormalizedRealmName = function() return "Realm" end,
	}, { __index = _G })
	for _, file in ipairs({ "Locales/enUS.lua", "Core/Init.lua", "Core/Util.lua", "Data/Store.lua", "Search/Upgrades.lua",
		"Features/Wishlist.lua", "Features/Reagents.lua", "Features/ChatResponder.lua" }) do
		loadInto(H.ADDON_DIR .. file, env)("GuildTradebook", ns)
	end
	return ns
end

return H
