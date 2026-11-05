--[[
  immich_search.lua - search Immich from darktable's lighttable

  Copyright (C) 2026 Jörn Gorres <joern@gorres.com>

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program. If not, see <https://www.gnu.org/licenses/>.

  This file embeds json.lua 0.1.2, Copyright (c) 2020 rxi, MIT License.
  See the section "Embedded JSON library" below for its licence text.
]]

--[[
  IMMICH SEARCH
  Sends a search to an Immich server, either a smart search (CLIP, free
  text describing the image content) or a metadata search (file name,
  date range, camera, favourites, rating). The matching originals are
  imported into darktable's library through a configurable path mapping,
  tagged with "<tag prefix>|<query>" and shown as the current collection,
  so they can be opened in the darkroom right away. darktable works on the
  original files; edits stay in the XMP sidecars next to them.

  REQUIREMENTS
  * darktable 5.0 or newer (Lua API 9.3.0 or newer)
  * curl 7.76 or newer in the PATH (shipped with Linux desktops, macOS and
    Windows 10/11)
  * Immich with API v2 search endpoints (tested with Immich v3.3.5)
  * an Immich API key with the permission "asset.read"
  * the originals must be reachable from this machine (local disk or a
    network share); the path mapping translates Immich's container paths
    into local paths

  INSTALLATION
  * copy this file to <darktable config>/lua/immich-for-darktable/ and add
        require "immich-for-darktable/immich_search"
    to luarc, or start it from the script manager
  * set the preferences under preferences > lua options:
        server URL, API key, path mapping, tag prefix, timeout

  USAGE
  * lighttable > module "Immich search"
  * enter a search text, choose the mode, optionally set filters (date,
    camera, text recognised in the image, favourites, rating), press
    "search"; the lighttable then shows the hits as a collection
  * while Immich searches and darktable imports, the left panel shows a
    background job; the import can be cancelled there, the two request
    buttons are locked meanwhile, the search button reads "searching ..."
    and the status line ends with the time spent on the server and on the
    import
  * "install status highlight" (opt-in) writes a CSS rule into user.css
    that colours the status line while a request runs; the colour is a
    Lua option. The switch "modify theme with CSS tweaks" in
    preferences > general has to be enabled by hand (Lua cannot set it);
    saving that dialog applies the rule at once. The status line carries
    the CSS name immich_search_status, while a request runs
    immich_search_busy.
  * "restore previous collection" brings back the collection that was
    active before the first Immich search
  * "check connection" verifies server, version and API key

  PATH MAPPING
  * format: CONTAINER=HOST;CONTAINER=HOST
  * CONTAINER is the path prefix Immich reports in originalPath (the path
    inside the Immich container), HOST is the corresponding local prefix,
    e.g. /mnt/media/bilder=/mnt/home2/jgorres/Bilder or, on Windows,
    /mnt/media/bilder=Z:\Bilder

  SECURITY
  * the API key is stored in darktablerc like every darktable preference;
    use a dedicated key with the single permission "asset.read"
  * the key and the request body are passed to curl through temporary
    files, never on the command line
  * user input never reaches the shell; it is JSON-encoded into the body
]]

local dt = require "darktable"
local du = require "lib/dtutils"
local df = require "lib/dtutils.file"
local dsys = require "lib/dtutils.system"

local MODULE = "immich_search"
local VERSION = "0.3.2"
local MIN_API = "9.3.0"

du.check_min_api_version(MIN_API, MODULE)

-- Translations live next to the script in locale/<lang>/LC_MESSAGES/<MODULE>.mo,
-- so a copied or cloned folder carries them along on every platform.
local SCRIPT_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)[/\\][^/\\]+$")
  or (dt.configuration.config_dir .. "/lua/immich-for-darktable")
dt.gettext.bindtextdomain(MODULE, SCRIPT_DIR .. "/locale/")

--- Translate a message id in this script's text domain.
-- @param msgid string Message id.
-- @return string Translated text.
local function _(msgid)
  return dt.gettext.dgettext(MODULE, msgid)
end

-- ---------------------------------------------------------------------------
-- Embedded JSON library (json.lua 0.1.2 by rxi, MIT License)
-- ---------------------------------------------------------------------------

local json

-- luacheck: push ignore
do
--
-- json.lua
--
-- Copyright (c) 2020 rxi
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
--

json = { _version = "0.1.2" }

-------------------------------------------------------------------------------
-- Encode
-------------------------------------------------------------------------------

local encode

local escape_char_map = {
  [ "\\" ] = "\\",
  [ "\"" ] = "\"",
  [ "\b" ] = "b",
  [ "\f" ] = "f",
  [ "\n" ] = "n",
  [ "\r" ] = "r",
  [ "\t" ] = "t",
}

local escape_char_map_inv = { [ "/" ] = "/" }
for k, v in pairs(escape_char_map) do
  escape_char_map_inv[v] = k
end


local function escape_char(c)
  return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
end


local function encode_nil(val)
  return "null"
end


local function encode_table(val, stack)
  local res = {}
  stack = stack or {}

  -- Circular reference?
  if stack[val] then error("circular reference") end

  stack[val] = true

  if rawget(val, 1) ~= nil or next(val) == nil then
    -- Treat as array -- check keys are valid and it is not sparse
    local n = 0
    for k in pairs(val) do
      if type(k) ~= "number" then
        error("invalid table: mixed or invalid key types")
      end
      n = n + 1
    end
    if n ~= #val then
      error("invalid table: sparse array")
    end
    -- Encode
    for i, v in ipairs(val) do
      table.insert(res, encode(v, stack))
    end
    stack[val] = nil
    return "[" .. table.concat(res, ",") .. "]"

  else
    -- Treat as an object
    for k, v in pairs(val) do
      if type(k) ~= "string" then
        error("invalid table: mixed or invalid key types")
      end
      table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
    end
    stack[val] = nil
    return "{" .. table.concat(res, ",") .. "}"
  end
