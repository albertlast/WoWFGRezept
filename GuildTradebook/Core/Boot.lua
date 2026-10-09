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
	ns.Wishlist.Start()
	ns.ChatResponder.Start()
	ns.Tooltip.Start()
	ns.Settings.Register()
	ns.MinimapButton.Start()
end)
