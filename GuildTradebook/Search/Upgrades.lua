--[[
Upgrade finder: guild-craftable items of the selected type and slot that beat
the equipped item in the selected favorite stats.

The core (Upgrades.Find) takes an `api` table so it can be tested without the
game; Upgrades.GameAPI() supplies the real one.
]]
local _, ns = ...

local Upgrades = {}
ns.Upgrades = Upgrades

local ITEM_CLASS_WEAPON = 2
local ITEM_CLASS_ARMOR = 4
local BIND_ON_PICKUP = 1

-- Equip location -> inventory slots it competes for.
Upgrades.SLOTS_BY_EQUIPLOC = {
	INVTYPE_HEAD = { 1 },
	INVTYPE_NECK = { 2 },
	INVTYPE_SHOULDER = { 3 },
	INVTYPE_BODY = { 4 },
	INVTYPE_CHEST = { 5 },
	INVTYPE_ROBE = { 5 },
	INVTYPE_WAIST = { 6 },
	INVTYPE_LEGS = { 7 },
	INVTYPE_FEET = { 8 },
	INVTYPE_WRIST = { 9 },
	INVTYPE_HAND = { 10 },
	INVTYPE_FINGER = { 11, 12 },
	INVTYPE_TRINKET = { 13, 14 },
	INVTYPE_CLOAK = { 15 },
	INVTYPE_WEAPON = { 16 },
	INVTYPE_2HWEAPON = { 16 },
	INVTYPE_WEAPONMAINHAND = { 16 },
	INVTYPE_WEAPONOFFHAND = { 17 },
	INVTYPE_SHIELD = { 17 },
	INVTYPE_HOLDABLE = { 17 },
	INVTYPE_RANGED = { 18 },
	INVTYPE_RANGEDRIGHT = { 18 },
	INVTYPE_THROWN = { 18 },
	INVTYPE_RELIC = { 18 },
	INVTYPE_TABARD = { 19 },
}

-- Slots offered in the UI, in paper doll order.
Upgrades.SLOT_ORDER = { 1, 2, 3, 15, 5, 4, 19, 9, 10, 6, 7, 8, 11, 13, 16, 17, 18 }

-- Item type filter keys: "ANY", "WEAPON", or "ARMOR:<subclassID>".
-- Armor subclasses: 0 misc (jewelry, trinkets), 1 cloth, 2 leather, 3 mail, 4 plate, 6 shield.
Upgrades.ITEM_TYPES = { "ANY", "ARMOR:1", "ARMOR:2", "ARMOR:3", "ARMOR:4", "ARMOR:0", "ARMOR:6", "WEAPON" }

-- Best armor per class: { subclass, fromLevel } pairs, highest first.
local ARMOR_BY_CLASS = {
	WARRIOR = { { 4, 40 }, { 3, 1 } },
	PALADIN = { { 4, 40 }, { 3, 1 } },
	HUNTER = { { 3, 40 }, { 2, 1 } },
	SHAMAN = { { 3, 40 }, { 2, 1 } },
	ROGUE = { { 2, 1 } },
	DRUID = { { 2, 1 } },
	PRIEST = { { 1, 1 } },
	MAGE = { { 1, 1 } },
	WARLOCK = { { 1, 1 } },
}

function Upgrades.BestArmorType(classFile, level)
	for _, entry in ipairs(ARMOR_BY_CLASS[classFile] or {}) do
		if level >= entry[2] then
			return "ARMOR:" .. entry[1]
		end
	end
	return "ANY"
end

-- Stat keys as returned by C_Item.GetItemStats (global string names).
Upgrades.STATS = {
	"ITEM_MOD_STRENGTH_SHORT",
	"ITEM_MOD_AGILITY_SHORT",
	"ITEM_MOD_STAMINA_SHORT",
	"ITEM_MOD_INTELLECT_SHORT",
	"ITEM_MOD_SPIRIT_SHORT",
	"RESISTANCE0_NAME",
	"ITEM_MOD_ATTACK_POWER_SHORT",
	"ITEM_MOD_SPELL_POWER_SHORT",
	"ITEM_MOD_CRIT_RATING_SHORT",
	"ITEM_MOD_HIT_RATING_SHORT",
	"ITEM_MOD_MANA_REGENERATION_SHORT",
	"ITEM_MOD_DEFENSE_SKILL_RATING_SHORT",
	"RESISTANCE2_NAME",
	"RESISTANCE3_NAME",
	"RESISTANCE4_NAME",
	"RESISTANCE5_NAME",
	"RESISTANCE6_NAME",
}

