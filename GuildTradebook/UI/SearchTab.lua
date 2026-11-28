local _, ns = ...

local L, W, Index, Util, Categories, Unknown = ns.L, ns.Widgets, ns.Index, ns.Util, ns.Categories, ns.Unknown
-- history: recipes visited by clicking a reagent, for the Back button.
-- crafter: GUID of a member whose recipes are shown (from the Members tab).
-- searchClosed: groups closed by hand during the current search.
-- unknown: the list shows the recipes nobody in the guild knows (Unknown).
local state = { text = "", skillLine = 0, selected = nil, crafts = 1, history = {}, crafter = nil, searchClosed = {},
	unknown = false }
local MAX_HISTORY = 20
local MAX_CRAFTS = 50
local MAX_REAGENT_ROWS = 8
local REAGENT_ROW_HEIGHT = 14
local PRICE_LINES = 2 -- cost and auction house value, with Auctionator
local INDENT = 14
local ICON_OPEN = "Interface\\Buttons\\UI-MinusButton-Up"
local ICON_CLOSED = "Interface\\Buttons\\UI-PlusButton-Up"
local ui = {}

--[[
The recipe list in collapsible groups, like the profession window:
  all professions   profession > category > recipes
  one profession    category > recipes
Recipes without a (named) category go to "Other" at the end; when that is
the only group of a profession (data from 0.1.0 clients), the recipes
follow the profession directly. Open groups are remembered per character;
while searching every group is open (unless closed by hand).
]]
local RecipeList = {}
ns.RecipeList = RecipeList
local OTHER = 0

function RecipeList.Open()
	local s = ns.charDB.recipes
	if type(s) ~= "table" then
		s = {}
		ns.charDB.recipes = s
	end
	if type(s.open) ~= "table" then s.open = {} end
	return s.open
end

local function categoryOf(recipeID)
	local id = Categories.Of(recipeID)
	return (id and Categories.Name(id)) and id or OTHER
end

local function categoryLabel(id)
	return id ~= OTHER and Categories.Name(id) or L.CATEGORY_OTHER
end

-- Group keys of a recipe: { profession key, category key }.
function RecipeList.KeysFor(recipeID, skillLine)
	return { "p:" .. skillLine, "c:" .. skillLine .. ":" .. categoryOf(recipeID) }
end

-- Like the profession window: the recipe that turns grey last first;
-- recipes whose grey skill is unknown (crafters with older versions) follow
-- by name.
local function byTrivial(a, b)
	local fa, fb = ns.db.recipeFacts[a.recipeID], ns.db.recipeFacts[b.recipeID]
	local ta, tb = fa and fa.trivial or 0, fb and fb.trivial or 0
	if ta ~= tb then return ta > tb end
	if a.name ~= b.name then return a.name < b.name end
	return a.recipeID < b.recipeID
end

