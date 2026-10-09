--[[
Record store and merge rules. Everything in here is pure (no WoW API calls),
so the split-brain rules can be unit tested and simulated outside the game.

A record is a full snapshot of one character's professions, authored only by
that character (or by the same account while playing an alt). Relayers forward
records unchanged. Records are ordered by (ver, seq, h):
  ver = server time of the owner's last change (shared clock for all clients)
  seq = tie-breaker for changes within the same second / owner reclaim
  h   = content hash, total order for the (theoretical) equal ver+seq case

Internal record:
  { guid, name, class, level, ver, seq, player?, loc?,
    profs = { [skillLineID] = { rank, maxRank, primary?, scannedAt?, unverified?,
                                recipes = { [recipeID] = outputItemID or 0 } | nil,
                                cds = { [recipeID] = readyAt (server time, 0 = ready) } | nil } },
    h,                                     -- content hash
    recvAt?, recvFrom?, goneSince? }       -- local metadata, never sent
]]
local _, ns = ...

local Util = ns.Util
local Store = {}
ns.Store = Store

Store.SCHEMA = 1
Store.FUTURE_TOLERANCE = 300        -- seconds a version may be ahead of our clock
Store.GONE_GRACE = 14 * 86400       -- keep records of ex-members this long (hidden)
Store.MAX_RECORDS = 2000            -- per guild
Store.MAX_PROFS = 12
Store.MAX_RECIPES = 1500            -- per profession
Store.MAX_COOLDOWNS = 50            -- per profession
Store.COOLDOWN_TOLERANCE = 120      -- seconds of drift ignored when re-reading a cooldown
Store.NUM_BUCKETS = 16

-- Professions are shared when the game gives them a crafting window (see
-- Scanner.Snapshot). This list is only the fallback for when the game cannot
-- tell yet: known gathering-only professions without recipes.
Store.NO_RECIPE_SKILLLINES = {
	[182] = true, -- Herbalism
	[393] = true, -- Skinning
}

Store.OPTION_DEFAULTS = {
	debug = false,
	tooltip = true,          -- crafters on craftable items
	tooltipRecipes = true,   -- known / not known on recipe items
	chatResponder = true,    -- answer "!craft" in guild chat
	wishAlerts = true,       -- notice when a wished crafter comes online
	wishSound = true,
	minimapButton = true,
	hideForeignBoP = true,   -- recipe list: hide BoP items only others can craft
}

-- SavedVariables ---------------------------------------------------------------

function Store.InitDB(saved)
	if type(saved) ~= "table" or saved.schema ~= Store.SCHEMA then
		saved = { schema = Store.SCHEMA }
	end
	saved.guilds = saved.guilds or {}
	saved.recipeFacts = saved.recipeFacts or {}
	saved.account = saved.account or {}
	saved.account.chars = saved.account.chars or {}
	saved.options = saved.options or {}
	for k, v in pairs(Store.OPTION_DEFAULTS) do
		if saved.options[k] == nil then
			saved.options[k] = v
		end
	end
	return saved
end

function Store.GetGuild(db, guildKey)
	local gd = db.guilds[guildKey]
	if not gd then
		gd = { chars = {} }
		db.guilds[guildKey] = gd
	end
	return gd
end

-- Hashing and ordering ---------------------------------------------------------

-- Integers as text. Not "%d": WoW's string.format only accepts 32-bit signed
-- values there, and hashes go up to 2^32. "%.0f" is exact up to 2^53.
local function fmt(n)
	return string.format("%.0f", n or 0)
end
Store.FormatInt = fmt

