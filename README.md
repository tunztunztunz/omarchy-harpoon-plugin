# Harpoon

Bookmark up to 10 Hyprland windows and jump to them from anywhere — an
[Omarchy](https://omarchy.org) plugin in the spirit of
[Harpoon](https://github.com/ThePrimeagen/harpoon) for Neovim.

A jump floats, centers and pins the window on top of your **current**
workspace. Jump to the same slot again, or press `SUPER+W` on it, and it goes
back into its reserved tile, with focus returning to the window you were
working in. While a tiled window is away, a Harpoon logo holds its place;
click the placeholder to bring the window back. The reservation also keeps
an otherwise empty workspace alive.

![Harpoon demo: bookmarking and jumping between windows](assets/harpoon-demo.gif)

## Requirements

- Omarchy 4.x (Quickshell shell, Lua Hyprland config)
- Hyprland, Quickshell, and Omarchy's shell utilities from that installation
- `rsync` — required only when using the local `./install.sh` installer
- `grim` — optional, for the preview fallback

The Lua JSON library, dkjson, is bundled; no separate Lua package installation
is needed. Harpoon runs as your user and does not require `sudo`.

## Install

```bash
omarchy plugin add https://github.com/mpriem/omarchy-harpoon-plugin
omarchy plugin enable harpoon
```

Alternatively, run `./install.sh` from a local checkout to install and enable
the plugin. This requires `rsync` and replaces the contents of the installed
Harpoon directory with this checkout, including deleting files absent from
the checkout. Back up any edits to the installed plugin before running it.

After either installation method, add this line to
`~/.config/hypr/bindings.lua`:

```lua
dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/harpoon/hypr/harpoon-bindings.lua")
```

Reload Hyprland to activate the shortcuts:

```bash
hyprctl reload
```

To add a bar button showing the bookmark count and opening the list:

```bash
omarchy plugin enable harpoon right
```

## Configuration and local data

The installer does not edit your Hyprland configuration. Adding the
`dofile(...)` line above explicitly activates Harpoon's bindings: `SUPER+H`
opens the Harpoon group, and `SUPER+W` becomes Harpoon-aware (restoring a
borrowed window, or closing other windows as usual).

The Lua integration expects the plugin at
`~/.config/omarchy/plugins/harpoon`; use the default configuration location.
Bookmarks, preview preferences, a generated icon, and fallback screenshots
are stored under `~/.local/state/omarchy/harpoon/`, readable only by you.
Previews capture window contents locally; press `Shift+P` on a bookmark (a
password manager, say) to never preview it, or select Off with `p` to disable
previews entirely. Either deletes the cached screenshots, as does removing a
bookmark or reloading Hyprland.

## Remove

1. Open the Harpoon list (`SUPER+H`, then `Space`) and press `Shift+D` to
   clear bookmarks and restore any borrowed windows before unloading it.
2. Remove the Harpoon `dofile(...)` line added above from
   `~/.config/hypr/bindings.lua`.
3. Reload Hyprland, then remove the plugin:

   ```bash
   hyprctl reload
   omarchy plugin remove harpoon
   ```

Removing the plugin leaves its local state behind. To also delete its
bookmarks, preferences, generated icon, and cached screenshots after removal:

```bash
rm -rf -- "$HOME/.local/state/omarchy/harpoon"
```

## Keys

`SUPER+H` opens a one-shot group; the next key acts and the group closes.

| Key | Action |
|---|---|
| `A` | Bookmark the focused window in the first empty slot |
| `1`–`9`, `0` | Jump to slot 1–10; jumping to a slot already on screen restores it |
| `Shift`+digit | Bookmark the focused window **at** that slot |
| `Space` | Focus the on-screen bookmark (cycling if several); otherwise open the list |
| `Escape` | Cancel |

`SUPER+W` restores an on-screen bookmark instead of closing it; any other
window closes as usual.

### The list (`SUPER+H`, `Space`)

| Key | Action |
|---|---|
| `↑`/`↓`, `j`/`k` | Move |
| `Shift+↑`/`↓` | Swap with the neighbouring bookmark |
| `Shift`+digit | Move the selection to that slot (swapping if taken) |
| `r` | Rename |
| `d` / `Shift+D` | Delete / clear all — restores borrowed windows first; never closes them |
| `p` | Preview: Live → Thumbnail → Off (remembered) |
| `Shift+P` | Make the selected bookmark private: never previewed |
| `Enter`/`Space`, click | Jump |
| `q`/`Escape` | Close |

Windows behind the list stay interactive, so you can pick another window
and bookmark it without closing the list — which is why there's no
click-outside-to-close.

Closing a bookmarked window automatically removes it from the list and frees
its slot. The remaining bookmarks keep their slot numbers. Stale bookmarks
from previous sessions are also removed when the plugin loads.

Preview modes are Live, Thumbnail, and Off. Thumbnail captures a still image
when the list opens; your chosen mode is remembered.

## License

[MIT](LICENSE). Includes [dkjson](http://dkolf.de/src/dkjson-lua.fsl/) by
David Kolf, also licensed under MIT.
