--[[
Members tab, three views (dropdown at the top right, remembered per
character in ns.charDB.members):
  players      one group per person: the online or highest character first,
               the other characters indented below; fixed columns for the
               primary professions, or (switch above the list) the secondary
               ones; the details in the row's tooltip
  professions  one collapsible group per profession, members by skill level
  cooldowns    one collapsible group per cooldown recipe (recipes sharing a
               cooldown are one group), ready and reachable crafters first
Every view starts with one row per profession of this character that has not
been read yet; a click opens its window, which reads it. The game allows that
only from the click itself (no timer, no event).
"Only reachable now" hides characters nobody can ask right now (offline,
and not online on another character), in every view. The search box
(not remembered) matches character names and profession names:
  players      keeps a person when one of their characters matches
  groups       a matching group label (profession, cooldown recipe) keeps
               the whole group; otherwise only the matching characters,
               and the group is shown open
]]
local _, ns = ...

local L, W, Index, Roster, Store, Util = ns.L, ns.Widgets, ns.Index, ns.Roster, ns.Store, ns.Util
local ui = {}
local MembersView = {}
ns.MembersView = MembersView

MembersView.VIEWS = { "players", "professions", "cooldowns" }
local VIEW_LABELS = { players = "VIEW_PLAYERS", professions = "VIEW_PROFESSIONS", cooldowns = "VIEW_COOLDOWNS" }
local COOLDOWN_GROUP_LABELS = { transmute = "COOLDOWN_TRANSMUTES" }
local MAX_READY_NAMES = 3
local ICON_OPEN = "|TInterface\\Buttons\\UI-MinusButton-Up:14:14|t "
local ICON_CLOSED = "|TInterface\\Buttons\\UI-PlusButton-Up:14:14|t "

-- { view, reachable, secondary, open = { [group key] = true } }
function MembersView.Settings()
	local s = ns.charDB.members
	if type(s) ~= "table" then
		s = {}
		ns.charDB.members = s
	end
	local known = false
	for _, v in ipairs(MembersView.VIEWS) do
		if s.view == v then known = true end
	end
	if not known then s.view = "players" end
	s.reachable = s.reachable == true
	s.secondary = s.secondary == true
	if type(s.open) ~= "table" then s.open = {} end
	return s
end

local function isMember(guid)
	return Roster.IsMember(guid)
end

-- Search text, trimmed and lower case ("" = no search).
local function needleOf(text)
	return text and text:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
end

local function matches(text, needle)
	return needle == "" or (text ~= nil and text:lower():find(needle, 1, true) ~= nil)
end

