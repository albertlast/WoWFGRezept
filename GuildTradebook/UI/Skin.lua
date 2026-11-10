--[[
The look of a UI suite on our windows. EllesmereUI (with its Blizzard Skins+
module) has a public skinning API for other addons: we register once, it
hands us a skin object S at login, and S paints the frames we give it in the
player's theme (developer guide: SKINNING_API.md in the EllesmereUI folder).
Players can turn it off per addon in EllesmereUI's options; then S never
arrives.

The UI code hands every frame over as it creates it: Skin.Button(b),
Skin.Shell(frame), ... Frames made before S arrives wait in a queue. Without
EllesmereUI every call does nothing. A failing paint call is logged and
never stops our own UI code.
]]
local _, ns = ...

local Skin = { queue = {}, selected = {} }
ns.Skin = Skin

local S              -- EllesmereUI's skin object, once it arrived
local expected = false -- registered: S may still arrive

local function paint(kind, frame, opts)
	local fn = S[kind]
	if not fn then return end -- an older EllesmereUI without this primitive
	local ok, err = pcall(fn, frame, opts)
	if not ok then ns.Debug("skin", kind, "failed:", tostring(err)) end
end

local function use(kind, frame, opts)
	if not frame then return end
	if S then
		paint(kind, frame, opts)
	elseif expected then
		Skin.queue[#Skin.queue + 1] = { kind, frame, opts }
	end
end

for _, kind in ipairs({ "Shell", "CloseButton", "Tab", "Button", "EditBox", "Checkbox", "Dropdown", "ScrollBar" }) do
	Skin[kind] = function(frame, opts) use(kind, frame, opts) end
end

-- Our window tabs are buttons we switch ourselves, so the selected look is
-- set from here (Main.lua's UI.Select).
function Skin.SetTabSelected(tab, selected)
	Skin.selected[tab] = selected
	if S and S.SetTabSelection then
		local ok, err = pcall(S.SetTabSelection, tab, selected)
		if not ok then ns.Debug("skin SetTabSelection failed:", tostring(err)) end
	end
end

function Skin.Active()
	return S ~= nil
end

local function arrived(s)
	S = s
	local queue = Skin.queue
	Skin.queue = {}
	for _, entry in ipairs(queue) do
		paint(entry[1], entry[2], entry[3])
	end
	for tab, selected in pairs(Skin.selected) do
		Skin.SetTabSelected(tab, selected)
	end
end

local EUI = EllesmereUI
if type(EUI) == "table" and type(EUI.RegisterSkin) == "function" then
	expected = EUI.RegisterSkin("GuildTradebook", arrived) and true or false
end
