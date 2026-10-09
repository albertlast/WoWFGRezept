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

local function threeMembers()
	math.randomseed(42)
	local world = H.NewWorld()
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

test("restricted channel queues messages until allowed", function()
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
	eq(co.ns.Index.ContactName(c), "Mainy-Realm")
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

test("100 online, fresh install logs in: one elected partner sends the pool once", function()
	local world = bigGuild(100, 5)
	local fresh = world:AddChar({ guid = guid(501), name = "Fresh" })
	world:ResetCounters()
	local cf = world:Login(fresh.guid)
	world:Run(200)
	local t = world.byType
	print(("       fresh install: %d messages %s"):format(world.messages, H.Describe(t)))
	eq(t.P, 1, "one partner request")
	eq(t.A, 1, "exactly one peer accepted")
	eq(t.H, 2, "login sync + follow-up")
	truthy((t.D or 0) <= 16, "at most one digest per bucket")
	truthy((t.R or 0) <= 100 + 2, "each record sent about once")
	for i = 1, 100 do
		truthy(cf:Record(guid(i)), "fresh client has member " .. i)
	end
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

test("!craft from a member without the addon: exactly one answer", function()
	local world = bigGuild(30, 23)
	local nora = world:AddChar({ guid = guid(900), name = "Nora" }) -- no addon, never logs in
	world:GuildChat(nora.name, "!craft Recipe 3005")
	world:Run(30)
	local answers = {}
	for _, line in ipairs(world.chat) do
		if line.text:find("[Guild Tradebook]", 1, true) then answers[#answers + 1] = line.text end
	end
	eq(#answers, 1, "one answer for 30 addon users")
	truthy(answers[1]:find("Recipe 3005: M3", 1, true), "names the crafter: " .. answers[1])

	world:GuildChat(nora.name, "!craft Recipe 3005")
	world:Run(30)
	local again = 0
	for _, line in ipairs(world.chat) do
		if line.text:find("[Guild Tradebook]", 1, true) then again = again + 1 end
	end
	eq(again, 1, "the same question within a minute is not answered twice")
end)

test("!craft is silent when every client disabled it", function()
	local world = bigGuild(5, 24)
	for _, client in pairs(world.online) do
		client.env.GuildTradebookDB.options.chatResponder = false
	end
	world:GuildChat("Nora-Realm", "!craft Recipe 1001")
	world:Run(30)
	eq(#world.chat, 1, "only the question")
end)
