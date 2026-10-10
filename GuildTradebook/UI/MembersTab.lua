--[[
Members tab, three views (dropdown at the top right, remembered per
character in ns.charDB.members):
  players      one group per person: the online or highest character first,
               the other characters indented below
  professions  one collapsible group per profession, members by skill level
  cooldowns    one collapsible group per cooldown recipe, ready and
               reachable crafters first
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
local MAX_READY_NAMES = 3
local ICON_OPEN = "|TInterface\\Buttons\\UI-MinusButton-Up:14:14|t "
local ICON_CLOSED = "|TInterface\\Buttons\\UI-PlusButton-Up:14:14|t "

-- { view, reachable, open = { [group key] = true } }
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

-- Primary professions first; secondary ones (Cooking, First Aid, ...) dimmed.
local function professionText(rec)
	local parts = {}
	local skillLines = Util.SortedKeys(rec.profs)
	Index.SortSkillLines(skillLines, function(sl) return rec.profs[sl].primary end)
	for _, sl in ipairs(skillLines) do
		local p = rec.profs[sl]
		local text = ("%s %d/%d"):format(Index.SkillLineName(sl), p.rank, p.maxRank)
		if not p.recipes then
			text = text .. " |cffff8000(" .. L.NOT_SCANNED .. ")|r"
		else
			text = text .. " |cff999999(" .. Util.Count(p.recipes) .. ")|r"
			if p.unverified then
				text = text .. " |cffff8000" .. L.UNVERIFIED .. "|r"
			end
		end
		if p.cds and next(p.cds) then
			local now, cds = ns.Now(), {}
			for _, rid in ipairs(Util.SortedKeys(p.cds)) do
				local readyAt = p.cds[rid]
				local state = Store.IsHiddenCooldown(readyAt) and ("|cff808080" .. L.CD_NOT_SHARED .. "|r")
					or readyAt <= now and ("|cff20ff20" .. L.CD_READY .. "|r")
					or ("|cffff8000" .. Util.FormatAge(readyAt - now) .. "|r")
				cds[#cds + 1] = (Index.RecipeName(rid) or ("#" .. rid)) .. " " .. state
			end
			text = text .. " [" .. table.concat(cds, ", ") .. "]"
		end
		if Roster.IsProfessionContradicted(rec.guid, sl) then
			text = "|cff808080" .. text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. " (server: -)|r"
		elseif not p.primary then
			text = "|cffa0a0a0" .. text:gsub("|r", "|cffa0a0a0") .. "|r"
		end
		parts[#parts + 1] = text
	end
	return table.concat(parts, ", ")
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
			for _, p in pairs(rec.profs) do
				recipes = recipes + (p.recipes and Util.Count(p.recipes) or 0)
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
			for sl in pairs(rec.profs) do profNames[#profNames + 1] = Index.SkillLineName(sl) end
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
				profs = professionText(rec),
				searchText = table.concat(profNames, " "),
			}
		end
	end
	-- Members the server lists with professions but who share no data.
	for guid, member in pairs(Roster.members) do
		local server = Roster.ServerProfessions(guid)
		if not seen[guid] and server then
			local names = {}
			for sl in pairs(server) do names[#names + 1] = Index.SkillLineName(sl) end
			table.sort(names)
			rows[#rows + 1] = {
				kind = "member",
				guid = guid, name = member.name, class = member.class, level = member.level or 0,
				online = member.online or false, ver = 0,
				profs = "|cff808080" .. table.concat(names, ", ") .. " (" .. L.NO_ADDON_DATA .. ")|r",
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
		if needle ~= "" and not matches(g.header.label, needle) then
			entries = {}
			for _, e in ipairs(g.entries) do
				if matches(e.name, needle) then entries[#entries + 1] = e end
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
				if not Roster.IsProfessionContradicted(guid, sl) then
					local e = entry(guid, rec)
					if e.reachable or not reachableOnly then
						e.skillLine, e.rank = sl, p.rank
						e.right = ("%d/%d"):format(p.rank, p.maxRank)
						e.extra = p.recipes and ("|cff999999" .. L.MEMBERS_RECIPES:format(Util.Count(p.recipes)) .. "|r")
							or ("|cffff8000" .. L.NOT_SCANNED .. "|r")
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
	local byRecipe = {}
	for guid, rec in pairs(gd.chars) do
		if Store.IsShareable(rec, isMember) then
			for _, p in pairs(rec.profs) do
				for rid, readyAt in pairs(p.cds or {}) do
					local e = entry(guid, rec)
					if e.reachable or not reachableOnly then
						e.recipeID, e.readyAt, e.ready = rid, readyAt, readyAt <= now
						e.hidden = Store.IsHiddenCooldown(readyAt)
						e.right = e.hidden and ("|cff808080" .. L.CD_NOT_SHARED .. "|r")
							or e.ready and ("|cff20ff20" .. L.CD_READY .. "|r")
							or ("|cffff8000" .. Util.FormatAge(readyAt - now) .. "|r")
						byRecipe[rid] = byRecipe[rid] or { entries = {} }
						table.insert(byRecipe[rid].entries, e)
					end
				end
			end
		end
	end
	local groups = {}
	for rid, g in pairs(byRecipe) do
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
			kind = "group", key = "c:" .. rid, label = Index.RecipeName(rid) or ("#" .. rid),
			summary = summary, recipeID = rid,
		}
		groups[#groups + 1] = g
	end
	table.sort(groups, function(a, b)
		if a.readyReachable ~= b.readyReachable then return a.readyReachable end
		if a.soonest ~= b.soonest then return a.soonest < b.soonest end
		return a.header.label < b.header.label
	end)
	return flatten(groups, open, needle)
end

--[[
Rows for one view: { kind = "member" | "group" | "entry" | "info", ... }
  group:  key, label, summary, open, dim?
  entry:  guid, name, class, online, via, reachable, isSelf, isAlt, right, extra,
          skillLine (professions) or recipeID (cooldowns)
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
	return rows, L.MEMBERS_STATS:format(stats(gd))
end

local searchText = ""

local function refresh()
	local s = MembersView.Settings()
	local rows, statsText = MembersView.Rows(s.view, s.reachable, s.open, searchText)
	ui.stats:SetText(statsText)
	ui.list:SetData(rows)
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
	local labelWidth = tonumber(ui.reachable.label.GetStringWidth and ui.reachable.label:GetStringWidth()) or 120
	ui.reachable:SetPoint("RIGHT", ui.view, "LEFT", -(labelWidth + 12), 0)
	ui.stats = W.Text(content, "GameFontDisableSmall")
	ui.stats:SetPoint("LEFT", search, "RIGHT", 12, 0)
	ui.stats:SetPoint("RIGHT", ui.reachable, "LEFT", -8, 0)

	-- Right-click menu: account linking (Features/Link.lua). Returns the
	-- entries for a row: { {label, fn}, ... }.
	local function menuItems(data)
		local items = {}
		if not data.guid then return items end
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
		local items = menuItems(data)
		if #items == 0 or not (MenuUtil and MenuUtil.CreateContextMenu) then return end
		MenuUtil.CreateContextMenu(owner, function(_, root)
			root:CreateTitle(Util.ShortName(data.name))
			for _, item in ipairs(items) do
				root:CreateButton(item[1], item[2])
			end
		end)
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
		elseif data.kind == "entry" and data.recipeID then
			ns.UI.ShowRecipe(data.recipeID)
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
		row.nameButton:SetWidth(248)
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
			end
			local target = data.guid and Index.ContactFor(data)
			if target then
				W.SendTell(target)
			end
		end)
		hint(row.nameButton, function(self)
			local data = self:GetParent().data
			if data.kind == "group" then return L.CLICK_TOGGLE end
			if data.kind == "info" then return nil end
			local target, reason = Index.ContactFor(data)
			if not target then return reason end
			return data.via and L.CLICK_WHISPER_VIA:format(Util.ShortName(data.via.name)) or L.CLICK_WHISPER
		end)
		row.name = W.Text(row.nameButton)
		row.name:SetWidth(150)
		row.age = W.Text(row.nameButton, "GameFontDisableSmall")
		row.age:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.age:SetWidth(90)
		row.profs = W.Text(row)
		row.profs:SetPoint("LEFT", row.nameButton, "RIGHT", 4, 0)
		row.profs:SetPoint("RIGHT", -4, 0)
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
			if data.kind == "info" then return nil end
			if data.recipeID then return L.CLICK_OPEN_RECIPE end
			return data.ver > 0 and L.CLICK_SHOW_RECIPES or L.NO_ADDON_DATA
		end)
	end, function(row, data)
		row.data = data
		row.name:ClearAllPoints()
		if data.kind == "group" or data.kind == "info" then
			local label = data.kind == "group" and ((data.open and ICON_OPEN or ICON_CLOSED) .. data.label) or data.text
			if data.dim then label = "|cffa0a0a0" .. label .. "|r" end
			row.name:SetPoint("LEFT", 4, 0)
			row.name:SetWidth(data.kind == "info" and 600 or 244)
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
		row.name:SetWidth(data.alt and 136 or 150)
		row.name:SetText(name)
		if data.kind == "entry" then
			row.age:SetText(data.right or "")
			row.profs:SetText(data.extra or "")
		else
			row.age:SetText(data.ver > 0 and L.CONFIRMED_AGO:format(Util.FormatAge(ns.Now() - data.ver)) or "")
			row.profs:SetText(data.profs)
		end
	end)
	ui.list.box:SetPoint("TOPLEFT", 4, -28)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)
end

ns.UI.RegisterTab("members", L.TAB_MEMBERS, build, refresh)
