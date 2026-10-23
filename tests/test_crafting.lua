--[[
Specializations, cooldowns read without the profession window (Salt Shaker
included) and reagents by mail.
]]
local H = ...
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

local ns = H.LoadPure()
local Store, Mail = ns.Store, ns.Mail

local LEATHERWORKING, ALCHEMY, TAILORING = 165, 171, 197
local DRAGONSCALE, ELEMENTAL = 10656, 10658
local SALT_SHAKER, SALT_SHAKER_SPELL = 15846, 19566

local function guid(n)
	return ("Player-1-%08X"):format(n)
end

print("Specializations, cooldowns, mail")

-- Specializations: store and wire -------------------------------------------------

local function leatherworker()
	return { guid = guid(1), name = "Mira Feld-Realm", class = "ROGUE", level = 60, ver = 100, seq = 0,
		profs = { [LEATHERWORKING] = { rank = 300, maxRank = 300, primary = true, recipes = { [19048] = 15095 } } } }
end

test("specialization: an extra on the wire, not part of the hash", function()
	local rec = leatherworker()
	local without = Store.Rehash(rec)
	rec.profs[LEATHERWORKING].spec = DRAGONSCALE
	eq(Store.Rehash(rec), without, "the hash ignores it: older clients compute the same")
	local back = assert(Store.FromWire(H.DeepCopy(Store.ToWire(rec))))
	eq(back.profs[LEATHERWORKING].spec, DRAGONSCALE)
	eq(back.h, without)
	local wire = Store.ToWire(rec)
	wire[8][1][11] = "dragonscale"
	back = assert(Store.FromWire(wire), "a malformed specialization drops only the specialization")
	eq(back.profs[LEATHERWORKING].spec, nil)
	rec.profs[LEATHERWORKING].spec = nil
	eq(Store.ToWire(rec)[8][1][11], 0, "none = 0")
end)

test("specialization: a copy relayed without it (older client) is filled, not replaced", function()
	local gd = { chars = {} }
	local ctx = { now = 1000, selfGUID = guid(9), isMember = function() return true end }
	local old = leatherworker()
	Store.Rehash(old)
	eq(Store.Accept(gd, old, ctx, "x"), "accepted")
	local same = leatherworker()
	same.profs[LEATHERWORKING].spec = DRAGONSCALE
	Store.Rehash(same)
	eq(Store.Accept(gd, same, ctx, "y"), "filled")
	eq(gd.chars[guid(1)].profs[LEATHERWORKING].spec, DRAGONSCALE)
end)

test("specialization: a lost one goes only after a second look", function()
	local own = leatherworker()
	local changed, pending = Store.ApplySpec(own, LEATHERWORKING, DRAGONSCALE, false)
	truthy(changed)
	falsy(pending)
	changed = Store.ApplySpec(own, LEATHERWORKING, DRAGONSCALE, false)
	falsy(changed, "same one again: no change")
	changed, pending = Store.ApplySpec(own, LEATHERWORKING, nil, false)
	falsy(changed)
	truthy(pending, "waits for the confirmation")
	eq(own.profs[LEATHERWORKING].spec, DRAGONSCALE)
	changed = Store.ApplySpec(own, LEATHERWORKING, nil, true)
	truthy(changed)
	eq(own.profs[LEATHERWORKING].spec, nil)
	falsy(Store.ApplySpec(own, ALCHEMY, 28672, true), "a profession the character does not have")
	-- Unlearned and learned again: the specialization goes with the recipes.
	own.profs[LEATHERWORKING].spec = ELEMENTAL
	Store.ReconcileProfessions(own, { [LEATHERWORKING] = { rank = 1, maxRank = 75, primary = true } }, true)
	eq(own.profs[LEATHERWORKING].spec, nil)
end)

-- Mail plan -----------------------------------------------------------------------

local function stacks(t)
	return function(itemID) return t[itemID] or {} end
end

