-- Run from the repository root: lua tests/closed-windows.lua
-- Exercise the real backend with in-memory files and a mocked compositor.
local json = dofile("hypr/json.lua")
local state, pending, writes = "", nil, 0
local windows, handlers, removed = {}, {}, {}
local function seed(entries)
  local slots = {}
  for i = 1, 10 do
    local entry = entries[i]
    slots[i] = entry and {
      slot = i, address = entry[1], overlaid = entry[2] or false,
      app = "Test", name = "Bookmark " .. i, customName = true,
    } or json.null
  end
  state = json.encode({version = 1, slots = slots})
end
local function slots()
  return json.decode(state, nil, false).slots
end
local env = setmetatable({
  io = {
    open = function(path, mode)
      if path:match("/list.json$") then
        return {read = function() return state end, close = function() end}
      elseif path:match("/list.json.tmp$") and mode == "w" then
        return {write = function(_, text) pending = text end, close = function() end}
      end
      return nil
    end,
  },
  os = setmetatable({
    execute = function() end,
    rename = function() state = assert(pending); writes = writes + 1 end,
    remove = function(path) removed[path:match("([^/]+)%.png$")] = true end,
  }, {__index = os}),
  dofile = function() return json end,
  hl = {
    get_window = function(selector) return windows[selector:sub(9)] end,
    on = function(name, callback) handlers[name] = callback end,
    dsp = {no_op = function() return {} end},
    dispatch = function() error("Cleanup must not manipulate windows") end,
  },
}, {__index = _G})

windows.live = {address = "live", mapped = true}
windows.closing = {address = "closing", mapped = true}
windows.unmapped = {address = "unmapped", mapped = false}
seed({[1] = {"gone"}, [3] = {"live"}, [5] = {"unmapped"}, [8] = {"closing", true}, [10] = {"closing"}})
assert(loadfile("hypr/harpoon-logic.lua", "t", env))()
assert(slots()[1] == false and slots()[5] == false, "Prune stale entries on load")
assert(slots()[3].slot == 3 and slots()[3].name == "Bookmark 3", "Preserve live slots and names")
assert(writes == 1, "Write once for startup cleanup")

handlers["window.close"](windows.closing)
assert(slots()[8] == false and slots()[10] == false, "Remove all bookmarks for a closing window, even while mapped")
assert(slots()[3].address == "live", "Keep other live windows")
assert(writes == 2, "Write once for close cleanup")
handlers["window.close"]({address = "unbookmarked"})
handlers["window.close"](nil)
assert(writes == 2, "Do not write on unrelated close events")
handlers["window.active"]({address = "other"}) -- no overlay remains to raise

seed({[2] = {"gone"}})
env.Harpoon.jump(2)
assert(slots()[2] == false, "Jump removes a stale bookmark if a close event was missed")
seed({[7] = {"gone", true}})
env.Harpoon.restore(7)
assert(slots()[7] == false, "Restore removes a stale overlay bookmark")
handlers["window.close"](windows.live)
assert(#slots() == 10, "Keep the fixed ten-slot state format")
seed({[3] = {"live"}})
local writes_before_reload = writes
assert(loadfile("hypr/harpoon-logic.lua", "t", env))()
assert(writes == writes_before_reload, "Reload with only live bookmarks must not rewrite state")

seed({[2] = {"live"}, [4] = {"closing"}})
removed = {}
env.Harpoon.togglePreview(2)
assert(slots()[2].noPreview == true and removed.live, "Going private deletes the cached capture")
assert(not removed.closing, "Keep captures of bookmarks that still allow previews")
env.Harpoon.togglePreview(2)
assert(slots()[2].noPreview == false, "Toggle previews back on")
removed = {}
env.Harpoon.delete(4)
assert(removed.closing and not removed.live, "Deleting a bookmark deletes its cached capture")
state = json.encode({version = 1, slots = {42, {slot = 2, name = "No address"}, {slot = 3, address = "live"}}})
env.Harpoon.togglePreview(1)
env.Harpoon.togglePreview(3)
assert(slots()[1] == false and slots()[2] == false and slots()[3].noPreview, "Malformed slots read as empty")
print("closed-window cleanup: PASS")
