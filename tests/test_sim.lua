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
	local b = world:AddChar({ guid = guid(2), name = "Bert", profs = { [COOKING] = { rank = 50, maxRank = 75, name = "Cooking", recipes = { [2538] = 2679 } } } })
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

test("idle guild: periodic sync stays cheap", function()
	local world = bigGuild(30, 9)
	world:ResetCounters()
	world:Run(3 * 1200)
	local perRound = world.messages / 3
	print(("       idle: %.0f messages per 20 min for 30 clients"):format(perRound))
	truthy(perRound <= 30 * 2 + 10, "about one hello + ack per client and round")
end)
