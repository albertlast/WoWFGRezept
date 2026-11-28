--[[
Every recipe of a profession, learned or not, as the profession window lists
it (GetAllRecipeIDs). That is static game data, the same for everyone with
the profession, so the account keeps one list per profession:
  ns.db.recipeLists[skillLine] = { b = game build, own = true | nil, l = { recipeID, ... } (sorted) }
own: read from our own window (Scanner). A list from a guild member never
replaces it. A list of another game build counts as missing: a patch can
add recipes.

The Recipes tab's "Unknown in guild" switch shows every listed recipe that
nobody in the guild knows (Search/Unknown.lua). Lists of professions this
account does not have come from guild members, only while the switch is
used:
  LIST_REQ (L)  to an online member with the profession running 0.21 or
                later; older versions ignore the message type and are
                never asked
  LIST (M)      the answer, one profession per message, with the facts the
                tab shows (item, grey skill, category)
A member that has no list (it has not opened the window since 0.21) does
not answer; after RETRY the next member is asked. Answers are taken only for
professions we asked for and only from the same game build.
]]
local _, ns = ...

local Util, Store, Roster = ns.Util, ns.Store, ns.Roster
local Catalog = {
	requested = {}, -- [skillLine] = { at = GetTime(), first = GetTime(), tried = { [guid] = true } }
	shownUntil = 0, -- GetTime() until which missing lists are asked for
}
ns.Catalog = Catalog

Catalog.MIN_MAJOR, Catalog.MIN_MINOR = 0, 21 -- first release that answers LIST_REQ
Catalog.MAX_RECIPES = 1000   -- recipes in one list
Catalog.MAX_SKILLS = 20      -- professions in one LIST_REQ
Catalog.RETRY = 60           -- seconds before the next member is asked
Catalog.RESET = 600          -- seconds after which members already asked may be asked again
Catalog.MAX_TARGETS = 3      -- members asked per round
Catalog.SHOWN_FOR = 300      -- seconds of asking after the tab last showed the list

-- The game build: version and build number (a hotfix build can add recipes).
function Catalog.Build()
	local version, build = GetBuildInfo()
	return tostring(version or "?") .. "." .. tostring(build or 0)
end

-- The current list of a profession ({ recipeID, ... }), or nil.
function Catalog.Recipes(skillLine)
	local e = ns.db.recipeLists[skillLine]
	if e and e.b == Catalog.Build() then return e.l end
	return nil
end

