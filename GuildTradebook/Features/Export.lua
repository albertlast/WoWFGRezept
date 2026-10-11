--[[
"/gtb export [zip] [name]": the guild pool as JSON, for Discord bots,
spreadsheets and debugging. Not part of the window.

The JSON goes to the SavedVariables entry GuildTradebookExport (written by
the game on /reload or logout; tools/read_export.py takes it out of the
file) and, if it is not too large, into the copy window. With "zip" the
copy window shows "GTB1:" .. Base64(Deflate(JSON)) instead: several times
smaller, so a large guild fits the window and a chat paste. The
SavedVariables keep the plain JSON either way.

Format 1:
{
  format = 1, addon = { version, build }, exportedAt (server time),
  exportedBy, locale, guild,
  members = [ {
    guid, name, class, level, online, playerId, locale, self, linked,
    confirmedAt (= ver), version = { ver, seq, hash },
    receivedAt, receivedFrom, shareable,
    professions = [ { id, name, rank, maxRank, primary, unverified,
      scannedAt, serverContradicts,
      recipes = [ recipeID, ... ] | null (not scanned yet),
      cooldowns = [ { recipe, readyAt (0 = ready) | null (not shared) } ] } ] } ],
  withoutAddon = [ { guid, name, class, level, online, professions = [ name ] } ],
  recipes = { "<recipeID>" = { name, item (0 = none), itemName, profession, category } },
  categories = { "<categoryID>" = { name, names = { locale = name }, parent, order } },
}
Names are in the exporting client's language; IDs are the game's.
]]
local _, ns = ...

local L, Store, Roster, Util = ns.L, ns.Store, ns.Roster, ns.Util
local Export = {}
ns.Export = Export

Export.FORMAT = 1
Export.WINDOW_LIMIT = 200 * 1024 -- larger exports only go to the SavedVariables
Export.ZIP_PREFIX = "GTB1:"

-- Deflate + Base64 with the game's encoder. Tests replace it.
function Export.compress(text)
	local level = Enum.CompressionLevel and Enum.CompressionLevel.OptimizeForSize
	return C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(text, Enum.CompressionMethod.Deflate, level))
end

-- JSON ----------------------------------------------------------------------------

-- Marks a table as a JSON array (an empty plain table is an object).
local ARRAY = {}
function Export.Array(t)
	return setmetatable(t or {}, ARRAY)
end

local function isArray(t)
	if getmetatable(t) == ARRAY then return true end
	local n = #t
	if n == 0 then return false end
	local count = 0
	for _ in pairs(t) do count = count + 1 end
	return count == n
end

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return ESCAPES[c] or ("\\u%04x"):format(c:byte())
	end) .. '"'
end

