--[[
Tooltip lines:
  crafted items  -> "Craftable by guild: A, B (+3)"
  recipe items   -> "Known by guild: ..." (matched by the name after "Pattern: ")
]]
local _, ns = ...

local L, Index, Util = ns.L, ns.Index, ns.Util
local Tooltip = {}
ns.Tooltip = Tooltip

local ITEM_CLASS_RECIPE = 9
local MAX_NAMES = 4

local function crafterLine(recipeIDs)
	local names, seen, total = {}, {}, 0
	for _, rid in ipairs(recipeIDs) do
		for _, c in ipairs(Index.Crafters(rid)) do
			if not seen[c.guid] then
				seen[c.guid] = true
				total = total + 1
				if #names < MAX_NAMES then
					local name = Util.ClassColored(Util.ShortName(c.name), c.class)
					if c.online then name = name .. "|cff20ff20*|r" end
					names[#names + 1] = name
				end
			end
		end
	end
	if total == 0 then return nil end
	local line = table.concat(names, ", ")
	if total > #names then
		line = line .. " " .. L.TOOLTIP_MORE:format(total - #names)
	end
	return line
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

local function onItem(tooltip, itemID)
	if not ns.db or not ns.db.options.tooltip or not itemID or not ns.GetGuildData() then return end

	local rids = Index.RecipesForItem(itemID)
	if rids then
		local line = crafterLine(rids)
		if line then
			tooltip:AddLine(L.TOOLTIP_CRAFTABLE .. " " .. line, 0.4, 0.8, 1, true)
		end
		return
	end

	local name, _, _, _, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(itemID)
	if classID == ITEM_CLASS_RECIPE and name then
		local taught = name:match("^[^:]+:%s*(.+)$")
		local known = taught and recipesByName(taught)
		local line = known and crafterLine(known)
		if line then
			tooltip:AddLine(L.TOOLTIP_KNOWN .. " " .. line, 0.4, 0.8, 1, true)
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
