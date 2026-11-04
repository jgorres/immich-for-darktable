# Immich for Darktable – Konzept

Version: 0.1.0
Stand: 04.11.2026
Status: Entwurf, noch kein Code

## 1. Ziel

Ein Lua-Skript für Darktable, das aus dem Leuchttisch heraus eine Suche an
Immich schickt (Freitext per CLIP oder Metadatenfilter), die Treffer als
Sammlung im Leuchttisch anzeigt und die Bilder direkt in der Dunkelkammer
bearbeitbar macht. Darktable arbeitet dabei auf den Originaldateien, nicht
auf Kopien. Bearbeitungen landen wie gewohnt im XMP-Sidecar neben dem
Original, das Immich beim nächsten Bibliotheksscan mitliest.

### Abgrenzung

- Keine Änderungen an Immich, keine Uploads, keine Schreibzugriffe auf Assets.
- Kein eigener Thumbnail-Browser: Darktable zeigt seine eigenen Vorschauen.
- Keine Darktable-Erweiterung in C; Darktable bietet nur die Lua-API.

## 2. Rahmenbedingungen

### 2.1 Zielumgebung (Fokus)

| Punkt | Befund (04.11.2026) |
|---|---|
| Darktable | Flatpak `org.darktable.Darktable` 5.6.2, Lua 5.4 eingebettet, Script-Manager aktiv |
| Flatpak-Rechte | `shared=network`, `filesystems=host`, Host-Ordner der Bilder lesbar |
| Werkzeuge in der Sandbox | `curl` 8.21 (OpenSSL), `git`; keine Lua-Bibliotheken (kein luasocket, luasec, dkjson) |
| Skriptordner | `~/.var/app/org.darktable.Darktable/config/darktable/lua/` (Checkout von darktable/lua-scripts) |
| Immich | v3.3.5 auf `http://silentium:2283`, nur im LAN, HTTP |
| Pfadabbildung extern | Host `/mnt/home2/jgorres/Bilder` ↔ Container `/mnt/media/bilder` (ro) |
| Pfadabbildung Uploads | Host `/mnt/home2/immich/library` ↔ Container `/data` |

### 2.2 Portabilität (Anforderung)

Das Skript soll ohne Änderung auch unter Darktable aus apt (Debian 13:
5.0.1), Windows und macOS laufen. Daraus folgt:

- Einzige externe Abhängigkeit ist `curl` (Windows ab 10, macOS und
  Desktop-Linux bringen es mit). Keine Lua-HTTP-Bibliothek.
- JSON-Parser in reinem Lua, in die Skriptdatei eingebettet
  (rxi/json.lua, MIT, Attribution im Kopf). Eine Datei, ein Installationsweg.
- Externe Aufrufe über `dtutils.system.external_command`, das die
  Windows-Eigenheiten (cmd, Anführungszeichen) kapselt.
- Temporäre Dateien in `dt.configuration.tmp_dir`, Pfadtrenner werden
  normalisiert, Laufwerksbuchstaben sind in der Pfadabbildung erlaubt.
- Mindest-API-Version wird mit `du.check_min_api_version` geprüft
  (Ziel: Darktable 5.0; die genaue API-Nummer wird in der Umsetzung mit
  `dt.configuration.api_version_string` festgelegt).
- Auf fremden Rechnern müssen die Originale per Freigabe (SMB/NFS)
  erreichbar sein; die Pfadabbildung zeigt dann auf den Mount. Ohne Freigabe
  greift der optionale Download-Modus (Ausbaustufe, Abschnitt 11).

Getestet wird nur die Flatpak-Installation auf silentium. Für apt, Windows
und macOS gilt: defensiver Code, keine Linux-Annahmen, Prüfung per Review.

## 3. Architektur und Datenfluss

