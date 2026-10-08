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
	ns.Print(("%s ver=%d seq=%d h=%d from=%s gone=%s"):format(rec.name, rec.ver, rec.seq, rec.h or 0,
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

local function setMain(name)
	local own = ns.Scanner.GetOwn()
	if not own then return end
	local mainGUID
	if name and name ~= "" then
		mainGUID = Roster.GuidByName(name)
		if not mainGUID then
			ns.Print("unknown guild member:", name)
			return
		end
	end
	if own.main ~= mainGUID then
		own.main = mainGUID
		ns.Scanner.Commit(own, "major")
	end
	ns.Print("main:", name ~= "" and name or "-")
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
	elseif cmd == "main" then
		setMain(rest)
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
		for _, line in ipairs(ns.log) do print(line) end
	elseif cmd == "dump" then
		dump(rest)
	elseif cmd == "stats" then
		stats()
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
	ns.Tooltip.Start()
end)
