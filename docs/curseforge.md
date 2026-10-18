# CurseForge project texts (copy and paste)

Not part of the addon zip. Update the file list and the changelog with every upload.

## Project

| Field | Value |
|---|---|
| Game / type | World of Warcraft / Addons |
| Name | Guild Tradebook |
| Author | albertlast |
| Project ID | 1752487 (`## X-Curse-Project-ID` in the TOC) |
| Categories | Professions, Guild, Tooltip (whatever the form offers that fits) |
| Source / issues | none yet (no public repository) |
| License | your choice; the form requires one ("All Rights Reserved" is allowed) |

### Summary (max. 250 characters)

Guild recipe sharing: every member who runs the addon shares their recipes, so you can search what anyone in the guild can craft, even offline. Gear upgrade finder, wishlist, !craft in guild chat. English and German.

### Description (Markdown)

```markdown
# Guild Tradebook

**Who in the guild can craft this?** Every guild member who runs Guild Tradebook shares their professions and recipes with the guild automatically, and members pass on the recipes of others. You can search everything the guild can craft, **even when the crafter is offline**.

Built for **World of Warcraft: Forever** (interface 16001). Available in English and German.

## Features

- **Recipes tab:** search all guild recipes, filter by profession, grouped like the profession window (profession > category, collapsible, in the window's order). Click a recipe to see who can craft it (online first, click to whisper) and the reagents.
- **Upgrades tab:** pick an item type, a slot and the stats you care about; the addon lists craftable items by guild members that beat your equipped item and shows how many levels you still need. Stat weights per stat in the settings.
- **Wishlist:** mark recipes you want. A chat notice (and a glowing minimap button) tells you when a crafter comes online. Pause single wishes if you do not want to be bothered.
- **Members tab:** every member with their professions and crafting cooldowns (you can choose not to share yours), search by name, alts grouped under one player.
- **Tooltips:** "Craftable by guild: ..." on items, "Known in your guild by ..." on recipes, professions on player tooltips. A **tooltip filter** in the settings hides basics everyone makes (First Aid and Fishing are off by default).
- **`!craft <item>` in guild chat:** the addon answers by whisper for members without the addon (can be turned off).
- **Export** of the guild data as JSON for Discord bots or spreadsheets (`/gtb export`).

## Getting started

1. Everybody in the guild installs the addon.
2. **Open each of your professions once** and click each profession tab: that is the only time the game exposes your recipe list. The addon scans and shares it. New recipes and skill-ups follow automatically.
3. Open the window with `/gtb` (or the minimap button).

## Good to know

- It only talks to guild members through addon messages; nothing leaves the game. What is shared: your characters' professions, recipes, skill levels and (optionally) cooldowns.
- A new member syncs with one online guildmate at login, not with everyone, so a big guild does not flood the chat.
- Rogue Poisons are not shared (a class skill, everyone makes their own).
- Settings: Options > AddOns > Guild Tradebook (sub-pages: stat weights, tooltip filter). `/gtb` shows all commands.

Questions or bugs? Use the comments or message the author.
```

## File upload (0.5.0)

- File: `dist/GuildTradebook-0.5.0.zip` (one root folder `GuildTradebook`, matching `GuildTradebook.toc`)
- Release type: Release
- Display name: `0.5.0`
- Game version: see the form; the TOC says `## Interface: 16001`

### Changelog (Markdown)

```markdown
## 0.5.0

- **Tooltip filter:** new settings page lists all professions of the guild with their groups; mark what should not show "who can craft this" in item tooltips. First Aid and Fishing are hidden by default.
- **Wishlist:** Pause and Remove buttons on every wish; a paused wish stays on the list but gives no notice, sound or glow.
- **Minimap glow** only for news: looking at the Wishlist tab counts the crafters online now as seen.
- **Tooltips:** every person is listed once (you and your alt were two entries).
- Recipes in the profession window's order (highest skill first); the crafter shares it after opening the profession window with 0.4.0 or later.
- A short chat line (at most once a day) when a guildmate has a newer release.
- Fix: error message on player tooltips ("secret values").
```

## Deutsch

Für die Gilde und deutschsprachige Besucher; die Beschreibung kann unter den englischen Text gesetzt werden.

### Zusammenfassung (max. 250 Zeichen)

Gildenrezepte automatisch teilen: Such nach, was jeder in der Gilde herstellen kann, auch wenn er offline ist. Mit Upgrade-Finder, Wunschliste und !craft im Gildenchat. Auf Englisch und Deutsch.

### Beschreibung (Markdown)

