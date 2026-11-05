--[[
  Test harness for immich_search.lua, run with:
      lua5.4 tests/run.lua [--live]
  Without --live only the pure logic is tested. With --live the harness
  reads the API key from `pass show immich/darktable-api-key`, calls the
  real Immich server and runs one search end to end (imports are stubbed).
]]

local live = arg[1] == "--live"

package.path = "./tests/?.lua;" .. package.path
local stub = require "darktable_stub"
local script = dofile("immich_search.lua")
local I = script.internal

local failures = 0
local function check(cond, msg)
  if cond then
    print("ok   " .. msg)
  else
    failures = failures + 1
    print("FAIL " .. msg)
  end
end

-- path mapping -------------------------------------------------------------
local map, err = I.parse_path_map("/mnt/media/bilder=/mnt/home2/jgorres/Bilder;/data=/mnt/home2/immich/library")
check(map and #map == 2 and not err, "parse_path_map accepts two entries")
check(I.map_path(map, "/mnt/media/bilder/2020/a b/c.NEF") == "/mnt/home2/jgorres/Bilder/2020/a b/c.NEF", "map_path maps library prefix")
check(I.map_path(map, "/data/upload/x.jpg") == "/mnt/home2/immich/library/upload/x.jpg", "map_path maps upload prefix")
check(I.map_path(map, "/mnt/media/bilderx/y.jpg") == nil, "map_path rejects partial prefix match")
check(I.map_path(map, "/elsewhere/y.jpg") == nil, "map_path returns nil without mapping")
check(select(2, I.parse_path_map("/a=")) ~= nil, "parse_path_map rejects empty host")
check(select(2, I.parse_path_map("/a/../b=/x")) ~= nil, "parse_path_map rejects '..'")
check(select(2, I.parse_path_map("a=/x")) ~= nil, "parse_path_map requires leading slash")
check(select(2, I.parse_path_map("")) ~= nil, "parse_path_map rejects empty spec")

-- tag names ----------------------------------------------------------------
check(I.result_tag_name("darktable|immich", "Hund am Strand", 1) == "darktable|immich|Hund am Strand", "tag name from query")
check(I.result_tag_name("darktable|immich", "a|b\tc", 1) == "darktable|immich|a b c", "tag name strips pipes and control chars")
check(I.result_tag_name("darktable|immich", "", 2) == "darktable|immich|metadata", "tag name for empty metadata query")
check(I.result_tag_name("darktable|immich", "", 1) == "darktable|immich|smart", "tag name for empty smart query")
local long = string.rep("ü", 70)
local tn = I.result_tag_name("p", long, 1)
check(utf8.len(tn) == 2 + 60, "tag name truncated to 60 characters at UTF-8 boundary")

-- request building ---------------------------------------------------------
local base = {
  query = "", mode = 1, date_from = "", date_to = "", make = "", model = "", ocr = "",
  favorites = false, rating = 0, limit = 50, open_first = false,
}
local function with(overrides)
  local p = {}
  for k, v in pairs(base) do p[k] = v end
  for k, v in pairs(overrides) do p[k] = v end
  return p
end
local ep, body, berr, fallback = I.build_request(with({}))
check(ep == nil and berr ~= nil and body == nil and not fallback, "smart search without text and filters is rejected")
ep, body, berr, fallback = I.build_request(with({ ocr = "Feuerwehr" }))
check(ep == "/api/search/metadata" and body.ocr == "Feuerwehr" and body.query == nil and berr == nil and fallback == true,
  "smart mode without text but with a filter falls back to the filter search")
ep, body, berr, fallback = I.build_request(with({ query = "dog" }))
check(ep == "/api/search/smart" and body.query == "dog" and berr == nil and fallback == false, "smart mode with text stays smart")
ep, body = I.build_request(with({
  query = "dog", date_from = "2020-01-01", date_to = "2020-12-31", make = "Canon", favorites = true, rating = 3,
}))
check(ep == "/api/search/smart" and body.query == "dog" and body.size == 50 and body.type == "IMAGE", "smart request basics")
check(body.takenAfter == "2020-01-01T00:00:00.000Z" and body.takenBefore == "2020-12-31T23:59:59.999Z", "date filters as ISO timestamps")
check(body.make == "Canon" and body.isFavorite == true and body.rating == 3 and body.model == nil and body.ocr == nil,
  "optional filters only when set")
ep, body = I.build_request(with({ mode = 2, ocr = "ticket" }))
check(ep == "/api/search/metadata" and body.ocr == "ticket" and body.originalFileName == nil, "OCR filter is passed through")
check(I.widgets.limit.hard_max == 200 and I.widgets.limit.soft_max == 200, "hit limit capped at 200")
ep, body = I.build_request(with({ mode = 2, query = "IMG_2" }))
check(ep == "/api/search/metadata" and body.originalFileName == "IMG_2" and body.query == nil, "metadata request uses originalFileName")
ep, body = I.build_request(with({ mode = 2 }))
check(ep == "/api/search/metadata" and body.originalFileName == nil, "metadata request without text is allowed")
ep, body, berr = I.build_request(with({ mode = 2, date_from = "1.2.2020" }))
check(ep == nil and body == nil and berr ~= nil, "malformed date is rejected")

-- settings -----------------------------------------------------------------
check(stub.textdomain and stub.textdomain.domain == "immich_search" and stub.textdomain.dir:find("/locale/$"),
  "text domain bound to the script's locale folder: " .. tostring(stub.textdomain and stub.textdomain.dir))
check(stub.prefs["immich_search/server_url"] == "" and stub.prefs["immich_search/path_map"] == "",
  "server URL and path mapping default to empty")
local s, serr = I.load_settings()
check(s == nil and serr and serr:find("server URL is not set", 1, true), "empty server URL is reported with a hint")
stub.prefs["immich_search/server_url"] = "silentium:2283"
s, serr = I.load_settings()
check(s == nil and serr and serr:find("invalid", 1, true), "URL without scheme is rejected")
stub.prefs["immich_search/server_url"] = "http://silentium:2283/"
stub.prefs["immich_search/api_key"] = ""
s, serr = I.load_settings()
check(s == nil and serr and serr:find("API key is not set", 1, true), "missing API key is reported with a hint")
stub.prefs["immich_search/api_key"] = "abc"
s, serr = I.load_settings()
check(s == nil and serr and serr:find("path mapping is not set", 1, true), "empty path mapping is reported with a hint")
stub.prefs["immich_search/path_map"] = "/mnt/media/bilder=/mnt/home2/jgorres/Bilder;/data=/mnt/home2/immich/library"
s = I.load_settings()
check(s and s.server_url == "http://silentium:2283" and s.timeout == 30, "trailing slash removed, defaults applied")

-- unreachable server (no live access needed) --------------------------------
stub.prefs["immich_search/server_url"] = "http://127.0.0.1:9"
stub.prefs["immich_search/timeout"] = 5
local data, rerr = I.api_request(I.load_settings(), "/api/server/version")
check(data == nil and rerr and rerr:find("not reachable", 1, true), "connection refused is reported as not reachable: " .. tostring(rerr))

-- guard, button lock and dispatch (no live access needed) ------------------
local before = #stub.imported
I.widgets.query.text = "dog"
I.widgets.search.clicked_callback()
I.widgets.query.text = ""
check(stub.dispatched == 1, "search button hands the work to dt.control.dispatch")
check(I.widgets.status.label:find("not reachable", 1, true), "failed search reports in the status line: " .. I.widgets.status.label)
check(#stub.imported == before, "failed search imports nothing")
check(I.widgets.search.sensitive == true and I.widgets.check.sensitive == true and I.state.busy == false,
  "buttons are unlocked and busy flag cleared after a failed search")
check(stub.jobs[#stub.jobs].text == "Immich search running ..." and stub.jobs[#stub.jobs].valid == false,
  "text-only search job is created and closed again")

I.state.busy = true
I.run_search(with({ query = "dog" }))
check(stub.log[#stub.log] == "a request is already running", "second start while busy is rejected")
I.state.busy = false

local real_read = stub.dt.preferences.read
local seen_busy = {}
stub.dt.preferences.read = function()
  seen_busy = { label = I.widgets.search.label, name = I.widgets.status.name, sensitive = I.widgets.search.sensitive }
  error("boom")
end
I.widgets.check.clicked_callback()
stub.dt.preferences.read = real_read
check(seen_busy.label == "searching ..." and seen_busy.name == "immich_search_busy" and seen_busy.sensitive == false,
  "while a request runs the search button reads 'searching ...' and the status line is named immich_search_busy")
check(I.widgets.search.label == "search" and I.widgets.status.name == "immich_search_status",
  "button label and status name are restored afterwards")
check(I.widgets.status.label:find("internal error", 1, true) and I.widgets.status.label:find("boom", 1, true),
  "Lua error inside the worker is reported: " .. I.widgets.status.label)
check(I.widgets.search.sensitive == true and I.state.busy == false, "buttons are unlocked after an internal error")

-- status highlight installer (writes user.css in a throw-away folder) -----
local css_dir = os.tmpname()
os.remove(css_dir)
os.execute("mkdir -p '" .. css_dir .. "'")
local real_config_dir = stub.dt.configuration.config_dir
stub.dt.configuration.config_dir = css_dir
local css_path = css_dir .. "/user.css"
local function read_css()
  local f = io.open(css_path, "rb")
  if not f then return nil end
  local c = f:read("a")
  f:close()
  return c
end
local function count(text, needle)
  local n, pos = 0, 1
  while true do
    local b, e = text:find(needle, pos, true)
    if not b then return n end
    n, pos = n + 1, e + 1
  end
end

local f = assert(io.open(css_path, "wb"))
f:write("/* mine */\nbody { margin: 0; }")
f:close()

stub.prefs["darktable/themes/usercss"] = false
I.install_highlight()
local css = read_css()
check(I.widgets.status.label:find("enable 'modify theme with CSS tweaks'", 1, true),
  "first install with the switch off points to the preferences: " .. I.widgets.status.label)
check(css:find("/* mine */\nbody { margin: 0; }\n\n/* immich_search: status highlight (begin) */", 1, true) ~= nil,
  "existing user.css content is kept and the block appended")
check(css:find("#immich_search_busy {\n    background-color: #f6c90e;", 1, true) ~= nil, "default colour written")
check(stub.prefs["darktable/themes/usercss"] == false, "script does not try to set the core switch")

I.install_highlight()
check(I.widgets.status.label:find("enable 'modify theme", 1, true) and read_css() == css,
  "with the switch still off the hint is repeated, file unchanged")

stub.prefs["darktable/themes/usercss"] = true
I.install_highlight()
check(I.widgets.status.label == "status highlight is already installed" and read_css() == css,
  "with the switch on and the block present nothing changes")

stub.prefs["immich_search/highlight_color"] = "#FFCC00"
I.install_highlight()
css = read_css()
check(count(css, "status highlight (begin)") == 1 and css:find("background-color: #ffcc00;", 1, true) ~= nil,
  "colour change replaces the block in place")
check(I.widgets.status.label:find("restart darktable", 1, true), "with the switch on a restart is requested: " .. I.widgets.status.label)
check(css:find("/* mine */", 1, true) == 1, "other content still first")

stub.prefs["immich_search/highlight_color"] = "yellow"
I.install_highlight()
check(I.widgets.status.label:find("hex value", 1, true) and read_css() == css, "invalid colour is rejected without writing")

stub.prefs["immich_search/highlight_color"] = "#f6c90e"
stub.prefs["darktable/themes/usercss"] = nil
stub.dt.configuration.config_dir = real_config_dir
os.execute("rm -rf '" .. css_dir .. "'")

-- live -----------------------------------------------------------------------
if live then
  local p = io.popen("pass show immich/darktable-api-key | head -1")
  local key = p:read("l")
  p:close()
  stub.prefs["immich_search/api_key"] = key
  stub.prefs["immich_search/server_url"] = "http://silentium:2283"
  stub.prefs["immich_search/timeout"] = 60

  I.check_connection()
  local status = I.widgets.status.label
  check(status:find("API key accepted", 1, true), "check_connection: " .. status)
  check(status:find("smart search: on", 1, true), "feature flags reported in check_connection")

  stub.prefs["immich_search/api_key"] = "wrong-key"
  I.check_connection()
  status = I.widgets.status.label
  check(status:find("rejected", 1, true), "wrong key is reported: " .. status)
  stub.prefs["immich_search/api_key"] = key

  I.run_search(with({ query = "dog", limit = 5 }))
  status = I.widgets.status.label
  check(status:find("^5 of 5 hits shown"), "smart search imports five hits: " .. status)
  check(status:find("%(server %d+ s, import %d+ s%)$"), "status line ends with the timing: " .. status)
  check(#stub.imported == 5, "five images imported")
  local rule = stub.collection_rules[1]
  check(rule.data == "darktable|immich|dog" and rule.item == "DT_COLLECTION_PROP_TAG", "collection rule set to the result tag")
  check(stub.tags["darktable|immich|dog"] and #stub.tags["darktable|immich|dog"] == 5, "five images carry the tag")

  I.run_search(with({ query = "dog", limit = 3 }))
  check(#stub.tags["darktable|immich|dog"] == 3, "second search detaches previous hits first")

  I.run_search(with({ mode = 2, query = "IMG_2", limit = 2, open_first = true }))
  check(stub.view == "darkroom" and stub.selection[1] and stub.selection[1].path:find("IMG_2", 1, true),
    "metadata search selects first hit and enters the darkroom")
  stub.view = "lighttable"

  stub.prefs["immich_search/path_map"] = "/nowhere=/tmp"
  I.run_search(with({ query = "dog", limit = 2 }))
  status = I.widgets.status.label
  check(status:find("0 of 2 hits shown, 2 without mapping", 1, true), "unmapped hits are counted: " .. status)
end

-- leftovers ----------------------------------------------------------------
local tmp = io.popen("ls " .. stub.dt.configuration.tmp_dir .. " | grep -c '^immich_search_' ")
local leftover = tonumber(tmp:read("l")) or 0
tmp:close()
check(leftover == 0, "no temporary files left behind")

print(failures == 0 and "ALL OK" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
