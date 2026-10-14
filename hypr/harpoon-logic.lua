-- Harpoon's backend: bookmark state and all window manipulation.
--
-- dofile'd into Hyprland's embedded Lua VM by harpoon-bindings.lua, so the
-- SUPER+H submap calls these functions in-process. The list UI
-- (Harpoon.qml, a separate Quickshell process) reaches the same functions
-- through `hyprctl dispatch "Harpoon.jump(3)"`, which evaluates its argument
-- against this VM's global environment -- hence `Harpoon` is a global while
-- everything else in this file stays local.
--
-- `hyprctl dispatch "<expr>"` compiles to `return hl.dispatch(<expr>)`, so
-- every Harpoon.* function returns hl.dsp.no_op() (a harmless dispatcher) to
-- keep that outer call from erroring on a nil result.

local PLUGIN_DIR = os.getenv("HOME") .. "/.config/omarchy/plugins/harpoon"
local STATE_DIR = os.getenv("HOME") .. "/.local/state/omarchy/harpoon"
local STATE_FILE = STATE_DIR .. "/list.json"
local PREVIEW_DIR = STATE_DIR .. "/previews" -- grim fallback captures, written by HarpoonPreview.qml

local SLOT_COUNT = 10

-- An overlay is capped at this fraction of the target monitor's usable area
-- and never shrunk below the minimum, so a tiny source window stays usable.
local OVERLAY_MAX_FRACTION = 0.9
local OVERLAY_MIN_W, OVERLAY_MIN_H = 200, 150

local json = dofile(PLUGIN_DIR .. "/hypr/json.lua")

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Bookmarks hold window titles and previews hold window contents, so the
-- state stays owner-only. Captures are only read right after they are taken,
-- so none need to survive a config load.
os.execute("umask 077; mkdir -p " .. shell_quote(PREVIEW_DIR)
  .. "; chmod 700 " .. shell_quote(STATE_DIR) .. " " .. shell_quote(PREVIEW_DIR)
  .. "; rm -f " .. shell_quote(PREVIEW_DIR) .. "/*.png*")

-- Must match the path HarpoonPreview.qml captures to.
local function preview_path(address)
  return PREVIEW_DIR .. "/" .. address .. ".png"
end

-- The notification card draws an icon file as-is, so the mark (plain white
-- in assets/) is copied with its stroke set to the theme's accent, the
-- same color the list UI tints it to. Rewritten only when the accent
-- changes, i.e. after a theme switch.
local THEME_COLORS = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/omarchy/current/theme/colors.toml"
local ICON_SOURCE = PLUGIN_DIR .. "/assets/harpoon.svg"
local ICON_PATH = STATE_DIR .. "/harpoon-icon.svg"
local icon_tint = nil

local function theme_accent()
  local f = io.open(THEME_COLORS, "r")
  if not f then return nil end
  local accent
  for line in f:lines() do
    accent = line:match('^%s*accent%s*=%s*"(#%x+)"')
    if accent then break end
  end
  f:close()
  return accent
end

local function notification_icon()
  local tint = theme_accent() or "#ffffff"
  if tint ~= icon_tint then
    local src = io.open(ICON_SOURCE, "r")
    if not src then return nil end
    local svg = src:read("*a")
    src:close()
    local out = io.open(ICON_PATH, "w")
    if not out then return nil end
    out:write((svg:gsub('stroke="#ffffff"', 'stroke="' .. tint .. '"')))
    out:close()
    icon_tint = tint
  end
  return ICON_PATH
end

local function notify(msg)
  local icon = notification_icon()
  os.execute("omarchy-notification-send -g '󰛢'"
    .. (icon and (" -i " .. shell_quote(icon)) or "")
    .. " -u low 'Harpoon' " .. shell_quote(msg))
end

-- The app's short name from its .desktop file ("Ghostty" rather than
-- "com.mitchellh.ghostty"), the way the list UI shows it. Tries the class
-- as the entry id, then lowercased, then its last reverse-DNS segment, then
-- any entry declaring it as StartupWMClass. Falls back to the raw class.
-- Cached: only ever called when a window is bookmarked or has vanished.
local app_name_cache = {}

