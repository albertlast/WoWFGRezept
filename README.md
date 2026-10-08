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
| `/gtb main <name>` | link this character to your main (`/gtb main` clears it) |
| `/gtb resync` | sync with a guild member now |
| `/gtb tooltip` | toggle the "Craftable by guild" tooltip lines |
| `/gtb dump <name>` | show what is known about a character |
| `/gtb stats`, `/gtb debug`, `/gtb log` | diagnostics |

- **Recipes:** free-text search plus a profession filter. Selecting a recipe shows the crafters (online first, then the most recently confirmed; click to whisper) and the reagents.
- **Upgrades:** pick an item type (Cloth, Leather, …), a slot and your favorite stats. You get items guild members can craft that beat what you have equipped. Rings and trinkets are compared with your weaker one. Bind-on-pickup items are hidden by default, because a crafter cannot hand them over.
- **Members:** who shares what and how fresh it is. It also lists members whose professions the server knows but who share no addon data.

## How the data stays correct

Each character's data is a **record**: a full snapshot of its professions and recipes. Only the character itself (or its account, for alts) ever writes it; everyone else forwards it unchanged.

- **Versions use server time** (`GetServerTime()`, the same clock on every client), plus a sequence number and a content hash. The owner's latest change always beats an older copy, even if the owner lost their SavedVariables.
- **Profession switch:** a dropped profession is simply missing from the next snapshot, so the newer snapshot replaces every old copy. A lower rank than before means the profession was unlearned and relearned, so its recipes are reset and stale copies cannot bring them back.
- **Lost SavedVariables / new PC:** a brand-new own record is held back for up to 90 s. During that time the owner pulls its old copy from the guild and adopts the recipes for professions it still has, marked *unverified* until the next profession-window scan.
- **Owner reclaim:** if someone holds a copy of you that claims to be newer (forged, or from another PC), you re-publish with a version above it.
- **Guild membership:** records of characters not in the roster are hidden, not relayed, and deleted after 14 days. Nothing is pruned until the roster has fully loaded. Characters are keyed by GUID, so renames are handled.
- **Server cross-check:** the guild roster data names each member's two primary professions (the rank is always reported as 1, so it is not used). If it positively lists two other professions, a relayed profession is hidden from search; the record itself is left alone.

## Network traffic

Built for about 100 members online at once:

- An owner's change is broadcast once to the guild: recipe changes in the two primary professions within 5 s; secondary professions (Cooking, First Aid, …) and rank-ups are batched into one message per 60 s.
- When you log in, you sync with **one** partner by whisper. You compare 16 bucket hashes and then exchange only the records that differ. If you are already up to date, that costs two small messages. A second check with another partner follows about a minute later.
- A fresh install with no known partner broadcasts one request. Peers elect a single responder by a deterministic ranking.
- Every 20 minutes each client re-syncs with one random partner.
- Reagents are not part of the records. They are fetched on demand from an online crafter of that recipe and cached.

Messages are CBOR, compressed with Deflate and Base64-encoded (native `C_EncodingUtil`). They go through AceComm and ChatThrottleLib, which are included under `Libs/`.

## Development

```
lua tests/run.lua
```

This runs unit tests for the merge rules, upgrade finder tests, a UI smoke test, and a multi-client network simulation. The simulation covers split brain, partitions, lost SavedVariables, forged copies, members leaving, alts, and 100-member traffic. Any Lua 5.1–5.4 works; the addon code itself stays Lua 5.1 compatible.

### To verify in game

The following were built from the `forever` API source but are not yet confirmed on a live client:

- `C_TradeSkillUI.GetAllRecipeIDs` exists; otherwise scans fall back to the filtered list and count as partial.
- `GetRecipeSchematic(id).outputItemID` and reagents for recipes the player does not know (only used as a fallback).
- `C_Club` member `profession1ID`/`profession2ID` are skill line IDs.
- Real addon-message throughput. A fresh install pulls the whole pool from one partner, which can take a few minutes on a large guild.
