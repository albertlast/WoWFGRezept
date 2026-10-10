--[[
In-memory lookup tables over the visible pool, rebuilt lazily after changes:
  byRecipe[recipeID] = { guid, ... }
  byItem[itemID]     = { recipeID, ... }
  recipeSkill[recipeID] = skillLineID
  primarySkill[skillLineID] = true when some member has it as a primary profession
  byPlayer[playerID] = { guid, ... }: characters of the same person (sorted)
Visible = shared record of a current member, minus primary professions the
server says the member no longer has (stale relayed data).
]]
local _, ns = ...

local Store, Roster, Util = ns.Store, ns.Roster, ns.Util
local Index = { dirty = true, byRecipe = {}, byItem = {}, recipeSkill = {}, primarySkill = {}, byPlayer = {} }
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
	local byRecipe, byItem, recipeSkill, primarySkill, byPlayer = {}, {}, {}, {}, {}
	local gd = ns.GetGuildData()
	if gd then
		for guid, rec in pairs(gd.chars) do
			if Store.IsShareable(rec, isMember) then
				if rec.player then
					byPlayer[rec.player] = byPlayer[rec.player] or {}
					table.insert(byPlayer[rec.player], guid)
				end
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
	for _, list in pairs(byPlayer) do
		table.sort(list)
	end
	Index.byRecipe, Index.byItem, Index.recipeSkill, Index.primarySkill = byRecipe, byItem, recipeSkill, primarySkill
	Index.byPlayer = byPlayer
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

-- Other characters of the same person (shared player ID), or an empty list.
function Index.Siblings(guid)
	Index.Ensure()
	local gd = ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	local out = {}
	for _, other in ipairs(rec and rec.player and Index.byPlayer[rec.player] or {}) do
		if other ~= guid then out[#out + 1] = other end
	end
	return out
end

--[[
The online character to whisper when `guid` itself is offline: another
character of the same person, as { guid, name, class }, or nil. Never you:
your own alts are not "reachable" through you.
]]
function Index.Via(guid)
	local member = Roster.Get(guid)
	if member and member.online then return nil end
	local selfGUID = UnitGUID("player")
	for _, other in ipairs(Index.Siblings(guid)) do
		local m = Roster.Get(other)
		if other ~= selfGUID and m and m.online then
			return { guid = other, name = Roster.NameOf(other) or m.name, class = m.class }
		end
	end
	return nil
end

local function charInfo(guid, recipeID)
	local gd = ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	local member = Roster.Get(guid)
	local selfGUID = UnitGUID("player")
	-- Own characters: this account's, and the linked other license's.
	local acc = ns.db.account.chars[guid] or (ns.Link and ns.Link.IsPartner(guid)) or nil
	local online = member and member.online or false
	local via = not online and Index.Via(guid) or nil
	return {
		guid = guid,
		name = Roster.NameOf(guid) or "?",
		class = (member and member.class) or (rec and rec.class),
		online = online,
		via = via,                         -- same person, online on another character
		reachable = online or via ~= nil,  -- can be asked right now
		ver = rec and rec.ver or 0,
		isSelf = guid == selfGUID,
		isAlt = acc ~= nil and guid ~= selfGUID,
		readyAt = cooldownOf(rec, recipeID),
	}
end

--[[
Whom to whisper about a character entry ({name, online, via, isSelf, isAlt}):
the character when online, else the same player's online character. nil
for your own characters (you, your alts) and for players who are not online
on any character; the second value is the reason, for tooltips.
]]
function Index.ContactFor(c)
	if c.isSelf or c.isAlt then return nil, ns.L.YOUR_CHARACTER end
	if c.online then return c.name end
	if c.via then return c.via.name end
	return nil, ns.L.NOT_REACHABLE
end

-- Client locale of a member ("deDE"), from its record; nil if unknown.
function Index.LocaleOf(guid)
	local gd = ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	return rec and rec.loc
end

-- Display info for one character (name, class, online, ...).
function Index.CrafterInfo(guid)
	return charInfo(guid)
end

-- Crafters of a recipe: you first, then online, then reachable through another
-- online character of the same person, then (for cooldown recipes) ready
-- ones, then most recently confirmed.
function Index.Crafters(recipeID)
	Index.Ensure()
	local now = ns.Now()
	local out = {}
	for _, guid in ipairs(Index.byRecipe[recipeID] or {}) do
		local c = charInfo(guid, recipeID)
		c.ready = c.readyAt == nil or c.readyAt <= now
		-- The owner does not share the time: listed, never ready.
		c.cooldownHidden = Store.IsHiddenCooldown(c.readyAt)
		out[#out + 1] = c
	end
	table.sort(out, function(a, b)
		if a.isSelf ~= b.isSelf then return a.isSelf end
		if a.online ~= b.online then return a.online end
		if a.reachable ~= b.reachable then return a.reachable end
		if a.ready ~= b.ready then return a.ready end
		if a.cooldownHidden ~= b.cooldownHidden then return not a.cooldownHidden end
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