end


local function encode_string(val)
  return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
end


local function encode_number(val)
  -- Check for NaN, -inf and inf
  if val ~= val or val <= -math.huge or val >= math.huge then
    error("unexpected number value '" .. tostring(val) .. "'")
  end
  return string.format("%.14g", val)
end


local type_func_map = {
  [ "nil"     ] = encode_nil,
  [ "table"   ] = encode_table,
  [ "string"  ] = encode_string,
  [ "number"  ] = encode_number,
  [ "boolean" ] = tostring,
}


encode = function(val, stack)
  local t = type(val)
  local f = type_func_map[t]
  if f then
    return f(val, stack)
  end
  error("unexpected type '" .. t .. "'")
end


function json.encode(val)
  return ( encode(val) )
end


-------------------------------------------------------------------------------
-- Decode
-------------------------------------------------------------------------------

local parse

local function create_set(...)
  local res = {}
  for i = 1, select("#", ...) do
    res[ select(i, ...) ] = true
  end
  return res
end

local space_chars   = create_set(" ", "\t", "\r", "\n")
local delim_chars   = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
local escape_chars  = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
local literals      = create_set("true", "false", "null")

local literal_map = {
  [ "true"  ] = true,
  [ "false" ] = false,
  [ "null"  ] = nil,
}


local function next_char(str, idx, set, negate)
  for i = idx, #str do
    if set[str:sub(i, i)] ~= negate then
      return i
    end
  end
  return #str + 1
end


local function decode_error(str, idx, msg)
  local line_count = 1
  local col_count = 1
  for i = 1, idx - 1 do
    col_count = col_count + 1
    if str:sub(i, i) == "\n" then
      line_count = line_count + 1
      col_count = 1
    end
  end
  error( string.format("%s at line %d col %d", msg, line_count, col_count) )
end


local function codepoint_to_utf8(n)
  -- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
  local f = math.floor
  if n <= 0x7f then
    return string.char(n)
  elseif n <= 0x7ff then
    return string.char(f(n / 64) + 192, n % 64 + 128)
  elseif n <= 0xffff then
    return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
  elseif n <= 0x10ffff then
    return string.char(f(n / 262144) + 240, f(n % 262144 / 4096) + 128,
                       f(n % 4096 / 64) + 128, n % 64 + 128)
  end
  error( string.format("invalid unicode codepoint '%x'", n) )
end


local function parse_unicode_escape(s)
  local n1 = tonumber( s:sub(1, 4),  16 )
  local n2 = tonumber( s:sub(7, 10), 16 )
   -- Surrogate pair?
  if n2 then
    return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
  else
    return codepoint_to_utf8(n1)
  end
end


local function parse_string(str, i)
  local res = ""
  local j = i + 1
  local k = j

  while j <= #str do
    local x = str:byte(j)

    if x < 32 then
      decode_error(str, j, "control character in string")

    elseif x == 92 then -- `\`: Escape
      res = res .. str:sub(k, j - 1)
      j = j + 1
      local c = str:sub(j, j)
      if c == "u" then
        local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
                 or str:match("^%x%x%x%x", j + 1)
                 or decode_error(str, j - 1, "invalid unicode escape in string")
        res = res .. parse_unicode_escape(hex)
        j = j + #hex
      else
        if not escape_chars[c] then
          decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
        end
        res = res .. escape_char_map_inv[c]
      end
      k = j + 1

    elseif x == 34 then -- `"`: End of string
      res = res .. str:sub(k, j - 1)
      return res, j + 1
    end

    j = j + 1
  end

  decode_error(str, i, "expected closing quote for string")
end


local function parse_number(str, i)
  local x = next_char(str, i, delim_chars)
  local s = str:sub(i, x - 1)
  local n = tonumber(s)
  if not n then
    decode_error(str, i, "invalid number '" .. s .. "'")
  end
  return n, x
end


local function parse_literal(str, i)
  local x = next_char(str, i, delim_chars)
  local word = str:sub(i, x - 1)
  if not literals[word] then
    decode_error(str, i, "invalid literal '" .. word .. "'")
  end
  return literal_map[word], x
end


local function parse_array(str, i)
  local res = {}
  local n = 1
  i = i + 1
  while 1 do
    local x
    i = next_char(str, i, space_chars, true)
    -- Empty / end of array?
    if str:sub(i, i) == "]" then
      i = i + 1
      break
    end
    -- Read token
    x, i = parse(str, i)
    res[n] = x
    n = n + 1
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "]" then break end
    if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
  end
  return res, i
end


local function parse_object(str, i)
  local res = {}
  i = i + 1
  while 1 do
    local key, val
    i = next_char(str, i, space_chars, true)
    -- Empty / end of object?
    if str:sub(i, i) == "}" then
      i = i + 1
      break
    end
    -- Read key
    if str:sub(i, i) ~= '"' then
      decode_error(str, i, "expected string for key")
    end
    key, i = parse(str, i)
    -- Read ':' delimiter
    i = next_char(str, i, space_chars, true)
    if str:sub(i, i) ~= ":" then
      decode_error(str, i, "expected ':' after key")
    end
    i = next_char(str, i + 1, space_chars, true)
    -- Read value
    val, i = parse(str, i)
    -- Set
    res[key] = val
    -- Next token
    i = next_char(str, i, space_chars, true)
    local chr = str:sub(i, i)
    i = i + 1
    if chr == "}" then break end
    if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
  end
  return res, i
end


