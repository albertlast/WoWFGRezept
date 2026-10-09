--[[
Tooltip lines:
  crafted items  -> "Craftable by guild: Anna*, Bert" or, with many crafters,
                    "Craftable by guild: 23 members (online: Anna, Bert, Cleo +2)"
  recipe items   -> "Known in your guild by 3: A, B, C" or "Not known in your guild yet"
                    (matched by the name after "Pattern: ", "Recipe: ", ...)
]]
local _, ns = ...

local L, Index, Util = ns.L, ns.Index, ns.Util
local Tooltip = {}
ns.Tooltip = Tooltip

local ITEM_CLASS_RECIPE = 9
local RECIPE_SUBCLASS_BOOK = 0  -- class skill books, not profession recipes
local MAX_NAMES = 4

local MAX_ONLINE_NAMES = 3

local function label(c)
	return Util.ClassColored(Util.ShortName(c.name), c.class)
end

--[[
Text for a list of crafters (Index.Crafters order: you, online, ...).
  few (<= MAX_NAMES):  "Anna*, Bert"            (* = online)
  many:                "online: Anna, Bert, Cleo +2"   or   "none online"
The caller puts the total in front for the "many" case. Common items (every
tailor makes Bolt of Linen Cloth) then stay one short line.
]]
function Tooltip.CrafterText(crafters)
	if #crafters <= MAX_NAMES then
		local names = {}
		for _, c in ipairs(crafters) do
			names[#names + 1] = label(c) .. (c.online and "|cff20ff20*|r" or "")
		end
		return table.concat(names, ", ")
	end
	local online = {}
	for _, c in ipairs(crafters) do
		if c.online and not c.isSelf then online[#online + 1] = c end
	end
	if #online == 0 then
		return L.TOOLTIP_NONE_ONLINE
	end
	local names = {}
	for i = 1, math.min(#online, MAX_ONLINE_NAMES) do
		names[i] = label(online[i])
	end
	local text = L.TOOLTIP_ONLINE:format(table.concat(names, ", "))
	if #online > MAX_ONLINE_NAMES then
		text = text .. " +" .. (#online - MAX_ONLINE_NAMES)
	end
	return text
end

-- Unique crafters of several recipes (the same item can have more than one).
local function craftersOf(recipeIDs)
	local list, seen = {}, {}
	for _, rid in ipairs(recipeIDs) do
		for _, c in ipairs(Index.Crafters(rid)) do
			if not seen[c.guid] then
				seen[c.guid] = true
				list[#list + 1] = c
			end
		end
	end
	return list
end

-- name (lowercase) -> recipeIDs, rebuilt with the index.
local nameMap, nameMapFor
local function recipesByName(name)
	Index.Ensure()
	if nameMapFor ~= Index.byRecipe then
		nameMap, nameMapFor = {}, Index.byRecipe
		for rid in pairs(Index.byRecipe) do
			local names = { Index.RecipeName(rid) }
			local item = Index.OutputItem(rid)
			if item > 0 then names[#names + 1] = C_Item.GetItemNameByID(item) end
			for _, n in pairs(names) do
				n = n:lower()
				nameMap[n] = nameMap[n] or {}
				table.insert(nameMap[n], rid)
			end
		end
	end
	return nameMap[name:lower()]
end

-- Recipe items: who in the guild already knows the recipe. "Not known" is
-- only claimed once the pool has data, so a fresh install stays quiet.
local function onRecipeItem(tooltip, name, subclassID)
	if subclassID == RECIPE_SUBCLASS_BOOK then return end
	local taught = name:match("^[^:]+:%s*(.+)$")
	if not taught then return end
	local known = recipesByName(taught)
	local crafters = known and craftersOf(known) or {}
	if #crafters > 0 then
		tooltip:AddLine(L.TOOLTIP_KNOWN_BY:format(#crafters) .. " " .. Tooltip.CrafterText(crafters), 0.4, 0.8, 1, true)
	elseif next(Index.byRecipe) then
		tooltip:AddLine(L.TOOLTIP_NOT_KNOWN, 0.3, 1, 0.3, true)
	end
end

local function onItem(tooltip, itemID)
	if not ns.db or not itemID or not ns.GetGuildData() then return end
	local options = ns.db.options

	local rids = Index.RecipesForItem(itemID)
	if rids then
		local crafters = options.tooltip and craftersOf(rids) or {}
		if #crafters > MAX_NAMES then
			tooltip:AddLine(L.TOOLTIP_CRAFTABLE .. " " .. L.TOOLTIP_MEMBERS:format(#crafters)
				.. " (" .. Tooltip.CrafterText(crafters) .. ")", 0.4, 0.8, 1, true)
		elseif #crafters > 0 then
			tooltip:AddLine(L.TOOLTIP_CRAFTABLE .. " " .. Tooltip.CrafterText(crafters), 0.4, 0.8, 1, true)
		end
		return
	end

	if options.tooltipRecipes then
		local name, _, _, _, _, _, _, _, _, _, _, classID, subclassID = C_Item.GetItemInfo(itemID)
		if classID == ITEM_CLASS_RECIPE and name then
			onRecipeItem(tooltip, name, subclassID)
		end
	end
end

function Tooltip.Start()
	if TooltipDataProcessor and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
			if tooltip == GameTooltip or tooltip == ItemRefTooltip then
				onItem(tooltip, data and data.id)
			end
		end)
	else
		GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
			local _, link = tooltip:GetItem()
			onItem(tooltip, link and C_Item.GetItemInfoInstant(link))
		end)
	end
end
