local H = ...
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

local TAILORING, ALCHEMY, COOKING = 197, 171, 185

local function guid(n)
	return ("Player-1-%08X"):format(n)
end

local function tailoring(rank, recipes)
	return { rank = rank, maxRank = 300, name = "Tailoring", recipes = recipes }
end

-- Every online client holds exactly the owner's current version of `owner`.
local function assertConverged(world, owner, msg)
	local truth = world:OwnerRecord(owner)
	assert(truth, "owner has no record")
	for g, client in pairs(world.online) do
		local r = client:Record(owner)
		assert(r, (msg or "") .. ": " .. client.char.name .. " has no record of " .. owner)
		if r.ver ~= truth.ver or r.seq ~= truth.seq or r.h ~= truth.h then
			error(("%s: %s holds %d/%d, owner has %d/%d"):format(msg or "not converged", client.char.name,
				r.ver, r.seq, truth.ver, truth.seq), 2)
		end
	end
end

-- !craft answers whispered to `to` ("Name-Realm").
local function craftAnswers(world, to)
	local list = {}
	for _, w in ipairs(world.whispers) do
		if w.to == to and w.text:find("[Guild Tradebook]", 1, true) then list[#list + 1] = w.text end
	end
	return list
end

local function threeMembers(opts)
	math.randomseed(42)
	local world = H.NewWorld(opts)
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = { [TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Bert", profs = { [COOKING] = { rank = 50, maxRank = 75, name = "Cooking", secondary = true, recipes = { [2538] = 2679 } } } })
	local c = world:AddChar({ guid = guid(3), name = "Cleo" })
	return world, a, b, c
end

print("Simulation")

test("recipes spread to everyone online", function()
	local world, a, b, c = threeMembers()
	world:Login(b.guid)
	world:Login(c.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	assertConverged(world, a.guid, "after scan")
	local rb = world.online[b.guid]:Record(a.guid)
	eq(rb.profs[TAILORING].recipes[3914], 2568)
	eq(world.online[c.guid].env.GuildTradebookDB.recipeFacts[3914].item, 2568, "fact learned from record")
end)

test("clicking quickly through profession tabs scans every profession", function()
	math.randomseed(11)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568 }),
		[ALCHEMY] = { rank = 80, maxRank = 150, name = "Alchemy", recipes = { [2330] = 118 } },
	} })
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(0.2)
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(30)
	local own = ca:Record(a.guid)
	truthy(own.profs[TAILORING].recipes, "tailoring scanned")
	truthy(own.profs[ALCHEMY].recipes, "alchemy scanned")
end)

test("every profession with a crafting window is shared, gathering ones are not", function()
	math.randomseed(12)
	local world = H.NewWorld()
	local FISHING, HERBALISM = 356, 182
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = {
		[FISHING] = { rank = 100, maxRank = 150, name = "Fishing", secondary = true, recipes = { [9001] = 6533 } },
		[HERBALISM] = { rank = 100, maxRank = 150, name = "Herbalism", noCraftingUI = true },
		[COOKING] = { rank = 50, maxRank = 75, name = "Cooking", secondary = true, recipes = { [2538] = 2679 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(FISHING)
	world:Run(5)
	ca:OpenTradeSkill(COOKING)
	world:Run(120)
	local r = world.online[b.guid]:Record(a.guid)
	truthy(r.profs[FISHING] and r.profs[FISHING].recipes[9001] == 6533, "fishing recipes shared")
	truthy(r.profs[COOKING] and r.profs[COOKING].recipes[2538], "cooking shared")
	eq(r.profs[HERBALISM], nil, "herbalism has no crafting window")
end)

test("primary recipe changes go out fast, secondary ones are batched", function()
	math.randomseed(13)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568 }),
		[COOKING] = { rank = 50, maxRank = 75, name = "Cooking", secondary = true, recipes = { [2538] = 2679 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(2)
	ca:OpenTradeSkill(COOKING)
	world:Run(200)
	local cb = world.online[b.guid]
	truthy(cb:Record(a.guid).profs[TAILORING].primary, "primary flag shared")
	eq(cb:Record(a.guid).profs[COOKING].primary, nil)

	a.profs[COOKING].recipes[2539] = 2680
	ca:Fire("NEW_RECIPE_LEARNED", 2539)
	world:Run(20)
	eq(cb:Record(a.guid).profs[COOKING].recipes[2539], nil, "secondary change not sent yet")
	world:Run(60)
	eq(cb:Record(a.guid).profs[COOKING].recipes[2539], 2680, "secondary change sent in the batch")

	a.profs[TAILORING].recipes[3915] = 2569
	ca:Fire("NEW_RECIPE_LEARNED", 3915)
	world:Run(10)
	eq(cb:Record(a.guid).profs[TAILORING].recipes[3915], 2569, "primary change sent within seconds")
end)

test("cooldowns reach the guild and show who is ready", function()
	math.randomseed(21)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = {
		[ALCHEMY] = { rank = 300, maxRank = 300, name = "Alchemy", recipes = { [17187] = 12360, [2330] = 118 } },
	}, cooldowns = { [17187] = 86400 } })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(150)
	local cb = world.online[b.guid]
	local readyAt = cb:Record(a.guid).profs[ALCHEMY].cds[17187]
	truthy(readyAt and readyAt > world.clock.t + 80000, "B knows when the transmute is ready")
	local c = cb.ns.Index.Crafters(17187)[1]
	falsy(c.ready, "on cooldown")
	eq(cb.ns.Index.Crafters(2330)[1].readyAt, nil, "normal recipe has no cooldown")

	-- A day later the cooldown is over, without any new message.
	world:Run(86400)
	truthy(cb.ns.Index.Crafters(17187)[1].ready, "ready after the cooldown")
end)

test("the global cooldown after crafting is no recipe cooldown; false entries of older versions go", function()
	math.randomseed(22)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569 }),
		[ALCHEMY] = { rank = 300, maxRank = 300, name = "Alchemy", recipes = { [17187] = 12360 } },
	}, cooldowns = { [3914] = 1.5, [3915] = 1.5 } }) -- right after a craft: every recipe reports 1.5 s
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	local cb = world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(150)
	falsy(cb:Record(a.guid).profs[TAILORING].cds, "no cooldown entries")
	eq(cb.ns.Index.Crafters(3914)[1].readyAt, nil, "so no \"ready\" tag")

	-- A record from an older version marked every recipe: the next scan cleans it.
	ca:Record(a.guid).profs[TAILORING].cds = { [3914] = 0, [3915] = 0 }
	a.cooldowns = {}
	ca:OpenTradeSkill(TAILORING)
	world:Run(150)
	falsy(ca:Record(a.guid).profs[TAILORING].cds, "cleaned in the own record")
	falsy(cb:Record(a.guid).profs[TAILORING].cds, "and in the guild's copy")

	-- A real cooldown recipe under the global cooldown counts as ready.
	a.cooldowns = { [17187] = 86400 }
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(150)
	truthy(cb:Record(a.guid).profs[ALCHEMY].cds[17187] > world.clock.t, "on cooldown")
	a.cooldowns = { [17187] = 1.5 }
	ca:OpenTradeSkill(TAILORING)
	world:Run(5)
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(150)
	eq(cb:Record(a.guid).profs[ALCHEMY].cds[17187], 0, "ready")
end)

test("cooldowns not shared (option): the guild sees the crafter, never as ready; real times come back when turned on", function()
	math.randomseed(26)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", account = "acc1", profs = {
		[ALCHEMY] = { rank = 300, maxRank = 300, name = "Alchemy", recipes = { [17187] = 12360, [2330] = 118 } },
	}, cooldowns = { [17187] = 86400 } })
	local alt = world:AddChar({ guid = guid(3), name = "Alty", account = "acc1", profs = {
		[ALCHEMY] = { rank = 300, maxRank = 300, name = "Alchemy", recipes = { [17187] = 12360 } },
	}, cooldowns = { [17187] = 3600 } })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	world:Login(b.guid)
	local calt = world:Login(alt.guid)
	world:Run(60)
	calt:OpenTradeSkill(ALCHEMY)
	world:Run(150)
	world:Logout(alt.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(150)
	local cb = world.online[b.guid]
	local Store = cb.ns.Store
	local shared = cb:Record(a.guid).profs[ALCHEMY].cds[17187]
	truthy(shared and not Store.IsHiddenCooldown(shared), "shared by default")

	ca.env.GuildTradebookDB.options.shareCooldowns = false
	ca.ns.Scanner.ApplyCooldownSharing()
	world:Run(90)
	truthy(Store.IsHiddenCooldown(cb:Record(a.guid).profs[ALCHEMY].cds[17187]), "the guild's copy: not shared")
	truthy(Store.IsHiddenCooldown(cb:Record(alt.guid).profs[ALCHEMY].cds[17187]), "for the account's alts too")
	eq(cb:Record(a.guid).profs[ALCHEMY].cds[2330], nil, "a normal recipe stays without cooldown")
	-- A day later, when the real cooldown would be over: still never ready.
	world:Run(86400 + 3600)
	for _, c in ipairs(cb.ns.Index.Crafters(17187)) do
		falsy(c.ready, c.name .. " is never shown as ready")
		truthy(c.cooldownHidden)
	end
	truthy(cb.ns.Index.Crafters(2330)[1].ready, "normal recipes are not affected")
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(150)
	truthy(Store.IsHiddenCooldown(cb:Record(a.guid).profs[ALCHEMY].cds[17187]), "a new scan keeps it hidden")

	ca.env.GuildTradebookDB.options.shareCooldowns = true
	ca.ns.Scanner.ApplyCooldownSharing()
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(150)
	local back = cb:Record(a.guid).profs[ALCHEMY].cds[17187]
	truthy(back and not Store.IsHiddenCooldown(back), "the real time is back after the next scan")
	truthy(back <= world.clock.t + 86400 + 300, "a real time, about a day from the scan")
end)

test("wishlist: notice when a crafter comes online", function()
	math.randomseed(22)
	local world, a, b = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(150)
	world:Logout(a.guid)
	world:Run(300)
	local cb = world.online[b.guid]
	cb.ns.Wishlist.Toggle(3914)
	world.log = {}
	world:Login(a.guid)
	world:Run(30)
	local found = false
	for _, line in ipairs(world.log) do
		if line:find("Bert", 1, true) == 1 and line:find("can craft", 1, true) and line:find("Recipe 3914", 1, true) then
			found = true
		end
	end
	truthy(found, "B was told that Anna can craft the wished recipe")
end)