```
Leuchttisch-Modul „Immich-Suche“ (dt.register_lib)
   │ Suchbegriff, Filter, Limit
   ▼
Anfrage bauen → JSON-Body und Header als temporäre Dateien
   │
   ▼
curl (dtutils.system.external_command) → POST /api/search/smart|metadata
   │ Antwort als temporäre Datei
   ▼
JSON parsen → Liste der Assets (id, originalPath, originalFileName, exifInfo)
   │
   ▼
Pfadabbildung Container → Host; Treffer ohne Abbildung oder ohne Datei zählen
   │
   ▼
dt.database.import(pfad) je Treffer (bekannte Bilder kommen unverändert zurück)
   │
   ▼
Tag „darktable|immich|<suche>“ setzen, alte Treffer-Tags derselben Suche lösen
   │
   ▼
Sammlungsregel auf den Tag setzen (dt.gui.libs.collect.set_rules)
   │
   ▼
Statuszeile: n Treffer, m importiert, k ohne lokale Datei
   └─ optional: dt.gui.views.darkroom.display_image(erster Treffer)
```

Die Suche läuft in einem Darktable-Job (`dt.gui.create_job`) mit
Fortschrittsanzeige, damit die Oberfläche bei großen Trefferlisten nicht
blockiert.

## 4. Immich-API

Quelle: OpenAPI-Spezifikation v3.3.5 aus dem Immich-Repository.

### 4.1 Authentifizierung

- Header `x-api-key: <key>`.
- Eigener API-Key in Immich nur für dieses Skript, Rechte minimal:
  `asset.read` (Suche), dazu `person.read` und `tag.read` nur, wenn die
  Personen- und Tag-Filter (Ausbaustufe) genutzt werden, `asset.download`
  nur im Download-Modus.
- Der Key steht nie auf der Kommandozeile: Header kommen per `-H @datei`
  aus einer temporären Datei, der Body per `--data @datei`.

### 4.2 Endpunkte

| Methode | Pfad | Zweck | Recht |
|---|---|---|---|
| GET | `/api/server/ping` | Erreichbarkeit (Button „Verbindung prüfen“) | keins |
| GET | `/api/server/version` | Version anzeigen, Mindestversion prüfen | keins |
| POST | `/api/search/smart` | Freitext (CLIP) mit optionalen Filtern | asset.read |
| POST | `/api/search/metadata` | Reine Filtersuche ohne Freitext | asset.read |
| GET | `/api/assets/{id}/original` | nur Download-Modus | asset.download |

### 4.3 Genutzte Felder

Anfrage (`SmartSearchDto` bzw. `MetadataSearchDto`), erste Stufe:
`query` (nur smart), `originalFileName` (nur metadata), `takenAfter`,
`takenBefore`, `make`, `model`, `isFavorite`, `rating`, `type` = `IMAGE`,
`size`, `page`, `withExif` = true.

Antwort (`SearchResponseDto.assets.items[]`, Typ `AssetResponseDto`):
`id`, `originalPath`, `originalFileName`, `originalMimeType`, `type`,
`fileCreatedAt`, `isOffline`, `exifInfo.{make,model,dateTimeOriginal}`.
Außerdem `assets.total`, `assets.count`, `assets.nextPage`.

Hinweise:

- Die Smart-Suche liefert eine Rangliste ohne Trefferschwelle; es kommen
  immer `size` Treffer, solange genug Assets existieren. Das Limit ist
  deshalb im Modul sichtbar und klein voreingestellt.
- Videos werden ausgefiltert (`type` = `IMAGE`).
- Assets mit `isOffline` = true werden übersprungen.

## 5. Darktable-Lua-Bausteine

| Baustein | Verwendung |
|---|---|
| `dt.register_lib` | Modul im Leuchttisch, Container `DT_UI_CONTAINER_PANEL_RIGHT_CENTER` |
| `dt.new_widget` | entry (Suche), combobox (Modus), entry (Datum von/bis, Kamera), check_button (Favoriten), slider (Limit), button (Suchen, Verbindung prüfen, Ersten Treffer öffnen), label (Status) |
| `dt.preferences.register` | Server-URL, API-Key, Pfadabbildung, Tag-Präfix, Download-Modus, Download-Ordner |
| `dtutils.system.external_command` | portabler Aufruf von curl |
| `dtutils.file.check_if_bin_exists` | curl finden, sonst Fehlermeldung |
| `dt.configuration.tmp_dir` | temporäre Dateien |
| `dt.database.import` | Treffer in die Bibliothek holen |
| `dt.tags.create`, `dt.tags.attach`, `dt.tags.detach` | Treffer-Tag pflegen |
| `dt.gui.libs.collect.new_rule` / `set_rules` | Leuchttisch auf den Tag filtern (`DT_COLLECTION_PROP_TAG`) |
| `dt.gui.views.darkroom.display_image` | ersten Treffer öffnen |
| `dt.gui.create_job` | Fortschritt, Abbruch |
| `dt.print`, `dt.print_log` | Statusmeldungen, Protokoll |
| `du.check_min_api_version`, `script_data` (destroy/restart) | Script-Manager-Konformität |

