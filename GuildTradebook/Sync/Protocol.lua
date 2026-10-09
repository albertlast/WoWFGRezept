--[[
Sync protocol. Designed for ~100 online addon users: a client that logs in
talks to ONE partner, never to everyone.

Owner updates (broadcast, GUILD):
  R  REC      {r = wire record}         owner changed its record (or reclaim)

Pairwise anti-entropy (WHISPER between two clients):
  H  HELLO    {b = 16 bucket hashes}    "here is my state" -> partner
  K  ACK      {n = buckets that differ} partner is alive (sent even if in sync)
  D  DIGEST   {b, e = entries}          entries of one differing bucket
  W  WANT     {l = guids}               "send me these"
  R  REC      {r = wire record}         records the other side lacks / has older

Partner election (only when no partner is known, e.g. fresh install):
  P  PARTNER? {}                        GUILD broadcast by the newcomer
  A  ACCEPT   {to = name}               GUILD: first elected peer answers; others
                                        see it and stay silent
  Peers rank themselves by hash(newcomer, peer): rank 0 answers at once, rank 1
  after a few seconds only if rank 0 did not, and so on.

Recipe facts (reagents):
  Q  FACT_REQ {l = recipeIDs}           whisper to an online crafter of the recipe
  F  FACT     {f = facts}               whisper answer

Guild chat "!craft" (see Features/ChatResponder.lua):
  X  ANSWERED {k = question key}        GUILD: "I answer this one", others stay silent

A client starts a sync on login and every 20 minutes with a random partner.
Every message carries the protocol major version (p) and the guild key (g).
]]
local _, ns = ...

local Store, Util, Roster = ns.Store, ns.Util, ns.Roster
local P = {
	peers = {},         -- ["Name-Realm"] = GetTime(): seen sending addon messages
	sync = nil,         -- { partner, answered, tried = {}, attempts }
	accepted = {},      -- [newcomer] = true: someone already accepted (election)
	factAsk = {},       -- [recipeID] = true: facts we are about to request
	factRequested = {}, -- [recipeID] = GetTime() of the last request
	pushQueue = {},     -- [guid] = true: account alts to broadcast with the next PushOwn
	outbox = {},
}
ns.Protocol = P

P.SYNC_INTERVAL = 1200
P.PARTNER_TIMEOUT = 10
P.MAX_PARTNER_TRIES = 3
P.ELECTION_SLOT = 3      -- seconds between election ranks
P.ELECTION_RANKS = 4     -- ranks per election round
P.MAX_LIST = 200
P.MAX_FACTS = 50
P.MAX_OUTBOX = 100

-- Tests set this to function(msg, channel, target, prio) to bypass AceComm.
P.transport = nil

local function isMember(guid)
	return Roster.IsMember(guid)
end

function P.Ctx()
	return { now = ns.Now(), selfGUID = UnitGUID("player"), isMember = isMember }
end

local function selfName()
	return Util.NormalizeName(UnitName("player"))
end

-- Sending ----------------------------------------------------------------------

local function restricted()
	return C_ChatInfo.AreOutgoingAddonChatMessagesRestricted and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()
end

local function deliver(msg, channel, target, prio)
	if P.transport then
		P.transport(msg, channel, target, prio)
		return
	end
	local text = ns.Codec.Encode(msg)
	if text then
		P.comm:SendCommMessage(ns.PREFIX, text, channel, target, prio or "BULK")
	end
end

function P.Send(msg, channel, target, prio)
	if not Roster.guildKey then return end
	msg.p = ns.PROTO
	msg.g = Roster.guildKey
	if restricted() then
		table.insert(P.outbox, { msg, channel, target, prio })
		if #P.outbox > P.MAX_OUTBOX then
			table.remove(P.outbox, 1)
		end
		return
	end
	deliver(msg, channel, target, prio)
end