function Upgrades.MatchesType(info, itemType)
	if itemType == "ANY" then
		return info.classID == ITEM_CLASS_ARMOR or info.classID == ITEM_CLASS_WEAPON
	elseif itemType == "WEAPON" then
		return info.classID == ITEM_CLASS_WEAPON
	end
	local sub = tonumber(itemType:match("^ARMOR:(%d+)$"))
	return info.classID == ITEM_CLASS_ARMOR and info.subclassID == sub
end

function Upgrades.Score(stats, favStats)
	local score = 0
	if stats then
		for _, key in ipairs(favStats) do
			score = score + (stats[key] or 0)
		end
	end
	return score
end

--[[
opts = { itemType, slot (0 = all), favStats = {keys}, level, levelAhead,
         showBoP, showAll }
api  = { itemIDs() -> array, info(itemID) -> table | nil (still loading),
         stats(link) -> table, equipped(slot) -> link | nil,
         itemLevel(link) -> number }
Returns results (sorted best first), pendingCount.
result = { itemID, info, slot, delta, ilvlDelta, equippedLink, bop }
]]
function Upgrades.Find(opts, api)
	local results, pending = {}, 0
	local equippedCache = {}
	local function equippedFor(slot)
		local cached = equippedCache[slot]
		if not cached then
			local link = api.equipped(slot)
			cached = {
				link = link,
				score = link and Upgrades.Score(api.stats(link), opts.favStats) or 0,
				ilvl = link and api.itemLevel(link) or 0,
			}
			equippedCache[slot] = cached
		end
		return cached
	end

	for _, itemID in ipairs(api.itemIDs()) do
		local info = api.info(itemID)
		if not info then
			pending = pending + 1
		else
			local slots = Upgrades.SLOTS_BY_EQUIPLOC[info.equipLoc or ""]
			local bop = info.bindType == BIND_ON_PICKUP
			local ok = slots ~= nil
				and Upgrades.MatchesType(info, opts.itemType)
				and (opts.slot == 0 or ns.Util.Contains(slots, opts.slot))
				and (info.minLevel or 0) <= opts.level + (opts.levelAhead or 0)
				and (opts.showBoP or not bop)
			if ok then
				-- Rings and trinkets: replace the weaker of the two.
				local target
				for _, slot in ipairs(slots) do
					local eq = equippedFor(slot)
					if not target or eq.score < target.score or (eq.score == target.score and eq.ilvl < target.ilvl) then
						target = eq
						target.slot = slot
					end
				end
				local score = Upgrades.Score(api.stats(info.link), opts.favStats)
				local delta = score - target.score
				local ilvlDelta = (info.itemLevel or 0) - target.ilvl
				if opts.showAll or delta > 0 or (delta == 0 and score > 0 and ilvlDelta > 0) then
					results[#results + 1] = {
						itemID = itemID, info = info, slot = target.slot,
						delta = delta, ilvlDelta = ilvlDelta,
						equippedLink = target.link, bop = bop,
					}
				end
			end
		end
	end

	table.sort(results, function(a, b)
		if a.delta ~= b.delta then return a.delta > b.delta end
		if a.ilvlDelta ~= b.ilvlDelta then return a.ilvlDelta > b.ilvlDelta end
		return (a.info.name or "") < (b.info.name or "")
	end)
	return results, pending
end

-- Real game data source.
function Upgrades.GameAPI()
	local api = {}
	function api.itemIDs()
		ns.Index.Ensure()
		local ids = {}
		for itemID in pairs(ns.Index.byItem) do
			ids[#ids + 1] = itemID
		end
		return ids
	end
	function api.info(itemID)
		local name, link, quality, itemLevel, minLevel, _, _, _, equipLoc, icon, _, classID, subclassID, bindType = C_Item.GetItemInfo(itemID)
		if not name then
			C_Item.RequestLoadItemDataByID(itemID)
			return nil
		end
		return {
			name = name, link = link, quality = quality, itemLevel = itemLevel, minLevel = minLevel,
			equipLoc = equipLoc, icon = icon, classID = classID, subclassID = subclassID, bindType = bindType,
		}
	end
	function api.stats(link)
		return C_Item.GetItemStats(link) or {}
	end
	function api.equipped(slot)
		return GetInventoryItemLink("player", slot)
	end
	function api.itemLevel(link)
		local ilvl = C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)
		if not ilvl then
			ilvl = select(4, C_Item.GetItemInfo(link))
		end
		return ilvl or 0
	end
	return api
end
