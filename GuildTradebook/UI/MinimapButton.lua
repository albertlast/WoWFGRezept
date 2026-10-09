--[[
Minimap button, the same way Gargul does it: a LibDataBroker data object
shown by LibDBIcon-1.0 (dragging, minimap shapes, button-collector addons and
LDB displays like Titan Panel all work), plus a LibCustomGlow "proc" glow
while a guild member who can craft something on your wishlist is online.

Left-click: open the window (the Wishlist while glowing), right-click: settings.
Position: ns.db.minimap (LibDBIcon's own table), shown/hidden: options.minimapButton.
]]
local ADDON, ns = ...

local L, Util = ns.L, ns.Util
local MinimapButton = { glowing = false }
ns.MinimapButton = MinimapButton

local ICON = "Interface\\Icons\\INV_Scroll_03"
local GLOW_COLOR = { 1, 0.82, 0, 1 }

local function libs()
	return LibStub("LibDataBroker-1.1", true), LibStub("LibDBIcon-1.0", true), LibStub("LibCustomGlow-1.0", true)
end

local function onTooltipShow(tooltip)
	tooltip:AddLine(L.TITLE, 1, 1, 1)
	local ready = ns.Wishlist.ReadyNow()
	if #ready > 0 then
		tooltip:AddLine(L.MINIMAP_WISH_READY, 0.4, 0.8, 1)
		for _, entry in ipairs(ready) do
			local names = {}
			for _, c in ipairs(entry.online) do
				names[#names + 1] = Util.ClassColored(Util.ShortName(c.name), c.class)
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
	MinimapButton.glowing = glowing
	local button = icon and icon:GetMinimapButton(ADDON)
	if not (button and glow) then return end
	if glowing and ns.db.options.minimapButton then
		glow.ButtonGlow_Start(button, GLOW_COLOR)
	else
		glow.ButtonGlow_Stop(button)
	end
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
	local function updateSoon()
		ns.Debounce("minimapGlow", 1, MinimapButton.Update)
	end
	ns.On("RosterUpdated", updateSoon)
	ns.On("RecordsChanged", updateSoon)
	ns.On("WishlistChanged", updateSoon)
	ns.On("GuildChanged", updateSoon)
end