test("wishlist: notice as soon as sync data shows the crafter's player is online on another character", function()
	math.randomseed(23)
	local world = H.NewWorld()
	local crafter = world:AddChar({ guid = guid(1), name = "Crafty", account = "acc1", profs = { [TAILORING] = tailoring(100, { [3914] = 2568 }) } })
	local main = world:AddChar({ guid = guid(2), name = "Mainy", account = "acc1" })
	local other = world:AddChar({ guid = guid(3), name = "Otto" })
	local cc = world:Login(crafter.guid)
	world:Run(60)
	cc:OpenTradeSkill(TAILORING)
	world:Run(120)
	local co = world:Login(other.guid)
	world:Run(180)
	world:Logout(crafter.guid)
	world:Run(150)
	co.ns.Wishlist.Toggle(3914)
	world.log = {}
	-- Otto has never seen Mainy: only Mainy's record links it to Crafty.
	world:Login(main.guid)
	local linkedAt, noticedAt
	for _ = 1, 300 do
		world:Run(1)
		local rm = co:Record(main.guid)
		if not linkedAt and rm and rm.player and rm.player == co:Record(crafter.guid).player then
			linkedAt = world.clock.t
		end
		for _, line in ipairs(world.log) do
			if not noticedAt and line:find("Otto", 1, true) == 1 and line:find("can craft", 1, true) then
				noticedAt = world.clock.t
			end
		end
		if noticedAt then break end
	end
	truthy(linkedAt, "Mainy's record arrived")
	truthy(noticedAt, "Otto was told")
	truthy(noticedAt - linkedAt <= 5, ("told %d s after the data arrived, not at the next roster update"):format(noticedAt - linkedAt))
end)