local function encode(v, out)
	local kind = type(v)
	if kind == "string" then
		out[#out + 1] = encodeString(v)
	elseif kind == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			out[#out + 1] = "null"
		elseif v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			out[#out + 1] = ("%.0f"):format(v)
		else
			out[#out + 1] = ("%.14g"):format(v)
		end
	elseif kind == "boolean" then
		out[#out + 1] = v and "true" or "false"
	elseif kind == "table" then
		if isArray(v) then
			out[#out + 1] = "["
			for i = 1, #v do
				if i > 1 then out[#out + 1] = "," end
				encode(v[i], out)
			end
			out[#out + 1] = "]"
		else
			-- Sorted keys: the same data gives the same text.
			local keys = {}
			for k in pairs(v) do keys[#keys + 1] = tostring(k) end
			table.sort(keys)
			out[#out + 1] = "{"
			for i, k in ipairs(keys) do
				if i > 1 then out[#out + 1] = "," end
				out[#out + 1] = encodeString(k)
				out[#out + 1] = ":"
				local value = v[k]
				if value == nil then value = v[tonumber(k)] end
				encode(value, out)
			end
			out[#out + 1] = "}"
		end
	else
		out[#out + 1] = "null"
	end
end

function Export.ToJSON(v)
	local out = {}
	encode(v, out)
	return table.concat(out)
end

-- Data ----------------------------------------------------------------------------

local function professionsOf(rec, recipes)
	local list = Export.Array()
	local skillLines = Store.ProfessionSkillLines(rec)
	ns.Index.SortSkillLines(skillLines, function(sl) return rec.profs[sl].primary end)
	for _, sl in ipairs(skillLines) do
		local p = rec.profs[sl]
		local entry = {
			id = sl, name = ns.Index.SkillLineName(sl), rank = p.rank, maxRank = p.maxRank,
			primary = p.primary == true, unverified = p.unverified == true, scannedAt = p.scannedAt,
			serverContradicts = Roster.IsProfessionContradicted(rec.guid, sl) and true or false,
			cooldowns = Export.Array(),
		}
		if p.recipes then
			entry.recipes = Export.Array(Util.SortedKeys(p.recipes))
			for rid in pairs(p.recipes) do recipes[rid] = sl end
		end
		for _, rid in ipairs(Util.SortedKeys(p.cds or {})) do
			local readyAt = p.cds[rid]
			table.insert(entry.cooldowns, { recipe = rid, readyAt = not Store.IsHiddenCooldown(readyAt) and readyAt or nil })
		end
		list[#list + 1] = entry
	end
	return list
end

local function matches(name, filter)
	return not filter or (name and name:lower():find(filter, 1, true) ~= nil)
end

--[[
The export table. filter: optional part of a character name (lower case);
then only matching characters, and only their recipes.
]]
function Export.Build(filter)
	local gd = ns.GetGuildData()
	local version, build = ns.Versions.Mine()
	local data = {
		format = Export.FORMAT,
		addon = { version = version, build = build },
		exportedAt = ns.Now(),
		exportedBy = Util.PlayerName(),
		locale = GetLocale(),
		guild = Roster.guildKey,
		members = Export.Array(),
		withoutAddon = Export.Array(),
		recipes = {},
		categories = {},
	}
	if not gd then return data end
	local self = UnitGUID("player")
	local recipeSkill, seen = {}, {}
	for _, guid in ipairs(Util.SortedKeys(gd.chars)) do
		local rec = gd.chars[guid]
		local member = Roster.Get(guid)
		local name = Roster.NameOf(guid) or rec.name
		seen[guid] = true
		if matches(name, filter) then
			table.insert(data.members, {
				guid = guid, name = name,
				class = (member and member.class) or rec.class,
				level = (member and member.level) or rec.level,
				online = (member and member.online) or false,
				playerId = rec.player, locale = rec.loc,
				self = guid == self, linked = ns.Link.IsPartner(guid),
				confirmedAt = rec.ver, version = Export.Array({ rec.ver, rec.seq, rec.h or Store.Hash(rec) }),
				receivedAt = rec.recvAt, receivedFrom = rec.recvFrom,
				shareable = Store.IsShareable(rec, Roster.IsMember),
				professions = professionsOf(rec, recipeSkill),
			})
		end
	end
	for _, guid in ipairs(Util.SortedKeys(Roster.members)) do
		local member = Roster.members[guid]
		local server = Roster.ServerProfessions(guid)
		if not seen[guid] and server and matches(member.name, filter) then
			local names = Export.Array()
			for _, sl in ipairs(Util.SortedKeys(server)) do names[#names + 1] = ns.Index.SkillLineName(sl) end
			table.insert(data.withoutAddon, {
				guid = guid, name = member.name, class = member.class, level = member.level,
				online = member.online or false, professions = names,
			})
		end
	end
	local categories = {}
	for rid, sl in pairs(recipeSkill) do
		local item = ns.Index.OutputItem(rid)
		local cat = ns.Categories.Of(rid)
		local fact = ns.db.recipeFacts[rid]
		data.recipes[tostring(rid)] = {
			name = ns.Index.RecipeName(rid), item = item,
			itemName = item > 0 and C_Item.GetItemNameByID(item) or nil,
			profession = sl, category = cat, greyAt = fact and fact.trivial,
		}
		if cat then categories[cat] = true end
	end
	for id in pairs(categories) do
		local cat = ns.db.categories[id]
		if cat then
			data.categories[tostring(id)] = {
				name = ns.Categories.Name(id), names = cat.names, parent = cat.parent, order = cat.order,
			}
		end
	end
	return data
end

-- "/gtb export [zip] [name]". Returns the JSON and the text shown (the
-- compressed form with "zip"), or nil when no character matches.
function Export.Command(rest)
	local text = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	local zip = text == "zip" or text:sub(1, 4) == "zip "
	if zip then text = text:sub(5):gsub("^%s+", "") end
	local filter = text ~= "" and text or nil
	local data = Export.Build(filter)
	if filter and #data.members == 0 and #data.withoutAddon == 0 then
		-- Nothing matched: keep the previous export.
		ns.Print(L.EXPORT_NO_MATCH:format(filter))
		return nil
	end
	local json = Export.ToJSON(data)
	GuildTradebookExport = { format = Export.FORMAT, exportedAt = data.exportedAt, json = json }
	local recipes = 0
	for _ in pairs(data.recipes) do recipes = recipes + 1 end
	local shown = json
	if zip then
		local ok, packed = pcall(Export.compress, json)
		if ok and type(packed) == "string" then
			shown = Export.ZIP_PREFIX .. packed
		else
			ns.Print(L.EXPORT_ZIP_FAILED)
		end
	end
	ns.Print(L.EXPORT_DONE:format(#data.members, #data.withoutAddon, recipes, math.ceil(#shown / 1024)))
	if #shown <= Export.WINDOW_LIMIT then
		if ns.Widgets and ns.Widgets.ShowText then ns.Widgets.ShowText(L.EXPORT_TITLE, shown) end
	else
		ns.Print(zip and L.EXPORT_TOO_BIG or L.EXPORT_TOO_BIG_ZIP)
	end
	return json, shown
end
