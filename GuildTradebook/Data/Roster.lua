local _, ns = ...

local Util = ns.Util
local Roster = {
	members = {},   -- [guid] = { name, online, level, class, index }
	byName = {},    -- ["Name-Realm"] = guid
	ready = false,  -- roster fully loaded; membership answers are trustworthy
	guildKey = nil,
	lastCount = 0,
}
ns.Roster = Roster

local REFRESH_INTERVAL = 120

function Roster.ComputeGuildKey()
	if not IsInGuild() then return nil end
	local guildName, _, _, guildRealm = GetGuildInfo("player")
	if not guildName then return nil end
	guildRealm = guildRealm or GetNormalizedRealmName()
	return guildName .. "-" .. (guildRealm or "")
end

function Roster.Reset()
	Roster.members, Roster.byName = {}, {}
	Roster.ready = false
	Roster.lastCount = 0
end

-- true / false, or nil while the roster is not loaded yet.
function Roster.IsMember(guid)
	if not Roster.ready then return nil end
	return Roster.members[guid] ~= nil
end

function Roster.IsMemberName(name)
	if not Roster.ready then return nil end
	return Roster.byName[name] ~= nil
end

function Roster.GuidByName(name)
	return Roster.byName[Util.NormalizeName(name) or ""]
end

function Roster.Get(guid)
	return Roster.members[guid]
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
function Roster.IsProfessionContradicted(guid, skillLine)
	if Roster.SECONDARY_SKILLLINES[skillLine] then return false end
	local known = Roster.serverProfs[guid]
	return known ~= nil and known.complete and not known.profs[skillLine]
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
			members[guid] = { name = name, online = online and true or false, level = level, class = classFile, index = i }
			byName[name] = guid
		end
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

function Roster.Start()
	ns.RegisterEvent("GUILD_ROSTER_UPDATE", function()
		ns.Debounce("roster", 1, Roster.Refresh)
	end)
	ns.RegisterEvent("PLAYER_GUILD_UPDATE", function()
		ns.Debounce("roster", 1, Roster.Refresh)
		requestRoster()
	end)
	requestRoster()
	-- A second request makes the roster count stable (see Refresh).
	ns.After(15, requestRoster)
	C_Timer.NewTicker(REFRESH_INTERVAL, requestRoster)
end