local function shape(plan)
	local out = {}
	for _, s in ipairs(plan.whole) do out[#out + 1] = ("%d@%d:%d=%d"):format(s.itemID, s.bag, s.slot, s.count) end
	for _, s in ipairs(plan.splits) do out[#out + 1] = ("%d@%d:%d-%d"):format(s.itemID, s.bag, s.slot, s.amount) end
	return table.concat(out, " ")
end

test("mail plan: whole stacks first, the rest split off the smallest stack that is too big", function()
	local bags = { [2589] = { { bag = 0, slot = 1, count = 4 }, { bag = 0, slot = 2, count = 5 }, { bag = 1, slot = 3, count = 20 } } }
	local plan = Mail.Plan({ { 2589, 2, 0 } }, 3, stacks(bags))
	truthy(plan.ok)
	eq(shape(plan), "2589@0:2=5 2589@0:1-1", "5 whole, 1 split off the 4-stack (not the 20)")
	plan = Mail.Plan({ { 2589, 9, 0 } }, 1, stacks(bags))
	eq(shape(plan), "2589@0:2=5 2589@0:1=4", "two whole stacks, no split")
	plan = Mail.Plan({ { 2589, 3, 0 } }, 1, stacks(bags))
	eq(shape(plan), "2589@0:1-3", "nothing fits whole: split off the smallest")
	plan = Mail.Plan({ { 2589, 20, 0 } }, 1, stacks(bags))
	eq(shape(plan), "2589@1:3=20")
end)

test("mail plan: optional reagents stay home; anything short blocks the mail and is named", function()
	local bags = { [2589] = { { bag = 0, slot = 1, count = 10 } }, [2320] = { { bag = 0, slot = 2, count = 1 } } }
	local plan = Mail.Plan({ { 2589, 2, 0 }, { 8170, 1, 1 } }, 2, stacks(bags))
	truthy(plan.ok)
	eq(shape(plan), "2589@0:1-4", "the optional reagent is left out")
	plan = Mail.Plan({ { 2589, 2, 0 }, { 2320, 1, 0 } }, 3, stacks(bags))
	falsy(plan.ok)
	eq(#plan.missing, 1)
	eq(plan.missing[1].itemID, 2320)
	eq(plan.missing[1].count, 2)
	plan = Mail.Plan({ { 8170, 1, 1 } }, 1, stacks(bags))
	falsy(plan.ok, "nothing to mail")
end)

test("mail plan: more stacks than one mail takes", function()
	local list = {}
	for i = 1, 13 do list[i] = { bag = 1, slot = i, count = 1 } end
	local plan = Mail.Plan({ { 2589, 13, 0 } }, 1, stacks({ [2589] = list }))
	truthy(plan.tooMany)
	falsy(plan.ok)
	truthy(Mail.Plan({ { 2589, 12, 0 } }, 1, stacks({ [2589] = list })).ok, "12 fit")
end)

-- Simulated clients ------------------------------------------------------------------

test("specialization: read from the spellbook, reaches the guild, goes after a second look", function()
	math.randomseed(31)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Mira Feld", profs = {
		[LEATHERWORKING] = { rank = 300, maxRank = 300, name = "Leatherworking", recipes = { [19048] = 15095 } },
	}, spells = { [DRAGONSCALE] = true } })
	local b = world:AddChar({ guid = guid(2), name = "Tom Berg" })
	local cb = world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(LEATHERWORKING)
	world:Run(150)
	eq(ca:Record(a.guid).profs[LEATHERWORKING].spec, DRAGONSCALE, "own record")
	eq(cb:Record(a.guid).profs[LEATHERWORKING].spec, DRAGONSCALE, "the guild sees it")
	eq(cb.ns.Index.SpecName(DRAGONSCALE), "Recipe " .. DRAGONSCALE, "named by the game")
	local json = cb.ns.Export.ToJSON(cb.ns.Export.Build())
	truthy(json:find('"spec":' .. DRAGONSCALE, 1, true), "in the export")

	-- Unlearned: the spellbook may be incomplete for a moment, so it goes
	-- only when a second look agrees.
	a.spells = {}
	ca:Fire("SPELLS_CHANGED")
	world:Run(3)
	eq(ca:Record(a.guid).profs[LEATHERWORKING].spec, DRAGONSCALE, "not yet")
	world:Run(10)
	eq(ca:Record(a.guid).profs[LEATHERWORKING].spec, nil, "gone after the second look")
	a.spells = { [ELEMENTAL] = true }
	ca:Fire("SPELLS_CHANGED")
	world:Run(900)
	eq(cb:Record(a.guid).profs[LEATHERWORKING].spec, ELEMENTAL, "a new one reaches the guild")
end)