-- Professions with a current list.
function Catalog.SkillLines()
	local out = {}
	for sl in pairs(ns.db.recipeLists) do
		if Catalog.Recipes(sl) then out[#out + 1] = sl end
	end
	table.sort(out)
	return out
end

--[[
Stores a profession's list (recipeIDs, any order). own: from our own window.
Returns true if it changed; then RecipeListsChanged is emitted.
]]
function Catalog.Set(skillLine, ids, own)
	local build = Catalog.Build()
	local cur = ns.db.recipeLists[skillLine]
	local current = cur and cur.b == build
	if not own and current and cur.own then return false end
	local list = {}
	for i, rid in ipairs(ids) do list[i] = rid end
	table.sort(list)
	local same = current and #cur.l == #list and (cur.own or false) == (own or false)
	if same then
		for i = 1, #list do
			if cur.l[i] ~= list[i] then
				same = false
				break
			end
		end
	end
	Catalog.requested[skillLine] = nil
	if same then return false end
	ns.db.recipeLists[skillLine] = { b = build, own = own or nil, l = list }
	ns.Emit("RecipeListsChanged", skillLine)
	return true
end

-- Wire form of a list: { recipeID, item, grey skill, category, ... }, 0 =
-- not known; nil without a current list.
function Catalog.ToWire(skillLine)
	local list = Catalog.Recipes(skillLine)
	if not list then return nil end
	local flat = {}
	for _, rid in ipairs(list) do
		local f = ns.db.recipeFacts[rid]
		flat[#flat + 1] = rid
		flat[#flat + 1] = f and f.item or 0
		flat[#flat + 1] = f and f.trivial or 0
		flat[#flat + 1] = f and f.cat or 0
	end
	return flat
end

--[[
A list from a guild member (LIST). Taken only if we asked for the
profession, the build is ours and every field is valid. Returns true if it
was stored.
]]
function Catalog.FromWire(skillLine, build, flat)
	if not Util.IsInt(skillLine, 1, 2 ^ 31) or not Catalog.requested[skillLine] then return false end
	if build ~= Catalog.Build() or type(flat) ~= "table" then return false end
	local n = #flat
	if n == 0 or n % 4 ~= 0 or n / 4 > Catalog.MAX_RECIPES then return false end
	for i = 1, n, 4 do
		if not (Util.IsInt(flat[i], 1, 2 ^ 31) and Util.IsInt(flat[i + 1], 0, 2 ^ 31)
			and Util.IsInt(flat[i + 2], 0, 10000) and Util.IsInt(flat[i + 3], 0, 2 ^ 31)) then
			return false
		end
	end
	local ids, factBuild = {}, ns.Scanner.BuildKey()
	for i = 1, n, 4 do
		local rid, item, trivial, cat = flat[i], flat[i + 1], flat[i + 2], flat[i + 3]
		ids[#ids + 1] = rid
		-- 0 = the sender does not know; local facts always win (SetFact).
		Store.SetFact(ns.db, rid, { item = item > 0 and item or nil, trivial = trivial > 0 and trivial or nil,
			cat = cat > 0 and cat or nil }, false, factBuild)
	end
	return Catalog.Set(skillLine, ids, false)
end

-- Professions the guild has (Recipes tab) without a current list here.
function Catalog.Missing()
	local out = {}
	for _, sl in ipairs(ns.Index.SkillLines()) do
		if not Catalog.Recipes(sl) then out[#out + 1] = sl end
	end
	return out
end

local function online(guid)
	local m = Roster.Get(guid)
	return m ~= nil and m.online == true
end

-- True if this member's build answers LIST_REQ.
function Catalog.CanAnswer(guid)
	return ns.Versions.AtLeast(Roster.NameOf(guid), Catalog.MIN_MAJOR, Catalog.MIN_MINOR)
end

--[[
Asks for the missing lists: per profession one online member that has it
(its record has the profession's recipes) and runs a build that answers.
Members are picked at random, so one member does not answer for everyone;
professions go to a member already picked this round when it has them too.
]]
function Catalog.RequestMissing()
	local gd = ns.GetGuildData()
	if not gd or GetTime() > Catalog.shownUntil then return end
	local missing = Catalog.Missing()
	if #missing == 0 then return end
	local now, self = GetTime(), UnitGUID("player")
	local byTarget, targets = {}, {}
	for _, sl in ipairs(missing) do
		local req = Catalog.requested[sl]
		if req and now - req.first > Catalog.RESET then
			req = nil
			Catalog.requested[sl] = nil
		end
		if not req or now - req.at > Catalog.RETRY then
			local candidates = {}
			for guid, rec in pairs(gd.chars) do
				local p = rec.profs[sl]
				if guid ~= self and p and p.recipes and not (req and req.tried[guid]) and online(guid)
					and Store.IsShareable(rec, Roster.IsMember) and Catalog.CanAnswer(guid) then
					candidates[#candidates + 1] = guid
				end
			end
			table.sort(candidates)
			local target
			for _, guid in ipairs(candidates) do
				if byTarget[guid] and #byTarget[guid] < Catalog.MAX_SKILLS then
					target = guid
					break
				end
			end
			if not target and #candidates > 0 and #targets < Catalog.MAX_TARGETS then
				target = candidates[math.random(#candidates)]
				byTarget[target] = {}
				targets[#targets + 1] = target
			end
			if target then
				table.insert(byTarget[target], sl)
				local tried = req and req.tried or {}
				tried[target] = true
				Catalog.requested[sl] = { at = now, first = req and req.first or now, tried = tried }
			end
		end
	end
	for _, guid in ipairs(targets) do
		ns.Debug("recipe lists from", Roster.NameOf(guid), table.concat(byTarget[guid], ","))
		ns.Protocol.RequestLists(guid, byTarget[guid])
	end
	ns.ScheduleEarliest("recipeLists", Catalog.RETRY + 1, Catalog.RequestMissing)
end

-- The Recipes tab shows the unknown recipes: missing lists are asked for
-- now and, while it keeps showing them, again after RETRY.
function Catalog.Shown()
	Catalog.shownUntil = GetTime() + Catalog.SHOWN_FOR
	ns.ScheduleEarliest("recipeLists", 2, Catalog.RequestMissing)
end

ns.On("GuildChanged", function() Catalog.requested = {} end)
