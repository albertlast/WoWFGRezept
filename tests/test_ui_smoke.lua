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
			return "Item " .. id, "|Hitem:" .. id .. "|h[Item " .. id .. "]|h", 2, 25, 20, "Armor", "Cloth", 1,
				"INVTYPE_CHEST", 1, 0, 4, 1, 2
		end,
		GetItemStats = function() return { ITEM_MOD_INTELLECT_SHORT = 7 } end,
		GetItemIconByID = function() return 1 end,
		GetItemNameByID = function(id) return "Item " .. id end,
		RequestLoadItemDataByID = function() end,
		GetDetailedItemLevelInfo = function() return 25 end,
	}
	env.GetInventoryItemLink = function() return nil end
	env.ITEM_MOD_INTELLECT_SHORT = "Intellect"
	env.CHESTSLOT = "Chest"
	client.ns.charDB = {}
	for _, file in ipairs({ "UI/Widgets.lua", "UI/Main.lua", "UI/SearchTab.lua", "UI/UpgradeTab.lua", "UI/MembersTab.lua", "UI/Tooltip.lua" }) do
		local chunk = assert(loadfile(H.ADDON_DIR .. file, "t", env))
		chunk("GuildTradebook", client.ns)
	end
	return { lists = lists, tooltipHooks = tooltipHooks }
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
	cb.ns.UI.ShowRecipe(3914)
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
end)
