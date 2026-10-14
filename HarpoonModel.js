// Pure helpers for Harpoon.qml. No Quickshell/QML imports here on purpose --
// keeps this file testable and simple to reason about in isolation.

// harpoon-logic.lua writes a fixed 10-element `slots` array with `false` (or
// JSON null decoded as Lua false) marking an empty slot. QML/JS reads the
// raw JSON text via FileView and parses it with the platform's native
// JSON.parse -- no vendored library needed on this side.
function parseSlots(rawText) {
  try {
    var doc = JSON.parse(rawText)
    var slots = Array.isArray(doc.slots) ? doc.slots : []
    var out = []
    for (var i = 0; i < 10; i++) {
      var v = slots[i]
      out.push(v && typeof v === "object" ? v : null)
    }
    return out
  } catch (e) {
    return [null, null, null, null, null, null, null, null, null, null]
  }
}

// Rows for the visible list: only populated slots, in slot-ascending order
// (slots are not compacted -- a partially-filled list can have gaps).
// `live` is filled in separately once the current `hyprctl -j clients`
// address set is known (see Harpoon.qml's refreshLiveness).
//
// For a slot the user hasn't renamed, the name is rebuilt at display time
// as "<app> - <title>", with `resolveAppName` turning the window class into
// the app's short name from its .desktop file ("com.mitchellh.ghostty" ->
// "Ghostty"); `app`/`title` are exposed separately so the row can style
// them differently. A custom name is shown verbatim.
function displayRows(slots, resolveAppName) {
  var rows = []
  for (var i = 0; i < slots.length; i++) {
    var e = slots[i]
    if (!e) continue
    var custom = !!e.customName
    var name = e.name || ""
    var app = ""
    if (!custom) {
      // the desktop-entry lookup here first; when it only echoes the class
      // back, the name harpoon-logic.lua resolved at add time (it also
      // searches StartupWMClass) is the better one
      var cls = e.class || ""
      app = resolveAppName ? (resolveAppName(cls) || cls) : cls
      if (app === cls && e.app && e.app !== cls) app = e.app
      name = app + " - " + (e.title || "")
    }
    rows.push({
      slot: e.slot || (i + 1),
      name: name,
      app: app,
      custom: custom,
      address: e.address || "",
      cls: e.class || "",
      title: e.title || "",
      overlaid: !!e.overlaid,
      noPreview: !!e.noPreview,
      live: true
    })
  }
  return rows
}

// Address -> live bool, from a parsed `hyprctl -j clients` array.
function liveAddressSet(clientsJsonText) {
  var set = {}
  try {
    var clients = JSON.parse(clientsJsonText)
    for (var i = 0; i < clients.length; i++) {
      var addr = clients[i] && clients[i].address
      if (addr) set[addr] = true
    }
  } catch (e) {
    // leave set empty -- callers treat "not present" as "not live"
  }
  return set
}

// Escape a JS string as a Lua source string literal, for embedding into an
// expression handed to `hyprctl dispatch "Harpoon.rename(N, <this>)"`.
function luaStringLiteral(s) {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"'
}
