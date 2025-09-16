--- === FocusMode ===
--- A Hammerspoon Spoon that dims everything except your focused app
--- (and optionally the app under your mouse cursor).

local obj                         = {}
obj.__index                       = obj

obj.name                          = "FocusMode"
obj.version                       = "0.1.0" -- add: screenshot-aware suspend/resume
obj.author                        = "Selim Acerbas"
obj.homepage                      = "https://github.com/selimacerbas/FocusMode.spoon"
obj.license                       = "MIT"

-- ==========
-- Settings (can be changed by users before :start())
-- ==========

--- Dim overlay opacity (0..1). 0.45 is a gentle shade; increase to dim more strongly.
obj.dimAlpha                      = 0.45

--- Corner radius for undimmed windows (visual nicety). Set to 0 for sharp edges.
obj.windowCornerRadius            = 6

--- If true, the app under the mouse pointer is also undimmed (even if it isn't focused).
--- (Renamed from `mouseUndim` → `mouseDim`; old key is still honored.)
obj.mouseDim                      = true

--- Throttle for mouse move updates, in seconds (prevents excessive redraws).
obj.mouseUpdateThrottle           = 0.05

--- Debounce for focus/move/resize event bursts (helps tilers like PaperWM settle frames)
obj.eventSettleDelay              = 0.03

--- Screenshot awareness: temporarily hide overlays while taking screenshots
obj.screenshotAware               = true
obj.screenshotSuspendSecondsShort = 3.0  -- ⌘⇧3 / ⌘⇧4 quick captures
obj.screenshotSuspendSecondsUI    = 12.0 -- ⌘⇧5 toolbar (longer session)

--- If true, bind default hotkeys automatically when the Spoon is loaded.
obj.autoBindDefaultHotkeys        = true

--- Default hotkeys (users can override with :bindHotkeys).
obj.defaultHotkeys                = {
    start = { { "ctrl", "alt", "cmd" }, "I" },
    stop  = { { "ctrl", "alt", "cmd" }, "O" },
}

-- ==========
-- Internals
-- ==========

obj._log                          = hs.logger.new("FocusMode", "info")
obj._overlays                     = {}  -- screenUUID -> hs.canvas
obj._wf                           = nil -- hs.window.filter instance
obj._screenWatcher                = nil -- hs.screen.watcher
obj._mouseTap                     = nil -- hs.eventtap for mouse moved
obj._mouseTimer                   = nil -- throttle timer for mouse
obj._redrawTimer                  = nil -- debounce timer for redraw coalescing
obj._menubar                      = nil -- hs.menubar indicator
obj._running                      = false

-- Screenshot-awareness internals
obj._suspended                    = false
obj._suspendTimer                 = nil
obj._ssKeyTap                     = nil -- keyDown tap for ⌘⇧3/4/5/6
obj._ssAppWatcher                 = nil -- watches Screenshot app activation/termination

-- Utility: shallow copy
local function copy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    return r
end

-- Utility: is window standard & visible (compat: avoid isOnScreen on older HS)
local function isValidWindow(w)
    if not w then return false end
    if not w:isStandard() then return false end
    if w:isMinimized() then return false end
    if not w:application() then return false end
    if not w:screen() then return false end
    local f = w:frame()
    local visible = (type(w.isVisible) == "function") and w:isVisible() or true
    return f and f.w > 0 and f.h > 0 and visible
end

-- Get window under mouse (topmost visible window containing point)
local function windowUnderMouse()
    local pt = (type(hs.mouse.absolutePosition) == "function" and hs.mouse.absolutePosition())
        or hs.mouse.getAbsolutePosition()

    -- Prefer strict z-order; filter for on-screen/visible via isValidWindow
    local wins = hs.window.orderedWindows()
    for _, w in ipairs(wins) do
        if isValidWindow(w) then
            local f = w:frame()
            -- Robust point-in-rect check without relying on geometry helpers
            if pt.x >= f.x and pt.x <= f.x + f.w and pt.y >= f.y and pt.y <= f.y + f.h then
                return w
            end
        end
    end
    return nil
end

-- ------------- Screenshot awareness helpers -------------

local function _isScreenshotApp(app)
    if not app then return false end
    local bid = app:bundleID()
    -- Known Apple screenshot UI bundle; keep name fallback for safety
    if bid == "com.apple.screencaptureui" then return true end
    local name = app:name() or ""
    return (name == "Screenshot" or name == "Screen Shot" or name == "Grab")
end

function obj:_applySuspendState()
    for _, cv in pairs(self._overlays) do
        if self._suspended then cv:hide() else cv:show() end
    end
end

function obj:_setSuspended(flag)
    if self._suspended == flag then return end
    self._suspended = flag
    self:_applySuspendState()
    -- Optional: nudge a redraw after resuming
    if not flag then self:_scheduleRedraw() end
end

function obj:_suspendFor(seconds)
    self:_setSuspended(true)
    if self._suspendTimer then
        self._suspendTimer:stop(); self._suspendTimer = nil
    end
    self._suspendTimer = hs.timer.doAfter(seconds or self.screenshotSuspendSecondsShort, function()
        self._suspendTimer = nil
        self:_setSuspended(false)
    end)
end

-- --------------------------------------------------------

-- Rebuild overlays for all screens if needed
function obj:_ensureOverlays()
    local screens = hs.screen.allScreens()
    local known = {}

    for _, s in ipairs(screens) do
        local uuid = s:getUUID()
        known[uuid] = true
        if not self._overlays[uuid] then
            local frame = s:frame() -- workspace frame (not fullFrame) so menubar/dock stay undimmed
            local cv = hs.canvas.new(frame)
            cv:level(hs.canvas.windowLevels.overlay)

            -- Original behavior: join all Spaces + click-through
            local wb = hs.canvas.windowBehaviors
            local behaviors = { wb.canJoinAllSpaces }
            if wb.ignoresMouseEvents then table.insert(behaviors, wb.ignoresMouseEvents) end
            cv:behavior(behaviors)

            -- Do not activate Hammerspoon when the canvas is clicked
            if cv.clickActivating then cv:clickActivating(false) end

            -- Element #1: the dim background covering the screen frame
            cv[1] = {
                type = "rectangle",
                action = "fill",
                fillColor = { red = 0, green = 0, blue = 0, alpha = self.dimAlpha },
                roundedRectRadii = { xRadius = 0, yRadius = 0 },
            }

            if self._suspended then cv:hide() else cv:show() end
            self._overlays[uuid] = cv
        else
            -- Keep the canvas positioned to the current screen frame (if resolution changed)
            self._overlays[uuid]:frame(s:frame())
            -- Keep visibility consistent with suspend state
            if self._suspended then self._overlays[uuid]:hide() else self._overlays[uuid]:show() end
        end
    end

    -- Remove overlays for disconnected screens
    for uuid, cv in pairs(self._overlays) do
        if not known[uuid] then
            cv:delete()
            self._overlays[uuid] = nil
        end
    end
end

-- Compute per-screen hole rectangles for windows to undim
function obj:_computeHolesPerScreen()
    local holes = {} -- screenUUID -> array of rects (screen-local)
    local frontApp = hs.application.frontmostApplication()

    local function addHoleForWindow(w)
        if not isValidWindow(w) then return end
        local s = w:screen()
        if not s then return end
        local uuid = s:getUUID()
        local sFrame = s:frame()
        local f = w:frame()
        -- Convert to screen-local coordinates
        local loc = { x = f.x - sFrame.x, y = f.y - sFrame.y, w = f.w, h = f.h }
        holes[uuid] = holes[uuid] or {}
        table.insert(holes[uuid], loc)
    end

    -- If suspended (e.g., screenshot in progress), leave everything to macOS
    if self._suspended then
        return holes -- no holes -> overlay hidden anyway
    end

    -- 1) Undim all windows of the focused app
    if frontApp then
        for _, w in ipairs(frontApp:allWindows()) do
            if isValidWindow(w) then addHoleForWindow(w) end
        end
    end

    -- 2) Mouse-aware: undim entire app under the cursor (even if not focused)
    if self.mouseDim then
        local mw = windowUnderMouse()
        if mw then
            local app = mw:application()
            if app then
                for _, w in ipairs(app:allWindows()) do
                    if isValidWindow(w) then addHoleForWindow(w) end
                end
            else
                addHoleForWindow(mw)
            end
        end
    end

    return holes
