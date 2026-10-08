local _, ns = ...

local L, W, Index, Roster, Store, Util = ns.L, ns.Widgets, ns.Index, ns.Roster, ns.Store, ns.Util
local ui = {}

-- Primary professions first; secondary ones (Cooking, First Aid, ...) dimmed.
local function professionText(rec)
	local parts = {}
	local skillLines = Util.SortedKeys(rec.profs)
	Index.SortSkillLines(skillLines, function(sl) return rec.profs[sl].primary end)
	for _, sl in ipairs(skillLines) do
		local p = rec.profs[sl]
		local text = ("%s %d/%d"):format(Index.SkillLineName(sl), p.rank, p.maxRank)
		if not p.recipes then
			text = text .. " |cffff8000(" .. L.NOT_SCANNED .. ")|r"
		else
			text = text .. " |cff999999(" .. Util.Count(p.recipes) .. ")|r"
			if p.unverified then
				text = text .. " |cffff8000" .. L.UNVERIFIED .. "|r"
			end
		end
		if Roster.IsProfessionContradicted(rec.guid, sl) then
			text = "|cff808080" .. text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. " (server: -)|r"
		elseif not p.primary then
			text = "|cffa0a0a0" .. text:gsub("|r", "|cffa0a0a0") .. "|r"
		end
		parts[#parts + 1] = text
	end
	return table.concat(parts, ", ")
end

local function refresh()
	local gd = ns.GetGuildData()
	local rows, recipeTotal = {}, 0
	local isMember = function(guid) return Roster.IsMember(guid) end
	local seen = {}
	for guid, rec in pairs(gd.chars) do
		if Store.IsShareable(rec, isMember) then
			seen[guid] = true
			local member = Roster.Get(guid)
			for _, p in pairs(rec.profs) do
				recipeTotal = recipeTotal + (p.recipes and Util.Count(p.recipes) or 0)
			end
			rows[#rows + 1] = {
				name = (member and member.name) or rec.name,
				class = (member and member.class) or rec.class,
				online = member and member.online,
				ver = rec.ver,
				profs = professionText(rec),
			}
		end
	end
	local shared = #rows
	-- Members the server lists with professions but who share no data.
	for guid, member in pairs(Roster.members) do
		local server = Roster.ServerProfessions(guid)
		if not seen[guid] and server then
			local names = {}
			for sl in pairs(server) do names[#names + 1] = Index.SkillLineName(sl) end
			table.sort(names)
			rows[#rows + 1] = {
				name = member.name, class = member.class, online = member.online, ver = 0,
				profs = "|cff808080" .. table.concat(names, ", ") .. " (no addon data)|r",
			}
		end
	end
	table.sort(rows, function(a, b)
		if (a.ver > 0) ~= (b.ver > 0) then return a.ver > 0 end
		return a.name < b.name
	end)
	ui.header:SetText(L.MEMBERS_HEADER:format(shared, recipeTotal))
	ui.list:SetData(rows)
end

local function build(content)
	ui.header = W.Text(content, "GameFontNormal")
	ui.header:SetPoint("TOPLEFT", 6, -2)

	ui.list = W.CreateList(content, 20, function(row)
		row.name = W.Text(row)
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetWidth(150)
		row.age = W.Text(row, "GameFontDisableSmall")
		row.age:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.age:SetWidth(90)
		row.profs = W.Text(row)
		row.profs:SetPoint("LEFT", row.age, "RIGHT", 4, 0)
		row.profs:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self) W.SendTell(self.data.name) end)
	end, function(row, data)
		row.data = data
		local name = Util.ClassColored(Util.ShortName(data.name), data.class)
		if data.online then name = name .. " |cff20ff20*|r" end
		row.name:SetText(name)
		row.age:SetText(data.ver > 0 and L.CONFIRMED_AGO:format(Util.FormatAge(ns.Now() - data.ver)) or "")
		row.profs:SetText(data.profs)
	end)
	ui.list.box:SetPoint("TOPLEFT", 4, -24)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)
end

ns.UI.RegisterTab("members", L.TAB_MEMBERS, build, refresh)