-- Canonical content string: identical on every client for identical content.
function Store.Canonical(rec)
	local parts = { rec.guid, rec.name or "", rec.class or "", fmt(rec.level), fmt(rec.ver), fmt(rec.seq), rec.player or "" }
	for _, sl in ipairs(Util.SortedKeys(rec.profs)) do
		local p = rec.profs[sl]
		parts[#parts + 1] = fmt(sl) .. ":" .. fmt(p.rank) .. ":" .. fmt(p.maxRank) .. ":" .. fmt(p.scannedAt) .. ":" .. (p.unverified and "u" or "") .. (p.primary and "p" or "")
		if p.recipes then
			local r = {}
			for _, rid in ipairs(Util.SortedKeys(p.recipes)) do
				r[#r + 1] = fmt(rid) .. "=" .. fmt(p.recipes[rid])
			end
			parts[#parts + 1] = "[" .. table.concat(r, ",") .. "]"
		else
			parts[#parts + 1] = "-"
		end
		if p.cds and next(p.cds) then
			local c = {}
			for _, rid in ipairs(Util.SortedKeys(p.cds)) do
				c[#c + 1] = fmt(rid) .. "@" .. fmt(p.cds[rid])
			end
			parts[#parts + 1] = "cd[" .. table.concat(c, ",") .. "]"
		end
	end
	return table.concat(parts, "|")
end

function Store.Hash(rec)
	return Util.Hash(Store.Canonical(rec))
end

function Store.Rehash(rec)
	rec.h = Store.Hash(rec)
	return rec.h
end

-- Works on records and on digest entries ({ver, seq, h}). Returns -1, 0, 1.
function Store.CompareVersion(a, b)
	if a.ver ~= b.ver then return a.ver < b.ver and -1 or 1 end
	if a.seq ~= b.seq then return a.seq < b.seq and -1 or 1 end
	local ha, hb = a.h or 0, b.h or 0
	if ha == hb then return 0 end
	return ha < hb and -1 or 1
end

-- Gives `own` a version that is newer than both its current one and `seen`.
-- Server time normally does this by itself; seq covers same-second changes and
-- reclaiming against a copy whose version is ahead of the current time.
function Store.Bump(own, now, seen)
	local maxVer, maxSeq = own.ver or 0, own.seq or 0
	if seen and (seen.ver > maxVer or (seen.ver == maxVer and seen.seq > maxSeq)) then
		maxVer, maxSeq = seen.ver, seen.seq
	end
	if now > maxVer then
		own.ver, own.seq = now, 0
	else
		own.ver, own.seq = maxVer, maxSeq + 1
	end
	Store.Rehash(own)
end

-- Accepting relayed records ----------------------------------------------------

--[[
ctx = {
  now,
  selfGUID,
  isMember = function(guid) -> true | false | nil (roster not loaded yet)
}
Returns one of:
  "accepted"  stored as the newest known version
  "self"      a copy of the logged-in character; caller runs MergeIncomingSelf
  "older" / "same"
  "notmember", "future", "full"
]]
function Store.Accept(gd, rec, ctx, sender)
	if ctx.isMember(rec.guid) == false then
		return "notmember"
	end
	if rec.ver > ctx.now + Store.FUTURE_TOLERANCE then
		return "future"
	end
	if not rec.h then
		Store.Rehash(rec)
	end
	if rec.guid == ctx.selfGUID then
		return "self"
	end
	local cur = gd.chars[rec.guid]
	if cur then
		local c = Store.CompareVersion(rec, cur)
		if c < 0 then return "older" end
		if c == 0 then return "same" end
	elseif Util.Count(gd.chars) >= Store.MAX_RECORDS then
		return "full"
	end
	rec.recvAt = ctx.now
	rec.recvFrom = sender
	rec.goneSince = nil
	gd.chars[rec.guid] = rec
	return "accepted"
end

-- Owner side rules -------------------------------------------------------------

-- Creates the logged-in character's own record if it does not exist yet.
function Store.EnsureOwn(gd, guid)
	local own = gd.chars[guid]
	if not own then
		own = { guid = guid, ver = 0, seq = 0, profs = {} }
		Store.Rehash(own)
		gd.chars[guid] = own
	end
	return own
end

--[[
Diffs the live profession list (snapshot[skillLine] = {rank, maxRank}) into the
owner's record. Returns nil (no change), "minor" (rank only) or "major".
  - profession gone            -> removed (only if allowRemove; the caller confirms
                                  removals with a second snapshot, because the
                                  profession list can be empty during login)
  - new profession             -> added as "not scanned" (recipes = nil)
  - rank went down             -> unlearned and relearned: recipes reset, so stale
                                  copies in the pool can never bring them back
Returns a second value: list of skill lines that would be removed.
]]
function Store.ReconcileProfessions(own, snapshot, allowRemove)
	local kind
	local function mark(k)
		if k == "major" or kind == nil then kind = k end
	end
	local removals = {}
	for sl in pairs(own.profs) do
		if not snapshot[sl] then
			removals[#removals + 1] = sl
		end
	end
	if allowRemove then
		for _, sl in ipairs(removals) do
			own.profs[sl] = nil
			mark("major")
		end
	end
	for sl, s in pairs(snapshot) do
		local p = own.profs[sl]
		if not p then
			own.profs[sl] = { rank = s.rank, maxRank = s.maxRank, primary = s.primary or nil }
			mark("major")
		else
			if s.rank < p.rank then
				p.recipes, p.scannedAt, p.unverified, p.cds = nil, nil, nil, nil
				mark("major")
			end
			if p.rank ~= s.rank or p.maxRank ~= s.maxRank or p.primary ~= (s.primary or nil) then
				p.rank, p.maxRank, p.primary = s.rank, s.maxRank, s.primary or nil
				mark("minor")
			end
		end
	end
	return kind, removals
end

--[[
Applies a scan of the open profession window. Individual recipes are never
unlearned (only whole professions, handled above), so a scan only ever adds -
except that a complete scan replaces recipes adopted from the pool
("unverified"), which may contain stale entries.
Returns true if the record changed.
]]
function Store.ApplyScan(own, skillLine, recipes, complete, now)
	local p = own.profs[skillLine]
	if not p then return false end
	local changed = false
	if not p.recipes or (complete and p.unverified) then
		-- First scan, or a verified list replacing adopted pool data.
		p.recipes = {}
		for rid, item in pairs(recipes) do
			p.recipes[rid] = item
		end
		p.unverified = nil
		changed = true
	else
		for rid, item in pairs(recipes) do
			if p.recipes[rid] ~= item then
				p.recipes[rid] = item
				changed = true
			end
		end
	end
	if changed then
		p.scannedAt = now
	end
	return changed
end

--[[
Cooldowns of one profession, read from the open window:
observed[recipeID] = seconds remaining (0 = ready). Entries are kept once a
recipe is known to have a cooldown, so "ready" can be shown. Re-reading the
same cooldown a little later gives a slightly different readyAt; drift below
COOLDOWN_TOLERANCE is not a change. Returns true if the record changed.
]]
function Store.ApplyCooldowns(own, skillLine, observed, now)
	local p = own.profs[skillLine]
	if not p then return false end
	local changed = false
	for rid, remaining in pairs(observed) do
		local readyAt = remaining > 0 and math.floor(now + remaining) or 0
		local old = p.cds and p.cds[rid]
		local differs
		if old == nil then
			differs = true
		elseif readyAt == 0 then
			differs = old > now
		else
			differs = math.abs(readyAt - old) > Store.COOLDOWN_TOLERANCE
		end
		if differs then
			p.cds = p.cds or {}
			p.cds[rid] = readyAt
			changed = true
		end
	end
	return changed
end

-- Recipe changes of primary professions are published quickly ("major"),
-- secondary ones (Cooking, First Aid, Fishing, ...) are batched ("minor").
function Store.ChangeKind(prof)
	return (prof and prof.primary) and "major" or "minor"
end

-- Removes the recipes of one profession for which shouldRemove(recipeID) is
-- true. Returns true if anything was removed.
function Store.RemoveRecipes(own, skillLine, shouldRemove)
	local p = own.profs[skillLine]
	if not p or not p.recipes then return false end
	local removed = false
	local doomed = {}
	for rid in pairs(p.recipes) do
		if shouldRemove(rid) then doomed[#doomed + 1] = rid end
	end
	for _, rid in ipairs(doomed) do
		p.recipes[rid] = nil
		if p.cds then p.cds[rid] = nil end
		removed = true
	end
	return removed
end

-- Adds one newly learned recipe. Ignored while the profession is unscanned,
-- because a single recipe would make the profession look fully scanned.
function Store.AddLearned(own, skillLine, recipeID, itemID)
	local p = own.profs[skillLine]
	if not p or not p.recipes or p.recipes[recipeID] == itemID then
		return false
	end
	p.recipes[recipeID] = itemID
	return true
end

--[[
Called when the pool hands us a copy of our own (logged-in) character. Live
data always wins, but we adopt recipes for professions we still have and have
not scanned (lost SavedVariables, new PC). Adopted recipes are "unverified"
until the next complete scan. Copies whose rank is above our live rank are
from before an unlearn/relearn and are ignored.
Returns changed, needBump. needBump means our record must be re-published with
a version newer than the copy (owner reclaim).
]]
function Store.MergeIncomingSelf(own, incoming)
	local changed = false
	for sl, p in pairs(own.profs) do
		local ip = incoming.profs[sl]
		if ip and ip.recipes and ip.rank <= p.rank and (p.recipes == nil or p.unverified) then
			p.recipes = p.recipes or {}
			for rid, item in pairs(ip.recipes) do
				if p.recipes[rid] == nil then
					p.recipes[rid] = item
					changed = true
				end
			end
			if ip.cds and not p.cds then
				p.cds = {}
				for rid, readyAt in pairs(ip.cds) do p.cds[rid] = readyAt end
				changed = true
			end
			if changed then
				p.unverified = true
			end
		end
	end
	local needBump = changed or Store.CompareVersion(incoming, own) >= 0
	return changed, needBump
end

-- Player ID --------------------------------------------------------------------

--[[
All characters of one account in a guild carry the same random player ID, so
others can tell which characters belong to the same person (e.g. reach an
offline crafting alt through its online main). Nobody has to set anything up:
the account-wide SavedVariables know the account's characters.

A second PC (or deleted SavedVariables) starts with its own ID. Whenever a
record of one of the account's characters shows another ID, the smaller one
wins, so all copies end up with the same ID.
]]
function Store.IsValidPlayerId(id)
	return type(id) == "string" and #id == 12 and id:match("^%x+$") ~= nil
end

-- rand(lo, hi) like math.random.
function Store.NewPlayerId(rand)
	return ("%04x%04x%04x"):format(rand(0, 65535), rand(0, 65535), rand(0, 65535))
end

--[[
guids  = the account's characters with a record in this guild
extra  = optional ID seen elsewhere (a copy of the logged-in character)
newId  = function() -> fresh ID, used if nothing is known yet
Sets gd.playerId and stamps it on the records. Returns the ID and the list of
records that changed (the caller publishes them with a new version).
]]
function Store.ReconcilePlayerId(gd, guids, extra, newId)
	local best = Store.IsValidPlayerId(gd.playerId) and gd.playerId or nil
	local function consider(id)
		if Store.IsValidPlayerId(id) and (not best or id < best) then best = id end
	end
	consider(extra)
	for _, guid in ipairs(guids) do
		local rec = gd.chars[guid]
		if rec then consider(rec.player) end
	end
	best = best or newId()
	gd.playerId = best
	local stamped = {}
	for _, guid in ipairs(guids) do
		local rec = gd.chars[guid]
		if rec and rec.player ~= best then
			rec.player = best
			Store.Rehash(rec)
			stamped[#stamped + 1] = guid
		end
	end
	return best, stamped
end

-- Membership -------------------------------------------------------------------

-- Hides records of characters that left the guild and deletes them after the
-- grace period. Must only run with a fully loaded roster.
function Store.Prune(gd, isMember, now)
	local removed = 0
	for guid, rec in pairs(gd.chars) do
		if isMember(guid) then
			rec.goneSince = nil
		else
			rec.goneSince = rec.goneSince or now
			if now - rec.goneSince > Store.GONE_GRACE then
				gd.chars[guid] = nil
				removed = removed + 1
			end
		end
	end
	return removed
end

-- Visible to search and relayed to others. Version 0 is an own record still in
-- its adoption window (see Scanner); it has nothing authoritative to share yet.
function Store.IsShareable(rec, isMember)
	return rec.ver > 0 and not rec.goneSince and isMember(rec.guid) ~= false
end

-- Sync digests -----------------------------------------------------------------

function Store.BucketOf(guid)
	return Util.Hash(guid) % Store.NUM_BUCKETS + 1
end

-- Sorted digest entries of one bucket as a flat list {guid, ver, seq, h, ...}.
function Store.BucketEntries(gd, isMember, bucket)
	local guids = {}
	for guid, rec in pairs(gd.chars) do
		if Store.BucketOf(guid) == bucket and Store.IsShareable(rec, isMember) then
			guids[#guids + 1] = guid
		end
	end
	table.sort(guids)
	local flat = {}
	for _, guid in ipairs(guids) do
		local rec = gd.chars[guid]
		if not rec.h then Store.Rehash(rec) end
		flat[#flat + 1] = guid
		flat[#flat + 1] = rec.ver
		flat[#flat + 1] = rec.seq
		flat[#flat + 1] = rec.h
	end
	return flat
end

function Store.BucketHashes(gd, isMember)
	local hashes = {}
	for b = 1, Store.NUM_BUCKETS do
		local flat = Store.BucketEntries(gd, isMember, b)
		local parts = {}
		for i = 1, #flat do
			parts[i] = type(flat[i]) == "number" and fmt(flat[i]) or flat[i]
		end
		hashes[b] = Util.Hash(table.concat(parts, ":"))
	end
	return hashes
end

-- Parses a DIGEST entry list into { [guid] = {ver, seq, h} }. Returns nil if malformed.
function Store.ParseDigest(flat)
	if type(flat) ~= "table" or #flat % 4 ~= 0 or #flat > 4 * Store.MAX_RECORDS then
		return nil
	end
	local out = {}
	for i = 1, #flat, 4 do
		local guid, ver, seq, h = flat[i], flat[i + 1], flat[i + 2], flat[i + 3]
		if not Store.IsValidGUID(guid) or not Util.IsInt(ver, 0, 2 ^ 40) or not Util.IsInt(seq, 0, 2 ^ 31) or not Util.IsInt(h, 0, 2 ^ 32) then
			return nil
		end
		out[guid] = { ver = ver, seq = seq, h = h }
	end
	return out
end

-- Wire format ------------------------------------------------------------------
-- Records travel as compact arrays (CBOR handles arrays more reliably than
-- sparse integer-keyed maps):
--   { guid, name, class, level, ver, seq, player|"", profs, loc|""}
-- loc (client locale, e.g. "deDE") came after 0.1.0: it is not part of the
-- content hash, so 0.1.0 clients (which drop it) compute the same hash and
-- versions stay comparable. It changes only with a new version anyway.
-- Older layout comment:
--   { guid, name, class, level, ver, seq, player|"",
--     { {sl, rank, maxRank, scannedAt, unverified(0/1), {rid, item, ...}|false, primary(0/1),
--        {rid, readyAt, ...}}, ... } }

function Store.IsValidGUID(guid)
	return type(guid) == "string" and #guid <= 40 and guid:match("^Player%-%d+%-%x+$") ~= nil
end

function Store.ToWire(rec)
	local profs = {}
	for _, sl in ipairs(Util.SortedKeys(rec.profs)) do
		local p = rec.profs[sl]
		local flat = false
		if p.recipes then
			flat = {}
			for _, rid in ipairs(Util.SortedKeys(p.recipes)) do
				flat[#flat + 1] = rid
				flat[#flat + 1] = p.recipes[rid]
			end
		end
		local cds = {}
		for _, rid in ipairs(Util.SortedKeys(p.cds or {})) do
			cds[#cds + 1] = rid
			cds[#cds + 1] = p.cds[rid]
		end
		profs[#profs + 1] = { sl, p.rank, p.maxRank, p.scannedAt or 0, p.unverified and 1 or 0, flat, p.primary and 1 or 0, cds }
	end
	return { rec.guid, rec.name or "", rec.class or "", rec.level or 0, rec.ver, rec.seq, rec.player or "", profs, rec.loc or "" }
end

-- Validates untrusted input. Returns record or nil, reason.
function Store.FromWire(w)
	if type(w) ~= "table" then return nil, "not a table" end
	local guid, name, class, level, ver, seq, player, profs, loc = w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9]
	if not Store.IsValidGUID(guid) then return nil, "guid" end
	if not Util.IsString(name, 64) or not Util.IsString(class, 20) then return nil, "name/class" end
	if not Util.IsInt(level, 0, 1000) then return nil, "level" end
	if not Util.IsInt(ver, 0, 2 ^ 40) or not Util.IsInt(seq, 0, 2 ^ 31) then return nil, "version" end
	if player ~= "" and not Store.IsValidPlayerId(player) then return nil, "player" end
	if loc ~= nil and loc ~= "" and not (type(loc) == "string" and loc:match("^%a%a%a%a$")) then return nil, "loc" end
	if type(profs) ~= "table" or #profs > Store.MAX_PROFS then return nil, "profs" end

	local rec = {
		guid = guid, name = name, class = class, level = level, ver = ver, seq = seq,
		player = player ~= "" and player or nil, loc = (loc ~= nil and loc ~= "") and loc or nil, profs = {},
	}
	for i = 1, #profs do
		local p = profs[i]
		if type(p) ~= "table" then return nil, "prof" end
		local sl, rank, maxRank, scannedAt, unverified, flat, primary, cdFlat = p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]
		if not Util.IsInt(sl, 1, 2 ^ 31) or rec.profs[sl] then return nil, "skillLine" end
		if not Util.IsInt(rank, 0, 10000) or not Util.IsInt(maxRank, 0, 10000) then return nil, "rank" end
		if not Util.IsInt(scannedAt, 0, 2 ^ 40) or (unverified ~= 0 and unverified ~= 1) or (primary ~= 0 and primary ~= 1) then
			return nil, "prof meta"
		end
		local recipes
		if flat ~= false then
			if type(flat) ~= "table" or #flat % 2 ~= 0 or #flat > 2 * Store.MAX_RECIPES then return nil, "recipes" end
			recipes = {}
			for j = 1, #flat, 2 do
				local rid, item = flat[j], flat[j + 1]
				if not Util.IsInt(rid, 1, 2 ^ 31) or not Util.IsInt(item, 0, 2 ^ 31) then return nil, "recipe" end
				recipes[rid] = item
			end
		end
		local cds
		if cdFlat ~= nil then
			if type(cdFlat) ~= "table" or #cdFlat % 2 ~= 0 or #cdFlat > 2 * Store.MAX_COOLDOWNS then return nil, "cooldowns" end
			for j = 1, #cdFlat, 2 do
				local rid, readyAt = cdFlat[j], cdFlat[j + 1]
				if not Util.IsInt(rid, 1, 2 ^ 31) or not Util.IsInt(readyAt, 0, 2 ^ 40) then return nil, "cooldown" end
				cds = cds or {}
				cds[rid] = readyAt
			end
		end
		rec.profs[sl] = {
			cds = cds,
			rank = rank, maxRank = maxRank,
			scannedAt = scannedAt ~= 0 and scannedAt or nil,
			unverified = unverified == 1 or nil,
			primary = primary == 1 or nil,
			recipes = recipes,
		}
	end
	Store.Rehash(rec)
	return rec
end

-- Recipe facts -----------------------------------------------------------------
-- recipeFacts[recipeID] = { item = outputItemID (0 = none), enchant = bool,
--                           reagents = { {itemID, qty, optional(0/1)}, ... } | nil, build }
-- Facts are static game data, not ownership data, so any source may fill them.
-- A local API result overrides remote values.

function Store.SetFact(db, recipeID, fact, isLocal, build)
	local cur = db.recipeFacts[recipeID]
	if not cur then
		cur = {}
		db.recipeFacts[recipeID] = cur
	end
	local changed = false
	if fact.item ~= nil and (isLocal or cur.item == nil) then
		if cur.item ~= nil and cur.item ~= fact.item and ns.Debug then
			ns.Debug("fact conflict", recipeID, cur.item, fact.item)
		end
		changed = changed or cur.item ~= fact.item
		cur.item = fact.item
	end
	if fact.enchant ~= nil and (isLocal or cur.enchant == nil) then
		cur.enchant = fact.enchant
	end
	if fact.reagents and (isLocal or not cur.reagents) then
		cur.reagents = fact.reagents
		changed = true
	end
	if isLocal or not cur.build then
		cur.build = build
	end
	return changed
end

-- Copies outputItemIDs carried by a record into the fact cache.
function Store.LearnFactsFromRecord(db, rec, build)
	for _, p in pairs(rec.profs) do
		if p.recipes then
			for rid, item in pairs(p.recipes) do
				local cur = db.recipeFacts[rid]
				if not cur or cur.item == nil then
					Store.SetFact(db, rid, { item = item }, false, build)
				end
			end
		end
	end
end

-- Wire format of facts: { rid, item, enchant(0/1), {itemID, qty, optional, ...} }
function Store.FactToWire(rid, fact)
	local flat = {}
	for _, r in ipairs(fact.reagents or {}) do
		flat[#flat + 1] = r[1]
		flat[#flat + 1] = r[2]
		flat[#flat + 1] = r[3]
	end
	return { rid, fact.item or 0, fact.enchant and 1 or 0, flat }
end

function Store.FactFromWire(w)
	if type(w) ~= "table" then return nil end
	local rid, item, enchant, flat = w[1], w[2], w[3], w[4]
	if not Util.IsInt(rid, 1, 2 ^ 31) or not Util.IsInt(item, 0, 2 ^ 31) or (enchant ~= 0 and enchant ~= 1) then return nil end
	if type(flat) ~= "table" or #flat % 3 ~= 0 or #flat > 3 * 16 then return nil end
	local reagents = {}
	for i = 1, #flat, 3 do
		local id, qty, opt = flat[i], flat[i + 1], flat[i + 2]
		if not Util.IsInt(id, 1, 2 ^ 31) or not Util.IsInt(qty, 1, 1000) or (opt ~= 0 and opt ~= 1) then return nil end
		reagents[#reagents + 1] = { id, qty, opt }
	end
	return rid, { item = item, enchant = enchant == 1, reagents = reagents }
end
