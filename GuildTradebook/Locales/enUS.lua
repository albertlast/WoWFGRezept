local _, ns = ...

-- Missing keys fall back to the key itself, so English strings double as keys.
ns.L = setmetatable({}, { __index = function(_, k) return k end })
local L = ns.L

L.TITLE = "Guild Tradebook"
L.TAB_SEARCH = "Recipes"
L.TAB_UPGRADES = "Upgrades"
L.TAB_MEMBERS = "Members"

L.SEARCH_HINT = "Search recipe or item"
L.ALL_PROFESSIONS = "All professions"
L.NO_RESULTS = "No results."
L.NOT_IN_GUILD = "You are not in a guild."
L.CRAFTERS = "Crafters"
L.REAGENTS = "Reagents"
L.REAGENTS_LOADING = "Loading reagents..."
L.REAGENTS_UNKNOWN = "Reagents unknown."
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
L.TOOLTIP_KNOWN = "Known by guild:"
L.TOOLTIP_MORE = "(+%d more)"

L.REMIND_SCAN = "Open your %s window once so your recipes can be shared with the guild."

L.SLASH_HELP = [[/gtb - open window
/gtb search <text> - search recipes
/gtb main <name> - link this character to your main
/gtb main - clear main link
/gtb resync - ask the guild for a full sync
/gtb tooltip - toggle tooltip lines
/gtb debug - toggle debug output
/gtb dump <name> - print what is known about a character
/gtb stats - print pool statistics]]
