local _, ns = ...
if GetLocale() ~= "deDE" then return end
local L = ns.L

L.TAB_SEARCH = "Rezepte"
L.TAB_UPGRADES = "Verbesserungen"
L.TAB_MEMBERS = "Mitglieder"

L.SEARCH_HINT = "Rezept oder Gegenstand suchen"
L.ALL_PROFESSIONS = "Alle Berufe"
L.NO_RESULTS = "Keine Ergebnisse."
L.NOT_IN_GUILD = "Du bist in keiner Gilde."
L.CRAFTERS = "Hersteller"
L.REAGENTS = "Reagenzien"
L.REAGENTS_LOADING = "Reagenzien werden geladen..."
L.REAGENTS_UNKNOWN = "Reagenzien unbekannt."
L.OPTIONAL = "optional"
L.WHISPER = "Flüstern"
L.ONLINE = "online"
L.YOU = "du"
L.ALT = "Twink"
L.UNVERIFIED = "unbestätigt"
L.NOT_SCANNED = "noch nicht eingelesen"
L.CONFIRMED_AGO = "bestätigt vor %s"
L.RANK = "Stufe %d/%d"

L.ITEM_TYPE = "Gegenstandsart"
L.SLOT = "Platz"
L.FAV_STATS = "Bevorzugte Werte"
L.ANY = "Beliebig"
L.ALL_SLOTS = "Alle Plätze"
L.WEAPON_ANY = "Waffe (beliebig)"
L.MISC_ARMOR = "Verschiedenes (Ringe, Hals, Schmuck)"
L.SHOW_BOP = "Beim Aufheben gebundene zeigen"
L.SHOW_ALL = "Auch keine Verbesserungen zeigen"
L.LEVEL_AHEAD = "Gegenstände bis +%d Stufen einbeziehen"
L.EQUIPPED_EMPTY = "Platz leer"
L.PENDING_ITEMS = "Lade %d Gegenstand/Gegenstände..."
L.BOP_WARNING = "Beim Aufheben gebunden: Der Hersteller kann es dir nicht geben."
L.NO_FAV_STATS = "Wähle mindestens einen bevorzugten Wert."

L.MEMBERS_HEADER = "%d Mitglieder teilen Rezepte (%d Rezepte)"

L.TOOLTIP_CRAFTABLE = "Herstellbar in der Gilde:"
L.TOOLTIP_KNOWN = "Bekannt in der Gilde:"
L.TOOLTIP_MORE = "(+%d weitere)"

L.REMIND_SCAN = "Öffne das Berufsfenster und klicke einmal auf den Reiter %s, damit deine Rezepte mit der Gilde geteilt werden."

L.SLASH_HELP = [[/gtb - Fenster öffnen
/gtb search <Text> - Rezepte suchen
/gtb main <Name> - diesen Charakter mit deinem Main verknüpfen
/gtb main - Main-Verknüpfung entfernen
/gtb resync - vollständige Synchronisierung anfordern
/gtb tooltip - Tooltip-Zeilen ein/aus
/gtb debug - Debug-Ausgabe ein/aus
/gtb dump <Name> - zeigt, was über einen Charakter bekannt ist
/gtb stats - Statistik des Rezept-Pools]]
