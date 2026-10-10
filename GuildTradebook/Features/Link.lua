--[[
Account linking: a person with two WoW licenses (two accounts, so two sets
of SavedVariables) shows up as one player in the guild. The guild groups
characters by player ID (record field `player`, Index.byPlayer); a link
makes both licenses use the same ID. Every client, 0.1.0 ones included,
then groups them, and nothing else is needed on the wire.

  1. License A offers: gd.link.offerTo = B's player ID. The offer travels in
     A's own record (field `offer`, not hashed; 0.1.0 clients drop it when
     they relay). While it is pending, A whispers its record to every
     character of B that comes online, so it always arrives when both are
     online; while A is offline it needs a 0.2 client to relay it.
  2. License B sees a record with offer == its own ID and asks the player
     (popup). Accept: B takes over A's player ID. Decline: never asked again
     for that player.
  3. A sees records that are not its own with its player ID: confirmed, the
     offer goes.
  4. Either side unlinks alone by taking a fresh player ID; the other side
     notices that its partners' records no longer carry its ID.

gd.link = {
  offerTo  = player ID | nil,  offerName = display name of the offer target,
  partners = { [guid] = true }  -- the other license's characters
  declined = { [player ID] = true },
}
]]
local _, ns = ...

local L, Store, Roster, Util = ns.L, ns.Store, ns.Roster, ns.Util
local Link = { prompted = {}, sentTo = {} }
ns.Link = Link

local function state(gd)
	gd.link = gd.link or {}
	gd.link.partners = gd.link.partners or {}
	gd.link.declined = gd.link.declined or {}
	return gd.link
end

local function isMember(guid)
	return Roster.IsMember(guid)
end

local function isOwn(guid)
	return ns.db.account.chars[guid] ~= nil
end

local function shortName(guid)
	return Util.ShortName(Roster.NameOf(guid) or "?")
end