local function desktop_dirs()
  local dirs = {}
  local data_home = os.getenv("XDG_DATA_HOME") or (os.getenv("HOME") .. "/.local/share")
  dirs[#dirs + 1] = data_home .. "/applications"
  for dir in (os.getenv("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"):gmatch("[^:]+") do
    dirs[#dirs + 1] = dir .. "/applications"
  end
  return dirs
end

local function desktop_name(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local in_entry = false
  for line in f:lines() do
    if line:sub(1, 1) == "[" then
      in_entry = line == "[Desktop Entry]"
    elseif in_entry then
      local name = line:match("^Name=(.+)$")
      if name then
        f:close()
        return name
      end
    end
  end
  f:close()
  return nil
end

local function app_name(class)
  if not class or class == "" then return "that window" end
  if app_name_cache[class] then return app_name_cache[class] end

  local dirs = desktop_dirs()
  local ids = { class, class:lower(), class:match("([^.]+)$"):lower() }
  local name
  for _, dir in ipairs(dirs) do
    for _, id in ipairs(ids) do
      name = desktop_name(dir .. "/" .. id .. ".desktop")
      if name then break end
    end
    if name then break end
  end
  if not name then
    for _, dir in ipairs(dirs) do
      local p = io.popen("grep -lisxF -- " .. shell_quote("StartupWMClass=" .. class) .. " " .. shell_quote(dir) .. "/*.desktop 2>/dev/null")
      if p then
        local hit = p:read("*l")
        p:close()
        name = hit and desktop_name(hit)
        if name then break end
      end
    end
  end

  name = name or class
  app_name_cache[class] = name
  return name
end

-- One line per event, picked at random. {app}, {slot} and {key} (the key
-- that jumps to the slot) are filled in.
math.randomseed(os.time())
local LINES = {
  added = {
    "Thar she blows! {app} is slot {slot}",
    "Harpooned {app}. Slot {slot}, aye",
    "{app} hooked — slot {slot}",
    "Slot {slot}: {app}. Don't let go",
    "{app} is on the line. SUPER+H, {key} reels it in",
  },
  full = {
    "All ten harpoons are out. Shift+number re-throws one",
    "Ten's the limit, captain. Shift+number replaces a slot",
  },
  no_window = {
    "Nothing to aim at — focus a window first",
    "Harpoon what, exactly? Focus a window",
  },
  empty = {
    "Slot {slot} is empty — nothing on the line",
    "Nothing in slot {slot}. The sea is quiet",
  },
  gone = {
    "{app} got away — its window is closed",
    "The one that got away: {app}, slot {slot}",
  },
  monitor_gone = {
    "{app}'s home monitor sailed off. Docking it here",
  },
  cleared = {
    "All lines cut. The list is empty",
    "Cast off — every harpoon's back in the rack",
  },
}

local function say(kind, vars)
  local options = LINES[kind]
  local line = options[math.random(#options)]
  notify((line:gsub("{(%w+)}", function(k) return tostring(vars[k] or "") end)))
end

local function slot_key(n)
  return n == SLOT_COUNT and "0" or tostring(n)
end

local function empty_slots()
  local slots = {}
  for i = 1, SLOT_COUNT do slots[i] = false end
  return slots
end

local function has_overlaid(doc)
  for i = 1, SLOT_COUNT do
    local e = doc.slots[i]
    if e ~= false and e.overlaid then return true end
  end
  return false
end

-- An empty slot is `false` throughout this file (a nil can't sit inside a
-- sequence table). dkjson's third decode argument sets what JSON null
-- decodes to, so the file's nulls come in as `false` directly.
local function read_state()
  local f = io.open(STATE_FILE, "r")
  if not f then
    return { version = 1, slots = empty_slots() }
  end
  local text = f:read("*a")
  f:close()
  local ok, doc = pcall(json.decode, text, nil, false)
  if not ok or type(doc) ~= "table" or type(doc.slots) ~= "table" then
    return { version = 1, slots = empty_slots() }
  end
  -- Every reader indexes e.address, so a hand-edited slot without one reads as empty.
  for i = 1, SLOT_COUNT do
    local e = doc.slots[i]
    if type(e) ~= "table" or type(e.address) ~= "string" then doc.slots[i] = false end
  end
  return doc
end

-- Mirrors the on-disk state so the window.active handler at the bottom can
-- bail out without a file read on every focus change. Every mutation goes
-- through write_state, which keeps it current.
local any_overlaid = has_overlaid(read_state())

local function write_state(doc)
  local out, keep = {}, {}
  for i = 1, SLOT_COUNT do
    local e = doc.slots[i]
    out[i] = (e == false) and json.null or e
    if e ~= false and not e.noPreview then keep[e.address] = true end
  end
  -- A bookmark that is gone or private loses its cached capture.
  for _, e in ipairs(read_state().slots) do
    if e ~= false and not keep[e.address] and e.address:match("^%w+$") then
      os.remove(preview_path(e.address))
    end
  end
  local tmp = STATE_FILE .. ".tmp"
  local f = io.open(tmp, "w")
  f:write(json.encode({ version = 1, slots = out }, { indent = true }))
  f:close()
  os.rename(tmp, STATE_FILE)
  any_overlaid = has_overlaid(doc)
end

-- Everything restore() needs to put a window back where it came from.
local function snapshot_home(w)
  return {
    workspaceId = w.workspace and w.workspace.id or false,
    -- by name, not id: ids get reused across unplug/replug, names don't
    monitorName = w.monitor and w.monitor.name or false,
    at = { x = w.at.x, y = w.at.y },
    size = { x = w.size.x, y = w.size.y },
    floating = w.floating,
    pinned = w.pinned,
  }
end

-- hl.get_window() takes the classic selector form; a bare address returns nil.
local function find_window(address)
  return hl.get_window("address:" .. address)
end

local function close_placeholder(entry)
  local placeholder = entry.placeholder and find_window(entry.placeholder)
  if placeholder then hl.dispatch(hl.dsp.window.close({ window = placeholder })) end
  entry.placeholder, entry.placeholderTitle = nil, nil
end

-- Remove closed bookmarks without renumbering the surviving slots. The
-- close event can arrive while its window is still mapped/animating, so
-- explicitly remove that address as well as any older stale entries.
local function prune_closed(closed_address)
  local doc = read_state()
  local changed = false
  for i = 1, SLOT_COUNT do
    local entry = doc.slots[i]
    if entry ~= false then
      local win = find_window(entry.address)
      if entry.address == closed_address or not win or not win.mapped then
        close_placeholder(entry)
        doc.slots[i] = false
        changed = true
      elseif closed_address and entry.placeholder == closed_address then
        entry.placeholder, entry.placeholderTitle = nil, nil
        changed = true
      end
    end
  end
  if changed then write_state(doc) end
end

-- The monitor's usable area in logical pixels -- the coordinate space window
-- geometry and mon.x/mon.y are in. mon.width/mon.height are the physical
-- mode resolution and must be divided by the scale (a 2560x1440 panel at
-- scale 2 is a 1280x720 desktop); odd transforms are 90/270 degree
-- rotations, reported unrotated. `reserved` is the space taken by bars.
local function usable_area(mon)
  local scale = mon.scale or 1
  local w, h = mon.width / scale, mon.height / scale
  if (mon.transform or 0) % 2 == 1 then w, h = h, w end
  local r = mon.reserved or {}
  local top, right = r.top or 0, r.right or 0
  local bottom, left = r.bottom or 0, r.left or 0
  return {
    x = mon.x + left,
    y = mon.y + top,
    w = math.floor(w - left - right),
    h = math.floor(h - top - bottom),
  }
end

local function center_in(area, w, tw, th)
  hl.dispatch(hl.dsp.window.resize({ window = w, x = tw, y = th }))
  hl.dispatch(hl.dsp.window.move({
    window = w,
    x = area.x + math.floor((area.w - tw) / 2),
    y = area.y + math.floor((area.h - th) / 2),
  }))
end

local function is_dwindle(ws_id)
  local ws = hl.get_workspace(ws_id)
  return ws ~= nil and ws.tiled_layout == "dwindle"
end

-- Which side of its old neighbor w sat on, and the dwindle split ratio that
-- gives it its old size back. The neighbor's box now covers the node that
-- w's space collapsed into, so comparing centers picks the axis and side.
-- The ratio is w's old node extent along that axis as a fraction of that
-- node, in dwindle's 0.1-1.9 scale where 1.0 is an even split and the
-- ratio sizes the first (left/top) child. A node is its window plus the
-- inner gaps on both sides; leaving those out drifts the split by a gap's
-- width on every restore.
local function split_from_home(home, neighbor)
  local g = hl.get_config("general:gaps_in")
  if type(g) ~= "table" then g = { top = g, right = g, bottom = g, left = g } end
  local gx = (tonumber(g.left) or 0) + (tonumber(g.right) or 0)
  local gy = (tonumber(g.top) or 0) + (tonumber(g.bottom) or 0)
  local dx = (home.at.x + home.size.x / 2) - (neighbor.at.x + neighbor.size.x / 2)
  local dy = (home.at.y + home.size.y / 2) - (neighbor.at.y + neighbor.size.y / 2)
  local side, fraction
  if math.abs(dx) >= math.abs(dy) then
    side = dx < 0 and "l" or "r"
    fraction = (home.size.x + gx) / (neighbor.size.x + gx)
  else
    side = dy < 0 and "u" or "d"
    fraction = (home.size.y + gy) / (neighbor.size.y + gy)
  end
  if side == "r" or side == "d" then fraction = 1 - fraction end
  return side, math.max(0.1, math.min(1.9, 2 * fraction))
end

local function near(a, b)
  return math.abs(a - b) <= 2
end

-- The window that will absorb w's space once w leaves the tiling tree: its
-- sibling in the layout's binary tree. Hyprland has no query for that, so
-- the adjacent windows are found with movefocus in each direction from w
-- (which must be focused first -- the dispatch is relative to the active
-- window; and it can land on another workspace or monitor when nothing is
-- adjacent here, hence the workspace check). Both children of a node span
-- the node's full extent on the axis it didn't split, so the sibling is
-- the adjacent window that lines up with w on that axis. If none does, w's
-- sibling is a group of windows; the first adjacent one is the best
-- available approximation.
local function find_tile_neighbor(w)
  local home_ws_id = w.workspace and w.workspace.id
  local box = { x = w.at.x, y = w.at.y, w = w.size.x, h = w.size.y }
  local fallback = false
  hl.dispatch(hl.dsp.focus({ window = w }))
  for _, dir in ipairs({ "l", "r", "u", "d" }) do
    hl.dispatch(hl.dsp.focus({ direction = dir }))
    local c = hl.get_active_window()
    hl.dispatch(hl.dsp.focus({ window = w }))
    if c and c.address ~= w.address and c.workspace and c.workspace.id == home_ws_id then
      local aligned
      if dir == "l" or dir == "r" then
        aligned = near(c.at.y, box.y) and near(c.size.y, box.h)
      else
        aligned = near(c.at.x, box.x) and near(c.size.x, box.w)
      end
      if aligned then return c.address end
      fallback = fallback or c.address
    end
  end
  return fallback
end

Harpoon = {}

local SCRATCHPAD = "special:harpoon-reservations"
local placeholder_serial = 0

local function show_overlay(doc, n, entry, w, current_ws)
  if not w.floating then
    hl.dispatch(hl.dsp.window.float({ window = w, action = "toggle" }))
  end
  hl.dispatch(hl.dsp.window.move({ window = w, workspace = current_ws.id, follow = true }))
  local area = usable_area(current_ws.monitor or hl.get_active_monitor())
  local tw = math.max(OVERLAY_MIN_W, math.min(entry.home.size.x, math.floor(area.w * OVERLAY_MAX_FRACTION)))
  local th = math.max(OVERLAY_MIN_H, math.min(entry.home.size.y, math.floor(area.h * OVERLAY_MAX_FRACTION)))
  center_in(area, w, tw, th)
  if not w.pinned then hl.dispatch(hl.dsp.window.pin({ window = w })) end
  hl.dispatch(hl.dsp.window.alter_zorder({ window = w, mode = "top" }))
  hl.dispatch(hl.dsp.focus({ window = w }))
  entry.overlaid = true
  doc.slots[n] = entry
  write_state(doc)
end

-- Mapping a Wayland surface is asynchronous. Keep the original tile untouched
-- until the scratchpad surface exists, and resolve the slot again on completion
-- in case the user reordered/deleted the bookmark while Quickshell started.
local function reserve_tile(doc, entry, current_ws)
  placeholder_serial = placeholder_serial + 1
  local title = "Harpoon-reservation-" .. os.time() .. "-" .. placeholder_serial
  entry.placeholderTitle = title
  write_state(doc)
  local command = "exec env HARPOON_PLACEHOLDER_TITLE=" .. shell_quote(title)
    .. " HARPOON_PLACEHOLDER_LABEL=" .. shell_quote(entry.app or "Harpoon")
    .. " quickshell -p " .. shell_quote(PLUGIN_DIR .. "/HarpoonPlaceholder.qml")
  hl.dispatch(hl.dsp.exec_cmd(command, { workspace = SCRATCHPAD .. " silent", float = false }))
  local attempts = 0
  local function ready()
    local latest = read_state()
    local slot, saved
    for i = 1, SLOT_COUNT do
      local e = latest.slots[i]
      if e ~= false and e.placeholderTitle == title then slot, saved = i, e; break end
    end
    local placeholder = hl.get_window("title:^" .. title .. "$")
    if not saved then
      if placeholder then hl.dispatch(hl.dsp.window.close({ window = placeholder })) end
      return
    end
    local w = find_window(saved.address)
    attempts = attempts + 1
    if not w or attempts >= 100 then
      if placeholder then hl.dispatch(hl.dsp.window.close({ window = placeholder })) end
      saved.placeholderTitle = nil
      write_state(latest)
      if w then notify("Could not create a placeholder; the window stayed in place") end
      return
    end
    if not placeholder or not placeholder.mapped then
      hl.timer(ready, { timeout = 50, type = "oneshot" })
      return
    end
    -- Cancel if the original changed mode while the placeholder was starting.
    if w.floating or (w.fullscreen or 0) ~= 0 or placeholder.floating
      or not placeholder.workspace or placeholder.workspace.name ~= SCRATCHPAD then
      hl.dispatch(hl.dsp.window.close({ window = placeholder }))
      saved.placeholderTitle = nil
      write_state(latest)
      return
    end
    saved.home = snapshot_home(w)
    saved.placeholder = placeholder.address
    hl.dispatch(hl.dsp.window.swap({ window = w, target = placeholder }))
    show_overlay(latest, slot, saved, w, hl.get_workspace(current_ws.id) or hl.get_active_workspace())
  end
  hl.timer(ready, { timeout = 50, type = "oneshot" })
end

-- Bookmark the focused window at `slot`, or at the first empty slot.
function Harpoon.add(slot)
  local w = hl.get_active_window()
  if not w then
    say("no_window")
    return hl.dsp.no_op()
  end

  local doc = read_state()
  if (w.title or ""):match("^Harpoon%-reservation%-") then return hl.dsp.no_op() end
  if not slot then
    for i = 1, SLOT_COUNT do
      if doc.slots[i] == false then slot = i; break end
    end
    if not slot then
      say("full")
      return hl.dsp.no_op()
    end
  end

  -- Replacing an overlay must release its reservation first.
  if doc.slots[slot] ~= false and doc.slots[slot].overlaid then
    Harpoon.restore(slot)
    doc = read_state()
  end
  local app = app_name(w.class)
  doc.slots[slot] = {
    slot = slot,
    name = app .. " - " .. w.title,
    customName = false,
    address = w.address,
    class = w.class,
    app = app,
    title = w.title,
    home = snapshot_home(w),
    overlaid = false,
  }
  write_state(doc)
  say("added", { app = app, slot = slot, key = slot_key(slot) })
  return hl.dsp.no_op()
end

-- Overlay slot n's window on the current workspace: floated, sized to fit,
-- centered, pinned and focused. Jumping to an already-overlaid slot
-- restores it instead.
function Harpoon.jump(n)
  local doc = read_state()
  local entry = doc.slots[n]
  if entry == false then
    say("empty", { slot = n })
    return hl.dsp.no_op()
  end
  if entry.overlaid then
    return Harpoon.restore(n)
  end
  if entry.placeholderTitle then return hl.dsp.no_op() end

  local w = find_window(entry.address)
  if not w then
    doc.slots[n] = false
    write_state(doc)
    say("gone", { app = entry.app or app_name(entry.class), slot = n })
    return hl.dsp.no_op()
  end

  -- restore() hands focus back to this window, not to wherever the
  -- re-tiling happens to leave it. Nothing to return to if w itself was
  -- focused.
  local active_before = hl.get_active_window()
  entry.previousFocus = (active_before and active_before.address ~= w.address) and active_before.address or false

  entry.home = snapshot_home(w)

  -- Read before find_tile_neighbor: it focuses w, which switches the active
  -- workspace to w's own if w lives on another monitor.
  local current_ws = hl.get_active_workspace()

  -- Fullscreen and tab groups retain the legacy restoration path.
  if not w.floating and (w.fullscreen or 0) == 0 and #(w.grouped or {}) == 0 then
    reserve_tile(doc, entry, current_ws)
    return hl.dsp.no_op()
  end

  entry.tileNeighbor = (not w.floating) and find_tile_neighbor(w) or false

  show_overlay(doc, n, entry, w, current_ws)
  return hl.dsp.no_op()
end

-- Put slot n's overlaid window back where jump() took it from, and return
-- focus to the window that was focused before the jump.
function Harpoon.restore(n)
  local doc = read_state()
  local entry = doc.slots[n]
  if entry == false or not entry.overlaid then
    return hl.dsp.no_op()
  end

  local w = find_window(entry.address)
  if not w then
    close_placeholder(entry)
    doc.slots[n] = false
    write_state(doc)
    say("gone", { app = entry.app or app_name(entry.class), slot = n })
    return hl.dsp.no_op()
  end

  -- Unpin before anything moves: Hyprland leaves pinned windows behind
  -- when a workspace changes monitor (see the workspace move below).
  if w.pinned and not entry.home.pinned then
    hl.dispatch(hl.dsp.window.pin({ window = w }))
  end

  local placeholder = entry.placeholder and find_window(entry.placeholder)
  if placeholder and placeholder.mapped and not placeholder.floating then
    -- Both participants must be tiled during the swap: Hyprland 0.56.2
    -- recalculates floating/tiled swaps before updating their floating state.
    -- Retile out of sight so the reservation's tree is never disturbed.
    hl.dispatch(hl.dsp.window.move({ window = w, workspace = SCRATCHPAD, follow = false }))
    if w.floating then hl.dispatch(hl.dsp.window.float({ window = w, action = "toggle" })) end
    hl.dispatch(hl.dsp.window.swap({ window = w, target = placeholder }))
    entry.overlaid = false
    local placeholder_address = entry.placeholder
    entry.placeholder, entry.placeholderTitle = nil, nil
    write_state(doc)
    local retired = find_window(placeholder_address)
    if retired then hl.dispatch(hl.dsp.window.close({ window = retired })) end
    local previous = entry.previousFocus and find_window(entry.previousFocus)
    hl.dispatch(hl.dsp.focus({ window = previous or w }))
    return hl.dsp.no_op()
  end
  close_placeholder(entry)

  -- If the home monitor was unplugged, Hyprland has migrated (or dropped)
  -- its workspaces, so the workspace id alone would restore to wherever
  -- the workspace drifted; restore onto the workspace the user is on now
  -- instead. A home workspace that merely no longer exists is fine:
  -- Hyprland removes a workspace the moment its last window leaves (which
  -- is what a jump does to a lone bookmark), and the move below recreates
  -- it -- on the focused monitor, hence the second step.
  local target_ws = entry.home.workspaceId
  local home_gone = not target_ws
  if entry.home.monitorName and not hl.get_monitor(entry.home.monitorName) then
    home_gone = true
    say("monitor_gone", { app = entry.app or app_name(entry.class) })
  end
  if home_gone then target_ws = hl.get_active_workspace().id end
  hl.dispatch(hl.dsp.window.move({ window = w, workspace = target_ws, follow = false }))

  if not home_gone and entry.home.monitorName then
    local ws = hl.get_workspace(target_ws)
    if ws and ws.monitor and ws.monitor.name ~= entry.home.monitorName then
      hl.dispatch(hl.dsp.workspace.move({ workspace = target_ws, monitor = entry.home.monitorName }))
    end
  end

  if entry.home.floating and home_gone then
    -- home.at is on a monitor that no longer exists; center on the
    -- fallback monitor instead, shrunk to fit if needed.
    local area = usable_area(hl.get_active_workspace().monitor or hl.get_active_monitor())
    center_in(area, w, math.min(entry.home.size.x, area.w), math.min(entry.home.size.y, area.h))
  elseif not entry.home.floating then
    -- Hyprland inserts a newly tiled window by splitting the focused one,
    -- so focusing the old neighbor first puts w back next to it. Dwindle
    -- additionally lets us say which side (preselect) and how big
    -- (splitratio); together that recreates w's old node exactly when the
    -- neighbor was a single window. (If it was a group, w lands inside the
    -- group instead -- see README, "Restoring a tiled window".)
    local neighbor = entry.tileNeighbor and find_window(entry.tileNeighbor)
    if neighbor and neighbor.workspace and neighbor.workspace.id == target_ws then
      hl.dispatch(hl.dsp.focus({ window = neighbor }))
      if is_dwindle(target_ws) then
        local side, ratio = split_from_home(entry.home, neighbor)
        hl.dispatch(hl.dsp.layout("preselect " .. side))
        hl.dispatch(hl.dsp.window.float({ window = w, action = "toggle" }))
        -- splitratio only takes a delta, applied to the focused window's
        -- node; a fresh node starts at dwindle's default ratio
        local default_ratio = tonumber(hl.get_config("dwindle:default_split_ratio")) or 1.0
        hl.dispatch(hl.dsp.focus({ window = w }))
        hl.dispatch(hl.dsp.layout(string.format("splitratio %+.4f", ratio - default_ratio)))
      else
        hl.dispatch(hl.dsp.window.float({ window = w, action = "toggle" }))
      end
    else
      hl.dispatch(hl.dsp.window.float({ window = w, action = "toggle" }))
    end
  else
    hl.dispatch(hl.dsp.window.resize({ window = w, x = entry.home.size.x, y = entry.home.size.y }))
    hl.dispatch(hl.dsp.window.move({ window = w, x = entry.home.at.x, y = entry.home.at.y }))
  end
  if entry.previousFocus then
    local previous = find_window(entry.previousFocus)
    if previous then
      hl.dispatch(hl.dsp.focus({ window = previous }))
    end
  end

  entry.overlaid = false
  doc.slots[n] = entry
  write_state(doc)
  return hl.dsp.no_op()
end

-- SUPER+H, Space: focus an overlaid window that isn't already focused
-- (cycling through them if there are several); with the overlay already
-- focused, or nothing overlaid, open the list instead. Directional focus
-- (movefocus) only walks tiled windows, so this is the keyboard route back
-- to a floating overlay.
function Harpoon.focus_or_list()
  local doc = read_state()
  local active = hl.get_active_window()
  local active_address = active and active.address

  local overlays = {}
  local active_index = 0
  for i = 1, SLOT_COUNT do
    local e = doc.slots[i]
    if e ~= false and e.overlaid then
      local w = find_window(e.address)
      if w then
        overlays[#overlays + 1] = w
        if w.address == active_address then active_index = #overlays end
      end
    end
  end

  for k = 1, #overlays do
    local w = overlays[(active_index + k - 1) % #overlays + 1]
    if w.address ~= active_address then
      hl.dispatch(hl.dsp.focus({ window = w }))
      return hl.dsp.no_op()
    end
  end

  hl.exec_cmd("omarchy-shell shell toggle harpoon")
  return hl.dsp.no_op()
end

-- SUPER+W: restore the focused window if it's an overlay, close it otherwise.
function Harpoon.smart_close()
  local w = hl.get_active_window()
  if not w then return hl.dsp.no_op() end

  local doc = read_state()
  for i = 1, SLOT_COUNT do
    local e = doc.slots[i]
    if e ~= false and e.overlaid and e.address == w.address then
      return Harpoon.restore(i)
    end
  end
  hl.dispatch(hl.dsp.window.close({ window = w }))
  return hl.dsp.no_op()
end

function Harpoon.rename(n, text)
  local doc = read_state()
  if doc.slots[n] == false then return hl.dsp.no_op() end
  doc.slots[n].name = text
  doc.slots[n].customName = true
  write_state(doc)
  return hl.dsp.no_op()
end

function Harpoon.delete(n)
  local doc = read_state()
  if doc.slots[n] == false then return hl.dsp.no_op() end
  if doc.slots[n].overlaid then
    Harpoon.restore(n)
    doc = read_state()
  end
  doc.slots[n] = false
  write_state(doc)
  return hl.dsp.no_op()
end

-- Stop (or resume) capturing slot n's window in the list's preview pane.
function Harpoon.togglePreview(n)
  local doc = read_state()
  if doc.slots[n] == false then return hl.dsp.no_op() end
  doc.slots[n].noPreview = not doc.slots[n].noPreview
  write_state(doc)
  return hl.dsp.no_op()
end

-- Swapping with an empty slot (`false`) is how "move to an empty slot" works.
local function swap_slots(doc, a, b)
  doc.slots[a], doc.slots[b] = doc.slots[b], doc.slots[a]
  if doc.slots[a] ~= false then doc.slots[a].slot = a end
  if doc.slots[b] ~= false then doc.slots[b].slot = b end
end

-- Swap slot n with the nearest occupied slot above ("up") or below.
function Harpoon.reorder(n, dir)
  local doc = read_state()
  local target = nil
  if dir == "up" then
    for i = n - 1, 1, -1 do
      if doc.slots[i] ~= false then target = i; break end
    end
  else
    for i = n + 1, SLOT_COUNT do
      if doc.slots[i] ~= false then target = i; break end
    end
  end
  if not target then return hl.dsp.no_op() end

  swap_slots(doc, n, target)
  write_state(doc)
  return hl.dsp.no_op()
end

-- Move slot n to `target`, swapping with whatever is there.
function Harpoon.moveToSlot(n, target)
  if n == target then return hl.dsp.no_op() end
  local doc = read_state()
  if doc.slots[n] == false then return hl.dsp.no_op() end
  swap_slots(doc, n, target)
  write_state(doc)
  return hl.dsp.no_op()
end

function Harpoon.clear()
  local doc = read_state()
  for i = 1, SLOT_COUNT do
    if doc.slots[i] ~= false and doc.slots[i].overlaid then
      Harpoon.restore(i)
      doc = read_state()
    end
  end
  for i = 1, SLOT_COUNT do doc.slots[i] = false end
  write_state(doc)
  os.execute("rm -f " .. shell_quote(PREVIEW_DIR) .. "/*.png*")
  say("cleared")
  return hl.dsp.no_op()
end

-- Pinning keeps a window on every workspace, not above every window: any
-- window focused later rises above an overlay in the normal stacking order.
-- Re-raise overlays (without re-focusing them, which would fight the user)
-- whenever focus moves to something else. Registered once per config load,
-- like the submap in harpoon-bindings.lua.
hl.on("window.active", function(win)
  if not win or not any_overlaid then return end
  local doc = read_state()
  for i = 1, SLOT_COUNT do
    local e = doc.slots[i]
    if e ~= false and e.overlaid and e.address ~= win.address then
      local overlay = find_window(e.address)
      if overlay then
        hl.dispatch(hl.dsp.window.alter_zorder({ window = overlay, mode = "top" }))
      end
    end
  end
end)

-- FileView watchers in the list and bar pick up the updated state even
-- when the list is already open. No polling or UI-side writes are needed.
hl.on("window.close", function(win)
  if win then prune_closed(win.address) end
end)

-- Also discard bookmarks left behind by previous sessions/plugin versions.
prune_closed()

-- A config reload cancels in-flight timers. Release unfinished reservations;
-- their standalone surfaces notice the removed title and exit themselves.
do
  local doc, changed = read_state(), false
  for i = 1, SLOT_COUNT do
    local entry = doc.slots[i]
    if entry ~= false and entry.placeholderTitle and not entry.overlaid then
      close_placeholder(entry)
      changed = true
    end
  end
  if changed then write_state(doc) end
end