local char_func_map = {
  [ '"' ] = parse_string,
  [ "0" ] = parse_number,
  [ "1" ] = parse_number,
  [ "2" ] = parse_number,
  [ "3" ] = parse_number,
  [ "4" ] = parse_number,
  [ "5" ] = parse_number,
  [ "6" ] = parse_number,
  [ "7" ] = parse_number,
  [ "8" ] = parse_number,
  [ "9" ] = parse_number,
  [ "-" ] = parse_number,
  [ "t" ] = parse_literal,
  [ "f" ] = parse_literal,
  [ "n" ] = parse_literal,
  [ "[" ] = parse_array,
  [ "{" ] = parse_object,
}


parse = function(str, idx)
  local chr = str:sub(idx, idx)
  local f = char_func_map[chr]
  if f then
    return f(str, idx)
  end
  decode_error(str, idx, "unexpected character '" .. chr .. "'")
end


function json.decode(str)
  if type(str) ~= "string" then
    error("expected argument of type string, got " .. type(str))
  end
  local res, idx = parse(str, next_char(str, 1, space_chars, true))
  idx = next_char(str, idx, space_chars, true)
  if idx <= #str then
    decode_error(str, idx, "trailing garbage")
  end
  return res
end


end
-- luacheck: pop

-- ---------------------------------------------------------------------------
-- Constants and script manager data
-- ---------------------------------------------------------------------------

local OS = dt.configuration.running_os
local PS = OS == "windows" and "\\" or "/"

local MODE_SMART = 1
local MODE_METADATA = 2

local DEFAULT_TAG_PREFIX = "darktable|immich"
local MAX_TAG_LENGTH = 60

local script_data = {}

script_data.metadata = {
  name = _("Immich search"),
  purpose = _("search Immich and show the hits in the lighttable"),
  author = "Jörn Gorres <joern@gorres.com>",
  help = "https://github.com/jgorres/immich-for-darktable"
}

script_data.destroy = nil
script_data.destroy_method = nil
script_data.restart = nil
script_data.show = nil

-- Module state that survives between callbacks.
local state = {
  module_installed = false,
  previous_rules = nil,
  busy = false,
}

math.randomseed(os.time())

-- ---------------------------------------------------------------------------
-- Preferences
-- ---------------------------------------------------------------------------

dt.preferences.register(MODULE, "server_url", "string",
  "Immich search - " .. _("server URL"),
  _("base URL of the Immich server without trailing slash, e.g. http://immich.local:2283"),
  "")

dt.preferences.register(MODULE, "api_key", "string",
  "Immich search - " .. _("API key"),
  _("Immich API key with the permission asset.read (stored unencrypted in darktablerc)"),
  "")

dt.preferences.register(MODULE, "path_map", "string",
  "Immich search - " .. _("path mapping"),
  _("CONTAINER=HOST pairs separated by ';' that translate Immich's originalPath prefixes into local paths, e.g. /mnt/media/photos=/home/me/Pictures;/data=/mnt/immich/library"), -- luacheck: ignore 631
  "")

dt.preferences.register(MODULE, "tag_prefix", "string",
  "Immich search - " .. _("tag prefix"),
  _("parent tag under which each search result tag is created"),
  DEFAULT_TAG_PREFIX)

dt.preferences.register(MODULE, "timeout", "integer",
  "Immich search - " .. _("timeout (seconds)"),
  _("maximum time for one request to the Immich server"),
  30, 5, 300)

dt.preferences.register(MODULE, "highlight_color", "string",
  "Immich search - " .. _("status highlight colour"),
  _("background colour (#rrggbb) of the status line while a request runs; written to user.css by the button 'install status highlight', needs 'modify theme with CSS tweaks' in preferences > general"), -- luacheck: ignore 631
  "#f6c90e")

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

--- Remove leading and trailing whitespace.
-- @param s string|nil Input.
-- @return string Trimmed text, empty string for nil.
local function trim(s)
  if s == nil then
    return ""
  end
  return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Split a string at a plain (non-pattern) separator.
-- @param s string Input.
-- @param sep string Separator.
-- @return table List of parts.
local function split(s, sep)
  local parts = {}
  local start = 1
  while true do
    local i, j = string.find(s, sep, start, true)
    if not i then
      table.insert(parts, string.sub(s, start))
      break
    end
    table.insert(parts, string.sub(s, start, i - 1))
    start = j + 1
  end
  return parts
end

--- Quote one argument for the operating system shell.
-- Only file paths and the server URL are ever quoted; user input never
-- reaches the command line.
-- @param arg string Argument.
-- @return string Quoted argument.
local function quote_arg(arg)
  if OS == "windows" then
    return '"' .. (arg:gsub('"', '""')) .. '"'
  end
  return "'" .. (arg:gsub("'", "'\\''")) .. "'"
end

--- Build a unique path inside darktable's temporary directory.
-- @param kind string Short label that becomes part of the file name.
-- @return string Absolute path.
local function tmp_path(kind)
  return dt.configuration.tmp_dir .. PS ..
    string.format("%s_%s_%d_%04d.tmp", MODULE, kind, os.time(), math.random(0, 9999))
end

--- Write a string to a file (binary mode).
-- @param path string File path.
-- @param content string Content.
-- @return boolean True on success.
local function write_file(path, content)
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  f:write(content)
  f:close()
  return true
end

--- Read a whole file.
-- @param path string File path.
-- @return string|nil Content or nil if the file cannot be read.
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("a")
  f:close()
  return content
end

--- Remove a file, ignoring errors and nil.
-- @param path string|nil File path.
local function remove_quiet(path)
  if path then
    os.remove(path)
  end
end

--- Cut a UTF-8 string to a maximum number of characters.
-- @param s string Input.
-- @param max_chars number Maximum number of characters.
-- @return string Shortened string.
local function utf8_truncate(s, max_chars)
  local ok, offset = pcall(utf8.offset, s, max_chars + 1)
  if ok and offset then
    return s:sub(1, offset - 1)
  end
  if not ok then
    return s:sub(1, max_chars)
  end
  return s
