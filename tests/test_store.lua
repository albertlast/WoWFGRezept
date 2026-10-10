local H = ...
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

local ns = H.LoadPure()
local Store = ns.Store

local A = "Player-1-0000000A"
local B = "Player-1-0000000B"

local function rec(guid, ver, seq, profs)
	local r = { guid = guid, name = "X-Realm", class = "MAGE", level = 60, ver = ver, seq = seq or 0, profs = profs or {} }
	Store.Rehash(r)
	return r
end

local function members(list)
	local set = {}
	for _, g in ipairs(list) do set[g] = true end
	return function(guid) return set[guid] == true end
end

local function ctx(now, isMember, selfGUID)
	return { now = now, isMember = isMember or function() return true end, selfGUID = selfGUID }
end

print("Store")

test("hash is stable and content sensitive", function()
	local a = rec(A, 100, 0, { [197] = { rank = 10, maxRank = 75, recipes = { [1] = 2, [3] = 4 } } })
	local b = rec(A, 100, 0, { [197] = { rank = 10, maxRank = 75, recipes = { [3] = 4, [1] = 2 } } })
	eq(a.h, b.h, "same content, same hash")
	local c = rec(A, 100, 0, { [197] = { rank = 10, maxRank = 75, recipes = { [1] = 2 } } })
	truthy(a.h ~= c.h, "different recipes, different hash")
	eq(ns.Util.Hash("abc"), ns.Util.Hash("abc"))
end)

test("newer version wins, older and same are rejected", function()
	local gd = { chars = {} }
	eq(Store.Accept(gd, rec(A, 100), ctx(1000)), "accepted")
	eq(Store.Accept(gd, rec(A, 90), ctx(1000)), "older")
	eq(Store.Accept(gd, rec(A, 100), ctx(1000)), "same")
	eq(Store.Accept(gd, rec(A, 100, 1), ctx(1000)), "accepted", "higher seq at same ver")
	eq(gd.chars[A].seq, 1)
end)

test("future-dated versions are rejected", function()
	local gd = { chars = {} }
	eq(Store.Accept(gd, rec(A, 1000 + Store.FUTURE_TOLERANCE + 1), ctx(1000)), "future")
	eq(Store.Accept(gd, rec(A, 1000 + Store.FUTURE_TOLERANCE), ctx(1000)), "accepted")
end)

test("non-members are rejected only with a loaded roster", function()
	local gd = { chars = {} }
	eq(Store.Accept(gd, rec(A, 100), ctx(1000, members({ B }))), "notmember")
	eq(Store.Accept(gd, rec(A, 100), ctx(1000, function() return nil end)), "accepted", "unknown roster accepts")
end)

test("copies of the logged-in character are routed to the owner", function()
	local gd = { chars = {} }
	eq(Store.Accept(gd, rec(A, 100), ctx(1000, nil, A)), "self")
	falsy(gd.chars[A], "never stored over the owner's record")
end)

