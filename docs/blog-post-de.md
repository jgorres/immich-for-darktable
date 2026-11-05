# Immich for Darktable: Fotos in Immich suchen, in Darktable bearbeiten

Immich kennt meine Bilder besser als ich. Es findet „Hund am Strand“ ohne ein einziges Stichwort, liest Schilder und Dokumente auf den Fotos mit und sortiert alles nach Ort, Kamera und Datum. Bearbeiten will ich die Treffer aber nicht im Browser, sondern in Darktable, auf den Originaldateien, mit allen Werkzeugen der Dunkelkammer.

Genau diese Lücke schließt **Immich for Darktable**: ein Lua-Skript, das die Immich-Suche als Modul in den Leuchttisch von Darktable holt.

## Was das Skript macht

Im Leuchttisch erscheint ein neues Modul „Immich-Suche“. Dort gebe ich einen Suchtext ein, wähle den Modus und klicke auf „suchen“:

- **Smart-Suche** versteht den Bildinhalt. Die Beschreibung „Hund am Strand“ liefert Hunde am Strand, auch wenn kein Bild je ein Stichwort bekommen hat. Immich nutzt dafür ein CLIP-Modell.
- **Metadatensuche** filtert nach Teilen des Dateinamens. Aufnahmezeitraum, Kamerahersteller und -modell, Favoriten und Bewertung stehen als Filter in beiden Modi zur Verfügung und schränken auch die Smart-Suche ein.
- **Text im Bild** findet Fotos, auf denen Immich per OCR ein bestimmtes Wort erkannt hat: das Ortsschild, die Speisekarte, den Flyer. Der Filter funktioniert in beiden Modi und auch ganz allein.

Die Treffer landen nicht als Kopien irgendwo, sondern Darktable importiert die Originale an ihrem echten Speicherort. Jeder Treffer bekommt einen Tag wie `darktable|immich|Hund am Strand`, und der Leuchttisch zeigt genau diese Sammlung. Ein Doppelklick öffnet die Dunkelkammer, auf Wunsch springt das Skript direkt zum ersten Treffer. Ein Klick auf „vorherige Sammlung wiederherstellen“ bringt den alten Zustand zurück.

Während der Suche bleibt Darktable bedienbar. Der Button zeigt „suche läuft …“, das linke Panel führt die Anfrage und den Import als Hintergrundaufträge, der Import lässt sich dort abbrechen. Die Statuszeile nennt zum Schluss, wie viele Sekunden auf den Server und wie viele auf den Import entfielen. Wer es auffälliger mag, lässt sich per Button „Statushervorhebung installieren“ eine CSS-Regel in die `user.css` schreiben, die die Statuszeile während einer Anfrage einfärbt; die CSS-Anpassungen müssen dafür in den Darktable-Einstellungen eingeschaltet sein.

Weil Darktable auf den Originalen arbeitet, landet die Bearbeitung wie gewohnt im XMP-Sidecar neben der Datei. Immich liest dieses Sidecar beim nächsten Scan mit. Beide Programme arbeiten so auf demselben Bestand, ohne Export, Upload oder doppelte Dateien.

## Wie es technisch funktioniert

Darktable bietet keine Plugin-Schnittstelle in C, aber eine ausgereifte Lua-API. Das Skript ist eine einzige Lua-Datei:

- Die Anfragen an Immich laufen über `curl`, das auf Linux, macOS und Windows ohnehin vorhanden ist. Eine Lua-HTTP-Bibliothek wäre im Flatpak von Darktable nicht verfügbar gewesen.
- Der JSON-Parser ist eingebettet (json.lua von rxi), damit die Installation aus einer Datei besteht.
- Immich meldet zu jedem Treffer den Pfad des Originals aus Sicht seines Containers. Eine konfigurierbare Pfadabbildung übersetzt diesen Präfix in den lokalen Pfad, etwa den Import-Pfad der externen Bibliothek auf das Verzeichnis, unter dem dieselben Dateien auf dem Darktable-Rechner liegen. Das kann eine lokale Platte sein, eine Netzwerkfreigabe oder unter Windows ein Laufwerksbuchstabe.
- Die Suche läuft in Darktables Lua-Hintergrundthread, damit die Oberfläche währenddessen weiter zeichnet. Ein Lauf sperrt die Buttons, ein zweiter Start wird abgewiesen.
- Die Oberfläche ist auf Englisch und Deutsch verfügbar. Die Übersetzung liegt als eigene Textdomain neben dem Skript.

Getestet habe ich mit Darktable 5.6.2 als Flatpak und Immich 3.3.5. Das Skript verlangt Darktable 5.0 oder neuer.

## Sicherheit

Das Skript braucht einen API-Schlüssel von Immich. Ich empfehle einen eigenen Schlüssel mit genau einer Berechtigung: `asset.read`. Mehr braucht die Suche nicht, und der Schlüssel lässt sich in Immich jederzeit widerrufen.

Schlüssel und Suchanfrage gehen über temporäre Dateien an `curl`, nie über die Kommandozeile, wo sie in der Prozessliste sichtbar wären. Eingaben erreichen die Shell nicht, sie werden als JSON kodiert. Das Skript schreibt nichts nach Immich, es liest nur.

Eine Einschränkung sollte man kennen: Darktable speichert alle Einstellungen unverschlüsselt in seiner Konfigurationsdatei, auch den API-Schlüssel. Deshalb der Schlüssel mit Minimalrechten.

## Installation in Kürze

1. Repository klonen oder die Datei `immich_search.lua` samt Ordner `locale/` in den Darktable-Konfigurationsordner unter `lua/immich-for-darktable/` kopieren (Flatpak: `~/.var/app/org.darktable.Darktable/config/darktable/`).
2. In der Datei `luarc` im selben Konfigurationsordner die Zeile `require "immich-for-darktable/immich_search"` ergänzen oder das Skript im Script-Manager starten.
3. In Immich unter Kontoeinstellungen einen API-Schlüssel mit der Berechtigung `asset.read` anlegen.
4. In Darktable unter Einstellungen > Lua-Optionen Server-URL, API-Schlüssel und Pfadabbildung eintragen.

Der Button „Verbindung prüfen“ meldet danach Serverversion, Gültigkeit des Schlüssels und ob Smart-Suche und OCR auf dem Server aktiv sind.

## Grenzen und Ausblick

Die Smart-Suche liefert immer so viele Treffer wie angefordert, eine Trefferschwelle kennt Immich nicht. Das Limit steht darum sichtbar im Modul, voreingestellt auf 50, höchstens 200. Dateien, die Darktable nicht importieren kann, etwa SVG-Grafiken, werden gezählt und übersprungen.

Der Leuchttisch wendet seine eigenen Filter, etwa den Sterne-Filter in der oberen Leiste, auch auf die Immich-Sammlung an. Wirkt eine Suche leer, lohnt dort der erste Blick.

Auf der Liste für die nächsten Versionen stehen der Rückweg „in Immich zeigen“ für das gewählte Bild, die Suche nach ähnlichen Bildern über Immichs Bildvergleich, Ortsfilter sowie Auswahllisten für Personen, Alben und Tags.

## Code und Mitmachen

Das Skript steht unter GPL-3.0-or-later auf GitHub:
**https://github.com/jgorres/immich-for-darktable**

Dort liegen auch das Konzept, ein Testharness mit Darktable-Stub und die Übersetzungsdateien. Fehlerberichte und Erfahrungen mit anderen Plattformen sind willkommen, besonders von Windows- und macOS-Nutzern, denn getestet ist bisher nur Linux.
