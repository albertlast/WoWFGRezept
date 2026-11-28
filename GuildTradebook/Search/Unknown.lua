--[[
Recipes nobody in the guild knows: every recipe of the profession lists
(Data/Catalog.lua) that no visible member has. The Recipes tab lists them
when its "Unknown in guild" switch is on.
]]
local _, ns = ...

local Index, Util, Catalog = ns.Index, ns.Util, ns.Catalog
local Unknown = {}
ns.Unknown = Unknown

local skillOf -- [recipeID] = skillLine, from the current lists

ns.On("RecipeListsChanged", function() skillOf = nil end)

local function lookup()
	if not skillOf then
		skillOf = {}
		for _, sl in ipairs(Catalog.SkillLines()) do
			for _, rid in ipairs(Catalog.Recipes(sl)) do skillOf[rid] = sl end
		end
	end
	return skillOf
end

-- True if a profession list has the recipe and no visible member knows it.
function Unknown.Is(recipeID)
	Index.Ensure()
	return lookup()[recipeID] ~= nil and Index.byRecipe[recipeID] == nil
end

--[[
Like Index.Search, over the unknown recipes: { recipeID, itemID, skillLine,
name, count, unknown = true }; count shows the skill at which the recipe
turns grey, when known. Missing lists are asked from the guild (Catalog).
]]
function Unknown.Search(text, skillLine)
	Index.Ensure()
	Catalog.Shown()
	local needle = text and text:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
	local results = {}
	for _, sl in ipairs(Catalog.SkillLines()) do
		if skillLine == 0 or sl == skillLine then
			for _, rid in ipairs(Catalog.Recipes(sl)) do
				if not Index.byRecipe[rid] then
					local name = Index.RecipeName(rid) or ("#" .. rid)
					if needle == "" or name:lower():find(needle, 1, true) then
						local fact = ns.db.recipeFacts[rid]
						results[#results + 1] = {
							recipeID = rid,
							itemID = Index.OutputItem(rid),
							skillLine = sl,
							name = name,
							count = fact and fact.trivial and ("|cff999999" .. fact.trivial .. "|r") or "",
							unknown = true,
						}
					end
				end
			end
		end
	end
	table.sort(results, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.recipeID < b.recipeID
	end)
	return results
end

-- Professions for the filter: those with a list and those of the guild.
function Unknown.SkillLines()
	local seen = {}
	for _, sl in ipairs(Catalog.SkillLines()) do seen[sl] = true end
	for _, sl in ipairs(Index.SkillLines()) do seen[sl] = true end
	local list = Util.SortedKeys(seen)
	Index.SortSkillLines(list, function(sl) return Index.primarySkill[sl] end)
	return list
end