test("cooldowns: read without the profession window; ready never resets a running one; not in combat", function()
	math.randomseed(32)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Mira Feld", profs = {
		[ALCHEMY] = { rank = 300, maxRank = 300, name = "Alchemy", recipes = { [17187] = 12360, [2330] = 118 } },
	}, cooldowns = { [17187] = 100 } })
	local b = world:AddChar({ guid = guid(2), name = "Tom Berg" })
	local cb = world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(ALCHEMY) -- the window finds the cooldown recipe
	world:Run(5)
	ca:CloseTradeSkill()
	a.cooldowns = {}
	world:Run(300)
	local cds = ca:Record(a.guid).profs[ALCHEMY].cds
	truthy(cds[17187] <= world.clock.t, "the first cooldown is over")

	-- Transmuted without the window being scanned (another addon's crafting UI).
	a.spellCooldowns = { [17187] = { 86400, 86400 } }
	ca:Fire("SPELL_UPDATE_COOLDOWN")
	world:Run(4)
	truthy(cds[17187] > world.clock.t + 86000, "read from the spell")
	eq(cds[2330], nil, "a recipe without a cooldown is not read")
	world:Run(900)
	truthy(cb:Record(a.guid).profs[ALCHEMY].cds[17187] > world.clock.t + 85000, "the guild knows")

	-- A reading that does not see the cooldown never resets it.
	local before = cds[17187]
	a.spellCooldowns = {}
	ca:Fire("SPELL_UPDATE_COOLDOWN")
	world:Run(4)
	eq(cds[17187], before, "still running")

	-- In combat the times are secret: skipped, read after the fight.
	a.spellCooldowns = { [17187] = { 3600, 86400 } } -- reset by a game master, say
	a.inCombat = true
	ca:Fire("SPELL_UPDATE_COOLDOWN")
	world:Run(4)
	eq(cds[17187], before, "nothing read in combat")
	a.inCombat = false
	ca:Fire("PLAYER_REGEN_ENABLED")
	world:Run(4)
	truthy(math.abs(cds[17187] - (world.clock.t + 3600)) < 10, "read after combat")
end)

test("cooldowns: the Salt Shaker counts under its spell, only for its owner", function()
	math.randomseed(33)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Mira Feld", profs = {
		[LEATHERWORKING] = { rank = 300, maxRank = 300, name = "Leatherworking", recipes = { [19048] = 15095 } },
	}, itemSpells = { [SALT_SHAKER] = SALT_SHAKER_SPELL }, bags = { [SALT_SHAKER] = 1 } })
	local c = world:AddChar({ guid = guid(3), name = "Lena Stein", profs = {
		[LEATHERWORKING] = { rank = 300, maxRank = 300, name = "Leatherworking", recipes = { [19048] = 15095 } },
	}, itemSpells = { [SALT_SHAKER] = SALT_SHAKER_SPELL } })
	local b = world:AddChar({ guid = guid(2), name = "Tom Berg" })
	local cb = world:Login(b.guid)
	local ca = world:Login(a.guid)
	local cc = world:Login(c.guid)
	world:Run(60)
	eq(ca:Record(a.guid).profs[LEATHERWORKING].cds[SALT_SHAKER_SPELL], 0, "owned, ready, without opening anything")
	eq(cc:Record(c.guid).profs[LEATHERWORKING].cds, nil, "no Salt Shaker, no entry")

	a.itemCooldowns = { [SALT_SHAKER] = { 259200, 259200 } }
	ca:Fire("BAG_UPDATE_COOLDOWN")
	world:Run(4)
	truthy(ca:Record(a.guid).profs[LEATHERWORKING].cds[SALT_SHAKER_SPELL] > world.clock.t + 250000, "used")
	-- A window scan of the profession leaves it alone (it is no recipe).
	ca:OpenTradeSkill(LEATHERWORKING)
	world:Run(900)
	truthy(cb:Record(a.guid).profs[LEATHERWORKING].cds[SALT_SHAKER_SPELL] > world.clock.t + 249000, "the guild knows")
	falsy(cb.ns.Index.IsRecipe(SALT_SHAKER_SPELL), "no recipe to open")
