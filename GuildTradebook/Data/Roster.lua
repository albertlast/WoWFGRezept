local _, ns = ...

local Util = ns.Util
local Roster = {
	members = {},   -- [guid] = { name, online, sharedOnline, rosterOnline, level, class, index }
	byName = {},    -- ["Name-Realm"] = guid
	realNames = {}, -- [guid] = "Name-Realm" seen on the member's addon messages
	ready = false,  -- roster fully loaded; membership answers are trustworthy
	guildKey = nil,
	lastCount = 0,
}
ns.Roster = Roster

local REFRESH_INTERVAL = 120

--[[
Online state. The roster's online flags lag behind: a logout shows up only
with the next refresh (or later), a login too. Newer knowledge wins for a
while, in two levels:
  announced[guid]  login/logout system messages - every client sees them
  evidence[guid]   only this client: a message from the member (online), or a
                   whisper the server refused with "No player named" (offline)
Each is { online = bool, at = GetTime() }, valid ONLINE_PROOF seconds when
online and OFFLINE_MEMORY seconds when offline; a roster change towards the
other state ends it early (the roster caught up, or the member relogged).

  member.rosterOnline  the roster's flag
  member.sharedOnline  roster + announcements: the same on every client, so
                       elections (Protocol.ElectionRank) use it
  member.online        everything this client knows: sync partners, lists,
                       wishlist
]]
Roster.ONLINE_PROOF = 150
Roster.OFFLINE_MEMORY = 600
Roster.announced = {}
Roster.evidence = {}

local function valid(entry, now)
	return entry ~= nil and now - entry.at < (entry.online and Roster.ONLINE_PROOF or Roster.OFFLINE_MEMORY)
end

-- Recomputes sharedOnline and online of one member; true if either changed.
local function applyOnline(guid, m)
	local now = GetTime()
	local a, e = Roster.announced[guid], Roster.evidence[guid]
	if a and not valid(a, now) then a, Roster.announced[guid] = nil, nil end
	if e and not valid(e, now) then e, Roster.evidence[guid] = nil, nil end
	local shared = m.rosterOnline
	if a then shared = a.online end
	local latest = a
	if e and (not latest or e.at >= latest.at) then latest = e end
	local online = m.rosterOnline
	if latest then online = latest.online end
	local changed = m.online ~= online or m.sharedOnline ~= shared
	m.sharedOnline, m.online = shared, online
	return changed
end

function Roster.ComputeGuildKey()
	if not IsInGuild() then return nil end
	local guildName, _, _, guildRealm = GetGuildInfo("player")
	if not guildName then return nil end
	guildRealm = guildRealm or GetNormalizedRealmName()
	return guildName .. "-" .. (guildRealm or "")
end

function Roster.Reset()
	Roster.members, Roster.byName, Roster.realNames = {}, {}, {}
	Roster.announced, Roster.evidence = {}, {}
	Roster.ready = false
	Roster.lastCount = 0
end

-- true / false, or nil while the roster is not loaded yet.
function Roster.IsMember(guid)
	if not Roster.ready then return nil end
	return Roster.members[guid] ~= nil
end

--[[
Members are identified by GUID; names are for whispering and display. Best
source first:
  1. the sender name of the member's own addon messages (exactly what the
     server uses)
  2. the roster's name
  3. the name the owner put into its record (older builds wrote a wrong one
     for Forever names with a surname)
]]
function Roster.NameOf(guid)
	local real = Roster.realNames[guid]
	if real then return real end
	local m = Roster.members[guid]
	if m and m.name then return m.name end
	local gd = ns.GetGuildData and ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	if rec and rec.name and rec.name ~= "" then return rec.name end
	return nil
end

function Roster.LearnName(guid, name)
	if Roster.realNames[guid] ~= name then
		Roster.realNames[guid] = name
		Roster.byName[name] = guid
	end
end

function Roster.GuidByName(name)
	return Roster.byName[Util.NormalizeName(name) or ""]
