--[[
Recipe costs from Auctionator (optional): what the reagents of a recipe
cost and what the crafted item sells for in the auction house. Only
Auctionator's public API (Auctionator.API.v1) is used; without Auctionator
nothing is shown.

A reagent's unit price:
  1. reagents vendors sell (thread, dye, flux, vials, spices, ...): the full
     vendor price from the table below, without reputation discount, so
     everyone sees the same cost
  2. other items Auctionator saw at a vendor without a stock limit: that
     price (Auctionator remembers the merchant windows it saw)
  3. the price of Auctionator's last auction house scan
Optional reagents do not count toward the cost.
]]
local _, ns = ...

local Prices = {}
ns.Prices = Prices

Prices.CALLER = "Guild Tradebook" -- Auctionator names the caller in its errors

-- Full vendor price in copper per item of reagents vendors sell. Source:
-- Wowhead Classic item data ("buyprice", sold by a vendor), 2026-11-16.
Prices.VENDOR = {
	-- thread
	[2320] = 10, [2321] = 100, [4291] = 500, [8343] = 2000, [14341] = 5000,
	-- dye and bleach
	[2324] = 25, [2325] = 1000, [2604] = 50, [2605] = 100, [4340] = 350, [4341] = 500,
	[4342] = 2500, [6260] = 50, [6261] = 1000, [10290] = 2500,
	-- leatherworking, blacksmithing, engineering, enchanting
	[4289] = 50, [2880] = 100, [3466] = 2000, [18567] = 150000, [3857] = 500,
	[4399] = 200, [4400] = 2000, [4470] = 38, [4471] = 135, [6217] = 124,
	[10647] = 2000, [10648] = 500, [11291] = 4500,
	-- vials and poison reagents
	[3371] = 20, [3372] = 200, [8925] = 2500, [18256] = 30000,
	[2928] = 20, [2930] = 50, [5173] = 100, [8923] = 200, [8924] = 100, [5140] = 25,
	-- cooking
	[159] = 25, [1179] = 125, [1205] = 500, [2596] = 120, [2665] = 20, [2678] = 10,
	[2692] = 40, [3713] = 160, [17194] = 10, [17196] = 50,
	-- fishing
	[6530] = 100, [6529] = 50, [6532] = 250,
}

local function api()
	local a = Auctionator
	return type(a) == "table" and type(a.API) == "table" and a.API.v1 or nil
end

function Prices.Available()
	local v1 = api()
	return type(v1) == "table" and type(v1.GetAuctionPriceByItemID) == "function"
end

-- A price in copper from one of Auctionator's lookups, or nil. A failing
-- call (a changed Auctionator) counts as no price.
local function lookup(name, itemID)
	local v1 = api()
	local fn = type(v1) == "table" and v1[name]
	if type(fn) ~= "function" then return nil end
	local ok, price = pcall(fn, Prices.CALLER, itemID)
	if ok and type(price) == "number" and price > 0 then return price end
	return nil
end

-- Unit price of an item in copper and where it comes from ("vendor" or
-- "auction"), or nil.
function Prices.Unit(itemID)
	local full = Prices.VENDOR[itemID]
	if full then return full, "vendor" end
	local vendor = lookup("GetVendorPriceByItemID", itemID)
	if vendor then return vendor, "vendor" end
	local auction = lookup("GetAuctionPriceByItemID", itemID)
	if auction then return auction, "auction" end
	return nil
end

-- Auction house price of one item in copper, or nil.
function Prices.Auction(itemID)
	return lookup("GetAuctionPriceByItemID", itemID)
end

--[[
Pure core.
  reagents = { {itemID, quantity, optional(0/1)}, ... }  (recipe facts)
  crafts   = number of crafts
  unitFn(itemID) -> copper per item or nil
Returns the cost in copper of the required reagents that have a price, and
the number of required reagents without one.
]]
function Prices.Cost(reagents, crafts, unitFn)
	local total, unpriced = 0, 0
	for _, r in ipairs(reagents) do
		if r[3] ~= 1 then
			local unit = unitFn(r[1])
			if unit then
				total = total + unit * r[2] * crafts
			else
				unpriced = unpriced + 1
			end
		end
	end
	return math.floor(total + 0.5), unpriced
end

-- "1g 20s 5c" (with the game's coin icons where it has them).
function Prices.Format(copper)
	copper = math.floor(copper + 0.5)
	if GetMoneyString then
		local ok, text = pcall(GetMoneyString, copper, true)
		if ok and type(text) == "string" then return text end
	end
	local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	local parts = {}
	if gold > 0 then parts[#parts + 1] = ("|cffffd700%dg|r"):format(gold) end
	if silver > 0 then parts[#parts + 1] = ("|cffc7c7cf%ds|r"):format(silver) end
	if rest > 0 or #parts == 0 then parts[#parts + 1] = ("|cffeda55f%dc|r"):format(rest) end
	return table.concat(parts, " ")
end
