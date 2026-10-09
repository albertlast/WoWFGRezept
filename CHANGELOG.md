# Changelog

## 0.2.0 (in development)

- Nothing yet.

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
