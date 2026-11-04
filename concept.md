# Immich for Darktable – Concept

Version: 0.1.1
Date: 2026-11-04
Status: draft, no code yet

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
| darktable | Flatpak `org.darktable.Darktable` 5.6.2, embedded Lua 5.4, script manager active |
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
  (target: darktable 5.0; the exact API number is determined during
  implementation via `dt.configuration.api_version_string`).
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
Set collection rule to the tag (dt.gui.libs.collect.set_rules)
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
| POST | `/api/search/smart` | free text (CLIP) with optional filters | asset.read |
| POST | `/api/search/metadata` | pure filter search without free text | asset.read |
| GET | `/api/assets/{id}/original` | download mode only | asset.download |

### 4.3 Fields used

Request (`SmartSearchDto` or `MetadataSearchDto`), first stage:
`query` (smart only), `originalFileName` (metadata only), `takenAfter`,
`takenBefore`, `make`, `model`, `isFavorite`, `rating`, `type` = `IMAGE`,
`size`, `page`, `withExif` = true.

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
| `dt.gui.libs.collect.new_rule` / `set_rules` | filter the lighttable by tag (`DT_COLLECTION_PROP_TAG`) |
| `dt.gui.views.darkroom.display_image` | open first hit |
| `dt.gui.create_job` | progress, cancel |
| `dt.print`, `dt.print_log` | status messages, log |
| `du.check_min_api_version`, `script_data` (destroy/restart) | script manager compliance |

## 6. Module and user interface

Widget order, top to bottom:

1. Query (entry; Return triggers the search).
2. Mode: "Smart (image content)" or "Metadata". In "Metadata" mode the entry
   acts as a file name filter.
3. Taken from / to (ISO date, empty = none).
4. Camera (make/model, empty = none).
5. Favourites only (toggle), minimum rating (0–5).
6. Hits (slider 1–200, default 50).
7. Open first hit after the search (toggle).
8. Buttons: "Search", "Check connection".
9. Status line.

Settings (darktable preferences, tab Lua options):

| Key | Type | Default | Meaning |
|---|---|---|---|
| `server_url` | string | `http://silentium:2283` | without trailing slash |
| `api_key` | string | empty | Immich API key (see 8.) |
| `path_map` | string | `/mnt/media/bilder=/mnt/home2/jgorres/Bilder;/data=/mnt/home2/immich/library` | container prefix=host prefix, several separated by `;` |
| `tag_prefix` | string | `darktable|immich` | parent path of the result tag |
| `download_mode` | bool | off | extension: download originals instead of mapping |
| `download_dir` | directory | empty | target folder in download mode |
| `timeout` | integer | 30 | seconds for curl `--max-time` |

The path mapping is validated on load: every entry needs both sides, the
host side must exist, `..` is rejected. Hits whose `originalPath` matches no
prefix are counted and reported in the status line.

## 7. Search flow

1. Validate settings (URL, key, curl present); on error show a message, no
   request.
2. Build the request body as a Lua table, encode it to JSON with the
   embedded encoder and write it to a temporary file; write a header file
   with `x-api-key`, `Content-Type`, `Accept`.
3. Run curl: `--silent --show-error --fail-with-body --max-time N
   -H @header --data @body -o response URL`. No `--insecure`.
4. Evaluate exit code and HTTP status; report 401/403 as "API key or
   permissions", 0/7/28 as "server not reachable".
5. Parse the response, filter items (type, offline), map paths.
6. Create the result tag `<tag_prefix>|<sanitised query>`; detach it from
   images that still carry it so the collection shows only the current result.
7. Per hit: `dt.database.import`, attach tag, report progress.
8. Set the collection rule (mode AND, item TAG, data = tag path).
9. Status line and `dt.print` with counters; optionally open the first hit.
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

Location: `~/dev-silentium/immich-for-darktable`, GitHub `jgorres/immich-for-darktable` (private).

```
immich-for-darktable/
├── immich_search.lua      script (single file, JSON parser embedded)
├── concept.md
├── README.md
├── docs/                  screenshots, manual (later)
└── LICENSE                open, see 12.
```

Development on silentium: symlink
`~/.var/app/org.darktable.Darktable/config/darktable/lua/immich-for-darktable`
to the repository; the script manager lists the file as its own category
and can start, stop and reload it. Alternatively in `luarc`:
`require "immich-for-darktable/immich_search"`.

Distribution later: script manager, action "install additional scripts"
with the repository URL (requires a public repository), or a copy of the
single file.

## 10. Tests (acceptance on silentium, Flatpak)

Preparation: dedicated API key in Immich, throwaway tag prefix
`darktable|immich-test`; afterwards remove tags and imported throwaway images.

| No. | Case | Expectation |
|---|---|---|
| 1 | Check connection with valid key | version is shown |
| 2 | Wrong key | message "API key or permissions", no import |
| 3 | Server stopped | message "not reachable" after timeout |
| 4 | Smart search "dog on the beach", limit 20 | 20 images in the collection, tag set |
| 5 | Second search | collection shows only the new result |
| 6 | Metadata: file name, date, camera | only matching hits |
| 7 | Hit from the upload folder | imported via the second mapping |
| 8 | Mapping removed | hits are counted, not imported |
| 9 | Video in the result | filtered out |
| 10 | "Open first hit" | darkroom opens |
| 11 | Stop/start the script via script manager | module disappears and returns cleanly |

## 11. Extensions

1. **Reverse direction:** button "Show in Immich" for the selected image,
   search by `originalFileName`, browser opens `/photos/<id>`.
2. **People, albums, tags** as selection lists loaded from the API
   (`person.read`, `album.read`, `tag.read`).
3. **Download mode** for machines without a share: original to
   `download_dir`, then import; with a note that edits stay local.
4. **Paging** (`nextPage`).
5. **Translation** de_DE via the lua-scripts mechanism (`gettext`).

## 12. Open points

- Licence: dtutils from lua-scripts is GPL-3.0; the script would then have to
  be GPL-3.0-or-later (instead of GPL-2.0-or-later like the WordPress projects).
- Exact minimum API version (darktable 5.0 = ?); determine during implementation.
- Create the Immich API key for the script (`asset.read` only).
- Character set for the tag derived from the query (allow umlauts?).
- Upper bound of the limit (200?) after measuring import duration.

## 13. Changes

| Version | Date | Change |
|---|---|---|
| 0.1.0 | 2026-11-04 | First version after analysing the Flatpak environment and the Immich API v3.3.5 |
| 0.1.1 | 2026-11-04 | Documentation language switched to English, file renamed to `concept.md` |