test("wishlist: notice and sound right at login, not at the next roster refresh; gone at logout", function()
	math.randomseed(24)
	local world, a, b = threeMembers({ slowRoster = true })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(150)
	world:Logout(a.guid)
	local cb = world.online[b.guid]
	world:Run(5)
	eq(#cb.ns.Wishlist.ReadyNow(), 0, "offline at once (wishlist still empty)")
	cb.ns.Wishlist.Toggle(3914)
	world:Run(300)
	eq(#cb.ns.Wishlist.ReadyNow(), 0, "Anna is offline")
	world.log = {}
	cb.sounds = {}
	world:Login(a.guid)
	world:Run(5)
	local found = false
	for _, line in ipairs(world.log) do
		if line:find("Bert", 1, true) == 1 and line:find("can craft", 1, true) then found = true end
	end
	truthy(found, "B was told within 5 s")
	eq(#cb.sounds, 1, "one sound")
	eq(cb.sounds[1].channel, "Master")
	eq(#cb.ns.Wishlist.ReadyNow(), 1, "glow on")
	world:Logout(a.guid)
	world:Run(5)
	eq(#cb.ns.Wishlist.ReadyNow(), 0, "glow off within 5 s of the logout")
end)

test("roster: login and logout messages are recognized", function()
	local world = H.NewWorld()
	local c = world:Login(world:AddChar({ guid = guid(1), name = "Anna" }).guid)
	local R = c.ns.Roster
	eq(select(1, R.ParseOnlineMessage("|Hplayer:Jörg Falk|h[Jörg Falk]|h has come online.")), "Jörg Falk")
	eq(select(2, R.ParseOnlineMessage("|Hplayer:Jörg Falk|h[Jörg Falk]|h has come online.")), true)
	eq(select(1, R.ParseOnlineMessage("Jörg Falk has gone offline.")), "Jörg Falk")
	eq(select(2, R.ParseOnlineMessage("Jörg Falk has gone offline.")), false)
	eq(R.ParseOnlineMessage("No player named 'X' is currently playing."), nil)
	eq(R.ParseOnlineMessage(nil), nil)
end)

test("tab switch with a stale recipe list: recipes stay in their profession", function()
	math.randomseed(31)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", staleTabSwitch = true, profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569 }),
		[COOKING] = { rank = 50, maxRank = 75, name = "Cooking", secondary = true, recipes = { [2538] = 2679 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(3)
	ca:OpenTradeSkill(COOKING) -- first read returns the tailoring list
	world:Run(150)
	local own = ca:Record(a.guid)
	eq(own.profs[COOKING].recipes[3914], nil, "tailoring recipe not stored under cooking")
	truthy(own.profs[COOKING].recipes[2538], "cooking recipe stored")
	eq(#world.online[b.guid].ns.Index.Crafters(3914), 1, "Anna listed once")
end)

test("recipes stored under the wrong profession are cleaned up and listed once", function()
	math.randomseed(32)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568 }),
		[COOKING] = { rank = 50, maxRank = 75, name = "Cooking", secondary = true, recipes = { [2538] = 2679 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(3)
	ca:OpenTradeSkill(COOKING)
	world:Run(150)
	-- Damage as written by the previous version: a tailoring recipe under cooking.
	local own = ca:Record(a.guid)
	own.profs[COOKING].recipes[3914] = 2568
	ca.ns.Store.Rehash(own)
	ca.ns.Index.dirty = true
	eq(#ca.ns.Index.Crafters(3914), 1, "listed once even with damaged data")
	ca:OpenTradeSkill(COOKING)
	world:Run(150)
	eq(ca:Record(a.guid).profs[COOKING].recipes[3914], nil, "cleaned up by the next scan")
	assertConverged(world, a.guid, "cleaned record reached the guild")
end)

test("search by crafter", function()
	math.randomseed(33)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = { [TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Bert", profs = { [TAILORING] = tailoring(100, { [3914] = 2568 }) } })
	local ca = world:Login(a.guid)
	local cb = world:Login(b.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	cb:OpenTradeSkill(TAILORING)
	world:Run(150)
	local Index = ca.ns.Index
	eq(#Index.Search("", 0), 2)
	eq(#Index.Search("", 0, a.guid), 2)
	eq(#Index.Search("", 0, b.guid), 1)
	eq(Index.Search("", 0, b.guid)[1].recipeID, 3914)
	eq(#Index.Search("", 197, b.guid), 1, "combines with the profession filter")
end)

test("recipe list hides bind-on-pickup items only others can craft", function()
	math.randomseed(34)
	local world = H.NewWorld()
	world.bindTypes = { [2568] = 1, [2569] = 2 } -- 2570 not loaded yet
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569, [3916] = 2570 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	local ca = world:Login(a.guid)
	local cb = world:Login(b.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(150)
	local function ids(results)
		local out = {}
		for _, r in ipairs(results) do out[#out + 1] = r.recipeID end
		return table.concat(out, ",")
	end
	eq(ids(cb.ns.Index.Search("", 0, nil, true)), "3915,3916", "Bert: Anna's BoP item hidden, unloaded item kept")
	eq(ids(cb.ns.Index.Search("", 0, nil, false)), "3914,3915,3916", "setting off: everything")
	eq(ids(ca.ns.Index.Search("", 0, nil, true)), "3914,3915,3916", "Anna sees her own BoP recipe")
	eq(cb.env.GuildTradebookDB.options.hideForeignBoP, true, "on by default")
end)

test("names: own realm hidden, other realms shown", function()
	local world, a = threeMembers()
	local ca = world:Login(a.guid)
	eq(ca.ns.Util.ShortName("Bert-Realm"), "Bert")
	eq(ca.ns.Util.ShortName("Mira Stein-Realm"), "Mira Stein")
	eq(ca.ns.Util.ShortName("Bert-OtherRealm"), "Bert-OtherRealm")
	eq(ca.ns.Util.ShortName("Bert"), "Bert")
end)

test("offline owner's data is relayed to later logins", function()
	local world, a, b, c = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(a.guid)
	world:Run(10)
	world:Login(c.guid)
	world:Run(120)
	local r = world.online[c.guid]:Record(a.guid)
	truthy(r and r.profs[TAILORING].recipes, "C learned A's recipes from B")
	assertConverged(world, a.guid, "relay")
end)

test("profession switch while a holder is offline: stale copy loses", function()
	local world, a, b, c = threeMembers()
	world:Login(b.guid)
	world:Login(c.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(c.guid)              -- C keeps the tailoring copy
	world:Logout(a.guid)
	world:Run(3600)

	-- A drops tailoring and learns alchemy while C is offline.
	a.profs = { [ALCHEMY] = { rank = 1, maxRank = 75, name = "Alchemy", recipes = { [2330] = 118 } } }
	ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(ALCHEMY)
	world:Run(60)
	world:Logout(a.guid)
	world:Run(3600)

	world:Login(c.guid)               -- comes back with the stale copy
	world:Run(180)
	local r = world.online[c.guid]:Record(a.guid)
	falsy(r.profs[TAILORING], "stale tailoring gone")
	truthy(r.profs[ALCHEMY] and r.profs[ALCHEMY].recipes[2330], "alchemy known")
	assertConverged(world, a.guid, "after switch")
end)

test("stale holder relays old data: it is corrected, not spread", function()
	local world, a, b, c = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	-- C still has an ancient copy from a previous session.
	world:Logout(b.guid)
	world.accounts[c.account] = H.DeepCopy(world.accounts[b.account])
	a.profs[TAILORING].recipes[3916] = 2570
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Login(b.guid)
	world:Login(c.guid)
	world:Run(180)
	assertConverged(world, a.guid, "stale relay corrected")
	truthy(world.online[c.guid]:Record(a.guid).profs[TAILORING].recipes[3916])
end)

test("unlearn and relearn between sessions resets recipes everywhere", function()
	local world, a, b = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(a.guid)
	a.profs[TAILORING] = tailoring(1, {})
	world:Login(a.guid)
	world:Run(120)
	local r = world.online[b.guid]:Record(a.guid)
	eq(r.profs[TAILORING].rank, 1)
	eq(r.profs[TAILORING].recipes, nil, "old recipes not kept")
	assertConverged(world, a.guid, "relearn")
end)

test("lost SavedVariables: owner adopts pool data, then verifies by scanning", function()
	local world, a, b = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(a.guid)
	world.accounts[a.account] = nil   -- WTF folder deleted
	world:Run(600)

	ca = world:Login(a.guid)
	world:Run(180)
	local own = ca:Record(a.guid)
	truthy(own.profs[TAILORING].recipes and own.profs[TAILORING].recipes[3914], "adopted from pool")
	truthy(own.profs[TAILORING].unverified, "marked unverified")
	assertConverged(world, a.guid, "after adoption")

	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	falsy(ca:Record(a.guid).profs[TAILORING].unverified, "verified by scan")
	assertConverged(world, a.guid, "after verification")
end)

test("forged newer copy of a member is overridden when the owner is online", function()
	local world, a, b, c = threeMembers()
	world:Login(b.guid)
	world:Login(c.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	-- B fabricates a copy of A without tailoring, slightly in the future.
	local cb = world.online[b.guid]
	local Store = cb.ns.Store
	local fake = H.DeepCopy(cb:Record(a.guid))
	fake.profs = {}
	fake.ver = math.floor(world.clock.t) + 200
	Store.Rehash(fake)
	cb.ns.Protocol.Send({ t = "R", r = Store.ToWire(fake) }, "GUILD")
	world:Run(120)
	truthy(world.online[c.guid]:Record(a.guid).profs[TAILORING], "owner's truth restored")
	assertConverged(world, a.guid, "after reclaim")
end)

test("former members are hidden and not relayed", function()
	local world, a, b, c = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(a.guid)
	world:RemoveFromGuild(a.guid)
	world:Run(30)
	truthy(world.online[b.guid]:Record(a.guid).goneSince, "hidden on B")
	world:Login(c.guid)
	world:Run(180)
	falsy(world.online[c.guid]:Record(a.guid), "never reached C")
	world:Run(15 * 86400)
	falsy(world.online[b.guid]:Record(a.guid), "deleted after grace period")
end)

test("partitions heal and converge", function()
	local world, a, b, c = threeMembers()
	local d = world:AddChar({ guid = guid(4), name = "Dora", profs = { [ALCHEMY] = { rank = 10, maxRank = 75, name = "Alchemy", recipes = { [2330] = 118 } } } })
	a.partition, b.partition = 1, 1
	c.partition, d.partition = 2, 2
	local ca = world:Login(a.guid)
	world:Login(b.guid)
	world:Login(c.guid)
	local cd = world:Login(d.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	cd:OpenTradeSkill(ALCHEMY)
	world:Run(120)
	falsy(world.online[c.guid]:Record(a.guid) and world.online[c.guid]:Record(a.guid).profs[TAILORING].recipes, "split")
	c.partition, d.partition = 1, 1
	world:Run(8 * 1300) -- periodic pairwise sync rounds with exploration
	assertConverged(world, a.guid, "A after heal")
	assertConverged(world, d.guid, "D after heal")
end)

test("chat lockdown queues messages until allowed", function()
	local world, a, b = threeMembers()
	world:Login(b.guid)
	a.restricted = true
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	local rb = world.online[b.guid]:Record(a.guid)
	falsy(rb and rb.profs[TAILORING] and rb.profs[TAILORING].recipes, "nothing sent while restricted")
	a.restricted = false
	world:Run(60)
	assertConverged(world, a.guid, "after restriction lifted")
end)

test("alts are shared from the account while playing another character", function()
	math.randomseed(7)
	local world = H.NewWorld()
	local main = world:AddChar({ guid = guid(1), name = "Mainy", account = "acc1", profs = { [TAILORING] = tailoring(100, { [3914] = 2568 }) } })
	local alt = world:AddChar({ guid = guid(2), name = "Alty", account = "acc1" })
	local other = world:AddChar({ guid = guid(3), name = "Otto" })
	local cm = world:Login(main.guid)
	world:Run(60)
	cm:OpenTradeSkill(TAILORING)
	world:Run(120) -- first-ever login: past the adoption window
	world:Logout(main.guid)
	world:Login(alt.guid)
	world:Run(30)
	world:Login(other.guid)
	world:Run(180)
	local r = world.online[other.guid]:Record(main.guid)
	truthy(r and r.profs[TAILORING].recipes[3914], "main's recipes came from the alt's client")
end)

test("roster name differs from the sender's name: sync still works", function()
	math.randomseed(21)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", rosterName = "Mira Stein-Realm", profs = { [TAILORING] = tailoring(150, { [3914] = 2568 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Bert", rosterName = "Ein Magier-Realm" })
	local c = world:AddChar({ guid = guid(3), name = "Cleo", rosterName = "Mira Stein-Realm" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	truthy(world.online[b.guid]:Record(a.guid), "B received A's broadcast")
	-- A late login knows nobody yet and must find a partner through the guild.
	local cc = world:Login(c.guid)
	world:Run(200)
	assertConverged(world, a.guid, "with differing roster names")
	for name in pairs(world.sentBy) do
		truthy(name == "Anna-Realm" or name == "Bert-Realm" or name == "Cleo-Realm", name)
	end
	-- Whispers and displays use the name the server puts on messages.
	local crafter = cc.ns.Index.Crafters(3914)[1]
	eq(cc.ns.Index.ContactFor(crafter), "Anna-Realm")
	eq(world.repeatedFailures, 0, "a name that failed once is not whispered again")
end)

test("/gtb versions lists every online addon user; an outdated build is named", function()
	math.randomseed(41)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", version = "0.1.0-aaaaaaa", build = 100 })
	local b = world:AddChar({ guid = guid(2), name = "Bert", version = "0.1.0-bbbbbbb", build = 200 })
	local c = world:AddChar({ guid = guid(3), name = "Cleo", version = "0.1.0-aaaaaaa", build = 100 })
	local old = world:AddChar({ guid = guid(4), name = "Olli", legacy = true })
	local ca = world:Login(a.guid)
	world:Login(b.guid)
	world:Login(c.guid)
	world:Run(200)
	world:Login(old.guid) -- knows nobody: asks the guild for a partner
	world:Run(60)
	local logBefore = #world.log
	world:ResetCounters()
	ca.ns.Versions.Request()
	world:Run(10)
	eq(world.byType.V, 1, "one request")
	eq(world.byType.N, 2, "one whispered answer per compatible client")
	local seen = ca.ns.Versions.byName
	eq(seen["Bert-Realm"].version, "0.1.0-bbbbbbb")
	eq(seen["Cleo-Realm"].version, "0.1.0-aaaaaaa")
	truthy(seen["Olli-Realm"].incompatible, "the old build is noticed, not silently ignored")
	local report = {}
	for i = logBefore + 1, #world.log do
		if world.log[i]:find("^Anna%-Realm: ") then report[#report + 1] = world.log[i] end
	end
	local text = table.concat(report, "\n")
	truthy(text:find("Bert: 0.1.0-bbbbbbb", 1, true) and text:find("newer", 1, true), text)
	truthy(text:find("Cleo: 0.1.0-aaaaaaa", 1, true), text)
	truthy(text:find("Olli: ", 1, true) and text:find("outdated", 1, true), text)
	-- Notices: none about Bert's newer test build, one about the outdated guildmate.
	local function told(pattern)
		for _, line in ipairs(world.log) do
			if line:find("^Anna%-Realm: ") and line:find(pattern, 1, true) then return true end
		end
		return false
	end
	falsy(told("is out"), "test builds are not announced")
	truthy(told("Olli uses an outdated Guild Tradebook"), "outdated notice")
	-- Asking again right away does not make everyone answer again.
	world:ResetCounters()
	ca.ns.Versions.Request()
	world:Run(10)
	falsy(world.byType.N, "no second round of answers")
end)

test("update notice: releases only, one chat line a day per account", function()
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", version = "0.3.0", build = 100 })
	local alt = world:AddChar({ guid = guid(5), name = "Alba", version = "0.3.0", build = 100, account = a.account })
	local ca = world:Login(a.guid)
	local Versions = ca.ns.Versions
	-- The rule.
	truthy(Versions.IsNewerRelease("0.3.0", "0.4.0"))
	truthy(Versions.IsNewerRelease("0.3.0", "1.0.0"))
	truthy(Versions.IsNewerRelease("0.9.0", "0.10.0"), "numbers, not text")
	truthy(Versions.IsNewerRelease("0.4.0-dev", "0.4.0"), "the release is newer than its development copy")
	truthy(Versions.IsNewerRelease("0.4.0-d8dcb0e", "0.4.0"), "and than its test build")
	falsy(Versions.IsNewerRelease("0.3.0", "0.4.0-dev"), "development copies are ignored")
	falsy(Versions.IsNewerRelease("0.3.0", "0.4.0-d8dcb0e"), "test builds are ignored")
	falsy(Versions.IsNewerRelease("0.4.0", "0.4.0"))
	falsy(Versions.IsNewerRelease("0.4.0", "0.3.0"))
	falsy(Versions.IsNewerRelease("0.3.0", nil))
	falsy(Versions.IsNewerRelease("?", "0.4.0"), "own version unknown")
	-- The chat line.
	local function notices()
		local n = 0
		for _, line in ipairs(world.log) do
			if line:find(" is out ", 1, true) then n = n + 1 end
		end
		return n
	end
	Versions.Seen("Bert-Realm", "0.4.0-d8dcb0e", 200)
	Versions.Seen("Bert-Realm", "0.4.0-dev", 0)
	eq(notices(), 0, "nothing for test builds and development copies")
	Versions.Seen("Bert-Realm", "0.4.0", 300)
	eq(notices(), 1)
	truthy(world.log[#world.log]:find("Version 0.4.0 is out (you have 0.3.0).", 1, true), world.log[#world.log])
	Versions.Seen("Cleo-Realm", "0.4.0", 300)
	Versions.SeenIncompatible("Dana-Realm", "0.4.0", 99)
	eq(notices(), 1, "once a day")
	-- Another character of the account: already told today.
	world:Logout(a.guid)
	local cAlt = world:Login(alt.guid)
	cAlt.ns.Versions.Seen("Bert-Realm", "0.4.0", 300)
	eq(notices(), 1, "once a day per account")
	cAlt.ns.Versions.Seen("Bert-Realm", "0.5.0", 400)
	eq(notices(), 2, "a newer release right away")
	cAlt.ns.Versions.Seen("Cleo-Realm", "0.4.0", 300)
	eq(notices(), 2, "an older release after a newer one: nothing")
	-- The next day: once more, naming the newest release known.
	cAlt.env.GuildTradebookDB.updateTold.day = "yesterday"
	cAlt.ns.Versions.Seen("Cleo-Realm", "0.4.0", 300)
	eq(notices(), 3, "again the next day")
	truthy(world.log[#world.log]:find("Version 0.5.0 is out", 1, true), world.log[#world.log])
	cAlt.ns.Versions.Seen("Bert-Realm", "0.5.0", 400)
	eq(notices(), 3)
	-- Updated: quiet.
	cAlt.env.GuildTradebookDB.updateTold.day = "yesterday"
	alt.version = "0.5.0"
	world:Logout(alt.guid)
	cAlt = world:Login(alt.guid)
	cAlt.ns.Versions.Seen("Bert-Realm", "0.5.0", 400)
	eq(notices(), 3, "nothing once up to date")
end)

test("/gtb diag: the sender sees its own echo, others see the test message", function()
	local world, a, b = threeMembers()
	local ca = world:Login(a.guid)
	world:Login(b.guid)
	world:Run(30)
	ca.ns.Protocol.Diagnose()
	world:Run(6)
	local function said(who, text)
		for _, line in ipairs(world.log) do
			if line:find("^" .. who) and line:find(text, 1, true) then return true end
		end
		return false
	end
	truthy(said("Anna", "echo received"), "echo")
	falsy(said("Anna", "no echo"), "no timeout message")
	truthy(said("Bert", "test message received from Anna"), "other side")
	-- Nothing comes back: the timeout says so.
	a.deaf = true
	ca.ns.Protocol.Diagnose()
	world:Run(6)
	truthy(said("Anna", "no echo within 5 s"), "timeout")
end)

test("/gtb diag <name>: test whispers in both name forms; the echo teaches your own name", function()
	math.randomseed(24)
	local world = H.NewWorld()
	world.spaceWhispers = true
	local a = world:AddChar({ guid = guid(1), name = "Mira Stein" })
	local b = world:AddChar({ guid = guid(2), name = "Joerg Falk" })
	local ca = world:Login(a.guid)
	world:Login(b.guid)
	world:Run(30)
	ca.ns.Protocol.Diagnose("Joerg Falk")
	world:Run(3)
	local got = {}
	for _, line in ipairs(world.log) do
		local target = line:match("^Joerg Falk%-Realm: .*test whisper received.*sent to '([^']+)'")
		if target then got[#got + 1] = target end
	end
	table.sort(got)
	eq(table.concat(got, ","), "Joerg Falk,Joerg Falk-Realm")
	ca.ns.Protocol.Diagnose()
	world:Run(6)
	eq(ca.ns.Util.learnedPlayerName, "Mira Stein-Realm")
end)

test("names with a space can not be whispered: sync goes through the guild channel, addressed", function()
	math.randomseed(22)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Joerg Falk", profs = { [TAILORING] = tailoring(150, { [3914] = 2568 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Mira Stein" })
	local c = world:AddChar({ guid = guid(3), name = "Cleo" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	local cc = world:Login(c.guid)
	world:Run(200)
	assertConverged(world, a.guid, "names with spaces")
	assertConverged(world, b.guid, "names with spaces")
	truthy(world.addressed > 0, "addressed guild messages were used")
	truthy(cc:Record(a.guid).profs[TAILORING].recipes[3914])
	-- A first failure counts as "offline" (the roster is often behind); the
	-- same name failing again while the roster still shows it online is a
	-- name problem: from then on it goes the guild way.
	world:Run(3 * 1300)
	world:ResetCounters()
	world:Run(3 * 1300)
	eq(world.repeatedFailures, 0, "a name that failed twice is not whispered again")
	-- Your own name: first name and surname, as the server shows it.
	eq(cc:Record(a.guid).name, "Joerg Falk-Realm")
	eq(cc:Record(b.guid).name, "Mira Stein-Realm")
	eq(cc.ns.Index.Crafters(3914)[1].name, "Joerg Falk-Realm")
end)

test("Forever names can be whispered without the realm: plain whispers, no detour", function()
	math.randomseed(23)
	local world = H.NewWorld()
	world.spaceWhispers = true
	local a = world:AddChar({ guid = guid(1), name = "Joerg Falk", profs = { [TAILORING] = tailoring(150, { [3914] = 2568 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Mira Stein" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	world:Login(world:AddChar({ guid = guid(3), name = "Cleo Tanner" }).guid)
	world:Run(200)
	assertConverged(world, a.guid, "whispers with surnames")
	eq(world.badWhispers, 0)
	eq(world.addressed, 0, "no guild detour needed")
end)

test("a whisper fails: the name is marked and the guild channel is used instead", function()
	local world, a, b = threeMembers()
	a.unwhisperable = true
	world:Login(a.guid)
	world:Run(60)
	world.online[a.guid]:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(a.guid)
	-- B knows A from the record; A comes back and B syncs with A.
	world:Login(b.guid)
	world:Run(30)
	world:Login(a.guid)
	world:ResetCounters()
	world:Run(1300)
	truthy(world.online[b.guid].ns.Protocol.unreachable["Anna-Realm"], "marked unreachable")
	truthy(world.addressed > 0, "guild channel used")
	assertConverged(world, a.guid, "after the fallback")
	-- The failed replies were resent, so no sync ran into its timeout.
	for _, line in ipairs(world.online[a.guid].ns.log) do
		falsy(line:find("no answer from", 1, true), line)
	end
	-- Later whispers to Anna go the guild way right away.
	world:Run(2 * 1300)
	eq(world.repeatedFailures, 0, "a name that failed once is not whispered again")
end)

test("offline while the roster still shows online: one failed whisper, the sync moves on, no repeats", function()
	math.randomseed(25)
	local world, a, b, c = threeMembers()
	a.staleRoster, a.quietLogout = true, true
	world:Login(b.guid)
	world:Login(c.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(200)
	world:Logout(a.guid)
	world:Run(5)
	local cb = world.online[b.guid]
	truthy(cb.ns.Roster.members[a.guid].online, "the roster still shows Anna online")
	world:ResetCounters()
	cb.ns.log = {}
	-- Bert syncs a few times; Anna is a known peer, so she gets picked.
	for i = 1, 6 do
		cb.ns.Protocol.sync = nil
		cb.ns.Protocol.StartSync(false)
		world:Run(5)
		falsy(cb.ns.Protocol.sync, "sync " .. i .. " answered within 5 s")
		world:Run(25)
	end
	local offline, timeouts = 0, 0
	for _, line in ipairs(cb.ns.log) do
		if line:find("failed: offline", 1, true) then offline = offline + 1 end
		if line:find("no answer from Anna", 1, true) then timeouts = timeouts + 1 end
	end
	eq(offline, 1, "one failed whisper to Anna")
	eq(timeouts, 0, "no sync waited for Anna")
	eq(world.repeatedFailures, 0, "Anna is not whispered again")
	local m = cb.ns.Roster.members[a.guid]
	falsy(m.online, "Anna counts as offline here")
	truthy(m.sharedOnline, "elections still see the roster every client sees")
	truthy(m.rosterOnline)
	eq(#cb.ns.Wishlist.ReadyNow(), 0)
end)

test("guild cleanup runs in a session: the current guild is stamped, an old one pruned", function()
	local world = H.NewWorld()
	local me = world:AddChar({ guid = guid(1), name = "Anna" })
	local c = world:Login(me.guid)
	world:Run(30)
	local db = c.env.GuildTradebookDB
	local old = { chars = { [guid(77)] = { guid = guid(77) } }, seenAt = c.ns.Now() - c.ns.Store.GUILD_RETENTION - 1 }
	db.guilds["Old Guild-Realm"] = old
	local gd = c.ns.GetGuildData()
	truthy(gd.seenAt, "current guild stamped")
	c:Fire("GUILD_ROSTER_UPDATE")
	world:Run(10)
	falsy(db.guilds["Old Guild-Realm"], "old guild pruned")
	truthy(db.guilds[c.ns.Roster.guildKey], "current guild kept")
end)

test("online state: messages prove online, failed whispers offline, both expire; roster changes end them", function()
	local world = H.NewWorld()
	local me = world:AddChar({ guid = guid(1), name = "Anna" })
	local x = world:AddChar({ guid = guid(2), name = "Bert" })
	local c = world:Login(me.guid)
	world:Run(30)
	local R = c.ns.Roster
	local function state() local m = R.members[x.guid] return m.online, m.sharedOnline end
	falsy((state()))
	R.Heard(x.guid)
	local online, shared = state()
	truthy(online, "a message proves online")
	falsy(shared, "only for this client")
	world:Run(R.ONLINE_PROOF + 1)
	c:Fire("GUILD_ROSTER_UPDATE")
	world:Run(2)
	falsy((state()), "the proof expires")

	world:Login(x.guid)
	world:Run(2)
	truthy((state()))
	R.Note(x.guid, false, true) -- a whisper failed
	online, shared = state()
	falsy(online)
	truthy(shared)
	truthy(R.KnownOffline(x.guid))
	c:Fire("GUILD_ROSTER_UPDATE")
	world:Run(2)
	falsy((state()), "an unchanged roster does not undo it")
	world:Run(R.OFFLINE_MEMORY + 1)
	c:Fire("GUILD_ROSTER_UPDATE")
	world:Run(2)
	truthy((state()), "expired")

	R.Note(x.guid, false, true)
	world:Logout(x.guid)
	world:Run(2)
	world:Login(x.guid)
	world:Run(2)
	truthy((state()), "a relog on the roster ends it")
	falsy(R.KnownOffline(x.guid))
end)

-- Account linking (Features/Link.lua) ------------------------------------------

local function logHas(client, text)
	for _, line in ipairs(client.ns.log) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

-- License 1: Crafty (crafter) and Alty; license 2: Mainy; Otto watches; Olli
-- runs 0.1.0 (relays only 8 record slots).
local function linkWorld(seed, withOld)
	math.randomseed(seed)
	local world = H.NewWorld()
	local crafty = world:AddChar({ guid = guid(1), name = "Crafty", account = "lic1", profs = { [TAILORING] = tailoring(100, { [3914] = 2568 }) } })
	local alty = world:AddChar({ guid = guid(2), name = "Alty", account = "lic1" })
	local mainy = world:AddChar({ guid = guid(3), name = "Mainy", account = "lic2" })
	local otto = world:AddChar({ guid = guid(4), name = "Otto" })
	local olli = world:AddChar({ guid = guid(5), name = "Olli", v010 = true })
	world:Login(otto.guid)
	if withOld then world:Login(olli.guid) end
	local cc = world:Login(crafty.guid)
	world:Run(60)
	cc:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(crafty.guid)
	world:Login(alty.guid)
	world:Run(120)
	world:Logout(alty.guid)
	world:Login(mainy.guid)
	world:Run(200)
	return world, crafty, alty, mainy, otto, olli
end

test("link: offer on one license, accept later on the other; the guild sees one player; unlink splits again", function()
	local world, crafty, alty, mainy, otto, olli = linkWorld(51)
	local co = world.online[otto.guid]
	falsy(co:Record(mainy.guid).player == co:Record(crafty.guid).player, "two players before")
	world:Logout(mainy.guid)
	world:Run(30)

	-- License 1 offers, then goes offline: the offer waits in its record.
	local cc = world:Login(crafty.guid)
	world:Run(60)
	cc.ns.Link.Offer(mainy.guid)
	truthy(logHas(cc, "Link offer for Mainy sent"))
	world:Run(30)
	world:Logout(crafty.guid)
	world:Run(30)

	-- License 2 logs in later: it is asked once.
	local cm = world:Login(mainy.guid)
	world:Run(120)
	eq(#cm.popups, 1, "asked")
	eq(cm.popups[1].which, "GUILDTRADEBOOK_LINK_REQUEST")
	eq(cm.popups[1].text1, "Crafty")
	truthy(cm:Answer("GUILDTRADEBOOK_LINK_REQUEST", true))
	world:Run(60)
	truthy(logHas(cm, "Linked:"))
	truthy(cm.ns.Link.IsPartner(crafty.guid) and cm.ns.Link.IsPartner(alty.guid), "both characters of license 1")

	-- Everyone groups them.
	eq(co:Record(mainy.guid).player, co:Record(crafty.guid).player, "one player")
	local crafter = co.ns.Index.Crafters(3914)[1]
	eq(crafter.via and crafter.via.guid, mainy.guid, "Crafty is reached via Mainy")
	-- On license 2, Crafty is an own character now: never whispered.
	local own = cm.ns.Index.Crafters(3914)[1]
	falsy(cm.ns.Index.ContactFor(own))
	eq(#cm.ns.Wishlist.ReadyNow(), 0)

	-- License 1 comes back: confirmed, the offer is gone.
	cc = world:Login(crafty.guid)
	world:Run(120)
	truthy(logHas(cc, "Linked:"))
	falsy(cc.ns.GetGuildData().link.offerTo)
	falsy(co:Record(crafty.guid).offer, "the offer left the record")
	truthy(cc.ns.Link.IsPartner(mainy.guid))

	-- Many sync rounds later, the link holds (stale copies do not undo it).
	world:Run(3 * 1300)
	eq(co:Record(mainy.guid).player, co:Record(crafty.guid).player, "still linked")
	eq(cc.ns.GetGuildData().playerId, cm.ns.GetGuildData().playerId)
	-- An older copy of an own record with a smaller ID must not undo it.
	local linkedId = cm.ns.GetGuildData().playerId
	local stale = H.DeepCopy(cm.ns.Scanner.GetOwn())
	stale.ver, stale.player = stale.ver - 100, "000000000000"
	cm.ns.Store.Rehash(stale)
	cm.ns.Protocol.OnSelfCopy(stale)
	eq(cm.ns.GetGuildData().playerId, linkedId, "a stale copy does not undo the link")

	-- License 2 unlinks alone; license 1 is told.
	cm.ns.Link.Unlink()
	world:Run(60)
	falsy(co:Record(mainy.guid).player == co:Record(crafty.guid).player, "two players again")
	truthy(logHas(cc, "no longer linked"))
	falsy(cc.ns.Link.IsLinked())
	eq(co:Record(alty.guid).player, co:Record(crafty.guid).player, "license 1 stays one player")
	world:Run(3 * 1300)
	falsy(co:Record(mainy.guid).player == co:Record(crafty.guid).player, "stays unlinked")
end)

test("link with only a 0.1.0 client relaying: the offer arrives once both licenses are online; 0.1.0 groups them", function()
	local world, crafty, _, mainy, otto, olli = linkWorld(54, true)
	world:Logout(otto.guid)
	world:Logout(mainy.guid)
	world:Run(30)
	local cc = world:Login(crafty.guid)
	world:Run(60)
	cc.ns.Link.Offer(mainy.guid)
	world:Run(30)
	world:Logout(crafty.guid)
	world:Run(30)
	local cm = world:Login(mainy.guid)
	world:Run(200)
	eq(#cm.popups, 0, "Olli relayed the record without the offer")
	cc = world:Login(crafty.guid)
	world:Run(30)
	eq(#cm.popups, 1, "asked as soon as both are online")
	truthy(cm:Answer("GUILDTRADEBOOK_LINK_REQUEST", true))
	world:Run(60)
	local co = world.online[olli.guid]
	eq(co:Record(mainy.guid).player, co:Record(crafty.guid).player, "the 0.1.0 client groups them by player ID")
	truthy(logHas(cc, "Linked:"))
end)

test("link: a linked character leaves the guild and comes back", function()
	local world, crafty, alty, mainy, otto = linkWorld(55)
	local cc = world:Login(crafty.guid)
	world:Run(60)
	cc.ns.Link.Offer(mainy.guid)
	world:Run(60)
	local cm = world.online[mainy.guid]
	truthy(cm:Answer("GUILDTRADEBOOK_LINK_REQUEST", true))
	world:Run(60)
	local co = world.online[otto.guid]
	world:Logout(crafty.guid)
	world:Run(150)
	eq(co.ns.Index.Crafters(3914)[1].via and co.ns.Index.Crafters(3914)[1].via.guid, mainy.guid, "reached via Mainy")

	-- Mainy (license 2) leaves: the guild no longer reaches Crafty through it.
	world:Logout(mainy.guid)
	world:RemoveFromGuild(mainy.guid)
	cc = world:Login(crafty.guid)
	world:Run(150)
	world:Logout(crafty.guid)
	world:Run(150)
	local crafter = co.ns.Index.Crafters(3914)[1]
	falsy(crafter.via, "nobody to reach Crafty through")
	falsy(crafter.reachable)
	for _, guid in ipairs(co.ns.Index.Siblings(crafty.guid)) do
		falsy(guid == mainy.guid, "Mainy is no longer grouped")
	end
	eq(co.ns.Index.Siblings(crafty.guid)[1], alty.guid, "license 1 is still one player")
	local alive = world:Login(alty.guid)
	world:Run(60)
	truthy(alive.ns.Link.IsPartner(mainy.guid), "license 1 keeps the link while Mainy is away")

	-- Mainy comes back: grouped again everywhere, still ours on license 1.
	world:Logout(alty.guid)
	world:AddToGuild(mainy.guid)
	cm = world:Login(mainy.guid)
	world:Run(200)
	eq(#cm.popups, 0, "no new question")
	world:Logout(mainy.guid)
	world:Run(150)
	eq(co:Record(mainy.guid).player, co:Record(crafty.guid).player)
	truthy(co.ns.Index.Siblings(crafty.guid)[1] == mainy.guid or co.ns.Index.Siblings(crafty.guid)[2] == mainy.guid, "grouped again")
	cc = world:Login(crafty.guid)
	world:Run(60)
	truthy(cc.ns.Link.IsPartner(mainy.guid))
	falsy(cc.ns.Index.ContactFor(cc.ns.Index.CrafterInfo(mainy.guid)), "never whispered: one of yours")
end)

test("link: a declined offer is not asked again; nothing changes", function()
	local world, crafty, _, mainy, otto = linkWorld(52)
	local cc = world.online[crafty.guid] or world:Login(crafty.guid)
	world:Run(60)
	cc.ns.Link.Offer(mainy.guid)
	world:Run(60)
	local cm = world.online[mainy.guid]
	eq(#cm.popups, 1)
	truthy(cm:Answer("GUILDTRADEBOOK_LINK_REQUEST", false))
	world:Logout(mainy.guid)
	world:Run(30)
	cm = world:Login(mainy.guid)
	world:Run(300)
	eq(#cm.popups, 0, "not asked again after a relog")
	local co = world.online[otto.guid]
	falsy(co:Record(mainy.guid).player == co:Record(crafty.guid).player)
	-- The offerer withdraws: the record no longer carries it.
	cc.ns.Link.CancelOffer()
	world:Run(30)
	falsy(co:Record(crafty.guid).offer)
end)

test("link: offers are only shown for characters of other players with addon data", function()
	local world, crafty, alty, mainy, otto = linkWorld(53)
	local cm = world.online[mainy.guid]
	local L = cm.ns.Link
	truthy(L.TargetOf(crafty.guid), "another player's character")
	falsy(L.TargetOf(mainy.guid), "not yourself")
	local stranger = world:AddChar({ guid = guid(6), name = "Nodata" })
	world:Login(stranger.guid)
	world:Run(5)
	falsy(L.TargetOf(stranger.guid), "no shared record yet")
	local items = cm.ns.Link.TargetOf(alty.guid)
	eq(items, L.TargetOf(crafty.guid), "both characters of license 1 lead to the same player")
end)

test("characters of one account are grouped; an offline crafter is reached via the online one", function()
	math.randomseed(11)
	local world = H.NewWorld()
	local crafter = world:AddChar({ guid = guid(1), name = "Crafty", account = "acc1", profs = { [TAILORING] = tailoring(100, { [3914] = 2568 }) } })
	local main = world:AddChar({ guid = guid(2), name = "Mainy", account = "acc1" })
	local other = world:AddChar({ guid = guid(3), name = "Otto" })
	local cc = world:Login(crafter.guid)
	world:Run(60)
	cc:OpenTradeSkill(TAILORING)
	world:Run(120)
	world:Logout(crafter.guid)
	world:Login(main.guid)
	world:Run(30)
	local co = world:Login(other.guid)
	world:Run(180)
	local rc, rm = co:Record(crafter.guid), co:Record(main.guid)
	truthy(rc and rc.player, "crafter has a player ID")
	eq(rm and rm.player, rc.player)
	falsy(co:Record(other.guid).player == rc.player, "other players have their own ID")
	local c = co.ns.Index.Crafters(3914)[1]
	eq(c.guid, crafter.guid)
	falsy(c.online)
	eq(c.via and c.via.guid, main.guid)
	truthy(c.reachable)
	eq(co.ns.Index.ContactFor(c), "Mainy-Realm")
	-- On the player's own client the crafter is an own alt: never whispered.
	local cm = world.online[main.guid]
	local own = cm.ns.Index.Crafters(3914)[1]
	local target, reason = cm.ns.Index.ContactFor(own)
	falsy(target, "your own alt is never whispered")
	eq(reason, "Your character")
	-- A !craft answer from the owner's client still tells others whom to ask.
	co.env.GuildTradebookDB.options.chatResponder = false
	world:GuildChat("Otto-Realm", "!craft Recipe 3914")
	world:Run(15)
	local answer = craftAnswers(world, "Otto-Realm")[1] or "no answer"
	truthy(answer:find("Crafty (Mainy*)", 1, true), answer)
	-- The crafter's owner logs off completely: no longer reachable.
	world:Logout(main.guid)
	world:Run(150)
	c = co.ns.Index.Crafters(3914)[1]
	falsy(c.via)
	falsy(c.reachable)
end)

test("the 'main' leaves the guild: the remaining characters stay grouped without it", function()
	math.randomseed(13)
	local world = H.NewWorld()
	local main = world:AddChar({ guid = guid(1), name = "Mainy", level = 60, account = "acc1" })
	local crafter = world:AddChar({ guid = guid(2), name = "Crafty", level = 40, account = "acc1", profs = { [TAILORING] = tailoring(100, { [3914] = 2568 }) } })
	local banker = world:AddChar({ guid = guid(3), name = "Banky", level = 10, account = "acc1" })
	local other = world:AddChar({ guid = guid(4), name = "Otto" })
	local co = world:Login(other.guid)
	for _, c in ipairs({ main, banker }) do
		world:Login(c.guid)
		world:Run(150)
		world:Logout(c.guid)
	end
	local cc = world:Login(crafter.guid)
	world:Run(60)
	cc:OpenTradeSkill(TAILORING)
	world:Run(150)
	world:Logout(crafter.guid)
	world:Run(30)
	local Index = co.ns.Index
	eq(#Index.Siblings(crafter.guid), 2)
	-- Mainy is online but leaves the guild (or is kicked).
	world:Login(main.guid)
	world:Run(30)
	eq(Index.Crafters(3914)[1].via.guid, main.guid)
	world:RemoveFromGuild(main.guid)
	world:Run(30)
	local siblings = Index.Siblings(crafter.guid)
	eq(#siblings, 1, "only the characters still in the guild")
	eq(siblings[1], banker.guid)
	falsy(Index.Crafters(3914)[1].via, "a former member is never the contact")
	-- The bank alt comes online: it is the contact now.
	world:Login(banker.guid)
	world:Run(30)
	eq(Index.Crafters(3914)[1].via.guid, banker.guid)
	-- The remaining characters keep their ID; nothing was re-published.
	eq(co:Record(crafter.guid).player, co:Record(banker.guid).player)
end)

test("same character on a second PC: both PCs agree on one player ID", function()
	math.randomseed(12)
	local world = H.NewWorld()
	local main = world:AddChar({ guid = guid(1), name = "Mainy", account = "pc1" })
	local alt = world:AddChar({ guid = guid(2), name = "Alty", account = "pc2" })
	local other = world:AddChar({ guid = guid(3), name = "Otto" })
	local co = world:Login(other.guid)
	world:Login(main.guid)
	world:Run(150)
	world:Logout(main.guid)
	world:Login(alt.guid)
	world:Run(150)
	world:Logout(alt.guid)
	falsy(co:Record(main.guid).player == co:Record(alt.guid).player, "unrelated so far")
	-- Mainy is played on the second PC once: its pool copy links both IDs.
	main.account = "pc2"
	world:Login(main.guid)
	world:Run(200)
	world:Logout(main.guid)
	world:Run(30)
	eq(co:Record(main.guid).player, co:Record(alt.guid).player)
	-- Back on the first PC, that PC adopts the shared ID as well.
	main.account = "pc1"
	world:Login(main.guid)
	world:Run(200)
	eq(co:Record(main.guid).player, co:Record(alt.guid).player)
	eq(world.online[main.guid].env.GuildTradebookDB.guilds[world.online[main.guid].ns.Roster.guildKey].playerId,
		co:Record(alt.guid).player)
end)

test("server profession data hides stale primary professions", function()
	local world, a, b = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	world:Logout(a.guid)
	-- Server now says A has Alchemy + Mining; the pool copy still says Tailoring.
	world.serverProfs[a.guid] = { ALCHEMY, 186 }
	local cb = world.online[b.guid]
	cb.ns.Roster.Refresh()
	cb.ns.Index.dirty = true
	eq(#cb.ns.Index.Crafters(3914), 0, "hidden from search")
	truthy(cb:Record(a.guid).profs[TAILORING], "record itself untouched")
	-- Only one slot known: no conclusion.
	world.serverProfs[a.guid] = { ALCHEMY, nil }
	cb.ns.Roster.Refresh()
	cb.ns.Index.dirty = true
	eq(#cb.ns.Index.Crafters(3914), 1, "partial server data is not evidence")
end)

test("rogue Poisons are a class skill: not shared; an older record that has them hides them", function()
	math.randomseed(12)
	local world = H.NewWorld()
	local POISONS = 40
	local r = world:AddChar({ guid = guid(1), name = "Rina", class = "ROGUE", profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568 }),
		[POISONS] = { rank = 200, maxRank = 300, name = "Poisons", secondary = true, recipes = { [8681] = 6947 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	local cb = world:Login(b.guid)
	local cr = world:Login(r.guid)
	world:Run(60)
	cr:OpenTradeSkill(TAILORING)
	cr:OpenTradeSkill(POISONS)
	world:Run(120)
	falsy(cr:Record(r.guid).profs[POISONS], "not in the rogue's own record")
	falsy(cb:Record(r.guid).profs[POISONS], "not shared")
	eq(#cb.ns.Index.Crafters(3914), 1)
	-- A record from an older version still carries Poisons: hidden everywhere.
	local old = cb:Record(r.guid)
	old.profs[POISONS] = { rank = 200, maxRank = 300, recipes = { [8681] = 6947 }, cds = { [8681] = 0 } }
	cb.ns.Index.dirty = true
	eq(#cb.ns.Index.Crafters(8681), 0, "not searchable")
	eq(#cb.ns.Store.ProfessionSkillLines(old), 1, "only Tailoring counts")
	for _, m in ipairs(cb.ns.Export.Build().members) do
		for _, p in ipairs(m.professions) do truthy(p.id ~= POISONS, "not exported") end
	end
end)

test("server profession data never hides professions the owner marks as not primary", function()
	math.randomseed(13)
	local world = H.NewWorld()
	local OTHER = 777 -- a non-primary skill with a crafting window
	local r = world:AddChar({ guid = guid(1), name = "Rina", profs = {
		[TAILORING] = tailoring(150, { [3914] = 2568 }),
		[OTHER] = { rank = 50, maxRank = 300, name = "Other", secondary = true, recipes = { [9991] = 9992 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	local cb = world:Login(b.guid)
	local cr = world:Login(r.guid)
	world:Run(60)
	cr:OpenTradeSkill(TAILORING)
	cr:OpenTradeSkill(OTHER)
	world:Run(120)
	falsy(cb:Record(r.guid).profs[OTHER].primary)
	-- The server lists the two primary professions: Tailoring and Mining.
	world.serverProfs[r.guid] = { TAILORING, 186 }
	cb.ns.Roster.Refresh()
	cb.ns.Index.dirty = true
	falsy(cb.ns.Roster.IsProfessionContradicted(r.guid, OTHER))
	eq(#cb.ns.Index.Crafters(9991), 1, "stays searchable")
end)

test("reagents are fetched from the guild on demand", function()
	local world, a, b = threeMembers()
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(60)
	local cb = world.online[b.guid]
	falsy(cb.env.GuildTradebookDB.recipeFacts[3914].reagents, "B has no reagents yet")
	cb.ns.Protocol.RequestFacts({ 3914 })
	world:Run(10)
	local fact = cb.env.GuildTradebookDB.recipeFacts[3914]
	truthy(fact.reagents and fact.reagents[1][1] == 2589, "reagents received")
end)

local function bigGuild(n, seed)
	math.randomseed(seed)
	local world = H.NewWorld()
	for i = 1, n do
		local recipes = {}
		for r = 1, 40 do recipes[i * 1000 + r] = i * 1000 + r end
		world:AddChar({ guid = guid(i), name = "M" .. i, profs = { [TAILORING] = tailoring(100 + i, recipes) } })
	end
	for i = 1, n do
		local c = world:Login(guid(i))
		world:Run(2)
		c:OpenTradeSkill(TAILORING)
	end
	world:Run(400)
	return world
end

test("100 online, one more logs in with an up-to-date copy: talks to one partner", function()
	local world = bigGuild(100, 3)
	for i = 1, 100 do assertConverged(world, guid(i), "member " .. i) end
	local late = world:AddChar({ guid = guid(500), name = "Late" })
	-- Late's account already holds a current copy (e.g. was online yesterday).
	world.accounts[late.account] = H.DeepCopy(world.online[guid(1)].env.GuildTradebookDB)
	world:ResetCounters()
	world:Login(late.guid)
	world:Run(120)
	local t = world.byType
	print(("       login with current data: %d messages %s"):format(world.messages, H.Describe(t)))
	eq(t.H, 2, "login sync + follow-up, one partner each")
	eq(t.K, 2, "one ack each")
	truthy((t.R or 0) <= 2, "no record flood")
	truthy(not t.P and not t.A, "no election needed")
	truthy(world.messages <= 8)
end)

test("100 online, fresh install logs in: two partners split the pool, each record sent once", function()
	local world = bigGuild(100, 5)
	local fresh = world:AddChar({ guid = guid(501), name = "Fresh" })
	world:ResetCounters()
	local cf = world:Login(fresh.guid)
	world:Run(200)
	local t = world.byType
	print(("       fresh install: %d messages %s, %d records"):format(world.messages, H.Describe(t), world.records))
	eq(t.P, 1, "one partner request")
	eq(t.A, 1, "exactly one peer accepted")
	eq(t.H, 2, "elected partner + second partner (instead of the login follow-up)")
	truthy((t.D or 0) <= 16 + 8, "one digest per bucket from the first partner, the even ones from the second")
	truthy(world.records <= 100 + 2, "each record sent about once: " .. world.records)
	truthy((t.B or 0) > 0 and (t.R or 0) <= 2, "records go in batches")
	for i = 1, 100 do
		truthy(cf:Record(guid(i)), "fresh client has member " .. i)
	end
end)

test("fresh install with only one partner online: the deferred half follows after the wait, nothing twice", function()
	local world = bigGuild(12, 41)
	for i = 2, 12 do world:Logout(guid(i)) end
	world:Run(30)
	local fresh = world:AddChar({ guid = guid(502), name = "Fresh" })
	world:ResetCounters()
	local cf = world:Login(fresh.guid)
	world:Run(cf.ns.Protocol.SPLIT_WAIT + 60)
	for i = 1, 12 do
		truthy(cf:Record(guid(i)), "fresh client has member " .. i)
	end
	truthy(world.records <= 12 + 1, "each record once: " .. world.records)
end)

test("load model: send queue like ChatThrottleLib, ALERT and NORMAL overtake a long BULK transfer", function()
	local world = H.NewWorld({ bandwidth = 800 })
	local from = { guid = "G", char = { name = "A-Realm", realm = "Realm", partition = 1 }, env = {} }
	local sentAt = {}
	local function send(label, size, prio)
		world:Enqueue(from, size, prio, function() sentAt[label] = world.clock.t end)
	end
	local t0 = world.clock.t
	send("small", 100, "NORMAL")
	eq(sentAt.small, t0, "idle queue and enough bandwidth: at once")
	send("bulk", 20000, "BULK")
	world:Run(1)
	send("alert", 60, "ALERT")
	send("normal", 300, "NORMAL")
	world:Run(60)
	truthy(sentAt.alert - t0 < 2, "alert within a second or so")
	truthy(sentAt.normal - t0 < 3)
	truthy(sentAt.bulk - t0 > 15, "the bulk transfer takes its time at 800 B/s")
end)

test("rank-up batches stretch with the number of active senders", function()
	local world = bigGuild(3, 42)
	local P = world.online[guid(1)].ns.Protocol
	local function range()
		local lo, hi = math.huge, 0
		for _ = 1, 50 do
			local d = P.MinorDelay()
			lo, hi = math.min(lo, d), math.max(hi, d)
		end
		return lo, hi
	end
	local lo, hi = range()
	truthy(lo >= 48 and hi <= 72, ("small guild: about 60 s (%.0f-%.0f)"):format(lo, hi))
	local now = world.online[guid(1)].env.GetTime()
	for i = 1, 199 do P.guildSenders["Player-1-F" .. i] = now end
	lo, hi = range()
	truthy(lo >= 235 and hi <= 370, ("200 active senders: about 300 s (%.0f-%.0f)"):format(lo, hi))
	for i = 200, 999 do P.guildSenders["Player-1-F" .. i] = now end
	lo, hi = range()
	truthy(hi <= P.MINOR_DELAY_MAX * 1.2, ("never above the cap (%.0f)"):format(hi))
	-- Old entries drop out.
	for g in pairs(P.guildSenders) do P.guildSenders[g] = now - P.SENDER_WINDOW - 1 end
	eq(P.ActiveSenders(now), 1)
end)

test("30 online see a member leave at once: no messages, every copy hidden", function()
	local world = bigGuild(30, 31)
	local leaver = guid(7)
	world:Logout(leaver)
	world:Run(30)
	world:ResetCounters()
	world:RemoveFromGuild(leaver)
	world:Run(60)
	eq(world.messages, 0, "a leave is not announced: every client sees the roster itself")
	for g, client in pairs(world.online) do
		local r = client:Record(leaver)
		truthy(r and r.goneSince, client.char.name .. " hides the leaver")
		falsy(client.ns.Index.Crafters(7001)[1], client.char.name .. " no longer lists the leaver")
	end
	-- The next sync round: digests agree (former members are left out), so no
	-- client sends records about the leaver.
	world:Run(1300)
	falsy(world.byType.D or world.byType.W or world.byType.R, "only hello + ack: " .. H.Describe(world.byType))
end)

test("idle guild: periodic sync stays cheap", function()
	local world = bigGuild(30, 9)
	world:ResetCounters()
	world:Run(3 * 1200)
	local perRound = world.messages / 3
	print(("       idle: %.0f messages per 20 min for 30 clients"):format(perRound))
	truthy(perRound <= 30 * 2 + 10, "about one hello + ack per client and round")
end)

test("secret values from the game (chat, system and addon messages) are skipped, not an error", function()
	local world = bigGuild(3, 24)
	local secret = {}
	for _, client in pairs(world.online) do
		client.env.issecretvalue = function(v) return secret[v] == true end
	end
	local nora = world:AddChar({ guid = guid(901), name = "Nora" })
	secret["!craft Recipe 1001"] = true
	world:GuildChat(nora.name, "!craft Recipe 1001")
	world:Run(30)
	eq(#craftAnswers(world, nora.name), 0, "a secret question is not answered")
	local c1 = world.online[guid(1)]
	secret["SECRET-SYSTEM"] = true
	c1.ns.Roster.OnSystemMessage(nil, "SECRET-SYSTEM")
	c1.ns.Protocol.OnSystemMessage(nil, "SECRET-SYSTEM")
	c1.ns.Protocol.OnComm(c1.ns.PREFIX, "SECRET-SYSTEM", "GUILD", "M2-Realm")
	-- Normal questions still work.
	world:GuildChat(nora.name, "!craft Recipe 1002")
	world:Run(30)
	eq(#craftAnswers(world, nora.name), 1)
end)

test("!craft from a member without the addon: exactly one answer", function()
	local world = bigGuild(30, 23)
	local nora = world:AddChar({ guid = guid(900), name = "Nora" }) -- no addon, never logs in
	world:GuildChat(nora.name, "!craft Recipe 3005")
	world:Run(30)
	local answers = craftAnswers(world, nora.name)
	eq(#answers, 1, "one answer for 30 addon users")
	truthy(answers[1]:find("Recipe 3005: M3", 1, true), "names the crafter: " .. answers[1])
	eq(#world.chat, 1, "guild chat only shows the question")

	world:GuildChat(nora.name, "!craft Recipe 3005")
	world:Run(30)
	eq(#craftAnswers(world, nora.name), 1, "the same question within a minute is not answered twice")
end)

test("!craft whispered to an addon user: answered right away by whisper", function()
	local world = bigGuild(5, 27)
	local nora = world:AddChar({ guid = guid(902), name = "Nora" })
	world:Run(130) -- the next roster refresh lists her
	world:ResetCounters()
	world:Whisper(nora.name, "M1", "!craft Recipe 3005")
	world:Run(5)
	local answers = craftAnswers(world, nora.name)
	eq(#answers, 1)
	truthy(answers[1]:find("Recipe 3005: M3", 1, true), answers[1])
	eq(world.byType.X or 0, 0, "nobody else saw it: no answered signal")
	-- The answerer's own copy ("To Nora: ...") is hidden from its chat.
	local filtered
	for _, w in ipairs(world.whispers) do
		if w.to == nora.name then filtered = w.text end
	end
	local m1 = world.online[guid(1)]
	truthy(m1.chatFilters and m1.chatFilters.CHAT_MSG_WHISPER_INFORM, "filter registered")
	truthy(m1.chatFilters.CHAT_MSG_WHISPER_INFORM(nil, "CHAT_MSG_WHISPER_INFORM", filtered), "own answer hidden")
	falsy(m1.chatFilters.CHAT_MSG_WHISPER_INFORM(nil, "CHAT_MSG_WHISPER_INFORM", "hi there"), "normal whispers stay")

	-- Someone outside the guild gets no answer.
	local stranger = world:AddChar({ guid = guid(903), name = "Stranger" })
	world:RemoveFromGuild(stranger.guid)
	world:Run(5)
	world:Whisper(stranger.name, "M1", "!craft Recipe 3005")
	world:Run(5)
	eq(#craftAnswers(world, stranger.name), 0, "not told to strangers")
end)

test("AreOutgoingAddonChatMessagesRestricted is true (Forever beta): sync and !craft still work", function()
	local world, a, b, c = threeMembers()
	a.noChatPosting, b.noChatPosting, c.noChatPosting = true, true, true
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Login(c.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	assertConverged(world, a.guid, "addon messages are not chat messages")
	world:GuildChat("Nora-Realm", "!craft Recipe 3914")
	world:Run(30)
	eq(#craftAnswers(world, "Nora-Realm"), 1, "exactly one answer")
end)

test("!craft: clients see the asker's name in different forms, still exactly one answer", function()
	local world = bigGuild(12, 25)
	world.chatNameFormats = true
	local asker = world:AddChar({ guid = guid(901), name = "Joerg Falk" })
	world:Login(asker.guid)
	world:Run(60)
	world:GuildChat(asker.name, "!craft Recipe 3005")
	world:Run(30)
	eq(#craftAnswers(world, asker.name), 1, "the answered signal matches on every client")
end)

test("partner request: a client that missed the first round answers a later one", function()
	math.randomseed(26)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", profs = { [TAILORING] = tailoring(150, { [3914] = 2568 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	-- Anna is in a loading screen while Bert's first request goes out.
	a.partition = 2
	world:ResetCounters()
	local cb = world:Login(b.guid)
	for _ = 1, 120 do
		if world.byType.P then break end
		world:Run(1)
	end
	eq(world.byType.P, 1, "first round sent")
	world:Run(3)
	falsy(cb:Record(a.guid), "first round missed")
	a.partition = 1
	world:Run(60)
	truthy(cb:Record(a.guid), "Anna answered a later round")
end)

-- 8 English clients and 1 German one; the German client is usually not
-- first in the overall ranking.
local function mixedGuild(seed)
	local world = bigGuild(8, seed)
	local de = world:AddChar({ guid = guid(950), name = "Greta", locale = "deDE",
		profs = { [TAILORING] = tailoring(100, { [3005] = 3005 }) } })
	world:Login(de.guid)
	world:Run(400)
	return world, de
end

test("!craft in German: answered by the German client, not 'nobody' from an English one", function()
	for seed = 30, 34 do
		local world, de = mixedGuild(seed)
		local nora = world:AddChar({ guid = guid(904), name = "Nora" })
		world:Run(130)
		world:GuildChat(nora.name, "!craft Rezept 3005")
		world:Run(30)
		local answers = {}
		for _, w in ipairs(world.whispers) do
			if w.to == nora.name then answers[#answers + 1] = w end
		end
		eq(#answers, 1, "one answer (seed " .. seed .. ")")
		eq(answers[1].from, de.name, "from the German client")
		truthy(answers[1].text:find("Rezept 3005: M3", 1, true), answers[1].text)
	end
end)

test("!craft that no client finds: one late 'nobody' answer naming the language", function()
	local world = mixedGuild(35)
	local nora = world:AddChar({ guid = guid(905), name = "Nora" })
	world:Run(130)
	local asked = world.clock.t
	world:GuildChat(nora.name, "!craft Thunderfury")
	local answered
	for _ = 1, 30 do
		world:Run(1)
		if #craftAnswers(world, nora.name) > 0 then answered = world.clock.t break end
	end
	local answers = craftAnswers(world, nora.name)
	world:Run(20)
	eq(#craftAnswers(world, nora.name), 1, "exactly one")
	truthy(answers[1]:find("Nobody", 1, true) or answers[1]:find("Niemand", 1, true), answers[1])
	truthy(answers[1]:find("(client language: English)", 1, true) or answers[1]:find("(Client-Sprache: Deutsch)", 1, true), answers[1])
	truthy(answered - asked >= 8, "waited for clients that might have found it: " .. (answered - asked))
end)

test("!craft in German whispered to an English client: 'nobody', with a hint to ask the guild", function()
	local world = mixedGuild(36)
	local nora = world:AddChar({ guid = guid(906), name = "Nora" })
	world:Run(130)
	world:Whisper(nora.name, "M1", "!craft Rezept 3005")
	world:Run(5)
	local answer = craftAnswers(world, nora.name)[1] or "no answer"
	truthy(answer:find('Nobody in the guild can craft "Rezept 3005". (client language: English) - ask in guild chat', 1, true), answer)
end)

local function link(id, name)
	return "|cffffffff|Hitem:" .. id .. "::::::::|h[" .. name .. "]|h|r"
end

test("!craft with a German item link: answered first by the German client, in German", function()
	for seed = 40, 43 do
		local world, de = mixedGuild(seed)
		local nora = world:AddChar({ guid = guid(907), name = "Nora" })
		world:Run(130)
		local asked = world.clock.t
		world:GuildChat(nora.name, "!craft " .. link(3005, "Gegenstand 3005"))
		world:Run(30)
		local answers = {}
		for _, w in ipairs(world.whispers) do
			if w.to == nora.name then answers[#answers + 1] = w end
		end
		eq(#answers, 1, "one answer (seed " .. seed .. ")")
		eq(answers[1].from, de.name, "from the German client")
		truthy(answers[1].text:find("Gegenstand 3005: M3", 1, true), answers[1].text)
	end
end)

test("!craft with a German item link, no German client online: one answer from another language", function()
	local world = bigGuild(6, 44)
	local nora = world:AddChar({ guid = guid(908), name = "Nora" })
	world:Run(130)
	local asked = world.clock.t
	world:GuildChat(nora.name, "!craft " .. link(3005, "Gegenstand 3005"))
	local answeredAt
	for _ = 1, 30 do
		world:Run(1)
		if #craftAnswers(world, nora.name) > 0 then answeredAt = world.clock.t break end
	end
	world:Run(20)
	local answers = craftAnswers(world, nora.name)
	eq(#answers, 1, "exactly one")
	truthy(answers[1]:find("Gegenstand 3005: M3", 1, true), "found by ID, named as linked: " .. answers[1])
	truthy(answeredAt - asked >= 8, "waited for the asker's language first")
end)

test("!craft with a link nobody can craft: one 'nobody' with the linked name", function()
	local world = bigGuild(6, 45)
	local nora = world:AddChar({ guid = guid(909), name = "Nora" })
	world:Run(130)
	world:GuildChat(nora.name, "!craft " .. link(19019, "Item 19019"))
	world:Run(30)
	local answers = craftAnswers(world, nora.name)
	eq(#answers, 1)
	eq(answers[1], '[Guild Tradebook] Nobody in the guild can craft "Item 19019".')
end)

test("!craft is silent when every client disabled it", function()
	local world = bigGuild(5, 24)
	for _, client in pairs(world.online) do
		client.env.GuildTradebookDB.options.chatResponder = false
	end
	world:GuildChat("Nora-Realm", "!craft Recipe 1001")
	world:Run(30)
	eq(#world.chat, 1, "only the question")
	eq(#world.whispers, 0, "no answer")
end)

test("recipe categories travel with the record; names come in the viewer's language when possible", function()
	math.randomseed(7)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", recipeCats = { [3914] = 10, [3915] = 11 },
		profs = { [TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569 }) } })
	local g = world:AddChar({ guid = guid(2), name = "Greta", locale = "deDE" })
	local k = world:AddChar({ guid = guid(3), name = "Karl", locale = "deDE", recipeCats = { [3914] = 10 },
		profs = { [TAILORING] = tailoring(100, { [3914] = 2568 }) } })
	local cg = world:Login(g.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	local db = cg.env.GuildTradebookDB
	eq(db.recipeFacts[3914].cat, 10, "category came with the record")
	eq(cg:Record(a.guid).profs[TAILORING].cats[3915], 11)
	-- Only an English crafter online: the English names meanwhile.
	eq(cg.ns.Categories.Name(10), "Category 10")
	eq(cg.ns.Categories.Name(11), "Category 11")
	-- A German crafter scans: asked at once for the German name.
	local ck = world:Login(k.guid)
	world:Run(60)
	ck:OpenTradeSkill(TAILORING)
	world:Run(120)
	eq(cg.ns.Categories.Name(10), "Kategorie 10", "German name from the German crafter")
	eq(cg.ns.Categories.Name(11), "Category 11", "no German client has this one")
	eq(db.categories[10].names.enUS, "Category 10", "both languages kept")
	eq(world.online[a.guid].ns.Categories.Name(10), "Category 10", "the English client keeps its own")
	-- Rows of the Recipes tab group by category.
	truthy(cg.ns.Categories.Of(3915) == 11)
end)

test("grey skills travel with the record (order of the recipe list)", function()
	math.randomseed(7)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", recipeTrivial = { [3914] = 50, [3915] = 110 },
		profs = { [TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569 }) } })
	local g = world:AddChar({ guid = guid(2), name = "Greta" })
	local cg = world:Login(g.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	eq(cg:Record(a.guid).profs[TAILORING].trivial[3915], 110, "published after the scan")
	local db = cg.env.GuildTradebookDB
	eq(db.recipeFacts[3914].trivial, 50)
	eq(db.recipeFacts[3915].trivial, 110)
end)

test("recipe categories relayed by 0.1.0 arrive once a newer client sends the record", function()
	math.randomseed(8)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", recipeCats = { [3914] = 10 },
		profs = { [TAILORING] = tailoring(150, { [3914] = 2568 }) } })
	local o = world:AddChar({ guid = guid(2), name = "Olli", v010 = true })
	local c = world:AddChar({ guid = guid(3), name = "Cleo" })
	world:Login(o.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	world:Logout(a.guid)
	local cc = world:Login(c.guid)
	world:Run(120)
	truthy(cc:Record(a.guid), "Cleo has Anna's record from Olli")
	eq(cc:Record(a.guid).profs[TAILORING].cats, nil, "0.1.0 dropped the categories")
	world:Login(a.guid)
	world:Run(120)
	eq(cc.env.GuildTradebookDB.recipeFacts[3914].cat, nil, "not asked in the background")
	-- Cleo opens the Recipes tab: asked from the crafter.
	cc.ns.Categories.Shown()
	world:Run(30)
	eq(cc.env.GuildTradebookDB.recipeFacts[3914].cat, 10, "category from the crafter")
	eq(cc.ns.Categories.Name(10), "Category 10", "with its name")
end)

test("export: the pool as JSON, also into the SavedVariables", function()
	math.randomseed(9)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Anna", recipeCats = { [3914] = 10 },
		cooldowns = { [3915] = 3600 },
		profs = { [TAILORING] = tailoring(150, { [3914] = 2568, [3915] = 2569 }) } })
	local b = world:AddChar({ guid = guid(2), name = "Bert" })
	local cb = world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(120)
	local E = cb.ns.Export
	-- Encoder: sorted keys, arrays, escapes, integers without exponent.
	eq(E.ToJSON({ b = 1, a = { 1, 2 }, c = E.Array(), d = {}, e = 'x"\n', f = 1.5, g = 2 ^ 40, h = true }),
		'{"a":[1,2],"b":1,"c":[],"d":{},"e":"x\\"\\n","f":1.5,"g":1099511627776,"h":true}')
	eq(E.ToJSON({ [10] = "x" }), '{"10":"x"}', "number keys become strings")

	local json = E.Command("")
	eq(cb.env.GuildTradebookExport.json, json, "kept for the SavedVariables")
	local data = E.Build()
	eq(data.format, 1)
	eq(#data.members, 2, "Anna and Bert (own record too)")
	local anna
	for _, m in ipairs(data.members) do if m.guid == a.guid then anna = m end end
	eq(anna.name, a.name)
	eq(anna.professions[1].id, TAILORING)
	eq(#anna.professions[1].recipes, 2)
	eq(anna.professions[1].cooldowns[1].recipe, 3915)
	truthy(anna.professions[1].cooldowns[1].readyAt > 0, "time of a shared cooldown")
	eq(data.recipes["3914"].item, 2568)
	eq(data.recipes["3914"].category, 10)
	eq(data.categories["10"].name, "Category 10")
	truthy(json:find('"recipes":{"3914":', 1, true), "recipe table keyed by ID")
	-- One character only.
	local only = E.Build("ann")
	eq(#only.members, 1)
	eq(only.members[1].guid, a.guid)
	-- A filter nobody matches keeps the previous export.
	eq(E.Command("nobody here"), nil)
	eq(cb.env.GuildTradebookExport.json, json, "previous export kept")
	-- "zip": compressed text for the window, plain JSON kept.
	E.compress = function(text) return "<" .. #text .. ">" end
	local plain, shown = E.Command("zip")
	eq(plain, json)
	eq(shown, "GTB1:<" .. #json .. ">")
	eq(cb.env.GuildTradebookExport.json, json)
	local _, shownAnna = E.Command("ZIP anna")
	truthy(shownAnna:find("^GTB1:"), "zip with a name filter")
	E.compress = function() error("no encoder") end
	local _, fallback = E.Command("zip")
	eq(fallback, json, "plain JSON when compressing fails")
end)
