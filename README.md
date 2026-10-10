# Guild Tradebook

Guild recipe sharing for **World of Warcraft: Forever** (interface 16001).

Every guild member running the addon shares their recipes automatically, and members relay the recipes of others. You can search all guild recipes, even when the crafter is offline. You can also find **gear upgrades** that guild members can craft for you.

## Install

Copy (or link) the `GuildTradebook` folder into the game's `Interface/AddOns/` folder. During the beta, Forever installs as `World of Warcraft/_classic_beta_/` (product `wow_classic_beta`, build 1.60.x); the folder name for the live release is not known yet.

For development, link the repository folder instead of copying it (PowerShell):

```powershell
New-Item -ItemType Junction `
  -Path "<WoW folder>\_classic_beta_\Interface\AddOns\GuildTradebook" `
  -Target "<repository>\GuildTradebook"
```

Each crafter has to open the professions window once and click each profession tab. That is the only time the game exposes the recipe list.

## Usage

| Command | |
|---|---|
| `/gtb` or `/tradebook` | open the window (Recipes, Upgrades, Members) |
| `/gtb search <text>` | search recipes and items |
| `/gtb wishlist` | open your wishlist |
| `/gtb options` | open the settings (also under Options → AddOns → Guild Tradebook) |
| `/gtb minimap` | show/hide the minimap button |
| `/gtb chatbot` | toggle answering `!craft <item>` (asked in guild chat or whispered; answered by whisper) |
| `/gtb link [name]`, `/gtb unlink` | show, offer or end a link with your other license (also by right-click in the Members tab) |
| `/gtb versions` | ask the guild which addon version everyone runs; builds that can not exchange data with yours are named |
| `/gtb resync` | sync with a guild member now |
| `/gtb diag [name]` | test whether addon messages reach the guild (the server echoes them back to you); with a name, test addon whispers to that member in both name forms |
| `/gtb dump <name>` | show what is known about a character |
| `/gtb log` | open the log (debug lines and addon messages, with times) as copyable text |
| `/gtb stats`, `/gtb debug` | diagnostics |