end

-- Debounced redraw scheduler (coalesce bursts from tilers into one repaint)
function obj:_scheduleRedraw()
    if self._redrawTimer then
        self._redrawTimer:stop()
        self._redrawTimer = nil
    end
    self._redrawTimer = hs.timer.doAfter(self.eventSettleDelay, function()
        self._redrawTimer = nil
        self:_redraw()
    end)
end

-- Update canvas holes according to current focus & mouse state
function obj:_redraw()
    if not self._running then return end
    self:_ensureOverlays()

    local holesPerScreen = self:_computeHolesPerScreen()

    -- For each overlay, rebuild the hole rectangles via destinationOut
    for uuid, cv in pairs(self._overlays) do
        -- Clear hole elements (keep index 1 as the dim background)
        local count = #cv
        for i = count, 2, -1 do cv:removeElement(i) end

        local s = hs.screen.find(uuid)
        if s then
            local sFrame = s:frame()
            cv[1].frame = { x = 0, y = 0, w = sFrame.w, h = sFrame.h }
            -- LIVE opacity updates without restart
            cv[1].fillColor = { red = 0, green = 0, blue = 0, alpha = self.dimAlpha }
        end

        local holes = holesPerScreen[uuid]
        if holes and #holes > 0 then
            for _, r in ipairs(holes) do
                cv:insertElement({
                    type = "rectangle",
                    action = "fill",
                    fillColor = { red = 1, green = 1, blue = 1, alpha = 1 },
                    frame = r,
                    roundedRectRadii = { xRadius = self.windowCornerRadius, yRadius = self.windowCornerRadius },
                    compositeRule = "destinationOut", -- punches a hole in the dim layer
                })
            end
        end
    end
