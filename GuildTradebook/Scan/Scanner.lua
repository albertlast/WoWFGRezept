--[[
Reads the logged-in character's professions and recipes and keeps its own
record (the only record this client may author) up to date.
]]
local _, ns = ...

local Store, Util = ns.Store, ns.Util
local Scanner = {}
ns.Scanner = Scanner

local REMOVAL_CONFIRM_DELAY = 5

local function collect(...)
	return select("#", ...), { ... }
end

function Scanner.BuildKey()
	local version = GetBuildInfo()
	return (version and version:match("^(%d+%.%d+)")) or "0"
end

-- Same rule as the tabs of Blizzard's professions window: a profession has
-- recipes to share if the game can show a crafting window for it. Returns
-- true / false, or nil when the spell data is not available yet.
local function hasCraftingUI(spellOffset)
	if not (C_SpellBook and C_SpellBook.GetSpellBookItemInfo and C_TradeSkillUI.CanTradeSkillShowCraftingUI) then
		return nil
	end
	local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
	local info = spellOffset and C_SpellBook.GetSpellBookItemInfo(spellOffset + 1, bank)
	if not info or not info.spellID then return nil end
	return C_TradeSkillUI.CanTradeSkillShowCraftingUI(info.spellID) and true or false
end

-- Live profession list: [skillLine] = { rank, maxRank, name, primary }
-- GetProfessions() returns the two primary slots first, then the secondary ones.
function Scanner.Snapshot()
	local snapshot = {}
	local n, indices = collect(GetProfessions())
	for i = 1, n do
		local index = indices[i]
		if index then
			local name, _, rank, maxRank, _, spellOffset, skillLine = GetProfessionInfo(index)
			if skillLine and skillLine > 0 then
				local craftable = hasCraftingUI(spellOffset)
				if craftable == nil then
					craftable = not Store.NO_RECIPE_SKILLLINES[skillLine]
				end
				if craftable then
					snapshot[skillLine] = { rank = rank or 0, maxRank = maxRank or 0, name = name, primary = i <= 2 }
				end
			end
		end
	end
	return snapshot
end

function Scanner.GetOwn()
	local gd = ns.GetGuildData()
	local guid = UnitGUID("player")
	if not gd or not guid then return nil end
	local fresh = gd.chars[guid] == nil
	local own = Store.EnsureOwn(gd, guid)
	if fresh then
		Scanner.BeginAdoption()
	end
	-- Account bookkeeping: the account's characters share one player ID
	-- (Scanner.UpdatePlayerId) and are marked as alts in the UI.
	local acc = ns.db.account.chars[guid] or {}
	acc.guildKey = ns.Roster.guildKey
	acc.name = own.name
	acc.class = own.class
	ns.db.account.chars[guid] = acc
	return own
end

--[[
Adoption window: a brand-new own record (version 0, e.g. after the WTF folder
was deleted) must not be published right away. Its fresh version would beat
the pool's copy and wipe the recipes we could adopt from it. While the window
is open, version 0 loses every comparison, so peers push their copy to us
(Protocol -> OnSelfCopy -> MergeIncomingSelf). Pending changes are committed
when a copy arrives or the window ends.
]]
Scanner.ADOPT_WINDOW = 90
Scanner.adopting = false

function Scanner.BeginAdoption()
	Scanner.adopting = true
	ns.Debounce("adopt", Scanner.ADOPT_WINDOW, Scanner.FinishAdoption)
end

-- The first sync round starts after the roster is ready: give it a full window.
local function extendAdoption()
	if Scanner.adopting then
		Scanner.BeginAdoption()
	end
end

function Scanner.FinishAdoption()
	ns.Cancel("adopt")
	if not Scanner.adopting then return end
	Scanner.adopting = false
	local kind = Scanner.pendingKind
	Scanner.pendingKind = nil
	local own = Scanner.GetOwn()
	if own and kind then
		Scanner.Commit(own, kind)
	end
end

-- Bumps the version after a change and lets the protocol publish it.
function Scanner.Commit(own, kind)
	if Scanner.adopting and own.ver == 0 then
		if kind == "major" or not Scanner.pendingKind then
			Scanner.pendingKind = kind
		end
		return
	end
	Store.Bump(own, ns.Now())
	ns.Debug("own record changed", kind, own.ver, own.seq)
	ns.Emit("OwnChanged", kind)
	ns.Emit("RecordsChanged", own.guid)
end

local function updateIdentity(own)
	local name = Util.PlayerName()
	local _, classFile = UnitClass("player")
	local level = UnitLevel("player")
	local kind
	if own.name ~= name or own.class ~= classFile then
		own.name, own.class = name, classFile
		kind = "major"
	end
	if own.level ~= level then
		own.level = level
		kind = kind or "minor"
	end
	-- Client language: !craft answers come from a client that knows the
	-- names in the asker's language (ChatResponder).
	local loc = GetLocale and GetLocale()
	if loc and own.loc ~= loc then
		own.loc = loc
		kind = kind or "minor"
	end
	return kind
end

