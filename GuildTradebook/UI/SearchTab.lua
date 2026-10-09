local _, ns = ...

local L, W, Index, Util = ns.L, ns.Widgets, ns.Index, ns.Util
-- history: recipes visited by clicking a reagent, for the Back button.
-- crafter: GUID of a member whose recipes are shown (from the Members tab).
local state = { text = "", skillLine = 0, selected = nil, crafts = 1, history = {}, crafter = nil }
local MAX_HISTORY = 20
local MAX_CRAFTS = 50
local MAX_REAGENT_ROWS = 8
local REAGENT_ROW_HEIGHT = 14
local ui = {}

-- Reagents: local client first, then the guild (FACT_REQ). See Protocol.
local function reagentsFor(recipeID)
	local fact = ns.db.recipeFacts[recipeID]
	if fact and fact.reagents then
		return fact.reagents
	end
	local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if ok and schematic and schematic.reagentSlotSchematics and #schematic.reagentSlotSchematics > 0 then
		ns.Scanner.ResolveFact(recipeID, nil)
		fact = ns.db.recipeFacts[recipeID]
		if fact and fact.reagents and #fact.reagents > 0 then
			return fact.reagents
		end
	end
	ns.Protocol.RequestFacts({ recipeID })
	return nil
end

local function itemLabel(itemID, fallback)
	if itemID and itemID > 0 then
		local _, link = C_Item.GetItemInfo(itemID)
		if link then return link end
		C_Item.RequestLoadItemDataByID(itemID)
	end
	return fallback
end

-- One hoverable row per reagent: have/need (green = enough, red = short)
-- and the item, with the game's item tooltip and shift-click linking. If a
-- guild member can craft the reagent, it is marked and a click opens that
-- recipe (Back returns).
local function reagentRow(index)
	local d = ui.detail
	local row = d.reagentRows[index]
	if not row then
		row = CreateFrame("Button", nil, d.reagentArea)
		row:SetHeight(REAGENT_ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 0, -(index - 1) * REAGENT_ROW_HEIGHT)
		row:SetPoint("RIGHT", 0, 0)
		row.fs = W.Text(row)
		row.fs:SetAllPoints()
		W.AttachItem(row, function(recipeID) ns.UI.ShowRecipe(recipeID, true) end)
		d.reagentRows[index] = row
	end
	return row
end

