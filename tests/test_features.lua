local H = ...
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

local ns = H.LoadPure()
local Store, Reagents, Wishlist, Chat = ns.Store, ns.Reagents, ns.Wishlist, ns.ChatResponder

print("Features")

-- Cooldowns ---------------------------------------------------------------------

local function own()
	return { guid = "Player-1-0000000A", ver = 1, seq = 0, profs = { [171] = { rank = 300, maxRank = 300, recipes = { [17187] = 12360 } } } }
end

test("cooldowns: new, drift, ready", function()
	local o = own()
	truthy(Store.ApplyCooldowns(o, 171, { [17187] = 86400 }, 1000), "new cooldown")
	eq(o.profs[171].cds[17187], 87400)
	falsy(Store.ApplyCooldowns(o, 171, { [17187] = 86340 }, 1070), "same cooldown read a minute later")
	truthy(Store.ApplyCooldowns(o, 171, { [17187] = 0 }, 2000), "ready early (reset) is a change")
	eq(o.profs[171].cds[17187], 0)
	falsy(Store.ApplyCooldowns(o, 171, { [17187] = 0 }, 3000), "still ready")
end)

test("cooldowns: expired readyAt counts as ready, no change", function()
	local o = own()
	Store.ApplyCooldowns(o, 171, { [17187] = 100 }, 1000)
	falsy(Store.ApplyCooldowns(o, 171, { [17187] = 0 }, 5000))
end)

test("cooldowns travel in the wire format and the hash", function()
	local o = own()
	Store.Rehash(o)
	local before = o.h
	Store.ApplyCooldowns(o, 171, { [17187] = 600 }, 1000)
	Store.Rehash(o)
	truthy(o.h ~= before, "hash covers cooldowns")
	local back = assert(Store.FromWire(H.DeepCopy(Store.ToWire(o))))
	eq(back.profs[171].cds[17187], 1600)
	eq(back.h, o.h)
end)

test("cooldowns reset with a relearned profession", function()
	local o = own()
	Store.ApplyCooldowns(o, 171, { [17187] = 600 }, 1000)
	Store.ReconcileProfessions(o, { [171] = { rank = 1, maxRank = 75 } }, true)
	eq(o.profs[171].cds, nil)
end)

-- Secret values -------------------------------------------------------------------

local function isSecretWith(globals)
	return H.LoadPure(globals).Util.IsSecret
end

test("secret values: the game's check decides", function()
	local isSecret = isSecretWith({ issecretvalue = function(v) return v == H.SECRET end })
	truthy(isSecret(H.SECRET))
	truthy(isSecret("text", nil, H.SECRET), "any argument counts")
	falsy(isSecret("text", nil, 5))
end)

test("secret values: no check on this client", function()
	falsy(isSecretWith({})(H.SECRET))
end)

test("secret values: a check that refuses our call falls back to the other", function()
	local isSecret = isSecretWith({
		issecretvalue = function() error("not allowed for tainted callers") end,
		canaccessvalue = function(v) return v ~= H.SECRET end,
	})
	truthy(isSecret(H.SECRET))
	falsy(isSecret("text"))
end)

test("secret values: no working check is no error and nothing is secret", function()
	local refuse = function() error("not allowed for tainted callers") end
	falsy(isSecretWith({ issecretvalue = refuse, canaccessvalue = refuse })(H.SECRET))
end)

test("secret values: a value the working check raises on counts as secret", function()
	local isSecret = isSecretWith({ issecretvalue = function(v)
		if v == H.SECRET then error("bad value") end
		return false
	end })
	truthy(isSecret(H.SECRET))
	falsy(isSecret("text"))
end)

-- Reagents ------------------------------------------------------------------------

