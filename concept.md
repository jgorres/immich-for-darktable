# Immich for Darktable – Concept

Version: 0.1.10
Date: 2026-11-05
Status: implemented as immich_search.lua 0.3.2

## 1. Goal

A Lua script for darktable that sends a search to Immich from the
lighttable (free text via CLIP or metadata filters), shows the results as a
collection in the lighttable and makes the images directly editable in the
darkroom. darktable works on the original files, not on copies. Edits end
up in the XMP sidecar next to the original as usual, and Immich picks the
sidecar up on its next library scan.

### Out of scope

- No changes to Immich, no uploads, no write access to assets.
- No separate thumbnail browser: darktable shows its own thumbnails.
- No darktable extension in C; darktable only offers the Lua API.

## 2. Constraints

### 2.1 Target environment (focus)

| Item | Finding (2026-11-04) |
|---|---|
| darktable | Flatpak `org.darktable.Darktable` 5.6.2, embedded Lua 5.4, Lua API 9.7.0, script manager active |
| Flatpak permissions | `shared=network`, `filesystems=host`, host image folder readable |
| Tools inside the sandbox | `curl` 8.21 (OpenSSL), `git`; no Lua libraries (no luasocket, luasec, dkjson) |
| Script folder | `~/.var/app/org.darktable.Darktable/config/darktable/lua/` (checkout of darktable/lua-scripts) |
| Immich | v3.3.5 at `http://silentium:2283`, LAN only, HTTP |
| Path mapping, external library | host `/mnt/home2/jgorres/Bilder` ↔ container `/mnt/media/bilder` (ro) |
| Path mapping, uploads | host `/mnt/home2/immich/library` ↔ container `/data` |

### 2.2 Portability (requirement)

The script must also run unchanged with darktable from apt (Debian 13:
5.0.1), on Windows and on macOS. Consequences:

- The only external dependency is `curl` (shipped with Windows 10+, macOS
  and desktop Linux). No Lua HTTP library.
- JSON parser in pure Lua, embedded in the script file (rxi/json.lua, MIT,
  attribution in the header). One file, one installation path.
- External calls go through `dtutils.system.external_command`, which wraps
  the Windows specifics (cmd, quoting).
- Temporary files live in `dt.configuration.tmp_dir`, path separators are
  normalised, drive letters are allowed in the path mapping.
- The minimum API version is checked with `du.check_min_api_version`
  (9.3.0, i.e. darktable 5.0; darktable 5.6.2 reports 9.7.0).
- On other machines the originals must be reachable through a share
  (SMB/NFS); the path mapping then points at the mount. Without a share the
  optional download mode applies (extension, section 11).

Only the Flatpak installation on silentium is tested. For apt, Windows and
macOS: defensive code, no Linux assumptions, verification by review.

## 3. Architecture and data flow

```
Lighttable module "Immich search" (dt.register_lib)
   │ query, filters, limit
   ▼
Build request → JSON body and headers as temporary files
   │
   ▼
curl (dtutils.system.external_command) → POST /api/search/smart|metadata
   │ response as temporary file
   ▼
Parse JSON → list of assets (id, originalPath, originalFileName, exifInfo)
   │
   ▼
Path mapping container → host; count hits without mapping or without a file
   │
   ▼
dt.database.import(path) per hit (known images are returned unchanged)
   │
   ▼
Attach tag "darktable|immich|<query>", detach it from previous hits of the same query
   │
   ▼
Set collection rule to the tag (dt.gui.libs.collect.filter)
   │
   ▼
Status line: n hits, m imported, k without local file
   └─ optional: dt.gui.views.darkroom.display_image(first hit)
```

The search runs inside a darktable job (`dt.gui.create_job`) with a
progress indicator so the UI does not block on large result lists.

## 4. Immich API

Source: OpenAPI specification v3.3.5 from the Immich repository.

### 4.1 Authentication

- Header `x-api-key: <key>`.
- A dedicated API key in Immich for this script only, minimal permissions:
  `asset.read` (search); `person.read` and `tag.read` only once the person
  and tag filters (extension) are used; `asset.download` only in download
  mode.
