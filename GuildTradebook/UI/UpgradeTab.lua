local _, ns = ...

local L, W, U, Index = ns.L, ns.Widgets, ns.Upgrades, ns.Index
local ui = {}

local SLOT_NAMES = {
	[1] = "HEADSLOT", [2] = "NECKSLOT", [3] = "SHOULDERSLOT", [4] = "SHIRTSLOT", [5] = "CHESTSLOT",
	[6] = "WAISTSLOT", [7] = "LEGSSLOT", [8] = "FEETSLOT", [9] = "WRISTSLOT", [10] = "HANDSSLOT",
	[11] = "FINGER0SLOT", [12] = "FINGER1SLOT", [13] = "TRINKET0SLOT", [14] = "TRINKET1SLOT",
	[15] = "BACKSLOT", [16] = "MAINHANDSLOT", [17] = "SECONDARYHANDSLOT", [18] = "RANGEDSLOT", [19] = "TABARDSLOT",
}

local DEFAULT_STATS = {
	WARRIOR = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_STAMINA_SHORT" },
	PALADIN = { "ITEM_MOD_STRENGTH_SHORT", "ITEM_MOD_STAMINA_SHORT" },
	ROGUE = { "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STAMINA_SHORT" },
	HUNTER = { "ITEM_MOD_AGILITY_SHORT", "ITEM_MOD_STAMINA_SHORT" },
	DRUID = { "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_STAMINA_SHORT" },
	SHAMAN = { "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_STAMINA_SHORT" },
	PRIEST = { "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_SPIRIT_SHORT" },
	MAGE = { "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_STAMINA_SHORT" },
	WARLOCK = { "ITEM_MOD_INTELLECT_SHORT", "ITEM_MOD_STAMINA_SHORT" },
}

local function settings()
	local s = ns.charDB.upgrades
	if not s then
		local _, classFile = UnitClass("player")
		local fav = {}
		for _, key in ipairs(DEFAULT_STATS[classFile] or { "ITEM_MOD_STAMINA_SHORT" }) do
			fav[key] = true
		end
		s = {
			itemType = U.BestArmorType(classFile, UnitLevel("player")),
			slot = 0, fav = fav, showBoP = false, showAll = false, levelAhead = 0,
		}
		ns.charDB.upgrades = s
	end
	return s
end

local function statName(key)
	return _G[key] or key
end

local function slotName(slot)
	return _G[SLOT_NAMES[slot]] or ("#" .. slot)
end

local function itemTypeName(key)
	if key == "ANY" then return L.ANY end
	if key == "WEAPON" then return L.WEAPON_ANY end
	local sub = tonumber(key:match("^ARMOR:(%d+)$"))
	if sub == 0 then return L.MISC_ARMOR end
	local getSubClass = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
	return (getSubClass and getSubClass(4, sub)) or key
end

