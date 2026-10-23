--[[
Reagents by mail: while the mailbox is open, right-click a crafter and the
addon puts the reagents of the recipe (for the chosen number of crafts) into
a mail to them. The player sends it with the mailbox's own Send button; the
addon never sends mail itself.

All or nothing: a mail is prepared only when the bags hold every reagent
(optional ones are left out) in at most ATTACHMENTS_MAX_SEND stacks. An
amount that is not made of whole stacks is split off a bigger stack into an
empty bag slot first: the client takes one split at a time, and a split is
an item only once it is placed. Then everything is attached and checked. The
order of the steps (split, place, wait until landed, attach) follows the
supply mail of TOGProfessionMaster (MIT).

Sent mails are remembered per character (charDB.mailed) for SENT_KEEP and
shown next to the crafter.
]]
local _, ns = ...

local L, Util = ns.L, ns.Util
local Mail = { open = false, pending = nil }
ns.Mail = Mail

Mail.MAX_ATTACHMENTS = 12
Mail.SENT_KEEP = 3 * 86400
Mail.SPLIT_STEP = 0.3   -- seconds between two splits
Mail.PLACE_DELAY = 0.15 -- split -> placed into its empty slot
Mail.LAND_TRIES = 5     -- checks, 0.2 s apart, that every split has landed

