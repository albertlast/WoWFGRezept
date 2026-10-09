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
