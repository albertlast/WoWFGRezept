--[[
Recipe categories, as in the profession window ("Cloaks", "Reagents", ...).
  recipe -> category   recipeFacts[recipeID].cat, carried by the crafter's
                       record (Store: profession slot 9)
  category -> name     ns.db.categories (Store), per language
The game names categories only in the client's language and only for the
profession in the open window. Missing names are asked from guild members:
one who speaks our language and has the category (the crafter scanned it in
that language), else, while no name is known at all, any crafter who has it.
Until our language arrives the English or German name is shown.

The same request (CAT_REQ) also asks for the category of recipes that came
without one: a 0.1.0 client relays records without the categories, and the
sync never sends the same version again. Any member running a build with
categories may know them (they are the same for every crafter). That part
runs only while the Recipes tab shows such recipes (Categories.Shown):
right after an update most records have no categories yet, and every
client asking in the background would flood the guild.
]]
local _, ns = ...

local Store, Roster, Util = ns.Store, ns.Roster, ns.Util
local Categories = {
	requested = {},       -- [categoryID] = { at = GetTime(), own = asked our language }
	recipeRequested = {}, -- [recipeID] = GetTime(): asked for its category
}
ns.Categories = Categories

Categories.RETRY = 600       -- seconds before the same thing is asked again
Categories.MAX_TARGETS = 3   -- members asked per round

function Categories.Of(recipeID)
	local fact = ns.db.recipeFacts[recipeID]
	return fact and fact.cat or nil
end

-- Display name, or nil while no language is known.
function Categories.Name(id)
	return id and Store.CategoryName(ns.db, id, GetLocale()) or nil
end

function Categories.Order(id)
	local cat = id and ns.db.categories[id]
	return cat and cat.order or nil
end

local function online(guid)
	local m = Roster.Get(guid)
	return m ~= nil and m.online == true
end

--[[
What the visible recipes lack:
  missing        { [categoryID] = hasAnyName }: no name in our language
  uncategorized  { recipeID, ... }: no category known
]]
function Categories.Missing()
	ns.Index.Ensure()
	local locale, missing, uncategorized = GetLocale(), {}, {}
	for rid in pairs(ns.Index.byRecipe) do
		local id = Categories.Of(rid)
		if not id then
			uncategorized[#uncategorized + 1] = rid
		elseif missing[id] == nil then
			local cat = ns.db.categories[id]
			if not (cat and cat.names[locale]) then
				missing[id] = cat ~= nil and next(cat.names) ~= nil
			end
		end
	end
	table.sort(uncategorized)
	return missing, uncategorized
end

--[[
Picks whom to ask and sends the requests. A missing name goes to
  1. an online crafter of our language whose record has the category (it
     scanned the category, so it has the name)
  2. no name known at all: any online crafter whose record has it
Otherwise nobody is asked: the English or German name stays. A name is
asked again after RETRY (lost answer), or at once when a crafter of our
language comes online and the last request went to another language. A
recipe without category goes to an online crafter of it running a build
with categories, else to any member running one. While something is
missing, the check repeats every RETRY.
]]
function Categories.RequestMissing(withRecipes)
	local gd = ns.GetGuildData()
	if not gd then return end
	local missing, uncategorized = Categories.Missing()
	if not withRecipes then uncategorized = {} end
	if not next(missing) and #uncategorized == 0 then return end
	local now, locale, self = GetTime(), GetLocale(), UnitGUID("player")

	-- Online members running a build with categories: their record has
	-- some, or they wrote from 0.2 or later.
	local sameLang, otherLang, knowers, knows = {}, {}, {}, {}
	for guid, rec in pairs(gd.chars) do
		if guid ~= self and Store.IsShareable(rec, Roster.IsMember) and online(guid) then
			knows[guid] = ns.Versions.AtLeast(Roster.NameOf(guid), 0, 2) or nil
			for _, p in pairs(rec.profs) do
				for _, id in pairs(p.cats or {}) do
					knows[guid] = true
					if missing[id] ~= nil then
						local into = rec.loc == locale and sameLang or otherLang
						into[id] = into[id] or guid
					end
				end
			end
			if knows[guid] then knowers[#knowers + 1] = guid end
		end
	end
	if #knowers == 0 then
		ns.ScheduleEarliest("categoryNames", Categories.RETRY + 1, Categories.RequestMissing)
		return
	end
	table.sort(knowers)

	local byTarget, targets = {}, 0
	local function slot(target)
		if not byTarget[target] then
			if targets >= Categories.MAX_TARGETS then return nil end
			byTarget[target] = { ids = {}, rids = {} }
			targets = targets + 1
		end
		return byTarget[target]
	end
	for _, id in ipairs(Util.SortedKeys(missing)) do
		local own = sameLang[id]
		local target = own
		if not target and not missing[id] then target = otherLang[id] end
		local last = Categories.requested[id]
		local due = not last or now - last.at > Categories.RETRY or (own ~= nil and not last.own)
		local s = target and due and slot(target)
		if s and #s.ids < ns.Protocol.MAX_CATEGORIES then
			s.ids[#s.ids + 1] = id
			Categories.requested[id] = { at = now, own = own ~= nil }
		end
	end
	for _, rid in ipairs(uncategorized) do
		local last = Categories.recipeRequested[rid]
		if not last or now - last > Categories.RETRY then
			local target
			for _, guid in ipairs(ns.Index.byRecipe[rid] or {}) do
				if knows[guid] then target = guid break end
			end
			local s = slot(target or knowers[1])
			if s and #s.rids < ns.Protocol.MAX_CATEGORY_RECIPES then
				s.rids[#s.rids + 1] = rid
				Categories.recipeRequested[rid] = now
			end
		end
	end
	for guid, s in pairs(byTarget) do
		if #s.ids > 0 or #s.rids > 0 then
			ns.Debug("categories from", Roster.NameOf(guid), #s.ids, "names", #s.rids, "recipes")
			ns.Protocol.RequestCategories(guid, s.ids, s.rids)
		end
	end
	ns.ScheduleEarliest("categoryNames", Categories.RETRY + 1, Categories.RequestMissing)
end

-- Not postponed by further changes: in a busy guild records keep arriving.
local function soon()
	ns.ScheduleEarliest("categoryNames", 10, Categories.RequestMissing)
end

-- The Recipes tab shows recipes without a category.
function Categories.Shown()
	ns.ScheduleEarliest("categoryRecipes", 5, function() Categories.RequestMissing(true) end)
end
ns.On("RecordsChanged", soon)
ns.On("RosterReady", soon)
ns.On("RosterUpdated", soon)
ns.On("GuildChanged", function()
	Categories.requested = {}
	Categories.recipeRequested = {}
end)
