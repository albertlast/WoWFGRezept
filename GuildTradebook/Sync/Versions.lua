--[[
Addon versions of guild members, for "/gtb versions" and update notices.

Every addon message carries the sender's version (av) and build number (ab:
commit time of a packaged build, 0 for a development copy). Messages from a
build that can not talk to this one (older than the sender GUID field, or
another protocol) are dropped by Protocol.Handle, but noted here: an outdated
guildmate shows up as "incompatible" instead of silently missing.

"/gtb versions" asks the guild once (V on GUILD); every addon user answers
with a whisper (N), spread over a few seconds. The answer needs no content:
the envelope carries the version.
]]
local ADDON, ns = ...

local L, Util, Roster = ns.L, ns.Util, ns.Roster
local Versions = {
	byName = {},       -- ["Name-Realm"] = { version, build, incompatible, newerProtocol, seen }
	answered = {},     -- [requester] = GetTime() of our last answer
	notified = {},     -- [name] = true: incompatible notice shown this session
	lastRequest = nil,
}
ns.Versions = Versions

Versions.REQUEST_GAP = 60   -- answer the same requester at most once a minute
Versions.REPLY_SPREAD = 5   -- answers are spread over this many seconds
Versions.REPORT_DELAY = 7   -- the report waits this long for answers

local function metadata(field)
	local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	return get and get(ADDON, field)
end

-- Version string and build number of this copy.
function Versions.Mine()
	return metadata("Version") or "?", tonumber(metadata("X-Build")) or 0
end

-- "newer" / "older" / "same" for another build, or nil when either side is a
-- development copy (build 0) and the order is unknown.
function Versions.Compare(myBuild, otherBuild)
	if not (Util.IsInt(myBuild, 1, 2 ^ 40) and Util.IsInt(otherBuild, 1, 2 ^ 40)) then return nil end
	if otherBuild == myBuild then return "same" end
	return otherBuild > myBuild and "newer" or "older"
end

-- A message from a compatible build.
function Versions.Seen(name, version, build)
	if not Util.IsString(version, 40) then version = nil end
	if not Util.IsInt(build, 0, 2 ^ 40) then build = 0 end
	Versions.byName[name] = { version = version, build = build, seen = GetTime() }
	local _, myBuild = Versions.Mine()
	if Versions.Compare(myBuild, build) == "newer" and not Versions.toldNewer then
		Versions.toldNewer = true
		ns.Print(L.VERSION_NEWER:format(Util.ShortName(name), version or "?"))
	end
end

-- A message this build can not read. theirProtocol: the sender's protocol
-- number, if it sent one.
function Versions.SeenIncompatible(name, version, theirProtocol)
	local newer = Util.IsInt(theirProtocol, 0, 2 ^ 31) and theirProtocol > ns.PROTO
	Versions.byName[name] = {
		version = Util.IsString(version, 40) and version or nil,
		incompatible = true, newerProtocol = newer, seen = GetTime(),
	}
	if not Versions.notified[name] then
		Versions.notified[name] = true
		ns.Print((newer and L.VERSION_UPDATE_NEEDED or L.VERSION_INCOMPATIBLE):format(Util.ShortName(name)))
	end
end

-- Short text for tooltips and the report: "0.1.0-d8dcb0e (newer)".
function Versions.Describe(entry)
	if not entry then return nil end
	if entry.incompatible then
		return "|cffff4040" .. (entry.newerProtocol and L.VERSION_STATE_NEWER_PROTOCOL or L.VERSION_STATE_OUTDATED) .. "|r"
	end
	local text = entry.version or "?"
	local _, myBuild = Versions.Mine()
	local relation = Versions.Compare(myBuild, entry.build)
	if relation == "newer" then
		text = text .. " |cff20ff20(" .. L.VERSION_STATE_NEWER .. ")|r"
	elseif relation == "older" then
		text = text .. " |cffff8000(" .. L.VERSION_STATE_OLDER .. ")|r"
	end
	return text
end

function Versions.Get(name)
	return name and Versions.byName[name]
end

-- True if name's last message came from version major.minor or later.
function Versions.AtLeast(name, major, minor)
	local entry = Versions.Get(name)
	local a, b = (entry and entry.version or ""):match("^(%d+)%.(%d+)")
	a, b = tonumber(a), tonumber(b)
	if not a then return false end
	return a > major or (a == major and b >= minor)
end

-- Someone ran "/gtb versions": answer with a whisper, a little later.
function Versions.OnRequest(sender)
	local last = Versions.answered[sender]
	if last and GetTime() - last < Versions.REQUEST_GAP then return end
	Versions.answered[sender] = GetTime()
	ns.After(ns.RandomDelay(0.2, Versions.REPLY_SPREAD), function()
		ns.Protocol.Send({ t = "N" }, "WHISPER", sender, "NORMAL")
	end)
end

function Versions.Request()
	if not Roster.guildKey then
		ns.Print(L.VERSION_NO_GUILD)
		return
	end
	if not (Versions.lastRequest and GetTime() - Versions.lastRequest < Versions.REPORT_DELAY + 3) then
		Versions.lastRequest = GetTime()
		ns.Protocol.Send({ t = "V" }, "GUILD", nil, "NORMAL")
	end
	ns.Print(L.VERSION_CHECKING)
	ns.Debounce("versionReport", Versions.REPORT_DELAY, Versions.Report)
end

--[[
Report lines (pure): seen = byName, online = { [name] = true } of online
members, expected = names of online members known to run the addon.
Returns lines for: every online member seen with a version (sorted), then
one line naming expected members that did not answer.
]]
function Versions.ReportLines(seen, online, expected)
	local lines = {}
	for _, name in ipairs(Util.SortedKeys(seen)) do
		if online[name] then
			lines[#lines + 1] = "  " .. Util.ShortName(name) .. ": " .. Versions.Describe(seen[name])
		end
	end
	local silent = {}
	for _, name in ipairs(expected) do
		if not seen[name] then silent[#silent + 1] = Util.ShortName(name) end
	end
	table.sort(silent)
	if #silent > 0 then
		lines[#lines + 1] = "  " .. L.VERSION_NO_ANSWER:format(table.concat(silent, ", "))
	end
	return lines
end

function Versions.Report()
	local version = Versions.Mine()
	ns.Print(L.VERSION_HEADER:format(version))
	local gd = ns.GetGuildData()
	local selfGUID = UnitGUID("player")
	local online, expected = {}, {}
	for guid, member in pairs(Roster.members) do
		if member.online and guid ~= selfGUID then
			local name = Roster.NameOf(guid)
			online[name] = true
			local rec = gd and gd.chars[guid]
			if ns.Protocol.peers[guid] or (rec and rec.ver > 0) then
				expected[#expected + 1] = name
			end
		end
	end
	-- Senders of unreadable messages are not in the roster under their real name.
	for name, entry in pairs(Versions.byName) do
		if entry.incompatible and GetTime() - entry.seen < 3600 then online[name] = true end
	end
	local lines = Versions.ReportLines(Versions.byName, online, expected)
	if #lines == 0 then
		lines[1] = "  " .. L.VERSION_NOBODY
	end
	for _, line in ipairs(lines) do
		print(line)
	end
end