end

-- Mouse move handling (throttled); schedule redraw to follow cursor without clicks
function obj:_handleMouseMoved()
    if not self.mouseDim then return end
    if self._suspended then return end -- no-op while screenshots
    self:_scheduleRedraw()
end

function obj:_startWatchers()
    if self._wf then return end

    -- Watch only the CURRENT Space for fewer spurious events
    self._wf = hs.window.filter.new(nil):setCurrentSpace(true)

    local wf = hs.window.filter
    local function safeSubscribe(ev, cb)
        if not ev then return end
        local ok, err = pcall(function() self._wf:subscribe(ev, cb) end)
        if not ok then self._log.w("window.filter event not supported: " .. tostring(ev) .. " -> " .. tostring(err)) end
    end

    local function onEvent()
        if self._suspended then return end
        self:_scheduleRedraw()
    end

    -- Subscribe (omit wf.windowsChanged — it's noisy and redundant here)
    safeSubscribe(wf.windowFocused, onEvent)
    safeSubscribe(wf.windowUnfocused, onEvent)
    safeSubscribe(wf.windowMoved, onEvent)
    safeSubscribe(wf.windowResized, onEvent)
    safeSubscribe(wf.windowMinimized, onEvent)
    safeSubscribe(wf.windowUnminimized, onEvent)
    safeSubscribe(wf.windowDestroyed, onEvent)
    safeSubscribe(wf.windowCreated, onEvent)

    -- Screen watcher (resolution/display changes)
    self._screenWatcher = hs.screen.watcher.new(function()
        if self._suspended then return end
        self:_scheduleRedraw()
    end)
    self._screenWatcher:start()

    -- Mouse tracking (throttled)
    self._mouseTap = hs.eventtap.new({ hs.eventtap.event.types.mouseMoved }, function(_, _)
        if not self._mouseTimer then
            self._mouseTimer = hs.timer.doAfter(self.mouseUpdateThrottle, function()
                self._mouseTimer = nil
                self:_handleMouseMoved()
            end)
        end
        return false -- pass through
    end)
    self._mouseTap:start()

    -- === Screenshot awareness ===
    if self.screenshotAware then
        -- 1) Key combo detector for ⌘⇧3/4/5/6 (do not consume the event)
        local keyDown = hs.eventtap.event.types.keyDown
        local kc = hs.keycodes.map
        local K3, K4, K5, K6 = kc["3"], kc["4"], kc["5"], kc["6"]

        self._ssKeyTap = hs.eventtap.new({ keyDown }, function(e)
            local f = e:getFlags()
            if f and f.cmd and f.shift then
                local code = e:getKeyCode()
                if code == K3 or code == K4 then
                    self:_suspendFor(self.screenshotSuspendSecondsShort)
                elseif code == K5 or code == K6 then
                    self:_suspendFor(self.screenshotSuspendSecondsUI)
                end
            end
            return false
        end)
        self._ssKeyTap:start()

        -- 2) Watch for the Screenshot app (toolbar mode, ⌘⇧5)
        self._ssAppWatcher = hs.application.watcher.new(function(appName, event, app)
            if _isScreenshotApp(app) then
                if event == hs.application.watcher.activated or event == hs.application.watcher.launched then
                    self:_setSuspended(true)
                elseif event == hs.application.watcher.deactivated or event == hs.application.watcher.terminated then
                    -- give the system a moment to finish writing the file(s)
                    self:_suspendFor(0.5)
                end
            end
        end)
        self._ssAppWatcher:start()
    end