--[[
Rows: { kind = "group", key, label, count, open, level, profession? } and the
search results ({recipeID, ...}) with level set.
isOpen(key) -> bool. bySkillOrder: recipes in profession window order, else
in the order of results (by name, used while searching).
]]
function RecipeList.Rows(results, allProfessions, isOpen, bySkillOrder)
	local bySkill = {}
	for _, r in ipairs(results) do
		local sl = r.skillLine or 0
		local id = categoryOf(r.recipeID)
		bySkill[sl] = bySkill[sl] or {}
		bySkill[sl][id] = bySkill[sl][id] or {}
		table.insert(bySkill[sl][id], r)
	end
	if bySkillOrder then
		for _, cats in pairs(bySkill) do
			for _, list in pairs(cats) do table.sort(list, byTrivial) end
		end
	end
	local skills = Util.SortedKeys(bySkill)
	Index.SortSkillLines(skills, function(sl) return Index.primarySkill[sl] end)
	local rows = {}
	local function add(list, level)
		for _, r in ipairs(list) do
			r.level = level
			rows[#rows + 1] = r
		end
	end
	for _, sl in ipairs(skills) do
		local cats = bySkill[sl]
		local level, shown = 0, true
		if allProfessions then
			local key, count = "p:" .. sl, 0
			for _, list in pairs(cats) do count = count + #list end
			shown = isOpen(key)
			rows[#rows + 1] = { kind = "group", key = key, label = Index.SkillLineName(sl), count = count,
				open = shown, level = 0, profession = true }
			level = 1
		end
		if shown then
			local ids = Util.SortedKeys(cats)
			if #ids == 1 and ids[1] == OTHER then
				add(cats[OTHER], level)
			else
				Categories.SortGroups(ids)
				for _, id in ipairs(ids) do
					local key = "c:" .. sl .. ":" .. id
					local open = isOpen(key)
					rows[#rows + 1] = { kind = "group", key = key, label = categoryLabel(id), count = #cats[id],
						open = open, level = level }
					if open then add(cats[id], level + 1) end
				end
			end
		end
	end
	return rows
end

local function searching()
	return state.text:match("%S") ~= nil
end

local function isOpen(key)
	if searching() then return not state.searchClosed[key] end
	return RecipeList.Open()[key] == true
end

local function toggle(key)
	if searching() then
		state.searchClosed[key] = not state.searchClosed[key] or nil
	else
		local open = RecipeList.Open()
		open[key] = not open[key] or nil
	end
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
-- recipe (Back returns). With Auctionator the price of the needed amount
-- stands on the right.
local function reagentRow(index)
	local d = ui.detail
	local row = d.reagentRows[index]
	if not row then
		row = CreateFrame("Button", nil, d.reagentArea)
		row:SetHeight(REAGENT_ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 0, -(index - 1) * REAGENT_ROW_HEIGHT)
		row:SetPoint("RIGHT", 0, 0)
		row.price = W.Text(row, nil, "RIGHT")
		row.price:SetPoint("TOPRIGHT")
		row.price:SetPoint("BOTTOMRIGHT")
		row.fs = W.Text(row)
		row.fs:SetPoint("TOPLEFT")
		row.fs:SetPoint("BOTTOMRIGHT", row.price, "BOTTOMLEFT", -6, 0)
		W.AttachItem(row, function(recipeID) ns.UI.ShowRecipe(recipeID, true) end)
		d.reagentRows[index] = row
	end
	return row
end

local function itemName(itemID)
	local name = C_Item.GetItemInfo(itemID)
	if not name then C_Item.RequestLoadItemDataByID(itemID) end
	return name
end

-- Two lines under the reagents (only with Auctionator): the cost of the
-- crafts and the auction house price of the crafted item. While the auction
-- house is open, a button on their right lets Auctionator search the
-- reagents.
local function refreshCost(rid, reagents, rows)
	local d = ui.detail
	local priced = reagents ~= nil and ns.Prices.Available()
	d.reagentArea:SetHeight((MAX_REAGENT_ROWS + (priced and PRICE_LINES or 0)) * REAGENT_ROW_HEIGHT)
	d.cost:SetShown(priced)
	d.value:SetShown(priced)
	local terms = priced and ns.Prices.CanSearch() and ns.Prices.SearchTerms(rows, ns.Prices.Unit, itemName) or {}
	d.ahSearch.terms = terms
	d.ahSearch:SetShown(#terms > 0)
	if not priced then return end
	local top = -math.min(#rows, MAX_REAGENT_ROWS) * REAGENT_ROW_HEIGHT - 2
	d.ahSearch:SetPoint("TOPRIGHT", d.reagentArea, "TOPRIGHT", 0, top)
	d.cost:ClearAllPoints()
	d.cost:SetPoint("TOPLEFT", d.reagentArea, "TOPLEFT", 0, top)
	if #terms > 0 then
		d.cost:SetPoint("TOPRIGHT", d.ahSearch, "TOPLEFT", -6, 0)
	else
		d.cost:SetPoint("TOPRIGHT", d.reagentArea, "TOPRIGHT", 0, top)
	end
	local cost, unpriced = ns.Prices.Cost(reagents, state.crafts, ns.Prices.Unit)
	if unpriced > 0 and cost == 0 then
		d.cost:SetText("|cff999999" .. L.PRICE_NONE .. "|r")
	else
		local text = L.PRICE_COST:format("|cffffffff" .. ns.Prices.Format(cost) .. "|r")
		if unpriced > 0 then
			text = text .. "  |cffff4040(" .. L.PRICE_UNPRICED:format(unpriced) .. ")|r"
		end
		d.cost:SetText(text)
	end
	local itemID = Index.OutputItem(rid)
	local value = itemID > 0 and ns.Prices.Auction(itemID)
	d.value:SetText(value and L.PRICE_AUCTION:format("|cffffffff" .. ns.Prices.Format(value) .. "|r") or "")
end

local function refreshReagents(rid)
	local d = ui.detail
	-- Nobody in the guild could answer for an unknown recipe.
	local unknown = rid and Unknown.Is(rid)
	local reagents = rid and ns.Reagents.ForRecipe(rid, unknown)
	local rows = {}
	if not rid then
		d.reagents:SetText("")
	elseif not reagents then
		d.reagents:SetText(unknown and L.REAGENTS_UNKNOWN or L.REAGENTS_LOADING)
	else
		d.reagents:SetText(L.REAGENTS_FOR:format(state.crafts))
		rows = ns.Reagents.Check(reagents, state.crafts, ns.Reagents.Count)
	end
	local priced = ns.Prices.Available()
	refreshCost(rid, reagents, rows)
	for i = 1, math.max(#rows, #d.reagentRows) do
		local data = rows[i]
		if data and i <= MAX_REAGENT_ROWS then
			local row = reagentRow(i)
			local unit = priced and ns.Prices.Unit(data.itemID)
			if unit then
				local price = ns.Prices.Format(unit * data.need)
				row.price:SetText(data.optional and ("|cff999999" .. price .. "|r") or price)
			else
				row.price:SetText(priced and "|cff999999?|r" or "")
			end
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

-- The list under the reagents: who crafts the recipe, or one line saying
-- nobody in the guild knows it.
local function refreshCrafters(rid)
	if rid and Unknown.Is(rid) then
		ui.crafters:SetData({ { text = "|cff999999" .. L.UNKNOWN_NOBODY .. "|r" } })
		return
	end
	ui.crafters:SetData(rid and Index.Crafters(rid) or {})
end

local function refreshDetail()
	local d = ui.detail
	local rid = state.selected
	-- A wish waits for a crafter; an unknown recipe has none.
	d.wish:SetShown(rid ~= nil and not Unknown.Is(rid))
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
		refreshCrafters(nil)
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
	refreshCrafters(rid)
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
	local results
	if state.unknown then
		results = Unknown.Search(state.text, state.skillLine)
	else
		results = Index.Search(state.text, state.skillLine, state.crafter, ns.db.options.hideForeignBoP)
	end
	if state.crafter then
		local c = Index.CrafterInfo(state.crafter)
		ui.crafterLabel:SetText(L.FILTER_CRAFTER:format(Util.ClassColored(Util.ShortName(c.name), c.class)))
	end
	ui.crafterLabel:SetShown(state.crafter ~= nil)
	ui.crafterClear:SetShown(state.crafter ~= nil)
	ui.results:SetData(RecipeList.Rows(results, state.skillLine == 0, isOpen, not searching()))
	ui.unknown:Refresh()
	-- Professions whose recipe list has not arrived yet (Catalog).
	local missing = {}
	if state.unknown then
		for _, sl in ipairs(ns.Catalog.Missing()) do
			if state.skillLine == 0 or sl == state.skillLine then missing[#missing + 1] = sl end
		end
	end
	ui.missing.skillLines = missing
	ui.missing.fs:SetText(L.UNKNOWN_MISSING:format(#missing))
	ui.missing:SetShown(#missing > 0)
	-- Categories are asked for the guild's recipes only.
	for _, r in ipairs(state.unknown and {} or results) do
		if not Categories.Of(r.recipeID) then
			Categories.Shown()
			break
		end
	end
	ui.empty:SetText(#missing > 0 and L.UNKNOWN_WAITING or L.NO_RESULTS)
	ui.empty:SetShown(#results == 0)
	ui.profession:GenerateMenu()
	refreshDetail()
end

-- The "Unknown in guild" switch: starts from a plain list (no crafter
-- filter, nothing selected); a profession filter stays if the new list has
-- that profession.
local function setUnknown(on)
	state.unknown = on
	state.crafter = nil
	state.selected = nil
	state.history = {}
	state.searchClosed = {}
	local skills = on and Unknown.SkillLines() or Index.SkillLines()
	if state.skillLine ~= 0 and not Util.Contains(skills, state.skillLine) then
		state.skillLine = 0
	end
	refresh()
end

local function build(content)
	local search = CreateFrame("EditBox", nil, content, "SearchBoxTemplate")
	search:SetSize(220, 20)
	search:SetPoint("TOPLEFT", 6, -2)
	search.Instructions:SetText(L.SEARCH_HINT)
	ns.Skin.EditBox(search)
	-- Every change counts, including the box's clear button (not user input).
	search:HookScript("OnTextChanged", function(self)
		if self:GetText() == state.text then return end
		state.text = self:GetText()
		state.searchClosed = {}
		ns.Debounce("searchInput", 0.2, function() refresh() end)
	end)
	ui.search = search

	ui.profession = W.CreateDropdown(content, 180, function()
		local entries = { { 0, L.ALL_PROFESSIONS } }
		for _, sl in ipairs(state.unknown and Unknown.SkillLines() or Index.SkillLines()) do
			entries[#entries + 1] = { sl, Index.SkillLineName(sl) }
		end
		return entries
	end, function() return state.skillLine end, function(v)
		state.skillLine = v
		refresh()
	end)
	ui.profession:SetPoint("LEFT", search, "RIGHT", 12, 0)

	-- Switch: the recipes nobody in the guild knows instead of the guild's.
	ui.unknown = W.CreateCheck(content, L.UNKNOWN_TOGGLE, function() return state.unknown end, setUnknown)
	ui.unknown:SetPoint("LEFT", ui.profession, "RIGHT", 10, 0)
	ui.unknown:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L.UNKNOWN_TOGGLE)
		GameTooltip:AddLine(L.UNKNOWN_TOGGLE_HINT, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	ui.unknown:SetScript("OnLeave", GameTooltip_Hide)

	-- With the switch on: how many professions still lack their recipe list
	-- (asked from guild members), the names in the tooltip.
	ui.missing = CreateFrame("Button", nil, content)
	ui.missing:SetSize(110, 20)
	ui.missing:SetPoint("LEFT", ui.unknown.label, "RIGHT", 12, 0)
	ui.missing.fs = W.Text(ui.missing, "GameFontDisableSmall")
	ui.missing.fs:SetAllPoints()
	ui.missing:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L.UNKNOWN_MISSING:format(#(self.skillLines or {})))
		for _, sl in ipairs(self.skillLines or {}) do
			GameTooltip:AddLine(Index.SkillLineName(sl), 1, 1, 1)
		end
		GameTooltip:AddLine(L.UNKNOWN_MISSING_HINT, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	ui.missing:SetScript("OnLeave", GameTooltip_Hide)
	ui.missing:Hide()

	-- Crafter filter, set from the Members tab; the button removes it.
	ui.crafterLabel = W.Text(content, "GameFontHighlightSmall")
	ui.crafterLabel:SetPoint("LEFT", ui.unknown.label, "RIGHT", 12, 0)
	ui.crafterClear = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	ui.crafterClear:SetSize(22, 20)
	ui.crafterClear:SetText("x")
	ui.crafterClear:SetPoint("LEFT", ui.crafterLabel, "RIGHT", 4, 0)
	ns.Skin.Button(ui.crafterClear)
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
			if self.data.kind == "group" then
				toggle(self.data.key)
				refresh()
				return
			end
			state.history = {}
			selectRecipe(self.data.recipeID)
			refresh()
		end)
	end, function(row, data)
		row.data = data
		row.icon:ClearAllPoints()
		row.icon:SetPoint("LEFT", 2 + (data.level or 0) * INDENT, 0)
		if data.kind == "group" then
			row.icon:SetTexture(data.open and ICON_OPEN or ICON_CLOSED)
			row.text:SetText(data.profession and ("|cffffd100" .. data.label .. "|r") or data.label)
			row.count:SetText("|cff999999" .. data.count .. "|r")
			row.selected:Hide()
			return
		end
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

	ui.empty = W.EmptyText(content, ui.results.box, L.NO_RESULTS)

	-- Detail (right)
	local detail = CreateFrame("Frame", nil, content)
	detail:SetPoint("TOPLEFT", ui.results.box, "TOPRIGHT", 24, 0)
	detail:SetPoint("BOTTOMRIGHT", -4, 4)
	ui.detail = detail

	local wish = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
	wish:SetSize(150, 22)
	wish:SetPoint("TOPRIGHT", 0, 2)
	ns.Skin.Button(wish)
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
	ns.Skin.Button(back)
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
	detail.reagentArea:SetPoint("TOPLEFT", detail.reagents, "BOTTOMLEFT", 0, -9) -- below the +/- buttons
	detail.reagentArea:SetPoint("RIGHT", 0, 0)
	detail.reagentArea:SetHeight(MAX_REAGENT_ROWS * REAGENT_ROW_HEIGHT)
	detail.reagentRows = {}
	-- Cost lines right under the last reagent (see refreshCost).
	detail.cost = W.Text(detail.reagentArea)
	detail.cost:SetPoint("TOPLEFT")
	detail.cost:SetPoint("TOPRIGHT")
	detail.value = W.Text(detail.reagentArea)
	detail.value:SetPoint("TOPLEFT", detail.cost, "BOTTOMLEFT", 0, -2)
	detail.value:SetPoint("TOPRIGHT", detail.cost, "BOTTOMRIGHT", 0, -2)
	detail.cost:Hide()
	detail.value:Hide()
	-- Auction house search with Auctionator (see refreshCost).
	local ahSearch = CreateFrame("Button", nil, detail.reagentArea, "UIPanelButtonTemplate")
	ahSearch:SetSize(110, 22)
	ahSearch:SetText(L.AH_SEARCH)
	ns.Skin.Button(ahSearch)
	ahSearch:SetScript("OnClick", function(self)
		if not ns.Prices.Search(self.terms or {}) then
			ns.Print(L.AH_SEARCH_FAILED)
		end
	end)
	ahSearch:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L.AH_SEARCH)
		GameTooltip:AddLine(L.AH_SEARCH_HINT, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	ahSearch:SetScript("OnLeave", GameTooltip_Hide)
	ahSearch:Hide()
	detail.ahSearch = ahSearch

	-- Number of crafts for the reagent check.
	local function stepper(label, delta)
		local b = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
		b:SetSize(22, 18)
		b:SetText(label)
		ns.Skin.Button(b)
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
	header:SetPoint("RIGHT", -4, 0)
	header:SetText(L.CRAFTERS .. " |cff999999(" .. L.CRAFTERS_HINT .. ")|r")

	-- Right-click on a crafter: whisper, invite, reagents by mail (for the
	-- number of crafts set above).
	local function crafterMenu(owner, c)
		local items = W.ContactItems(c)
		items[#items + 1] = ns.Mail.MenuItem(c, state.selected, state.crafts)
		W.OpenMenu(owner, Util.ShortName(c.name), items)
	end

	ui.crafters = W.CreateList(detail, 18, function(row)
		row.text = W.Text(row)
		row.text:SetPoint("LEFT", 4, 0)
		row.text:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self, button)
			if self.data.text then return end -- "nobody knows it"
			if button == "RightButton" then
				crafterMenu(self, self.data)
				return
			end
			local target = Index.ContactFor(self.data)
			if target then
				W.SendTell(target)
			end
		end)
	end, function(row, data)
		row.data = data
		row.text:SetText(data.text or W.CrafterLabel(data))
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
-- The auction house search button.
ns.RegisterEvent("AUCTION_HOUSE_SHOW", refreshDetailIfVisible)
ns.RegisterEvent("AUCTION_HOUSE_CLOSED", refreshDetailIfVisible)

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
	-- detail panel shows the opened recipe even if the list does not. Its
	-- groups open.
	selectRecipe(recipeID)
	Index.Ensure()
	local skillLine = Index.recipeSkill[recipeID]
	if skillLine then
		local open = RecipeList.Open()
		for _, key in ipairs(RecipeList.KeysFor(recipeID, skillLine)) do
			open[key] = true
			state.searchClosed[key] = nil
		end
	end
	ns.UI.Show("search")
end

-- Shows all recipes of one member (Members tab). Clears the search and sets
-- the profession filter to skillLine (nil: all professions).
function ns.UI.ShowCrafter(guid, skillLine)
	state.crafter = guid
	state.unknown = false
	state.text = ""
	state.skillLine = skillLine or 0
	state.selected = nil
	state.history = {}
	if ui.search then ui.search:SetText("") end
	ns.UI.Show("search")
end

-- For tests: the auction house search button of the recipe detail.
function ns.UI.RecipeSearchButton()
	return ui.detail.ahSearch
end

-- Opens the Recipes tab with the "Unknown in guild" switch on or off.
function ns.UI.ShowUnknownRecipes(on)
	ns.UI.Show("search")
	setUnknown(on and true or false)
end

-- For tests: how many recipes Back can return through.
function ns.UI.RecipeHistoryDepth()
	return #state.history
end
