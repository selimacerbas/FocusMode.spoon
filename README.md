
# FocusMode.spoon

A Hammerspoon Spoon that helps you stay in flow by **dimming everything except what you’re working on**. It supports multiple displays, shows a tiny **“FM”** menu bar indicator when active, and can also keep the **app under your mouse cursor** undimmed (even if it’s not focused).

> You might be also interested in these repos;
> [PaperWM](https://github.com/mogenson/PaperWM.spoon)
> [KeyCaster](https://github.com/selimacerbas/KeyCaster.spoon)
> [CursorScope](https://github.com/selimacerbas/CursorScope.spoon)
---

## 🎥 Demo

### App Focus
![App Focus](assets/app_focus.gif)

### Mouse Dimming
![Mouse Dimming](assets/mouse_dimming.gif)

---

## ✨ Features

* **Focus dimming**: all non-focused app windows are dimmed.
* **Mouse-aware dimming** *(optional)*: the app under your cursor stays undimmed while you hover.
* **Multi-display support**: per-screen overlays.
* **Click-through overlays**: your clicks go straight to the apps underneath.
* **Menu bar indicator**: “FM” icon with quick toggles and brightness controls.
* **PaperWM-friendly**: debounced redraws for smooth transitions when tiling or switching.

---

## 📦 Requirements

* **macOS** with [Hammerspoon](https://www.hammerspoon.org/) installed.
* Works best with a **recent Hammerspoon build**. The Spoon contains fallbacks for older APIs, but if you see deprecation warnings, please update Hammerspoon.

---

## 🔧 Install

### Manual (recommended for first-time use)

1. Create the Spoon folder:

   ```bash
   mkdir -p ~/.hammerspoon/Spoons/FocusMode.spoon
   ```
2. Copy `init.lua` from this repo into:

   ```
   ~/.hammerspoon/Spoons/FocusMode.spoon/init.lua
   ```

### Via SpoonInstall (once it’s published)

```lua
hs.loadSpoon("SpoonInstall")
spoon.SpoonInstall:andUse("FocusMode", { start = true })
```

---

## 🚀 Quick Start

In your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("FocusMode")

-- Optional: tweak settings before start
-- spoon.FocusMode.dimAlpha = 0.45
-- spoon.FocusMode.mouseDim = true
-- spoon.FocusMode.windowCornerRadius = 6
-- spoon.FocusMode.eventSettleDelay = 0.03 -- smoother with tilers

-- Optional: custom hotkeys
-- spoon.FocusMode:bindHotkeys({
--   start = { {"ctrl","alt","cmd"}, "I" },
--   stop  = { {"ctrl","alt","cmd"}, "O" },
-- })

-- Start (you can also use the hotkey)
spoon.FocusMode:start()
```

**Default hotkeys**

* Start: **Ctrl + Option (Alt) + Command + I**
* Stop: **Ctrl + Option (Alt) + Command + O**

**Menu bar**

* Shows **FM** when running.
* Toggle **Mouse Dimming**.
* Adjust brightness with **Brighter (+)** / **Dimmer (−)**.
* Stop FocusMode.

---

## ⚙️ Configuration Options

Set these before `:start()` in `init.lua`.

| Option                   | Type               | Default  | What it does                                                                          |
| ------------------------ | ------------------ | -------- | ------------------------------------------------------------------------------------- |
| `dimAlpha`               | `number` (0..1)    | `0.45`   | Darkness of the dim overlay (higher = darker).                                        |
| `windowCornerRadius`     | `number`           | `6`      | Rounded corners for the undimmed holes. Set `0` for sharp edges.                      |
| `mouseDim`               | `boolean`          | `true`   | If `true`, the entire app under your cursor stays undimmed (even when not focused).   |
| `mouseUpdateThrottle`    | `number` (seconds) | `0.05`   | Throttle for mouse move handling; lower is more responsive, higher is lighter on CPU. |
| `eventSettleDelay`       | `number` (seconds) | `0.03`   | Debounce for focus/move/resize bursts (useful with tilers like PaperWM).              |
| `autoBindDefaultHotkeys` | `boolean`          | `true`   | Whether to bind default start/stop hotkeys automatically.                             |
| `defaultHotkeys`         | `table`            | see code | Change the default hotkeys. Prefer `:bindHotkeys()` instead.                          |

---

## 🧩 API (public)

* `spoon.FocusMode:start()` – Start overlays and watchers.
* `spoon.FocusMode:stop()` – Stop and clean up.
* `spoon.FocusMode:toggle()` – Toggle running state.
* `spoon.FocusMode:bindHotkeys({ start = {...}, stop = {...} })` – Rebind hotkeys.

> The Spoon is designed to be **click-through** and **non-activating**. Overlays join all Spaces so the shade follows you as you move.

---

## 🧱 How it works (high level)

* For each screen, FocusMode renders a single transparent **canvas overlay**.
* The overlay is filled with a semi-opaque rectangle (the dim), and we “punch holes” for windows that should be visible using a compositing rule.
* Holes are created for **all windows of the focused app**; if `mouseDim = true`, holes are also added for **all windows of the app under your cursor**.
* Redraws are **debounced** (`eventSettleDelay`) to avoid flicker while window managers are shuffling frames.

---

## 🧭 PaperWM Integration (optional)

FocusMode already works well with PaperWM thanks to `eventSettleDelay`. If you want extra smoothness during **window moves** and **Space switches**, you can wrap your PaperWM actions to let Mission Control settle and (optionally) quiet FocusMode briefly.

> If you prefer referencing the Spoon as `FocusMode` (global), add:
>
> ```lua
> FocusMode = spoon.FocusMode
> ```

**Example: wrappers for moves/focus/switch**

```lua
-- ——— Space-safe wrappers; integrate with FocusMode and PaperWM ———
local A = s.actions.actions() -- PaperWM actions table (zero-arg functions)
local function now() return hs.timer.secondsSinceEpoch() end
local lastMoveAt = 0

local function wrapMove(fn)
  return function()
    lastMoveAt = now()
    -- optional: quiet FocusMode if it’s running and a suspend helper exists
    if _G.FocusMode and FocusMode._running and FocusMode._suspend then
      FocusMode:_suspend(1.2)
    end
    fn()                                      -- perform PaperWM move_window_N
    hs.timer.doAfter(0.25, A.refresh_windows) -- let Mission Control settle, then refresh
  end
end

local function withRefresh(fn)
  return function()
    local dt = now() - lastMoveAt
    if dt < 1.0 then
      -- if this follows a move, give Spaces a tick before refreshing+focusing
      hs.timer.doAfter(0.15, function()
        A.refresh_windows(); fn()
      end)
    else
      A.refresh_windows()
      fn()
    end
  end
end

local function wrapSwitch(fn)
  return function()
    fn()
    hs.timer.doAfter(0.25, A.refresh_windows)
  end
end

-- Sample nav bindings (adapt to your setup)
nav:bind({}, "escape", function() nav:exit() end)
nav:bind({ "cmd" }, "return", function() nav:exit() end)

nav:bind({}, "h", nil, withRefresh(A.focus_left),  nil, withRefresh(A.focus_left))
nav:bind({}, "l", nil, withRefresh(A.focus_right), nil, withRefresh(A.focus_right))
nav:bind({}, "j", nil, withRefresh(A.focus_down),  nil, withRefresh(A.focus_down))
nav:bind({}, "k", nil, withRefresh(A.focus_up),    nil, withRefresh(A.focus_up))

nav:bind({ "shift" }, "h", nil, withRefresh(A.swap_left),  nil, withRefresh(A.swap_left))
nav:bind({ "shift" }, "j", nil, withRefresh(A.swap_down),  nil, withRefresh(A.swap_down))
nav:bind({ "shift" }, "k", nil, withRefresh(A.swap_up),    nil, withRefresh(A.swap_up))
nav:bind({ "shift" }, "l", nil, withRefresh(A.swap_right), nil, withRefresh(A.swap_right))

nav:bind({}, "c", nil, A.center_window)
nav:bind({}, "f", nil, A.full_width)
nav:bind({}, "r", nil, A.cycle_width)

nav:bind({}, ",", nil, wrapSwitch(A.switch_space_l), wrapSwitch(A.switch_space_l))
nav:bind({}, ".", nil, wrapSwitch(A.switch_space_r), wrapSwitch(A.switch_space_r))
nav:bind({}, "1", nil, wrapSwitch(A.switch_space_1), wrapSwitch(A.switch_space_1))
nav:bind({}, "2", nil, wrapSwitch(A.switch_space_2), wrapSwitch(A.switch_space_2))
nav:bind({}, "3", nil, wrapSwitch(A.switch_space_3), wrapSwitch(A.switch_space_3))

nav:bind({ "shift" }, "1", nil, wrapMove(A.move_window_1), nil, wrapMove(A.move_window_1))
nav:bind({ "shift" }, "2", nil, wrapMove(A.move_window_2), nil, wrapMove(A.move_window_2))
nav:bind({ "shift" }, "3", nil, wrapMove(A.move_window_3), nil, wrapMove(A.move_window_3))
```

**Notes**

* The wrappers above simply **delay refresh** calls and optionally **suspend** FocusMode if you have a helper like `FocusMode:_suspend(seconds)` in your local fork. FocusMode doesn’t require this, but it can reduce redraws while Spaces are in flight.
* You can also tune `spoon.FocusMode.eventSettleDelay` (e.g., `0.02`–`0.05`) for your machine.

---

## 📜 License

MIT

## 🙏 Credits

* The Hammerspoon community
* [PaperWM.spoon](https://github.com/mogenson/PaperWM.spoon) by @mogenson for the tiling workflow inspiration
