local ADDON, ns = ...

local Store, Roster, Util, L = ns.Store, ns.Roster, ns.Util, ns.L

function ns.GetGuildData()
	if not ns.db or not Roster.guildKey then return nil end
	return Store.GetGuild(ns.db, Roster.guildKey)
end

local function dump(name)
	local gd = ns.GetGuildData()
	local guid = Roster.GuidByName(name)
	local rec = gd and guid and gd.chars[guid]
	if not rec then
		ns.Print("no data for", name)
		return
	end
	local int = Store.FormatInt
	ns.Print(("%s ver=%s seq=%s h=%s from=%s gone=%s"):format(rec.name, int(rec.ver), int(rec.seq), int(rec.h),
		tostring(rec.recvFrom), tostring(rec.goneSince)))
	for sl, p in pairs(rec.profs) do
		local count = p.recipes and Util.Count(p.recipes) or -1
		local contradicted = Roster.IsProfessionContradicted(guid, sl) and " [server: no longer has it]" or ""
		ns.Print(("  %s (%d) rank %d/%d recipes=%s%s%s"):format(ns.Index.SkillLineName(sl), sl, p.rank, p.maxRank,
			count >= 0 and count or L.NOT_SCANNED, p.unverified and (" " .. L.UNVERIFIED) or "", contradicted))
	end
end

