--[[
Minimap button, the same way Gargul does it: a LibDataBroker data object
shown by LibDBIcon-1.0 (dragging, minimap shapes, button-collector addons and
LDB displays like Titan Panel all work), plus a LibCustomGlow "proc" glow
while a guild member who can craft something on your wishlist is online.

Left-click: open the window (the Wishlist while glowing), right-click: settings.
Position: ns.db.minimap (LibDBIcon's own table), shown/hidden: options.minimapButton.
]]
local ADDON, ns = ...

local L = ns.L
local MinimapButton = { glowing = false }
ns.MinimapButton = MinimapButton

local ICON = "Interface\\Icons\\INV_Scroll_03"
local GLOW_COLOR = { 1, 0.82, 0, 1 }

-- The embedded LibCustomGlow is Gargul's copy, registered as "LibCustomGlowGargul-1.0".
local function libs()
	return LibStub("LibDataBroker-1.1", true), LibStub("LibDBIcon-1.0", true),
		LibStub("LibCustomGlowGargul-1.0", true) or LibStub("LibCustomGlow-1.0", true)
end

local function onTooltipShow(tooltip)
	tooltip:AddLine(L.TITLE, 1, 1, 1)
	local ready = ns.Wishlist.ReadyNow()
	if (#ready > 0) ~= MinimapButton.glowing then
		ns.Debug("minimap glow out of date (should be", tostring(#ready > 0) .. "), updating")
		MinimapButton.Update()
	end
	if #ready > 0 then
		tooltip:AddLine(L.MINIMAP_WISH_READY, 0.4, 0.8, 1)
		for _, entry in ipairs(ready) do
			local names = {}
			for _, c in ipairs(entry.online) do
				names[#names + 1] = ns.Widgets.CrafterShort(c, false)
			end
			tooltip:AddDoubleLine(entry.name, table.concat(names, ", "), 1, 1, 1, 1, 1, 1)
		end
	end
	tooltip:AddLine(L.MINIMAP_HINT, 0.6, 0.6, 0.6, true)
end

local function onClick(_, mouseButton)
	if mouseButton == "RightButton" then
		ns.Settings.Open()
	elseif MinimapButton.glowing then
		ns.UI.Show("wishlist")
	else
		ns.UI.Toggle()
	end
end

local function register()
	local ldb, icon = libs()
	if not (ldb and icon) or MinimapButton.registered then return end
	local object = ldb:NewDataObject(ADDON, {
		type = "launcher",
		text = L.TITLE,
		icon = ICON,
		OnClick = onClick,
		OnTooltipShow = onTooltipShow,
	})
	ns.db.minimap = ns.db.minimap or {}
	ns.db.minimap.hide = not ns.db.options.minimapButton
	icon:Register(ADDON, object, ns.db.minimap)
	MinimapButton.object = object
	MinimapButton.registered = true
end

-- Glow while a wished recipe has an online crafter (other than you).
function MinimapButton.Update()
	local _, icon, glow = libs()
	local glowing = #ns.Wishlist.ReadyNow() > 0
	if glowing ~= MinimapButton.glowing then
		ns.Debug("minimap glow:", tostring(glowing))
	end
	MinimapButton.glowing = glowing
	local button = icon and icon:GetMinimapButton(ADDON)
	if not (button and glow) then
		ns.Debug("minimap glow: no button or LibCustomGlow", tostring(button), tostring(glow))
		return
	end
	local ok, err
	if glowing and ns.db.options.minimapButton then
		ok, err = pcall(glow.ButtonGlow_Start, button, GLOW_COLOR)
	else
		ok, err = pcall(glow.ButtonGlow_Stop, button)
	end
	if not ok then
		ns.Debug("minimap glow failed:", tostring(err))
	end
end

-- "/gtb glow": what the glow should show and what it does, for the log.
function MinimapButton.Report()
	local ldb, icon, glow = libs()
	local ready = ns.Wishlist.ReadyNow()
	ns.Print(("glow: should=%s option=%s libs: LDB=%s DBIcon=%s CustomGlow=%s"):format(
		tostring(#ready > 0), tostring(ns.db.options.minimapButton), tostring(ldb ~= nil), tostring(icon ~= nil),
		tostring(glow ~= nil)))
	MinimapButton.Update()
	local button = icon and icon:GetMinimapButton(ADDON)
	if not button then
		ns.Print("glow: no minimap button")
		return
	end
	ns.Print(("glow: button shown=%s visible=%s size=%.0fx%.0f level=%d strata=%s parent=%s"):format(
		tostring(button:IsShown()), tostring(button:IsVisible()), button:GetWidth(), button:GetHeight(),
		button:GetFrameLevel(), tostring(button:GetFrameStrata()), tostring(button:GetParent() and button:GetParent():GetName())))
	local f = button._ButtonGlow
	if not f then
		ns.Print("glow: no glow frame")
		return
	end
	ns.Print(("glow: frame shown=%s visible=%s alpha=%.2f size=%.0fx%.0f level=%d animIn=%s animOut=%s"):format(
		tostring(f:IsShown()), tostring(f:IsVisible()), f:GetAlpha(), f:GetWidth(), f:GetHeight(), f:GetFrameLevel(),
		tostring(f.animIn and f.animIn:IsPlaying()), tostring(f.animOut and f.animOut:IsPlaying())))
	for _, key in ipairs({ "ants", "outerGlow", "innerGlow", "spark" }) do
		local t = f[key]
		if t then
			ns.Print(("glow: %s texture=%s alpha=%.2f shown=%s"):format(key, tostring(t:GetTexture()), t:GetAlpha(),
				tostring(t:IsShown())))
		end
	end
	ns.Print("glow: AnimateTexCoords=" .. type(AnimateTexCoords))
end

function MinimapButton.SetShown(shown)
	register()
	local _, icon = libs()
	if not icon then return end
	ns.db.minimap.hide = not shown
	if shown then
		icon:Show(ADDON)
	else
		icon:Hide(ADDON)
	end
	MinimapButton.Update()
end

function MinimapButton.Start()
	register()
	MinimapButton.SetShown(ns.db.options.minimapButton)
	-- Never postponed: frequent roster updates must not keep it from running.
	local function updateSoon()
		ns.ScheduleEarliest("minimapGlow", 1, MinimapButton.Update)
	end
	ns.On("RosterUpdated", updateSoon)
	ns.On("RecordsChanged", updateSoon)
	ns.On("WishlistChanged", updateSoon)
	ns.On("GuildChanged", updateSoon)
end
