local _, ns = ...

local L, W, Index = ns.L, ns.Widgets, ns.Index
local state = { text = "", skillLine = 0, selected = nil }
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

local function refreshDetail()
	local d = ui.detail
	local rid = state.selected
	if not rid then
		d.title:SetText("")
		d.item:SetText("")
		d.reagents:SetText("")
		ui.crafters:SetData({})
		return
	end
	local itemID = Index.OutputItem(rid)
	d.title:SetText(Index.RecipeName(rid) or ("#" .. rid))
	d.item.itemID = itemID
	d.item:SetText(itemID > 0 and itemLabel(itemID, "#" .. itemID) or "")

	local reagents = reagentsFor(rid)
	if reagents then
		local lines = { L.REAGENTS .. ":" }
		for _, r in ipairs(reagents) do
			local line = r[2] .. "x " .. itemLabel(r[1], "#" .. r[1])
			if r[3] == 1 then line = line .. " |cff999999(" .. L.OPTIONAL .. ")|r" end
			lines[#lines + 1] = line
		end
		d.reagents:SetText(table.concat(lines, "\n"))
	else
		d.reagents:SetText(L.REAGENTS_LOADING)
	end
	ui.crafters:SetData(Index.Crafters(rid))
end

local function refresh(_, arg)
	if arg then
		state.text = arg
		ui.search:SetText(arg)
	end
	local results = Index.Search(state.text, state.skillLine)
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
	search:HookScript("OnTextChanged", function(self, userInput)
		if not userInput then return end
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
		row:SetScript("OnClick", function(self)
			state.selected = self.data.recipeID
			refreshDetail()
		end)
	end, function(row, data)
		row.data = data
		local icon = data.itemID > 0 and C_Item.GetItemIconByID(data.itemID) or nil
		row.icon:SetTexture(icon or 134939)
		row.text:SetText(data.name)
		row.count:SetText(data.count)
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

	detail.title = W.Text(detail, "GameFontNormalLarge")
	detail.title:SetPoint("TOPLEFT", 0, 0)
	detail.title:SetPoint("RIGHT", 0, 0)

	-- Output item with tooltip.
	local item = CreateFrame("Button", nil, detail)
	item:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -6)
	item:SetSize(360, 16)
	item.fs = W.Text(item)
	item.fs:SetAllPoints()
	item.SetText = function(self, text) self.fs:SetText(text) end
	item:SetScript("OnEnter", function(self)
		if self.itemID and self.itemID > 0 then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.itemID)
			GameTooltip:Show()
		end
	end)
	item:SetScript("OnLeave", GameTooltip_Hide)
	detail.item = item

	detail.reagents = detail:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	detail.reagents:SetJustifyH("LEFT")
	detail.reagents:SetJustifyV("TOP")
	detail.reagents:SetPoint("TOPLEFT", item, "BOTTOMLEFT", 0, -10)
	detail.reagents:SetPoint("RIGHT", 0, 0)
	detail.reagents:SetHeight(110)

	local header = W.Text(detail, "GameFontNormal")
	header:SetPoint("TOPLEFT", detail.reagents, "BOTTOMLEFT", 0, -8)
	header:SetText(L.CRAFTERS .. " |cff999999(" .. L.WHISPER .. ": click)|r")

	ui.crafters = W.CreateList(detail, 18, function(row)
		row.text = W.Text(row)
		row.text:SetPoint("LEFT", 4, 0)
		row.text:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self)
			if not self.data.isSelf then
				W.SendTell(self.data.name)
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

-- Item names arrive asynchronously.
ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
	if ui.detail and ui.detail:IsVisible() then
		ns.Debounce("searchItemInfo", 0.3, refreshDetail)
	end
end)

-- Lets other tabs jump to a recipe.
function ns.UI.ShowRecipe(recipeID)
	state.selected = recipeID
	state.text = Index.RecipeName(recipeID) or ""
	ns.UI.Show("search", state.text)
end
