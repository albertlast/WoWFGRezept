local _, ns = ...

local W = {}
ns.Widgets = W

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

function W.SendTell(name)
	if ChatFrameUtil and ChatFrameUtil.SendTell then
		ChatFrameUtil.SendTell(name)
	elseif ChatFrame_SendTell then
		ChatFrame_SendTell(name)
	end
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
	if c.online then
		tags[#tags + 1] = "|cff20ff20" .. L.ONLINE .. "|r"
	elseif c.ver > 0 then
		tags[#tags + 1] = L.CONFIRMED_AGO:format(ns.Util.FormatAge(ns.Now() - c.ver))
	end
	if #tags > 0 then
		label = label .. " |cff999999(" .. table.concat(tags, ", ") .. ")|r"
	end
	return label
end