- The key never appears on the command line: headers are passed via
  `-H @file` from a temporary file, the body via `--data @file`.

### 4.2 Endpoints

| Method | Path | Purpose | Permission |
|---|---|---|---|
| GET | `/api/server/ping` | reachability ("Check connection" button) | none |
| GET | `/api/server/version` | show version, check minimum version | none |
| GET | `/api/server/features` | feature flags `smartSearch`, `ocr` for "check connection" | none |
| POST | `/api/search/smart` | free text (CLIP) with optional filters | asset.read |
| POST | `/api/search/metadata` | pure filter search without free text | asset.read |
| GET | `/api/assets/{id}/original` | download mode only | asset.download |

### 4.3 Fields used

Request (`SmartSearchDto` or `MetadataSearchDto`), first stage:
`query` (smart only), `originalFileName` (metadata only), `takenAfter`,
`takenBefore`, `make`, `model`, `ocr`, `isFavorite`, `rating`, `type` = `IMAGE`,
`size` (capped at 200), `page`, `withExif` = true.

Response (`SearchResponseDto.assets.items[]`, type `AssetResponseDto`):
`id`, `originalPath`, `originalFileName`, `originalMimeType`, `type`,
`fileCreatedAt`, `isOffline`, `exifInfo.{make,model,dateTimeOriginal}`.
Also `assets.total`, `assets.count`, `assets.nextPage`.

Notes:

- Smart search returns a ranked list without a score threshold; it always
  returns `size` hits as long as enough assets exist. The limit is therefore
  visible in the module and defaults to a small value.
- Videos are filtered out (`type` = `IMAGE`).
- Assets with `isOffline` = true are skipped.
- `originalFileName` is a case-insensitive substring match (verified).
- `rating` is an exact match, not a minimum (API semantics).
- Immich counts SVG files as images; darktable cannot import them, so they
  end up in the "skipped" counter with a log entry.
- A 401 response carries only `message`, no `statusCode`; the HTTP status
  is therefore also taken from curl's stderr.

## 5. darktable Lua building blocks

| Building block | Use |
|---|---|
| `dt.register_lib` | lighttable module, container `DT_UI_CONTAINER_PANEL_RIGHT_CENTER` |
| `dt.new_widget` | entry (query), combobox (mode), entry (date from/to, camera), check_button (favourites), slider (limit), button (Search, Check connection, Open first hit), label (status) |
| `dt.preferences.register` | server URL, API key, path mapping, tag prefix, download mode, download folder |
| `dtutils.system.external_command` | portable curl invocation |
| `dtutils.file.check_if_bin_exists` | locate curl, otherwise error message |
| `dt.configuration.tmp_dir` | temporary files |
| `dt.database.import` | bring hits into the library |
| `dt.tags.create`, `dt.tags.attach`, `dt.tags.detach` | maintain the result tag |
| `dt.gui.libs.collect.new_rule` / `filter` | filter the lighttable by tag (`DT_COLLECTION_PROP_TAG`); `filter` returns the previous rules |
| `dt.gui.selection` + `dt.gui.current_view(darkroom)` | open first hit (`display_image` only works inside the darkroom) |
| `dt.gui.create_job` | text-only job in the left panel while the server works; progress bar with cancel during the import |
| `dt.control.dispatch` | runs search and connection check in darktable's Lua background thread; the button callbacks only read the widgets |
| `dt.print`, `dt.print_log` | status messages, log |
| `du.check_min_api_version`, `script_data` (destroy/restart) | script manager compliance |

## 6. Module and user interface

Widget order, top to bottom:

1. Query (entry; darktable entries have no activate callback, so the
   search is started with the button).
2. Mode: "Smart (image content)" or "Metadata". In "Metadata" mode the entry
   acts as a file name filter.