## 6. Modul und Oberfläche

Reihenfolge der Widgets von oben nach unten:

1. Suchbegriff (Eingabefeld, Return löst die Suche aus).
2. Modus: „Smart (Bildinhalt)“ oder „Metadaten“. Bei „Metadaten“ dient das
   Eingabefeld als Dateinamensfilter.
3. Aufgenommen von / bis (ISO-Datum, leer = ohne).
4. Kamera (Hersteller/Modell, leer = ohne).
5. Nur Favoriten (Schalter), Mindestbewertung (0–5).
6. Treffer (Schieberegler 1–200, Vorgabe 50).
7. Nach der Suche ersten Treffer öffnen (Schalter).
8. Buttons: „Suchen“, „Verbindung prüfen“.
9. Statuszeile.

Einstellungen (Darktable-Voreinstellungen, Reiter Lua-Optionen):

| Schlüssel | Typ | Vorgabe | Bedeutung |
|---|---|---|---|
| `server_url` | string | `http://silentium:2283` | ohne abschließenden Schrägstrich |
| `api_key` | string | leer | Immich-API-Key (siehe 8.) |
| `path_map` | string | `/mnt/media/bilder=/mnt/home2/jgorres/Bilder;/data=/mnt/home2/immich/library` | Container-Präfix=Host-Präfix, mehrere mit `;` |
| `tag_prefix` | string | `darktable|immich` | Elternpfad des Treffer-Tags |
| `download_mode` | bool | aus | Ausbaustufe: Originale laden statt abbilden |
| `download_dir` | directory | leer | Zielordner im Download-Modus |
| `timeout` | integer | 30 | Sekunden für curl `--max-time` |

Die Pfadabbildung wird beim Laden geprüft: jeder Eintrag braucht beide
Seiten, Host-Seite muss existieren, `..` ist unzulässig. Treffer, deren
`originalPath` zu keinem Präfix passt, werden gezählt und in der
Statuszeile genannt.

## 7. Ablauf einer Suche

1. Einstellungen prüfen (URL, Key, curl vorhanden); bei Fehler Meldung,
   kein Aufruf.
2. Anfrage-Body als Lua-Tabelle bauen, mit dem eingebetteten Encoder nach
   JSON wandeln und in eine temporäre Datei schreiben; Header-Datei mit
   `x-api-key`, `Content-Type`, `Accept` schreiben.
3. curl ausführen: `--silent --show-error --fail-with-body --max-time N
   -H @header --data @body -o antwort URL`. Kein `--insecure`.
4. Rückgabewert und HTTP-Status auswerten; 401/403 als „API-Key oder
   Rechte“, 0/7/28 als „Server nicht erreichbar“ melden.
5. Antwort parsen, Items filtern (Typ, offline), Pfade abbilden.
6. Treffer-Tag `<tag_prefix>|<suchbegriff bereinigt>` anlegen; vorhandene
   Bilder mit diesem Tag zuerst lösen, damit die Sammlung nur das aktuelle
   Ergebnis zeigt.
7. Je Treffer `dt.database.import`, Tag anhängen, Fortschritt melden.
8. Sammlungsregel setzen (Modus AND, Item TAG, Daten = Tagpfad).
9. Statuszeile und `dt.print` mit Zählern; optional ersten Treffer öffnen.
10. Temporäre Dateien löschen, auch im Fehlerfall.

## 8. Sicherheit

- Der API-Key liegt in der `darktablerc` des Benutzers (unverschlüsselt,
  wie alle Darktable-Voreinstellungen). `pass` oder der Secret Service sind
  aus der Flatpak-Sandbox nicht erreichbar. Deshalb: eigener Key mit
  Minimalrechten, jederzeit in Immich widerrufbar.
- Key und Body nie auf der Kommandozeile (Prozessliste), sondern über
  Dateien im Darktable-Temp-Ordner, die nach dem Aufruf gelöscht werden.