end

-- ---------------------------------------------------------------------------
-- Settings and path mapping
-- ---------------------------------------------------------------------------

--- Parse the path mapping preference.
-- @param spec string Preference value "CONTAINER=HOST;CONTAINER=HOST".
-- @return table|nil List of {container=, host=} entries, nil on error.
-- @return string|nil Error message.
local function parse_path_map(spec)
  local map = {}
  for _idx, raw in ipairs(split(spec or "", ";")) do -- luacheck: ignore _idx
    local entry = trim(raw)
    if entry ~= "" then
      local container, host = entry:match("^([^=]+)=(.+)$")
      if not container then
        return nil, string.format(_("path mapping entry '%s' is not CONTAINER=HOST"), entry)
      end
      container = (trim(container):gsub("/+$", ""))
      host = (trim(host):gsub("[/\\]+$", ""))
      if container == "" or host == "" then
        return nil, string.format(_("path mapping entry '%s' has an empty side"), entry)
      end
      if container:find("..", 1, true) or host:find("..", 1, true) then
        return nil, string.format(_("path mapping entry '%s' must not contain '..'"), entry)
      end
      if container:sub(1, 1) ~= "/" then
        return nil, string.format(_("container path '%s' must start with '/'"), container)
      end
      table.insert(map, { container = container, host = host })
    end
  end
  if #map == 0 then
    return nil, _("path mapping is not set: enter CONTAINER=HOST pairs in preferences > lua options > Immich search")
  end
  return map
end