end)

-- Mail ----------------------------------------------------------------------------

-- Mailbox and bags of one client: bags[bag][slot] = { itemID, count };
-- mail[i] = attached { itemID, count }.
local function mailbox(client)
	local env = client.env
	local m = { bags = { [0] = {}, [1] = {} }, mail = {}, hooks = {}, open = false }
	local cursor
	env.ATTACHMENTS_MAX_SEND = 12
	env.MailFrame = { IsShown = function() return m.open end }
	env.MailFrameTab2 = { Click = function() m.tab = 2 end }
	local function box()
		local text = ""
		return { SetText = function(_, v) text = v end, GetText = function() return text end }
	end
	env.SendMailNameEditBox, env.SendMailSubjectEditBox, env.SendMailBodyEditBox = box(), box(), box()
	env.ClearCursor = function() cursor = nil end
	env.HasSendMailItem = function(i) return m.mail[i] ~= nil end
	env.ClickSendMailItemButton = function(i, clear)
		if clear then
			m.mail[i] = nil
		elseif cursor then
			m.mail[i], cursor = cursor, nil
		end
	end
	env.hooksecurefunc = function(name, fn) m.hooks[name] = fn end
	env.SendMailFrame_SendMail = function() end
	local C = env.C_Container
	C.GetContainerNumSlots = function(bag) return m.bags[bag] and 4 or 0 end
	C.GetContainerNumFreeSlots = function() return 0, 0 end
	C.GetContainerItemInfo = function(bag, slot)
		local s = m.bags[bag] and m.bags[bag][slot]
		if s then return { itemID = s[1], stackCount = s[2], isLocked = false, isBound = s.bound == true } end
	end
	C.SplitContainerItem = function(bag, slot, n)
		local s = m.bags[bag][slot]
		assert(n < s[2], "a split is smaller than its stack")
		s[2] = s[2] - n
		cursor = { s[1], n }
	end
	C.PickupContainerItem = function(bag, slot)
		local s = m.bags[bag][slot]
		if cursor then
			assert(not s, "a split goes into an empty slot")
			m.bags[bag][slot], cursor = cursor, nil
		elseif s then
			cursor, m.bags[bag][slot] = s, nil
		end
	end
	return m
end

local function logged(world, text)
	for _, line in ipairs(world.log) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

