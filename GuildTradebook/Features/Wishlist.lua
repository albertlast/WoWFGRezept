--[[
Wishlist: recipes this character wants crafted. When a guild member who can
craft one of them comes online, you get a chat notice (once per member and
recipe per session). Purely local: no network traffic.

ns.charDB.wishlist[recipeID] = time added (server time)
ns.charDB.wishPaused[recipeID] = true: kept on the list, but no notice,
  sound or glow until resumed.

The minimap glow means "something new": opening the Wishlist tab marks the
crafters online now as seen (for this session), and only a crafter not seen
yet makes it glow again. One who goes offline counts as new when back.
]]
local _, ns = ...

local L, Index, Roster, Util = ns.L, ns.Index, ns.Roster, ns.Util
local Wishlist = { alerted = {}, seen = {} }
ns.Wishlist = Wishlist

local function entries()
	ns.charDB.wishlist = ns.charDB.wishlist or {}
	return ns.charDB.wishlist
end

local function paused()
	if type(ns.charDB.wishPaused) ~= "table" then ns.charDB.wishPaused = {} end
	return ns.charDB.wishPaused
end

-- Wished and not paused: { [recipeID] = time added }.
local function active()
	local out, p = {}, paused()
	for rid, at in pairs(entries()) do
		if not p[rid] then out[rid] = at end
	end
	return out
end

function Wishlist.Has(recipeID)
	return recipeID ~= nil and entries()[recipeID] ~= nil
end

function Wishlist.Toggle(recipeID)
	local list = entries()
	if list[recipeID] then
		list[recipeID] = nil
		paused()[recipeID] = nil
	else
		list[recipeID] = ns.Now()
	end
	ns.Emit("WishlistChanged")
end

function Wishlist.IsPaused(recipeID)
	return recipeID ~= nil and paused()[recipeID] == true
end

function Wishlist.SetPaused(recipeID, on)
	if not entries()[recipeID] then return end
	paused()[recipeID] = on and true or nil
	ns.Emit("WishlistChanged")
end

-- Sorted entries for the UI: { recipeID, name, itemID, crafters, online, paused }.
-- Paused ones last.
function Wishlist.Entries()
	local out = {}
	for rid in pairs(entries()) do
		local crafters = Index.Crafters(rid)
		local online = 0
		for _, c in ipairs(crafters) do
			if c.reachable and not c.isSelf then online = online + 1 end
		end
		out[#out + 1] = {
			recipeID = rid, name = Index.RecipeName(rid) or ("#" .. rid),
			itemID = Index.OutputItem(rid), crafters = crafters, online = online,
			paused = Wishlist.IsPaused(rid),
		}
	end
	table.sort(out, function(a, b)
		if a.paused ~= b.paused then return b.paused end
		if (a.online > 0) ~= (b.online > 0) then return a.online > 0 end
		return a.name < b.name
	end)
	return out
end

