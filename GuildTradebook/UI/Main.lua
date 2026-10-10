local _, ns = ...

local L = ns.L
local UI = { tabs = {}, order = { "search", "upgrades", "wishlist", "members" } }
ns.UI = UI

-- Tab modules register themselves: UI.RegisterTab(key, label, build(content), refresh(content, arg))
function UI.RegisterTab(key, label, build, refresh)
	UI.tabs[key] = { label = label, build = build, refresh = refresh }
end

local function createFrame()
	local frame = CreateFrame("Frame", "GuildTradebookFrame", UIParent, "BasicFrameTemplateWithInset")
	frame:SetSize(760, 500)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("HIGH")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()
	tinsert(UISpecialFrames, "GuildTradebookFrame")

	local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not frame.TitleText then
		title:SetPoint("TOP", 0, -5)
	end
	title:SetText(L.TITLE)

	local previous
	for _, key in ipairs(UI.order) do
		local tab = UI.tabs[key]
		local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		button:SetSize(120, 22)
		if previous then
			button:SetPoint("LEFT", previous, "RIGHT", 4, 0)
		else
			button:SetPoint("TOPLEFT", 12, -28)
		end
		button:SetText(tab.label)
		button:SetScript("OnClick", function() UI.Select(key) end)
		tab.button = button
		previous = button

		local content = CreateFrame("Frame", nil, frame)
		content:SetPoint("TOPLEFT", 12, -56)
		content:SetPoint("BOTTOMRIGHT", -12, 10)
		content:Hide()
		tab.content = content
		tab.build(content)
	end

	frame.notInGuild = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	frame.notInGuild:SetPoint("CENTER")
	frame.notInGuild:SetText(L.NOT_IN_GUILD)

	frame:SetScript("OnShow", function() UI.Refresh() end)
	return frame
end

function UI.Select(key, arg)
	UI.current = key
	for k, tab in pairs(UI.tabs) do
		local active = k == key
		tab.content:SetShown(active and ns.GetGuildData() ~= nil)
		if active then
			tab.button:LockHighlight()
		else
			tab.button:UnlockHighlight()
		end
	end
	UI.Refresh(arg)
end

function UI.Refresh(arg)
	if not UI.frame or not UI.frame:IsShown() then return end
	local inGuild = ns.GetGuildData() ~= nil
	UI.frame.notInGuild:SetShown(not inGuild)
	local tab = UI.tabs[UI.current]
	if tab then
		tab.content:SetShown(inGuild)
		if inGuild then
			tab.refresh(tab.content, arg)
		end
	end
end

function UI.Show(key, arg)
	if not UI.frame then
		UI.frame = createFrame()
	end
	UI.frame:Show()
	UI.Select(key or UI.current or "search", arg)
end

function UI.Toggle()
	if UI.frame and UI.frame:IsShown() then
		UI.frame:Hide()
	else
		UI.Show()
	end
end

-- Refresh the open tab when data changes, at most a few times per second.
local function refreshSoon()
	if UI.frame and UI.frame:IsShown() then
		ns.Debounce("uiRefresh", 0.3, function() UI.Refresh() end)
	end
end
ns.On("RecordsChanged", refreshSoon)
ns.On("FactsChanged", refreshSoon)
ns.On("CategoriesChanged", refreshSoon)
ns.On("RosterUpdated", refreshSoon)
ns.On("GuildChanged", refreshSoon)
ns.On("WishlistChanged", refreshSoon)
