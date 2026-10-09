--[[
Wishlist: recipes this character wants crafted. When a guild member who can
craft one of them comes online, you get a chat notice (once per member and
recipe per session). Purely local: no network traffic.

ns.charDB.wishlist[recipeID] = time added (server time)
]]
local _, ns = ...

local L, Index, Roster, Util = ns.L, ns.Index, ns.Roster, ns.Util
local Wishlist = { alerted = {} }
ns.Wishlist = Wishlist

local function entries()
	ns.charDB.wishlist = ns.charDB.wishlist or {}
	return ns.charDB.wishlist
end

function Wishlist.Has(recipeID)
	return recipeID ~= nil and entries()[recipeID] ~= nil
end

function Wishlist.Toggle(recipeID)
	local list = entries()
	if list[recipeID] then
		list[recipeID] = nil
	else
		list[recipeID] = ns.Now()
	end
	ns.Emit("WishlistChanged")
end

-- Sorted entries for the UI: { recipeID, name, itemID, crafters, online }.
function Wishlist.Entries()
	local out = {}
	for rid in pairs(entries()) do
		local crafters = Index.Crafters(rid)
		local online = 0
		for _, c in ipairs(crafters) do
			if c.online and not c.isSelf then online = online + 1 end
		end
		out[#out + 1] = {
			recipeID = rid, name = Index.RecipeName(rid) or ("#" .. rid),
			itemID = Index.OutputItem(rid), crafters = crafters, online = online,
		}
	end
	table.sort(out, function(a, b)
		if (a.online > 0) ~= (b.online > 0) then return a.online > 0 end
		return a.name < b.name
	end)
	return out
end

-- Wished recipes that a member other than you, online right now, can craft:
-- { {recipeID, name, online = {crafter, ...}}, ... }. Drives the minimap glow.
function Wishlist.ReadyNow()
	local out = {}
	if not ns.charDB or not ns.GetGuildData() then return out end
	for rid in pairs(entries()) do
		local online = {}
		for _, c in ipairs(Index.Crafters(rid)) do
			if c.online and not c.isSelf then online[#online + 1] = c end
		end
		if #online > 0 then
			out[#out + 1] = { recipeID = rid, name = Index.RecipeName(rid) or ("#" .. rid), online = online }
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--[[
Pure core: which wished recipes became craftable because members came online.
  before, now   = { [guid] = true } of online members
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

local function onlineMembers()
	local selfGUID = UnitGUID("player")
	local online = {}
	for guid, m in pairs(Roster.members) do
		if m.online and guid ~= selfGUID then
			online[guid] = true
		end
	end
	return online
end

local function craftersOf(rid)
	Index.Ensure()
	return Index.byRecipe[rid]
end

function Wishlist.Check()
	if not Roster.ready or not ns.charDB or not ns.db.options.wishAlerts then
		Wishlist.onlineBefore = nil
		return
	end
	local now = onlineMembers()
	local before = Wishlist.onlineBefore
	Wishlist.onlineBefore = now
	local wished = entries()
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
			local member = Roster.Get(guid)
			local who = member and Util.ClassColored(Util.ShortName(member.name), member.class) or "?"
			ns.Print(L.WISH_ALERT:format(who, table.concat(names, ", ")))
			if ns.db.options.wishSound and PlaySound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then
				PlaySound(SOUNDKIT.TELL_MESSAGE)
			end
		end
	end
end

function Wishlist.Start()
	ns.On("RosterUpdated", function()
		ns.Debounce("wishlistCheck", 2, Wishlist.Check)
	end)
	ns.On("GuildChanged", function()
		Wishlist.onlineBefore = nil
	end)
end
