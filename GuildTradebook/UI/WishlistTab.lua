local _, ns = ...

local L, W, Util = ns.L, ns.Widgets, ns.Util
local ui = {}

local function crafterSummary(crafters)
	local names = {}
	for i, c in ipairs(crafters) do
		if i > 4 then
			names[#names + 1] = L.TOOLTIP_MORE:format(#crafters - 4)
			break
		end
		local name = Util.ClassColored(Util.ShortName(c.name), c.class)
		if c.online and not c.isSelf then name = name .. "|cff20ff20*|r" end
		names[#names + 1] = name
	end
	return #names > 0 and table.concat(names, ", ") or ("|cff999999" .. L.WISH_NO_CRAFTER .. "|r")
end

local function refresh()
	local entries = ns.Wishlist.Entries()
	ui.list:SetData(entries)
	ui.empty:SetShown(#entries == 0)
end

local function build(content)
	local hint = W.Text(content, "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", 6, -2)
	hint:SetText(L.WISH_HINT)

	ui.list = W.CreateList(content, 22, function(row)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 2, 0)
		row.name = W.Text(row, "GameFontHighlight")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
		row.name:SetWidth(240)
		row.crafters = W.Text(row)
		row.crafters:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
		row.crafters:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				ns.Wishlist.Toggle(self.data.recipeID)
			else
				ns.UI.ShowRecipe(self.data.recipeID)
			end
		end)
		row:SetScript("OnEnter", function(self)
			if self.data.itemID > 0 then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetItemByID(self.data.itemID)
				GameTooltip:Show()
			end
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
	end, function(row, data)
		row.data = data
		local icon = data.itemID > 0 and C_Item.GetItemIconByID(data.itemID) or nil
		row.icon:SetTexture(icon or 134939)
		row.name:SetText(data.name)
		row.crafters:SetText(crafterSummary(data.crafters))
	end)
	ui.list.box:SetPoint("TOPLEFT", 4, -22)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)

	ui.empty = W.Text(content, "GameFontDisable")
	ui.empty:SetPoint("TOP", ui.list.box, "TOP", 0, -20)
	ui.empty:SetText(L.WISH_EMPTY)
end

ns.UI.RegisterTab("wishlist", L.TAB_WISHLIST, build, refresh)