```markdown
# Guild Tradebook

**Wer in der Gilde kann das herstellen?** Jedes Gildenmitglied mit Guild Tradebook teilt seine Berufe und Rezepte automatisch mit der Gilde, und die Mitglieder geben die Rezepte der anderen weiter. So kannst du alles durchsuchen, was die Gilde herstellen kann, **auch wenn der Hersteller offline ist**.

Gebaut für **World of Warcraft: Forever** (Interface 16001). Auf Englisch und Deutsch.

## Funktionen

- **Reiter Rezepte:** alle Gildenrezepte durchsuchen, nach Beruf filtern, gruppiert wie im Berufsfenster (Beruf > Kategorie, einklappbar, in der Reihenfolge des Fensters). Ein Klick auf ein Rezept zeigt, wer es herstellt (online zuerst, Klick zum Anflüstern) und die Materialien.
- **Reiter Verbesserungen:** Gegenstandsart, Platz und die Werte wählen, die dir wichtig sind. Das Addon listet herstellbare Gegenstände von Gildenmitgliedern, die besser sind als dein angelegter, und zeigt, wie viele Stufen dir noch fehlen. Gewichtung pro Wert in den Einstellungen.
- **Wunschliste:** Rezepte markieren, die du haben willst. Ein Chat-Hinweis (und ein leuchtender Minimap-Knopf) meldet, wenn ein Hersteller online kommt. Einzelne Wünsche lassen sich pausieren.
- **Reiter Mitglieder:** alle Mitglieder mit Berufen und Herstellungs-Abklingzeiten (deine eigenen kannst du für dich behalten), Suche nach Namen, Twinks unter einem Spieler zusammengefasst.
- **Tooltips:** „Herstellbar in der Gilde: …“ bei Gegenständen, „In deiner Gilde bekannt bei …“ bei Rezepten, Berufe im Spieler-Tooltip. Ein **Tooltip-Filter** in den Einstellungen blendet Alltägliches aus, das jeder kann (Erste Hilfe und Angeln sind standardmäßig aus).
- **`!craft <Gegenstand>` im Gildenchat:** Das Addon antwortet per Flüstern für Mitglieder ohne das Addon (abschaltbar).
- **Export** der Gildendaten als JSON für Discord-Bots oder Tabellen (`/gtb export`).

## Erste Schritte

1. Alle in der Gilde installieren das Addon.
2. **Öffne jeden deiner Berufe einmal** und klicke jeden Berufsreiter an: Nur dann gibt das Spiel deine Rezeptliste frei. Das Addon liest sie und teilt sie. Neue Rezepte und Skill-ups folgen automatisch.
3. Das Fenster öffnest du mit `/gtb` (oder dem Minimap-Knopf).

## Gut zu wissen

- Das Addon spricht nur über Addon-Nachrichten mit Gildenmitgliedern; nichts verlässt das Spiel. Geteilt werden Berufe, Rezepte, Skillstufen und (optional) Abklingzeiten deiner Charaktere.
- Ein neues Mitglied gleicht sich beim Login mit einem Online-Gildenmitglied ab, nicht mit allen. Auch eine große Gilde wird nicht zugespammt.
- Schurken-Gifte werden nicht geteilt (Klassenfertigkeit, jeder macht seine eigenen).
- Einstellungen: Optionen > AddOns > Guild Tradebook (Unterseiten: Wertegewichtung, Tooltip-Filter). `/gtb` zeigt alle Befehle.

Fragen oder Fehler? Schreib einen Kommentar oder melde dich beim Autor.
```

### Changelog (Markdown)

```markdown
## 0.5.0

- **Tooltip-Filter:** Neue Einstellungsseite mit allen Berufen der Gilde und ihren Gruppen; markiere, bei welchen im Tooltip nicht stehen soll, wer sie herstellt. Erste Hilfe und Angeln sind standardmäßig ausgeblendet.
- **Wunschliste:** Pause- und Entfernen-Knopf bei jedem Wunsch; ein pausierter Wunsch bleibt auf der Liste, meldet sich aber nicht (kein Hinweis, kein Ton, kein Leuchten).
- **Minimap-Leuchten** nur noch bei Neuem: Sobald du die Wunschliste angesehen hast, gelten die gerade online befindlichen Hersteller als gesehen.
- **Tooltips:** Jede Person steht nur einmal da (du und dein Twink waren zwei Einträge).
- Rezepte in der Reihenfolge des Berufsfensters (höchste Stufe zuerst); der Hersteller teilt sie, sobald er mit 0.4.0 oder neuer sein Berufsfenster geöffnet hat.
- Kurzer Chat-Hinweis (höchstens einmal am Tag), wenn ein Gildenmitglied ein neueres Release hat.
- Behoben: Fehlermeldung im Spieler-Tooltip („secret values“).
```

### Bildunterschriften für Screenshots

| Bild | Deutsch | English |
|---|---|---|
| Rezepte-Tab (ein Beruf aufgeklappt) | Alle Gildenrezepte durchsuchen, gruppiert wie im Berufsfenster | Search every guild recipe, grouped like the profession window |
| Rezept mit Herstellerliste | Wer es herstellen kann, online zuerst, mit Materialien | Who can craft it, online first, with reagents |
| Wunschliste mit Pause/Entfernen | Wunschliste mit Hinweis, wenn ein Hersteller online kommt | Wishlist with a notice when a crafter comes online |
| Verbesserungen-Tab | Herstellbare Verbesserungen für dich, mit den Stufen bis zur Nutzbarkeit | Craftable upgrades for you, with levels until usable |
| Tooltip eines Gegenstands | „Herstellbar in der Gilde“ direkt im Item-Tooltip | "Craftable by guild" right in the item tooltip |
| Einstellungsseite Tooltip-Filter | Berufe und Gruppen im Tooltip ausblenden | Hide professions and groups in tooltips |
