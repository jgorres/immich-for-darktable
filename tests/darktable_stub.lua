--[[
  Minimal stand-in for darktable's Lua API and the lua-scripts helpers,
  just enough to load immich_search.lua in a plain Lua 5.4 interpreter and
  exercise its logic. Nothing here is a faithful darktable emulation.
]]

local stub = {}

stub.prefs = {}
stub.log = {}
stub.tags = {}
stub.imported = {}
stub.collection_rules = { "ORIGINAL_RULE" }
stub.displayed = nil
stub.selection = {}
stub.view = "lighttable"

local function noop() end

local function log(msg)
  table.insert(stub.log, msg)
end

--- Build a widget constructor: dt.new_widget("entry"){...} returns the table.
local function new_widget(kind)
  return function(def)
    def = def or {}
    def._kind = kind
    if kind == "combobox" then
      def.selected = type(def.value) == "number" and def.value or 1
    end
    return def
  end
end

local function make_tag(name)
  local tag = { name = name }
  stub.tags[name] = tag
  return tag
end

local dt = {
  configuration = {
    running_os = "linux",
    config_dir = "/tmp/dt-stub-config",
    tmp_dir = os.getenv("TMPDIR") or "/tmp",
    api_version_string = "9.6.0",
  },
  gettext = {
    gettext = function(s) return s end,
    dgettext = function(_domain, s) return s end,
    bindtextdomain = function(domain, dir) stub.textdomain = { domain = domain, dir = dir } end,
  },
  preferences = {
    register = function(script, name, _type, _label, _tooltip, default)
      local key = script .. "/" .. name
      if stub.prefs[key] == nil then
        stub.prefs[key] = default
      end
    end,
    read = function(script, name, _type)
      return stub.prefs[script .. "/" .. name]
    end,
    write = function(script, name, _type, value)
      stub.prefs[script .. "/" .. name] = value
    end,
  },
  new_widget = new_widget,
  print = log,
  print_log = log,
  print_error = log,
  register_lib = noop,
  register_event = noop,
  gui = {
    current_view = function(view)
      if view then stub.view = view.id end
      return { id = stub.view }
    end,
    selection = function(images)
      if images then stub.selection = images end
      return stub.selection
    end,
    views = {
      lighttable = { id = "lighttable" },
      darkroom = { id = "darkroom", display_image = function(img) stub.displayed = img end },
    },
    libs = {
      collect = {
        new_rule = function() return {} end,
        filter = function(rules)
          local previous = stub.collection_rules
          if rules then stub.collection_rules = rules end
          return previous
        end,
      },
    },
    create_job = function()
      return { valid = true, percent = 0 }
    end,
  },
  tags = {
    create = function(name) return stub.tags[name] or make_tag(name) end,
    find = function(name) return stub.tags[name] end,
    attach = function(tag, image) table.insert(tag, image) end,
    detach = function(tag, image)
      for i = #tag, 1, -1 do
        if tag[i] == image then table.remove(tag, i) end
      end
    end,
  },
  database = {
    import = function(path)
      local img = { path = path, id = #stub.imported + 1 }
      table.insert(stub.imported, img)
      return img
    end,
  },
}

setmetatable(dt.gui.libs, { __index = function(_, k) return { visible = true, name = k } end })

package.preload["darktable"] = function() return dt end
package.preload["lib/dtutils"] = function()
  return { check_min_api_version = noop }
end
package.preload["lib/dtutils.file"] = function()
  return {
    check_if_bin_exists = function(bin) return "/usr/bin/" .. bin end,
    check_if_file_exists = function(path)
      local f = io.open(path, "r")
      if f then f:close() return true end
      return false
    end,
  }
end
package.preload["lib/dtutils.system"] = function()
  return {
    external_command = function(command)
      local ok, how, code = os.execute(command)
      if ok then return 0 end
      if how == "exit" then return code end
      return 1
    end,
  }
end

stub.dt = dt
return stub