--- Translate an Immich originalPath into a local path.
-- @param map table Parsed path mapping.
-- @param original string Path as reported by Immich.
-- @return string|nil Local path or nil if no prefix matches.
local function map_path(map, original)
  for _idx, m in ipairs(map) do -- luacheck: ignore _idx
    if original == m.container or original:sub(1, #m.container + 1) == m.container .. "/" then
      local rest = original:sub(#m.container + 1)
      if OS == "windows" then
        rest = (rest:gsub("/", "\\"))
      end
      return m.host .. rest
    end
  end
  return nil
end

--- Read and validate all preferences.
-- @return table|nil Settings table or nil on error.
-- @return string|nil Error message.
local function load_settings()
  local s = {}
  s.server_url = (trim(dt.preferences.read(MODULE, "server_url", "string")):gsub("/+$", ""))
  s.api_key = trim(dt.preferences.read(MODULE, "api_key", "string"))
  s.tag_prefix = trim(dt.preferences.read(MODULE, "tag_prefix", "string"))
  s.timeout = dt.preferences.read(MODULE, "timeout", "integer")

  if s.server_url == "" then
    return nil, _("server URL is not set: enter it in preferences > lua options > Immich search")
  end
  if not s.server_url:match("^https?://[%w%.%-_:%[%]/]+$") then
    return nil, _("server URL is invalid (expected http(s)://host[:port])")
  end
  if s.api_key == "" then
    return nil, _("API key is not set: create one in Immich (permission asset.read) and enter it in preferences > lua options > Immich search") -- luacheck: ignore 631
  end
  if s.api_key:find("[%c%s]") then
    return nil, _("API key contains whitespace")
  end
  if s.tag_prefix == "" then
    s.tag_prefix = DEFAULT_TAG_PREFIX
  end
  if type(s.timeout) ~= "number" or s.timeout < 5 then
    s.timeout = 30
  end

  local map, err = parse_path_map(dt.preferences.read(MODULE, "path_map", "string"))
  if not map then
    return nil, err
  end
  s.path_map = map
  return s
end

-- ---------------------------------------------------------------------------
-- HTTP via curl
-- ---------------------------------------------------------------------------

--- Locate the curl executable.
-- @return string|nil Executable path or nil.
-- @return string|nil Error message.
local function find_curl()
  local curl = df.check_if_bin_exists("curl")
  if not curl then
    return nil, _("curl not found; install curl or set its path in preferences > lua options > executable paths")
  end
  return curl
end

--- Turn an Immich error body into a readable message.
-- @param data table Decoded error body.
-- @return number|nil HTTP status code.
-- @return string Message text.
local function immich_error(data)
  local code = tonumber(data.statusCode)
  local msg = data.message
  if type(msg) == "table" then
    msg = table.concat(msg, "; ")
  elseif type(msg) ~= "string" then
    msg = tostring(data.error or "")
  end
  return code, msg
end

--- Perform one request against the Immich API.
-- Headers (including the API key) and the JSON body are handed to curl
-- through temporary files, so nothing sensitive appears on the command
-- line. The response is read back from a temporary file.
-- @param settings table Validated settings.
-- @param path string API path starting with "/api/".
-- @param body table|nil Request body; a POST is sent when present.
-- @return table|nil Decoded JSON response or nil on error.
-- @return string|nil Error message.
local function api_request(settings, path, body)
  local curl, cerr = find_curl()
  if not curl then
    return nil, cerr
  end

  local header_file = tmp_path("headers")
  local body_file = nil
  local out_file = tmp_path("response")
  local err_file = tmp_path("stderr")

  local function cleanup()
    remove_quiet(header_file)
    remove_quiet(body_file)
    remove_quiet(out_file)
    remove_quiet(err_file)
  end

  local headers = "x-api-key: " .. settings.api_key .. "\nAccept: application/json\n"
  if body then
    headers = headers .. "Content-Type: application/json\n"
  end
  if not write_file(header_file, headers) then
    cleanup()
    return nil, _("cannot write a temporary file in darktable's temp directory")
  end

  local args = {
    curl,
    "--silent", "--show-error", "--fail-with-body",
    "--max-time", tostring(math.floor(settings.timeout)),
    "--max-redirs", "0",
    "--header", quote_arg("@" .. header_file),
  }

  if body then
    local ok, encoded = pcall(json.encode, body)
    if not ok then
      cleanup()
      return nil, _("cannot encode the request as JSON")
    end
    body_file = tmp_path("body")
    if not write_file(body_file, encoded) then
      cleanup()
      return nil, _("cannot write a temporary file in darktable's temp directory")
    end
    table.insert(args, "--data")
    table.insert(args, quote_arg("@" .. body_file))
  end

  table.insert(args, "--output")
  table.insert(args, quote_arg(out_file))
  table.insert(args, "--stderr")
  table.insert(args, quote_arg(err_file))
  table.insert(args, quote_arg(settings.server_url .. path))

  local command = table.concat(args, " ")
  dt.print_log(MODULE .. ": " .. command)

  local rc = dsys.external_command(command)
  if type(rc) ~= "number" then
    rc = 1
  elseif rc > 255 then
    rc = rc // 256
  end

  local text = read_file(out_file) or ""
  local errtext = trim(read_file(err_file))
  cleanup()

  local decoded_ok, data = pcall(json.decode, text)

  if rc == 0 then
    if not decoded_ok or type(data) ~= "table" then
      return nil, _("invalid JSON in the server response")
    end
    return data
  end

  -- Immich error bodies carry statusCode and message; some (e.g. 401) only
  -- a message, so fall back to the HTTP status curl prints on stderr.
  local http_code = tonumber(errtext:match("returned error: (%d%d%d)"))
  if decoded_ok and type(data) == "table" and (data.statusCode or http_code) then
    local code, msg = immich_error(data)
    code = code or http_code
    if code == 401 or code == 403 then
      return nil, string.format(_("Immich rejected the API key or its permissions (HTTP %d): %s"), code, msg)
    end
    return nil, string.format(_("Immich error (HTTP %s): %s"), tostring(code), msg)
  end

  if rc == 6 or rc == 7 or rc == 28 or rc == 35 then
    if errtext == "" then
      errtext = "curl exit " .. rc
    end
    return nil, string.format(_("Immich server not reachable: %s"), errtext)
  end
  if rc == 2 then
    return nil, _("curl is too old; version 7.76 or newer is required")
  end
  return nil, string.format(_("curl failed (exit %d): %s"), rc, errtext)
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

--- Validate a date entered as YYYY-MM-DD.
-- @param s string Input.
-- @return boolean True when empty or well-formed.
local function valid_date(s)
  return s == "" or s:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

--- Tell whether any filter besides the search text is set.
-- @param p table Parameters read from the widgets.
-- @return boolean True when at least one filter has a value.
local function has_filter(p)
  return p.date_from ~= "" or p.date_to ~= "" or p.make ~= "" or p.model ~= ""
    or p.ocr ~= "" or p.favorites or p.rating > 0
end

--- Build endpoint and request body from the module's input values.
-- In smart mode without a search text the request falls back to the
-- metadata endpoint when at least one filter is set, so that e.g. an OCR
-- word alone finds images without forcing the user to switch the mode.
-- @param p table Parameters read from the widgets.
-- @return string|nil API path or nil on error.
-- @return table|nil Request body.
-- @return string|nil Error message.
-- @return boolean True when smart mode fell back to the filter search.
local function build_request(p)
  if not valid_date(p.date_from) or not valid_date(p.date_to) then
    return nil, nil, _("dates must be entered as YYYY-MM-DD")
  end

  local body = { size = p.limit, page = 1, type = "IMAGE", withExif = true }
  local endpoint
  local fallback = false

  if p.mode == MODE_SMART and p.query == "" and not has_filter(p) then
    return nil, nil, _("enter a search text in the top field for the smart search, or set a filter")
  end

  if p.mode == MODE_SMART and p.query ~= "" then
    endpoint = "/api/search/smart"
    body.query = p.query
  else
    fallback = p.mode == MODE_SMART
    endpoint = "/api/search/metadata"
    if p.query ~= "" then
      body.originalFileName = p.query
    end
  end

  if p.date_from ~= "" then
    body.takenAfter = p.date_from .. "T00:00:00.000Z"
  end
  if p.date_to ~= "" then
    body.takenBefore = p.date_to .. "T23:59:59.999Z"
  end
  if p.make ~= "" then
    body.make = p.make
  end
  if p.model ~= "" then
    body.model = p.model
  end
  if p.ocr ~= "" then
    body.ocr = p.ocr
  end
  if p.favorites then
    body.isFavorite = true
  end
  if p.rating > 0 then
    body.rating = p.rating
  end

  return endpoint, body, nil, fallback
end

--- Derive the result tag name from the query.
-- @param prefix string Tag prefix from the preferences.
-- @param query string Search text.
-- @param mode number MODE_SMART or MODE_METADATA.
-- @return string Full tag path.
local function result_tag_name(prefix, query, mode)
  local base = query
  if base == "" then
    base = mode == MODE_METADATA and "metadata" or "smart"
  end
  base = base:gsub("[%c|]", " ")
  base = trim((base:gsub("%s+", " ")))
  base = utf8_truncate(base, MAX_TAG_LENGTH)
  if base == "" then
    base = "search"
  end
  return prefix .. "|" .. base
end

--- Detach a tag from every image that currently carries it.
-- @param tag table darktable tag object.
local function detach_from_all(tag)
  local images = {}
  for _idx, image in ipairs(tag) do -- luacheck: ignore _idx
    table.insert(images, image)
  end
  for _idx, image in ipairs(images) do -- luacheck: ignore _idx
    dt.tags.detach(tag, image)
  end
end

--- Replace the lighttable collection with a single tag rule.
-- The rules active before the first Immich search are kept for
-- "restore previous collection".
-- @param tag_name string Full tag path.
local function show_tag_collection(tag_name)
  local rule = dt.gui.libs.collect.new_rule()
  rule.mode = "DT_LIB_COLLECT_MODE_AND"
  rule.item = "DT_COLLECTION_PROP_TAG"
  rule.data = tag_name
  local previous = dt.gui.libs.collect.filter({ rule })
  if state.previous_rules == nil then
    state.previous_rules = previous
  end
end

--- Restore the collection that was active before the first search.
local function restore_collection()
  if state.previous_rules then
    dt.gui.libs.collect.filter(state.previous_rules)
    state.previous_rules = nil
  end
end

-- Forward declarations, assigned after the widgets exist.
local set_status
local set_busy

--- Whole seconds since a reading of os.time().
-- os.time() is the only portable wall clock in darktable's Lua; its
-- resolution is one second, which is enough to tell server from import time.
-- @param since number Start time from os.time().
-- @return number Elapsed seconds, never negative.
local function seconds_since(since)
  return math.max(0, math.floor(os.difftime(os.time(), since)))
end

--- Run a worker exactly once at a time with the request buttons locked.
-- A Lua error inside the worker is caught so that the module never stays
-- locked; the error is shown in the status line and logged.
-- @param worker function Function doing the work.
-- @param ... any Arguments for the worker.
local function run_guarded(worker, ...)
  if state.busy then
    dt.print(_("a request is already running"))
    return
  end
  state.busy = true
  set_busy(true)
  local ok, err = pcall(worker, ...)
  set_busy(false)
  state.busy = false
  if not ok then
    local msg = string.format(_("internal error: %s"), tostring(err))
    set_status(msg)
    dt.print(msg)
    dt.print_log(MODULE .. ": " .. msg)
  end
end

--- Search Immich, import the hits, tag and show them.
-- Runs in darktable's Lua background thread (see the button callbacks), so
-- the interface keeps redrawing while curl waits for the server and while
-- the hits are imported; GUI calls are marshalled to the GTK thread by
-- darktable itself.
-- @param p table Parameters read from the widgets.
local function search_worker(p)
  local settings, serr = load_settings()
  if not settings then
    set_status(serr)
    dt.print(serr)
    return
  end

  local endpoint, body, berr, fallback = build_request(p)
  if not endpoint then
    set_status(berr)
    dt.print(berr)
    return
  end

  set_status(_("searching ..."))
  dt.print(_("searching Immich ..."))

  -- Text-only background job in the left panel while the server works.
  -- No cancel callback: a running curl cannot be interrupted from here.
  local search_job = dt.gui.create_job(_("Immich search running ..."), false)
  local request_start = os.time()
  local data, rerr = api_request(settings, endpoint, body)
  local request_seconds = seconds_since(request_start)
  search_job.valid = false

  if not data then
    set_status(rerr)
    dt.print(rerr)
    return
  end

  local assets = type(data.assets) == "table" and data.assets or {}
  local items = type(assets.items) == "table" and assets.items or {}
  local total = tonumber(assets.total) or #items

  local tag_name = result_tag_name(settings.tag_prefix, p.query, p.mode)
  local tag = dt.tags.create(tag_name)
  detach_from_all(tag)

  local job = dt.gui.create_job(_("importing Immich results"), true, function(j)
    j.valid = false
  end)

  local images = {}
  local skipped = { unmapped = 0, missing = 0, other = 0 }
  local import_start = os.time()

  for i, item in ipairs(items) do
    if not job.valid then
      break
    end
    job.percent = (i - 1) / #items

    if type(item) ~= "table" or item.type ~= "IMAGE" or item.isOffline then
      skipped.other = skipped.other + 1
    else
      local original = tostring(item.originalPath or "")
      local local_path = map_path(settings.path_map, original)
      if not local_path then
        skipped.unmapped = skipped.unmapped + 1
        dt.print_log(MODULE .. ": no mapping for " .. original)
      elseif not df.check_if_file_exists(local_path) then
        skipped.missing = skipped.missing + 1
        dt.print_log(MODULE .. ": file not found " .. local_path)
      else
        local ok, image = pcall(dt.database.import, local_path)
        if ok and image then
          dt.tags.attach(tag, image)
          table.insert(images, image)
        else
          skipped.other = skipped.other + 1
          dt.print_log(MODULE .. ": import failed for " .. local_path)
        end
      end
    end
  end

  if job.valid then
    job.valid = false
  end
  local import_seconds = seconds_since(import_start)

  if #images > 0 then
    show_tag_collection(tag_name)
    if p.open_first then
      -- display_image() only switches images inside the darkroom; from the
      -- lighttable the first hit is selected and the view is changed.
      dt.gui.selection({ images[1] })
      if dt.gui.current_view().id == "darkroom" then
        dt.gui.views.darkroom.display_image(images[1])
      else
        dt.gui.current_view(dt.gui.views.darkroom)
      end
    end
  end

  -- The timing tells where a slow search spends its time: on the server
  -- (CLIP search) or in darktable (import and tagging of the hits).
  local timing = string.format(_("server %d s, import %d s"), request_seconds, import_seconds)
  local status = string.format(
    _("%d of %d hits shown, %d without mapping, %d missing, %d skipped"),
    #images, total, skipped.unmapped, skipped.missing, skipped.other)
  if fallback then
    status = _("no search text: filter search") .. "; " .. status
  end
  status = status .. " (" .. timing .. ")"
  dt.print_log(string.format("%s: %d items, %s", MODULE, #items, timing))
  set_status(status)
  dt.print(status)
end

--- Run a search with the buttons locked; see run_guarded.
-- @param p table Parameters read from the widgets.
local function run_search(p)
  run_guarded(search_worker, p)
end

--- Check server reachability, version and API key.
-- Runs in the background thread like search_worker.
local function check_worker()
  local settings, serr = load_settings()
  if not settings then
    set_status(serr)
    dt.print(serr)
    return
  end

  set_status(_("checking ..."))
  local version, verr = api_request(settings, "/api/server/version")
  if not version then
    set_status(verr)
    dt.print(verr)
    return
  end
  local vs = string.format("%s.%s.%s",
    tostring(version.major), tostring(version.minor), tostring(version.patch))

  local probe, perr = api_request(settings, "/api/search/metadata",
    { size = 1, page = 1, type = "IMAGE" })
  if not probe then
    local msg = string.format(_("Immich %s reachable, but: %s"), vs, perr)
    set_status(msg)
    dt.print(msg)
    return
  end

  local msg = string.format(_("Immich %s reachable, API key accepted"), vs)

  -- Feature flags tell whether smart search and OCR are enabled on this
  -- server. A key without the needed permission gets an error; then the
  -- flags are simply left out.
  local features = api_request(settings, "/api/server/features")
  if type(features) == "table" and features.smartSearch ~= nil then
    local function flag(v)
      return v and _("on") or _("off")
    end
    msg = msg .. string.format(" (%s: %s, %s: %s)",
      _("smart search"), flag(features.smartSearch), _("OCR"), flag(features.ocr))
  end

  set_status(msg)
  dt.print(msg)
end

--- Check the connection with the buttons locked; see run_guarded.
local function check_connection()
  run_guarded(check_worker)
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

local W = {}

W.query = dt.new_widget("entry") {
  placeholder = _("search text (smart) or file name (metadata)"),
  tooltip = _("smart: describe the image content; metadata: part of the file name, case-insensitive"),
  editable = true,
}

W.mode = dt.new_widget("combobox") {
  label = _("mode"),
  tooltip = _("smart search uses the image content (CLIP), metadata search uses file name and filters only"),
  value = MODE_SMART,
  _("smart (image content)"),
  _("metadata"),
}

W.date_from = dt.new_widget("entry") {
  placeholder = _("taken from (YYYY-MM-DD)"),
  editable = true,
}

W.date_to = dt.new_widget("entry") {
  placeholder = _("taken until (YYYY-MM-DD)"),
  editable = true,
}

W.make = dt.new_widget("entry") {
  placeholder = _("camera make"),
  editable = true,
}

W.model = dt.new_widget("entry") {
  placeholder = _("camera model"),
  editable = true,
}

W.ocr = dt.new_widget("entry") {
  placeholder = _("text in the image (OCR)"),
  tooltip = _("matches text recognised inside the images; needs OCR enabled on the server"),
  editable = true,
}

W.favorites = dt.new_widget("check_button") {
  label = _("favourites only"),
  value = false,
}

W.rating = dt.new_widget("combobox") {
  label = _("rating"),
  tooltip = _("exact Immich rating, 'any' disables the filter"),
  value = 1,
  _("any"), "1", "2", "3", "4", "5",
}

W.limit = dt.new_widget("slider") {
  label = _("max. hits"),
  tooltip = _("smart search always returns this many hits when enough assets exist"),
  soft_min = 1,
  soft_max = 200,
  hard_min = 1,
  hard_max = 200,
  step = 1,
  digits = 0,
  value = 50,
}

W.open_first = dt.new_widget("check_button") {
  label = _("open first hit in the darkroom"),
  value = false,
}

-- CSS names of the status line: idle and while a request runs. Users can
-- colour them in darktable's CSS tweaks, e.g. #immich_search_busy {...}.
local STATUS_NAME_IDLE = "immich_search_status"
local STATUS_NAME_BUSY = "immich_search_busy"

W.status = dt.new_widget("label") {
  label = "",
  ellipsize = "end",
  halign = "start",
  name = STATUS_NAME_IDLE,
}

--- Write a text to the status label.
-- @param text string Status text.
set_status = function(text)
  W.status.label = text or ""
end

--- Collect the current widget values.
-- @return table Parameters for run_search.
local function read_params()
  return {
    query = trim(W.query.text),
    mode = W.mode.selected,
    date_from = trim(W.date_from.text),
    date_to = trim(W.date_to.text),
    make = trim(W.make.text),
    model = trim(W.model.text),
    ocr = trim(W.ocr.text),
    favorites = W.favorites.value and true or false,
    rating = (W.rating.selected or 1) - 1,
    limit = math.floor(W.limit.value + 0.5),
    open_first = W.open_first.value and true or false,
  }
end

W.search = dt.new_widget("button") {
  label = _("search"),
  clicked_callback = function()
    -- Widget values are read here on the GTK thread; the work itself runs
    -- in darktable's Lua background thread so the interface stays
    -- responsive and the background jobs are drawn.
    local p = read_params()
    dt.control.dispatch(function()
      run_search(p)
    end)
  end,
}

W.check = dt.new_widget("button") {
  label = _("check connection"),
  clicked_callback = function()
    dt.control.dispatch(check_connection)
  end,
}

--- Lock or unlock the two buttons that start a request and make the busy
-- state visible: the search button reads "searching ..." and the status
-- line switches its CSS name so a user style can highlight it.
-- @param busy boolean True while a request runs.
set_busy = function(busy)
  W.search.sensitive = not busy
  W.check.sensitive = not busy
  W.search.label = busy and _("searching ...") or _("search")
  W.status.name = busy and STATUS_NAME_BUSY or STATUS_NAME_IDLE
end

W.restore = dt.new_widget("button") {
  label = _("restore previous collection"),
  clicked_callback = function()
    restore_collection()
    set_status("")
  end,
}

-- ---------------------------------------------------------------------------
-- Status highlight (optional CSS rule in user.css)
-- ---------------------------------------------------------------------------

-- Markers around the block this script maintains in user.css. Everything
-- outside the markers is left untouched.
local CSS_MARK_BEGIN = "/* immich_search: status highlight (begin) */"
local CSS_MARK_END = "/* immich_search: status highlight (end) */"
local DEFAULT_HIGHLIGHT = "#f6c90e"

--- CSS block that colours the status line while a request runs.
-- @param colour string Background colour as #rgb or #rrggbb.
-- @return string CSS text including both markers, without trailing newline.
local function highlight_css(colour)
  return table.concat({
    CSS_MARK_BEGIN,
    "#" .. STATUS_NAME_BUSY .. " {",
    "    background-color: " .. colour .. ";",
    "    color: #000000;",
    "    padding: 2px 6px;",
    "    border-radius: 3px;",
    "}",
    CSS_MARK_END,
  }, "\n")
end

--- Write the highlight rule into user.css.
-- Lua cannot load CSS at runtime, so this is an explicit opt-in (button).
-- Idempotent: an existing block is replaced when the colour changed and
-- left alone otherwise; all other content of user.css stays. The switch
-- "modify theme with CSS tweaks" (themes/usercss) cannot be set from Lua:
-- dt.preferences.write("darktable", ...) lands in the Lua namespace, not
-- in the core key (verified with darktable 5.6.2); only reading works.
local function install_highlight()
  local colour = trim(dt.preferences.read(MODULE, "highlight_color", "string")):lower()
  if colour == "" then
    colour = DEFAULT_HIGHLIGHT
  end
  if not (colour:match("^#%x%x%x%x%x%x$") or colour:match("^#%x%x%x$")) then
    local msg = string.format(_("status highlight colour must be a hex value like %s"), DEFAULT_HIGHLIGHT)
    set_status(msg)
    dt.print(msg)
    return
  end

  local path = dt.configuration.config_dir .. PS .. "user.css"
  local existing = read_file(path) or ""
  local block = highlight_css(colour)
  local tweaks_on = dt.preferences.read("darktable", "themes/usercss", "bool") and true or false

  local updated
  local b = existing:find(CSS_MARK_BEGIN, 1, true)
  local e = b and existing:find(CSS_MARK_END, b, true)
  if b and e then
    e = e + #CSS_MARK_END - 1
    if existing:sub(b, e) == block and tweaks_on then
      local msg = _("status highlight is already installed")
      set_status(msg)
      dt.print(msg)
      return
    end
    updated = existing:sub(1, b - 1) .. block .. existing:sub(e + 1)
  else
    local prefix = existing
    if prefix ~= "" and prefix:sub(-1) ~= "\n" then
      prefix = prefix .. "\n"
    end
    if prefix ~= "" then
      prefix = prefix .. "\n"
    end
    updated = prefix .. block .. "\n"
  end

  if updated ~= existing and not write_file(path, updated) then
    local msg = string.format(_("cannot write %s"), path)
    set_status(msg)
    dt.print(msg)
    return
  end
  dt.print_log(MODULE .. ": status highlight written to " .. path)

  -- The preferences dialog applies user.css as soon as it is saved, so
  -- with the switch still off no restart is needed on that route.
  local msg
  if tweaks_on then
    msg = _("status highlight written to user.css; restart darktable to apply")
  else
    msg = _("status highlight written to user.css; enable 'modify theme with CSS tweaks' in preferences > general and save, it applies at once") -- luacheck: ignore 631
  end
  set_status(msg)
  dt.print(msg)
end

W.highlight = dt.new_widget("button") {
  label = _("install status highlight"),
  tooltip = _("writes a CSS rule into user.css that colours the status line while a request runs; needs 'modify theme with CSS tweaks' in preferences > general"), -- luacheck: ignore 631
  clicked_callback = function()
    install_highlight()
  end,
}

W.box = dt.new_widget("box") {
  orientation = "vertical",
  W.query,
  W.mode,
  dt.new_widget("section_label") { label = _("filters") },
  W.date_from,
  W.date_to,
  W.make,
  W.model,
  W.ocr,
  W.favorites,
  W.rating,
  W.limit,
  dt.new_widget("section_label") { label = _("result") },
  W.open_first,
  dt.new_widget("box") {
    orientation = "horizontal",
    W.search,
    W.check,
  },
  W.restore,
  W.highlight,
  W.status,
}

-- ---------------------------------------------------------------------------
-- Module registration and script manager hooks
-- ---------------------------------------------------------------------------

--- Register the lighttable module once.
local function install_module()
  if not state.module_installed then
    dt.register_lib(
      MODULE,
      _("Immich search"),
      true,
      true,
      { [dt.gui.views.lighttable] = { "DT_UI_CONTAINER_PANEL_RIGHT_CENTER", 100 } },
      W.box,
      nil,
      nil
    )
    state.module_installed = true
  end
end

--- Hide the module (libs cannot be destroyed at runtime).
local function destroy()
  dt.gui.libs[MODULE].visible = false
end

--- Show the module again after it was hidden.
local function restart()
  dt.gui.libs[MODULE].visible = true
end

if dt.gui.current_view().id == "lighttable" then
  install_module()
else
  dt.register_event(MODULE, "view-changed", function(_event, _old_view, new_view) -- luacheck: ignore _event _old_view
    if new_view.id == "lighttable" then
      install_module()
    end
  end)
end

dt.print_log(string.format("%s %s loaded (Lua API %s, %s)",
  MODULE, VERSION, dt.configuration.api_version_string, OS))

script_data.destroy = destroy
script_data.destroy_method = "hide"
script_data.restart = restart
script_data.show = restart

-- Internal functions exposed for the test harness in tests/; not part of the UI.
script_data.internal = {
  parse_path_map = parse_path_map,
  map_path = map_path,
  result_tag_name = result_tag_name,
  build_request = build_request,
  load_settings = load_settings,
  api_request = api_request,
  run_search = run_search,
  check_connection = check_connection,
  install_highlight = install_highlight,
  widgets = W,
  state = state,
}

return script_data
