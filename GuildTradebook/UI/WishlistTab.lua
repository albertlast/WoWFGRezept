local _, ns = ...

local L, W = ns.L, ns.Widgets
local ui = {}

local function crafterSummary(crafters)
	local names = {}
	for i, c in ipairs(crafters) do
		if i > 4 then
			names[#names + 1] = L.TOOLTIP_MORE:format(#crafters - 4)
			break
		end
		names[#names + 1] = W.CrafterShort(c, true)
	end
	return #names > 0 and table.concat(names, ", ") or ("|cff999999" .. L.WISH_NO_CRAFTER .. "|r")
end

local function refresh()
	local entries = ns.Wishlist.Entries()
	ui.list:SetData(entries)
	ui.empty:SetShown(#entries == 0)
	-- Looking at the list: the crafters online now are no news (minimap glow).
	ns.Wishlist.MarkSeen()
end

-- Pause/resume and remove buttons of a row: small versions of the window's
-- red panel buttons (like the tabs).
local BUTTON_WIDTH, BUTTON_HEIGHT = 74, 18

local function rowButton(row, onClick, tooltip)
	local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	b:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
	b:SetNormalFontObject("GameFontNormalSmall")
	b:SetHighlightFontObject("GameFontHighlightSmall")
	b:SetDisabledFontObject("GameFontDisableSmall")
	b:SetScript("OnClick", function(self) onClick(self:GetParent().data) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(tooltip(self:GetParent().data))
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	return b
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
		row.pause = rowButton(row, function(data) ns.Wishlist.SetPaused(data.recipeID, not data.paused) end,
			function(data) return data.paused and L.WISH_RESUME or L.WISH_PAUSE end)
		row.pause:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
		row.remove = rowButton(row, function(data) ns.Wishlist.Toggle(data.recipeID) end,
			function() return L.WISH_REMOVE end)
		row.remove:SetText(L.WISH_REMOVE_SHORT)
		row.remove:SetPoint("LEFT", row.pause, "RIGHT", 2, 0)
		row.crafters = W.Text(row)
		row.crafters:SetPoint("LEFT", row.remove, "RIGHT", 10, 0)
		row.crafters:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self)
			ns.UI.ShowRecipe(self.data.recipeID)
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
		row.icon:SetDesaturated(data.paused)
		row.icon:SetAlpha(data.paused and 0.5 or 1)
		row.pause:SetText(data.paused and L.WISH_RESUME_SHORT or L.WISH_PAUSE_SHORT)
		if data.paused then
			row.name:SetText("|cff808080" .. data.name .. "|r")
			row.crafters:SetText("|cff808080" .. L.WISH_PAUSED .. "|r")
		else
			row.name:SetText(data.name)
			row.crafters:SetText(crafterSummary(data.crafters))
		end
	end)
	ui.list.box:SetPoint("TOPLEFT", 4, -22)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)

	ui.empty = W.Text(content, "GameFontDisable")
	ui.empty:SetPoint("TOP", ui.list.box, "TOP", 0, -20)
	ui.empty:SetText(L.WISH_EMPTY)
end

ns.UI.RegisterTab("wishlist", L.TAB_WISHLIST, build, refresh)