- **Recipes:** free-text search plus a profession filter. Selecting a recipe shows the crafters (online first, then the most recently confirmed; click to whisper) and the reagents.
- **Upgrades:** pick an item type (Cloth, Leather, …), a slot and your favorite stats. You get items guild members can craft that beat what you have equipped. Rings and trinkets are compared with your weaker one. Bind-on-pickup items are hidden by default, because a crafter cannot hand them over.
- **Members:** who shares what and how fresh it is. It also lists members whose professions the server knows but who share no addon data. Three views (dropdown at the top right): **Players** (each player with their characters), **Professions** (one collapsible group per profession, members by skill level: who is close to the cap, which profession is missing) and **Cooldowns** (one group per cooldown recipe: who is ready now, who is next). "Only reachable now" hides characters nobody can ask right now. The search box (top left) finds characters by name or profession: in the Players view the whole player stays, in the group views a matching profession or cooldown name keeps the whole group, and a matching name opens the groups with just that character. Name click whispers, row click opens the member's recipes (filtered to the profession) or the cooldown recipe. The view, open groups and filter are remembered per character.
- **Tooltips:** items guild members can craft show "Craftable by guild: Anna*, Bert". With more than 4 crafters it shows the count and who is online: "23 members (online: Anna, Bert, Cleo +2)". Patterns, recipes, formulas and plans show "Known in your guild by 3: …" or "Not known in your guild yet", which helps decide whether to learn one or pass it on. The match is by name. Hovering a guild member (in the world, on unit frames) shows their professions with skill levels, one line per primary profession; the secondary ones (Cooking, First Aid, Fishing) dimmed below if turned on in the settings (off by default).
- **Minimap button:** left-click opens the window, right-click opens the settings, drag to move. It **glows** while a guild member who can craft something on your wishlist is online; hovering shows what and who, and a click then opens the Wishlist.
- **Settings:** under Options → AddOns. Turn the tooltip types (and secondary professions on player tooltips), `!craft` answers, wishlist notices and sound, and debug output on or off.
- **Wishlist:** add a recipe from the Recipes tab, or right-click an upgrade. When a guild member who can craft it comes online, you get a chat notice.
- **Reagent check:** the recipe detail shows how many of each reagent you own (bags and bank; the bank counts after you've opened it) against what you need for 1–50 crafts, plus what's missing.
- **Reagents are clickable:** hover for the item tooltip (price addons included), shift-click to link. A reagent a guild member can craft is marked `»`; clicking it opens that recipe, and **Back** returns.
- **Cooldowns:** for recipes with a cooldown (transmutes, Mooncloth, …), crafter lists show who is ready now or when they will be. Ready crafters are listed first. Don't want to be asked? The setting "Share my cooldowns" (on by default) turned off keeps you listed as a crafter, but shown as "not shared" and never as ready, on all characters of your account.
- **Alts are grouped automatically:** the addon knows which characters you play on your account, so nobody sets a main. If a crafter is offline but the same player is online on another character, lists show "Crafty (online as Mainy)", whispers go to Mainy, the wishlist notice and the minimap glow count them as online, and the Members tab lists each player's characters together.
- **Two licenses, one player:** characters on a second WoW license (another account) can be linked. In the Members tab, right-click one of your characters on the other license → "Link with my account…"; then log in on that license and confirm the question. Both licenses then share one player ID, so the whole guild (0.1.0 clients included) groups all characters as one player. Either license can unlink alone (right-click your own characters → "Unlink other license…"), and the guild sees two players again. The offer waits in your record until the other license logs in; if only 0.1.0 clients relay it in the meantime, it arrives once both licenses are online at the same time. The guild is not told in chat; it simply sees one player. A linked character that leaves the guild drops out of the group like any former member; if it comes back, the link still holds. Links are per guild: in a new guild, link again.
- **`!craft <item>`:** members without the addon can ask who crafts something (`!herstellen` works too), in guild chat or by whispering an addon user. The answer comes as a whisper, so guild chat only shows the question. For a guild chat question exactly one addon user answers: they elect themselves with the same deterministic ranking as the sync partner. Names are searched in each client's language, so clients that find something answer first; "nobody" comes only after all of them had their turn, and names the language that was searched. Linked items (`!craft [Brown Linen Vest]`) are looked up by item ID, so they work in every language; a client of the asker's language (it calls the item by the linked name) answers first. The answering player does not see their own answer whisper (it is in `/gtb log`). Turn it off with `/gtb chatbot`.

## How the data stays correct

Each character's data is a **record**: a full snapshot of its professions and recipes. Only the character itself (or its account, for alts) ever writes it; everyone else forwards it unchanged.

- **Versions use server time** (`GetServerTime()`, the same clock on every client), plus a sequence number and a content hash. The owner's latest change always beats an older copy, even if the owner lost their SavedVariables.
- **Profession switch:** a dropped profession is simply missing from the next snapshot, so the newer snapshot replaces every old copy. A lower rank than before means the profession was unlearned and relearned, so its recipes are reset and stale copies cannot bring them back.
- **Lost SavedVariables / new PC:** a brand-new own record is held back for up to 90 s. During that time the owner pulls its old copy from the guild and adopts the recipes for professions it still has, marked *unverified* until the next profession-window scan.
- **Owner reclaim:** if someone holds a copy of you that claims to be newer (forged, or from another PC), you re-publish with a version above it.
- **Guild membership:** records of characters not in the roster are hidden, not relayed, and deleted after 14 days. Nothing is pruned until the roster has fully loaded. Characters are keyed by GUID, so renames are handled. Data of a guild none of your characters has been in for 60 days is deleted too, except your own characters' records.
- **Player ID:** all characters of one account in the guild carry the same random ID (stored in the guild's partition of the SavedVariables, so it never links characters across guilds). A second PC starts with its own ID; as soon as a character is played on both, the smaller ID wins everywhere and the account re-publishes its alts with it.
- **Server cross-check:** the guild roster data names each member's two primary professions (the rank is always reported as 1, so it is not used). If it positively lists two other professions, a relayed profession is hidden from search; the record itself is left alone.

## Network traffic

Built for about 100 members online at once:

- An owner's change is broadcast once to the guild: recipe changes in the two primary professions within 5 s; secondary professions (Cooking, First Aid, …) and rank-ups are batched into one message per 60 s.
- When you log in, you sync with **one** partner by whisper. You compare 16 bucket hashes and then exchange only the records that differ. If you are already up to date, that costs two small messages. A second check with another partner follows about a minute later.
- A fresh install with no known partner broadcasts one request. Peers elect a single responder by a deterministic ranking.
- Every 20 minutes each client re-syncs with one random partner.
- Reagents are not part of the records. They are fetched on demand from an online crafter of that recipe and cached.

Messages are CBOR, compressed with Deflate and Base64-encoded (native `C_EncodingUtil`). They go through AceComm and ChatThrottleLib. The minimap button uses LibDataBroker-1.1, LibDBIcon-1.0 and LibCustomGlow-1.0, the same versions as Gargul. All libraries are included under `Libs/`.

## Development

```
lua tests/run.lua
```

This runs unit tests for the merge rules, upgrade finder tests, a UI smoke test, and a multi-client network simulation. The simulation covers split brain, partitions, lost SavedVariables, forged copies, members leaving, alts, and 100-member traffic. Any Lua 5.1–5.4 works; the addon code itself stays Lua 5.1 compatible.

### Sharing a build

```
python tools/package.py
```

This writes `dist/GuildTradebook-<version>.zip`.

- **Release:** set `## Version:` in the TOC to e.g. `0.1.0` (no `-dev`), commit, tag `v0.1.0`, then package. The zip carries exactly that version. After the release, set the TOC to the next `-dev` version. What changed goes into `CHANGELOG.md`.
- **Test build:** with a `-dev` version in the TOC, the zip's version names the commit (`0.2.0-d8dcb0e`); uncommitted changes are included and marked `-dirty`.

The commit time becomes the build number, so `/gtb versions` notices newer builds. The copy in the repo reports its TOC version with build 0.

Every addon message carries the sender's version. A guildmate whose build can not exchange data with yours (another protocol, or a build from before the sender GUID) is reported once in chat instead of being silently ignored.

### To verify in game

The following were built from the `forever` API source but are not yet confirmed on a live client:

- `C_TradeSkillUI.GetAllRecipeIDs` exists; otherwise scans fall back to the filtered list and count as partial.
- `GetRecipeSchematic(id).outputItemID` and reagents for recipes the player does not know (only used as a fallback).
- `C_Club` member `profession1ID`/`profession2ID` are skill line IDs.
- Real addon-message throughput. A fresh install pulls the whole pool from one partner, which can take a few minutes on a large guild.