test("mail: reagents for a crafter, split and attached; the player sends; remembered", function()
	math.randomseed(34)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Mira Feld", profs = {
		[TAILORING] = { rank = 150, maxRank = 300, name = "Tailoring", recipes = { [3914] = 2568 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Tom Berg" })
	local cb = world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(150)
	local M = cb.ns.Mail
	cb.ns.db.recipeFacts[3914].reagents = { { 2589, 2, 0 }, { 2320, 1, 1 } }
	local box = mailbox(cb)
	box.bags[0][1] = { 2589, 4 }
	box.bags[0][2] = { 2589, 5 }
	box.bags[1][1] = { 2320, 10 }
	local crafter = cb.ns.Index.Crafters(3914)[1]

	local item = M.MenuItem(crafter, 3914, 3)
	truthy(item[3], "menu entry disabled while no mailbox is open")
	truthy(item[1]:find("open a mailbox", 1, true), item[1])
	falsy(M.Prepare(a.guid, crafter.name, 3914, 3))
	truthy(logged(world, "Open a mailbox first"), "says why")

	box.open = true
	cb:Fire("MAIL_SHOW")
	item = M.MenuItem(crafter, 3914, 3)
	falsy(item[3], "enabled at the mailbox")
	eq(M.MenuItem({ guid = b.guid, name = "Tom Berg-Realm", isSelf = true }, 3914, 1), nil, "never to yourself")
	item[2]()
	world:Run(2)
	eq(box.tab, 2, "the Send Mail tab")
	eq(box.mail[1][1], 2589)
	eq(box.mail[1][2], 1, "the split comes first")
	eq(box.mail[2][2], 5, "then the whole stack")
	eq(box.mail[3], nil, "the optional reagent stays home")
	eq(cb.env.SendMailNameEditBox:GetText(), "Mira Feld", "own realm: the plain name")
	eq(cb.env.SendMailSubjectEditBox:GetText(), "Reagents: Recipe 3914")
	truthy(logged(world, "Mail ready: 6x Item 2589 to Mira Feld"), "says what is in it")
	falsy(M.Prepare(a.guid, crafter.name, 3914, 1), "a second one waits until this one is sent")
	truthy(logged(world, "already has attachments"))

	-- The player clicks Send in the mailbox.
	box.hooks.SendMailFrame_SendMail()
	box.mail = {}
	cb:Fire("MAIL_SEND_SUCCESS")
	truthy(M.SentAt(a.guid, 3914), "remembered")
	truthy(cb.ns.Index.Crafters(3914)[1].mailedAt, "shown with the crafter")
	truthy(logged(world, "Reagents mailed to Mira Feld"))
	world:Run(3 * 86400 + 60)
	eq(M.SentAt(a.guid, 3914), nil, "forgotten after three days")

	-- Not enough left: nothing happens, the shortfall is named.
	falsy(M.Prepare(a.guid, crafter.name, 3914, 50))
	truthy(logged(world, "Missing: 97x Item 2589"), "100 needed, 3 left")
end)

test("mail: no free bag slot for a split, soulbound reagents, a send that is not ours", function()
	math.randomseed(35)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = guid(1), name = "Mira Feld", profs = {
		[TAILORING] = { rank = 150, maxRank = 300, name = "Tailoring", recipes = { [3914] = 2568 } },
	} })
	local b = world:AddChar({ guid = guid(2), name = "Tom Berg" })
	local cb = world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(TAILORING)
	world:Run(150)
	local M = cb.ns.Mail
	cb.ns.db.recipeFacts[3914].reagents = { { 2589, 2, 0 } }
	local box = mailbox(cb)
	box.open = true
	cb:Fire("MAIL_SHOW")
	-- Every slot full: a split has nowhere to go.
	for bag = 0, 1 do
		for slot = 1, 4 do box.bags[bag][slot] = { 4306, 1 } end
	end
	box.bags[0][1] = { 2589, 5 }
	falsy(M.Prepare(a.guid, "Mira Feld-Realm", 3914, 1))
	truthy(logged(world, "Free up 1 bag slot"))
	-- Soulbound stacks can not be mailed: they count as missing.
	box.bags[0][1] = { 2589, 5, bound = true }
	falsy(M.Prepare(a.guid, "Mira Feld-Realm", 3914, 1))
	truthy(logged(world, "Missing: 2x Item 2589"))
	-- Whole stacks only, then the player changes the recipient: not recorded.
	box.bags[0][1] = { 2589, 2 }
	truthy(M.Prepare(a.guid, "Mira Feld-Realm", 3914, 1))
	eq(box.mail[1][2], 2, "no split needed: attached at once")
	cb.env.SendMailNameEditBox:SetText("Someone Else")
	box.hooks.SendMailFrame_SendMail()
	cb:Fire("MAIL_SEND_SUCCESS")
	eq(M.SentAt(a.guid, 3914), nil, "another recipient: not our mail")
	box.mail = {}
	-- Closing the mailbox drops a mail in preparation.
	box.bags[1][4] = nil
	box.bags[0][2] = { 2589, 5 }
	truthy(M.Prepare(a.guid, "Mira Feld-Realm", 3914, 1))
	box.open = false
	cb:Fire("MAIL_CLOSED")
	world:Run(2)
	eq(next(box.mail), nil, "nothing attached after the mailbox closed")
end)