test("profession dropped: removed only when confirmed", function()
	local own = rec(A, 100, 0, { [197] = { rank = 100, maxRank = 150, recipes = { [1] = 2 } } })
	local kind, removals = Store.ReconcileProfessions(own, {}, false)
	eq(kind, nil)
	eq(#removals, 1)
	truthy(own.profs[197], "kept until confirmed")
	kind = Store.ReconcileProfessions(own, {}, true)
	eq(kind, "major")
	falsy(own.profs[197])
end)

test("new profession starts unscanned", function()
	local own = rec(A, 100)
	eq(Store.ReconcileProfessions(own, { [171] = { rank = 1, maxRank = 75 } }, true), "major")
	eq(own.profs[171].recipes, nil)
end)

test("rank drop means relearn: recipes reset", function()
	local own = rec(A, 100, 0, { [197] = { rank = 200, maxRank = 225, scannedAt = 5, recipes = { [1] = 2 } } })
	eq(Store.ReconcileProfessions(own, { [197] = { rank = 1, maxRank = 75 } }, true), "major")
	eq(own.profs[197].recipes, nil)
	eq(own.profs[197].rank, 1)
end)

test("rank increase is a minor change", function()
	local own = rec(A, 100, 0, { [197] = { rank = 10, maxRank = 75, recipes = {} } })
	eq(Store.ReconcileProfessions(own, { [197] = { rank = 11, maxRank = 75 } }, true), "minor")
	truthy(own.profs[197].recipes, "recipes kept")
end)

test("scan adds recipes and never shrinks verified data", function()
	local own = rec(A, 100, 0, { [197] = { rank = 10, maxRank = 75 } })
	truthy(Store.ApplyScan(own, 197, { [1] = 11, [2] = 12 }, true, 500))
	eq(own.profs[197].scannedAt, 500)
	falsy(Store.ApplyScan(own, 197, { [1] = 11 }, true, 600), "subset is not a change")
	truthy(own.profs[197].recipes[2], "not removed by a partial list")
	truthy(Store.ApplyScan(own, 197, { [3] = 13 }, false, 700))
	eq(ns.Util.Count(own.profs[197].recipes), 3)
end)

test("complete scan replaces unverified (adopted) recipes", function()
	local own = rec(A, 100, 0, { [197] = { rank = 10, maxRank = 75, unverified = true, recipes = { [1] = 11, [99] = 199 } } })
	truthy(Store.ApplyScan(own, 197, { [1] = 11 }, true, 500))
	falsy(own.profs[197].unverified)
	falsy(own.profs[197].recipes[99], "stale adopted recipe removed")
end)

test("partial scan keeps unverified flag", function()
	local own = rec(A, 100, 0, { [197] = { rank = 10, maxRank = 75, unverified = true, recipes = { [1] = 11 } } })
	Store.ApplyScan(own, 197, { [2] = 12 }, false, 500)
	truthy(own.profs[197].unverified)
end)

test("lost SavedVariables: adopt recipes only for current professions", function()
	local own = rec(A, 0, 0, {
		[197] = { rank = 150, maxRank = 225 },   -- still known, unscanned
	})
	local incoming = rec(A, 90, 0, {
		[197] = { rank = 140, maxRank = 225, recipes = { [1] = 11, [2] = 12 } },
		[171] = { rank = 100, maxRank = 150, recipes = { [5] = 15 } }, -- dropped since
	})
	local changed, needBump = Store.MergeIncomingSelf(own, incoming)
	truthy(changed)
	truthy(needBump)
	eq(ns.Util.Count(own.profs[197].recipes), 2)
	truthy(own.profs[197].unverified)
	falsy(own.profs[171], "dropped profession not resurrected")
end)

test("copy with a higher rank is from before a relearn: not adopted", function()
	local own = rec(A, 0, 0, { [197] = { rank = 5, maxRank = 75 } })
	local incoming = rec(A, 90, 0, { [197] = { rank = 200, maxRank = 225, recipes = { [1] = 11 } } })
	local changed = Store.MergeIncomingSelf(own, incoming)
	falsy(changed)
	eq(own.profs[197].recipes, nil)
end)

test("verified own data is never overwritten by a pool copy", function()
	local own = rec(A, 100, 0, { [197] = { rank = 150, maxRank = 225, recipes = { [1] = 11 } } })
	local incoming = rec(A, 50, 0, { [197] = { rank = 140, maxRank = 225, recipes = { [1] = 11, [7] = 17 } } })
	local changed, needBump = Store.MergeIncomingSelf(own, incoming)
	falsy(changed)
	falsy(needBump, "older copy needs no reclaim")
	falsy(own.profs[197].recipes[7])
end)

test("owner reclaim beats a copy that is ahead in time", function()
	local own = rec(A, 1000, 0)
	local forged = rec(A, 1200, 3)
	local _, needBump = Store.MergeIncomingSelf(own, forged)
	truthy(needBump)
	Store.Bump(own, 1001, forged)
	eq(Store.CompareVersion(own, forged), 1)
	eq(own.ver, 1200)
	eq(own.seq, 4)
end)

test("bump uses server time when it is ahead", function()
	local own = rec(A, 1000, 5)
	Store.Bump(own, 2000)
	eq(own.ver, 2000)
	eq(own.seq, 0)
	Store.Bump(own, 2000)
	eq(own.seq, 1, "same second increments seq")
end)

test("prune hides then deletes former members", function()
	local gd = { chars = { [A] = rec(A, 100), [B] = rec(B, 100) } }
	local isMember = members({ A })
	Store.Prune(gd, isMember, 1000)
	eq(gd.chars[B].goneSince, 1000)
	falsy(Store.IsShareable(gd.chars[B], isMember))
	eq(Store.Prune(gd, isMember, 1000 + Store.GONE_GRACE + 1), 1)
	falsy(gd.chars[B])
	truthy(gd.chars[A])
end)

test("rejoining clears the hidden flag", function()
	local gd = { chars = { [B] = rec(B, 100) } }
	Store.Prune(gd, members({}), 1000)
	Store.Prune(gd, members({ B }), 2000)
	eq(gd.chars[B].goneSince, nil)
end)

test("data of guilds you left goes after the retention time, own characters stay", function()
	local db = { guilds = {
		["Now-R"] = { chars = { a = {} }, seenAt = 1 },
		["Old-R"] = { chars = { b = {}, mine = {}, movedAway = {} }, seenAt = 1000 },
		["Gone-R"] = { chars = { c = {} }, seenAt = 1000 },
		["Legacy-R"] = { chars = { d = {} } },
	} }
	local account = { mine = { guildKey = "Old-R" }, movedAway = { guildKey = "Now-R" } }
	local t = 1000 + Store.GUILD_RETENTION
	eq(Store.PruneGuilds(db, "Now-R", t, account), 0, "not yet")
	eq(db.guilds["Legacy-R"].seenAt, t, "older entries start counting now")
	eq(Store.PruneGuilds(db, "Now-R", t + 1, account), 3)
	truthy(db.guilds["Now-R"].chars.a, "the current guild is never touched")
	truthy(db.guilds["Old-R"].chars.mine, "an own character still in that guild keeps its record")
	falsy(db.guilds["Old-R"].chars.b)
	falsy(db.guilds["Old-R"].chars.movedAway, "own character now in another guild: gone here")
	falsy(db.guilds["Gone-R"], "nothing left: the guild entry goes")
	truthy(db.guilds["Legacy-R"], "still counting")
end)

test("record link offer: travels in slot 10, not hashed, validated", function()
	local r = rec(A, 1000, 0)
	r.offer = "00ab12cd34ef"
	local back = assert(Store.FromWire(H.DeepCopy(Store.ToWire(r))))
	eq(back.offer, "00ab12cd34ef")
	eq(Store.Hash(back), Store.Hash(r))
	r.offer = nil
	eq(Store.Hash(back), Store.Hash(r), "not part of the hash")
	local w = Store.ToWire(back)
	w[10] = "bad"
	falsy(Store.FromWire(w))
	w[10] = nil
	eq(assert(Store.FromWire(w)).offer, nil, "0.1.0 relays drop it")
end)

test("same version from a 0.1.0 relay first: the unhashed slots come back with a later copy", function()
	local gd = { chars = {} }
	local ctx = { now = 2000, selfGUID = B, isMember = function() return true end }
	local full = rec(A, 1000, 0)
	full.offer, full.loc = "00ab12cd34ef", "deDE"
	local stripped = assert(Store.FromWire((function() local w = Store.ToWire(full) w[9], w[10] = nil, nil return w end)()))
	eq(Store.Accept(gd, stripped, ctx, "Olli"), "accepted")
	falsy(gd.chars[A].offer)
	eq(Store.Accept(gd, assert(Store.FromWire(Store.ToWire(full))), ctx, "Otto"), "filled")
	eq(gd.chars[A].offer, "00ab12cd34ef")
	eq(gd.chars[A].loc, "deDE")
	eq(Store.Accept(gd, assert(Store.FromWire(Store.ToWire(full))), ctx, "Otto"), "same")
end)

test("wire round trip preserves content and hash", function()
	local r = rec(A, 12345, 2, {
		[197] = { rank = 150, maxRank = 225, scannedAt = 999, recipes = { [3914] = 2568, [8776] = 0 } },
		[171] = { rank = 1, maxRank = 75 },
		[164] = { rank = 50, maxRank = 75, unverified = true, primary = true, recipes = { [2660] = 2862 } },
	})
	r.player = "00ab12cd34ef"
	Store.Rehash(r)
	local back = assert(Store.FromWire(H.DeepCopy(Store.ToWire(r))))
	eq(back.h, r.h)
	eq(back.player, "00ab12cd34ef")
	-- The client locale travels along but is not hashed (0.1.0 compatibility).
	r.loc = "deDE"
	local withLoc = assert(Store.FromWire(H.DeepCopy(Store.ToWire(r))))
	eq(withLoc.loc, "deDE")
	eq(Store.Hash(withLoc), r.h)
	local old = Store.ToWire(r)
	old[9] = nil -- a 0.1.0 client sends 8 fields
	eq(assert(Store.FromWire(old)).loc, nil)
	old[9] = "not a locale"
	falsy(Store.FromWire(old))
	eq(back.profs[171].recipes, nil)
	truthy(back.profs[164].unverified)
	truthy(back.profs[164].primary)
	eq(back.profs[197].primary, nil)
	eq(back.profs[197].recipes[8776], 0)
end)

test("malformed wire records are rejected", function()
	local good = Store.ToWire(rec(A, 100, 0, { [197] = { rank = 1, maxRank = 75, recipes = { [1] = 2 } } }))
	local function mutate(fn)
		local w = H.DeepCopy(good)
		fn(w)
		return Store.FromWire(w)
	end
	falsy(Store.FromWire("x"))
	falsy(mutate(function(w) w[1] = "Creature-1-2" end), "bad guid")
	falsy(mutate(function(w) w[5] = -1 end), "negative ver")
	falsy(mutate(function(w) w[5] = 1.5 end), "fractional ver")
	falsy(mutate(function(w) w[8][1][6] = { 1 } end), "odd recipe list")
	falsy(mutate(function(w) w[8][1][6] = { 1, "x" } end), "non-numeric item")
	falsy(mutate(function(w) w[8][2] = w[8][1] end), "duplicate skill line")
	falsy(mutate(function(w) w[2] = string.rep("a", 100) end), "long name")
	truthy(mutate(function() end), "unchanged is valid")
end)

test("digest round trip and bucket hashes", function()
	local gd = { chars = { [A] = rec(A, 100), [B] = rec(B, 200) } }
	local isMember = function() return true end
	local seen = 0
	for b = 1, Store.NUM_BUCKETS do
		local flat = Store.BucketEntries(gd, isMember, b)
		local parsed = assert(Store.ParseDigest(flat))
		for guid, v in pairs(parsed) do
			seen = seen + 1
			eq(v.ver, gd.chars[guid].ver)
			eq(v.h, gd.chars[guid].h)
		end
	end
	eq(seen, 2)
	local h1 = Store.BucketHashes(gd, isMember)
	gd.chars[A] = rec(A, 101)
	local h2 = Store.BucketHashes(gd, isMember)
	local diff = 0
	for b = 1, Store.NUM_BUCKETS do
		if h1[b] ~= h2[b] then diff = diff + 1 end
	end
	eq(diff, 1, "exactly the changed bucket differs")
	falsy(Store.ParseDigest({ A, 1, 2 }), "wrong arity")
end)

test("facts: local beats remote, remote only fills gaps", function()
	local db = Store.InitDB(nil)
	Store.SetFact(db, 1, { item = 5 }, false, "1.60")
	eq(db.recipeFacts[1].item, 5)
	Store.SetFact(db, 1, { item = 6 }, false, "1.60")
	eq(db.recipeFacts[1].item, 5, "remote does not override")
	Store.SetFact(db, 1, { item = 7, reagents = { { 2589, 2, 0 } } }, true, "1.60")
	eq(db.recipeFacts[1].item, 7, "local overrides")
	local rid, fact = Store.FactFromWire(H.DeepCopy(Store.FactToWire(1, db.recipeFacts[1])))
	eq(rid, 1)
	eq(fact.reagents[1][1], 2589)
	falsy(Store.FactFromWire({ 1, 7, 0, { 2589, 0, 0 } }), "zero quantity rejected")
end)

test("player ID: malformed IDs are rejected on the wire", function()
	local w = Store.ToWire(rec(A, 100))
	w[7] = "not-an-id"
	falsy(Store.FromWire(w))
	w[7] = ""
	truthy(Store.FromWire(w))
end)

test("player ID: one ID for all of the account's characters, smallest wins", function()
	local gd = { chars = { [A] = rec(A, 100), [B] = rec(B, 100) } }
	local fresh = 0
	local function newId() fresh = fresh + 1 return "bbbbbbbbbbbb" end
	local id, stamped = Store.ReconcilePlayerId(gd, { A, B }, nil, newId)
	eq(id, "bbbbbbbbbbbb")
	eq(fresh, 1)
	eq(#stamped, 2)
	eq(gd.chars[B].player, id)
	eq(gd.chars[A].h, Store.Hash(gd.chars[A]))
	-- Nothing to do the second time.
	id, stamped = Store.ReconcilePlayerId(gd, { A, B }, nil, newId)
	eq(#stamped, 0)
	eq(fresh, 1)
	-- A copy from another PC carries a smaller ID: everyone moves to it.
	id, stamped = Store.ReconcilePlayerId(gd, { A, B }, "aaaaaaaaaaaa", newId)
	eq(id, "aaaaaaaaaaaa")
	eq(gd.playerId, "aaaaaaaaaaaa")
	eq(#stamped, 2)
	-- A larger one is ignored.
	id, stamped = Store.ReconcilePlayerId(gd, { A, B }, "cccccccccccc", newId)
	eq(id, "aaaaaaaaaaaa")
	eq(#stamped, 0)
end)

test("player ID: generated IDs are valid", function()
	local id = Store.NewPlayerId(math.random)
	truthy(Store.IsValidPlayerId(id), id)
	truthy(Store.IsValidPlayerId(Store.NewPlayerId(function(_, hi) return hi end)))
end)