--[[
Pure: which stacks go into the mail.
  reagents  { {itemID, quantity, optional(0/1)}, ... } (recipe facts)
  stacksOf(itemID) -> { {bag, slot, count}, ... }: the stacks that can be mailed
Returns { ok, tooMany, missing = { {itemID, count} },
          whole = { {bag, slot, itemID, count} }, splits = { {bag, slot, itemID, amount} } }.
Whole stacks, largest first, as long as they fit; the rest is split off the
smallest stack that did not fit. That one is always larger than the rest: a
stack that fitted was taken.
]]
function Mail.Plan(reagents, crafts, stacksOf, maxAttachments)
	local plan = { whole = {}, splits = {}, missing = {} }
	for _, r in ipairs(reagents) do
		local itemID, need = r[1], r[2] * crafts
		if r[3] ~= 1 and need > 0 then
			local stacks, have = {}, 0
			for _, s in ipairs(stacksOf(itemID)) do
				stacks[#stacks + 1] = s
				have = have + s.count
			end
			if have < need then
				plan.missing[#plan.missing + 1] = { itemID = itemID, count = need - have }
			else
				table.sort(stacks, function(a, b)
					if a.count ~= b.count then return a.count > b.count end
					if a.bag ~= b.bag then return a.bag < b.bag end
					return a.slot < b.slot
				end)
				local rest, larger = need, nil
				for _, s in ipairs(stacks) do
					if s.count <= rest then
						rest = rest - s.count
						plan.whole[#plan.whole + 1] = { bag = s.bag, slot = s.slot, itemID = itemID, count = s.count }
					else
						larger = s
					end
				end
				if rest > 0 then
					plan.splits[#plan.splits + 1] = { bag = larger.bag, slot = larger.slot, itemID = itemID, amount = rest }
				end
			end
		end
	end
	local attachments = #plan.whole + #plan.splits
	plan.tooMany = attachments > (maxAttachments or Mail.MAX_ATTACHMENTS)
	plan.ok = #plan.missing == 0 and attachments > 0 and not plan.tooMany
	return plan
end

-- "6x Linen Cloth, 1x Coarse Thread": what a plan puts into the mail.
local function itemName(itemID)
	return C_Item.GetItemNameByID(itemID) or ("#" .. itemID)
end

function Mail.Describe(plan)
	local total, order = {}, {}
	local function add(itemID, n)
		if not total[itemID] then order[#order + 1] = itemID end
		total[itemID] = (total[itemID] or 0) + n
	end
	for _, s in ipairs(plan.whole) do add(s.itemID, s.count) end
	for _, s in ipairs(plan.splits) do add(s.itemID, s.amount) end
	local parts = {}
	for _, itemID in ipairs(order) do parts[#parts + 1] = total[itemID] .. "x " .. itemName(itemID) end
	return table.concat(parts, ", ")
end

local function describeMissing(missing)
	local parts = {}
	for _, m in ipairs(missing) do parts[#parts + 1] = m.count .. "x " .. itemName(m.itemID) end
	return table.concat(parts, ", ")
end

-- Bags --------------------------------------------------------------------------

local function numBags()
	local c = Constants and Constants.InventoryConstants
	return (c and c.NumBagSlots) or NUM_BAG_SLOTS or 4
end

-- Mailable stacks by item (not locked, not soulbound) and the empty slots of
-- ordinary bags (a profession bag takes only its own kind of item).
local function readBags()
	local stacks, empty = {}, {}
	for bag = 0, numBags() do
		local _, family = C_Container.GetContainerNumFreeSlots(bag)
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if not info then
				if (family or 0) == 0 then empty[#empty + 1] = { bag = bag, slot = slot } end
			elseif info.itemID and not info.isLocked and not info.isBound and (info.stackCount or 0) > 0 then
				stacks[info.itemID] = stacks[info.itemID] or {}
				table.insert(stacks[info.itemID], { bag = bag, slot = slot, count = info.stackCount })
			end
		end
	end
	return stacks, empty
end

-- Mailbox -----------------------------------------------------------------------

function Mail.IsOpen()
	return Mail.open and MailFrame ~= nil and MailFrame:IsShown() == true
end

local function hasAttachments()
	for i = 1, ATTACHMENTS_MAX_SEND or Mail.MAX_ATTACHMENTS do
		if HasSendMailItem(i) then return true end
	end
	return false
end

local function fail(pending, message)
	if Mail.pending == pending then Mail.pending = nil end
	ClearCursor()
	ns.Print(message)
end

-- Attaches everything once every split has landed, then fills in the mail.
local function attach(pending, plan, tries)
	if Mail.pending ~= pending then return end
	for _, s in ipairs(plan.splits) do
		local info = C_Container.GetContainerItemInfo(s.dst.bag, s.dst.slot)
		if not (info and info.itemID == s.itemID and info.stackCount == s.amount and not info.isLocked) then
			if tries < Mail.LAND_TRIES then
				ns.After(0.2, function() attach(pending, plan, tries + 1) end)
			else
				fail(pending, L.MAIL_SPLIT_FAILED)
			end
			return
		end
	end
	if not Mail.IsOpen() then return fail(pending, L.MAIL_OPEN_MAILBOX) end
	if hasAttachments() then return fail(pending, L.MAIL_NOT_EMPTY) end
	local sources = {}
	for _, s in ipairs(plan.splits) do sources[#sources + 1] = s.dst end
	for _, s in ipairs(plan.whole) do sources[#sources + 1] = s end
	for i, src in ipairs(sources) do
		ClearCursor()
		C_Container.PickupContainerItem(src.bag, src.slot)
		ClickSendMailItemButton(i)
		if not HasSendMailItem(i) then
			-- A stack moved since the plan: put back what is attached.
			ClearCursor()
			for j = i - 1, 1, -1 do ClickSendMailItemButton(j, true) end
			return fail(pending, L.MAIL_ATTACH_FAILED)
		end
	end
	pending.target = Util.ShortName(pending.name)
	SendMailNameEditBox:SetText(pending.target)
	SendMailSubjectEditBox:SetText(L.MAIL_SUBJECT:format(pending.recipeName))
	if SendMailBodyEditBox then
		SendMailBodyEditBox:SetText(L.MAIL_BODY:format(pending.crafts, pending.recipeName))
	end
	pending.phase = "ready"
	ns.Print(L.MAIL_READY:format(Mail.Describe(plan), pending.target))
end

--[[
Fills a mail to `name` (the crafter, "First Last-Realm") with the reagents of
recipeID for `crafts` crafts; guid is the crafter, for the "mailed" note.
Says in chat what is missing or why it can not be done. Returns true when
the mail is being prepared.
]]
function Mail.Prepare(guid, name, recipeID, crafts)
	if Mail.pending and Mail.pending.phase == "building" then
		ns.Print(L.MAIL_BUSY)
		return false
	end
	if not Mail.IsOpen() then
		ns.Print(L.MAIL_OPEN_MAILBOX)
		return false
	end
	if hasAttachments() then
		ns.Print(L.MAIL_NOT_EMPTY)
		return false
	end
	local recipeName = ns.Index.RecipeName(recipeID) or ("#" .. recipeID)
	local reagents = ns.Reagents.ForRecipe(recipeID)
	if not reagents then
		ns.Print(L.MAIL_NO_REAGENTS:format(recipeName))
		return false
	end
	local stacks, empty = readBags()
	local maxAttachments = ATTACHMENTS_MAX_SEND or Mail.MAX_ATTACHMENTS
	local plan = Mail.Plan(reagents, crafts, function(itemID) return stacks[itemID] or {} end, maxAttachments)
	if #plan.missing > 0 then
		ns.Print(L.MAIL_MISSING:format(describeMissing(plan.missing)))
		return false
	elseif plan.tooMany then
		ns.Print(L.MAIL_TOO_MANY:format(maxAttachments))
		return false
	elseif not plan.ok then
		ns.Print(L.MAIL_NO_REAGENTS:format(recipeName))
		return false
	elseif #plan.splits > #empty then
		ns.Print(L.MAIL_NEED_SLOTS:format(#plan.splits))
		return false
	end

	local pending = { phase = "building", guid = guid, name = name, recipeID = recipeID, crafts = crafts, recipeName = recipeName }
	Mail.pending = pending
	-- The Send Mail tab: attachments go there (the inbox may be showing).
	if MailFrameTab2 and MailFrameTab2.Click then MailFrameTab2:Click() end
	if #plan.splits == 0 then
		attach(pending, plan, 0)
		return true
	end
	for i, s in ipairs(plan.splits) do
		s.dst = empty[i]
		local at = (i - 1) * Mail.SPLIT_STEP
		ns.After(at, function()
			if Mail.pending ~= pending then return end
			ClearCursor()
			C_Container.SplitContainerItem(s.bag, s.slot, s.amount)
		end)
		ns.After(at + Mail.PLACE_DELAY, function()
			if Mail.pending ~= pending then return ClearCursor() end
			C_Container.PickupContainerItem(s.dst.bag, s.dst.slot)
		end)
	end
	ns.After(#plan.splits * Mail.SPLIT_STEP, function() attach(pending, plan, 0) end)
	return true
end

-- Sent mails --------------------------------------------------------------------

local function sentStore()
	local s = ns.charDB.mailed
	if type(s) ~= "table" then
		s = {}
		ns.charDB.mailed = s
	end
	return s
end

function Mail.RecordSent(guid, recipeID, now)
	local s = sentStore()
	for key, at in pairs(s) do
		if now - at > Mail.SENT_KEEP then s[key] = nil end
	end
	s[guid .. ":" .. recipeID] = now
end

-- Server time the reagents of recipeID went to this crafter, or nil.
function Mail.SentAt(guid, recipeID)
	local s = ns.charDB and ns.charDB.mailed
	local at = type(s) == "table" and guid and recipeID and s[guid .. ":" .. recipeID]
	if at and ns.Now() - at <= Mail.SENT_KEEP then return at end
	return nil
end

-- Right-click menu entry { label, fn, disabled } for a crafter entry
-- (Index.Crafters, a Members row), or nil for yourself.
function Mail.MenuItem(c, recipeID, crafts)
	if not (c and c.guid and c.name and recipeID) or c.isSelf then return nil end
	local label = L.MAIL_MENU:format(crafts)
	if not Mail.IsOpen() then
		return { label .. " " .. L.MAIL_MENU_CLOSED, nil, true }
	end
	return { label, function() Mail.Prepare(c.guid, c.name, recipeID, crafts) end }
end

-- The mailbox's Send (SendMailFrame_SendMail, also behind its button): is
-- it our mail? Still addressed as we filled it, with the attachments (the
-- mailbox empties them only on MAIL_SEND_SUCCESS).
local hooked = false
local function onSend()
	local p = Mail.pending
	if p and p.phase == "ready" then
		p.sent = SendMailNameEditBox:GetText() == p.target and hasAttachments()
	end
end

function Mail.Start()
	ns.RegisterEvent("MAIL_SHOW", function()
		Mail.open = true
		if not hooked and SendMailFrame_SendMail and hooksecurefunc then
			hooksecurefunc("SendMailFrame_SendMail", onSend)
			hooked = true
		end
	end)
	ns.RegisterEvent("MAIL_CLOSED", function()
		Mail.open = false
		Mail.pending = nil
	end)
	ns.RegisterEvent("MAIL_SEND_SUCCESS", function()
		local p = Mail.pending
		if not p or p.phase ~= "ready" then return end
		Mail.pending = nil
		if p.sent then
			Mail.RecordSent(p.guid, p.recipeID, ns.Now())
			ns.Print(L.MAIL_SENT:format(p.target))
			ns.Emit("MailSent", p.guid)
		end
	end)
	ns.RegisterEvent("MAIL_FAILED", function()
		local p = Mail.pending
		if p and p.sent then
			p.sent = nil
			ns.Print(L.MAIL_FAILED:format(p.target))
		end
	end)
end