--[[
The cooldowns of one profession as shown: { key, group?, label, rids, readyAt }.
Recipes sharing a cooldown become one entry with the latest time: a running
cooldown holds them all, and a hidden time (far in the future) stays hidden.
]]
local function cooldownList(cds)
	local list, groups = {}, {}
	for _, rid in ipairs(Util.SortedKeys(cds)) do
		local group = Store.COOLDOWN_GROUPS[rid]
		local c = group and groups[group]
		if c then
			c.rids[#c.rids + 1] = rid
			c.readyAt = math.max(c.readyAt, cds[rid])
		else
			c = { key = group or rid, group = group, rids = { rid }, readyAt = cds[rid],
				label = group and L[COOLDOWN_GROUP_LABELS[group]] or Index.RecipeName(rid) or ("#" .. rid) }
			list[#list + 1] = c
			if group then groups[group] = c end
		end
	end
	return list
end

local function grey(text)
	return "|cff808080" .. text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r"
end

-- The secondary professions' columns (players view), by name.
function MembersView.SecondaryColumns()
	local list = {}
	for sl in pairs(Roster.SECONDARY_SKILLLINES) do list[#list + 1] = sl end
	table.sort(list, function(a, b) return Index.SkillLineName(a) < Index.SkillLineName(b) end)
	return list
end

--[[
Pure: a character's professions for the players view:
  primary    { cell, ... }  the columns, professions the server still confirms first
  secondary  { [skillLine] = cell }  Cooking, First Aid, Fishing (fixed columns)
  details    { line, ... }  everything for the row's tooltip
cell = { rank = "205/300", name, mark }. A specialization replaces the profession's
name (its name says the profession, the tooltip has both), so two specialized
professions still fit. Markers: "!" not scanned yet, "?" unverified; grey: the
server says the member no longer has it.
]]
function MembersView.ProfessionCells(rec)
	local out = { primary = {}, secondary = {}, details = {} }
	local skillLines = Store.ProfessionSkillLines(rec)
	local contradicted = {}
	for _, sl in ipairs(skillLines) do
		contradicted[sl] = Roster.IsProfessionContradicted(rec.guid, sl)
	end
	table.sort(skillLines, function(a, b)
		local sa, sb = Roster.SECONDARY_SKILLLINES[a] or false, Roster.SECONDARY_SKILLLINES[b] or false
		if sa ~= sb then return sb end
		if contradicted[a] ~= contradicted[b] then return contradicted[b] end
		return Index.SkillLineName(a) < Index.SkillLineName(b)
	end)
	local now = ns.Now()
	for _, sl in ipairs(skillLines) do
		local p = rec.profs[sl]
		local profName = Index.SkillLineName(sl)
		local spec = Index.SpecName(p.spec)
		local rank = ("%d/%d"):format(p.rank, p.maxRank)
		local cell = { rank = rank, name = spec and ("|cff66ccff" .. spec .. "|r") or profName, mark = "" }
		local notes = {}
		if not p.recipes then
			cell.rank = "|cffff8000" .. rank .. "|r"
			cell.mark = " |cffff8000!|r"
			notes[#notes + 1] = "|cffff8000" .. L.NOT_SCANNED .. "|r"
		else
			notes[#notes + 1] = "|cff999999" .. L.MEMBERS_RECIPES:format(Util.Count(p.recipes)) .. "|r"
			if p.unverified then
				cell.mark = " |cffff8000?|r"
				notes[#notes + 1] = "|cffff8000" .. L.UNVERIFIED .. "|r"
			end
		end
		for _, c in ipairs(cooldownList(p.cds or {})) do
			local readyAt = c.readyAt
			local state = Store.IsHiddenCooldown(readyAt) and ("|cff808080" .. L.CD_NOT_SHARED .. "|r")
				or readyAt <= now and ("|cff20ff20" .. L.CD_READY .. "|r")
				or ("|cffff8000" .. Util.FormatAge(readyAt - now) .. "|r")
			notes[#notes + 1] = c.label .. " " .. state
		end
		local head = profName .. " " .. rank
		if spec then head = head .. " - |cff66ccff" .. spec .. "|r" end
		local lines = { head }
		for _, note in ipairs(notes) do lines[#lines + 1] = "   " .. note end
		if contradicted[sl] then
			cell.rank, cell.name, cell.mark = grey(cell.rank), grey(cell.name), grey(cell.mark)
			lines[#lines + 1] = "   " .. L.SERVER_DROPPED
			for i, line in ipairs(lines) do lines[i] = grey(line) end
		end
		if Roster.SECONDARY_SKILLLINES[sl] then
			out.secondary[sl] = cell
		else
			out.primary[#out.primary + 1] = cell
		end
		for _, line in ipairs(lines) do out.details[#out.details + 1] = line end
	end
	return out
end

-- One group per person (characters with the same player ID). The group's
-- first row is the character that is online, else the highest level one;
-- the other characters follow indented, by name.
local function groupRows(rows)
	local groups, byKey = {}, {}
	for _, row in ipairs(rows) do
		local key = row.player or row.guid
		local g = byKey[key]
		if not g then
			g = { rows = {}, hasData = false }
			byKey[key] = g
			groups[#groups + 1] = g
		end
		g.rows[#g.rows + 1] = row
		g.hasData = g.hasData or row.ver > 0
	end
	for _, g in ipairs(groups) do
		table.sort(g.rows, function(a, b)
			if a.online ~= b.online then return a.online end
			if a.level ~= b.level then return a.level > b.level end
			return a.name < b.name
		end)
		local first = table.remove(g.rows, 1)
		table.sort(g.rows, function(a, b) return a.name < b.name end)
		table.insert(g.rows, 1, first)
	end
	table.sort(groups, function(a, b)
		if a.hasData ~= b.hasData then return a.hasData end
		return a.rows[1].name < b.rows[1].name
	end)
	local out, players = {}, 0
	for _, g in ipairs(groups) do
		if g.hasData then players = players + 1 end
		for i, row in ipairs(g.rows) do
			row.alt = i > 1
			out[#out + 1] = row
		end
	end
	return out, players
end

-- Guild totals for the stats line: people sharing data, their characters,
-- recipes. The filters do not change them.
local function stats(gd)
	local people, players, characters, recipes = {}, 0, 0, 0
	for guid, rec in pairs(gd.chars) do
		if Store.IsShareable(rec, isMember) then
			characters = characters + 1
			local key = rec.player or guid
			if not people[key] then
				people[key] = true
				players = players + 1
			end
			for sl, p in pairs(rec.profs) do
				if not Store.IsClassSkill(sl) then
					recipes = recipes + (p.recipes and Util.Count(p.recipes) or 0)
				end
			end
		end
	end
	return players, characters, recipes
end

-- Players view rows ({kind = "member", ...}).
local function playerRows(gd, reachableOnly, needle)
	local rows = {}
	local seen = {}
	for guid, rec in pairs(gd.chars) do
		if Store.IsShareable(rec, isMember) then
			seen[guid] = true
			local member = Roster.Get(guid)
			local profNames = {}
			for _, sl in ipairs(Store.ProfessionSkillLines(rec)) do
				profNames[#profNames + 1] = Index.SkillLineName(sl)
				profNames[#profNames + 1] = Index.SpecName(rec.profs[sl].spec)
			end
			local cells = MembersView.ProfessionCells(rec)
			rows[#rows + 1] = {
				kind = "member",
				guid = guid,
				player = rec.player,
				name = Roster.NameOf(guid) or "?",
				class = (member and member.class) or rec.class,
				level = (member and member.level) or rec.level or 0,
				online = (member and member.online) or false,
				via = Index.Via(guid),
				isSelf = guid == UnitGUID("player"),
				isAlt = guid ~= UnitGUID("player") and (ns.db.account.chars[guid] ~= nil or ns.Link.IsPartner(guid)),
				linked = ns.Link.IsPartner(guid),
				ver = rec.ver,
				cells = cells,
				details = cells.details,
				searchText = table.concat(profNames, " "),
			}
		end
	end
	-- Members the server lists with professions but who share no data.
	for guid, member in pairs(Roster.members) do
		local server = Roster.ServerProfessions(guid)
		if not seen[guid] and server then
			-- Names only: the server reports every rank as 1.
			local names, primary = {}, {}
			for sl in pairs(server) do names[#names + 1] = Index.SkillLineName(sl) end
			table.sort(names)
			for i, name in ipairs(names) do primary[i] = { rank = "", name = "|cff808080" .. name .. "|r", mark = "" } end
			rows[#rows + 1] = {
				kind = "member",
				guid = guid, name = member.name, class = member.class, level = member.level or 0,
				online = member.online or false, ver = 0,
				cells = { primary = primary, secondary = {} },
				searchText = table.concat(names, " "),
			}
		end
	end
	if reachableOnly then
		local kept = {}
		for _, row in ipairs(rows) do
			if row.online or row.via then kept[#kept + 1] = row end
		end
		rows = kept
	end
	if needle ~= "" then
		-- The whole person stays when one of their characters matches.
		local hit = {}
		for _, row in ipairs(rows) do
			if matches(row.name, needle) or matches(row.searchText, needle) then
				hit[row.player or row.guid] = true
			end
		end
		local kept = {}
		for _, row in ipairs(rows) do
			if hit[row.player or row.guid] then kept[#kept + 1] = row end
		end
		rows = kept
	end
	return (groupRows(rows))
end

-- A character inside a profession or cooldown group.
local function entry(guid, rec)
	local c = Index.CrafterInfo(guid)
	return {
		kind = "entry", guid = guid, name = c.name, class = c.class, online = c.online, via = c.via,
		reachable = c.reachable, isSelf = c.isSelf, isAlt = c.isAlt, linked = ns.Link.IsPartner(guid),
		ver = rec.ver, alt = true,
	}
end

-- Groups (sorted) and their open entries into one row list. Searching: a
-- group whose label matches stays whole; otherwise only its matching
-- characters stay, shown open, and a group without any is left out.
local function flatten(groups, open, needle)
	local rows = {}
	for _, g in ipairs(groups) do
		local entries, forced = g.entries, false
		if needle ~= "" and not matches(g.header.label, needle) and not matches(g.header.searchText, needle) then
			entries = {}
			for _, e in ipairs(g.entries) do
				if matches(e.name, needle) or (e.spec and matches(e.spec, needle)) then entries[#entries + 1] = e end
			end
			forced = true
		end
		if #entries > 0 then
			g.header.open = forced or open[g.header.key] == true
			rows[#rows + 1] = g.header
			if g.header.open then
				for _, e in ipairs(entries) do rows[#rows + 1] = e end
			end
		end
	end
	return rows
end

local function professionRows(gd, reachableOnly, open, needle)
	local byLine = {}
	for guid, rec in pairs(gd.chars) do
		if Store.IsShareable(rec, isMember) then
			for sl, p in pairs(rec.profs) do
				if Index.IsProfessionVisible(rec, sl) then
					local e = entry(guid, rec)
					if e.reachable or not reachableOnly then
						e.skillLine, e.rank = sl, p.rank
						e.right = ("%d/%d"):format(p.rank, p.maxRank)
						e.extra = p.recipes and ("|cff999999" .. L.MEMBERS_RECIPES:format(Util.Count(p.recipes)) .. "|r")
							or ("|cffff8000" .. L.NOT_SCANNED .. "|r")
						e.spec = Index.SpecName(p.spec)
						if e.spec then
							e.extra = "|cff66ccff" .. e.spec .. "|r  " .. e.extra
						end
						local g = byLine[sl]
						if not g then
							g = { entries = {}, best = 0, primary = false }
							byLine[sl] = g
						end
						g.entries[#g.entries + 1] = e
						g.best = math.max(g.best, p.rank)
						g.primary = g.primary or p.primary == true
					end
				end
			end
		end
	end
	local groups = {}
	for sl, g in pairs(byLine) do
		table.sort(g.entries, function(a, b)
			if a.rank ~= b.rank then return a.rank > b.rank end
			if a.reachable ~= b.reachable then return a.reachable end
			return a.name < b.name
		end)
		local label = Index.SkillLineName(sl)
		g.header = {
			kind = "group", key = "p:" .. sl, label = label, dim = not g.primary,
			summary = L.MEMBERS_PROF_SUMMARY:format(#g.entries, g.best),
		}
		groups[#groups + 1] = g
	end
	table.sort(groups, function(a, b)
		if a.primary ~= b.primary then return a.primary end
		return a.header.label < b.header.label
	end)
	return flatten(groups, open, needle)
end

local function cooldownRows(gd, reachableOnly, open, needle)
	local now = ns.Now()
	local byCooldown = {}
	for guid, rec in pairs(gd.chars) do
		if Store.IsShareable(rec, isMember) then
			for sl, p in pairs(rec.profs) do
				for _, c in ipairs(cooldownList(not Store.IsClassSkill(sl) and p.cds or {})) do
					local e = entry(guid, rec)
					if e.reachable or not reachableOnly then
						local readyAt = c.readyAt
						e.readyAt, e.ready = readyAt, readyAt <= now
						e.hidden = Store.IsHiddenCooldown(readyAt)
						if c.group then
							-- No single recipe: a click shows the member's recipes of
							-- this profession, the menu offers each transmute.
							e.recipes, e.skillLine = c.rids, sl
						else
							e.recipeID = c.rids[1]
						end
						local mailedAt
						for _, rid in ipairs(c.rids) do
							mailedAt = math.max(mailedAt or 0, ns.Mail.SentAt(guid, rid) or 0)
						end
						if mailedAt > 0 then
							e.extra = "|cff66ccff" .. L.MAILED_AGO:format(Util.FormatAge(now - mailedAt)) .. "|r"
						end
						e.right = e.hidden and ("|cff808080" .. L.CD_NOT_SHARED .. "|r")
							or e.ready and ("|cff20ff20" .. L.CD_READY .. "|r")
							or ("|cffff8000" .. Util.FormatAge(readyAt - now) .. "|r")
						local g = byCooldown[c.key]
						if not g then
							g = { entries = {}, cooldown = c, recipes = {} }
							byCooldown[c.key] = g
						end
						for _, rid in ipairs(c.rids) do g.recipes[rid] = true end
						table.insert(g.entries, e)
					end
				end
			end
		end
	end
	local groups = {}
	for key, g in pairs(byCooldown) do
		table.sort(g.entries, function(a, b)
			if a.ready ~= b.ready then return a.ready end
			if a.ready then
				if a.reachable ~= b.reachable then return a.reachable end
				return a.name < b.name
			end
			if a.readyAt ~= b.readyAt then return a.readyAt < b.readyAt end
			return a.name < b.name
		end)
		local ready, nextUp = {}, nil
		for _, e in ipairs(g.entries) do
			if e.ready then
				ready[#ready + 1] = e
			elseif not nextUp and not e.hidden then
				nextUp = e
			end
		end
		local names = {}
		for i = 1, math.min(#ready, MAX_READY_NAMES) do
			names[i] = W.CrafterShort(ready[i], true)
		end
		local summary = #ready > 0 and table.concat(names, ", ") or ("|cff808080" .. L.COOLDOWN_NONE_READY .. "|r")
		if #ready > MAX_READY_NAMES then
			summary = summary .. " +" .. (#ready - MAX_READY_NAMES)
		end
		if nextUp then
			summary = summary .. "   |cff999999" .. L.COOLDOWN_NEXT:format(Util.ShortName(nextUp.name),
				Util.FormatAge(nextUp.readyAt - now)) .. "|r"
		end
		g.readyReachable = false
		for _, e in ipairs(ready) do
			if e.reachable then g.readyReachable = true end
		end
		g.soonest = #ready > 0 and 0 or (nextUp and nextUp.readyAt) or math.huge
		g.header = {
			kind = "group", key = "c:" .. key, label = g.cooldown.label, summary = summary,
			recipeID = not g.cooldown.group and g.cooldown.rids[1] or nil,
		}
		if g.cooldown.group then
			-- Searching "arcanite" finds the transmutes.
			local names = {}
			for rid in pairs(g.recipes) do names[#names + 1] = Index.RecipeName(rid) or "" end
			g.header.searchText = table.concat(names, " ")
		end
		groups[#groups + 1] = g
	end
	table.sort(groups, function(a, b)
		if a.readyReachable ~= b.readyReachable then return a.readyReachable end
		if a.soonest ~= b.soonest then return a.soonest < b.soonest end
		return a.header.label < b.header.label
	end)
	return flatten(groups, open, needle)
end

-- One row per profession of this character that was never read.
local function scanRows(gd)
	local rec = gd.chars[UnitGUID("player")]
	local rows = {}
	for _, sl in ipairs(rec and Store.ProfessionSkillLines(rec) or {}) do
		if not rec.profs[sl].recipes then
			rows[#rows + 1] = { kind = "scan", skillLine = sl,
				text = "|cffff8000" .. L.SCAN_ROW:format(Index.SkillLineName(sl)) .. "|r" }
		end
	end
	return rows
end

-- Must run inside a click: the game blocks the call from anywhere else.
function MembersView.OpenProfession(skillLine)
	local ok, opened = pcall(C_TradeSkillUI.OpenTradeSkill, skillLine)
	if not ok or opened == false then
		ns.Print(L.REMIND_SCAN:format(Index.SkillLineName(skillLine)))
	end
end

--[[
Rows for one view: { kind = "member" | "group" | "entry" | "info" | "scan", ... }
  group:  key, label, summary, open, dim?
  entry:  guid, name, class, online, via, reachable, isSelf, isAlt, right, extra,
          skillLine (professions) or recipeID (cooldowns); a cooldown shared by
          several recipes has recipes and skillLine instead of recipeID
  scan:   skillLine, text
text: optional search (character or profession name).
Second value: the stats line (guild totals, not filtered).
]]
function MembersView.Rows(view, reachableOnly, open, text)
	local gd = ns.GetGuildData()
	if not gd then return {}, "" end
	local needle = needleOf(text)
	local rows
	if view == "professions" then
		rows = professionRows(gd, reachableOnly, open or {}, needle)
	elseif view == "cooldowns" then
		rows = cooldownRows(gd, reachableOnly, open or {}, needle)
		if #rows == 0 and needle == "" then
			rows = { { kind = "info", text = L.COOLDOWNS_EMPTY } }
		end
	else
		rows = playerRows(gd, reachableOnly, needle)
	end
	if #rows == 0 and needle ~= "" then
		rows = { { kind = "info", text = L.MEMBERS_NO_MATCH } }
	end
	if needle == "" then
		local scans = scanRows(gd)
		for i = #scans, 1, -1 do table.insert(rows, 1, scans[i]) end
	end
	return rows, L.MEMBERS_STATS:format(stats(gd))
end

local searchText = ""

--[[
Players view layout (window 760 wide, list about 714): name and the age of
the data in the name button, then the profession columns at fixed places, so
they line up from row to row. Primary: two columns, rank then name (or
specialization; too long is cut with "..."). Secondary: one column per
profession, rank only, the profession named in the header above the list.
]]
local NAME_WIDTH, AGE_WIDTH = 150, 38
local MEMBER_BUTTON_WIDTH = 4 + NAME_WIDTH + 4 + AGE_WIDTH
local GROUP_BUTTON_WIDTH = 248
local COLUMNS_X = MEMBER_BUTTON_WIDTH + 6
local RANK_WIDTH = 50
local PRIMARY_WIDTH, SECONDARY_WIDTH = 255, 120
local HEADER_HEIGHT = 18
local COLUMNS = 3 -- the most columns: one per secondary profession

local function columnX(i, secondary)
	return COLUMNS_X + (i - 1) * (secondary and SECONDARY_WIDTH or PRIMARY_WIDTH)
end

local function refresh()
	local s = MembersView.Settings()
	local players = s.view == "players"
	ui.secondaryColumns = MembersView.SecondaryColumns()
	-- The header (column titles, primary/secondary switch) only in the players view.
	ui.header:SetShown(players)
	ui.toggle:SetText(s.secondary and L.SHOW_PRIMARY or L.SHOW_SECONDARY)
	for i, title in ipairs(ui.columnTitles) do
		title:ClearAllPoints()
		title:SetPoint("LEFT", columnX(i, s.secondary), 0)
		local sl = ui.secondaryColumns[i]
		title:SetText(s.secondary and (sl and Index.SkillLineName(sl) or "") or (i == 1 and L.PROFS_PRIMARY or ""))
	end
	ui.list.box:ClearAllPoints()
	ui.list.box:SetPoint("TOPLEFT", 4, players and -(28 + HEADER_HEIGHT + 2) or -28)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)
	local rows, statsText = MembersView.Rows(s.view, s.reachable, s.open, searchText)
	ui.stats:SetText(statsText)
	ui.list:SetData(rows)
end

-- A member row's profession columns; without data the columns are cleared.
local function showColumns(row, data)
	local secondary = data ~= nil and MembersView.Settings().secondary
	local width = secondary and SECONDARY_WIDTH or PRIMARY_WIDTH
	for i = 1, COLUMNS do
		local col, cell = row.cols[i], nil
		if data and secondary then
			cell = data.cells.secondary[ui.secondaryColumns[i]]
		elseif data and i <= 2 then
			cell = data.cells.primary[i]
		end
		col.rank:ClearAllPoints()
		col.rank:SetPoint("LEFT", row, "LEFT", columnX(i, secondary), 0)
		col.name:SetWidth(width - RANK_WIDTH - 10)
		col.rank:SetText(cell and cell.rank or "")
		col.name:SetText(cell and (secondary and cell.mark or cell.name .. cell.mark) or "")
	end
end

function MembersView.Toggle(key)
	local s = MembersView.Settings()
	s.open[key] = not s.open[key] or nil
	if ui.list then refresh() end
end

local function build(content)
	-- Top left the search box; top right the view dropdown, and the
	-- reachable filter left of it. The stats line takes what is left and is
	-- cut off rather than overlapping (German labels are longer).
	local search = CreateFrame("EditBox", nil, content, "SearchBoxTemplate")
	search:SetSize(180, 20)
	search:SetPoint("TOPLEFT", 6, -2)
	search.Instructions:SetText(L.MEMBERS_SEARCH_HINT)
	ns.Skin.EditBox(search)
	-- Every change counts, including the box's clear button (not user input).
	search:HookScript("OnTextChanged", function(self)
		if self:GetText() == searchText then return end
		searchText = self:GetText()
		ns.Debounce("membersSearch", 0.2, function() refresh() end)
	end)
	ui.search = search

	ui.view = W.CreateDropdown(content, 140, function()
		local entries = {}
		for _, v in ipairs(MembersView.VIEWS) do entries[#entries + 1] = { v, L[VIEW_LABELS[v]] } end
		return entries
	end, function() return MembersView.Settings().view end, function(value)
		MembersView.Settings().view = value
		refresh()
	end)
	ui.view:SetPoint("TOPRIGHT", -4, 0)
	ui.reachable = W.CreateCheck(content, L.MEMBERS_REACHABLE, function() return MembersView.Settings().reachable end,
		function(value)
			MembersView.Settings().reachable = value
			refresh()
		end)
	-- Laid out from the dropdown leftwards: label, then the box left of it,
	-- so any label length (and font) fits without measuring it.
	local reachableLabel = ui.reachable.label
	reachableLabel:ClearAllPoints()
	reachableLabel:SetPoint("RIGHT", ui.view, "LEFT", -12, 0)
	ui.reachable:SetPoint("RIGHT", reachableLabel, "LEFT", -4, 0)
	ui.stats = W.Text(content, "GameFontDisableSmall")
	ui.stats:SetPoint("LEFT", search, "RIGHT", 12, 0)
	ui.stats:SetPoint("RIGHT", ui.reachable, "LEFT", -8, 0)

	-- Players view: column titles above the list; the button switches the
	-- columns between primary and secondary professions (remembered).
	ui.header = CreateFrame("Frame", nil, content)
	ui.header:SetPoint("TOPLEFT", 4, -28)
	ui.header:SetPoint("TOPRIGHT", -18, -28)
	ui.header:SetHeight(HEADER_HEIGHT)
	local function title(x, width)
		local fs = W.Text(ui.header, "GameFontNormalSmall")
		fs:SetPoint("LEFT", x, 0)
		if width then fs:SetWidth(width) end
		return fs
	end
	title(4, NAME_WIDTH):SetText(L.COL_CHARACTER)
	title(4 + NAME_WIDTH + 4, AGE_WIDTH + 4):SetText(L.COL_CONFIRMED)
	ui.columnTitles = {}
	for i = 1, COLUMNS do ui.columnTitles[i] = title(columnX(i, false)) end
	ui.toggle = CreateFrame("Button", nil, ui.header, "UIPanelButtonTemplate")
	ui.toggle:SetSize(150, HEADER_HEIGHT)
	ui.toggle:SetPoint("RIGHT")
	ns.Skin.Button(ui.toggle)
	ui.toggle:SetScript("OnClick", function()
		local s = MembersView.Settings()
		s.secondary = not s.secondary
		refresh()
	end)

	-- Right-click menu: invite, reagents by mail (cooldown rows), account
	-- linking (Features/Link.lua). Returns the entries for a row:
	-- { {label, fn, disabled}, ... }.
	local function menuItems(data)
		local items = {}
		if not data.guid then return items end
		-- The online character (or the same player's online one); never yourself or your alts.
		local inviteTarget = Index.ContactFor(data)
		if inviteTarget then
			items[#items + 1] = { L.MENU_INVITE, function() W.InviteToParty(inviteTarget) end }
		end
		for _, rid in ipairs(data.recipes or { data.recipeID }) do
			local item = Index.IsRecipe(rid) and ns.Mail.MenuItem(data, rid, 1)
			if item then
				-- Several recipes in one row: say which one the mail is for.
				if data.recipes then item[1] = (Index.RecipeName(rid) or ("#" .. rid)) .. ": " .. item[1] end
				items[#items + 1] = item
			end
		end
		if ns.Link.TargetOf(data.guid) then
			if ns.Link.OfferPendingFor(data.guid) then
				items[#items + 1] = { L.LINK_MENU_CANCEL, ns.Link.CancelOffer }
			else
				items[#items + 1] = { L.LINK_MENU_OFFER, function() ns.Link.ConfirmOffer(data.guid) end }
			end
		end
		if (data.isSelf or data.isAlt) and ns.Link.IsLinked() then
			items[#items + 1] = { L.LINK_MENU_UNLINK, ns.Link.ConfirmUnlink }
		end
		return items
	end
	ui.menuItems = menuItems

	local function openMenu(owner, data)
		W.OpenMenu(owner, Util.ShortName(data.name), menuItems(data))
	end

	-- Click hint, plus the member's addon version when known.
	local function hint(frame, text)
		frame:SetScript("OnEnter", function(self)
			local row = self.data and self or self:GetParent()
			local data = row.data
			local tip = data and text(self)
			if not tip then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(tip, 1, 1, 1)
			if data.kind == "member" then
				if data.ver > 0 then
					GameTooltip:AddLine(L.CONFIRMED_AGO:format(Util.FormatAge(ns.Now() - data.ver)), 0.6, 0.6, 0.6)
				end
				for _, line in ipairs(data.details or {}) do
					GameTooltip:AddLine(line, 1, 1, 1)
				end
			end
			if data.linked then
				GameTooltip:AddLine(L.LINKED_LICENSE, 0.4, 0.8, 1)
			end
			if data.kind == "member" or data.kind == "entry" then
				local version = ns.Versions.Describe(ns.Versions.Get(data.name))
				if version then
					GameTooltip:AddLine(L.VERSION_TOOLTIP:format(version), 0.6, 0.6, 0.6)
				end
			end
			if #menuItems(data) > 0 then
				GameTooltip:AddLine(L.RIGHT_CLICK_OPTIONS, 0.6, 0.6, 0.6)
			end
			GameTooltip:Show()
		end)
		frame:SetScript("OnLeave", GameTooltip_Hide)
	end

	-- What a click on the rest of the row does, per row kind.
	local function openRow(data)
		if data.kind == "group" then
			MembersView.Toggle(data.key)
		elseif data.kind == "scan" then
			MembersView.OpenProfession(data.skillLine)
		elseif data.kind == "entry" and data.recipeID then
			-- An item cooldown (Salt Shaker) has no recipe to open.
			if Index.IsRecipe(data.recipeID) then ns.UI.ShowRecipe(data.recipeID) end
		elseif (data.kind == "entry" or data.kind == "member") and data.ver > 0 then
			ns.UI.ShowCrafter(data.guid, data.skillLine)
		end
	end

	-- Two click areas: the name whispers (the character, or the same person's
	-- online character; never yourself or someone offline), the rest opens
	-- the member's recipes (or the cooldown recipe) in the Recipes tab. On a
	-- group header, both toggle the group.
	ui.list = W.CreateList(content, 20, function(row)
		row.nameButton = CreateFrame("Button", nil, row)
		row.nameButton:SetPoint("TOPLEFT")
		row.nameButton:SetPoint("BOTTOMLEFT")
		row.nameButton:SetWidth(GROUP_BUTTON_WIDTH)
		row.nameButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.nameButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row.nameButton:SetScript("OnClick", function(self, button)
			local data = self:GetParent().data
			if button == "RightButton" then
				openMenu(self, data)
				return
			end
			if data.kind == "group" then
				MembersView.Toggle(data.key)
				return
			elseif data.kind == "scan" then
				MembersView.OpenProfession(data.skillLine)
				return
			end
			local target = data.guid and Index.ContactFor(data)
			if target then
				W.SendTell(target)
			end
		end)
		hint(row.nameButton, function(self)
			local data = self:GetParent().data
			if data.kind == "group" then return L.CLICK_TOGGLE end
			if data.kind == "scan" then return L.CLICK_SCAN end
			if data.kind == "info" then return nil end
			local target, reason = Index.ContactFor(data)
			if not target then return reason end
			return data.via and L.CLICK_WHISPER_VIA:format(Util.ShortName(data.via.name)) or L.CLICK_WHISPER
		end)
		row.name = W.Text(row.nameButton)
		row.name:SetWidth(NAME_WIDTH)
		row.age = W.Text(row.nameButton, "GameFontDisableSmall")
		row.age:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.age:SetWidth(90)
		row.profs = W.Text(row)
		row.profs:SetPoint("LEFT", row.nameButton, "RIGHT", 4, 0)
		row.profs:SetPoint("RIGHT", -4, 0)
		-- Players view: the profession columns (see showColumns).
		row.cols = {}
		for i = 1, COLUMNS do
			local col = { rank = W.Text(row), name = W.Text(row) }
			col.rank:SetWidth(RANK_WIDTH)
			col.name:SetPoint("LEFT", col.rank, "RIGHT", 4, 0)
			row.cols[i] = col
		end
		row:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				openMenu(self, self.data)
				return
			end
			openRow(self.data)
		end)
		hint(row, function(self)
			local data = self.data
			if data.kind == "group" then return L.CLICK_TOGGLE end
			if data.kind == "scan" then return L.CLICK_SCAN end
			if data.kind == "info" then return nil end
			if data.recipeID then return Index.IsRecipe(data.recipeID) and L.CLICK_OPEN_RECIPE or nil end
			return data.ver > 0 and L.CLICK_SHOW_RECIPES or L.NO_ADDON_DATA
		end)
	end, function(row, data)
		row.data = data
		row.name:ClearAllPoints()
		local member = data.kind == "member"
		row.nameButton:SetWidth(member and MEMBER_BUTTON_WIDTH or GROUP_BUTTON_WIDTH)
		row.age:SetWidth(member and AGE_WIDTH or 90)
		showColumns(row, member and data or nil)
		if data.kind == "group" or data.kind == "info" or data.kind == "scan" then
			local label = data.kind == "group" and ((data.open and ICON_OPEN or ICON_CLOSED) .. data.label) or data.text
			if data.dim then label = "|cffa0a0a0" .. label .. "|r" end
			row.name:SetPoint("LEFT", 4, 0)
			row.name:SetWidth(data.kind == "group" and 244 or 600)
			row.name:SetText(label)
			row.age:SetText("")
			row.profs:SetText(data.summary or "")
			return
		end
		local name = Util.ClassColored(Util.ShortName(data.name), data.class)
		if data.kind == "entry" and data.via then
			-- In a group the person's online character is not nearby.
			name = name .. " (" .. Util.ClassColored(Util.ShortName(data.via.name), data.via.class) .. " |cff20ff20*|r)"
		elseif data.online and not (data.kind == "entry" and data.isSelf) then
			name = name .. " |cff20ff20*|r"
		end
		if data.kind == "entry" and data.isSelf then name = name .. " |cff999999(" .. L.YOU .. ")|r" end
		if data.linked then name = name .. " |cff66ccff~|r" end
		-- Other characters of the same person (players view) and the
		-- characters of a group sit indented.
		row.name:SetPoint("LEFT", data.alt and 18 or 4, 0)
		row.name:SetWidth(data.alt and NAME_WIDTH - 14 or NAME_WIDTH)
		row.name:SetText(name)
		if data.kind == "entry" then
			row.age:SetText(data.right or "")
			row.profs:SetText(data.extra or "")
		else
			-- Only the age here; "confirmed ... ago" is in the tooltip.
			row.age:SetText(data.ver > 0 and Util.FormatAge(ns.Now() - data.ver) or "")
			row.profs:SetText("")
		end
	end)
	ui.list.box:SetPoint("TOPLEFT", 4, -28)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)
end

ns.UI.RegisterTab("members", L.TAB_MEMBERS, build, refresh)
