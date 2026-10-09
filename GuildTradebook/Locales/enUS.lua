local _, ns = ...

-- Missing keys fall back to the key itself, so English strings double as keys.
ns.L = setmetatable({}, { __index = function(_, k) return k end })
local L = ns.L

L.TITLE = "Guild Tradebook"
L.TAB_SEARCH = "Recipes"
L.TAB_UPGRADES = "Upgrades"
L.TAB_MEMBERS = "Members"
L.TAB_WISHLIST = "Wishlist"

L.SEARCH_HINT = "Search recipe or item"
L.ALL_PROFESSIONS = "All professions"
L.NO_RESULTS = "No results."
L.NOT_IN_GUILD = "You are not in a guild."
L.CRAFTERS = "Crafters"
L.REAGENTS = "Reagents"
L.REAGENTS_LOADING = "Loading reagents..."
L.REAGENTS_UNKNOWN = "Reagents unknown."
L.REAGENTS_FOR = "Reagents for %d craft(s) - have/need:"

L.CD_READY = "ready"
L.CD_REMAINING = "cooldown %s"

L.WISH_ADD = "Add to wishlist"
L.WISH_REMOVE = "Remove from wishlist"
L.WISH_EMPTY = "Your wishlist is empty. Add recipes in the Recipes tab or right-click an upgrade."
L.WISH_HINT = "Click: open recipe - right-click: remove. You get a notice when a crafter comes online."
L.WISH_NO_CRAFTER = "nobody can craft this right now"
L.WISH_ALERT = "%s is online and can craft: %s"
L.WISH_SUMMARY = "Wishlist: %d item(s) can be crafted by guild members online now (/gtb wishlist)."
L.UPGRADE_HINT = "Click: open recipe - right-click: wishlist"

L.CHAT_PREFIX = "[Guild Tradebook]"
L.CHAT_NONE = "[Guild Tradebook] Nobody in the guild can craft \"%s\"."
L.CHAT_MANY = "[Guild Tradebook] %d matches for \"%s\" (%s, ...) - please be more specific."
L.CHAT_ONLINE_HINT = "(* = online)"
L.OPTIONAL = "optional"
L.WHISPER = "Whisper"
L.ONLINE = "online"
L.YOU = "you"
L.ALT = "alt"
L.UNVERIFIED = "unverified"
L.NOT_SCANNED = "not scanned yet"
L.CONFIRMED_AGO = "confirmed %s ago"
L.RANK = "Rank %d/%d"

L.ITEM_TYPE = "Item type"
L.SLOT = "Slot"
L.FAV_STATS = "Favorite stats"
L.ANY = "Any"
L.ALL_SLOTS = "All slots"
L.WEAPON_ANY = "Weapon (any)"
L.MISC_ARMOR = "Miscellaneous (rings, neck, trinkets)"
L.SHOW_BOP = "Show bind-on-pickup"
L.SHOW_ALL = "Show non-upgrades"
L.LEVEL_AHEAD = "Include items up to +%d levels"
L.EQUIPPED_EMPTY = "slot empty"
L.PENDING_ITEMS = "Loading %d item(s)..."
L.BOP_WARNING = "Bind on pickup: the crafter cannot trade it to you."
L.NO_FAV_STATS = "Select at least one favorite stat."

L.MEMBERS_HEADER = "%d members share recipes (%d recipes)"

L.TOOLTIP_CRAFTABLE = "Craftable by guild:"
L.TOOLTIP_KNOWN_BY = "Known in your guild by %d:"
L.TOOLTIP_NOT_KNOWN = "Not known in your guild yet"
L.TOOLTIP_MEMBERS = "%d members"
L.TOOLTIP_ONLINE = "online: %s"
L.TOOLTIP_NONE_ONLINE = "none online"
L.CLICK_OPEN_RECIPE = "Click: open the guild recipe"
L.BACK = "Back"
L.FILTER_CRAFTER = "Crafter: %s"
L.CLICK_WHISPER = "Click: whisper"
L.CLICK_SHOW_RECIPES = "Click: show this member's recipes"
L.NO_ADDON_DATA = "no addon data"
L.TOOLTIP_MORE = "(+%d more)"

L.REMIND_SCAN = "Open the professions window and click the %s tab once so your recipes can be shared with the guild."

L.SETTINGS_HIDE_BOP = "Hide bind-on-pickup items others craft"
L.SETTINGS_HIDE_BOP_DESC = "Recipe list: hides recipes whose item binds on pickup when this character cannot craft it itself - such items can never be handed to you, not even from your alts."
L.SETTINGS_TOOLTIP = "Crafters on item tooltips"
L.SETTINGS_TOOLTIP_DESC = "Adds \"Craftable by guild: ...\" to items guild members can craft."
L.SETTINGS_TOOLTIP_RECIPES = "Guild knowledge on recipe items"
L.SETTINGS_TOOLTIP_RECIPES_DESC = "On patterns, recipes, formulas and plans: who in your guild already knows it, or \"Not known in your guild yet\"."
L.SETTINGS_CHAT = "Answer !craft in guild chat"
L.SETTINGS_CHAT_DESC = "Lets members without the addon ask \"!craft <item>\". Only one addon user answers each question."
L.SETTINGS_WISH_ALERTS = "Wishlist notices"
L.SETTINGS_WISH_ALERTS_DESC = "Tells you in chat when a guild member who can craft something on your wishlist comes online."
L.SETTINGS_WISH_SOUND = "Wishlist sound"
L.SETTINGS_WISH_SOUND_DESC = "Plays a sound with the wishlist notice."
L.SETTINGS_DEBUG = "Debug output"
L.SETTINGS_DEBUG_DESC = "Prints sync messages to chat (for testing)."
L.SETTINGS_MINIMAP = "Show minimap button"
L.SETTINGS_MINIMAP_DESC = "The button glows while a guild member who can craft something on your wishlist is online."
L.MINIMAP_WISH_READY = "Online now for your wishlist:"
L.MINIMAP_HINT = "Left-click: open (the Wishlist while glowing) - right-click: settings - drag: move"

L.SLASH_HELP = [[/gtb - open window
/gtb options - open the settings
/gtb minimap - show/hide the minimap button
/gtb search <text> - search recipes
/gtb main <name> - link this character to your main
/gtb main - clear main link
/gtb wishlist - open your wishlist
/gtb chatbot - toggle answering "!craft <item>" in guild chat
/gtb resync - ask the guild for a full sync
/gtb tooltip - toggle tooltip lines
/gtb debug - toggle debug output
/gtb dump <name> - print what is known about a character
/gtb stats - print pool statistics]]