local function refreshReagents(rid)
	local d = ui.detail
	local reagents = rid and reagentsFor(rid)
	local rows = {}
	if not rid then
		d.reagents:SetText("")
	elseif not reagents then
		d.reagents:SetText(L.REAGENTS_LOADING)
	else
		d.reagents:SetText(L.REAGENTS_FOR:format(state.crafts))
		rows = ns.Reagents.Check(reagents, state.crafts, ns.Reagents.Count)
	end
	for i = 1, math.max(#rows, #d.reagentRows) do
		local data = rows[i]
		if data and i <= MAX_REAGENT_ROWS then
			local row = reagentRow(i)
			local color = data.optional and "|cff999999" or (data.have >= data.need and "|cff20ff20" or "|cffff4040")
			local text = ("%s%d/%d|r  %s"):format(color, data.have, data.need, itemLabel(data.itemID, "#" .. data.itemID))
			if data.optional then
				text = text .. " |cff999999(" .. L.OPTIONAL .. ")|r"
			end
			if W.GuildRecipeFor(data.itemID) then
				text = text .. "  |cff66ccff»|r"
			end
			row.itemID = data.itemID
			row.fs:SetText(text)
			row:Show()
		elseif d.reagentRows[i] then
			d.reagentRows[i]:Hide()
		end
	end
end

local function refreshDetail()
	local d = ui.detail
	local rid = state.selected
	d.wish:SetShown(rid ~= nil)
	d.back:SetShown(#state.history > 0)
	-- The header uses the Back button's space while it is hidden.
	d.item:SetPoint("RIGHT", d.back:IsShown() and d.back or d.wish, "LEFT", -6, 0)
	d.minus:SetShown(rid ~= nil)
	d.plus:SetShown(rid ~= nil)
	refreshReagents(rid)
	if not rid then
		d.item.itemID, d.item.spellID = nil, nil
		d.item:SetText("")
		d.item.icon:Hide()
		ui.crafters:SetData({})
		return
	end
	-- Header: the crafted item (icon + link). Recipes without an item
	-- (enchants) show the recipe's own icon and name instead.
	local itemID = Index.OutputItem(rid)
	local icon
	if itemID > 0 then
		d.item.itemID, d.item.spellID = itemID, nil
		d.item:SetText(itemLabel(itemID, Index.RecipeName(rid) or ("#" .. itemID)))
		icon = C_Item.GetItemIconByID(itemID)
	else
		d.item.itemID, d.item.spellID = nil, rid
		d.item:SetText("|cffffd100" .. (Index.RecipeName(rid) or ("#" .. rid)) .. "|r")
		icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(rid)
	end
	d.item.icon:SetTexture(icon or nil)
	d.item.icon:SetShown(icon ~= nil and icon ~= false)
	d.wish:SetText(ns.Wishlist.Has(rid) and L.WISH_REMOVE or L.WISH_ADD)
	ui.crafters:SetData(Index.Crafters(rid))
end

local function selectRecipe(recipeID)
	if state.selected ~= recipeID then
		state.crafts = 1
	end
	state.selected = recipeID
end

local function refresh(_, arg)
	if arg then
		state.text = arg
		ui.search:SetText(arg)
	end
	local results = Index.Search(state.text, state.skillLine, state.crafter, ns.db.options.hideForeignBoP)
	if state.crafter then
		local c = Index.CrafterInfo(state.crafter)
		ui.crafterLabel:SetText(L.FILTER_CRAFTER:format(Util.ClassColored(Util.ShortName(c.name), c.class)))
	end
	ui.crafterLabel:SetShown(state.crafter ~= nil)
	ui.crafterClear:SetShown(state.crafter ~= nil)
	ui.results:SetData(results)
	ui.empty:SetShown(#results == 0)
	ui.profession:GenerateMenu()
	refreshDetail()
end

local function build(content)
	local search = CreateFrame("EditBox", nil, content, "SearchBoxTemplate")
	search:SetSize(220, 20)
	search:SetPoint("TOPLEFT", 6, -2)
	search.Instructions:SetText(L.SEARCH_HINT)
	-- Every change counts, including the box's clear button (not user input).
	search:HookScript("OnTextChanged", function(self)
		if self:GetText() == state.text then return end
		state.text = self:GetText()
		ns.Debounce("searchInput", 0.2, function() refresh() end)
	end)
	ui.search = search

	ui.profession = W.CreateDropdown(content, 180, function()
		local entries = { { 0, L.ALL_PROFESSIONS } }
		for _, sl in ipairs(Index.SkillLines()) do
			entries[#entries + 1] = { sl, Index.SkillLineName(sl) }
		end
		return entries
	end, function() return state.skillLine end, function(v)
		state.skillLine = v
		refresh()
	end)
	ui.profession:SetPoint("LEFT", search, "RIGHT", 12, 0)

	-- Crafter filter, set from the Members tab; the button removes it.
	ui.crafterLabel = W.Text(content, "GameFontHighlightSmall")
	ui.crafterLabel:SetPoint("LEFT", ui.profession, "RIGHT", 12, 0)
	ui.crafterClear = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	ui.crafterClear:SetSize(22, 20)
	ui.crafterClear:SetText("x")
	ui.crafterClear:SetPoint("LEFT", ui.crafterLabel, "RIGHT", 4, 0)
	ui.crafterClear:SetScript("OnClick", function()
		state.crafter = nil
		refresh()
	end)
	ui.crafterLabel:Hide()
	ui.crafterClear:Hide()

	-- Results (left)
	ui.results = W.CreateList(content, 20, function(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(16, 16)
		row.icon:SetPoint("LEFT", 2, 0)
		row.text = W.Text(row)
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
		row.text:SetPoint("RIGHT", -30, 0)
		row.count = W.Text(row, "GameFontDisableSmall", "RIGHT")
		row.count:SetPoint("RIGHT", -4, 0)
		row.selected = row:CreateTexture(nil, "BACKGROUND")
		row.selected:SetAllPoints()
		row.selected:SetColorTexture(1, 0.82, 0, 0.15)
		row:SetScript("OnClick", function(self)
			state.history = {}
			selectRecipe(self.data.recipeID)
			refresh()
		end)
	end, function(row, data)
		row.data = data
		local icon = data.itemID > 0 and C_Item.GetItemIconByID(data.itemID) or nil
		row.icon:SetTexture(icon or 134939)
		local name = data.name
		if ns.Wishlist.Has(data.recipeID) then
			name = W.WISH_MARK .. " " .. name
		end
		row.text:SetText(name)
		row.count:SetText(data.count)
		row.selected:SetShown(data.recipeID == state.selected)
	end)
	ui.results.box:SetPoint("TOPLEFT", 4, -32)
	ui.results.box:SetPoint("BOTTOMLEFT", 4, 4)
	ui.results.box:SetWidth(320)

	ui.empty = W.Text(content, "GameFontDisable")
	ui.empty:SetPoint("TOP", ui.results.box, "TOP", 0, -20)
	ui.empty:SetText(L.NO_RESULTS)

	-- Detail (right)
	local detail = CreateFrame("Frame", nil, content)
	detail:SetPoint("TOPLEFT", ui.results.box, "TOPRIGHT", 24, 0)
	detail:SetPoint("BOTTOMRIGHT", -4, 4)
	ui.detail = detail

	local wish = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
	wish:SetSize(150, 22)
	wish:SetPoint("TOPRIGHT", 0, 2)
	wish:SetScript("OnClick", function()
		if state.selected then
			ns.Wishlist.Toggle(state.selected)
			refreshDetail()
		end
	end)
	detail.wish = wish

	local back = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
	back:SetSize(70, 22)
	back:SetPoint("RIGHT", wish, "LEFT", -4, 0)
	back:SetText(L.BACK)
	back:SetScript("OnClick", function()
		local previous = table.remove(state.history)
		if previous then
			ns.UI.ShowRecipe(previous, nil, true)
		end
	end)
	back:Hide()
	detail.back = back

	-- Header line: icon + crafted item (or recipe), with tooltip and
	-- shift-click link. Its right edge follows the buttons (refreshDetail).
	local item = CreateFrame("Button", nil, detail)
	item:SetPoint("TOPLEFT", 0, 0)
	item:SetPoint("RIGHT", wish, "LEFT", -6, 0)
	item:SetHeight(24)
	item.icon = item:CreateTexture(nil, "ARTWORK")
	item.icon:SetSize(24, 24)
	item.icon:SetPoint("LEFT")
	item.fs = W.Text(item, "GameFontNormalLarge")
	item.fs:SetPoint("LEFT", item.icon, "RIGHT", 5, 0)
	item.fs:SetPoint("RIGHT")
	item.SetText = function(self, text) self.fs:SetText(text) end
	W.AttachItem(item)
	detail.item = item

	-- Reagent header line, then one row per reagent (see refreshReagents).
	detail.reagents = W.Text(detail, "GameFontHighlightSmall")
	detail.reagents:SetPoint("TOPLEFT", item, "BOTTOMLEFT", 0, -10)
	detail.reagents:SetPoint("RIGHT", -52, 0)
	detail.reagentArea = CreateFrame("Frame", nil, detail)
	detail.reagentArea:SetPoint("TOPLEFT", detail.reagents, "BOTTOMLEFT", 0, -4)
	detail.reagentArea:SetPoint("RIGHT", 0, 0)
	detail.reagentArea:SetHeight(MAX_REAGENT_ROWS * REAGENT_ROW_HEIGHT)
	detail.reagentRows = {}

	-- Number of crafts for the reagent check.
	local function stepper(label, delta)
		local b = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
		b:SetSize(22, 18)
		b:SetText(label)
		b:SetScript("OnClick", function()
			state.crafts = math.max(1, math.min(MAX_CRAFTS, state.crafts + delta))
			refreshDetail()
		end)
		return b
	end
	detail.plus = stepper("+", 1)
	-- The header line ends 52 px before the right edge; the buttons sit there.
	detail.plus:SetPoint("TOPRIGHT", detail.reagents, "TOPRIGHT", 52, 2)
	detail.minus = stepper("-", -1)
	detail.minus:SetPoint("RIGHT", detail.plus, "LEFT", -2, 0)

	local header = W.Text(detail, "GameFontNormal")
	header:SetPoint("TOPLEFT", detail.reagentArea, "BOTTOMLEFT", 0, -8)
	header:SetText(L.CRAFTERS .. " |cff999999(" .. L.WHISPER .. ": click)|r")

	ui.crafters = W.CreateList(detail, 18, function(row)
		row.text = W.Text(row)
		row.text:SetPoint("LEFT", 4, 0)
		row.text:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self)
			if not self.data.isSelf then
				W.SendTell(Index.ContactName(self.data))
			end
		end)
	end, function(row, data)
		row.data = data
		row.text:SetText(W.CrafterLabel(data))
	end)
	ui.crafters.box:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	ui.crafters.box:SetPoint("BOTTOMRIGHT", -16, 0)
end

ns.UI.RegisterTab("search", L.TAB_SEARCH, build, refresh)

-- Item names arrive asynchronously; bag contents change.
local function refreshDetailIfVisible()
	if ui.detail and ui.detail:IsVisible() then
		ns.Debounce("searchItemInfo", 0.3, refreshDetail)
	end
end
-- Item data arriving can also change the list (bind-on-pickup filter).
ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
	if ui.detail and ui.detail:IsVisible() then
		ns.Debounce("searchItemInfo", 0.3, refresh)
	end
end)
ns.RegisterEvent("BAG_UPDATE_DELAYED", refreshDetailIfVisible)

-- Opens a recipe. fromCurrent: opened from the current recipe (reagent
-- click), so Back can return to it. keepHistory: used by Back itself. Any
-- other jump (from another tab) starts a new history.
function ns.UI.ShowRecipe(recipeID, fromCurrent, keepHistory)
	if fromCurrent then
		if state.selected and state.selected ~= recipeID then
			table.insert(state.history, state.selected)
			if #state.history > MAX_HISTORY then table.remove(state.history, 1) end
		end
	elseif not keepHistory then
		state.history = {}
	end
	-- The search and profession filter stay as the player left them; the
	-- detail panel shows the opened recipe even if the list does not.
	selectRecipe(recipeID)
	ns.UI.Show("search")
end

-- Shows all recipes of one member (Members tab). Clears the search and the
-- profession filter so the member's whole list is visible.
function ns.UI.ShowCrafter(guid)
	state.crafter = guid
	state.text = ""
	state.skillLine = 0
	state.selected = nil
	state.history = {}
	if ui.search then ui.search:SetText("") end
	ns.UI.Show("search")
end

-- For tests: how many recipes Back can return through.
function ns.UI.RecipeHistoryDepth()
	return #state.history
end