end

function Roster.Get(guid)
	return Roster.members[guid]
end

-- New knowledge about a member being online. private: only this client knows
-- it (see above). Emits RosterUpdated when the member's state changes.
function Roster.Note(guid, online, private)
	local m = guid and Roster.members[guid]
	if not m then return end
	local entry = { online = online and true or false, at = GetTime() }
	if private then
		Roster.evidence[guid] = entry
	else
		Roster.announced[guid] = entry
	end
	if applyOnline(guid, m) then
		ns.Emit("RosterUpdated")
	end
end

-- A message from the member arrived: online.
function Roster.Heard(guid)
	Roster.Note(guid, true, true)
end

-- True if a message from the member arrived within `seconds` (and nothing
-- said offline since).
function Roster.HeardWithin(guid, seconds)
	local e = Roster.evidence[guid]
	return e ~= nil and e.online and GetTime() - e.at < seconds
end

-- True only on fresh news that the member is offline (not just a roster
-- flag, which can be behind after a login).
function Roster.KnownOffline(guid)
	local m = guid and Roster.members[guid]
	if not m or m.online then return false end
	local now = GetTime()
	local a, e = Roster.announced[guid], Roster.evidence[guid]
	return (valid(a, now) and not a.online) or (valid(e, now) and not e.online) or false
end

-- Seconds since the member was last online (0 if online), or nil.
function Roster.LastOnlineAge(guid)
	local m = Roster.members[guid]
	if not m then return nil end
	if m.online then return 0 end
	if not GetGuildRosterLastOnline then return nil end
	local years, months, days, hours = GetGuildRosterLastOnline(m.index)
	if not years then return nil end
	return (((years * 12 + months) * 30 + days) * 24 + hours) * 3600
end

-- Server-side profession membership -------------------------------------------
-- The guild club data names each member's two primary professions. It reports
-- every rank as 1, so it is only used to spot primary professions a member no
-- longer has (stale relayed data), never for ranks or recipes.

Roster.serverProfs = {}   -- [guid] = { profs = { [skillLine] = true }, complete = bool }

Roster.SECONDARY_SKILLLINES = {
	[185] = true, -- Cooking
	[129] = true, -- First Aid
	[356] = true, -- Fishing
}

function Roster.RefreshServerProfessions()
	local profs = {}
	local clubId = C_Club and C_Club.GetGuildClubId and C_Club.GetGuildClubId()
	if clubId then
		for _, memberId in ipairs(C_Club.GetClubMembers(clubId) or {}) do
			local info = C_Club.GetMemberInfo(clubId, memberId)
			if info and info.guid and (info.profession1ID or info.profession2ID) then
				local set = {}
				if info.profession1ID then set[info.profession1ID] = true end
				if info.profession2ID then set[info.profession2ID] = true end
				profs[info.guid] = { profs = set, complete = (info.profession1ID and info.profession2ID) and true or false }
			end
		end
	end
	Roster.serverProfs = profs
end

-- True only when the server positively says the member has two other primary
-- professions. Missing or partial server data means "unknown" (false here).
-- The server lists only the two primary professions. So a profession the
-- owner's record marks as not primary (Cooking, Fishing, but also class
-- skills with a crafting window like the rogue's Poisons) is never
-- contradicted; the fixed list covers records without that flag.
function Roster.IsProfessionContradicted(guid, skillLine)
	if Roster.SECONDARY_SKILLLINES[skillLine] then return false end
	local known = Roster.serverProfs[guid]
	if not (known and known.complete) or known.profs[skillLine] then return false end
	local gd = ns.GetGuildData and ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	local p = rec and rec.profs[skillLine]
	return not (p and not p.primary)
end

-- { [skillLine] = true } of primary professions the server lists, or nil.
function Roster.ServerProfessions(guid)
	local known = Roster.serverProfs[guid]
	return known and known.profs
end

