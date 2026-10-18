--[[
Smoke test for the UI files: loads them into a simulated client with mock
frames, opens every tab, renders list rows and runs the tooltip hook. It does
not check layout (that needs the game), only that the code paths run.
]]
local H = ...
local test, eq, truthy, falsy = H.test, H.eq, H.truthy, H.falsy

-- Callable, indexable placeholder for any widget API we do not model.
local mockMeta = {}
local function mock()
	return setmetatable({}, mockMeta)
end
mockMeta.__index = function() return mock() end
mockMeta.__call = function() return mock() end

local function uiEnv(client)
	local env = client.env
	local frames = {}
	local tooltipHooks, unitHooks = {}, {}
	local lists = {}

	env.UIParent = mock()
	env.UISpecialFrames = {}
	env.tinsert = table.insert
	env.GameTooltip = mock()
	env.ItemRefTooltip = mock()
	env.GameTooltip_Hide = function() end
	env.ScrollBoxConstants = { RetainScrollPosition = 1 }
	env.CreateDataProvider = function(items) return items end
	env.CreateScrollBoxListLinearView = function()
		local view = mock()
		rawset(view, "SetElementInitializer", function(self, _, fn) rawset(self, "init", fn) end)
		return view
	end
	env.ScrollUtil = {
		InitScrollBoxListWithScrollBar = function(box, _, view) rawset(box, "view", view) end,
	}
	env.CreateFrame = function(frameType, name, _, template)
		local f = mock()
		if template == "WowScrollBoxList" then
			rawset(f, "SetDataProvider", function(self, items)
				rawset(self, "items", items)
				for _, item in ipairs(items) do
					local row = mock()
					rawget(self, "view").init(row, item)
				end
			end)
			table.insert(lists, f)
		elseif frameType == "DropdownButton" then
			rawset(f, "SetupMenu", function(self, gen)
				rawset(self, "gen", gen)
				local root = mock()
				rawset(root, "CreateRadio", function(_, _, isSelected) isSelected() end)
				rawset(root, "CreateCheckbox", function(_, _, isChecked) isChecked() end)
				gen(self, root)
			end)
		elseif template == "SearchBoxTemplate" then
			local text = ""
			rawset(f, "SetText", function(_, t) text = t end)
			rawset(f, "GetText", function() return text end)
			rawset(f, "HookScript", function(self, _, fn) rawset(self, "onTextChanged", fn) end)
			-- Recipes tab first, then the Members tab.
			env.searchBoxes = env.searchBoxes or {}
			env.searchBoxes[#env.searchBoxes + 1] = f
			env.searchBox = env.searchBox or f
		elseif frameType == "CheckButton" then
			rawset(f, "GetChecked", function() return false end)
		end
		rawset(f, "IsShown", function() return true end)
		rawset(f, "IsVisible", function() return true end)
		if name then env[name] = f end
		table.insert(frames, f)
		return f
	end
	env.TooltipDataProcessor = {
		AddTooltipPostCall = function(kind, fn)
			table.insert(kind == 2 and unitHooks or tooltipHooks, fn)
		end,
	}
	env.Enum.TooltipDataType = { Item = 0, Unit = 2 }
	env.C_Spell = { GetSpellName = function(id) return "Recipe " .. id end }
	env.C_Item = {
		GetItemInfo = function(id)
			if type(id) ~= "number" then return nil end
			-- Recipe items (class 9): known pattern, unknown pattern, class book.
			local recipes = { [9001] = { "Pattern: Recipe 3914", 2 }, [9002] = { "Pattern: Unknown Robe", 2 }, [9003] = { "Book: Frostbolt", 0 } }
			if recipes[id] then
				return recipes[id][1], "|Hitem:" .. id .. "|h[x]|h", 2, 25, 20, "Recipe", "Tailoring", 1, "", 1, 0, 9, recipes[id][2], 1
			end
			return "Item " .. id, "|Hitem:" .. id .. "|h[Item " .. id .. "]|h", 2, 25, 20, "Armor", "Cloth", 1,
				"INVTYPE_CHEST", 1, 0, 4, 1, 2
		end,
		GetItemStats = function() return { ITEM_MOD_INTELLECT_SHORT = 7 } end,
		GetItemIconByID = function() return 1 end,
		GetItemNameByID = function(id) return "Item " .. id end,
		RequestLoadItemDataByID = function() end,
		GetDetailedItemLevelInfo = function() return 25 end,
		GetItemCount = function() return 1 end,
	}
	env.GetInventoryItemLink = function() return nil end
	env.Minimap = setmetatable({
		GetWidth = function() return 140 end,
		GetHeight = function() return 140 end,
		GetCenter = function() return 500, 500 end,
		GetEffectiveScale = function() return 1 end,
	}, mockMeta)
	local registered = {}
	env.Settings = {
		RegisterVerticalLayoutCategory = function(name)
			return { name = name, GetID = function() return 42 end }
		end,
		RegisterAddOnSetting = function(_, variable, key, tbl, varType, name, default)
			local setting = { variable = variable, key = key, tbl = tbl, varType = varType, name = name, default = default }
			function setting:SetValueChangedCallback(fn) self.onChange = fn end
			table.insert(registered, setting)
			return setting
		end,
		CreateCheckbox = function() end,
		RegisterVerticalLayoutSubcategory = function(parent, name)
			registered.sub = { name = name, parent = parent }
			return registered.sub
		end,
		CreateSliderOptions = function(min, max, step) return { min = min, max = max, step = step } end,
		CreateSlider = function(_, setting, options) setting.slider = options end,
		RegisterAddOnCategory = function(category) registered.category = category end,
		OpenToCategory = function(id) registered.opened = id end,
	}
	env.ITEM_MOD_INTELLECT_SHORT = "Intellect"
	env.CHESTSLOT = "Chest"
	for _, file in ipairs({ "UI/Widgets.lua", "UI/Main.lua", "UI/SearchTab.lua", "UI/UpgradeTab.lua", "UI/WishlistTab.lua", "UI/MembersTab.lua", "UI/Tooltip.lua", "UI/Settings.lua", "UI/MinimapButton.lua" }) do
		local chunk = assert(loadfile(H.ADDON_DIR .. file, "t", env))
		chunk("GuildTradebook", client.ns)
	end
	return { lists = lists, tooltipHooks = tooltipHooks, unitHooks = unitHooks, settings = registered }
end

print("UI smoke")

test("tabs, rows and tooltip run against real pool data", function()
	math.randomseed(1)
	local world = H.NewWorld()
	local a = world:AddChar({ guid = "Player-1-00000001", name = "Anna",
		profs = { [197] = { rank = 150, maxRank = 300, name = "Tailoring", recipes = { [3914] = 2568, [3915] = 2569 } } } })
	local b = world:AddChar({ guid = "Player-1-00000002", name = "Bert" })
	world:Login(b.guid)
	local ca = world:Login(a.guid)
	world:Run(60)
	ca:OpenTradeSkill(197)
	world:Run(120)

	local cb = world.online[b.guid]
	local ui = uiEnv(cb)
	local UI = cb.ns.UI

	-- Recipe rows of the Recipes tab list (without group rows).
	local function recipeRows()
		local n = 0
		for _, item in ipairs(ui.lists[1].items) do
			if item.kind ~= "group" then n = n + 1 end
		end
		return n
	end
	UI.Show("search", "recipe")
	eq(recipeRows(), 2, "search found both recipes")
	eq(ui.lists[1].items[1].kind, "group", "under their profession")
	-- Reagents known (as after a FACT answer): rows render with tooltips.
	cb.env.GuildTradebookDB.recipeFacts[3914].reagents = { { 2589, 2, 0 }, { 2320, 1, 1 } }
	cb.ns.UI.ShowRecipe(3914)
	cb.ns.Wishlist.Toggle(3914)
	UI.Show("wishlist")
	cb.ns.Wishlist.SetPaused(3914, true) -- greyed row
	UI.Show("wishlist")
	cb.ns.Wishlist.SetPaused(3914, false)
	UI.Show("upgrades")
	UI.Show("members")
	UI.Toggle()
	UI.Toggle()

	local rendered = 0
	for _, list in ipairs(ui.lists) do
		rendered = rendered + #(rawget(list, "items") or {})
	end
	truthy(rendered >= 4, "rows rendered: " .. rendered)

	-- Copyable log window (twice: created once, then reused).
	cb.ns.Widgets.ShowText("log", "a |cffff0000red|r line")
	cb.ns.Widgets.ShowText("log", "again")
	truthy(cb.ns.Widgets.textFrame, "log window created")
	local registered = 0
	for _, name in ipairs(cb.env.UISpecialFrames) do
		if name == "GuildTradebookTextFrame" then registered = registered + 1 end
	end
	eq(registered, 1, "Esc closes it, registered once")

	cb.ns.Tooltip.Start()
	local lines = {}
	local tooltip = setmetatable({ AddLine = function(_, text) table.insert(lines, text) end }, mockMeta)
	cb.env.GameTooltip = tooltip
	for _, hook in ipairs(ui.tooltipHooks) do
		hook(tooltip, { id = 2568 })
	end
	truthy(lines[1] and lines[1]:find("Anna"), "tooltip names the crafter: " .. tostring(lines[1]))

	local function linesFor(itemID)
		lines = {}
		for _, hook in ipairs(ui.tooltipHooks) do hook(tooltip, { id = itemID }) end
		return lines
	end
	local known = linesFor(9001)
	truthy(known[1] and known[1]:find("Known in your guild by 1:", 1, true) and known[1]:find("Anna"), "known pattern: " .. tostring(known[1]))
	eq(linesFor(9002)[1], "Not known in your guild yet")
	eq(#linesFor(9003), 0, "class books are not profession recipes")
	cb.env.GuildTradebookDB.options.tooltipRecipes = false
	eq(#linesFor(9002), 0, "option off")
	cb.env.GuildTradebookDB.options.tooltipRecipes = true

	-- Player tooltips: a guild member's professions, primary first.
	local function unitLines(guid)
		lines = {}
		for _, hook in ipairs(ui.unitHooks) do hook(tooltip, { guid = guid }) end
		return lines
	end
	local anna = unitLines("Player-1-00000001")
	truthy(anna[1] and anna[1]:find(" 150/300", 1, true), "primary line with skill level: " .. tostring(anna[1]))
	eq(#anna, 1, "one profession, one line")
	-- Secondary professions only with their own option (default off).
	local bertRec = cb.ns.GetGuildData().chars["Player-1-00000002"]
	bertRec.profs[185] = { rank = 150, maxRank = 225 }
	eq(#unitLines("Player-1-00000002"), 0, "secondary only: nothing by default")
	cb.env.GuildTradebookDB.options.tooltipSecondary = true
	local withSecondary = unitLines("Player-1-00000002")
	eq(#withSecondary, 1)
	truthy(withSecondary[1]:find("150/225", 1, true))
	cb.env.GuildTradebookDB.options.tooltipSecondary = false
	bertRec.profs[185] = nil
	local P = cb.ns.Tooltip.ProfessionLines({ guid = "g", profs = {
		[165] = { rank = 225, maxRank = 300, primary = true },
		[202] = { rank = 180, maxRank = 300, primary = true },
		[185] = { rank = 150, maxRank = 225 },
		[129] = { rank = 225, maxRank = 225 },
	} }, function(_, sl) return sl == 202 end)
	eq(#P.primary, 1, "a primary the server contradicts is left out")
	truthy(P.primary[1]:find("225/300", 1, true))
	truthy(P.secondary:find(", ", 1, true), "secondary ones share a line")
	eq(#unitLines("Player-1-00000999"), 0, "not a guild member with data")
	eq(#unitLines(nil), 0)
	-- A "secret" GUID (the client hides it, e.g. world tooltips in combat):
	-- using it as a table key raises an error in the game; it is skipped.
	local SECRET = "Player-1-00000001-secret"
	cb.env.issecretvalue = function(v) return v == SECRET end
	local chars = cb.ns.GetGuildData().chars
	setmetatable(chars, { __index = function(_, k)
		if k == SECRET then error("attempted to index a table that cannot be indexed with secret keys") end
	end })
	eq(#unitLines(SECRET), 0, "secret GUID: no lines, no error")
	setmetatable(chars, nil)
	cb.env.issecretvalue = nil
	cb.env.GuildTradebookDB.options.tooltipProfessions = false
	eq(#unitLines("Player-1-00000001"), 0, "option off")
	cb.env.GuildTradebookDB.options.tooltipProfessions = true

	-- Settings panel: one checkbox per option, bound to the saved options.
	cb.ns.Settings.Register()
	local checks, sliders = {}, {}
	for _, s in ipairs(ui.settings) do
		table.insert(s.varType == "boolean" and checks or sliders, s)
	end
	eq(#checks, #cb.ns.Settings.CHECKBOXES)
	for _, s in ipairs(checks) do
		eq(s.tbl, cb.env.GuildTradebookDB.options, "bound to saved options")
		truthy(s.name and not s.name:find("^SETTINGS_"), "localized label for " .. s.key)
	end
	-- Sub-page with one weight slider per stat, per character, default 1.
	eq(ui.settings.sub.name, "Stat weights")
	eq(#sliders, #cb.ns.Upgrades.STATS)
	for _, s in ipairs(sliders) do
		eq(s.varType, "number")
		eq(s.tbl, cb.env.GuildTradebookCharDB.statWeights, "per character")
		eq(s.tbl[s.key], 1)
		eq(s.slider.max, 5)
	end
	eq(ui.settings.category.name, "Guild Tradebook")
	cb.ns.Settings.Open()
	eq(ui.settings.opened, 42, "fallback without C_SettingsUtil")
	-- With the game's own opener, Settings.OpenToCategory (taints) is not used.
	ui.settings.opened = nil
	local panel
	cb.env.C_SettingsUtil = { OpenSettingsPanel = function(id) panel = id end }
	cb.ns.Settings.Open()
	eq(panel, 42)
	eq(ui.settings.opened, nil, "OpenToCategory not called")
	cb.env.C_SettingsUtil = nil

	-- Item rows: game tooltip on hover (price addons hook it), shift-click links.
	local scripts, shown, linked = {}, {}, {}
	local fake = { itemID = 2589, SetScript = function(_, name, fn) scripts[name] = fn end }
	cb.env.GameTooltip = setmetatable({ SetItemByID = function(_, id) shown[#shown + 1] = id end }, mockMeta)
	cb.env.IsModifiedClick = function(what) return what == "CHATLINK" end
	cb.env.ChatFrameUtil = { InsertLink = function(link) linked[#linked + 1] = link end }
	cb.ns.Widgets.AttachItem(fake)
	scripts.OnEnter(fake)
	scripts.OnClick(fake)
	eq(shown[1], 2589, "tooltip shows the reagent item")
	truthy(linked[1] and linked[1]:find("item:2589", 1, true), "shift-click links the item")

	-- Reagent that a guild member crafts: hint in the tooltip, click opens its recipe.
	local opened, hints = {}, {}
	cb.env.IsModifiedClick = function() return false end
	cb.env.GameTooltip = setmetatable({ AddLine = function(_, text) hints[#hints + 1] = text end }, mockMeta)
	local craftable = { itemID = 2568, SetScript = function(_, name, fn) scripts[name] = fn end }
	cb.ns.Widgets.AttachItem(craftable, function(rid) opened[#opened + 1] = rid end)
	scripts.OnEnter(craftable)
	scripts.OnClick(craftable)
	eq(hints[1], "Click: open the guild recipe")
	eq(opened[1], 3914, "click opens the recipe that crafts the item")

	-- Opening a recipe keeps the search; the clear button resets the filter.
	UI.Show("search", "recipe 3914")
	eq(recipeRows(), 1, "search filters")
	cb.ns.UI.ShowRecipe(3915, true)
	eq(cb.env.searchBox:GetText(), "recipe 3914", "jump does not overwrite the search")
	cb.env.searchBox:SetText("")
	cb.env.searchBox.onTextChanged(cb.env.searchBox, false) -- clear button: not user input
	world:Run(1)
	eq(recipeRows(), 2, "cleared search shows everything again")

	-- Groups: profession > category > recipes; "Other" for recipes without
	-- a named category, last; nothing but "Other": recipes follow directly.
	local RL = cb.ns.RecipeList
	local all = cb.ns.Index.Search("", 0)
	local function shape(rows)
		local out = {}
		for _, r in ipairs(rows) do out[#out + 1] = r.kind == "group" and (r.label .. "/" .. r.count) or tostring(r.recipeID) end
		return table.concat(out, ",")
	end
	local always = function() return true end
	eq(shape(RL.Rows(all, true, always)), "#197/2,3914,3915", "no categories yet")
	local dbB = cb.env.GuildTradebookDB
	dbB.recipeFacts[3915].cat = 10
	dbB.recipeFacts[3914].cat = 11
	eq(shape(RL.Rows(all, true, always)), "#197/2,3914,3915", "categories without names: like none")
	dbB.categories[10] = { order = 1, names = { deDE = "Umhänge" } }
	eq(shape(RL.Rows(all, true, always)), "#197/2,Umhänge/1,3915,Other/1,3914", "Other last")
	dbB.categories[11] = { order = 2, names = { enUS = "Cloaks" } }
	eq(shape(RL.Rows(all, true, always)), "#197/2,Umhänge/1,3915,Cloaks/1,3914", "by the game's order")
	eq(shape(RL.Rows(all, false, always)), "Umhänge/1,3915,Cloaks/1,3914", "one profession: categories only")
	eq(shape(RL.Rows(all, true, function(key) return key == "p:197" end)), "#197/2,Umhänge/1,Cloaks/1", "closed categories")
	eq(shape(RL.Rows(all, true, function() return false end)), "#197/2", "closed profession")
	-- A jump to a recipe opens its groups.
	cb.ns.UI.ShowRecipe(3914)
	truthy(RL.Open()["c:197:11"] and RL.Open()["p:197"], "groups of the opened recipe")
	eq(cb.env.GuildTradebookCharDB.recipes.open["c:197:11"], true, "remembered per character")
	UI.Show("search")
	dbB.recipeFacts[3915].cat, dbB.recipeFacts[3914].cat = nil, nil
	dbB.categories[10], dbB.categories[11] = nil, nil
	-- Profession window order: greys last first, unknown ones after, by
	-- name; search results stay by name.
	dbB.recipeFacts[3915].trivial = 75
	eq(shape(RL.Rows(all, true, always, true)), "#197/2,3915,3914", "known grey skill before unknown")
	dbB.recipeFacts[3914].trivial = 90
	eq(shape(RL.Rows(all, true, always, true)), "#197/2,3914,3915", "highest first")
	dbB.recipeFacts[3914].trivial = 60
	eq(shape(RL.Rows(all, true, always, true)), "#197/2,3915,3914")
	eq(shape(RL.Rows(all, true, always)), "#197/2,3914,3915", "searching: by name")
	dbB.recipeFacts[3915].trivial, dbB.recipeFacts[3914].trivial = nil, nil

	-- Members tab -> Recipes tab filtered to one member.
	cb.env.searchBox:SetText("recipe 3914")
	cb.env.searchBox.onTextChanged(cb.env.searchBox)
	world:Run(1)
	cb.ns.UI.ShowCrafter(a.guid)
	eq(recipeRows(), 2, "all of Anna's recipes, search cleared")
	eq(cb.env.searchBox:GetText(), "")
	cb.ns.UI.ShowCrafter(b.guid)
	eq(recipeRows(), 0, "Bert knows no recipes")
	-- From the profession view: filtered to that profession.
	cb.ns.UI.ShowCrafter(a.guid, 197)
	eq(recipeRows(), 2, "Anna's tailoring recipes")
	cb.ns.UI.ShowCrafter(a.guid, 171)
	eq(recipeRows(), 0, "no alchemy")
	cb.ns.UI.ShowCrafter(a.guid)

	-- Members tab views: players, professions, cooldowns.
	local MV = cb.ns.MembersView
	local function kinds(rows)
		local out = {}
		for _, r in ipairs(rows) do out[#out + 1] = r.kind end
		return table.concat(out, ",")
	end
	local playersRows = MV.Rows("players", false, {})
	truthy(#playersRows >= 2 and playersRows[1].kind == "member", "players view: " .. kinds(playersRows))
	local profRows = MV.Rows("professions", false, {})
	eq(kinds(profRows), "group", "one profession, closed")
	eq(profRows[1].key, "p:197")
	eq(profRows[1].summary, "1 members, highest 150")
	profRows = MV.Rows("professions", false, { ["p:197"] = true })
	eq(kinds(profRows), "group,entry")
	eq(profRows[2].guid, a.guid)
	eq(profRows[2].right, "150/300")
	eq(profRows[2].skillLine, 197)
	-- Offline and not online elsewhere: hidden by the filter.
	local annaMember = cb.ns.Roster.members[a.guid]
	annaMember.online = false
	eq(#MV.Rows("professions", true, { ["p:197"] = true }), 0, "only reachable: Anna is offline")
	annaMember.online = true
	eq(#MV.Rows("professions", true, { ["p:197"] = true }), 2)

	local cdRows = MV.Rows("cooldowns", false, {})
	eq(kinds(cdRows), "info", "no cooldowns known yet")
	local gdB = cb.ns.GetGuildData()
	local now = cb.ns.Now()
	gdB.chars[a.guid].profs[197].cds = { [3914] = now - 10 }
	gdB.chars[b.guid].profs[197] = { rank = 100, maxRank = 150, primary = true, recipes = {}, cds = { [3914] = now + 3600, [3915] = now + 7200 } }
	cdRows = MV.Rows("cooldowns", false, { ["c:3914"] = true })
	eq(kinds(cdRows), "group,entry,entry,group")
	eq(cdRows[1].key, "c:3914", "the cooldown with someone ready comes first")
	truthy(cdRows[1].summary:find("Anna", 1, true) and cdRows[1].summary:find("next: Bert in 1h", 1, true), cdRows[1].summary)
	eq(cdRows[2].guid, a.guid, "ready first")
	eq(cdRows[2].recipeID, 3914)
	truthy(cdRows[3].isSelf, "you are listed too")
	truthy(cdRows[4].summary:find("none ready", 1, true), cdRows[4].summary)
	-- A time the owner does not share: "not shared", never ready, never "next".
	gdB.chars[b.guid].profs[197].cds[3915] = cb.ns.Store.CD_HIDDEN
	cdRows = MV.Rows("cooldowns", false, { ["c:3915"] = true })
	local hiddenGroup = cdRows[#cdRows - 1]
	eq(hiddenGroup.key, "c:3915")
	falsy(hiddenGroup.summary:find("next", 1, true), hiddenGroup.summary)
	truthy(cdRows[#cdRows].right:find("not shared", 1, true), cdRows[#cdRows].right)

	-- Search: names and profession names; stats stay guild totals.
	local _, statsText = MV.Rows("players", false, {}, "anna")
	local rows = MV.Rows("players", false, {}, " ANNA ")
	eq(#rows, 1, "only Anna")
	eq(rows[1].guid, a.guid)
	eq(statsText, select(2, MV.Rows("players", false, {})), "stats are not filtered")
	eq(MV.Rows("players", false, {}, "#197")[1].kind, "member", "profession name matches")
	eq(MV.Rows("players", false, {}, "nobody here")[1].kind, "info", "no match")
	-- Groups: a matching label keeps the group as it is (closed); a name
	-- match shows only that character, opened.
	eq(kinds(MV.Rows("professions", false, {}, "#197")), "group")
	rows = MV.Rows("cooldowns", false, {}, "bert")
	eq(kinds(rows), "group,entry,group,entry", "Bert's cooldowns, opened")
	eq(rows[2].guid, b.guid)
	local membersBox = cb.env.searchBoxes[2]
	membersBox:SetText("bert")
	membersBox.onTextChanged(membersBox)
	world:Run(1)
	membersBox:SetText("")
	membersBox.onTextChanged(membersBox)
	world:Run(1)

	-- Every view renders, groups open and closed; the choice is remembered.
	for _, view in ipairs(MV.VIEWS) do
		MV.Settings().view = view
		MV.Settings().open = { ["p:197"] = true, ["c:3914"] = true }
		UI.Show("members")
	end
	MV.Toggle("c:3914")
	eq(MV.Settings().open["c:3914"], nil, "toggled closed")
	eq(cb.env.GuildTradebookCharDB.members.view, "cooldowns", "per character")
	gdB.chars[a.guid].profs[197].cds = nil
	gdB.chars[b.guid].profs[197] = nil
	MV.Settings().view = "players"

	-- Back history: reagent jumps stack up, a jump from another tab starts over.
	cb.ns.UI.ShowRecipe(3915)
	cb.ns.UI.ShowRecipe(3914, true)
	eq(cb.ns.UI.RecipeHistoryDepth(), 1)
	cb.ns.UI.ShowRecipe(3915)
	eq(cb.ns.UI.RecipeHistoryDepth(), 0)

	-- Tooltip summary: names for few crafters, count + online names for many.
	local Tooltip = cb.ns.Tooltip
	local function crafters(n, online)
		local list = {}
		for i = 1, n do list[i] = { name = "M" .. i .. "-Realm", online = i <= online, reachable = i <= online } end
		return list
	end
	eq(Tooltip.CrafterText(crafters(2, 1)), "M1|cff20ff20*|r, M2")
	eq(Tooltip.CrafterText(crafters(23, 5)), "online: M1, M2, M3 +2")
	eq(Tooltip.CrafterText(crafters(23, 0)), "none online")
	-- Offline alt whose owner is online on another character counts as online.
	local viaAlt = { name = "Alty-Realm", online = false, reachable = true, via = { name = "Mainy-Realm" } }
	eq(Tooltip.CrafterText({ viaAlt }), "Alty (Mainy|cff20ff20*|r)")
	local many = crafters(23, 0)
	many[6] = viaAlt
	eq(Tooltip.CrafterText(many), "online: Alty (Mainy)")

	-- One entry per person: you and your alt, or an online character and its
	-- offline alt, are one crafter.
	local function who(list)
		local names = {}
		for _, c in ipairs(list) do names[#names + 1] = c.guid end
		return table.concat(names, ",")
	end
	local owner = { me = "P1", alt = "P1", bobby = "P2", bob = "P2", cleo = "P3" }
	local function playerOf(guid) return owner[guid] or guid end
	local pool = {
		{ guid = "alt", online = false },
		{ guid = "me", isSelf = true, online = true },
		{ guid = "bob", online = true },
		{ guid = "bobby", online = false, reachable = true, via = {} },
		{ guid = "cleo", online = false },
		{ guid = "solo", online = false },
	}
	eq(who(Tooltip.OnePerPlayer(pool, playerOf)), "me,bob,cleo,solo", "you instead of your alt; the online one instead of its alt")
	eq(who(Tooltip.OnePerPlayer({ pool[4], pool[3] }, playerOf)), "bob", "online before reachable through another")
	eq(who(Tooltip.OnePerPlayer({ { guid = "alt" }, { guid = "me", online = false } }, playerOf)), "alt", "equal: the first one")

	-- Minimap button (LibDataBroker + LibDBIcon + LibCustomGlow, like Gargul).
	local calls = { shown = nil, glowStarted = 0, glowStopped = 0 }
	local fakeButton = {}
	local stubs = {
		["LibDataBroker-1.1"] = { NewDataObject = function(_, name, obj) calls.object = obj return obj end },
		["LibDBIcon-1.0"] = {
			Register = function(_, name, obj, db) calls.registered, calls.db = name, db end,
			Show = function() calls.shown = true end,
			Hide = function() calls.shown = false end,
			GetMinimapButton = function() return fakeButton end,
		},
		["LibCustomGlowGargul-1.0"] = {
			ButtonGlow_Start = function(b) if b == fakeButton then calls.glowStarted = calls.glowStarted + 1 end end,
			ButtonGlow_Stop = function(b) if b == fakeButton then calls.glowStopped = calls.glowStopped + 1 end end,
		},
	}
	-- The stubbed names must be the ones the embedded copies register.
	for name, file in pairs({
		["LibDataBroker-1.1"] = "LibDataBroker-1.1/LibDataBroker-1.1.lua",
		["LibDBIcon-1.0"] = "LibDBIcon-1.0/LibDBIcon-1.0.lua",
		["LibCustomGlowGargul-1.0"] = "LibCustomGlow-1.0/LibCustomGlow-1.0.lua",
	}) do
		local f = assert(io.open(H.ADDON_DIR .. "Libs/" .. file, "rb"))
		local src = f:read("*a")
		f:close()
		truthy(src:find('"' .. name:gsub("%p", "%%%0") .. '"'), name .. " is registered by " .. file)
	end
	cb.env.LibStub = function(name) return stubs[name] end
	local MB = cb.ns.MinimapButton
	MB.Start()
	eq(calls.registered, "GuildTradebook", "registered with LibDBIcon under the addon name")
	eq(calls.shown, true, "shown (option on by default)")
	eq(calls.db, cb.env.GuildTradebookDB.minimap, "position saved in our DB")

	cb.ns.Wishlist.Toggle(3915) -- crafted by Anna, who is online; Bert is viewing
	MB.Update()
	truthy(MB.glowing, "glows: a wished recipe has an online crafter")
	truthy(calls.glowStarted > 0, "LibCustomGlow glow started")
	local opened
	local show = cb.ns.UI.Show
	cb.ns.UI.Show = function(tab) opened = tab end
	calls.object.OnClick(nil, "LeftButton")
	cb.ns.UI.Show = show
	eq(opened, "wishlist", "click while glowing opens the wishlist")
	local lines = {}
	calls.object.OnTooltipShow({ AddLine = function(_, t) lines[#lines + 1] = t end,
		AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. " = " .. r end })
	truthy(table.concat(lines, "|"):find("Recipe 3915 = ", 1, true), "tooltip lists the wished recipe and who is online")
	-- Opening the Wishlist tab: seen, the glow stops; the tooltip still lists it.
	cb.ns.UI.Show("wishlist")
	eq(MB.glowing, false, "seen in the Wishlist tab: no glow")
	lines = {}
	calls.object.OnTooltipShow({ AddLine = function(_, t) lines[#lines + 1] = t end,
		AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. " = " .. r end })
	truthy(table.concat(lines, "|"):find("Recipe 3915 = ", 1, true), "still in the tooltip")
	eq(MB.glowing, false, "the tooltip does not turn it back on")

	cb.ns.Wishlist.Toggle(3914)
	cb.ns.Wishlist.Toggle(3915)
	MB.Update()
	eq(MB.glowing, false, "no wishes, no glow")
	truthy(calls.glowStopped > 0, "glow stopped")

	for _, s in ipairs(ui.settings) do
		if s.key == "minimapButton" then s.onChange(s, false) end
	end
	eq(calls.shown, false, "settings checkbox hides the button at once")
	eq(cb.env.GuildTradebookDB.minimap.hide, true)

	-- Whispers use the plain name for your own realm.
	local told = {}
	cb.env.ChatFrameUtil = { SendTell = function(name) table.insert(told, name) end }
	cb.ns.Widgets.SendTell("Anna-Realm")
	cb.ns.Widgets.SendTell("Otto-OtherRealm")
	eq(told[1], "Anna")
	eq(told[2], "Otto-OtherRealm")
end)
