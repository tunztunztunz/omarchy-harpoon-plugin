-- Harpoon's keybindings: the SUPER+H group and the SUPER+W override.
--
-- dofile'd from the user's own ~/.config/hypr/bindings.lua (see README), so
-- it survives Omarchy updates. Loads harpoon-logic.lua first, which defines
-- the global `Harpoon` table these bindings call directly, in-process.

local plugin_dir = os.getenv("HOME") .. "/.config/omarchy/plugins/harpoon"
dofile(plugin_dir .. "/hypr/harpoon-logic.lua")

local function harpoon_exit()
  hl.dispatch(hl.dsp.submap("reset"))
end

-- A submap stays active until something resets it. Every action below
-- resets right away; this timer covers "opened the group, then got
-- distracted", so a stray SUPER+H can't keep swallowing the bound keys.
local harpoon_timeout = nil
local function harpoon_arm_timeout()
  if harpoon_timeout then harpoon_timeout:set_enabled(false) end
  harpoon_timeout = hl.timer(harpoon_exit, { timeout = 4000, type = "oneshot" })
end

-- SUPER+H opens a one-shot group (a native Hyprland submap): the next key
-- does one thing, then the group closes.
hl.define_submap("harpoon", function()
  hl.bind("A", function()
    Harpoon.add()
    harpoon_exit()
  end, { description = "Harpoon: add focused window" })

  hl.bind("SPACE", function()
    Harpoon.focus_or_list()
    harpoon_exit()
  end, { description = "Harpoon: focus overlay, or open list" })

  hl.bind("ESCAPE", harpoon_exit, { description = "Harpoon: cancel" })

  for key, anchor in pairs({
    Q = "top-left", E = "top-right", Z = "bottom-left", C = "bottom-right", S = "center",
  }) do
    hl.bind(key, function()
      Harpoon.anchor(anchor)
      harpoon_exit()
    end, { description = "Harpoon: anchor overlay " .. anchor })
  end

  -- keys 1-9 are slots 1-9, key 0 is slot 10
  for key = 0, 9 do
    local slot = key == 0 and 10 or key

    hl.bind(tostring(key), function()
      Harpoon.jump(slot)
      harpoon_exit()
    end, { description = "Harpoon: jump " .. slot })

    hl.bind("SHIFT + " .. key, function()
      Harpoon.add(slot)
      harpoon_exit()
    end, { description = "Harpoon: add at slot " .. slot })
  end
end)

o.bind("SUPER + H", "Harpoon group", function()
  hl.dispatch(hl.dsp.submap("harpoon"))
  harpoon_arm_timeout()
end)

-- Omarchy binds SUPER+W to an unconditional close; take it over so an
-- overlaid window is restored instead. Any other window closes as before.
hl.unbind("SUPER + W")
o.bind("SUPER + W", "Close window (harpoon-aware)", function()
  Harpoon.smart_close()
end)