3. Taken from / to (ISO date, empty = none).
4. Camera make, camera model, text in the image (OCR; three entries, empty = none).
5. Favourites only (toggle), rating (combobox any/1–5, exact match).
6. Hits (slider 1–200, default 50).
7. Open first hit after the search (toggle).
8. Buttons: "search", "check connection", "restore previous collection",
   "install status highlight". "search" and "check connection" are
   insensitive while a request runs and the search button then reads
   "searching ...".
9. Status line; after a search it ends with the seconds spent on the
   server and on the import. Its CSS name is `immich_search_status`,
   `immich_search_busy` while a request runs. Lua cannot set colours and
   darktable reads `user.css` only at start-up, so the highlight is an
   explicit opt-in: "install status highlight" appends a marked block
   (`/* immich_search: status highlight (begin|end) */`) to `user.css` in
   the config folder, replaces it when the colour option changed, leaves
   everything else in the file alone. The switch "modify theme with CSS
   tweaks" (`themes/usercss`) cannot be set from Lua: `dt.preferences.read
   ("darktable", key)` reads the core key, but `write` with that script
   name creates `lua/darktable/<key>` instead (verified 2026-11-05 with
   5.6.2, first attempt of 0.3.2). The button therefore only writes the
   file and tells the user to enable the switch in preferences > general;
   saving that dialog applies `user.css` at once, no restart needed. With
   the switch already on, a restart (or re-saving the dialog) applies it.

Settings (darktable preferences, tab Lua options):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `server_url` | string | empty | without trailing slash; the first search explains where to set it |
| `api_key` | string | empty | Immich API key (see 8.) |
| `path_map` | string | empty | container prefix=host prefix, several separated by `;`; examples live in the README |
| `tag_prefix` | string | `darktable|immich` | parent path of the result tag |
| `timeout` | integer | 30 | seconds for curl `--max-time` |
| `highlight_color` | string | `#f6c90e` | background of the status line while a request runs; `#rgb` or `#rrggbb`, written to `user.css` by "install status highlight" |

The path mapping is validated on every search: every entry needs both
sides, the container side starts with `/`, `..` is rejected. Download mode
and its folder are registered only once that extension exists. Hits whose `originalPath` matches no
prefix are counted and reported in the status line.

## 7. Search flow

The button callback reads the widget values on the GTK thread and hands
the rest to `dt.control.dispatch`, so it runs in darktable's Lua
background thread and the interface keeps redrawing (a blocking curl in
the callback froze the whole window, which looked like a crash with 200
hits). A module-level busy flag rejects a second start, the two request
buttons are locked meanwhile, and a Lua error inside the worker is caught
so the module never stays locked.

1. Validate settings (URL, key, curl present); on error show a message, no
   request. Smart mode without a search text uses the metadata endpoint when
   at least one filter is set (status line: "no search text: filter search")
   and reports an error only when nothing at all was entered.
2. Build the request body as a Lua table, encode it to JSON with the
   embedded encoder and write it to a temporary file; write a header file
   with `x-api-key`, `Content-Type`, `Accept`.
3. Run curl: `--silent --show-error --fail-with-body --max-time N
   -H @header --data @body -o response URL`. No `--insecure`. A text-only
   background job "Immich search running ..." is shown meanwhile (no
   cancel: curl cannot be interrupted from Lua).
4. Evaluate exit code and HTTP status; report 401/403 as "API key or
   permissions", 0/7/28 as "server not reachable".
5. Parse the response, filter items (type, offline), map paths.
6. Create the result tag `<tag_prefix>|<sanitised query>` (pipes and control
   characters replaced, at most 60 characters); detach it from images that
   still carry it so the collection shows only the current result.
7. Per hit: `dt.database.import`, attach tag, report progress in a
   background job with progress bar; its cancel button stops the loop.
8. Set the collection rule (mode AND, item TAG, data = tag path); the rules
   active before the first search are kept for "restore previous collection".
9. Status line and `dt.print` with counters and the seconds spent on the
   server and on the import (`os.time()`, one-second resolution; also
   logged); optionally open the first hit.
10. Delete temporary files, also on error.

## 8. Security

