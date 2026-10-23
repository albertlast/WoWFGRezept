--[[
Reagent check: which reagents of a recipe you already have (bags, bank,
reagent bank) and which are missing. Purely local.
]]
local _, ns = ...

local Reagents = {}
ns.Reagents = Reagents

--[[
Pure core.
  reagents = { {itemID, quantity, optional(0/1)}, ... }  (recipe facts)
  crafts   = number of crafts
  countFn(itemID) -> number owned
Returns rows = { {itemID, need, have, optional} }, missing = { {itemID, count} }.
Optional reagents never count as missing.
]]
function Reagents.Check(reagents, crafts, countFn)
	local rows, missing = {}, {}
	for _, r in ipairs(reagents) do
		local need = r[2] * crafts
		local have = countFn(r[1]) or 0
		local optional = r[3] == 1
		rows[#rows + 1] = { itemID = r[1], need = need, have = have, optional = optional }
		if not optional and have < need then
			missing[#missing + 1] = { itemID = r[1], count = need - have }
		end
	end
	return rows, missing
end

-- Reagents of a recipe ({ {itemID, quantity, optional}, ... }): known facts,
-- else the local client, else asked from the guild (FACT_REQ, see Protocol)
-- and nil until the answer arrives.
function Reagents.ForRecipe(recipeID)
	local fact = ns.db.recipeFacts[recipeID]
	if fact and fact.reagents then
		return fact.reagents
	end
	local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if ok and schematic and schematic.reagentSlotSchematics and #schematic.reagentSlotSchematics > 0 then
		ns.Scanner.ResolveFact(recipeID, nil)
		fact = ns.db.recipeFacts[recipeID]
		if fact and fact.reagents and #fact.reagents > 0 then
			return fact.reagents
		end
	end
	ns.Protocol.RequestFacts({ recipeID })
	return nil
end

-- Bank contents are only known after the bank was opened (game behavior).
function Reagents.Count(itemID)
	return C_Item.GetItemCount(itemID, true, false, true, true) or 0
end
