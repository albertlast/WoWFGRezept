--[[
Smoke test for the UI files: loads them into a simulated client with mock
frames, opens every tab, renders list rows and runs the tooltip hook. It does
not check layout (that needs the game), only that the code paths run.
]]
local H = ...
local test, eq, truthy = H.test, H.eq, H.truthy

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
	local tooltipHooks = {}
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
			env.searchBox = f
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
		AddTooltipPostCall = function(_, fn) table.insert(tooltipHooks, fn) end,
	}
	env.Enum.TooltipDataType = { Item = 0 }
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
		RegisterAddOnCategory = function(category) registered.category = category end,
		OpenToCategory = function(id) registered.opened = id end,
	}
	env.ITEM_MOD_INTELLECT_SHORT = "Intellect"
	env.CHESTSLOT = "Chest"
	for _, file in ipairs({ "UI/Widgets.lua", "UI/Main.lua", "UI/SearchTab.lua", "UI/UpgradeTab.lua", "UI/WishlistTab.lua", "UI/MembersTab.lua", "UI/Tooltip.lua", "UI/Settings.lua", "UI/MinimapButton.lua" }) do
		local chunk = assert(loadfile(H.ADDON_DIR .. file, "t", env))
		chunk("GuildTradebook", client.ns)
	end
	return { lists = lists, tooltipHooks = tooltipHooks, settings = registered }
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

	UI.Show("search", "recipe")
	local results = ui.lists[1].items
	eq(#results, 2, "search found both recipes")
	-- Reagents known (as after a FACT answer): rows render with tooltips.
	cb.env.GuildTradebookDB.recipeFacts[3914].reagents = { { 2589, 2, 0 }, { 2320, 1, 1 } }
	cb.ns.UI.ShowRecipe(3914)
	cb.ns.Wishlist.Toggle(3914)
	UI.Show("wishlist")
	UI.Show("upgrades")
	UI.Show("members")
	UI.Toggle()
	UI.Toggle()

	local rendered = 0
	for _, list in ipairs(ui.lists) do
		rendered = rendered + #(rawget(list, "items") or {})
	end
	truthy(rendered >= 4, "rows rendered: " .. rendered)

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

	-- Settings panel: one checkbox per option, bound to the saved options.
	cb.ns.Settings.Register()
	eq(#ui.settings, #cb.ns.Settings.CHECKBOXES)
	for _, s in ipairs(ui.settings) do
		eq(s.tbl, cb.env.GuildTradebookDB.options, "bound to saved options")
		eq(s.varType, "boolean")
		truthy(s.name and not s.name:find("^SETTINGS_"), "localized label for " .. s.key)
	end
	eq(ui.settings.category.name, "Guild Tradebook")
	cb.ns.Settings.Open()
	eq(ui.settings.opened, 42)

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
	eq(#ui.lists[1].items, 1, "search filters")
	cb.ns.UI.ShowRecipe(3915, true)
	eq(cb.env.searchBox:GetText(), "recipe 3914", "jump does not overwrite the search")
	cb.env.searchBox:SetText("")
	cb.env.searchBox.onTextChanged(cb.env.searchBox, false) -- clear button: not user input
	world:Run(1)
	eq(#ui.lists[1].items, 2, "cleared search shows everything again")

	-- Members tab -> Recipes tab filtered to one member.
	cb.env.searchBox:SetText("recipe 3914")
	cb.env.searchBox.onTextChanged(cb.env.searchBox)
	world:Run(1)
	cb.ns.UI.ShowCrafter(a.guid)
	eq(#ui.lists[1].items, 2, "all of Anna's recipes, search cleared")
	eq(cb.env.searchBox:GetText(), "")
	cb.ns.UI.ShowCrafter(b.guid)
	eq(#ui.lists[1].items, 0, "Bert knows no recipes")

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
		["LibCustomGlow-1.0"] = {
			ButtonGlow_Start = function(b) if b == fakeButton then calls.glowStarted = calls.glowStarted + 1 end end,
			ButtonGlow_Stop = function(b) if b == fakeButton then calls.glowStopped = calls.glowStopped + 1 end end,
		},
	}
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