local function names(guids)
	local out = {}
	for _, guid in ipairs(guids) do out[#out + 1] = shortName(guid) end
	table.sort(out)
	return table.concat(out, ", ")
end

-- The own record carries the offer; publish it.
local function publishOffer(gd)
	local own = ns.Scanner.GetOwn()
	local offer = state(gd).offerTo
	if own and own.offer ~= offer then
		own.offer = offer
		ns.Scanner.Commit(own, "major")
	end
end

function Link.IsPartner(guid)
	local gd = ns.GetGuildData()
	return gd ~= nil and gd.link ~= nil and gd.link.partners ~= nil and gd.link.partners[guid] == true
end

function Link.IsLinked()
	local gd = ns.GetGuildData()
	return gd ~= nil and gd.link ~= nil and next(gd.link.partners or {}) ~= nil
end

-- The player ID an offer to this character would go to, or nil if it can
-- not be linked (no shared record, already yours, already linked).
function Link.TargetOf(guid)
	local gd = ns.GetGuildData()
	local rec = gd and gd.chars[guid]
	if not rec or isOwn(guid) or not Store.IsShareable(rec, isMember) then return nil end
	if not Store.IsValidPlayerId(rec.player) or rec.player == gd.playerId then return nil end
	return rec.player
end

function Link.OfferPendingFor(guid)
	local gd = ns.GetGuildData()
	local target = Link.TargetOf(guid)
	return target ~= nil and state(gd).offerTo == target
end

function Link.Offer(guid)
	local gd = ns.GetGuildData()
	local target = Link.TargetOf(guid)
	if not target then
		ns.Print(L.LINK_NOT_POSSIBLE:format(shortName(guid)))
		return false
	end
	local link = state(gd)
	link.offerTo, link.offerName = target, shortName(guid)
	Link.sentTo = {}
	publishOffer(gd)
	ns.Print(L.LINK_OFFERED:format(link.offerName))
	ns.ScheduleEarliest("linkSend", 6, Link.SendOffer)
	return true
end

function Link.CancelOffer()
	local gd = ns.GetGuildData()
	if not gd or not state(gd).offerTo then return end
	gd.link.offerTo, gd.link.offerName = nil, nil
	publishOffer(gd)
	ns.Print(L.LINK_CANCELED)
end

-- The other license's characters: records that are not ours with our ID.
local function partnersNow(gd, id)
	local out = {}
	for guid, rec in pairs(gd.chars) do
		if rec.player == id and not isOwn(guid) and Store.IsShareable(rec, isMember) then
			out[#out + 1] = guid
		end
	end
	table.sort(out)
	return out
end

function Link.Accept(offererId)
	local gd = ns.GetGuildData()
	if not gd or not Store.IsValidPlayerId(offererId) then return end
	local link = state(gd)
	link.offerTo, link.offerName = nil, nil
	ns.Scanner.SetPlayerId(offererId)
	publishOffer(gd)
	link.partners = {}
	local partners = partnersNow(gd, offererId)
	for _, guid in ipairs(partners) do link.partners[guid] = true end
	ns.Print(L.LINK_DONE:format(names(partners)))
	ns.Emit("RecordsChanged")
end

function Link.Decline(offererId, name)
	local gd = ns.GetGuildData()
	if not gd then return end
	state(gd).declined[offererId] = true
	ns.Print(L.LINK_DECLINED:format(name or "?"))
end

function Link.Unlink()
	local gd = ns.GetGuildData()
	if not gd then return end
	local link = state(gd)
	link.partners, link.offerTo, link.offerName = {}, nil, nil
	ns.Scanner.SetPlayerId(nil)
	publishOffer(gd)
	ns.Print(L.LINK_UNLINKED)
	ns.Emit("RecordsChanged")
end

--[[
Pure core. records: gd.chars; id: our player ID; isOwn(guid), shareable(rec).
Returns
  partners = guids that are not ours but carry our ID (the other license)
  offers   = { [offerer player ID] = guid } of records offering to link to us
]]
function Link.Scan(records, id, isOwnChar, shareable)
	local partners, offers = {}, {}
	for guid, rec in pairs(records) do
		if not isOwnChar(guid) and shareable(rec) then
			if rec.player == id then
				partners[#partners + 1] = guid
			elseif rec.offer == id and Store.IsValidPlayerId(rec.player) and not offers[rec.player] then
				offers[rec.player] = guid
			end
		end
	end
	table.sort(partners)
	return partners, offers
end

local function prompt(offererId, guid)
	Link.popupOpen = true
	local name = shortName(guid)
	local data = { player = offererId, name = name }
	if StaticPopup_Show then
		StaticPopup_Show("GUILDTRADEBOOK_LINK_REQUEST", name, nil, data)
	end
end

function Link.Check()
	local gd = ns.GetGuildData()
	if not gd or not Roster.ready or not Store.IsValidPlayerId(gd.playerId) then return end
	local link = state(gd)
	local id = gd.playerId
	local partners, offers = Link.Scan(gd.chars, id, isOwn, function(rec) return Store.IsShareable(rec, isMember) end)

	-- Our offer was taken: their records carry our ID now.
	if link.offerTo and #partners > 0 then
		link.offerTo, link.offerName = nil, nil
		publishOffer(gd)
		for _, guid in ipairs(partners) do link.partners[guid] = true end
		ns.Print(L.LINK_DONE:format(names(partners)))
	elseif next(link.partners) then
		-- Linked: new characters of the other license join the group.
		for _, guid in ipairs(partners) do link.partners[guid] = true end
	end

	-- The other side unlinked: its records carry another ID now. A partner
	-- that left the guild stays a partner (hidden like every ex-member, its
	-- record deleted after Store.GONE_GRACE): if it comes back, its record
	-- still carries our ID and it is ours again at once.
	local ended = {}
	for guid in pairs(link.partners) do
		local rec = gd.chars[guid]
		if rec and not rec.goneSince and rec.player ~= id then
			link.partners[guid] = nil
			ended[#ended + 1] = guid
		end
	end
	if #ended > 0 and not next(link.partners) then
		ns.Print(L.LINK_ENDED:format(names(ended)))
	end

	if not Link.popupOpen then
		for offererId, guid in pairs(offers) do
			if not link.declined[offererId] and not Link.prompted[offererId] then
				Link.prompted[offererId] = true
				prompt(offererId, guid)
				break
			end
		end
	end
end

local function registerPopups()
	if not StaticPopupDialogs then return end
	StaticPopupDialogs.GUILDTRADEBOOK_LINK_REQUEST = {
		text = L.LINK_REQUEST,
		button1 = L.LINK_ACCEPT,
		button2 = L.LINK_DECLINE,
		OnAccept = function(_, data)
			Link.popupOpen = false
			Link.Accept(data.player)
		end,
		OnCancel = function(_, data)
			Link.popupOpen = false
			Link.Decline(data.player, data.name)
		end,
		-- Closed another way (another popup took its place): ask again next session.
		OnHide = function() Link.popupOpen = false end,
		timeout = 0, whileDead = true, hideOnEscape = false, preferredIndex = 3,
	}
	StaticPopupDialogs.GUILDTRADEBOOK_LINK_OFFER = {
		text = L.LINK_CONFIRM_OFFER,
		button1 = YES or "Yes",
		button2 = NO or "No",
		OnAccept = function(_, data) Link.Offer(data.guid) end,
		timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	}
	StaticPopupDialogs.GUILDTRADEBOOK_UNLINK = {
		text = L.LINK_CONFIRM_UNLINK,
		button1 = YES or "Yes",
		button2 = NO or "No",
		OnAccept = function() Link.Unlink() end,
		timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	}
end

function Link.ConfirmOffer(guid)
	if StaticPopup_Show then
		StaticPopup_Show("GUILDTRADEBOOK_LINK_OFFER", shortName(guid), nil, { guid = guid })
	end
end

function Link.ConfirmUnlink()
	if StaticPopup_Show then
		StaticPopup_Show("GUILDTRADEBOOK_UNLINK")
	end
end

-- "/gtb link" (status), "/gtb link <name>", "/gtb link cancel".
function Link.Command(rest)
	local gd = ns.GetGuildData()
	if not gd then return end
	local link = state(gd)
	if rest == "" then
		if next(link.partners) then
			ns.Print(L.LINK_STATUS_LINKED:format(names(Util.SortedKeys(link.partners))))
		end
		if link.offerTo then
			ns.Print(L.LINK_STATUS_OFFER:format(link.offerName or "?"))
		end
		if not next(link.partners) and not link.offerTo then
			ns.Print(L.LINK_STATUS_NONE)
		end
	elseif rest:lower() == "cancel" then
		Link.CancelOffer()
	else
		local guid = Roster.GuidByName(rest)
		if not guid then
			ns.Print(L.LINK_NOT_POSSIBLE:format(rest))
			return
		end
		Link.ConfirmOffer(guid)
	end
end

-- A pending offer goes straight to the other license's online characters
-- (once per character and session; their client may only have a copy a
-- 0.1.0 relay stripped).
function Link.SendOffer()
	local gd = ns.GetGuildData()
	local target = gd and gd.link and gd.link.offerTo
	if not target or not Roster.ready then return end
	for guid, rec in pairs(gd.chars) do
		local m = Roster.members[guid]
		if rec.player == target and m and m.online and not Link.sentTo[guid] then
			Link.sentTo[guid] = true
			ns.Protocol.SendOwnTo(Roster.NameOf(guid))
		end
	end
end

function Link.Start()
	registerPopups()
	local function checkSoon()
		ns.ScheduleEarliest("linkCheck", 3, Link.Check)
	end
	ns.On("RecordsChanged", checkSoon)
	ns.On("RosterReady", checkSoon)
	ns.On("RosterUpdated", function()
		ns.ScheduleEarliest("linkSend", 5, Link.SendOffer)
	end)
	ns.On("GuildChanged", function()
		Link.prompted, Link.sentTo, Link.popupOpen = {}, {}, false
	end)
end
