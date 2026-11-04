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
  query = "", mode = 1, date_from = "", date_to = "", make = "", model = "",
  favorites = false, rating = 0, limit = 50, open_first = false,
}
local function with(overrides)
  local p = {}
  for k, v in pairs(base) do p[k] = v end
  for k, v in pairs(overrides) do p[k] = v end
  return p
end
local ep, body, berr = I.build_request(with({}))
check(ep == nil and berr ~= nil and body == nil, "smart search without text is rejected")
ep, body = I.build_request(with({
  query = "dog", date_from = "2020-01-01", date_to = "2020-12-31", make = "Canon", favorites = true, rating = 3,
}))
check(ep == "/api/search/smart" and body.query == "dog" and body.size == 50 and body.type == "IMAGE", "smart request basics")
check(body.takenAfter == "2020-01-01T00:00:00.000Z" and body.takenBefore == "2020-12-31T23:59:59.999Z", "date filters as ISO timestamps")
check(body.make == "Canon" and body.isFavorite == true and body.rating == 3 and body.model == nil, "optional filters only when set")
ep, body = I.build_request(with({ mode = 2, query = "IMG_2" }))
check(ep == "/api/search/metadata" and body.originalFileName == "IMG_2" and body.query == nil, "metadata request uses originalFileName")
ep, body = I.build_request(with({ mode = 2 }))
check(ep == "/api/search/metadata" and body.originalFileName == nil, "metadata request without text is allowed")
ep, body, berr = I.build_request(with({ mode = 2, date_from = "1.2.2020" }))
check(ep == nil and body == nil and berr ~= nil, "malformed date is rejected")

-- settings -----------------------------------------------------------------
stub.prefs["immich_search/api_key"] = ""
local s, serr = I.load_settings()
check(s == nil and serr ~= nil, "missing API key is reported")
stub.prefs["immich_search/api_key"] = "abc"
stub.prefs["immich_search/server_url"] = "silentium:2283"
s, serr = I.load_settings()
check(s == nil and serr ~= nil, "URL without scheme is rejected")
stub.prefs["immich_search/server_url"] = "http://silentium:2283/"
s = I.load_settings()
check(s and s.server_url == "http://silentium:2283" and s.timeout == 30, "trailing slash removed, defaults applied")

-- unreachable server (no live access needed) --------------------------------
stub.prefs["immich_search/server_url"] = "http://127.0.0.1:9"
stub.prefs["immich_search/timeout"] = 5
local data, rerr = I.api_request(I.load_settings(), "/api/server/version")
check(data == nil and rerr and rerr:find("not reachable", 1, true), "connection refused is reported as not reachable: " .. tostring(rerr))

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

  stub.prefs["immich_search/api_key"] = "wrong-key"
  I.check_connection()
  status = I.widgets.status.label
  check(status:find("rejected", 1, true), "wrong key is reported: " .. status)
  stub.prefs["immich_search/api_key"] = key

  I.run_search(with({ query = "dog", limit = 5 }))
  status = I.widgets.status.label
  check(status:find("^5 of 5 hits shown"), "smart search imports five hits: " .. status)
  check(#stub.imported == 5, "five images imported")
  local rule = stub.collection_rules[1]
  check(rule.data == "darktable|immich|dog" and rule.item == "DT_COLLECTION_PROP_TAG", "collection rule set to the result tag")
  check(stub.tags["darktable|immich|dog"] and #stub.tags["darktable|immich|dog"] == 5, "five images carry the tag")

  I.run_search(with({ query = "dog", limit = 3 }))
  check(#stub.tags["darktable|immich|dog"] == 3, "second search detaches previous hits first")

  I.run_search(with({ mode = 2, query = "IMG_2", limit = 2, open_first = true }))
  check(stub.displayed ~= nil and stub.displayed.path:find("IMG_2", 1, true), "metadata search opens first hit")

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
