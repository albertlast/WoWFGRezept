local _, ns = ...

local W = {}
ns.Widgets = W

-- Marks wishlist entries in lists: Blizzard's favorite star, or a text star.
W.WISH_MARK = (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("auctionhouse-icon-favorite")
	and CreateAtlasMarkup and CreateAtlasMarkup("auctionhouse-icon-favorite", 13, 13)) or "|cffffd100(W)|r"

-- Scrolling list. initRow(row, data) is called for every visible row; rows are
-- plain Buttons, built once via buildRow(row).
function W.CreateList(parent, rowHeight, buildRow, initRow)
	local box = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
	local bar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
	bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
	bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(rowHeight)
	view:SetElementInitializer("Button", function(row, data)
		if not row.built then
			row.built = true
			row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
			buildRow(row)
		end
		initRow(row, data)
	end)
	ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)

	local list = { box = box, bar = bar }
	function list:SetData(items)
		box:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants.RetainScrollPosition)
	end
	return list
end

-- Single-choice dropdown. entries() returns { {value, text}, ... }.
function W.CreateDropdown(parent, width, entries, getValue, setValue)
	local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	dropdown:SetWidth(width)
	dropdown:SetupMenu(function(_, root)
		for _, entry in ipairs(entries()) do
			root:CreateRadio(entry[2], function() return getValue() == entry[1] end, function()
				setValue(entry[1])
			end)
		end
	end)
	return dropdown
end

-- Multi-choice dropdown with checkboxes. isChecked(value), toggle(value).
function W.CreateMultiDropdown(parent, width, entries, isChecked, toggle, summary)
	local dropdown = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
	dropdown:SetWidth(width)
	dropdown:SetupMenu(function(_, root)
		for _, entry in ipairs(entries()) do
			root:CreateCheckbox(entry[2], function() return isChecked(entry[1]) end, function()
				toggle(entry[1])
			end)
		end
	end)
	if summary then
		dropdown:SetDefaultText(summary())
		dropdown.UpdateSummary = function(self) self:SetDefaultText(summary()) end
	end
	return dropdown
end

function W.CreateCheck(parent, label, getValue, setValue)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	local text = check.Text or check.text
	if not text then
		text = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		text:SetPoint("LEFT", check, "RIGHT", 2, 0)
	end
	text:SetText(label)
	text:SetFontObject("GameFontHighlightSmall")
	check:SetScript("OnClick", function(self)
		setValue(self:GetChecked() and true or false)
	end)
	check.Refresh = function(self) self:SetChecked(getValue()) end
	check:Refresh()
	return check
end

function W.Text(parent, template, justify)
	local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlightSmall")
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	return fs
end

-- First recipe in the guild pool that makes itemID, or nil.
function W.GuildRecipeFor(itemID)
	local rids = itemID and itemID > 0 and ns.Index.RecipesForItem(itemID)
	return rids and rids[1]
end

-- Item behavior for any frame with .itemID: the game's item tooltip on hover
-- (so price addons like Auctioneer or TSM add their lines) and shift-click
-- to link the item in chat. onOpenRecipe(recipeID), if given, makes a plain
-- click open the guild recipe that crafts the item.
function W.AttachItem(frame, onOpenRecipe)
	frame:SetScript("OnEnter", function(self)
		if self.itemID and self.itemID > 0 then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.itemID)
			if onOpenRecipe and W.GuildRecipeFor(self.itemID) then
				GameTooltip:AddLine(ns.L.CLICK_OPEN_RECIPE, 0.4, 0.8, 1)
			end
			GameTooltip:Show()
		elseif self.spellID then
			-- Recipes without an item (enchants): the recipe spell's tooltip.
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetSpellByID(self.spellID)
			GameTooltip:Show()
		end
	end)
	frame:SetScript("OnLeave", GameTooltip_Hide)
	frame:SetScript("OnClick", function(self)
		if not (self.itemID and self.itemID > 0) then return end
		if IsModifiedClick and IsModifiedClick("CHATLINK") then
			local _, link = C_Item.GetItemInfo(self.itemID)
			if not link then return end
			if ChatFrameUtil and ChatFrameUtil.InsertLink then
				ChatFrameUtil.InsertLink(link)
			elseif ChatEdit_InsertLink then
				ChatEdit_InsertLink(link)
			end
		elseif onOpenRecipe then
			local rid = W.GuildRecipeFor(self.itemID)
			if rid then onOpenRecipe(rid) end
		end
	end)
end

-- Opens a whisper like the game does: just "Name" for your own realm,
-- "Name-Realm" only for other realms (needed to reach them).
function W.SendTell(name)
	name = ns.Util.ShortName(name)
	if ChatFrameUtil and ChatFrameUtil.SendTell then
		ChatFrameUtil.SendTell(name)
	elseif ChatFrame_SendTell then
		ChatFrame_SendTell(name)
	end
end

local ONLINE_STAR = "|cff20ff20*|r"

local function coloredName(name, class)
	return ns.Util.ClassColored(ns.Util.ShortName(name), class)
end

--[[
Compact crafter name for lists and tooltips (entry from Index.Crafters):
  "Anna*"          online (star only if `star`; never for you)
  "Bobalt (Bob*)"  offline, but the same person is online as Bob
]]
function W.CrafterShort(c, star)
	local name = coloredName(c.name, c.class)
	if c.via then
		return name .. " (" .. coloredName(c.via.name, c.via.class) .. (star and ONLINE_STAR or "") .. ")"
	elseif star and c.online and not c.isSelf then
		return name .. ONLINE_STAR
	end
	return name
end

-- "Anna (online, 3d)" style label for a crafter entry from Index.Crafters.
function W.CrafterLabel(c)
	local L = ns.L
	local label = ns.Util.ClassColored(ns.Util.ShortName(c.name), c.class)
	local tags = {}
	if c.isSelf then
		tags[#tags + 1] = L.YOU
	elseif c.isAlt then
		tags[#tags + 1] = L.ALT
	end
	if c.readyAt then
		if c.ready then
			tags[#tags + 1] = "|cff20ff20" .. L.CD_READY .. "|r"
		else
			tags[#tags + 1] = "|cffff8000" .. L.CD_REMAINING:format(ns.Util.FormatAge(c.readyAt - ns.Now())) .. "|r"
		end
	end
	if c.online then
		tags[#tags + 1] = "|cff20ff20" .. L.ONLINE .. "|r"
	elseif c.via then
		tags[#tags + 1] = "|cff20ff20" .. L.ONLINE_AS:format(coloredName(c.via.name, c.via.class) .. "|cff20ff20") .. "|r"
	elseif c.ver > 0 then
		tags[#tags + 1] = L.CONFIRMED_AGO:format(ns.Util.FormatAge(ns.Now() - c.ver))
	end
	if #tags > 0 then
		label = label .. " |cff999999(" .. table.concat(tags, ", ") .. ")|r"
	end
	return label
end