- The API key is stored in the user's `darktablerc` (unencrypted, like all
  darktable preferences). `pass` or the Secret Service are not reachable
  from the Flatpak sandbox. Hence: a dedicated key with minimal permissions,
  revocable in Immich at any time.
- Key and body never on the command line (process list) but in files in
  darktable's temp folder, deleted after the call.
- User input reaches the request only through the JSON encoder, never the
  shell line. The tag name is reduced to a character set without `|` and
  control characters.
- Path mapping is a prefix swap with plausibility checks only; only what
  exists as a file after mapping is imported.
- Timeout, no following of redirects (`--max-redirs 0`), system
  certificates for HTTPS.
- No write access to Immich in the first stage.

## 9. Repository and installation

Location: `~/dev-silentium/immich-for-darktable`, GitHub
`jgorres/immich-for-darktable`, public since 2026-11-05.

```
immich-for-darktable/
├── immich_search.lua        script (single file, JSON parser embedded)
├── tests/run.lua            test harness: lua5.4 tests/run.lua [--live]
├── tests/darktable_stub.lua minimal stand-in for the darktable Lua API
├── locale/                  immich_search.pot, de_DE/LC_MESSAGES/*.po|mo
├── .luacheckrc
├── LICENSE                  GPL-3.0 text
├── concept.md
├── README.md
└── docs/                    blog post draft; screenshots, manual (later)
```

Licence: GPL-3.0-or-later (header in the script, full text in `LICENSE`),
because the helpers from darktable/lua-scripts are GPL-3.0. The embedded
json.lua is MIT.

Development on silentium: symlink
`~/.var/app/org.darktable.Darktable/config/darktable/lua/immich-for-darktable`
to the repository; the script manager lists the file as its own category
and can start, stop and reload it. Alternatively in `luarc`:
`require "immich-for-darktable/immich_search"`.

Distribution: script manager, action "install additional scripts" with
the repository URL (possible since the repository is public), or a copy of
the script together with `locale/`.

## 10. Tests

### 10.1 Automated (lua5.4 on silentium)

- `luac5.4 -p immich_search.lua` and `luacheck immich_search.lua tests/`
  (std lua54, config in `.luacheckrc`).
- `lua5.4 tests/run.lua`: pure logic against the stub (path mapping, tag
  names, request building, settings, connection refused, temp files).
- `lua5.4 tests/run.lua --live`: the same harness against the real server,
  API key from `pass show immich/darktable-api-key`; covers connection
  check, wrong key, smart search with import/tag/collection, tag reset on
  the second search, metadata search with "open first hit", unmapped hits.
- The stub exposes `script_data.internal`; widgets, `register_lib`, the
  real import and the collection module are not covered.

### 10.2 Acceptance in the darktable GUI (Flatpak)

Start with `flatpak run org.darktable.Darktable -d lua` and read the log.
The running instance can be driven over D-Bus, which allows most cases to
be triggered without clicking:

```
gdbus call --session --dest org.darktable.service --object-path /darktable \
  --method org.darktable.service.Remote.Lua 'local dt = require "darktable"; ...'
```

State 2026-11-04: all cases passed (1, 4, 5 by clicking; 2 and 8 in the
live harness; 3, 6, 10, 11 over D-Bus; 3 with a closed port and with a
non-routable address, both reported as "not reachable"). Case 10 first
failed because `display_image` does nothing outside the darkroom; fixed in
0.1.1 by selecting the image and switching the view. Cases 7 and 9 are
covered by the path mapping tests and the type filter.

| No. | Case | Expectation |
|---|---|---|
| 1 | Check connection with valid key | version is shown |
| 2 | Wrong key | message "API key or permissions", no import |
| 3 | Server stopped | message "not reachable" after timeout |
| 4 | Smart search "dog", limit 20 | hits in the collection, tag set (19 of 20: one SVG skipped) |
| 5 | Second search | collection shows only the new result |
| 6 | Metadata: file name, date, camera | only matching hits |
| 7 | Hit from the upload folder | imported via the second mapping |
| 8 | Mapping removed | hits are counted, not imported |
| 9 | Video in the result | filtered out |
| 10 | "Open first hit" | darkroom opens |
| 11 | Stop/start the script via script manager | module disappears and returns cleanly |
| 12 | Smart search, limit 200 (0.3.0) | window stays responsive, "Immich search running ..." then the import progress bar in the left panel, buttons locked, timing in the status line; cancel in the panel stops the import |

