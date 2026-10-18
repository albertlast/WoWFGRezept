--[[
Settings sub-page "Tooltip filter": a tree of every profession in the guild
pool with its groups (the game's categories, "Bandages", "Cloaks", ...).
What is marked is left out of item tooltips ("Craftable by guild", "Known in
your guild"): for basics everyone can make (bandages, camp fires) the list
of crafters says nothing. A marked profession hides all its groups. The
marks are stored account-wide in ns.db.tooltipHidden (see Categories).

The tree is built when the page is shown, from the pool as it is then:
professions and categories appear as guild members share them.
]]
local _, ns = ...

local L, W, Index, Categories, Util = ns.L, ns.Widgets, ns.Index, ns.Categories, ns.Util
local FilterPage = { open = {} }   -- open: ["p:<skillLine>"] = true, this session
ns.FilterPage = FilterPage

local ROW_HEIGHT = 22
local INDENT = 22
local ICON_OPEN = "Interface\\Buttons\\UI-MinusButton-Up"
local ICON_CLOSED = "Interface\\Buttons\\UI-PlusButton-Up"
local GREY = "|cff808080"

local ui = {}

--[[
Rows of the tree (pure apart from the pool and the marks):
  { kind = "profession", key, label, count, hidden, open, groups, hiddenGroups, groupKeys }
  { kind = "group", key, label, count, hidden, locked }
hidden: marked, or (group) hidden by its profession; locked: can not be
changed because the profession is marked. Groups follow their open profession.
]]
function FilterPage.Rows()
	Index.Ensure()
	local bySkill = {}
	for rid in pairs(Index.byRecipe) do
		local sl = Index.recipeSkill[rid]
		if sl then
			local groups = bySkill[sl]
			if not groups then
				groups = {}
				bySkill[sl] = groups
			end
			local g = Categories.Group(rid)
			groups[g] = (groups[g] or 0) + 1
		end
	end
	local skills = Util.SortedKeys(bySkill)
	Index.SortSkillLines(skills, function(sl) return Index.primarySkill[sl] end)

	local rows = {}
	for _, sl in ipairs(skills) do
		local groups = bySkill[sl]
		local ids = Util.SortedKeys(groups)
		Categories.SortGroups(ids)
		local profKey = Categories.FilterKey("p", sl)
		local profHidden = Categories.IsKeyHidden(profKey)
		local total, hiddenGroups, children, groupKeys = 0, 0, {}, {}
		for _, g in ipairs(ids) do
			local key = g == Categories.OTHER and Categories.FilterKey("o", sl) or Categories.FilterKey("c", g)
			local own = Categories.IsKeyHidden(key)
			total = total + groups[g]
			groupKeys[#groupKeys + 1] = key
			if own then hiddenGroups = hiddenGroups + 1 end
			children[#children + 1] = { kind = "group", key = key, label = Categories.Label(g), count = groups[g],
				hidden = profHidden or own, locked = profHidden }
		end
		local open = FilterPage.open[profKey] == true
		rows[#rows + 1] = { kind = "profession", key = profKey, label = Index.SkillLineName(sl), count = total,
			hidden = profHidden, open = open, groups = #ids, hiddenGroups = hiddenGroups, groupKeys = groupKeys }
		if open then
			for _, child in ipairs(children) do rows[#rows + 1] = child end
		end
	end
	return rows
end

-- A click on a check mark. Marking or unmarking a profession also clears the
-- marks of its groups: unmarked means everything of it is shown again.
function FilterPage.SetHidden(data, hidden)
	if data.locked then return end
	if data.kind == "profession" then
		for _, key in ipairs(data.groupKeys) do Categories.SetKeyHidden(key, false) end
	end
	Categories.SetKeyHidden(data.key, hidden)
end

local function refresh()
	if not ui.list then return end
	local rows = FilterPage.Rows()
	ui.list:SetData(rows)
	ui.empty:SetShown(#rows == 0)
	-- Recipes without a (named) category are grouped as "Other" until the
	-- guild has told us: ask, like the Recipes tab.
	if next(Index.byRecipe) then
		for rid in pairs(Index.byRecipe) do
			if Categories.Group(rid) == Categories.OTHER then
				Categories.Shown()
				break
			end
		end
	end
end
FilterPage.Refresh = refresh

local function info(data)
	local text = L.FILTER_RECIPES:format(data.count)
	if data.kind == "profession" and not data.hidden and data.hiddenGroups > 0 then
		text = L.FILTER_GROUPS_HIDDEN:format(data.hiddenGroups, data.groups) .. " - " .. text
	end
	return text
end

local function build(frame)
	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(L.SETTINGS_FILTER)

	local hint = W.Text(frame, "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", 16, -44)
	hint:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	hint:SetHeight(40)
	hint:SetWordWrap(true)
	hint:SetJustifyV("TOP")
	hint:SetText(L.FILTER_HINT)

	local reset = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	reset:SetSize(150, 22)
	reset:SetPoint("TOPRIGHT", -16, -14)
	reset:SetText(L.FILTER_RESET)
	reset:SetScript("OnClick", function()
		for key in pairs(ns.db.tooltipHidden) do ns.db.tooltipHidden[key] = nil end
		refresh()
	end)

	ui.list = W.CreateList(frame, ROW_HEIGHT, function(row)
		row.expand = row:CreateTexture(nil, "ARTWORK")
		row.expand:SetSize(14, 14)
		row.check = W.CreateCheck(row, "", function() return row.data ~= nil and row.data.hidden end, function(on)
			if row.data then FilterPage.SetHidden(row.data, on) end
			refresh()
		end)
		row.check.label:SetText("")
		row.name = W.Text(row, "GameFontHighlight")
		row.info = W.Text(row, "GameFontDisableSmall", "RIGHT")
		row.info:SetPoint("RIGHT", -6, 0)
		row.name:SetPoint("RIGHT", row.info, "LEFT", -8, 0)
		row:SetScript("OnClick", function(self)
			local data = self.data
			if data and data.kind == "profession" then
				FilterPage.open[data.key] = not data.open or nil
				refresh()
			end
		end)
	end, function(row, data)
		row.data = data
		local isProfession = data.kind == "profession"
		local x = isProfession and 2 or 2 + INDENT
		row.expand:SetShown(isProfession)
		row.check:ClearAllPoints()
		if isProfession then
			row.expand:ClearAllPoints()
			row.expand:SetPoint("LEFT", x, 0)
			row.expand:SetTexture(data.open and ICON_OPEN or ICON_CLOSED)
			row.check:SetPoint("LEFT", x + 18, 0)
		else
			row.check:SetPoint("LEFT", x, 0)
		end
		row.check:SetChecked(data.hidden)
		row.check:SetEnabled(not data.locked)
		row.name:ClearAllPoints()
		row.name:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
		row.name:SetPoint("RIGHT", row.info, "LEFT", -8, 0)
		row.name:SetText((data.hidden and GREY or "") .. data.label .. (data.hidden and "|r" or ""))
		row.info:SetText(info(data))
	end)
	ui.list.box:SetPoint("TOPLEFT", 16, -92)
	ui.list.box:SetPoint("BOTTOMRIGHT", -36, 16)

	ui.empty = W.Text(frame, "GameFontDisable")
	ui.empty:SetPoint("TOP", ui.list.box, "TOP", 0, -20)
	ui.empty:SetText(L.FILTER_EMPTY)
end

-- A canvas sub-page below the addon's page (its content depends on the pool,
-- so it can not be a fixed list of settings).
function FilterPage.Register(category)
	if not (Settings and Settings.RegisterCanvasLayoutSubcategory) or FilterPage.frame then return end
	local frame = CreateFrame("Frame")
	frame.name = L.SETTINGS_FILTER
	build(frame)
	frame:SetScript("OnShow", refresh)
	FilterPage.frame = frame
	FilterPage.category = Settings.RegisterCanvasLayoutSubcategory(category, frame, L.SETTINGS_FILTER)
end
