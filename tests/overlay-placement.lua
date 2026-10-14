-- Run from the repository root: lua tests/overlay-placement.lua
-- Summon, anchor, adjust and return a floating bookmark against a mocked compositor.
local json = dofile("hypr/json.lua")
local state, pending, writes = "", nil, 0
local monitors = {
  big = { name = "big", x = 0, y = 0, width = 2560, height = 1440, scale = 1, reserved = { top = 30 } },
  small = { name = "small", x = 2560, y = 0, width = 1280, height = 600, scale = 1 },
}
local workspaces = { [1] = { id = 1, monitor = monitors.big }, [2] = { id = 2, monitor = monitors.small } }
local windows = {}
local active, active_ws = nil, workspaces[1]

local function window(address, x, y, w, h)
  windows[address] = {
    address = address, mapped = true, floating = true, pinned = false, fullscreen = 0,
    at = { x = x, y = y }, size = { x = w, y = h }, workspace = workspaces[1], monitor = monitors.big,
  }
  return windows[address]
end

local function apply(d)
  local a, w = d.args, d.args.window
  if d.op == "resize" then w.size = { x = a.x, y = a.y }
  elseif d.op == "move" and a.workspace then
    local ws = workspaces[a.workspace] or workspaces[1]
    w.workspace, w.monitor = ws, ws.monitor
  elseif d.op == "move" then w.at = { x = a.x, y = a.y }
  elseif d.op == "pin" then w.pinned = not w.pinned
  elseif d.op == "float" then w.floating = not w.floating
  elseif d.op == "focus" and w then active = w
  end
end

local function op(name) return function(args) return { op = name, args = args or {} } end end
local env = setmetatable({
  io = {
    open = function(path, mode)
      if path:match("/list.json$") then
        return { read = function() return state end, close = function() end }
      elseif path:match("/list.json.tmp$") and mode == "w" then
        return { write = function(_, text) pending = text end, close = function() end }
      end
      return nil
    end,
  },
  os = setmetatable({
    execute = function() end,
    rename = function() state = assert(pending); writes = writes + 1 end,
  }, { __index = os }),
  dofile = function() return json end,
  hl = {
    get_window = function(selector) return windows[selector:sub(9)] end,
    get_active_window = function() return active end,
    get_active_workspace = function() return active_ws end,
    get_active_monitor = function() return active_ws.monitor end,
    get_workspace = function(id) return workspaces[id] end,
    get_monitor = function(name) return monitors[name] end,
    on = function() end,
    dispatch = function(d) apply(d) end,
    dsp = {
      no_op = op("no_op"), focus = op("focus"),
      window = {
        resize = op("resize"), move = op("move"), pin = op("pin"), float = op("float"),
        alter_zorder = op("zorder"), close = op("close"),
      },
    },
  },
}, { __index = _G })

local function seed(overlay)
  local slots = {}
  for i = 1, 10 do slots[i] = json.null end
  slots[1] = { slot = 1, address = "pm", overlaid = false, app = "Pass", name = "Pass", overlay = overlay }
  state = json.encode({ version = 1, slots = slots })
end
local function entry() return json.decode(state, nil, false).slots[1] end
local function geometry(w) return w.at.x, w.at.y, w.size.x, w.size.y end
local function expect(w, x, y, width, height, msg)
  local ax, ay, aw, ah = geometry(w)
  assert(ax == x and ay == y and aw == width and ah == height,
    ("%s: got %d,%d %dx%d"):format(msg, ax, ay, aw, ah))
end

local pm = window("pm", 100, 100, 400, 300)
local other = window("other", 600, 600, 800, 500)
active = other
seed(nil)
assert(loadfile("hypr/harpoon-logic.lua", "t", env))()
local Harpoon = env.Harpoon

-- Usable area of "big" is x 0..2560, y 30..1440.
Harpoon.jump(1)
expect(pm, 1080, 585, 400, 300, "Bookmarks without preferences summon centered at their home size")

Harpoon.anchor("top-right")
expect(pm, 2140, 50, 400, 300, "Corner anchors keep the size and use a 20px margin")
assert(entry().overlay.anchor == "top-right" and entry().overlay.offsetX == 20, "Anchor saves a preference immediately")

pm.at, pm.size = { x = 2050, y = 70 }, { x = 480, y = 650 } -- user drag + resize
Harpoon.restore(1)
expect(pm, 100, 100, 400, 300, "Return restores floating home geometry")
assert(active == other, "Return hands focus back")
local o = entry().overlay
assert(o.anchor == "top-right" and o.width == 480 and o.height == 650 and o.offsetX == 30 and o.offsetY == 40,
  "Return records size and anchor-relative offsets")
assert(entry().overlayApplied == nil, "Applied geometry is dropped on return")

pm.size = { x = 900, y = 900 } -- home geometry changes
Harpoon.jump(1)
expect(pm, 2050, 70, 480, 650, "Resummon uses the saved overlay, not home size")
Harpoon.restore(1)
expect(pm, 100, 100, 900, 900, "Home geometry stays separate")

-- Usable area of "small" is x 2560..3840, y 0..600.
active_ws = workspaces[2]
Harpoon.jump(1)
expect(pm, 3330, 0, 480, 600, "Small monitors shrink and clamp the overlay")
Harpoon.restore(1)
o = entry().overlay
assert(o.width == 480 and o.height == 650 and o.offsetX == 30 and o.offsetY == 40,
  "Monitor-driven adjustments do not overwrite preferences")

Harpoon.jump(1)
pm.at = { x = 3300, y = 0 } -- user drags only horizontally
Harpoon.restore(1)
o = entry().overlay
assert(o.offsetX == 60 and o.offsetY == 40 and o.height == 650, "Only changed preferences update")

Harpoon.jump(1)
Harpoon.anchor("center")
expect(pm, 2560 + 400, 0, 480, 600, "Center anchor centers in the window's monitor without resizing")
Harpoon.restore(1)
o = entry().overlay
assert(o.anchor == "center" and o.offsetX == 0 and o.offsetY == 0 and o.height == 650,
  "Center anchor resets offsets and keeps the size preference")

active, active_ws = other, workspaces[1]
local writes_before = writes
Harpoon.anchor("top-left")
expect(other, 600, 600, 800, 500, "Anchors do nothing to ordinary windows")
assert(writes == writes_before, "Anchors on ordinary windows do not write state")

for _, bad in ipairs({
  { anchor = "middle", width = 480, height = 650, offsetX = 0, offsetY = 0 },
  { anchor = "center", width = 0, height = 650, offsetX = 0, offsetY = 0 },
  { anchor = "center", width = 480, height = 650, offsetX = "20", offsetY = 0 },
}) do
  seed(bad)
  pm.at, pm.size = { x = 100, y = 100 }, { x = 400, y = 300 }
  Harpoon.jump(1)
  expect(pm, 1080, 585, 400, 300, "Invalid preferences fall back to centered summon")
  Harpoon.delete(1)
  expect(pm, 100, 100, 400, 300, "Delete restores home")
end
print("overlay placement: PASS")