Case 12 passed on 2026-11-05 with 0.3.0 (smart search, 200 hits, window
stays responsive). The text job in the left panel was found easy to miss,
hence the button label and the CSS names in 0.3.1.

## 11. Extensions

1. **Reverse direction:** button "Show in Immich" for the selected image,
   search by `originalFileName`, browser opens `/photos/<id>`.
2. **People, albums, tags** as selection lists loaded from the API
   (`person.read`, `album.read`, `tag.read`).
2a. **Similar images:** `queryAssetId` in the smart search returns assets
   visually similar to a given one. From darktable: button on the selected
   image, asset id found via `originalFileName`, same path as the reverse
   direction in 1.
2b. **Places:** `/search/places` and `/search/cities` as selection lists for
   a location filter (`city`, `country`, `state` in both search DTOs).
3. **Download mode** for machines without a share: original to
   `download_dir`, then import; with a note that edits stay local.
4. **Paging** (`nextPage`).
5. ~~Translation de_DE~~ done in 0.2.0: text domain `immich_search` bound
   to `locale/` next to the script (`dt.gettext.bindtextdomain` +
   `dgettext`), `.po` and `.mo` in the repository. Plain `dt.gettext.gettext`
   would look in darktable's own domain and never find script strings.

## 12. Open points

- Screenshots for the blog post (`docs/`), then publish the post.
- Extensions from section 11 as needed.

Decided: licence GPL-3.0-or-later; minimum API 9.3.0; API key created
2026-11-04 with `asset.read` only, stored in `pass` and darktablerc;
umlauts are kept in tag names, only `|` and control characters are
replaced; repository made public on 2026-11-05 after a scan of the whole
history for secrets (none; host name and paths of the author appear only
in the live test and as README examples).

## 13. Changes

| Version | Date | Change |
|---|---|---|
| 0.1.0 | 2026-11-04 | First version after analysing the Flatpak environment and the Immich API v3.3.5 |
| 0.1.1 | 2026-11-04 | Documentation language switched to English, file renamed to `concept.md` |
| 0.1.2 | 2026-11-04 | Findings from implementation and first tests: API 9.7.0, `collect.filter`, exact rating, substring file name, SVG hits, 401 body, test harness, licence decided |
| 0.1.3 | 2026-11-04 | GUI acceptance complete via D-Bus; open first hit fixed (script 0.1.1) |
| 0.1.4 | 2026-11-04 | Script 0.2.0: empty defaults with hints, German translation via own text domain |
| 0.1.5 | 2026-11-04 | Script 0.2.1: OCR filter, feature flags in check connection, limit capped at 200 (cross-checked with drolosoft/immich-photo-manager); extensions 2a/2b |
| 0.1.6 | 2026-11-04 | Script 0.2.2: smart mode without text falls back to the filter search |
| 0.1.10 | 2026-11-05 | Repository public with `LICENSE`; sections 9 and 12 updated, open points now screenshots and extensions |
| 0.1.9 | 2026-11-05 | Script 0.3.2: opt-in button "install status highlight" writes a marked CSS block into `user.css`; colour as Lua option; finding: the CSS tweaks switch cannot be set from Lua, the user enables it in preferences > general |
| 0.1.8 | 2026-11-05 | Script 0.3.1: search button reads "searching ..." while a request runs, status line gets CSS names (`immich_search_status` / `immich_search_busy`) for an optional highlight in the CSS tweaks; case 12 passed |
| 0.1.7 | 2026-11-05 | Script 0.3.0: search and connection check run in the background thread (`dt.control.dispatch`), text job while the server works, import progress bar now visible and cancellable, buttons locked during a request, timing in the status line; acceptance case 12 |