local function favList()
	local list = {}
	for _, key in ipairs(U.STATS) do
		if settings().fav[key] then list[#list + 1] = key end
	end
	return list
end

local function crafterSummary(itemID)
	local names, seen = {}, {}
	for _, rid in ipairs(Index.RecipesForItem(itemID) or {}) do
		for _, c in ipairs(Index.Crafters(rid)) do
			if not seen[c.guid] then
				seen[c.guid] = true
				names[#names + 1] = W.CrafterShort(c, true)
			end
		end
	end
	if #names > 3 then
		return table.concat(names, ", ", 1, 3) .. " " .. L.TOOLTIP_MORE:format(#names - 3)
	end
	return table.concat(names, ", ")
end

local function refresh()
	local s = settings()
	for _, control in ipairs(ui.controls) do
		if control.GenerateMenu then control:GenerateMenu() end
		if control.UpdateSummary then control:UpdateSummary() end
		if control.Refresh then control:Refresh() end
	end
	local fav = favList()
	if #fav == 0 then
		ui.status:SetText(L.NO_FAV_STATS)
		ui.list:SetData({})
		return
	end
	local results, pending = U.Find({
		itemType = s.itemType, slot = s.slot, favStats = fav,
		level = UnitLevel("player"), levelAhead = s.levelAhead,
		showBoP = s.showBoP, showAll = s.showAll,
	}, U.GameAPI())
	ui.list:SetData(results)
	if pending > 0 then
		ui.status:SetText(L.PENDING_ITEMS:format(pending))
	elseif #results == 0 then
		ui.status:SetText(L.NO_RESULTS)
	else
		ui.status:SetText("")
	end
end

local function update(fn)
	return function(v)
		fn(settings(), v)
		refresh()
	end
end

local function build(content)
	ui.controls = {}

	local typeLabel = W.Text(content, "GameFontNormalSmall")
	typeLabel:SetPoint("TOPLEFT", 6, 0)
	typeLabel:SetText(L.ITEM_TYPE)
	local itemType = W.CreateDropdown(content, 200, function()
		local entries = {}
		for _, key in ipairs(U.ITEM_TYPES) do entries[#entries + 1] = { key, itemTypeName(key) } end
		return entries
	end, function() return settings().itemType end, update(function(s, v) s.itemType = v end))
	itemType:SetPoint("TOPLEFT", typeLabel, "BOTTOMLEFT", 0, -2)

	local slotLabel = W.Text(content, "GameFontNormalSmall")
	slotLabel:SetPoint("LEFT", typeLabel, "LEFT", 214, 0)
	slotLabel:SetText(L.SLOT)
	local slot = W.CreateDropdown(content, 150, function()
		local entries = { { 0, L.ALL_SLOTS } }
		for _, id in ipairs(U.SLOT_ORDER) do entries[#entries + 1] = { id, slotName(id) } end
		return entries
	end, function() return settings().slot end, update(function(s, v) s.slot = v end))
	slot:SetPoint("TOPLEFT", slotLabel, "BOTTOMLEFT", 0, -2)

	local statLabel = W.Text(content, "GameFontNormalSmall")
	statLabel:SetPoint("LEFT", slotLabel, "LEFT", 164, 0)
	statLabel:SetText(L.FAV_STATS)
	local stats = W.CreateMultiDropdown(content, 220, function()
		local entries = {}
		for _, key in ipairs(U.STATS) do entries[#entries + 1] = { key, statName(key) } end
		return entries
	end, function(key) return settings().fav[key] end, function(key)
		local s = settings()
		s.fav[key] = not s.fav[key] or nil
		refresh()
	end, function()
		local names = {}
		for _, key in ipairs(favList()) do names[#names + 1] = statName(key) end
		return #names > 0 and table.concat(names, ", ") or "-"
	end)
	stats:SetPoint("TOPLEFT", statLabel, "BOTTOMLEFT", 0, -2)

	local bop = W.CreateCheck(content, L.SHOW_BOP, function() return settings().showBoP end,
		update(function(s, v) s.showBoP = v end))
	bop:SetPoint("TOPLEFT", itemType, "BOTTOMLEFT", -4, -4)
	local all = W.CreateCheck(content, L.SHOW_ALL, function() return settings().showAll end,
		update(function(s, v) s.showAll = v end))
	all:SetPoint("LEFT", bop.label, "RIGHT", 12, 0)
	local ahead = W.CreateDropdown(content, 220, function()
		local entries = {}
		for _, n in ipairs({ 0, 2, 5, 10 }) do entries[#entries + 1] = { n, L.LEVEL_AHEAD:format(n) } end
		return entries
	end, function() return settings().levelAhead end, update(function(s, v) s.levelAhead = v end))
	ahead:SetPoint("LEFT", all.label, "RIGHT", 12, 0)

	ui.controls = { itemType, slot, stats, bop, all, ahead }

	ui.status = W.Text(content, "GameFontDisable")
	ui.status:SetPoint("TOPLEFT", bop, "BOTTOMLEFT", 4, -6)

	ui.list = W.CreateList(content, 24, function(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(20, 20)
		row.icon:SetPoint("LEFT", 2, 0)
		row.name = W.Text(row, "GameFontHighlight")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
		row.name:SetWidth(230)
		row.delta = W.Text(row, "GameFontHighlightSmall")
		row.delta:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
		row.delta:SetWidth(140)
		row.crafters = W.Text(row)
		row.crafters:SetPoint("LEFT", row.delta, "RIGHT", 6, 0)
		row.crafters:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(self.data.info.link)
			if self.data.bop then
				GameTooltip:AddLine(L.BOP_WARNING, 1, 0.3, 0.3, true)
			end
			GameTooltip:AddLine(L.UPGRADE_HINT, 0.6, 0.6, 0.6, true)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
		row:SetScript("OnClick", function(self, button)
			local rids = Index.RecipesForItem(self.data.itemID)
			if not (rids and rids[1]) then return end
			if button == "RightButton" then
				ns.Wishlist.Toggle(rids[1])
			else
				ns.UI.ShowRecipe(rids[1])
			end
		end)
	end, function(row, data)
		row.data = data
		row.icon:SetTexture(data.info.icon)
		local rids = Index.RecipesForItem(data.itemID)
		local wished = rids and rids[1] and ns.Wishlist.Has(rids[1])
		row.name:SetText(wished and (W.WISH_MARK .. " " .. data.info.link) or data.info.link)
		local color = data.delta > 0 and "|cff20ff20+" or (data.delta < 0 and "|cffff4040" or "|cffcccccc")
		local text = color .. data.delta .. "|r"
		if data.ilvlDelta ~= 0 then
			text = text .. (" |cff999999(ilvl %+d)|r"):format(data.ilvlDelta)
		end
		if not data.equippedLink then
			text = text .. " |cff999999" .. L.EQUIPPED_EMPTY .. "|r"
		end
		if data.bop then
			text = text .. " |cffff4040BoP|r"
		end
		row.delta:SetText(text)
		row.crafters:SetText(crafterSummary(data.itemID))
	end)
	ui.list.box:SetPoint("TOPLEFT", ui.status, "BOTTOMLEFT", -4, -6)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)
end

ns.UI.RegisterTab("upgrades", L.TAB_UPGRADES, build, refresh)

local function refreshIfVisible()
	if ui.list and ui.list.box:IsVisible() then
		ns.Debounce("upgradeRefresh", 0.5, refresh)
	end
end
ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", refreshIfVisible)
ns.RegisterEvent("PLAYER_EQUIPMENT_CHANGED", refreshIfVisible)
