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
		if p.cds and next(p.cds) then
			local now, cds = ns.Now(), {}
			for _, rid in ipairs(Util.SortedKeys(p.cds)) do
				local readyAt = p.cds[rid]
				local state = readyAt <= now and ("|cff20ff20" .. L.CD_READY .. "|r")
					or ("|cffff8000" .. Util.FormatAge(readyAt - now) .. "|r")
				cds[#cds + 1] = (Index.RecipeName(rid) or ("#" .. rid)) .. " " .. state
			end
			text = text .. " [" .. table.concat(cds, ", ") .. "]"
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
				guid = guid,
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
				guid = guid, name = member.name, class = member.class, online = member.online, ver = 0,
				profs = "|cff808080" .. table.concat(names, ", ") .. " (" .. L.NO_ADDON_DATA .. ")|r",
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

	local function hint(frame, text)
		frame:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(text(self), 1, 1, 1)
			GameTooltip:Show()
		end)
		frame:SetScript("OnLeave", GameTooltip_Hide)
	end

	-- Two click areas: the name whispers, the professions open the member's
	-- recipes in the Recipes tab.
	ui.list = W.CreateList(content, 20, function(row)
		row.nameButton = CreateFrame("Button", nil, row)
		row.nameButton:SetPoint("TOPLEFT")
		row.nameButton:SetPoint("BOTTOMLEFT")
		row.nameButton:SetWidth(248)
		row.nameButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.nameButton:SetScript("OnClick", function(self) W.SendTell(self:GetParent().data.name) end)
		hint(row.nameButton, function() return L.CLICK_WHISPER end)
		row.name = W.Text(row.nameButton)
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetWidth(150)
		row.age = W.Text(row.nameButton, "GameFontDisableSmall")
		row.age:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.age:SetWidth(90)
		row.profs = W.Text(row)
		row.profs:SetPoint("LEFT", row.nameButton, "RIGHT", 4, 0)
		row.profs:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self)
			if self.data.ver > 0 then
				ns.UI.ShowCrafter(self.data.guid)
			end
		end)
		hint(row, function(self)
			return self.data.ver > 0 and L.CLICK_SHOW_RECIPES or L.NO_ADDON_DATA
		end)
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
