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

-- One group per person (characters with the same player ID). The group's
-- first row is the character that is online, else the highest level one;
-- the other characters follow indented, by name.
local function groupRows(rows)
	local groups, byKey = {}, {}
	for _, row in ipairs(rows) do
		local key = row.player or row.guid
		local g = byKey[key]
		if not g then
			g = { rows = {}, hasData = false }
			byKey[key] = g
			groups[#groups + 1] = g
		end
		g.rows[#g.rows + 1] = row
		g.hasData = g.hasData or row.ver > 0
	end
	for _, g in ipairs(groups) do
		table.sort(g.rows, function(a, b)
			if a.online ~= b.online then return a.online end
			if a.level ~= b.level then return a.level > b.level end
			return a.name < b.name
		end)
		local first = table.remove(g.rows, 1)
		table.sort(g.rows, function(a, b) return a.name < b.name end)
		table.insert(g.rows, 1, first)
	end
	table.sort(groups, function(a, b)
		if a.hasData ~= b.hasData then return a.hasData end
		return a.rows[1].name < b.rows[1].name
	end)
	local out, players = {}, 0
	for _, g in ipairs(groups) do
		if g.hasData then players = players + 1 end
		for i, row in ipairs(g.rows) do
			row.alt = i > 1
			out[#out + 1] = row
		end
	end
	return out, players
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
				player = rec.player,
				name = Roster.NameOf(guid) or "?",
				class = (member and member.class) or rec.class,
				level = (member and member.level) or rec.level or 0,
				online = (member and member.online) or false,
				via = Index.Via(guid),
				isSelf = guid == UnitGUID("player"),
				isAlt = guid ~= UnitGUID("player") and (ns.db.account.chars[guid] ~= nil or ns.Link.IsPartner(guid)),
				linked = ns.Link.IsPartner(guid),
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
				guid = guid, name = member.name, class = member.class, level = member.level or 0,
				online = member.online or false, ver = 0,
				profs = "|cff808080" .. table.concat(names, ", ") .. " (" .. L.NO_ADDON_DATA .. ")|r",
			}
		end
	end
	local players
	rows, players = groupRows(rows)
	ui.header:SetText(L.MEMBERS_HEADER:format(players, shared, recipeTotal))
	ui.list:SetData(rows)
end

local function build(content)
	ui.header = W.Text(content, "GameFontNormal")
	ui.header:SetPoint("TOPLEFT", 6, -2)

	-- Right-click menu: account linking (Features/Link.lua). Returns the
	-- entries for a row: { {label, fn}, ... }.
	local function menuItems(data)
		local items = {}
		if ns.Link.TargetOf(data.guid) then
			if ns.Link.OfferPendingFor(data.guid) then
				items[#items + 1] = { L.LINK_MENU_CANCEL, ns.Link.CancelOffer }
			else
				items[#items + 1] = { L.LINK_MENU_OFFER, function() ns.Link.ConfirmOffer(data.guid) end }
			end
		end
		if (data.isSelf or data.isAlt) and ns.Link.IsLinked() then
			items[#items + 1] = { L.LINK_MENU_UNLINK, ns.Link.ConfirmUnlink }
		end
		return items
	end
	ui.menuItems = menuItems

	local function openMenu(owner, data)
		local items = menuItems(data)
		if #items == 0 or not (MenuUtil and MenuUtil.CreateContextMenu) then return end
		MenuUtil.CreateContextMenu(owner, function(_, root)
			root:CreateTitle(Util.ShortName(data.name))
			for _, item in ipairs(items) do
				root:CreateButton(item[1], item[2])
			end
		end)
	end

	-- Click hint, plus the member's addon version when known.
	local function hint(frame, text)
		frame:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(text(self), 1, 1, 1)
			local row = self.data and self or self:GetParent()
			local data = row.data
			if data and data.linked then
				GameTooltip:AddLine(L.LINKED_LICENSE, 0.4, 0.8, 1)
			end
			local version = ns.Versions.Describe(ns.Versions.Get(data and data.name))
			if version then
				GameTooltip:AddLine(L.VERSION_TOOLTIP:format(version), 0.6, 0.6, 0.6)
			end
			if data and #menuItems(data) > 0 then
				GameTooltip:AddLine(L.RIGHT_CLICK_OPTIONS, 0.6, 0.6, 0.6)
			end
			GameTooltip:Show()
		end)
		frame:SetScript("OnLeave", GameTooltip_Hide)
	end

	-- Two click areas: the name whispers (the character, or the same person's
	-- online character; never yourself or someone offline), the professions
	-- open the member's recipes in the Recipes tab.
	ui.list = W.CreateList(content, 20, function(row)
		row.nameButton = CreateFrame("Button", nil, row)
		row.nameButton:SetPoint("TOPLEFT")
		row.nameButton:SetPoint("BOTTOMLEFT")
		row.nameButton:SetWidth(248)
		row.nameButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.nameButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row.nameButton:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				openMenu(self, self:GetParent().data)
				return
			end
			local target = Index.ContactFor(self:GetParent().data)
			if target then
				W.SendTell(target)
			end
		end)
		hint(row.nameButton, function(self)
			local data = self:GetParent().data
			local target, reason = Index.ContactFor(data)
			if not target then return reason end
			return data.via and L.CLICK_WHISPER_VIA:format(Util.ShortName(data.via.name)) or L.CLICK_WHISPER
		end)
		row.name = W.Text(row.nameButton)
		row.name:SetWidth(150)
		row.age = W.Text(row.nameButton, "GameFontDisableSmall")
		row.age:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
		row.age:SetWidth(90)
		row.profs = W.Text(row)
		row.profs:SetPoint("LEFT", row.nameButton, "RIGHT", 4, 0)
		row.profs:SetPoint("RIGHT", -4, 0)
		row:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				openMenu(self, self.data)
				return
			end
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
		if data.linked then name = name .. " |cff66ccff~|r" end
		row.name:SetText(name)
		-- Other characters of the same person sit indented under the first one.
		row.name:ClearAllPoints()
		row.name:SetPoint("LEFT", data.alt and 18 or 4, 0)
		row.name:SetWidth(data.alt and 136 or 150)
		row.age:SetText(data.ver > 0 and L.CONFIRMED_AGO:format(Util.FormatAge(ns.Now() - data.ver)) or "")
		row.profs:SetText(data.profs)
	end)
	ui.list.box:SetPoint("TOPLEFT", 4, -24)
	ui.list.box:SetPoint("BOTTOMRIGHT", -18, 4)
end

ns.UI.RegisterTab("members", L.TAB_MEMBERS, build, refresh)