-- Wished recipes (not paused) that a member other than you can craft and can
-- be asked now (online, or online on another character of the same person):
-- { {recipeID, name, online = {crafter, ...}}, ... }. Shown in the minimap
-- tooltip.
function Wishlist.ReadyNow()
	local out = {}
	if not ns.charDB or not ns.GetGuildData() then return out end
	for rid in pairs(active()) do
		local online = {}
		for _, c in ipairs(Index.Crafters(rid)) do
			if c.reachable and not c.isSelf then online[#online + 1] = c end
		end
		if #online > 0 then
			out[#out + 1] = { recipeID = rid, name = Index.RecipeName(rid) or ("#" .. rid), online = online }
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- Keys ("recipeID:guid") of the crafters ReadyNow lists.
local function readyKeys()
	local keys = {}
	for _, entry in ipairs(Wishlist.ReadyNow()) do
		for _, c in ipairs(entry.online) do keys[entry.recipeID .. ":" .. c.guid] = true end
	end
	return keys
end

-- True if a crafter in ReadyNow was not seen yet: drives the minimap glow.
-- Crafters no longer reachable are forgotten, so they count as new when back.
function Wishlist.HasNew()
	local keys, new = readyKeys(), false
	for key in pairs(Wishlist.seen) do
		if not keys[key] then Wishlist.seen[key] = nil end
	end
	for key in pairs(keys) do
		if not Wishlist.seen[key] then new = true end
	end
	return new
end

-- The Wishlist tab is open: everything ready now counts as seen.
function Wishlist.MarkSeen()
	local changed = false
	for key in pairs(readyKeys()) do
		if not Wishlist.seen[key] then
			Wishlist.seen[key] = true
			changed = true
		end
	end
	if changed then ns.Emit("WishlistSeen") end
end

--[[
Pure core: which wished recipes became craftable because members came online.
  before, now   = { [guid] = true } of reachable characters
  wished        = { [recipeID] = anything }
  craftersOf(recipeID) -> list of guids
Returns { [guid] = { recipeID, ... } } for members online now but not before.
]]
function Wishlist.Matches(before, now, wished, craftersOf)
	local out = {}
	for rid in pairs(wished) do
		for _, guid in ipairs(craftersOf(rid) or {}) do
			if now[guid] and not before[guid] then
				out[guid] = out[guid] or {}
				table.insert(out[guid], rid)
			end
		end
	end
	for _, list in pairs(out) do
		table.sort(list)
	end
	return out
end

-- Characters that can be asked right now: online members and the other
-- characters of the same person. Never you or your own alts.
local function reachableChars()
	local selfGUID = UnitGUID("player")
	local out = {}
	for guid, m in pairs(Roster.members) do
		if m.online and guid ~= selfGUID then
			out[guid] = true
			for _, other in ipairs(Index.Siblings(guid)) do
				if other ~= selfGUID then out[other] = true end
			end
		end
	end
	return out
end

local function craftersOf(rid)
	Index.Ensure()
	return Index.byRecipe[rid]
end

-- The notice sound, on the master channel so it plays with sound effects
-- turned down. Logged: a missing sound is otherwise invisible.
local function playSound()
	if not ns.db.options.wishSound or not PlaySound then return end
	local id = SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081
	local ok, willPlay = pcall(PlaySound, id, "Master")
	if not (ok and willPlay) then
		ns.Debug("wishlist sound", id, "did not play:", tostring(willPlay))
	end
end

function Wishlist.Check()
	if not Roster.ready or not ns.charDB or not ns.db.options.wishAlerts then
		Wishlist.onlineBefore = nil
		return
	end
	local now = reachableChars()
	local before = Wishlist.onlineBefore
	Wishlist.onlineBefore = now
	local wished = active()
	if not next(wished) then return end

	if not before then
		-- First look after login: a summary instead of one line per member.
		local count = 0
		for rid in pairs(wished) do
			for _, guid in ipairs(craftersOf(rid) or {}) do
				if now[guid] then count = count + 1 break end
			end
		end
		if count > 0 then
			ns.Print(L.WISH_SUMMARY:format(count))
			playSound()
		end
		return
	end

	local matches = Wishlist.Matches(before, now, wished, craftersOf)
	for guid, rids in pairs(matches) do
		local names = {}
		for _, rid in ipairs(rids) do
			local key = guid .. ":" .. rid
			if not Wishlist.alerted[key] then
				Wishlist.alerted[key] = true
				names[#names + 1] = Index.RecipeName(rid) or ("#" .. rid)
			end
		end
		if #names > 0 then
			-- "Bobalt (Bob)" when the crafter is reachable through another character.
			local c = Index.CrafterInfo(guid)
			local who = Util.ClassColored(Util.ShortName(c.name), c.class)
			if c.via then
				who = who .. " (" .. Util.ClassColored(Util.ShortName(c.via.name), c.via.class) .. ")"
			end
			ns.Print(L.WISH_ALERT:format(who, table.concat(names, ", ")))
			playSound()
		end
	end
end

function Wishlist.Start()
	local function checkSoon()
		ns.ScheduleEarliest("wishlistCheck", 2, Wishlist.Check)
	end
	ns.On("RosterUpdated", checkSoon)
	-- Synced records can make a crafter reachable without a roster change:
	-- their record arrives, or links them to a character that is online.
	ns.On("RecordsChanged", checkSoon)
	ns.On("GuildChanged", function()
		Wishlist.onlineBefore = nil
	end)
end
