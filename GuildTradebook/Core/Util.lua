local _, ns = ...

local Util = {}
ns.Util = Util

local floor = math.floor

-- 32-bit sdbm-style string hash using plain arithmetic, because WoW's Lua 5.1
-- has no integer bit operators. Every client must compute the same value:
-- h < 2^32 and the multiplier < 2^17 keep every intermediate below 2^53, so
-- doubles (WoW) and integers (test Lua 5.4) give identical results.
local MOD = 4294967296
function Util.Hash(str)
	local h = 5381
	for i = 1, #str do
		h = (h * 65599 + str:byte(i)) % MOD
	end
	return floor(h)
end

function Util.IsInt(v, lo, hi)
	return type(v) == "number" and v == floor(v) and v >= lo and v <= hi
end

function Util.IsString(v, maxLen)
	return type(v) == "string" and #v <= maxLen
end

-- Character names are always stored as "Name-Realm".
function Util.NormalizeName(name, realm)
	if type(name) ~= "string" or name == "" then return nil end
	if name:find("-", 1, true) then
		return name
	end
	realm = realm or (GetNormalizedRealmName and GetNormalizedRealmName())
	if not realm or realm == "" then
		return name
	end
	return name .. "-" .. realm
end

--[[
Your own name as others see it ("First Last-Realm"). On Forever every
character has a first name and a surname, and UnitName returns the surname as
its second value (Blizzard's Camelot NameUtil joins them with
CHARACTERNAME_SURNAME_SEPARATOR); elsewhere the second value is the realm,
which is nil for yourself. The name the server puts on our own echoed guild
addon messages is the final word (Util.LearnPlayerName).
]]
Util.learnedPlayerName = nil

function Util.PlayerName()
	if Util.learnedPlayerName then return Util.learnedPlayerName end
	local name, surname = UnitName("player")
	if not name or name == "" then return nil end
	if surname and surname ~= "" then
		local consts = Constants and Constants.CharacterNameSeparatorConsts
		name = name .. (consts and consts.CHARACTERNAME_SURNAME_SEPARATOR or " ") .. surname
	end
	return Util.NormalizeName(name)
end

-- Returns true if the name changed.
function Util.LearnPlayerName(name)
	if not name or name == Util.learnedPlayerName then return false end
	Util.learnedPlayerName = name
	return true
end

-- Display name: without the realm when it is your own realm, so players
-- only see a realm for members from another (connected) realm.
function Util.ShortName(name)
	if not name then return "?" end
	local base, realm = name:match("^(.-)%-([^%-]+)$")
	if not base then return name end
	local own = GetNormalizedRealmName and GetNormalizedRealmName()
	if not own and UnitFullName then
		own = select(2, UnitFullName("player"))
	end
	if realm == own then
		return base
	end
	return name
end

function Util.ClassColored(name, classFile)
	local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if color and color.colorStr then
		return "|c" .. color.colorStr .. name .. "|r"
	end
	return name
end

function Util.SortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	return keys
end

function Util.Count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

function Util.Contains(list, value)
	for i = 1, #list do
		if list[i] == value then return true end
	end
	return false
end

-- Compact human readable age, e.g. "3d", "5h", "12m".
function Util.FormatAge(seconds)
	if not seconds or seconds < 0 then seconds = 0 end
	if seconds >= 86400 then
		return floor(seconds / 86400) .. "d"
	elseif seconds >= 3600 then
		return floor(seconds / 3600) .. "h"
	end
	return floor(seconds / 60) .. "m"
end
