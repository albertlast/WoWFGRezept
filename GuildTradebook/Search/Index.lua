--[[
In-memory lookup tables over the visible pool, rebuilt lazily after changes:
  byRecipe[recipeID] = { guid, ... }
  byItem[itemID]     = { recipeID, ... }
  recipeSkill[recipeID] = skillLineID
  primarySkill[skillLineID] = true when some member has it as a primary profession
Visible = shared record of a current member, minus primary professions the
server says the member no longer has (stale relayed data).
]]
local _, ns = ...

local Store, Roster, Util = ns.Store, ns.Roster, ns.Util
local Index = { dirty = true, byRecipe = {}, byItem = {}, recipeSkill = {}, primarySkill = {} }
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
	local byRecipe, byItem, recipeSkill, primarySkill = {}, {}, {}, {}
	local gd = ns.GetGuildData()
	if gd then
		for guid, rec in pairs(gd.chars) do
			if Store.IsShareable(rec, isMember) then
				local listed = {} -- a character appears once per recipe
				for sl, p in pairs(rec.profs) do
					if p.primary then
						primarySkill[sl] = true
					end
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
							if not listed[rid] then
								listed[rid] = true
								list[#list + 1] = guid
							end
						end
					end
				end
			end
		end
	end
	Index.byRecipe, Index.byItem, Index.recipeSkill, Index.primarySkill = byRecipe, byItem, recipeSkill, primarySkill
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

-- readyAt of the crafter's cooldown for recipeID (0 = ready), or nil.
local function cooldownOf(rec, recipeID)
	if not rec or not recipeID then return nil end
	for _, p in pairs(rec.profs) do
		if p.cds and p.cds[recipeID] then
			return p.cds[recipeID]
		end
	end
end

local function charInfo(guid, recipeID)
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
		readyAt = cooldownOf(rec, recipeID),
	}
end

-- Display info for one character (name, class, online, ...).
function Index.CrafterInfo(guid)
	return charInfo(guid)
end

-- Crafters of a recipe: you first, then online, then (for cooldown recipes)
-- ready ones, then most recently confirmed.
function Index.Crafters(recipeID)
	Index.Ensure()
	local now = ns.Now()
	local out = {}
	for _, guid in ipairs(Index.byRecipe[recipeID] or {}) do
		local c = charInfo(guid, recipeID)
		c.ready = c.readyAt == nil or c.readyAt <= now
		out[#out + 1] = c
	end
	table.sort(out, function(a, b)
		if a.isSelf ~= b.isSelf then return a.isSelf end
		if a.online ~= b.online then return a.online end
		if a.ready ~= b.ready then return a.ready end
		if a.ver ~= b.ver then return a.ver > b.ver end
		return a.name < b.name
	end)
	return out
end

function Index.RecipesForItem(itemID)
	Index.Ensure()
	return Index.byItem[itemID]
end

-- true / false, or nil while the item is not loaded yet (a load is requested).
function Index.IsBindOnPickup(itemID)
	local bindType = select(14, C_Item.GetItemInfo(itemID))
	if bindType == nil then
		C_Item.RequestLoadItemDataByID(itemID)
		return nil
	end
	return bindType == 1
end

--[[
Free-text search over recipe and item names.
  skillLine             0 = all professions
  crafterGUID           optional: only recipes this character knows
  hideForeignBoP        optional: hide recipes whose item binds on pickup
                        unless the logged-in character can craft it
                        (items still loading stay visible)
]]
function Index.Search(text, skillLine, crafterGUID, hideForeignBoP)
	Index.Ensure()
	local selfGUID = UnitGUID("player")
	local needle = text and text:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""
	local results = {}
	for rid, guids in pairs(Index.byRecipe) do
		if (skillLine == 0 or Index.recipeSkill[rid] == skillLine)
			and (not crafterGUID or Util.Contains(guids, crafterGUID)) then
			local name = Index.RecipeName(rid) or ("#" .. rid)
			local itemID = Index.OutputItem(rid)
			local hidden = hideForeignBoP and itemID > 0 and not Util.Contains(guids, selfGUID)
				and Index.IsBindOnPickup(itemID)
			if not hidden and (needle == "" or name:lower():find(needle, 1, true)) then
				results[#results + 1] = {
					recipeID = rid,
					itemID = itemID,
					skillLine = Index.recipeSkill[rid],
					name = name,
					count = #guids,
				}
			end
		end
	end
	table.sort(results, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		local pa, pb = Index.primarySkill[a.skillLine] or false, Index.primarySkill[b.skillLine] or false
		if pa ~= pb then return pa end
		return a.recipeID < b.recipeID
	end)
	return results
end

-- Skill lines present in the pool, for the profession filter: primary
-- professions first, then secondary ones, each by name.
function Index.SkillLines()
	Index.Ensure()
	local seen = {}
	for _, sl in pairs(Index.recipeSkill) do
		seen[sl] = true
	end
	local list = Util.SortedKeys(seen)
	Index.SortSkillLines(list, function(sl) return Index.primarySkill[sl] end)
	return list
end

function Index.SortSkillLines(list, isPrimary)
	table.sort(list, function(a, b)
		local pa, pb = isPrimary(a) or false, isPrimary(b) or false
		if pa ~= pb then return pa end
		return Index.SkillLineName(a) < Index.SkillLineName(b)
	end)
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