function Roster.Refresh()
	local key = Roster.ComputeGuildKey()
	if key ~= Roster.guildKey then
		Roster.Reset()
		Roster.guildKey = key
		ns.Emit("GuildChanged", key)
	end
	if not key then return end

	local count = GetNumGuildMembers()
	if count == 0 then return end

	local members, byName = {}, {}
	for i = 1, count do
		local name, _, _, level, _, _, _, _, online, _, classFile, _, _, _, _, _, guid = GetGuildRosterInfo(i)
		if name and guid then
			name = Util.NormalizeName(name)
			online = online and true or false
			local previous = Roster.members[guid]
			if previous and previous.rosterOnline ~= nil and previous.rosterOnline ~= online then
				-- The roster itself changed: newer than what we knew before.
				for _, known in ipairs({ Roster.announced, Roster.evidence }) do
					if known[guid] and known[guid].online ~= online then known[guid] = nil end
				end
			end
			local m = { name = name, rosterOnline = online, level = level, class = classFile, index = i }
			applyOnline(guid, m)
			members[guid] = m
			byName[name] = guid
		end
	end
	for guid, name in pairs(Roster.realNames) do
		if members[guid] then byName[name] = guid end
	end
	Roster.members, Roster.byName = members, byName
	Roster.RefreshServerProfessions()

	-- The first update after login can be partial, so membership is only
	-- trusted from the second non-empty update on. Until then IsMember returns
	-- nil and nothing gets pruned or rejected.
	local wasReady = Roster.ready
	if not Roster.ready and Roster.lastCount > 0 then
		Roster.ready = true
	end
	Roster.lastCount = count

	ns.Emit("RosterUpdated")
	if Roster.ready and not wasReady then
		ns.Emit("RosterReady", key)
	end
end

local function requestRoster()
	if IsInGuild() then
		C_GuildInfo.GuildRoster()
	end
end

-- Lua pattern for a localized message template; each %s becomes a capture.
local function templatePattern(template)
	return "^" .. template:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.-)") .. "$"
end

local onlinePattern, offlinePattern

-- Name from "[Name] has come online." / "Name has gone offline.", and the new
-- state; nil for other messages.
function Roster.ParseOnlineMessage(text)
	if type(text) ~= "string" then return nil end
	onlinePattern = onlinePattern or templatePattern(ERR_FRIEND_ONLINE_SS or "|Hplayer:%s|h[%s]|h has come online.")
	offlinePattern = offlinePattern or templatePattern(ERR_FRIEND_OFFLINE_S or "%s has gone offline.")
	local name = text:match(onlinePattern)
	if name then return name, true end
	name = text:match(offlinePattern)
	if name then return name, false end
	return nil
end

--[[
The server tells about guild members logging in or out in a system message
right away, while the roster's online flags change only with the next
refresh (up to REFRESH_INTERVAL later, or later still). It is noted for
every client alike (see "Online state"); a roster refresh is requested.
]]
function Roster.OnSystemMessage(_, text)
	if Util.IsSecret(text) then return end
	local name, online = Roster.ParseOnlineMessage(text)
	if not name then return end
	local guid = Roster.GuidByName(name)
	if not guid or not Roster.members[guid] then return end
	ns.Debug(name, online and "came online" or "went offline", "(system message)")
	Roster.Note(guid, online, false)
	ns.ScheduleEarliest("rosterConfirm", 3, requestRoster)
end

function Roster.Start()
	ns.RegisterEvent("GUILD_ROSTER_UPDATE", function()
		ns.Debounce("roster", 1, Roster.Refresh)
	end)
	ns.RegisterEvent("PLAYER_GUILD_UPDATE", function()
		ns.Debounce("roster", 1, Roster.Refresh)
		requestRoster()
	end)
	ns.RegisterEvent("CHAT_MSG_SYSTEM", Roster.OnSystemMessage)
	requestRoster()
	-- A second request makes the roster count stable (see Refresh).
	ns.After(15, requestRoster)
	C_Timer.NewTicker(REFRESH_INTERVAL, requestRoster)
end
