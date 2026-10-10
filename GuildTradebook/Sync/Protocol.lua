--[[
Sync protocol. Designed for ~100 online addon users: a client that logs in
talks to ONE partner, never to everyone.

Owner updates (broadcast, GUILD):
  R  REC      {r = wire record}         owner changed its record (or reclaim)
  Profession or recipe changes go out after 5 s. Rank-ups are batched, and
  the batch interval grows with the guild (P.MinorDelay): the whole guild
  sends about GUILD_RECORD_BUDGET of them per minute, however many craft.

Pairwise anti-entropy (WHISPER between two clients):
  H  HELLO    {b = 16 bucket hashes,    "here is my state" -> partner
               o = buckets?}            o: only these buckets (second partner, below)
  K  ACK      {n = buckets that differ} partner is alive (sent even if in sync)
  D  DIGEST   {b, e = entries}          entries of one differing bucket
  W  WANT     {l = guids}               "send me these"
  R  REC      {r = wire record}         records the other side lacks / has older
  B  BATCH    {l = wire records}        several records in one message, to members
                                        that read batches (bt in their messages):
                                        sorted by profession, so Deflate finds the
                                        recipe lists they share
  Requested records are remembered (P.wanted): while the partner that was
  asked keeps delivering, nobody else is asked for them. Many records
  missing (fresh install): the buckets are split, half from this partner,
  half from a second one at the same time (HELLO with o).

Partner election (only when no partner is known, e.g. fresh install):
  P  PARTNER? {}                        GUILD broadcast by the newcomer
  A  ACCEPT   {to = name}               GUILD: first elected peer answers; others
                                        see it and stay silent
  Peers rank themselves by hash(newcomer, peer): rank 0 answers at once, rank 1
  after a few seconds only if rank 0 did not, and so on.

Recipe facts (reagents):
  Q  FACT_REQ {l = recipeIDs}           whisper to an online crafter of the recipe
  F  FACT     {f = facts}               whisper answer

Recipe categories (see Search/Categories.lua):
  C  CAT_REQ  {l = categoryIDs,         whisper: names, preferably to a member of our language,
               r = recipeIDs}           and the category of recipes that came without one
  E  CAT      {c = categories,          whisper answer: every language the sender knows,
               r = {recipeID, categoryID, ...}}  and the recipes' categories

Guild chat "!craft" (see Features/ChatResponder.lua):
  X  ANSWERED {k = question key}        GUILD: "I answer this one", others stay silent

A client starts a sync on login and every 20 minutes with a random partner.
Every message carries the protocol major version (p), the guild key (g), the
sender's GUID (u), addon version and build (av, ab; see Versions) and
bt = 1 (reads BATCH; 0.1.0 and 0.2.0 do not send it). Other fields belong to
the message type, so these names must not be reused.
]]
local _, ns = ...