local function stats()
	local gd = ns.GetGuildData()
	if not gd then
		ns.Print(L.NOT_IN_GUILD)
		return
	end
	local chars, recipes, hidden = 0, 0, 0
	for _, rec in pairs(gd.chars) do
		if rec.goneSince then
			hidden = hidden + 1
		else
			chars = chars + 1
			for _, p in pairs(rec.profs) do
				recipes = recipes + (p.recipes and Util.Count(p.recipes) or 0)
			end
		end
	end
	ns.Print(("guild=%s roster=%s records=%d hidden=%d recipes=%d facts=%d outbox=%d"):format(
		Roster.guildKey, tostring(Roster.ready), chars, hidden, recipes, Util.Count(ns.db.recipeFacts), #ns.Protocol.outbox))
end

--[[
Memory tracking ("/gtb mem"), a debug aid. While on:
  - every SAMPLE_EVERY seconds the game's figure for this addon
    (GetAddOnMemoryUsage): now, lowest, highest, and the sum of the rises
    between samples (what was allocated; a fall is the garbage collector,
    so this is a lower bound)
  - every game event, internal callback (emit), keyed timer and module
    function (ns.Roster.Refresh, ...) runs through a wrapper that reads
    collectgarbage("count") before and after: calls and KB allocated.
    Inclusive (a function counts what it calls), and a garbage collector
    step inside a call makes it look smaller. The wrappers cost time
    themselves; it is off by default and after every reload.
The report goes to chat ("/gtb mem") and to GuildTradebookDB.memReport,
written with every sample, so a reload or logout keeps the latest.
]]
local Mem = { stats = {}, wrapped = {}, names = {}, depth = 0, topKB = 0 }
Mem.SAMPLE_EVERY = 10
Mem.REPORT_LINES = 30

local function memUpdate()
	local update = UpdateAddOnMemoryUsage or (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage)
	local get = GetAddOnMemoryUsage or (C_AddOns and C_AddOns.GetAddOnMemoryUsage)
	if not (update and get) then return nil end
	update()
	return get(ADDON)
end

local function memRecord(name, before, ...)
	Mem.depth = Mem.depth - 1
	local kb = collectgarbage("count") - before
	if kb < 0 then kb = 0 end
	local s = Mem.stats[name]
	if not s then
		s = { kb = 0, calls = 0 }
		Mem.stats[name] = s
	end
	s.kb, s.calls = s.kb + kb, s.calls + 1
	if Mem.depth == 0 then Mem.topKB = Mem.topKB + kb end
	return ...
end

-- ns.memTrack: see Core/Init.lua.
local function memTrack(kind, key, fn, ...)
	local byKind = Mem.names[kind]
	if not byKind then
		byKind = {}
		Mem.names[kind] = byKind
	end
	local name = byKind[key]
	if not name then
		name = kind .. " " .. tostring(key)
		byKind[key] = name
	end
	Mem.depth = Mem.depth + 1
	return memRecord(name, collectgarbage("count"), fn(...))
end

local function memWrapModules()
	for modName, mod in pairs(ns) do
		if type(mod) == "table" and modName ~= "L" and modName ~= "db" and modName ~= "charDB" then
			for k, f in pairs(mod) do
				if type(f) == "function" and type(k) == "string" then
					local name = "  " .. modName .. "." .. k
					Mem.wrapped[#Mem.wrapped + 1] = { mod, k, f }
					mod[k] = function(...)
						Mem.depth = Mem.depth + 1
						return memRecord(name, collectgarbage("count"), f(...))
					end
				end
			end
		end
	end
end

local function memUnwrap()
	for _, w in ipairs(Mem.wrapped) do
		w[1][w[2]] = w[3]
	end
	Mem.wrapped = {}
end

function Mem.Report()
	local lines = {}
	local minutes = (GetTime() - Mem.started) / 60
	local s = Mem.sample
	lines[1] = ("%s %s, %.1f min tracked"):format(L.TITLE, (ns.Versions.Mine()), minutes)
	if s.now then
		lines[2] = ("addon memory: now %.1f MB, lowest %.1f MB, highest %.1f MB; allocated at least %.1f MB (%.2f MB/min)")
			:format(s.now / 1024, s.min / 1024, s.max / 1024, s.rises / 1024, s.rises / 1024 / math.max(minutes, 0.01))
	end
	lines[#lines + 1] = ("tracked calls allocated %.1f MB (%.2f MB/min)"):format(Mem.topKB / 1024,
		Mem.topKB / 1024 / math.max(minutes, 0.01))
	local list = {}
	for name, st in pairs(Mem.stats) do list[#list + 1] = { name = name, kb = st.kb, calls = st.calls } end
	table.sort(list, function(a, b) return a.kb > b.kb end)
	for i = 1, math.min(Mem.REPORT_LINES, #list) do
		local e = list[i]
		lines[#lines + 1] = ("%9.0f KB %7d calls %7.1f KB/call %s"):format(e.kb, e.calls, e.kb / e.calls, e.name)
	end
	return lines
end

local function memSave()
	ns.db.memReport = { at = date and date("%Y-%m-%d %H:%M:%S") or "", lines = Mem.Report() }
end

local function memSample()
	Mem.depth = 0 -- an error inside a wrapped call left it raised
	local kb = memUpdate()
	if kb then
		local s = Mem.sample
		if s.now and kb > s.now then s.rises = s.rises + (kb - s.now) end
		s.now = kb
		s.min = math.min(s.min or kb, kb)
		s.max = math.max(s.max or kb, kb)
	end
	memSave()
end

local function mem(rest)
	if rest == "off" then
		if Mem.ticker then
			memSample()
			Mem.ticker:Cancel()
			Mem.ticker = nil
			ns.memTrack = nil
			memUnwrap()
		end
		ns.Print("mem: off")
		return
	end
	if not Mem.ticker then
		Mem.stats, Mem.names, Mem.depth, Mem.topKB = {}, {}, 0, 0
		Mem.started = GetTime()
		Mem.sample = { rises = 0 }
		memWrapModules()
		ns.memTrack = memTrack
		Mem.ticker = C_Timer.NewTicker(Mem.SAMPLE_EVERY, memSample)
		memSample()
		ns.Print("mem: on - \"/gtb mem\" shows the report, \"/gtb mem off\" stops")
		return
	end
	memSample()
	for _, line in ipairs(Mem.Report()) do
		print(line)
	end
end

local function slash(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "" then
		ns.UI.Toggle()
	elseif cmd == "search" then
		ns.UI.Show("search", rest)
	elseif cmd == "upgrades" then
		ns.UI.Show("upgrades")
	elseif cmd == "wishlist" then
		ns.UI.Show("wishlist")
	elseif cmd == "options" or cmd == "settings" then
		ns.Settings.Open()
	elseif cmd == "glow" then
		ns.MinimapButton.Report()
	elseif cmd == "minimap" then
		ns.db.options.minimapButton = not ns.db.options.minimapButton
		ns.MinimapButton.SetShown(ns.db.options.minimapButton)
	elseif cmd == "chatbot" then
		ns.db.options.chatResponder = not ns.db.options.chatResponder
		ns.Print("!craft:", tostring(ns.db.options.chatResponder))
	elseif cmd == "link" then
		ns.Link.Command(rest)
	elseif cmd == "unlink" then
		if ns.Link.IsLinked() then
			ns.Link.ConfirmUnlink()
		else
			ns.Print(L.LINK_STATUS_NONE)
		end
	elseif cmd == "versions" or cmd == "version" or cmd == "ver" then
		ns.Versions.Request()
	elseif cmd == "diag" then
		ns.Protocol.Diagnose(rest)
	elseif cmd == "resync" then
		ns.Protocol.sync = nil
		ns.Protocol.StartSync()
	elseif cmd == "tooltip" then
		ns.db.options.tooltip = not ns.db.options.tooltip
		ns.Print("tooltip:", tostring(ns.db.options.tooltip))
	elseif cmd == "debug" then
		ns.db.options.debug = not ns.db.options.debug
		ns.Print("debug:", tostring(ns.db.options.debug))
	elseif cmd == "log" then
		local header = ("%s %s - %s - %s"):format(L.TITLE, (ns.Versions.Mine()), tostring(Util.PlayerName()),
			date and date("%Y-%m-%d %H:%M") or "")
		ns.Widgets.ShowText(L.LOG_TITLE, header .. "\n" .. table.concat(ns.log, "\n"))
	elseif cmd == "dump" then
		dump(rest)
	elseif cmd == "export" then
		ns.Export.Command(rest)
	elseif cmd == "stats" then
		stats()
	elseif cmd == "mem" then
		mem(rest)
	else
		for line in L.SLASH_HELP:gmatch("[^\n]+") do
			print(line)
		end
	end
end

function GuildTradebook_OnAddonCompartmentClick()
	ns.UI.Toggle()
end

ns.RegisterEvent("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	ns.db = Store.InitDB(GuildTradebookDB)
	GuildTradebookDB = ns.db
	GuildTradebookCharDB = GuildTradebookCharDB or {}
	ns.charDB = GuildTradebookCharDB
end)

ns.RegisterEvent("PLAYER_LOGIN", function()
	SLASH_GUILDTRADEBOOK1 = "/gtb"
	SLASH_GUILDTRADEBOOK2 = "/tradebook"
	SlashCmdList.GUILDTRADEBOOK = slash

	Roster.Start()
	ns.Scanner.Start()
	ns.Protocol.Start()
	ns.Wishlist.Start()
	ns.ChatResponder.Start()
	ns.Link.Start()
	ns.Mail.Start()
	ns.Tooltip.Start()
	ns.Settings.Register()
	ns.MinimapButton.Start()
end)