-- One reminder per session, naming an unscanned primary profession first.
local function remindUnscanned(own, snapshot)
	if Scanner.reminded then return end
	local pick
	for sl, p in pairs(own.profs) do
		if p.recipes == nil and snapshot[sl] and (not pick or (p.primary and not own.profs[pick].primary)) then
			pick = sl
		end
	end
	if pick then
		Scanner.reminded = true
		ns.Print(ns.L.REMIND_SCAN:format(snapshot[pick].name or "?"))
	end
end

function Scanner.Reconcile(allowRemove)
	local own = Scanner.GetOwn()
	if not own then return end
	local snapshot = Scanner.Snapshot()
	local kind = updateIdentity(own)
	local profKind, removals = Store.ReconcileProfessions(own, snapshot, allowRemove)
	if profKind == "major" or kind == nil then
		kind = profKind or kind
	end
	if #removals > 0 and not allowRemove then
		-- The profession list can be empty or partial during loading screens;
		-- only drop a profession if a second look agrees.
		ns.Debounce("reconcileConfirm", REMOVAL_CONFIRM_DELAY, function()
			Scanner.Reconcile(true)
		end)
	end
	if kind then
		Scanner.Commit(own, kind)
	end
	Scanner.UpdatePlayerId()
	remindUnscanned(own, snapshot)
end

local function newPlayerId()
	return Store.NewPlayerId(math.random)
end

