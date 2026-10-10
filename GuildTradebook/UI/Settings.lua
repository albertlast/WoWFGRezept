--[[
Options page under Options -> AddOns -> Guild Tradebook, using the game's
Settings API. The checkboxes write straight into GuildTradebookDB.options,
which the rest of the addon reads on every use, so changes apply at once.
]]
local ADDON, ns = ...

local L = ns.L
local Settings_ = {}
ns.Settings = Settings_

-- { option key, label, tooltip, onChange(value)? }, in display order.
Settings_.CHECKBOXES = {
	{ "minimapButton", "SETTINGS_MINIMAP", "SETTINGS_MINIMAP_DESC",
		function(value) ns.MinimapButton.SetShown(value) end },
	{ "hideForeignBoP", "SETTINGS_HIDE_BOP", "SETTINGS_HIDE_BOP_DESC",
		function() ns.UI.Refresh() end },
	{ "tooltip", "SETTINGS_TOOLTIP", "SETTINGS_TOOLTIP_DESC" },
	{ "tooltipRecipes", "SETTINGS_TOOLTIP_RECIPES", "SETTINGS_TOOLTIP_RECIPES_DESC" },
	{ "tooltipProfessions", "SETTINGS_TOOLTIP_PROFESSIONS", "SETTINGS_TOOLTIP_PROFESSIONS_DESC" },
	{ "tooltipSecondary", "SETTINGS_TOOLTIP_SECONDARY", "SETTINGS_TOOLTIP_SECONDARY_DESC" },
	{ "chatResponder", "SETTINGS_CHAT", "SETTINGS_CHAT_DESC" },
	{ "wishAlerts", "SETTINGS_WISH_ALERTS", "SETTINGS_WISH_ALERTS_DESC" },
	{ "wishSound", "SETTINGS_WISH_SOUND", "SETTINGS_WISH_SOUND_DESC" },
	{ "debug", "SETTINGS_DEBUG", "SETTINGS_DEBUG_DESC" },
}

function Settings_.Register()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) or Settings_.category then return end
	local category = Settings.RegisterVerticalLayoutCategory(L.TITLE)
	local options = ns.db.options
	for _, entry in ipairs(Settings_.CHECKBOXES) do
		local key = entry[1]
		local default = ns.Store.OPTION_DEFAULTS[key]
		local setting = Settings.RegisterAddOnSetting(category, ADDON .. "_" .. key, key, options,
			type(default), L[entry[2]], default)
		Settings.CreateCheckbox(category, setting, L[entry[3]])
		if entry[4] and setting.SetValueChangedCallback then
			local onChange = entry[4]
			setting:SetValueChangedCallback(function(_, value) onChange(value) end)
		end
	end
	Settings.RegisterAddOnCategory(category)
	Settings_.category = category
end

function Settings_.Open()
	if Settings_.category and Settings.OpenToCategory then
		Settings.OpenToCategory(Settings_.category:GetID())
	end
end
