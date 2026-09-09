# Umbriel Focus Modes (`raell/umbriel-focus-modes`)

Noctalia v5 background service plugin that automatically adapts Umbriel's `follows_mouse` window focus policy according to the currently focused workspace layout.

## Overview

Umbriel supports multiple workspace layouts, notably `scrolling`, `dwindle`, and `master`. However, a static global `follows_mouse` setting creates friction:
- In **`scrolling`**, having the mouse cursor unintentionally steal focus while panning columns or reading content disrupts navigation. A click-to-focus model (`follows_mouse = false`) feels natural.
- In **`dwindle`** and **`master`**, traditional dynamic tiling benefits from focus following the cursor (`follows_mouse = true`).

This plugin runs as a lightweight Noctalia service, subscribes to Umbriel's workspace event stream in real time, and dynamically maintains focus behavior without requiring compositor restarts.

### Default Layout Matrix

| Focused Workspace Layout | `follows_mouse` | Focus Behavior |
| :--- | :---: | :--- |
| **`scrolling`** | `false` | Click to focus (cursor motion does not steal focus) |
| **`dwindle`** | `true` | Focus follows mouse hover |
| **`master`** | `true` | Focus follows mouse hover |

---

## Architecture & Safety

- **Atomic Staged Writes**: Changes are written to a temporary staged file (`~/.config/umbriel/.umbriel-focus-modes.toml.tmp`).
- **Dual Validation**: Before applying, the staged file is checked via `umbriel validate -c <staged>`, followed by a full `umbriel validate`. If validation fails, changes roll back immediately.
- **Reload Deduplication**: When transitioning between layouts sharing the same focus policy (e.g., `dwindle` $\rightarrow$ `master`), redundant disk writes and compositor reloads are completely suppressed.
- **Multi-Monitor Awareness**: In multi-output setups, a 500ms lightweight polling check detects when the focused monitor changes even if no window event was generated.
- **Auto-Restoration**: When disabled or uninstalled, the plugin restores the original `follows_mouse` value saved in the fragment header.

---

## Installation

### 1. Register Plugin Source in Noctalia

In `~/.local/state/noctalia/settings.toml`, add the repository path under `[[plugins.source]]`:

```toml
[[plugins.source]]
kind = "path"
location = "/home/raell/Projetos/umbriel-focus-modes"
name = "umbriel-focus-modes-dev"
```

Then enable the plugin:

```bash
noctalia msg plugins enable raell/umbriel-focus-modes
```

### 2. Include Fragment in Umbriel Configuration

Add `umbriel-focus-modes.toml` to the `include` list in `~/.config/umbriel/config.toml`:

```toml
include = [
    "noctalia.toml",
    "umbriel-focus-modes.toml",
]
```

Validate and reload Umbriel:

```bash
umbriel validate
umbriel msg config-reload
```

---

## Configuration Settings

Settings can be adjusted through Noctalia Settings (`Plugins` $\rightarrow$ `Umbriel Focus Modes`) or declared in `~/.local/state/noctalia/settings.toml`:

```toml
[plugin_settings."raell/umbriel-focus-modes"]
# Enable or disable automatic layout synchronization (default: true)
automatic = true

# Desired focus behavior per layout
scrolling_follow_mouse = false
dwindle_follow_mouse = true
master_follow_mouse = true
```

When `automatic = false`, the plugin immediately restores the original pre-plugin `follows_mouse` setting.

---

## Mouse Button Bindings in Umbriel

When `follows_mouse = false` is active in `scrolling` mode, focus shifts on window click. You can also leverage Umbriel's native mouse button bindings in `~/.config/umbriel/keybinds.toml` for rapid navigation:

```toml
# Focus cycling via mouse side buttons
"Mod+MouseBack" = "window-focus-previous"
"Mod+MouseForward" = "window-focus-next"

# Smooth scroll dragging with middle mouse button
"Mod+MouseMiddle" = "layout-scroll-drag"

# Workspace overview toggle
"Mod+Shift+MouseMiddle" = { action = "overview-toggle", repeat = false }
```

---

## Uninstallation & Clean Restoration

To remove the plugin and restore your system cleanly:

1. **Disable or Uninstall via Noctalia**:
   ```bash
   noctalia msg plugins disable raell/umbriel-focus-modes
   ```
   *The plugin automatically restores `follows_mouse = true` (or your original saved value) upon exit.*

2. **Remove the Include from Umbriel**:
   In `~/.config/umbriel/config.toml`, remove `"umbriel-focus-modes.toml"` from the `include` list.

3. **Delete Managed Files**:
   ```bash
   rm -f ~/.config/umbriel/umbriel-focus-modes.toml
   rm -f ~/.config/umbriel/.umbriel-focus-modes.toml.*
   ```

4. **Validate and Reload Umbriel**:
   ```bash
   umbriel validate
   umbriel msg config-reload
   ```

---

## Current Notes & Limitations

- **Cross-Output Crossing Without Click**: Umbriel currently streams workspace events when active workspaces or layouts change, but does not emit workspace events on pointer crossing across monitors unless window focus changes. The plugin includes a 500ms fallback check to track active output transitions smoothly.
- **Zero Idle CPU**: During steady-state usage, the service uses 0.0% CPU and fewer than 25 MB RSS memory combined.
