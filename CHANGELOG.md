# Changelog

## 0.2.0 (in development)

- `!craft` in mixed-language guilds: item names are searched in each client's own language. Clients that find something answer first (in the order of clients with the same language); "nobody" is only answered once no client found anything, and names the language that was searched. A whispered question that finds nothing suggests asking in guild chat.
- `!craft` understands linked items and recipes (up to three per question): looked up by ID, so they work in every client language. A client that calls the item by the linked name (the asker's language) answers first; otherwise one client of another language answers after a short wait. The answer uses the linked name.
- Minimap button glow works on Forever: it was never shown (the embedded glow library was looked up by the wrong name, and the Forever client lacks a function its animation uses).
- Wishlist notice and minimap glow react within seconds: guild members logging in or out are taken from the "has come online" / "has gone offline" messages instead of waiting for the next roster refresh (up to two minutes), and the notice also follows synced data (it could lag the glow).
- Wishlist sound plays on the master channel, also for the summary after login; a sound that does not play is logged.
- Members who went offline while the guild roster still shows them online: one failed whisper marks them offline for 10 minutes (or until the roster shows a relog), the sync moves on to the next partner at once instead of waiting 10 seconds, and further whispers to them are skipped. A message from a member counts as proof they are online. Elections keep using the online state every client sees alike.
- Data of guilds none of your characters has been seen in for 60 days is removed (your own characters' records stay).
- Link two WoW licenses of one person: right-click a character in the Members tab ("Link with my account…"), confirm on the other license. The guild then sees one player (0.1.0 clients too); either side can unlink alone. A declined offer is not asked again. A linked character that leaves the guild drops out of the group; coming back, it is linked again. `/gtb link [name]`, `/gtb unlink`.
- Setting "Share my cooldowns" (default on): off, guild members still see that you have a cooldown recipe, but never as ready ("not shared"; 0.1.0 clients see a time far in the future). Turned on again, the real times return with the next look at the profession window.
- Members tab views: Players (as before), Professions (collapsible groups by profession, members by skill level) and Cooldowns (collapsible groups by cooldown recipe, ready crafters first, next one with time), plus an "Only reachable now" filter; remembered per character. A search box finds characters by name or profession in every view; the stats line above the list is shorter.
- Player tooltips show a guild member's professions and skill levels (one line per primary profession). Can be turned off in the settings ("Professions on player tooltips"); secondary professions are a separate setting, off by default.
- Records carry the owner's client language (not part of the content hash, so 0.1.0 clients stay compatible).

## 0.1.0 (2026-10-09)

First release for the guild.

**Sharing**
- Recipes of every profession with a crafting window (primary and secondary) are shared automatically inside the guild, including the recipes of offline members, relayed by others.
- Each crafter opens the professions window once and clicks each profession tab; new recipes are picked up when learned.
- Cooldowns (transmutes, Mooncloth, …) are shared too: crafter lists show who is ready.
- Characters of one account are grouped automatically. An offline crafter whose player is online on another character is shown as "online as …", and whispers go to the online character.

**Finding**
- Recipes tab: search by name, filter by profession or crafter, reagents with what you own and what is missing, crafters with online state.
- Upgrades tab: craftable items that beat your equipped gear in your favorite stats.
- Wishlist with a notice and a glowing minimap button when someone who can craft it comes online.
- Tooltips: "Craftable by guild" on items, "Known in your guild by …" on recipes and patterns.
- `!craft <item>` for members without the addon, asked in guild chat or by whisper; exactly one addon user answers, by whisper.

**Tools**
- `/gtb versions` shows which version each guild member runs; outdated builds are named.
- `/gtb diag` tests whether addon messages reach the guild; `/gtb log` shows a copyable log.

**Forever specifics**
- Character names with a surname ("First Last") are handled everywhere; whispers go to the name without the own realm.
