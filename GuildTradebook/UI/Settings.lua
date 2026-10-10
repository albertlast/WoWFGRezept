--[[
Options page under Options -> AddOns -> Guild Tradebook, using the game's
Settings API. The checkboxes write straight into GuildTradebookDB.options,
which the rest of the addon reads on every use, so changes apply at once.
Sub-page "Stat weights": one slider per stat for the Upgrades tab, stored
per character (GuildTradebookCharDB.statWeights; class and spec differ).
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
	{ "shareCooldowns", "SETTINGS_SHARE_COOLDOWNS", "SETTINGS_SHARE_COOLDOWNS_DESC",
		function() ns.Scanner.ApplyCooldownSharing() end },
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
	-- Sub-pages exist before the page is registered.
	Settings_.RegisterWeights(category)
	Settings.RegisterAddOnCategory(category)
	Settings_.category = category
end

local function formatWeight(value)
	return ("%.1f"):format(value)
end

function Settings_.RegisterWeights(category)
	if not (Settings.RegisterVerticalLayoutSubcategory and Settings.CreateSlider and Settings.CreateSliderOptions) then return end
	local U = ns.Upgrades
	local sub = Settings.RegisterVerticalLayoutSubcategory(category, L.SETTINGS_WEIGHTS)
	local weights = U.Weights()
	for _, key in ipairs(U.STATS) do
		local setting = Settings.RegisterAddOnSetting(sub, ADDON .. "_weight_" .. key, key, weights,
			"number", _G[key] or key, U.WEIGHT_DEFAULT)
		local options = Settings.CreateSliderOptions(U.WEIGHT_MIN, U.WEIGHT_MAX, U.WEIGHT_STEP)
		if options.SetLabelFormatter and MinimalSliderWithSteppersMixin then
			options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatWeight)
		end
		Settings.CreateSlider(sub, setting, options, L.SETTINGS_WEIGHT_DESC)
		if setting.SetValueChangedCallback then
			setting:SetValueChangedCallback(function() ns.UI.Refresh() end)
		end
	end
	Settings_.weightsCategory = sub
end

function Settings_.Open()
	if Settings_.category and Settings.OpenToCategory then
		Settings.OpenToCategory(Settings_.category:GetID())
	end
end