function P.FlushOutbox()
	if #P.outbox == 0 or restricted() then return end
	local queued = P.outbox
	P.outbox = {}
	for _, item in ipairs(queued) do
		if item[1].g == Roster.guildKey then
			deliver(item[1], item[2], item[3], item[4])
		end
	end
end

local function sendRecord(guid, channel, target, prio)
	local gd = ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	if not rec or not Store.IsShareable(rec, isMember) then return end
	P.Send({ t = "R", r = Store.ToWire(rec) }, channel, target, prio or "BULK")
end

-- Owner broadcast of its own record, plus alts of this account that changed
-- while playing another character (see Scanner.UpdatePlayerId).
function P.PushOwn()
	local selfGUID = UnitGUID("player")
	sendRecord(selfGUID, "GUILD", nil, "NORMAL")
	local queued = P.pushQueue
	P.pushQueue = {}
	for _, guid in ipairs(Util.SortedKeys(queued)) do
		if guid ~= selfGUID then
			sendRecord(guid, "GUILD", nil, "NORMAL")
		end
	end
end

function P.QueuePush(guid)
	P.pushQueue[guid] = true
	ns.ScheduleEarliest("pushOwn", 5, P.PushOwn)
end

-- Partner selection ------------------------------------------------------------

-- Online members believed to run the addon (seen sending messages, or owners
-- of a shared record), and the other online members.
function P.Candidates()
	local gd = ns.GetGuildData()
	local me = selfName()
	local known, unknown = {}, {}
	for guid, member in pairs(Roster.members) do
		if member.online and member.name ~= me then
			local rec = gd and gd.chars[guid]
			if P.peers[member.name] or (rec and rec.ver > 0) then
				known[#known + 1] = member.name
			else
				unknown[#unknown + 1] = member.name
			end
		end
	end
	table.sort(known)
	return known, unknown
end

P.EXPLORE_CHANCE = 0.25

-- Random known partner. With `explore`, sometimes an unknown online member:
-- otherwise two groups of clients that never heard of each other would only
-- ever sync among themselves.
local function pickPartner(tried, explore)
	local known, unknown = P.Candidates()
	local function untried(list)
		local out = {}
		for _, name in ipairs(list) do
			if not tried[name] then out[#out + 1] = name end
		end
		return out
	end
	known, unknown = untried(known), untried(unknown)
	-- Avoid the previous partner if anyone else is available.
	if #known > 1 then
		for i, name in ipairs(known) do
			if name == P.lastPartner then table.remove(known, i) break end
		end
	end
	local pool = known
	if explore and #unknown > 0 and (#known == 0 or math.random() < P.EXPLORE_CHANCE) then
		pool = unknown
	end
	if #pool == 0 then return nil end
	return pool[math.random(#pool)]
end

function P.SendHello(partner)
	local gd = ns.GetGuildData()
	if not gd then return end
	P.Send({ t = "H", b = Store.BucketHashes(gd, isMember) }, "WHISPER", partner, "NORMAL")
end

-- Starts one pairwise sync. Falls back to a partner election broadcast.
-- explore: periodic syncs may probe members not known to run the addon.
function P.StartSync(explore)
	if P.sync or not Roster.ready then return end
	local sync = { tried = {}, attempts = 0 }
	P.sync = sync

	local function try()
		if P.sync ~= sync then return end
		local partner = sync.attempts < P.MAX_PARTNER_TRIES and pickPartner(sync.tried, explore)
		if not partner then
			P.sync = nil
			if not explore then
				P.RequestPartner(0)
			end
			return
		end
		sync.attempts = sync.attempts + 1
		sync.tried[partner] = true
		sync.partner, sync.answered = partner, false
		P.lastPartner = partner
		ns.Debug("sync with", partner)
		P.SendHello(partner)
		ns.Debounce("syncTimeout", P.PARTNER_TIMEOUT, function()
			if P.sync == sync and not sync.answered then
				ns.Debug("no answer from", partner)
				try()
			end
		end)
	end
	try()
end

-- Election round `round` covers ranks [round*N, round*N+N).
function P.RequestPartner(round)
	P.electionRound = round
	P.Send({ t = "P", n = round }, "GUILD", nil, "NORMAL")
	ns.Debounce("electionTimeout", P.ELECTION_SLOT * P.ELECTION_RANKS + 5, function()
		if round + 1 < 3 then
			P.RequestPartner(round + 1)
		end
	end)
end

-- Rank of `me` among the clients that could answer `newcomer` (0 = first).
function P.ElectionRank(newcomer, me)
	local list = { me }
	for _, name in ipairs((P.Candidates())) do
		if name ~= newcomer then list[#list + 1] = name end
	end
	table.sort(list, function(a, b)
		local ha, hb = Util.Hash(newcomer .. ">" .. a), Util.Hash(newcomer .. ">" .. b)
		if ha ~= hb then return ha < hb end
		return a < b
	end)
	for i, name in ipairs(list) do
		if name == me then return i - 1 end
	end
end

-- Facts ------------------------------------------------------------------------

-- Ask an online crafter (who scanned the recipe and has its facts); at most
-- once a minute per recipe.
function P.RequestFacts(recipeIDs)
	local now = GetTime()
	for _, rid in ipairs(recipeIDs) do
		local last = P.factRequested[rid]
		if not last or now - last > 60 then
			P.factAsk[rid] = true
			P.factRequested[rid] = now
		end
	end
	if not next(P.factAsk) then return end
	ns.Debounce("Q", 0.5, function()
		local byTarget = {}
		for rid in pairs(P.factAsk) do
			local target
			for _, c in ipairs(ns.Index.Crafters(rid)) do
				if c.online and not c.isSelf then target = c.name break end
			end
			target = target or pickPartner({}, false)
			if target then
				byTarget[target] = byTarget[target] or {}
				if #byTarget[target] < P.MAX_FACTS then
					table.insert(byTarget[target], rid)
				end
			end
		end
		P.factAsk = {}
		for target, list in pairs(byTarget) do
			P.Send({ t = "Q", l = list }, "WHISPER", target, "NORMAL")
		end
	end)
end

-- Receiving --------------------------------------------------------------------

local handlers = {}

-- Owner reclaim: the pool holds a copy of the logged-in character.
function P.OnSelfCopy(rec)
	local own = ns.Scanner.GetOwn()
	if not own then return end
	local changed, needBump = Store.MergeIncomingSelf(own, rec)
	if needBump then
		Store.Bump(own, ns.Now(), rec)
		ns.Debug("reclaim own record", own.ver, own.seq, changed and "(adopted recipes)" or "")
		-- Pending changes are already part of the bumped record.
		ns.Scanner.pendingKind = nil
		ns.Scanner.FinishAdoption()
		ns.Emit("OwnChanged", "major")
		ns.Emit("RecordsChanged", own.guid)
	end
	ns.Scanner.UpdatePlayerId(rec.player)
end

-- Partner side: answer a HELLO with an ACK and the digests that differ.
handlers.H = function(msg, channel, sender, gd)
	if channel ~= "WHISPER" or type(msg.b) ~= "table" or #msg.b ~= Store.NUM_BUCKETS then return end
	local mine = Store.BucketHashes(gd, isMember)
	local differing = {}
	for b = 1, Store.NUM_BUCKETS do
		if msg.b[b] ~= mine[b] then differing[#differing + 1] = b end
	end
	P.Send({ t = "K", n = #differing }, "WHISPER", sender, "NORMAL")
	for _, b in ipairs(differing) do
		P.Send({ t = "D", b = b, e = Store.BucketEntries(gd, isMember, b) }, "WHISPER", sender, "BULK")
	end
end

handlers.K = function(_, _, sender)
	local sync = P.sync
	if sync and sync.partner == sender then
		sync.answered = true
		ns.Cancel("syncTimeout")
		-- The exchange continues with D/W/R; the sync slot is free again.
		P.sync = nil
	end
end

-- Compare a partner's bucket: ask for what is newer there, send what is newer here.
handlers.D = function(msg, channel, sender, gd)
	if channel ~= "WHISPER" then return end
	local bucket = msg.b
	if not Util.IsInt(bucket, 1, Store.NUM_BUCKETS) then return end
	local remote = Store.ParseDigest(msg.e)
	if not remote then return end

	local want = {}
	for guid, rv in pairs(remote) do
		if Store.BucketOf(guid) == bucket and isMember(guid) ~= false then
			local cur = gd.chars[guid]
			if not cur or Store.CompareVersion(rv, cur) > 0 then
				want[#want + 1] = guid
			end
		end
	end
	for guid, rec in pairs(gd.chars) do
		if Store.BucketOf(guid) == bucket and Store.IsShareable(rec, isMember) then
			local rv = remote[guid]
			if not rv or Store.CompareVersion(rec, rv) > 0 then
				sendRecord(guid, "WHISPER", sender)
			end
		end
	end
	for i = 1, #want, P.MAX_LIST do
		local chunk = {}
		for j = i, math.min(i + P.MAX_LIST - 1, #want) do chunk[#chunk + 1] = want[j] end
		P.Send({ t = "W", l = chunk }, "WHISPER", sender, "BULK")
	end
end

handlers.W = function(msg, channel, sender, gd)
	if channel ~= "WHISPER" or type(msg.l) ~= "table" or #msg.l > P.MAX_LIST then return end
	for _, guid in ipairs(msg.l) do
		if Store.IsValidGUID(guid) and gd.chars[guid] then
			sendRecord(guid, "WHISPER", sender)
		end
	end
end

handlers.R = function(msg, channel, sender, gd)
	local rec, err = Store.FromWire(msg.r)
	if not rec then
		ns.Debug("rejected record from", sender, err)
		return
	end
	local status = Store.Accept(gd, rec, P.Ctx(), sender)
	ns.Debug("REC", rec.name, rec.ver, rec.seq, status, "from", sender, channel)
	if status == "self" then
		P.OnSelfCopy(rec)
	elseif status == "accepted" then
		Store.LearnFactsFromRecord(ns.db, rec, ns.Scanner.BuildKey())
		ns.Emit("RecordsChanged", rec.guid)
		if ns.db.account.chars[rec.guid] and rec.player ~= gd.playerId then
			-- One of our alts, changed on another PC: agree on one player ID.
			ns.Scanner.UpdatePlayerId()
		end
	elseif status == "older" then
		-- The sender holds a stale copy: correct just the sender.
		ns.Debounce("fix" .. sender .. rec.guid, 2, function()
			sendRecord(rec.guid, "WHISPER", sender)
		end)
	end
end

handlers.P = function(msg, channel, sender)
	if channel ~= "GUILD" or not Util.IsInt(msg.n, 0, 2) then return end
	P.accepted[sender] = nil
	local rank = P.ElectionRank(sender, selfName())
	local first = msg.n * P.ELECTION_RANKS
	if not rank or rank < first or rank >= first + P.ELECTION_RANKS then return end
	local delay = (rank - first) * P.ELECTION_SLOT + ns.RandomDelay(0, 0.5)
	ns.Debounce("elect" .. sender, delay, function()
		if not P.accepted[sender] then
			P.Send({ t = "A", to = sender }, "GUILD", nil, "NORMAL")
		end
	end)
end

handlers.A = function(msg, channel, sender)
	if channel ~= "GUILD" or type(msg.to) ~= "string" then return end
	P.accepted[msg.to] = true
	ns.Cancel("elect" .. msg.to)
	if msg.to == selfName() and P.electionRound and not P.sync then
		P.electionRound = nil
		ns.Cancel("electionTimeout")
		P.sync = { tried = { [sender] = true }, attempts = 1, partner = sender, answered = false }
		P.SendHello(sender)
	end
end

handlers.Q = function(msg, channel, sender)
	if channel ~= "WHISPER" or type(msg.l) ~= "table" or #msg.l > P.MAX_FACTS then return end
	local list = {}
	for _, rid in ipairs(msg.l) do
		local fact = Util.IsInt(rid, 1, 2 ^ 31) and ns.db.recipeFacts[rid]
		if fact and fact.reagents then
			list[#list + 1] = Store.FactToWire(rid, fact)
		end
	end
	if #list > 0 then
		P.Send({ t = "F", f = list }, "WHISPER", sender, "BULK")
	end
end

handlers.F = function(msg)
	if type(msg.f) ~= "table" or #msg.f > P.MAX_FACTS then return end
	local changed = false
	local build = ns.Scanner.BuildKey()
	for _, w in ipairs(msg.f) do
		local rid, fact = Store.FactFromWire(w)
		if rid and Store.SetFact(ns.db, rid, fact, false, build) then
			changed = true
		end
	end
	if changed then
		ns.Emit("FactsChanged")
	end
end

handlers.X = function(msg, channel)
	if channel == "GUILD" and Util.IsInt(msg.k, 0, 2 ^ 32) then
		ns.Emit("CraftQueryAnswered", msg.k)
	end
end

function P.Handle(msg, channel, sender)
	sender = Util.NormalizeName(sender)
	if not sender or sender == selfName() then return end
	if type(msg) ~= "table" or msg.p ~= ns.PROTO or msg.g ~= Roster.guildKey then return end
	if Roster.IsMemberName(sender) == false then return end
	P.peers[sender] = GetTime()
	local gd = ns.GetGuildData()
	local handler = handlers[msg.t]
	if gd and handler then
		handler(msg, channel, sender, gd)
	end
end

function P.OnComm(prefix, text, channel, sender)
	if prefix ~= ns.PREFIX then return end
	local msg = ns.Codec.Decode(text)
	if msg then
		P.Handle(msg, channel, sender)
	end
end

-- Lifecycle --------------------------------------------------------------------

function P.Prune()
	local gd = ns.GetGuildData()
	if not gd or not Roster.ready then return end
	local removed = Store.Prune(gd, function(guid) return Roster.IsMember(guid) end, ns.Now())
	if removed > 0 then
		ns.Debug("pruned", removed, "records of former members")
	end
	ns.Emit("RecordsChanged")
end

function P.OnRosterReady()
	P.Prune()
	-- No broadcast on login: the own record is only broadcast when it changes.
	ns.Debounce("startup", ns.RandomDelay(5, 15), function() P.StartSync(false) end)
	-- A partner that logged in at the same time may be stale itself; a second
	-- sync with someone else shortly after closes that gap (2 messages if in sync).
	ns.Debounce("startup2", ns.RandomDelay(60, 90), function() P.StartSync(false) end)
end

function P.OnOwnChanged(kind)
	-- Profession or recipe changes go out quickly, rank-ups are batched.
	local delay = kind == "major" and 5 or 60
	ns.ScheduleEarliest("pushOwn", delay, P.PushOwn)
end

function P.Start()
	if not P.transport then
		P.comm = {}
		LibStub("AceComm-3.0"):Embed(P.comm)
		P.comm:RegisterComm(ns.PREFIX, P.OnComm)
	end

	ns.On("RosterReady", P.OnRosterReady)
	ns.On("RosterUpdated", function() ns.Debounce("prune", 5, P.Prune) end)
	ns.On("OwnChanged", P.OnOwnChanged)
	ns.On("GuildChanged", function()
		P.sync, P.peers, P.accepted, P.pushQueue = nil, {}, {}, {}
	end)

	C_Timer.NewTicker(15, P.FlushOutbox)
	C_Timer.NewTicker(P.SYNC_INTERVAL, function()
		ns.After(ns.RandomDelay(0, 120), function() P.StartSync(true) end)
	end)
end