local Store, Util, Roster = ns.Store, ns.Util, ns.Roster
local P = {
	peers = {},         -- [guid] = GetTime(): seen sending addon messages
	sync = nil,         -- { partner (guid), answered, tried = {[guid]}, attempts }
	accepted = {},      -- [newcomer guid] = true: someone already accepted (election)
	factAsk = {},       -- [recipeID] = true: facts we are about to request
	factRequested = {}, -- [recipeID] = GetTime() of the last request
	pushQueue = {},     -- [guid] = true: account alts to broadcast with the next PushOwn
	guildSenders = {},  -- [guid] = GetTime() of their last record broadcast (P.MinorDelay)
	batchPeers = {},    -- [guid] = true: their messages say they read BATCH
	wanted = {},        -- [guid] = { ver, seq, h, from, at }: requested, not received yet
	deliveredAt = {},   -- [guid] = GetTime(): last record received from this member by whisper
	outRecords = {},    -- [target name] = { guid = .., set = {[guid] = true} }: records about to go out
	split = nil,        -- { partner, at, deferred = {[guid] = digest entry} } (fresh install)
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
P.MAX_CATEGORIES = 100
P.MAX_CATEGORY_RECIPES = 200
P.MAX_OUTBOX = 100
P.MAJOR_DELAY = 5            -- seconds: profession or recipe changes
P.MINOR_DELAY = 60           -- seconds: rank-ups, in a small guild
P.MINOR_DELAY_MAX = 900      -- seconds: rank-ups, however busy the guild is
P.GUILD_RECORD_BUDGET = 40   -- rank-up broadcasts per minute for the whole guild
P.SENDER_WINDOW = 900        -- seconds: who broadcast in this window counts as active
P.BATCH_RECORDS = 16         -- records per BATCH (Deflate looks back 32 KB)
P.BATCH_GATHER = 1           -- seconds: records for one member are collected this long
P.WANT_PATIENCE = 60         -- seconds: a request stays with a partner that delivered this recently
P.SPLIT_MIN = 4              -- missing records in one bucket that start a split
P.SPLIT_WAIT = 30            -- seconds: deferred buckets then go to the first partner after all
P.SPLIT_WINDOW = 120         -- seconds: one split at a time

-- Tests set this to function(msg, channel, target, prio) to bypass AceComm.
P.transport = nil

local function isMember(guid)
	return Roster.IsMember(guid)
end

function P.Ctx()
	return { now = ns.Now(), selfGUID = UnitGUID("player"), isMember = isMember }
end

local function selfName()
	return Util.PlayerName()
end

-- Sending ----------------------------------------------------------------------

-- Addon messages are blocked while chat messaging is locked down (e.g. during
-- encounters); until then they wait in the outbox. Not
-- AreOutgoingAddonChatMessagesRestricted: it is true on the Forever beta
-- realm, where addon messages and guild chat from addons work fine.
local function restricted()
	return C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

local function outgoingRestrictedFlag()
	return C_ChatInfo.AreOutgoingAddonChatMessagesRestricted and C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()
end

local function sendResultName(result)
	if type(result) ~= "number" then return tostring(result) end
	for name, value in pairs(Enum.SendAddonMessageResult or {}) do
		if value == result then return name end
	end
	return tostring(result)
end

-- AceComm reports each sent chunk; only failures are worth a log line.
local function onSent(what, _, _, result)
	if result ~= nil and result ~= 0 and result ~= true then
		ns.Debug("send failed:", what, sendResultName(result))
	end
end

--[[
Whispers go to "First Last" on your own realm and "First Last-Realm"
elsewhere, the way Blizzard builds whisper targets
(ConcatinateServerNameToPlayerName). When the server answers "No player
named ... is currently playing", there are two cases:
  - nothing heard from the member lately: it went offline and the roster is
    behind. It counts as offline for a while (Roster.Note, private), the
    whispers are dropped, and a sync with it moves on to the next partner.
  - a message from it arrived within HEARD_WINDOW, or the same name fails
    again after the offline time while the roster still shows the member
    online: its name can not be whispered. It gets messages on the GUILD channel instead,
    addressed to its GUID: the text starts with "@<guid>@", and every other
    client skips it without decoding.
]]
P.unreachable = {}   -- ["Name-Realm"] = true: a whisper to this member failed
P.whispered = {}     -- [whisper target] = { at = GetTime(), name, guid, sent = { {msg, prio}, ... } }
P.RESEND_WINDOW = 10 -- seconds: whispers this recent are resent when they fail
P.MAX_RESEND = 50
P.HEARD_WINDOW = 60  -- seconds: a member heard from this recently is online
P.failedAt = {}      -- ["Name-Realm"] = GetTime() of the first failure taken as "offline"

function P.CanWhisper(name)
	return name ~= nil and not P.unreachable[name]
end

function P.WhisperTarget(name)
	return Util.ShortName(name)
end

local ADDRESS_PATTERN = "^@(Player%-%d+%-%x+)@"

-- Recent whispers per target: the "No player named" error comes back after a
-- moment, when a whole reply burst (ack + digests) may already be out.
local function rememberWhisper(target, name, msg, prio, guid)
	local entry = P.whispered[target]
	if not entry or GetTime() - entry.at > P.RESEND_WINDOW then
		entry = { sent = {} }
		P.whispered[target] = entry
	end
	entry.at, entry.name, entry.guid = GetTime(), name, guid or entry.guid
	if #entry.sent < P.MAX_RESEND then
		table.insert(entry.sent, { msg, prio })
	end
end

local function deliver(msg, channel, target, prio, addressee)
	ns.Debug("send", msg.t, channel, target or addressee or "")
	if P.transport then
		P.transport(msg, channel, target, prio, addressee)
		return
	end
	local text = ns.Codec.Encode(msg)
	if text then
		if addressee then
			text = "@" .. addressee .. "@" .. text
		end
		P.comm:SendCommMessage(ns.PREFIX, text, channel, target, prio or "BULK", onSent,
			msg.t .. " " .. channel .. " " .. (target or addressee or ""))
	end
end

-- channel "WHISPER": target is a member's "Name-Realm"; targetGUID
-- (optional) is used when the name can not be whispered and the roster does
-- not know it.
function P.Send(msg, channel, target, prio, targetGUID)
	if not Roster.guildKey then return end
	msg.p = ns.PROTO
	msg.g = Roster.guildKey
	msg.u = UnitGUID("player")
	msg.av, msg.ab = ns.Versions.Mine()
	msg.bt = 1
	local addressee
	if channel == "WHISPER" and Roster.KnownOffline(targetGUID or Roster.byName[target]) then
		ns.Debug("skip", msg.t, "to", tostring(target), "(offline)")
		return
	end
	if channel == "WHISPER" and not P.CanWhisper(target) then
		addressee = targetGUID or Roster.byName[target]
		if not addressee then
			ns.Debug("can not reach", tostring(target))
			return
		end
		channel, target = "GUILD", nil
	elseif channel == "WHISPER" then
		local whisperTo = P.WhisperTarget(target)
		rememberWhisper(whisperTo, target, msg, prio, targetGUID or Roster.byName[target])
		target = whisperTo
	end
	if restricted() then
		ns.Debug("queued", msg.t, "(chat messaging lockdown)")
		table.insert(P.outbox, { msg, channel, target, prio, addressee })
		if #P.outbox > P.MAX_OUTBOX then
			table.remove(P.outbox, 1)
		end
		return
	end
	deliver(msg, channel, target, prio, addressee)
end

function P.FlushOutbox()
	if #P.outbox == 0 or restricted() then return end
	local queued = P.outbox
	P.outbox = {}
	for _, item in ipairs(queued) do
		if item[1].g == Roster.guildKey then
			deliver(item[1], item[2], item[3], item[4], item[5])
		end
	end
end

-- "No player named 'X' is currently playing." after one of our addon
-- whispers: X is unreachable by whisper from now on, and our recent whispers
-- to X are sent again through the guild channel. The error itself is hidden
-- (one would show up per lost message).
local notFoundPattern
local function whisperFailedName(text)
	if not notFoundPattern then
		local template = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
		notFoundPattern = "^" .. template:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$"
	end
	local target = type(text) == "string" and text:match(notFoundPattern)
	local entry = target and P.whispered[target]
	if entry and GetTime() - entry.at < P.RESEND_WINDOW then
		return target, entry
	end
end

function P.OnSystemMessage(_, text)
	local target, entry = whisperFailedName(text)
	if not target then return end
	P.whispered[target] = nil
	local firstFailure = P.failedAt[entry.name]
	local failedAgain = firstFailure and GetTime() - firstFailure >= Roster.OFFLINE_MEMORY
	if entry.guid and not Roster.HeardWithin(entry.guid, P.HEARD_WINDOW) and not failedAgain then
		P.failedAt[entry.name] = firstFailure or GetTime()
		ns.Debug("whisper to", target, "failed: offline (the roster is behind)")
		Roster.Note(entry.guid, false, true)
		local sync = P.sync
		if sync and sync.partner == entry.guid and not sync.answered and sync.retry then
			ns.Cancel("syncTimeout")
			sync.retry()
		end
		return
	end
	if P.unreachable[entry.name] then return end
	P.unreachable[entry.name] = true
	ns.Debug("whisper to", target, "failed, using the guild channel - resending", #entry.sent)
	for _, item in ipairs(entry.sent) do
		P.Send(item[1], "WHISPER", entry.name, item[2], entry.guid)
	end
end

local function hideFailedWhisper(_, _, text)
	return whisperFailedName(text) ~= nil
end

local function sendRecord(guid, channel, target, prio)
	local gd = ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	if not rec or not Store.IsShareable(rec, isMember) then return end
	P.Send({ t = "R", r = Store.ToWire(rec) }, channel, target, prio or "BULK")
end

-- Primary professions of a record as a sort key: records of the same
-- professions next to each other in a BATCH share their recipe lists.
local function professionKey(rec)
	local primary = {}
	for sl, p in pairs(rec.profs) do
		if p.primary then primary[#primary + 1] = sl end
	end
	table.sort(primary)
	return table.concat(primary, ",")
end

local function flushRecords(target)
	local out = P.outRecords[target]
	P.outRecords[target] = nil
	local gd = ns.GetGuildData()
	if not (out and gd) then return end
	local recs = {}
	for guid in pairs(out.set) do
		local rec = gd.chars[guid]
		if rec and Store.IsShareable(rec, isMember) then recs[#recs + 1] = rec end
	end
	table.sort(recs, function(a, b)
		local ka, kb = professionKey(a), professionKey(b)
		if ka ~= kb then return ka < kb end
		return a.guid < b.guid
	end)
	for i = 1, #recs, P.BATCH_RECORDS do
		local list = {}
		for j = i, math.min(i + P.BATCH_RECORDS - 1, #recs) do list[#list + 1] = Store.ToWire(recs[j]) end
		P.Send({ t = "B", l = list }, "WHISPER", target, "BULK", out.guid)
	end
end

-- Records to one member by whisper: one per message, or several per BATCH
-- if the member reads batches (collected for BATCH_GATHER seconds, so the
-- answers to a whole digest exchange go out together).
local function sendRecords(guids, target, targetGUID)
	if not (targetGUID and P.batchPeers[targetGUID]) then
		for _, guid in ipairs(guids) do sendRecord(guid, "WHISPER", target) end
		return
	end
	local out = P.outRecords[target]
	if not out then
		out = { guid = targetGUID, set = {} }
		P.outRecords[target] = out
	end
	for _, guid in ipairs(guids) do out.set[guid] = true end
	ns.Debounce("records" .. target, P.BATCH_GATHER, function() flushRecords(target) end)
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

-- The own record to one member by whisper (a pending link offer, see
-- Features/Link.lua).
function P.SendOwnTo(name)
	sendRecord(UnitGUID("player"), "WHISPER", name, "NORMAL")
end

function P.QueuePush(guid)
	P.pushQueue[guid] = true
	ns.ScheduleEarliest("pushOwn", 5, P.PushOwn)
end

-- Partner selection ------------------------------------------------------------

-- GUIDs of online members believed to run the addon (seen sending messages,
-- or owners of a shared record), and of the other online members. Never
-- yourself. shared: by the online state every client sees alike (for
-- elections); else by everything this client knows (Roster "Online state").
function P.Candidates(shared)
	local gd = ns.GetGuildData()
	local selfGUID = UnitGUID("player")
	local known, unknown = {}, {}
	for guid, member in pairs(Roster.members) do
		local online = member.online
		if shared then online = member.sharedOnline end
		if online and guid ~= selfGUID then
			local rec = gd and gd.chars[guid]
			if P.peers[guid] or (rec and rec.ver > 0) then
				known[#known + 1] = guid
			else
				unknown[#unknown + 1] = guid
			end
		end
	end
	table.sort(known)
	table.sort(unknown)
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
		for _, guid in ipairs(list) do
			if not tried[guid] then out[#out + 1] = guid end
		end
		return out
	end
	known, unknown = untried(known), untried(unknown)
	-- Avoid the previous partner if anyone else is available.
	if #known > 1 then
		for i, guid in ipairs(known) do
			if guid == P.lastPartner then table.remove(known, i) break end
		end
	end
	local pool = known
	if explore and #unknown > 0 and (#known == 0 or math.random() < P.EXPLORE_CHANCE) then
		pool = unknown
	end
	if #pool == 0 then return nil end
	return pool[math.random(#pool)]
end

-- only: optional list of buckets the partner should compare (the others
-- come from someone else).
function P.SendHello(partnerName, partnerGUID, only)
	local gd = ns.GetGuildData()
	if not gd then return end
	P.Send({ t = "H", b = Store.BucketHashes(gd, isMember), o = only }, "WHISPER", partnerName, "NORMAL", partnerGUID)
end

-- Second partner for a split: a known addon user other than `exclude`, for
-- the buckets in `only`. Never an election: without a second partner the
-- first one sends everything (P.SPLIT_WAIT). Returns true if one was asked.
function P.StartHelperSync(exclude, only)
	if P.sync then return false end
	local pool = {}
	for _, guid in ipairs((P.Candidates())) do
		if guid ~= exclude then pool[#pool + 1] = guid end
	end
	local helper = pool[1] and pool[math.random(#pool)]
	local name = helper and Roster.NameOf(helper)
	if not name then return false end
	local sync = { tried = { [helper] = true }, attempts = 1, partner = helper, partnerName = name, answered = false }
	P.sync = sync
	ns.Debug("second partner", name)
	-- The login follow-up sync is not needed any more.
	ns.Cancel("startup2")
	P.SendHello(name, helper, only)
	ns.Debounce("syncTimeout", P.PARTNER_TIMEOUT, function()
		if P.sync == sync and not sync.answered then P.sync = nil end
	end)
	return true
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
		local partnerName = partner and Roster.NameOf(partner)
		if not partnerName then
			P.sync = nil
			if not explore then
				P.RequestPartner(0)
			end
			return
		end
		sync.attempts = sync.attempts + 1
		sync.tried[partner] = true
		sync.partner, sync.partnerName, sync.answered = partner, partnerName, false
		P.lastPartner = partner
		ns.Debug("sync with", partnerName)
		P.SendHello(partnerName, partner)
		ns.Debounce("syncTimeout", P.PARTNER_TIMEOUT, function()
			if P.sync == sync and not sync.answered then
				ns.Debug("no answer from", partnerName)
				try()
			end
		end)
	end
	sync.retry = try
	try()
end

-- Election round `round` covers ranks [0, round*N+N): the new ranks of this
-- round, and the earlier ones again (they may have missed an earlier round,
-- e.g. in a loading screen) - those answer right away.
function P.RequestPartner(round)
	P.electionRound = round
	P.Send({ t = "P", n = round }, "GUILD", nil, "NORMAL")
	ns.Debounce("electionTimeout", P.ELECTION_SLOT * P.ELECTION_RANKS + 5, function()
		if round + 1 < 3 then
			P.RequestPartner(round + 1)
		end
	end)
end

-- Rank of `me` (a GUID) among the clients that could answer `newcomer` (a
-- GUID, or any key) (0 = first). GUIDs, not names: every client must build
-- the same list, and name formats can differ.
-- include(guid), optional: only candidates for which it returns true.
function P.ElectionRank(newcomer, me, include)
	local list = { me }
	for _, guid in ipairs((P.Candidates(true))) do
		if guid ~= newcomer and guid ~= me and (not include or include(guid)) then list[#list + 1] = guid end
	end
	table.sort(list, function(a, b)
		local ha, hb = Util.Hash(newcomer .. ">" .. a), Util.Hash(newcomer .. ">" .. b)
		if ha ~= hb then return ha < hb end
		return a < b
	end)
	for i, guid in ipairs(list) do
		if guid == me then return i - 1 end
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
				if c.online and not c.isSelf then target = c.guid break end
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
		for guid, list in pairs(byTarget) do
			P.Send({ t = "Q", l = list }, "WHISPER", Roster.NameOf(guid), "NORMAL", guid)
		end
	end)
end

-- Category names (ids, at most MAX_CATEGORIES) and the categories of
-- recipes (rids, at most MAX_CATEGORY_RECIPES), from one member.
function P.RequestCategories(guid, ids, rids)
	P.Send({ t = "C", l = ids, r = rids }, "WHISPER", Roster.NameOf(guid), "BULK", guid)
end

-- Receiving --------------------------------------------------------------------

local handlers = {}

-- Owner reclaim: the pool holds a copy of the logged-in character.
function P.OnSelfCopy(rec)
	local own = ns.Scanner.GetOwn()
	if not own then return end
	-- Only a copy at least as new as ours may suggest a player ID: an older
	-- one still carries the ID from before a link or unlink.
	local notOlder = Store.CompareVersion(rec, own) >= 0
	local changed, needBump = Store.MergeIncomingSelf(own, rec)
	if needBump and not ns.db.options.shareCooldowns then
		-- Adopted from the pool: the times stay hidden (option).
		Store.HideCooldowns(own)
	end
	if needBump then
		Store.Bump(own, ns.Now(), rec)
		ns.Debug("reclaim own record", own.ver, own.seq, changed and "(adopted recipes)" or "")
		-- Pending changes are already part of the bumped record.
		ns.Scanner.pendingKind = nil
		ns.Scanner.FinishAdoption()
		ns.Emit("OwnChanged", "major")
		ns.Emit("RecordsChanged", own.guid)
	end
	ns.Scanner.UpdatePlayerId(notOlder and rec.player or nil)
end

-- Partner side: answer a HELLO with an ACK and the digests that differ.
handlers.H = function(msg, channel, sender, gd)
	if channel ~= "WHISPER" or type(msg.b) ~= "table" or #msg.b ~= Store.NUM_BUCKETS then return end
	local only
	if type(msg.o) == "table" and #msg.o <= Store.NUM_BUCKETS then
		only = {}
		for _, b in ipairs(msg.o) do
			if Util.IsInt(b, 1, Store.NUM_BUCKETS) then only[b] = true end
		end
	end
	local mine = Store.BucketHashes(gd, isMember)
	local differing = {}
	for b = 1, Store.NUM_BUCKETS do
		if msg.b[b] ~= mine[b] and (not only or only[b]) then differing[#differing + 1] = b end
	end
	P.Send({ t = "K", n = #differing }, "WHISPER", sender, "NORMAL")
	for _, b in ipairs(differing) do
		P.Send({ t = "D", b = b, e = Store.BucketEntries(gd, isMember, b) }, "WHISPER", sender, "BULK")
	end
end

handlers.K = function(msg)
	local sync = P.sync
	if sync and sync.partner == msg.u then
		sync.answered = true
		ns.Cancel("syncTimeout")
		-- The exchange continues with D/W/R; the sync slot is free again.
		P.sync = nil
	end
end

-- True while a request for this version (or a newer one) is underway: it
-- is young, or the member asked is still delivering.
local function wantPending(guid, rv, now)
	local w = P.wanted[guid]
	if not w or Store.CompareVersion(rv, w) > 0 then return false end
	if now - w.at < P.WANT_PATIENCE then return true end
	local last = P.deliveredAt[w.from]
	return last ~= nil and now - last < P.WANT_PATIENCE and not Roster.KnownOffline(w.from)
end

local function requestRecords(list, sender, senderGUID, now)
	for _, entry in ipairs(list) do
		local rv = entry[2]
		P.wanted[entry[1]] = { ver = rv.ver, seq = rv.seq, h = rv.h, from = senderGUID, at = now }
	end
	for i = 1, #list, P.MAX_LIST do
		local chunk = {}
		for j = i, math.min(i + P.MAX_LIST - 1, #list) do chunk[#chunk + 1] = list[j][1] end
		P.Send({ t = "W", l = chunk }, "WHISPER", sender, "BULK", senderGUID)
	end
end

local function evenBuckets()
	local list = {}
	for b = 2, Store.NUM_BUCKETS, 2 do list[#list + 1] = b end
	return list
end

-- Asks a second partner for the deferred buckets of the split, `delay`
-- seconds from now. A fresh install may not know anyone else yet: then it
-- tries again as records arrive (their owners are known addon users).
function P.TryHelper(delay)
	local split = P.split
	if not split or split.helper then return end
	ns.Debounce("helperSync", delay, function()
		if P.split == split and not split.helper and next(split.deferred) then
			split.helper = P.StartHelperSync(split.partner, evenBuckets())
		end
	end)
end

-- Many records missing from this partner: from now on its even buckets wait
-- for a second partner; whatever no one else delivers goes to this one
-- after SPLIT_WAIT.
local function startSplit(partnerGUID, partnerName, now)
	local split = { partner = partnerGUID, at = now, deferred = {} }
	P.split = split
	P.TryHelper(1)
	ns.Debounce("splitFallback", P.SPLIT_WAIT, function()
		if P.split ~= split then return end
		P.split = nil
		local gd, t, rest = ns.GetGuildData(), GetTime(), {}
		for _, guid in ipairs(Util.SortedKeys(split.deferred)) do
			local rv = split.deferred[guid]
			local cur = gd and gd.chars[guid]
			if (not cur or Store.CompareVersion(rv, cur) > 0) and not wantPending(guid, rv, t) then
				rest[#rest + 1] = { guid, rv }
			end
		end
		if #rest > 0 then
			ns.Debug("split: first partner sends the rest", #rest)
			requestRecords(rest, partnerName, partnerGUID, t)
		end
	end)
	return split
end

-- Compare a partner's bucket: ask for what is newer there, send what is newer here.
handlers.D = function(msg, channel, sender, gd)
	if channel ~= "WHISPER" then return end
	local bucket = msg.b
	if not Util.IsInt(bucket, 1, Store.NUM_BUCKETS) then return end
	local remote = Store.ParseDigest(msg.e)
	if not remote then return end

	local now = GetTime()
	local want = {}
	for _, guid in ipairs(Util.SortedKeys(remote)) do
		local rv = remote[guid]
		if Store.BucketOf(guid) == bucket and isMember(guid) ~= false then
			local cur = gd.chars[guid]
			if (not cur or Store.CompareVersion(rv, cur) > 0) and not wantPending(guid, rv, now) then
				want[#want + 1] = { guid, rv }
			end
		end
	end
	-- Split: one at a time; the second partner's digests are not split again.
	local split = P.split
	if split and now - split.at > P.SPLIT_WINDOW then
		P.split, split = nil, nil
	end
	if not split and #want >= P.SPLIT_MIN then
		split = startSplit(msg.u, sender, now)
	end
	if split and split.partner == msg.u and bucket % 2 == 0 then
		for _, entry in ipairs(want) do split.deferred[entry[1]] = entry[2] end
		want = {}
	end

	local newer = {}
	for guid, rec in pairs(gd.chars) do
		if Store.BucketOf(guid) == bucket and Store.IsShareable(rec, isMember) then
			local rv = remote[guid]
			if not rv or Store.CompareVersion(rec, rv) > 0 then
				newer[#newer + 1] = guid
			end
		end
	end
	table.sort(newer)
	sendRecords(newer, sender, msg.u)
	requestRecords(want, sender, msg.u, now)
end

handlers.W = function(msg, channel, sender, gd)
	if channel ~= "WHISPER" or type(msg.l) ~= "table" or #msg.l > P.MAX_LIST then return end
	local list = {}
	for _, guid in ipairs(msg.l) do
		if Store.IsValidGUID(guid) and gd.chars[guid] then list[#list + 1] = guid end
	end
	sendRecords(list, sender, msg.u)
end

-- One incoming record (REC or part of a BATCH).
local function receiveRecord(wire, channel, sender, gd, senderGUID)
	local rec, err = Store.FromWire(wire)
	if not rec then
		ns.Debug("rejected record from", sender, err)
		return
	end
	local now = GetTime()
	if channel == "GUILD" then
		P.guildSenders[senderGUID] = now
	else
		P.deliveredAt[senderGUID] = now
	end
	local w = P.wanted[rec.guid]
	if w and Store.CompareVersion(rec, w) >= 0 then
		P.wanted[rec.guid] = nil
	end
	if P.split and not P.split.helper and channel == "WHISPER" then P.TryHelper(1) end
	local status = Store.Accept(gd, rec, P.Ctx(), sender)
	ns.Debug("REC", rec.name, rec.ver, rec.seq, status, "from", sender, channel)
	if status == "self" then
		P.OnSelfCopy(rec)
	elseif status == "filled" then
		Store.LearnFactsFromRecord(ns.db, gd.chars[rec.guid], ns.Scanner.BuildKey())
		ns.Emit("RecordsChanged", rec.guid)
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
			sendRecords({ rec.guid }, sender, senderGUID)
		end)
	end
end

handlers.R = function(msg, channel, sender, gd)
	receiveRecord(msg.r, channel, sender, gd, msg.u)
end

handlers.B = function(msg, channel, sender, gd)
	if channel ~= "WHISPER" or type(msg.l) ~= "table" or #msg.l > P.BATCH_RECORDS then return end
	for _, wire in ipairs(msg.l) do
		receiveRecord(wire, channel, sender, gd, msg.u)
	end
end

handlers.P = function(msg, channel)
	if channel ~= "GUILD" or not Util.IsInt(msg.n, 0, 2) then return end
	local newcomer = msg.u
	P.accepted[newcomer] = nil
	local rank = P.ElectionRank(newcomer, UnitGUID("player"))
	local first = msg.n * P.ELECTION_RANKS
	if not rank or rank >= first + P.ELECTION_RANKS then return end
	local delay = math.max(0, rank - first) * P.ELECTION_SLOT + ns.RandomDelay(0, 0.5)
	ns.Debounce("elect" .. newcomer, delay, function()
		if not P.accepted[newcomer] then
			P.Send({ t = "A", to = newcomer }, "GUILD", nil, "NORMAL")
		end
	end)
end

handlers.A = function(msg, channel, sender)
	if channel ~= "GUILD" or not Store.IsValidGUID(msg.to) then return end
	P.accepted[msg.to] = true
	ns.Cancel("elect" .. msg.to)
	if msg.to == UnitGUID("player") and P.electionRound and not P.sync then
		P.electionRound = nil
		ns.Cancel("electionTimeout")
		P.sync = { tried = { [msg.u] = true }, attempts = 1, partner = msg.u, partnerName = sender, answered = false }
		P.SendHello(sender, msg.u)
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

local function optionalList(v, max)
	return v == nil or (type(v) == "table" and #v <= max)
end

handlers.C = function(msg, channel, sender)
	if channel ~= "WHISPER" or not optionalList(msg.l, P.MAX_CATEGORIES)
		or not optionalList(msg.r, P.MAX_CATEGORY_RECIPES) then return end
	local names, wanted, pairsOut = {}, {}, {}
	for _, id in ipairs(msg.l or {}) do
		if Util.IsInt(id, 1, 2 ^ 31) then wanted[id] = true end
	end
	-- Recipes' categories, with their names (saves a second round).
	for _, rid in ipairs(msg.r or {}) do
		local fact = Util.IsInt(rid, 1, 2 ^ 31) and ns.db.recipeFacts[rid]
		if fact and fact.cat then
			pairsOut[#pairsOut + 1] = rid
			pairsOut[#pairsOut + 1] = fact.cat
			wanted[fact.cat] = true
		end
	end
	for _, id in ipairs(Util.SortedKeys(wanted)) do
		local cat = ns.db.categories[id]
		if cat and next(cat.names) and #names < P.MAX_CATEGORIES then
			names[#names + 1] = Store.CategoryToWire(id, cat)
		end
	end
	if #names > 0 or #pairsOut > 0 then
		P.Send({ t = "E", c = names, r = pairsOut }, "WHISPER", sender, "BULK")
	end
end

handlers.E = function(msg, channel)
	if channel ~= "WHISPER" or not optionalList(msg.c, P.MAX_CATEGORIES)
		or not optionalList(msg.r, 2 * P.MAX_CATEGORY_RECIPES) then return end
	local changed = false
	for _, w in ipairs(msg.c or {}) do
		local id, cat = Store.CategoryFromWire(w)
		if id and Store.SetCategory(ns.db, id, cat, false) then
			changed = true
		end
	end
	local flat = msg.r or {}
	local build = ns.Scanner.BuildKey()
	for i = 1, #flat - 1, 2 do
		local rid, cat = flat[i], flat[i + 1]
		if Util.IsInt(rid, 1, 2 ^ 31) and Util.IsInt(cat, 1, 2 ^ 31) and Store.SetFact(ns.db, rid, { cat = cat }, false, build) then
			changed = true
		end
	end
	if changed then
		ns.Emit("CategoriesChanged")
	end
end

handlers.X = function(msg, channel)
	if channel == "GUILD" and Util.IsInt(msg.k, 0, 2 ^ 32) then
		ns.Emit("CraftQueryAnswered", msg.k)
	end
end

--[[
Senders are identified by the GUID in the message (u), not by name: name
formats differ between the roster, the chat events and our own UnitName
(Forever surnames). A sender may not claim a GUID while using a name that
belongs to another member.
]]
local function senderMismatch(guid, sender)
	local named = Roster.byName[sender]
	return named ~= nil and named ~= guid
end

-- "/gtb versions" from someone: answer by whisper (Versions). The answer (N)
-- has no content; Handle reads the version from its envelope.
handlers.V = function(_, channel, sender)
	if channel == "GUILD" then
		ns.Versions.OnRequest(sender)
	end
end

handlers.N = function() end

function P.Handle(msg, channel, sender)
	sender = Util.NormalizeName(sender)
	if not sender or type(msg) ~= "table" then return end
	if msg.u ~= nil and msg.u == UnitGUID("player") then
		-- Our own guild message, echoed by the server: its sender name is
		-- exactly how everyone else sees us.
		if Util.LearnPlayerName(sender) then
			ns.Debug("own name:", sender)
			ns.Emit("PlayerNameLearned", sender)
		end
		return
	end
	if sender == selfName() then return end
	if msg.g ~= Roster.guildKey then
		ns.Debug("ignored", tostring(msg.t), "from", sender, "- guild key", tostring(msg.g), "is not ours:", tostring(Roster.guildKey))
		return
	end
	local guid = msg.u
	if msg.p ~= ns.PROTO or not Store.IsValidGUID(guid) then
		-- A build that can not talk to this one (another protocol, or older
		-- than the sender GUID): unreadable, but worth telling the user.
		ns.Versions.SeenIncompatible(sender, msg.av, msg.p)
		return
	end
	if guid == UnitGUID("player") then return end
	if Roster.IsMember(guid) == false or senderMismatch(guid, sender) then
		ns.Debug("ignored message from", sender)
		return
	end
	Roster.LearnName(guid, sender)
	Roster.Heard(guid)
	P.peers[guid] = GetTime()
	if msg.bt == 1 then P.batchPeers[guid] = true end
	ns.Versions.Seen(sender, msg.av, msg.ab)
	local gd = ns.GetGuildData()
	local handler = handlers[msg.t]
	if gd and handler then
		handler(msg, channel, sender, gd)
	end
end

function P.OnComm(prefix, text, channel, sender)
	if prefix ~= ns.PREFIX then return end
	if type(text) == "string" and text:sub(1, #P.DIAG) == P.DIAG then
		P.OnDiag(text, channel, sender)
		return
	end
	-- Guild-channel message for one member (see P.Send): only that member
	-- decodes it, as if it were a whisper.
	local addressee = type(text) == "string" and text:match(ADDRESS_PATTERN)
	if addressee then
		if addressee ~= UnitGUID("player") then return end
		text = text:sub(#addressee + 3)
		channel = "WHISPER"
	end
	local msg = ns.Codec.Decode(text)
	if msg then
		ns.Debug("recv", tostring(msg.t), "from", tostring(sender), channel)
		P.Handle(msg, channel, sender)
	else
		ns.Debug("undecodable message from", tostring(sender), "via", tostring(channel), "-", #(text or ""), "bytes")
	end
end

-- Diagnostics ("/gtb diag [name]") ---------------------------------------------
-- Plain test messages "GTB-DIAG:<guid>[:<whisper target>]".
--   no name:   one to GUILD. The server echoes guild addon messages back to
--              the sender, so one player alone can tell whether sending and
--              receiving work; everyone else prints where it came from.
--   a name:    one whisper per target form ("First Last", "First Last-Realm").
--              The other side prints which forms arrived; the server answers
--              "No player named ..." for forms that do not work.

P.DIAG = "GTB-DIAG"
P.DIAG_TIMEOUT = 5
local DIAG_PATTERN = "^GTB%-DIAG:(Player%-%d+%-%x+):?(.*)$"

function P.Diagnose(name)
	local members, online = 0, 0
	for _, m in pairs(Roster.members) do
		members = members + 1
		if m.online then online = online + 1 end
	end
	local registered = C_ChatInfo.IsAddonMessagePrefixRegistered and C_ChatInfo.IsAddonMessagePrefixRegistered(ns.PREFIX)
	ns.Print(("diag: version %s, guild key %s, roster ready %s (%d members, %d online)"):format(
		(ns.Versions.Mine()), tostring(Roster.guildKey), tostring(Roster.ready), members, online))
	ns.Print(("diag: prefix registered %s, chat lockdown %s, queued %d, known addon users online %d"):format(
		tostring(registered), tostring(restricted() or false), #P.outbox, #(P.Candidates())))
	ns.Print(("diag: AreOutgoingAddonChatMessagesRestricted %s (not used), !craft answers %s"):format(
		tostring(outgoingRestrictedFlag() or false), ns.db.options.chatResponder and "on" or "off (/gtb chatbot)"))
	ns.Print(("diag: your name %s, members only reachable through the guild channel: %d"):format(
		tostring(selfName()), Util.Count(P.unreachable)))
	if not Roster.guildKey then return end
	local tag = P.DIAG .. ":" .. UnitGUID("player")
	if name and name ~= "" then
		local full = Util.NormalizeName(name)
		local forms = { Util.ShortName(full) }
		if forms[1] ~= full then forms[2] = full end
		for _, target in ipairs(forms) do
			local sent = C_ChatInfo.SendAddonMessage(ns.PREFIX, tag .. ":" .. target, "WHISPER", target)
			ns.Print(("diag: test whisper to '%s', result: %s"):format(target, sendResultName(sent)))
		end
		ns.Print("diag: the other side prints each test whisper it got; \"No player named\" means that form does not work")
		return
	end
	local result = C_ChatInfo.SendAddonMessage(ns.PREFIX, tag, "GUILD")
	ns.Print("diag: test message sent to the guild, result:", sendResultName(result))
	P.diagSentAt = GetTime()
	ns.Debounce("diagEcho", P.DIAG_TIMEOUT, function()
		if P.diagSentAt then
			P.diagSentAt = nil
			ns.Print(("diag: |cffff4040no echo within %d s|r - the server did not deliver your guild addon message"):format(P.DIAG_TIMEOUT))
		end
	end)
end

function P.OnDiag(text, channel, sender)
	local guid, target = text:match(DIAG_PATTERN)
	local name = Util.NormalizeName(sender)
	if not guid or not name then return end
	if guid == UnitGUID("player") then
		if Util.LearnPlayerName(name) then
			ns.Emit("PlayerNameLearned", name)
		end
		if P.diagSentAt and channel == "GUILD" then
			ns.Print(("diag: |cff20ff20echo received after %.1f s|r - sending and receiving work (the server calls you %s)"):format(
				GetTime() - P.diagSentAt, name))
			P.diagSentAt = nil
			ns.Cancel("diagEcho")
		end
	elseif target ~= "" then
		ns.Print(("diag: |cff20ff20test whisper received|r from %s (sent to '%s')"):format(Util.ShortName(name), target))
	else
		ns.Print("diag: test message received from", Util.ShortName(name), "via", tostring(channel))
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
	gd.seenAt = ns.Now()
	local old = Store.PruneGuilds(ns.db, Roster.guildKey, ns.Now(), ns.db.account.chars)
	if old > 0 then
		ns.Debug("pruned", old, "records of guilds you left")
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

-- Members (with us) who broadcast a record recently. Every client hears
-- the same broadcasts, so all of them come to about the same number.
function P.ActiveSenders(now)
	local n = 1
	for guid, at in pairs(P.guildSenders) do
		if now - at <= P.SENDER_WINDOW then
			n = n + 1
		else
			P.guildSenders[guid] = nil
		end
	end
	return n
end

-- Batch interval for rank-ups: each active sender sends at most once per
-- interval, so the guild stays near GUILD_RECORD_BUDGET per minute. Up to
-- 40 active senders that is the old 60 s. +-20% spread, so that clients do
-- not all send at the same moment.
function P.MinorDelay()
	local n = P.ActiveSenders(GetTime())
	local delay = math.max(P.MINOR_DELAY, math.min(P.MINOR_DELAY_MAX, n * 60 / P.GUILD_RECORD_BUDGET))
	return delay * (0.8 + 0.4 * math.random())
end

function P.OnOwnChanged(kind)
	-- Profession or recipe changes go out quickly, rank-ups are batched. A
	-- pending batch is never postponed; a major change pulls it forward.
	local delay = kind == "major" and P.MAJOR_DELAY or P.MinorDelay()
	ns.ScheduleEarliest("pushOwn", delay, P.PushOwn)
end

function P.Start()
	if not P.transport then
		P.comm = {}
		LibStub("AceComm-3.0"):Embed(P.comm)
		P.comm:RegisterComm(ns.PREFIX, P.OnComm)
	end

	ns.RegisterEvent("CHAT_MSG_SYSTEM", P.OnSystemMessage)
	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then
		addFilter("CHAT_MSG_SYSTEM", hideFailedWhisper)
	end
	ns.On("RosterReady", P.OnRosterReady)
	ns.On("RosterUpdated", function()
		ns.Debounce("prune", 5, P.Prune)
		-- A real logout on the roster: the failure was "offline", not the name.
		for name in pairs(P.failedAt) do
			local m = Roster.members[Roster.byName[name] or ""]
			if not m or m.rosterOnline == false then P.failedAt[name] = nil end
		end
	end)
	ns.On("OwnChanged", P.OnOwnChanged)
	ns.On("GuildChanged", function()
		P.sync, P.peers, P.accepted, P.pushQueue = nil, {}, {}, {}
	end)

	C_Timer.NewTicker(15, P.FlushOutbox)
	C_Timer.NewTicker(P.SYNC_INTERVAL, function()
		ns.After(ns.RandomDelay(0, 120), function() P.StartSync(true) end)
	end)
end