test("reagent check: have, need, missing, optional", function()
	local reagents = { { 14047, 6, 0 }, { 14341, 1, 0 }, { 8170, 2, 1 } }
	local owned = { [14047] = 20, [14341] = 0 }
	local rows, missing = Reagents.Check(reagents, 3, function(id) return owned[id] end)
	eq(rows[1].need, 18)
	eq(rows[1].have, 20)
	eq(#missing, 1, "optional reagent never missing")
	eq(missing[1].itemID, 14341)
	eq(missing[1].count, 3)
end)

-- Prices (Auctionator) -------------------------------------------------------------

test("prices: cost of the required reagents, unpriced ones counted", function()
	local reagents = { { 14047, 6, 0 }, { 14341, 1, 0 }, { 8170, 2, 1 }, { 7078, 1, 0 } }
	local unit = { [14047] = 250, [14341] = 5000, [8170] = 999 }
	local cost, unpriced = ns.Prices.Cost(reagents, 3, function(id) return unit[id] end)
	eq(cost, 6 * 3 * 250 + 3 * 5000, "optional reagent not counted")
	eq(unpriced, 1, "the reagent without a price")
	eq(select(1, ns.Prices.Cost(reagents, 1, function() return 2.5 end)), 20, "vendor prices per item may be fractions (8 x 2.5)")
end)

test("prices: full vendor price, then Auctionator's vendor and auction prices, errors are no price", function()
	falsy(ns.Prices.Available(), "no Auctionator here")
	eq(ns.Prices.Unit(2589), nil)
	local calls = {}
	local priced = H.LoadPure({ Auctionator = { API = { v1 = {
		GetVendorPriceByItemID = function(caller, id)
			calls[#calls + 1] = caller
			return ({ [2321] = 90, [99001] = 10 })[id]
		end,
		GetAuctionPriceByItemID = function(_, id)
			if id == 666 then error("changed API") end
			return ({ [2321] = 300, [99001] = 40, [2589] = 1500 })[id]
		end,
	} } } }).Prices
	truthy(priced.Available())
	local price, source = priced.Unit(2321)
	eq(price, 100, "Fine Thread: the full vendor price, not Auctionator's 90 (10% reputation discount)")
	eq(source, "vendor")
	price, source = priced.Unit(99001)
	eq(price, 10)
	eq(source, "vendor", "a vendor Auctionator saw beats the auction house")
	price, source = priced.Unit(2589)
	eq(price, 1500)
	eq(source, "auction")
	eq(priced.Unit(666), nil, "an error in Auctionator is no price")
	eq(priced.Unit(1), nil)
	eq(priced.Auction(99001), 40, "the crafted item's value is always the auction price")
	eq(calls[1], "Guild Tradebook", "Auctionator wants a caller name")
end)

test("prices: auction house search terms leave out vendor goods, optional and unnamed reagents", function()
	local rows = {
		{ itemID = 2589, need = 6, have = 2 }, -- short by 4
		{ itemID = 2321, need = 2, have = 0 }, -- Fine Thread: vendor
		{ itemID = 2592, need = 3, have = 5 }, -- enough
		{ itemID = 8170, need = 1, have = 0, optional = true },
		{ itemID = 4306, need = 1, have = 0 }, -- name not loaded yet
		{ itemID = 7777, need = 1, have = 0 }, -- name Auctionator refuses
	}
	local names = { [2589] = "Linen Cloth", [2321] = "Fine Thread", [2592] = "Wool Cloth", [8170] = "Rugged Leather",
		[7777] = 'Bad "Name"' }
	local terms = ns.Prices.SearchTerms(rows, ns.Prices.Unit, function(id) return names[id] end)
	eq(#terms, 2)
	eq(terms[1].searchString, "Linen Cloth")
	truthy(terms[1].isExact)
	eq(terms[1].quantity, 4, "the missing amount")
	eq(terms[2].searchString, "Wool Cloth")
	eq(terms[2].quantity, nil, "enough in the bags: no amount")
end)

test("prices: the search goes to Auctionator only while the auction house is open", function()
	falsy(ns.Prices.CanSearch(), "no Auctionator")
	falsy(ns.Prices.Search({ { searchString = "Linen Cloth" } }))
	local got, open = {}, false
	local env = { AuctionFrame = { IsShown = function() return open end }, Auctionator = { API = { v1 = {
		GetAuctionPriceByItemID = function() return nil end,
		MultiSearchAdvanced = function(caller, terms)
			got.caller, got.terms = caller, terms
			if terms[1].searchString == "boom" then error("Auction house is not open") end
		end,
	} } } }
	local priced = H.LoadPure(env).Prices
	falsy(priced.CanSearch(), "auction house closed")
	open = true
	truthy(priced.CanSearch(), "auction house open")
	open = false
	falsy(priced.CanSearch())
	falsy(priced.Search({}), "nothing to search")
	truthy(priced.Search({ { searchString = "Linen Cloth", isExact = true } }))
	eq(got.caller, "Guild Tradebook")
	eq(got.terms[1].searchString, "Linen Cloth")
	falsy(priced.Search({ { searchString = "boom" } }), "an error in Auctionator is a failed search")
end)

test("prices: money text without the game's formatter", function()
	eq(ns.Prices.Format(12345), "|cffffd7001g|r |cffc7c7cf23s|r |cffeda55f45c|r")
	eq(ns.Prices.Format(20000), "|cffffd7002g|r")
	eq(ns.Prices.Format(0), "|cffeda55f0c|r")
	eq(ns.Prices.Format(99.6), "|cffc7c7cf1s|r", "rounded to whole copper")
end)

-- Wishlist ------------------------------------------------------------------------

test("wishlist matches only members who just came online", function()
	local crafters = { [1] = { "A", "B" }, [2] = { "B" }, [3] = { "C" } }
	local m = Wishlist.Matches({ A = true }, { A = true, B = true }, { [1] = true, [2] = true, [3] = true },
		function(rid) return crafters[rid] end)
	falsy(m.A, "A was already online")
	eq(#m.B, 2)
	falsy(m.C, "C is offline")
end)

-- !craft ----------------------------------------------------------------------------

test("!craft parsing", function()
	eq(Chat.ParseQuery("!craft Mooncloth Bag"), "Mooncloth Bag")
	eq(Chat.ParseQuery("!CRAFT   runecloth  "), "runecloth")
	eq(Chat.ParseQuery("!herstellen Mondstofftasche"), "Mondstofftasche")
	eq(Chat.ParseQuery("!craft ab"), nil, "too short")
	eq(Chat.ParseQuery("!crafting bag"), nil)
	eq(Chat.ParseQuery("hello !craft bag"), nil)
end)

test("!craft links: item, enchant and recipe links, at most three", function()
	local q = Chat.ParseQuery("!craft |cff1eff00|Hitem:2568::::::::60:::::|h[Brauner Leinenwams]|h|r und |cffffd000|Henchant:7457|h[Verzauberung]|h|r")
	local links = Chat.ParseLinks(q)
	eq(#links, 2)
	eq(links[1].kind, "item")
	eq(links[1].id, 2568)
	eq(links[1].name, "Brauner Leinenwams")
	eq(links[2].kind, "enchant")
	eq(links[2].id, 7457)
	eq(#Chat.ParseLinks("plain text"), 0)
	local many = ("|Hitem:1|h[a]|h "):rep(5)
	eq(#Chat.ParseLinks(many), 3)
end)

local function crafters(map)
	return function(rid) return map[rid] or {} end
end

test("!craft answer: exact match wins, online marked", function()
	local results = { { recipeID = 1, name = "Mooncloth" }, { recipeID = 2, name = "Mooncloth Bag" } }
	local text = Chat.BuildAnswer("mooncloth bag", results, crafters({
		[2] = { { name = "Anna-Realm", online = true }, { name = "Bert-Realm", online = false } },
	}))
	eq(text, "[Guild Tradebook] Mooncloth Bag: Anna*, Bert (* = online)")
end)

test("!craft answer: none, too many, long lists", function()
	eq(Chat.BuildAnswer("xyz", {}, crafters({})), '[Guild Tradebook] Nobody in the guild can craft "xyz".')
	local many = {}
	for i = 1, 5 do many[i] = { recipeID = i, name = "Bag " .. i } end
	truthy(Chat.BuildAnswer("bag", many, crafters({})):find("5 matches", 1, true))
	local list = {}
	for i = 1, 6 do list[i] = { name = "M" .. i .. "-Realm" } end
	eq(Chat.BuildAnswer("bag 1", { many[1] }, crafters({ [1] = list })), "[Guild Tradebook] Bag 1: M1, M2, M3, +3")
	local long = { { recipeID = 1, name = string.rep("x", 300) } }
	eq(#Chat.BuildAnswer(long[1].name, long, crafters({})), Chat.MAX_LENGTH)
end)