- Nutzereingaben gelangen ausschließlich über den JSON-Encoder in die
  Anfrage, nie in die Shell-Zeile. Der Tag-Name wird auf einen
  Zeichenvorrat ohne `|` und Steuerzeichen reduziert.
- Pfadabbildung nur als Präfixtausch mit Plausibilitätsprüfung; es wird
  nur importiert, was nach der Abbildung als Datei existiert.
- Zeitlimit, kein Folgen auf Weiterleitungen (`--max-redirs 0`),
  Systemzertifikate bei HTTPS.
- Keine Schreibzugriffe auf Immich in der ersten Stufe.

## 9. Repository und Installation

Ablage: `~/dev-silentium/immich-for-darktable`, GitHub `jgorres/immich-for-darktable` (privat).

```
immich-for-darktable/
├── immich_search.lua      Skript (ein File, JSON-Parser eingebettet)
├── konzept.md
├── README.md
├── docs/                  Screenshots, Anleitung (später)
└── LICENSE                offen, siehe 12.
```

Entwicklung auf silentium: Symlink
`~/.var/app/org.darktable.Darktable/config/darktable/lua/immich-for-darktable`
auf das Repo; Script-Manager zeigt die Datei als eigene Kategorie und kann
sie starten, stoppen und neu laden. Alternativ in `luarc`:
`require "immich-for-darktable/immich_search"`.

Verteilung später: Script-Manager, Aktion „zusätzliche Skripte installieren“
mit der Repo-URL (setzt ein öffentliches Repo voraus) oder Kopie der
einen Datei.

## 10. Tests (Abnahme auf silentium, Flatpak)

Vorbereitung: eigener API-Key in Immich, Wegwerf-Tag-Präfix
`darktable|immich-test`, danach Tags und importierte Wegwerf-Bilder entfernen.

| Nr. | Fall | Erwartung |
|---|---|---|
| 1 | Verbindung prüfen mit gültigem Key | Version wird angezeigt |
| 2 | Falscher Key | Meldung „API-Key oder Rechte“, kein Import |
| 3 | Server gestoppt | Meldung „nicht erreichbar“ nach Zeitlimit |
| 4 | Smart-Suche „Hund am Strand“, Limit 20 | 20 Bilder in der Sammlung, Tag gesetzt |
| 5 | Zweite Suche | Sammlung zeigt nur das neue Ergebnis |
| 6 | Metadaten: Dateiname, Datum, Kamera | nur passende Treffer |
| 7 | Treffer aus dem Upload-Ordner | per zweiter Abbildung importiert |
| 8 | Abbildung entfernt | Treffer werden gezählt, nicht importiert |
| 9 | Video im Ergebnis | ausgefiltert |
| 10 | „Ersten Treffer öffnen“ | Dunkelkammer öffnet sich |
| 11 | Skript per Script-Manager stoppen/starten | Modul verschwindet und kommt sauber zurück |

## 11. Ausbaustufen

1. **Rückweg:** Button „In Immich zeigen“ für das gewählte Bild, Suche per
   `originalFileName`, Browser öffnet `/photos/<id>`.
2. **Personen, Alben, Tags** als Auswahllisten, geladen aus der API
   (`person.read`, `album.read`, `tag.read`).
3. **Download-Modus** für Rechner ohne Freigabe: Original nach
   `download_dir`, dann Import; mit Hinweis, dass Bearbeitungen lokal bleiben.
4. **Seitenweise nachladen** (`nextPage`).
5. **Übersetzung** de_DE über den Mechanismus der lua-scripts (`gettext`).

## 12. Offene Punkte

- Lizenz: dtutils aus lua-scripts steht unter GPL-3.0; das Skript müsste
  dann GPL-3.0-or-later werden (statt GPL-2.0-or-later wie die WordPress-Projekte).
- Genaue Mindest-API-Version (Darktable 5.0 = ?); in der Umsetzung ermitteln.
- Immich-API-Key für das Skript anlegen (nur `asset.read`).
- Zeichenvorrat für den Tag aus dem Suchbegriff (Umlaute erlauben?).
- Obergrenze des Limits (200?) nach Messung der Importdauer festlegen.

## 13. Änderungen

| Version | Datum | Änderung |
|---|---|---|
| 0.1.0 | 04.11.2026 | Erstfassung nach Analyse der Flatpak-Umgebung und der Immich-API v3.3.5 |
