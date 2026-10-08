local H = ...
local test, eq, truthy = H.test, H.eq, H.truthy

local ns = H.LoadPure()
local U = ns.Upgrades

local items = {
	[1] = { name = "Robe A", link = "l1", itemLevel = 30, minLevel = 25, equipLoc = "INVTYPE_ROBE", classID = 4, subclassID = 1, bindType = 2 },
	[2] = { name = "Robe B", link = "l2", itemLevel = 40, minLevel = 35, equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 1, bindType = 2 },
	[3] = { name = "Leather Vest", link = "l3", itemLevel = 40, minLevel = 30, equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 2, bindType = 2 },
	[4] = { name = "BoP Robe", link = "l4", itemLevel = 45, minLevel = 30, equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 1, bindType = 1 },
	[5] = { name = "Ring", link = "l5", itemLevel = 30, minLevel = 20, equipLoc = "INVTYPE_FINGER", classID = 4, subclassID = 0, bindType = 2 },
	[6] = { name = "Bag", link = "l6", itemLevel = 30, minLevel = 0, equipLoc = "INVTYPE_BAG", classID = 1, subclassID = 0, bindType = 0 },
}
local stats = {
	l1 = { ITEM_MOD_INTELLECT_SHORT = 8 },
	l2 = { ITEM_MOD_INTELLECT_SHORT = 14, ITEM_MOD_STAMINA_SHORT = 5 },
	l3 = { ITEM_MOD_AGILITY_SHORT = 12 },
	l4 = { ITEM_MOD_INTELLECT_SHORT = 20 },
	l5 = { ITEM_MOD_INTELLECT_SHORT = 4 },
	eqChest = { ITEM_MOD_INTELLECT_SHORT = 10 },
	eqRing1 = { ITEM_MOD_INTELLECT_SHORT = 6 },
	eqRing2 = { ITEM_MOD_INTELLECT_SHORT = 2 },
}

local function api(pendingIDs)
	return {
		itemIDs = function() return { 1, 2, 3, 4, 5, 6 } end,
		info = function(id) if pendingIDs and pendingIDs[id] then return nil end return items[id] end,
		stats = function(link) return stats[link] or {} end,
		equipped = function(slot)
			if slot == 5 then return "eqChest" elseif slot == 11 then return "eqRing1" elseif slot == 12 then return "eqRing2" end
		end,
		itemLevel = function() return 20 end,
	}
end

local function opts(o)
	o.favStats = o.favStats or { "ITEM_MOD_INTELLECT_SHORT" }
	o.level = o.level or 40
	o.slot = o.slot or 0
	return o
end

print("Upgrades")

test("cloth chest with intellect beats equipped", function()
	local results = U.Find(opts({ itemType = "ARMOR:1", slot = 5 }), api())
	eq(#results, 1)
	eq(results[1].itemID, 2)
	eq(results[1].delta, 4)
end)

test("type filter excludes other armor types", function()
	local results = U.Find(opts({ itemType = "ARMOR:1", slot = 5, favStats = { "ITEM_MOD_AGILITY_SHORT" } }), api())
	eq(#results, 0)
	results = U.Find(opts({ itemType = "ARMOR:2", slot = 5, favStats = { "ITEM_MOD_AGILITY_SHORT" } }), api())
	eq(results[1].itemID, 3)
end)

test("level filter and look-ahead", function()
	local results = U.Find(opts({ itemType = "ARMOR:1", slot = 5, level = 30 }), api())
	eq(#results, 0, "robe B needs 35")
	results = U.Find(opts({ itemType = "ARMOR:1", slot = 5, level = 30, levelAhead = 5 }), api())
	eq(results[1].itemID, 2)
end)

test("bind on pickup is hidden unless requested", function()
	local results = U.Find(opts({ itemType = "ARMOR:1", slot = 5 }), api())
	for _, r in ipairs(results) do truthy(r.itemID ~= 4) end
	results = U.Find(opts({ itemType = "ARMOR:1", slot = 5, showBoP = true }), api())
	eq(results[1].itemID, 4)
	truthy(results[1].bop)
end)

test("rings compare against the weaker equipped ring", function()
	local results = U.Find(opts({ itemType = "ARMOR:0", slot = 0 }), api())
	eq(#results, 1)
	eq(results[1].slot, 12)
	eq(results[1].delta, 2)
end)

test("items still loading are counted, non-equipment ignored", function()
	local results, pending = U.Find(opts({ itemType = "ANY" }), api({ [2] = true }))
	eq(pending, 1)
	for _, r in ipairs(results) do truthy(r.itemID ~= 6 and r.itemID ~= 2) end
end)

test("best armor type by class and level", function()
	eq(U.BestArmorType("WARRIOR", 39), "ARMOR:3")
	eq(U.BestArmorType("WARRIOR", 40), "ARMOR:4")
	eq(U.BestArmorType("MAGE", 10), "ARMOR:1")
end)
