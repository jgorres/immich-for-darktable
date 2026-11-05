# Immich for Darktable

Lua script for darktable: search [Immich](https://immich.app) directly from
the lighttable, either by image content (smart search, CLIP) or by metadata,
show the hits as a collection and edit the originals in the darkroom.
darktable works on the original files; edits stay in the XMP sidecars that
Immich picks up on its next library scan.

Status: 0.3.0, working on the author's setup (darktable 5.6.2 Flatpak,
Immich v3.3.5). Design notes in `concept.md`. UI in English and German.

## Requirements

- darktable 5.0 or newer (Lua API 9.3.0+), Lua enabled
- `curl` 7.76 or newer in the PATH (Linux desktops, macOS and Windows 10/11
  ship it)
- an Immich API key with the single permission `asset.read`
- the originals must be reachable from the machine running darktable, on a
  local disk or a network share

The focus is the Flatpak installation on Linux. The script avoids
Linux-only assumptions (curl as the only dependency, pure-Lua JSON, helper
functions from darktable's lua-scripts for Windows command handling), but
only Linux has been tested so far.

## Installation

1. Copy `immich_search.lua` together with the `locale/` folder to
   `<darktable config>/lua/immich-for-darktable/`
   (Flatpak: `~/.var/app/org.darktable.Darktable/config/darktable/lua/`),
   or clone/symlink this repository there. The translations are looked up
   in `locale/<lang>/LC_MESSAGES/immich_search.mo` next to the script.
2. Add to `luarc` in the darktable config folder:

   ```lua
   require "immich-for-darktable/immich_search"
   ```

   Alternatively start the script from the script manager.
3. In Immich, create an API key (account settings > API keys) with the
   permission `asset.read` only.
4. In darktable, open preferences > lua options and set:

   | Setting | Meaning |
   |---|---|
   | server URL | e.g. `http://immich.example:2283`, no trailing slash (empty by default) |
   | API key | the key from step 3 |
   | path mapping | `CONTAINER=HOST;CONTAINER=HOST`, see below (empty by default) |
   | tag prefix | parent tag for result tags, default `darktable\|immich` |
   | timeout | seconds per request, default 30 |

### Path mapping

Immich reports the path of each original as seen inside its container.
The mapping translates that prefix into a local path. For an external
library mounted as `/mnt/media/bilder` in the container and available as
`/mnt/home2/jgorres/Bilder` locally, plus the upload folder:

```
/mnt/media/bilder=/mnt/home2/jgorres/Bilder;/data=/mnt/home2/immich/library
```

On Windows the host side may be a drive letter, e.g. `/mnt/media/bilder=Z:\Bilder`.

## Usage

Lighttable > module "Immich search":

- enter a search text, pick the mode (smart or metadata), set filters
  (date range, camera make/model, text recognised in the image, favourites,
  rating) and the maximum number of hits (up to 200), press **search**
- smart mode without a search text but with at least one filter runs a
  filter search instead; the status line says so
- the hits are imported, tagged `<tag prefix>|<query>` and shown as the
  current collection; **open first hit in the darkroom** does what it says
- **restore previous collection** returns to the collection that was
  active before the first search
- **check connection** verifies server, version and API key and reports
  whether smart search and OCR are enabled on the server
- while a request runs, the left panel shows a background job ("Immich
  search running ...", then a progress bar for the import that can be
  cancelled there), **search** and **check connection** are locked, and the
  status line ends with the seconds spent on the server and on the import

Notes: smart search always returns as many hits as requested when enough
assets exist. The file name filter in metadata mode is a case-insensitive
substring match. Hits darktable cannot import (e.g. SVG) are counted as
skipped and logged (`darktable -d lua`).

## Security

- The API key is stored in `darktablerc` like every darktable preference.
  Use a dedicated key with `asset.read` only and revoke it in Immich if needed.
- Key and request body are handed to curl through temporary files, never
  on the command line; user input never reaches the shell.

## Development

```
luac5.4 -p immich_search.lua && luacheck immich_search.lua tests/
lua5.4 tests/run.lua          # logic tests against a darktable stub
lua5.4 tests/run.lua --live   # same, against the real server (key from pass)
```

Translations (gettext, text domain `immich_search`):

```
xgettext -L Lua -k_ -kdgettext:2 --from-code=UTF-8 -o locale/immich_search.pot immich_search.lua
msgmerge -U locale/de_DE/LC_MESSAGES/immich_search.po locale/immich_search.pot
msgfmt -c --statistics -o locale/de_DE/LC_MESSAGES/immich_search.mo locale/de_DE/LC_MESSAGES/immich_search.po
```

The `.mo` files are committed so that a plain copy of the folder works.

## Licence

GPL-3.0-or-later. Embeds [json.lua](https://github.com/rxi/json.lua) by rxi (MIT).