end

function obj:_stopWatchers()
    if self._wf then
        self._wf:unsubscribeAll()
        self._wf = nil
    end
    if self._screenWatcher then
        self._screenWatcher:stop()
        self._screenWatcher = nil
    end
    if self._mouseTap then
        self._mouseTap:stop()
        self._mouseTap = nil
    end
    if self._ssKeyTap then
        self._ssKeyTap:stop()
        self._ssKeyTap = nil
    end
    if self._ssAppWatcher then
        self._ssAppWatcher:stop()
        self._ssAppWatcher = nil
    end
    if self._mouseTimer then
        self._mouseTimer:stop()
        self._mouseTimer = nil
    end
    if self._redrawTimer then
        self._redrawTimer:stop()
        self._redrawTimer = nil
    end
    if self._suspendTimer then
        self._suspendTimer:stop()
        self._suspendTimer = nil
    end
end

function obj:_showMenubar()
    if self._menubar then return end
    self._menubar = hs.menubar.new()
    if not self._menubar then return end
    self._menubar:setTitle("FM")
    self._menubar:setTooltip("FocusMode active")
    self._menubar:setMenu(function()
        local items = {
            { title = "FocusMode is " .. (self._suspended and "PAUSED" or "ON"), disabled = true },
            {
                title = "Mouse Dimming " .. (self.mouseDim and "✓" or "✗"),
                fn = function()
                    self.mouseDim = not self.mouseDim
                    if not self._suspended then self:_scheduleRedraw() end
                end
            },
            { title = "Dim Opacity: " .. string.format("%.2f", self.dimAlpha),   disabled = true },
            {
                title = "Brighter (+)",
                fn = function()
                    self.dimAlpha = math.max(0.00, self.dimAlpha - 0.05)
                    if not self._suspended then self:_scheduleRedraw() end
                end
            },
            {
                title = "Dimmer (−)",
                fn = function()
                    self.dimAlpha = math.min(0.95, self.dimAlpha + 0.05)
                    if not self._suspended then self:_scheduleRedraw() end
                end
            },
            { title = "—", disabled = true },
            { title = "Stop FocusMode (⌃⌥⌘ O)", fn = function() self:stop() end },
        }
        return items
    end)
end

function obj:_hideMenubar()
    if self._menubar then
        self._menubar:delete()
        self._menubar = nil
    end
end

-- Public API

--- FocusMode:start()
--- Starts the dimming overlays and watchers.
function obj:start()
    if self._running then return self end
    self._running = true

    -- Backward compatibility: honor old config key if users still set it
    if self.mouseUndim ~= nil and self.mouseDim == nil then
        self.mouseDim = self.mouseUndim
    end

    self:_ensureOverlays()
    self:_startWatchers()
    self:_showMenubar()
    self:_redraw() -- immediate first paint
    self._log.i("FocusMode started")
    return self
end

--- FocusMode:stop()
--- Stops the dimming and removes overlays/watchers/menubar.
function obj:stop()
    if not self._running then return self end
    self._running = false
    self:_stopWatchers()
    for uuid, cv in pairs(self._overlays) do
        cv:delete()
        self._overlays[uuid] = nil
    end
    self:_hideMenubar()
    self._log.i("FocusMode stopped")
    return self
end

--- FocusMode:toggle()
function obj:toggle()
    if self._running then return self:stop() else return self:start() end
end

-- Hotkeys
function obj:bindHotkeys(mapping)
    local def = {
        start = function() self:start() end,
        stop  = function() self:stop() end,
    }
    hs.spoons.bindHotkeysToSpec(def, mapping)
    return self
end

-- Auto-bind defaults if requested
if obj.autoBindDefaultHotkeys and obj.defaultHotkeys then
    obj:bindHotkeys(copy(obj.defaultHotkeys))
end

return obj
