--[[
In-memory lookup tables over the visible pool, rebuilt lazily after changes:
  byRecipe[recipeID] = { guid, ... }
  byItem[itemID]     = { recipeID, ... }
  recipeSkill[recipeID] = skillLineID
Visible = shared record of a current member, minus primary professions the
server says the member no longer has (stale relayed data).
]]
local _, ns = ...

local Store, Roster, Util = ns.Store, ns.Roster, ns.Util
local Index = { dirty = true, byRecipe = {}, byItem = {}, recipeSkill = {} }
ns.Index = Index

ns.On("RecordsChanged", function() Index.dirty = true end)
ns.On("RosterUpdated", function() Index.dirty = true end)
ns.On("GuildChanged", function() Index.dirty = true end)

local function isMember(guid)
	return Roster.IsMember(guid)
end

function Index.IsProfessionVisible(rec, skillLine)
	return not Roster.IsProfessionContradicted(rec.guid, skillLine)
end

function Index.Rebuild()
	local byRecipe, byItem, recipeSkill = {}, {}, {}
	local gd = ns.GetGuildData()
	if gd then
		for guid, rec in pairs(gd.chars) do
			if Store.IsShareable(rec, isMember) then
				for sl, p in pairs(rec.profs) do
					if p.recipes and Index.IsProfessionVisible(rec, sl) then
						for rid, item in pairs(p.recipes) do
							local list = byRecipe[rid]
							if not list then
								list = {}
								byRecipe[rid] = list
								recipeSkill[rid] = sl
								local fact = ns.db.recipeFacts[rid]
								local itemID = (fact and fact.item and fact.item > 0 and fact.item) or item
								if itemID and itemID > 0 then
									byItem[itemID] = byItem[itemID] or {}
									table.insert(byItem[itemID], rid)
								end
							end
							list[#list + 1] = guid
						end
					end
				end
			end
		end
	end
	Index.byRecipe, Index.byItem, Index.recipeSkill = byRecipe, byItem, recipeSkill
	Index.dirty = false
end

function Index.Ensure()
	if Index.dirty then
		Index.Rebuild()
	end
end

function Index.OutputItem(recipeID)
	local fact = ns.db.recipeFacts[recipeID]
	return fact and fact.item or 0
end

function Index.RecipeName(recipeID)
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(recipeID)
	if not name and GetSpellInfo then
		name = GetSpellInfo(recipeID)
	end
	if not name then
		local item = Index.OutputItem(recipeID)
		name = item > 0 and C_Item.GetItemNameByID(item) or nil
	end
	return name
end

local function charInfo(guid)
	local gd = ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	local member = Roster.Get(guid)
	local selfGUID = UnitGUID("player")
	local acc = ns.db.account.chars[guid]
	return {
		guid = guid,
		name = (member and member.name) or (rec and rec.name) or "?",
		class = (member and member.class) or (rec and rec.class),
		online = member and member.online or false,
		ver = rec and rec.ver or 0,
		isSelf = guid == selfGUID,
		isAlt = acc ~= nil and guid ~= selfGUID,
	}
end

-- Crafters of a recipe: you first, then online, then most recently confirmed.
function Index.Crafters(recipeID)
	Index.Ensure()
	local out = {}
	for _, guid in ipairs(Index.byRecipe[recipeID] or {}) do
		out[#out + 1] = charInfo(guid)
	end
	table.sort(out, function(a, b)
		if a.isSelf ~= b.isSelf then return a.isSelf end
		if a.online ~= b.online then return a.online end
		if a.ver ~= b.ver then return a.ver > b.ver end
		return a.name < b.name
	end)
	return out
end

function Index.RecipesForItem(itemID)
	Index.Ensure()
	return Index.byItem[itemID]
end

-- Free-text search over recipe and item names; skillLine 0 = all professions.
function Index.Search(text, skillLine)
	Index.Ensure()
	local needle = text and text:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
	local results = {}
	for rid, guids in pairs(Index.byRecipe) do
		if skillLine == 0 or Index.recipeSkill[rid] == skillLine then
			local name = Index.RecipeName(rid) or ("#" .. rid)
			if needle == "" or name:lower():find(needle, 1, true) then
				results[#results + 1] = {
					recipeID = rid,
					itemID = Index.OutputItem(rid),
					skillLine = Index.recipeSkill[rid],
					name = name,
					count = #guids,
				}
			end
		end
	end
	table.sort(results, function(a, b) return a.name < b.name end)
	return results
end

-- Skill lines present in the pool, for the profession filter.
function Index.SkillLines()
	Index.Ensure()
	local seen = {}
	for _, sl in pairs(Index.recipeSkill) do
		seen[sl] = true
	end
	return Util.SortedKeys(seen)
end

function Index.SkillLineName(skillLine)
	local info = C_TradeSkillUI.GetProfessionInfoBySkillLineID and C_TradeSkillUI.GetProfessionInfoBySkillLineID(skillLine)
	if info and info.professionName and info.professionName ~= "" then
		return info.professionName
	end
	if C_TradeSkillUI.GetTradeSkillDisplayName then
		local name = C_TradeSkillUI.GetTradeSkillDisplayName(skillLine)
		if name and name ~= "" then return name end
	end
	return "#" .. skillLine
end