--[[
Gives all of the account's characters in this guild the same player ID (see
Store.ReconcilePlayerId). extra: the ID of a copy of the logged-in character
seen in the pool. Alts are not logged in, but their records belong to this
account, so it may publish them with a new version.
]]
function Scanner.UpdatePlayerId(extra)
	local gd = ns.GetGuildData()
	local own = Scanner.GetOwn()
	if not (gd and own) then return end
	local guids = {}
	for guid in pairs(ns.db.account.chars) do
		local rec = gd.chars[guid]
		if rec and not rec.goneSince then
			guids[#guids + 1] = guid
		end
	end
	table.sort(guids)
	local _, stamped = Store.ReconcilePlayerId(gd, guids, extra, newPlayerId)
	for _, guid in ipairs(stamped) do
		local rec = gd.chars[guid]
		if guid == own.guid then
			Scanner.Commit(own, "major")
		elseif rec.ver > 0 then
			Store.Bump(rec, ns.Now())
			ns.Protocol.QueuePush(guid)
			ns.Emit("RecordsChanged", guid)
		end
	end
end

-- The profession a recipe belongs to, according to the game (or nil).
local function skillLineForRecipe(recipeID)
	local info = C_TradeSkillUI.GetProfessionInfoByRecipeID and C_TradeSkillUI.GetProfessionInfoByRecipeID(recipeID)
	if not info then return nil end
	if info.parentProfessionID and info.parentProfessionID ~= 0 then
		return info.parentProfessionID
	end
	return info.professionID
end

-- True if the game says the recipe belongs to ANOTHER profession this
-- character has. Unknown or unexpected IDs never count as foreign, so a
-- mapping quirk can not wipe a real recipe list.
local function isForeign(own, skillLine, recipeID)
	local owner = skillLineForRecipe(recipeID)
	return owner ~= nil and owner ~= skillLine and own.profs[owner] ~= nil
end

-- Resolves static recipe facts from the local client and caches them.
function Scanner.ResolveFact(recipeID, info)
	local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
	if not schematic then return nil end
	local enchant = (info and info.isEnchantingRecipe) or false
	if Enum.TradeskillRecipeType and schematic.recipeType == Enum.TradeskillRecipeType.Enchant then
		enchant = true
	end
	local reagents = {}
	for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
		local r = slot.reagents and slot.reagents[1]
		if r and r.itemID then
			reagents[#reagents + 1] = { r.itemID, slot.quantityRequired or 1, slot.required == false and 1 or 0 }
		end
	end
	local fact = { item = schematic.outputItemID or 0, enchant = enchant, reagents = reagents }
	Store.SetFact(ns.db, recipeID, fact, true, Scanner.BuildKey())
	return fact
end

--[[
Cooldown of one recipe: seconds remaining (0 = ready), or nil if the recipe
has no known cooldown. A ready cooldown recipe looks like any other recipe,
so a recipe counts as a cooldown recipe once it was seen on cooldown or
reports charges; that knowledge is kept in recipeFacts and in the record.
]]
function Scanner.ReadCooldown(recipeID, knownCooldown)
	if not C_TradeSkillUI.GetRecipeCooldown then return nil end
	local cooldown, _, charges, maxCharges = C_TradeSkillUI.GetRecipeCooldown(recipeID)
	local onCooldown = cooldown ~= nil and cooldown > 0 and not (charges and charges > 0)
	local fact = ns.db.recipeFacts[recipeID]
	if onCooldown or (maxCharges and maxCharges > 0) then
		if fact then fact.cd = true end
	elseif not (knownCooldown or (fact and fact.cd)) then
		return nil
	end
	return onCooldown and cooldown or 0
end

-- Reads the open profession window, if it is the player's own.
function Scanner.ScanTradeSkill()
	if not C_TradeSkillUI.IsTradeSkillReady() then return end
	-- While switching tabs the window can briefly return the previous
	-- profession's recipes; the debounced scan runs again afterwards.
	if C_TradeSkillUI.IsDataSourceChanging and C_TradeSkillUI.IsDataSourceChanging() then return end
	if C_TradeSkillUI.IsTradeSkillLinked() or C_TradeSkillUI.IsTradeSkillGuild() then return end
	if C_TradeSkillUI.IsNPCCrafting and C_TradeSkillUI.IsNPCCrafting() then return end

	local base = C_TradeSkillUI.GetBaseProfessionInfo()
	local skillLine = base and base.professionID
	if not skillLine or skillLine == 0 then return end

	local own = Scanner.GetOwn()
	if not own then return end
	if not own.profs[skillLine] then
		Scanner.Reconcile(false)
		if not own.profs[skillLine] then return end
	end

	-- GetAllRecipeIDs is not in the generated API docs of the forever branch;
	-- the filtered list is used by Blizzard's UI and depends on its filters,
	-- so it only counts as a partial scan.
	local ids, complete
	if C_TradeSkillUI.GetAllRecipeIDs then
		ids, complete = C_TradeSkillUI.GetAllRecipeIDs(), true
	else
		ids, complete = C_TradeSkillUI.GetFilteredRecipeIDs(), false
	end
	if not ids or #ids == 0 then return end

	local prof = own.profs[skillLine]
	local recipes, cooldowns, count = {}, {}, 0
	for _, recipeID in ipairs(ids) do
		local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
		if info and info.learned and not info.isDummyRecipe and not info.isGatheringRecipe
			and not info.isSalvageRecipe and not info.isRecraft and not isForeign(own, skillLine, recipeID) then
			local fact = Scanner.ResolveFact(recipeID, info)
			recipes[recipeID] = fact and fact.item or 0
			cooldowns[recipeID] = Scanner.ReadCooldown(recipeID, prof.cds and prof.cds[recipeID] ~= nil)
			count = count + 1
		end
	end
	if count == 0 then return end

	ns.Debug("scanned", skillLine, count, "recipes", complete and "complete" or "partial")
	local now = ns.Now()
	local recipesChanged = Store.ApplyScan(own, skillLine, recipes, complete, now)
	-- Clean up recipes stored under the wrong profession by older versions.
	if Store.RemoveRecipes(own, skillLine, function(rid) return isForeign(own, skillLine, rid) end) then
		recipesChanged = true
	end
	local cooldownsChanged = Store.ApplyCooldowns(own, skillLine, cooldowns, now)
	if recipesChanged then
		Scanner.Commit(own, Store.ChangeKind(prof))
	elseif cooldownsChanged then
		-- A started cooldown is not urgent: it rides the 60 s batch.
		Scanner.Commit(own, "minor")
	end
end

function Scanner.OnRecipeLearned(_, recipeID)
	local own = Scanner.GetOwn()
	local skillLine = recipeID and skillLineForRecipe(recipeID)
	if not own or not skillLine then return end
	local fact = Scanner.ResolveFact(recipeID, C_TradeSkillUI.GetRecipeInfo(recipeID))
	if Store.AddLearned(own, skillLine, recipeID, fact and fact.item or 0) then
		Scanner.Commit(own, Store.ChangeKind(own.profs[skillLine]))
	end
end

function Scanner.Start()
	-- The professions window has one tab per profession; each tab click loads
	-- another profession into the same window. Scan the current one right away
	-- (fast tab clicking must not skip any), at most every 2 s per profession,
	-- and again shortly after the events settle to catch late-loading data.
	local lastScan = {}
	local function scanSoon()
		if C_TradeSkillUI.IsTradeSkillReady() then
			local base = C_TradeSkillUI.GetBaseProfessionInfo()
			local skillLine = base and base.professionID
			if skillLine and (not lastScan[skillLine] or GetTime() - lastScan[skillLine] > 2) then
				lastScan[skillLine] = GetTime()
				Scanner.ScanTradeSkill()
			end
		end
		ns.Debounce("scan", 1, Scanner.ScanTradeSkill)
	end
	local function reconcileSoon()
		ns.Debounce("reconcile", 2, function() Scanner.Reconcile(false) end)
	end
	ns.RegisterEvent("TRADE_SKILL_SHOW", scanSoon)
	ns.RegisterEvent("TRADE_SKILL_LIST_UPDATE", scanSoon)
	ns.RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", scanSoon)
	ns.RegisterEvent("NEW_RECIPE_LEARNED", Scanner.OnRecipeLearned)
	ns.RegisterEvent("SKILL_LINES_CHANGED", reconcileSoon)
	ns.RegisterEvent("PLAYER_LEVEL_UP", reconcileSoon)
	ns.On("RosterReady", function()
		extendAdoption()
		reconcileSoon()
	end)
	-- The server told us our exact name (Protocol, own echoed message).
	ns.On("PlayerNameLearned", reconcileSoon)
	ns.On("GuildChanged", function()
		Scanner.reminded = nil
		Scanner.adopting = false
		Scanner.pendingKind = nil
		reconcileSoon()
	end)
end
