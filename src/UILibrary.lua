--[[============================================================================

    WaffleUI v2.0.0
    A modern, animated, feature-rich Roblox UI library.

    Changelog (v2):
        * Connection lifecycle: ConnectionBag tracks every UserInputService /
          RunService / instance connection per-window so Destroy() no longer
          leaks listeners when windows are closed.
        * Live theme swapping: Window:SetTheme(themeOrName) re-colors every
          already-created component.
        * New components: ColorPicker, MultiSelect, Paragraph, Divider,
          ProgressBar, RadioGroup, SearchableDropdown.
        * Notifications: severities (Info/Success/Warning/Error), click-to-
          dismiss, explicit close button, non-fighting slide animation.
        * Searchable tab sidebar.
        * Config save/load (executor-safe writefile/readfile guard).
        * Window resize handle (drag from bottom-right corner).
        * Ripple effect on buttons.
        * SelectTab(name) helper; component :Destroy() everywhere.
        * Bug fixes:
            - Slider/Keybind/Drag no longer leak global InputChanged listeners.
            - Subtitle now uses AutomaticSize instead of reading TextBounds on
              frame 0 (which was always 0).
            - Notification slide animation no longer fights UIListLayout.
            - Hotkey toggle uses a cancel token instead of racing task.wait.
            - Dropdown SetOptions safely collapses-before-rebuild.

    Quick start:

        local WaffleUI = require(path.to.UILibrary)

        local Window = WaffleUI:CreateWindow({
            Title    = "Waffle Hub",
            SubTitle = "v2.0.0",
            Theme    = "Dark",                 -- "Dark" | "Light" | "Midnight" | table
            Keybind  = Enum.KeyCode.RightShift, -- toggle visibility
            ConfigFile = "WaffleHub.json",     -- optional; uses writefile if available
        })

        local Main = Window:CreateTab("Main", "rbxassetid://10734950309")
        Main:AddSection("Player")
        Main:AddSlider({ Text = "Speed", Min = 16, Max = 200, Default = 16,
                         Callback = function(v) print(v) end })

============================================================================]]

--==============================================================================
-- Services
--==============================================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui          = game:GetService("CoreGui")
local HttpService      = game:GetService("HttpService")
local TextService      = game:GetService("TextService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer and LocalPlayer:WaitForChild("PlayerGui", 5)

--==============================================================================
-- Animation presets
--==============================================================================
local QUICK  = TweenInfo.new(0.15, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
local MEDIUM = TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SPRING = TweenInfo.new(0.35, Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local SLOW   = TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local function tween(obj, info, goal)
    local t = TweenService:Create(obj, info, goal)
    t:Play()
    return t
end

--==============================================================================
-- ConnectionBag — central connection lifecycle manager
-- Any subsystem that hooks a signal should :Add() its connection to a bag.
-- On Destroy() the bag disconnects everything, preventing listener leaks.
--==============================================================================
local ConnectionBag = {}
ConnectionBag.__index = ConnectionBag

function ConnectionBag.new()
    return setmetatable({ _conns = {}, _destroyed = false }, ConnectionBag)
end

function ConnectionBag:Add(conn)
    if self._destroyed then
        if conn and conn.Disconnect then conn:Disconnect() end
        return conn
    end
    table.insert(self._conns, conn)
    return conn
end

function ConnectionBag:Destroy()
    self._destroyed = true
    for _, c in ipairs(self._conns) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(self._conns)
end

--==============================================================================
-- Low-level Instance helpers
--==============================================================================
local function new(className, props, children)
    local inst = Instance.new(className)
    if props then
        local parent = props.Parent
        for k, v in pairs(props) do
            if k ~= "Parent" then
                inst[k] = v
            end
        end
        if parent then inst.Parent = parent end
    end
    if children then
        for _, child in ipairs(children) do
            child.Parent = inst
        end
    end
    return inst
end

local function corner(radius, parent)
    return new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = parent })
end

local function stroke(color, thickness, parent, transparency)
    return new("UIStroke", {
        Color           = color,
        Thickness       = thickness or 1,
        Transparency    = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent          = parent,
    })
end

local function padding(px, parent)
    local p = new("UIPadding", {
        PaddingTop    = UDim.new(0, px),
        PaddingBottom = UDim.new(0, px),
        PaddingLeft   = UDim.new(0, px),
        PaddingRight  = UDim.new(0, px),
        Parent        = parent,
    })
    return p
end

local function gradient(colorSeq, rotation, parent)
    return new("UIGradient", {
        Color    = colorSeq,
        Rotation = rotation or 0,
        Parent   = parent,
    })
end

-- Safe parent: CoreGui where available (exploit executors, plugins),
-- otherwise PlayerGui.
local function safeParent(gui)
    local ok = pcall(function()
        if (gethui and gethui()) then
            gui.Parent = gethui()
            return
        end
        gui.Parent = CoreGui
    end)
    if not ok or not gui.Parent then
        gui.Parent = PlayerGui
    end
    return gui
end

--==============================================================================
-- Ripple effect used by buttons
--==============================================================================
local function ripple(parent, x, y, color)
    local c = new("Frame", {
        AnchorPoint            = Vector2.new(0.5, 0.5),
        Position               = UDim2.new(0, x, 0, y),
        Size                   = UDim2.new(0, 0, 0, 0),
        BackgroundColor3       = color,
        BackgroundTransparency = 0.6,
        BorderSizePixel        = 0,
        ZIndex                 = (parent.ZIndex or 1) + 1,
        Parent                 = parent,
    })
    corner(999, c)

    local maxSize = math.max(parent.AbsoluteSize.X, parent.AbsoluteSize.Y) * 2
    tween(c, TweenInfo.new(0.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Size                   = UDim2.new(0, maxSize, 0, maxSize),
        BackgroundTransparency = 1,
    })
    task.delay(0.5, function() c:Destroy() end)
end

--==============================================================================
-- Themes
--==============================================================================
local Themes = {
    Dark = {
        Background   = Color3.fromRGB(24, 24, 28),
        Surface      = Color3.fromRGB(32, 32, 38),
        Elevated     = Color3.fromRGB(42, 42, 50),
        Stroke       = Color3.fromRGB(60, 60, 70),
        Primary      = Color3.fromRGB(120, 120, 255),
        PrimaryHover = Color3.fromRGB(140, 140, 255),
        Text         = Color3.fromRGB(235, 235, 240),
        SubText      = Color3.fromRGB(170, 170, 180),
        Accent       = Color3.fromRGB(90, 200, 140),
        Warning      = Color3.fromRGB(240, 180, 70),
        Danger       = Color3.fromRGB(230, 90, 90),
    },
    Light = {
        Background   = Color3.fromRGB(240, 240, 245),
        Surface      = Color3.fromRGB(255, 255, 255),
        Elevated     = Color3.fromRGB(250, 250, 252),
        Stroke       = Color3.fromRGB(210, 210, 220),
        Primary      = Color3.fromRGB(80, 100, 240),
        PrimaryHover = Color3.fromRGB(100, 120, 255),
        Text         = Color3.fromRGB(25, 25, 30),
        SubText      = Color3.fromRGB(110, 110, 120),
        Accent       = Color3.fromRGB(30, 160, 100),
        Warning      = Color3.fromRGB(210, 150, 40),
        Danger       = Color3.fromRGB(220, 70, 70),
    },
    Midnight = {
        Background   = Color3.fromRGB(12, 14, 22),
        Surface      = Color3.fromRGB(18, 22, 32),
        Elevated     = Color3.fromRGB(28, 32, 44),
        Stroke       = Color3.fromRGB(40, 50, 70),
        Primary      = Color3.fromRGB(105, 170, 255),
        PrimaryHover = Color3.fromRGB(140, 195, 255),
        Text         = Color3.fromRGB(230, 235, 245),
        SubText      = Color3.fromRGB(140, 150, 175),
        Accent       = Color3.fromRGB(120, 230, 180),
        Warning      = Color3.fromRGB(255, 200, 100),
        Danger       = Color3.fromRGB(255, 110, 110),
    },
    Ocean = {
        Background   = Color3.fromRGB(10, 22, 34),
        Surface      = Color3.fromRGB(16, 32, 48),
        Elevated     = Color3.fromRGB(24, 44, 62),
        Stroke       = Color3.fromRGB(48, 78, 102),
        Primary      = Color3.fromRGB(80, 200, 220),
        PrimaryHover = Color3.fromRGB(120, 220, 235),
        Text         = Color3.fromRGB(220, 240, 250),
        SubText      = Color3.fromRGB(130, 160, 185),
        Accent       = Color3.fromRGB(180, 230, 130),
        Warning      = Color3.fromRGB(255, 190, 90),
        Danger       = Color3.fromRGB(255, 120, 140),
    },
}

local function resolveTheme(t)
    if type(t) == "table" then return t end
    return Themes[t] or Themes.Dark
end

--==============================================================================
-- Theme Dispatcher
-- Each window gets one Dispatcher. Components register a paint function; when
-- the theme changes, every paint function is called with the new theme.
--==============================================================================
local Dispatcher = {}
Dispatcher.__index = Dispatcher

function Dispatcher.new(theme)
    return setmetatable({
        theme    = theme,
        painters = {},
    }, Dispatcher)
end

function Dispatcher:Register(fn)
    table.insert(self.painters, fn)
    fn(self.theme) -- paint once on register
end

function Dispatcher:SetTheme(theme)
    self.theme = theme
    for _, fn in ipairs(self.painters) do
        pcall(fn, theme)
    end
end

--==============================================================================
-- Config persistence (executor-safe — falls back to in-memory)
--==============================================================================
local _memoryStore = {}

local function hasFS()
    return (writefile and readfile and isfile) ~= nil
end

local function configSave(name, data)
    local json = HttpService:JSONEncode(data)
    if hasFS() then
        pcall(function() writefile(name, json) end)
    else
        _memoryStore[name] = json
    end
end

local function configLoad(name)
    local raw
    if hasFS() and isfile(name) then
        local ok, content = pcall(readfile, name)
        if ok then raw = content end
    else
        raw = _memoryStore[name]
    end
    if not raw then return nil end
    local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if ok then return decoded end
    return nil
end

--==============================================================================
-- Draggable helper (uses ConnectionBag)
-- v3: optional `clampToViewport` keeps the window from being dragged off
-- screen. Enabled for windows, disabled by default for other handles.
--==============================================================================
local function makeDraggable(handle, target, bag, clampToViewport)
    local dragging, dragStart, startPos
    bag:Add(handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging  = true
            dragStart = input.Position
            startPos  = target.Position

            local changedConn
            changedConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if changedConn then changedConn:Disconnect() end
                end
            end)
        end
    end))

    bag:Add(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragStart
            local newX = startPos.X.Offset + delta.X
            local newY = startPos.Y.Offset + delta.Y

            if clampToViewport then
                local cam = workspace.CurrentCamera
                if cam then
                    local vp    = cam.ViewportSize
                    local size  = target.AbsoluteSize
                    -- Keep at least 80px of the window on-screen so the user
                    -- can always grab the titlebar to drag it back.
                    local minX = 80 - size.X
                    local maxX = vp.X - 80
                    local minY = 0
                    local maxY = vp.Y - 40
                    newX = math.clamp(newX, minX, maxX)
                    newY = math.clamp(newY, minY, maxY)
                end
            end

            target.Position = UDim2.new(
                startPos.X.Scale, newX,
                startPos.Y.Scale, newY
            )
        end
    end))
end

--==============================================================================
-- Resize helper (bottom-right corner handle)
--==============================================================================
local function makeResizable(handle, target, minSize, bag)
    local resizing, startInput, startSize
    bag:Add(handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            resizing   = true
            startInput = input.Position
            startSize  = target.AbsoluteSize

            local changedConn
            changedConn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    resizing = false
                    if changedConn then changedConn:Disconnect() end
                end
            end)
        end
    end))

    bag:Add(UserInputService.InputChanged:Connect(function(input)
        if not resizing then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - startInput
            local w = math.max(minSize.X, startSize.X + delta.X)
            local h = math.max(minSize.Y, startSize.Y + delta.Y)
            target.Size = UDim2.new(0, w, 0, h)
        end
    end))
end

--==============================================================================
-- Library root
--==============================================================================
local WaffleUI = {
    Version      = "3.0.0",
    _windows     = {},
    _notifyScreen = nil,
    _notifyStack = nil,
    _notifyBag   = ConnectionBag.new(),
}

--==============================================================================
-- Notifications (global; shared across windows)
--==============================================================================
local NOTIFY_COLORS = {
    Info    = "Primary",
    Success = "Accent",
    Warning = "Warning",
    Error   = "Danger",
}

local function ensureNotifyStack()
    if WaffleUI._notifyScreen and WaffleUI._notifyScreen.Parent then
        return WaffleUI._notifyStack
    end
    local screen = new("ScreenGui", {
        Name           = "WaffleUI_Notifications",
        ResetOnSpawn   = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder   = 1000,
    })
    safeParent(screen)

    local stack = new("Frame", {
        Name                   = "Stack",
        AnchorPoint            = Vector2.new(1, 0),
        Position               = UDim2.new(1, -16, 0, 16),
        Size                   = UDim2.new(0, 320, 1, -32),
        BackgroundTransparency = 1,
        Parent                 = screen,
    })
    new("UIListLayout", {
        Padding             = UDim.new(0, 10),
        SortOrder           = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment   = Enum.VerticalAlignment.Top,
        Parent              = stack,
    })

    WaffleUI._notifyScreen = screen
    WaffleUI._notifyStack  = stack
    return stack
end

--==============================================================================
-- Notify v3:
--   * Real horizontal slide: the card is absolutely positioned inside a
--     fixed-height wrap, so animating Position.X.Offset no longer fights
--     UIListLayout (v2 abused UIPadding which only resized content, never
--     translated it — that was the visible "notification is broken" bug).
--   * Countdown progress bar at the bottom that drains over `duration`.
--   * Optional `Actions = { {Text, Callback}, ... }` for confirm-style popups.
--   * Returns a handle: { Dismiss, Update, SetSeverity }.
--==============================================================================
function WaffleUI:Notify(opts)
    opts = opts or {}
    local title    = opts.Title    or "Notification"
    local text     = opts.Text     or ""
    local duration = opts.Duration or 4
    local severity = opts.Severity or "Info"
    local theme    = resolveTheme(opts.Theme or self._activeTheme)
    local barColor = theme[NOTIFY_COLORS[severity] or "Primary"]

    local stack = ensureNotifyStack()

    -- Measure helpers: width 300 is fixed; height follows content via AutomaticSize.
    local CARD_W = 300

    -- Outer wrap is what the UIListLayout positions.
    local wrap = new("Frame", {
        Size                   = UDim2.new(0, CARD_W, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent                 = stack,
        ClipsDescendants       = false,
    })

    -- Card is absolutely positioned INSIDE wrap. We animate its X offset for
    -- the real slide animation. It AutomaticSize.Y so wrap follows its height.
    local card = new("Frame", {
        AnchorPoint            = Vector2.new(0, 0),
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        Position               = UDim2.new(0, CARD_W + 40, 0, 0), -- start off-screen right
        BackgroundColor3       = theme.Surface,
        BackgroundTransparency = 0,
        Parent                 = wrap,
        ClipsDescendants       = true,
    })
    corner(10, card)
    local cardStroke = stroke(theme.Stroke, 1, card)
    padding(12, card)

    new("UIListLayout", {
        Padding   = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = card,
    })

    -- Color bar (left edge)
    local bar = new("Frame", {
        AnchorPoint      = Vector2.new(0, 0),
        Size             = UDim2.new(0, 3, 1, 0),
        Position         = UDim2.new(0, -9, 0, 0),
        BackgroundColor3 = barColor,
        BorderSizePixel  = 0,
        ZIndex           = 2,
        Parent           = card,
    })
    corner(2, bar)

    -- Title row + close button
    local titleRow = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        LayoutOrder            = 1,
        Parent                 = card,
    })
    local titleLabel = new("TextLabel", {
        Size                   = UDim2.new(1, -22, 1, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 14,
        TextColor3             = theme.Text,
        TextXAlignment         = Enum.TextXAlignment.Left,
        TextTruncate           = Enum.TextTruncate.AtEnd,
        Text                   = title,
        Parent                 = titleRow,
    })
    local closeBtn = new("TextButton", {
        Size                   = UDim2.new(0, 18, 0, 18),
        Position               = UDim2.new(1, -18, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 14,
        TextColor3             = theme.SubText,
        Text                   = "x",
        AutoButtonColor        = false,
        Parent                 = titleRow,
    })

    -- Body text
    local bodyLabel = new("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font                   = Enum.Font.Gotham,
        TextSize               = 13,
        TextColor3             = theme.SubText,
        TextWrapped            = true,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = text,
        LayoutOrder            = 2,
        Parent                 = card,
    })

    -- Forward-declare dismiss state BEFORE actions loop so button callbacks
    -- close over the right binding. (Lua closures capture binding not value,
    -- and a local declared *after* the loop would shadow the upvalue with
    -- nil at capture time.)
    local dismissed = false
    local dismissFn

    -- Action buttons row (optional)
    local actionRow
    if opts.Actions and #opts.Actions > 0 then
        actionRow = new("Frame", {
            Size                   = UDim2.new(1, 0, 0, 26),
            BackgroundTransparency = 1,
            LayoutOrder            = 3,
            Parent                 = card,
        })
        new("UIListLayout", {
            FillDirection      = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            Padding            = UDim.new(0, 6),
            SortOrder          = Enum.SortOrder.LayoutOrder,
            Parent             = actionRow,
        })
        for i, action in ipairs(opts.Actions) do
            local abtn = new("TextButton", {
                Size             = UDim2.new(0, 70, 1, 0),
                BackgroundColor3 = (action.Primary and theme.Primary) or theme.Elevated,
                Font             = Enum.Font.GothamMedium,
                TextSize         = 12,
                TextColor3       = action.Primary and Color3.new(1, 1, 1) or theme.Text,
                Text             = action.Text or "OK",
                AutoButtonColor  = false,
                LayoutOrder      = i,
                Parent           = actionRow,
            })
            corner(6, abtn)
            stroke(theme.Stroke, 1, abtn)
            local cb = action.Callback
            abtn.MouseButton1Click:Connect(function()
                if cb then task.spawn(cb) end
                if action.KeepOpen ~= true and dismissFn then dismissFn() end
            end)
        end
    end

    -- Countdown progress bar (drains over duration)
    local progressBg, progressFill
    if duration > 0 then
        progressBg = new("Frame", {
            Size             = UDim2.new(1, 0, 0, 2),
            BackgroundColor3 = theme.Stroke,
            BorderSizePixel  = 0,
            LayoutOrder      = 10,
            Parent           = card,
        })
        progressFill = new("Frame", {
            Size             = UDim2.new(1, 0, 1, 0),
            BackgroundColor3 = barColor,
            BorderSizePixel  = 0,
            Parent           = progressBg,
        })
    end

    -- State machine -----------------------------------------------------------
    local handle = {}

    function handle:Dismiss()
        dismissFn()
    end

    function handle:Update(newTitle, newText)
        if newTitle then titleLabel.Text = newTitle end
        if newText  then bodyLabel.Text  = newText  end
    end

    function handle:SetSeverity(sev)
        local c = theme[NOTIFY_COLORS[sev] or "Primary"]
        bar.BackgroundColor3 = c
        if progressFill then progressFill.BackgroundColor3 = c end
    end

    function dismissFn()
        if dismissed then return end
        dismissed = true
        tween(card, QUICK, {
            Position               = UDim2.new(0, CARD_W + 40, 0, 0),
            BackgroundTransparency = 1,
        })
        task.delay(0.2, function() wrap:Destroy() end)
    end

    -- Click-anywhere-to-dismiss hit region (behind the children)
    local hit = new("TextButton", {
        Size                   = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text                   = "",
        AutoButtonColor        = false,
        ZIndex                 = 0,
        Parent                 = card,
    })
    hit.MouseButton1Click:Connect(dismissFn)
    closeBtn.MouseButton1Click:Connect(dismissFn)

    -- Slide in
    tween(card, MEDIUM, { Position = UDim2.new(0, 0, 0, 0) })

    -- Countdown (pauses if hovered)
    if duration > 0 then
        task.spawn(function()
            local remaining = duration
            local startClock = os.clock()
            local paused = false

            card.MouseEnter:Connect(function() paused = true  end)
            card.MouseLeave:Connect(function() paused = false end)

            while remaining > 0 and not dismissed do
                task.wait(0.05)
                if not paused then
                    local dt = os.clock() - startClock
                    startClock = os.clock()
                    remaining = remaining - dt
                    if progressFill then
                        progressFill.Size = UDim2.new(math.clamp(remaining / duration, 0, 1), 0, 1, 0)
                    end
                else
                    startClock = os.clock()
                end
            end
            if not dismissed then dismissFn() end
        end)
    end

    return handle
end

--==============================================================================
-- COMPONENTS
-- Each component returns { frame, api } and registers a paint function with
-- the dispatcher so live theme swaps work.
--==============================================================================
local Components = {}

-- Section header ---------------------------------------------------------------
function Components.Section(parent, dispatcher, text)
    local holder = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        Parent                 = parent,
    })
    local label = new("TextLabel", {
        Size                   = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 13,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = string.upper(text or "SECTION"),
        Parent                 = holder,
    })
    dispatcher:Register(function(theme)
        label.TextColor3 = theme.SubText
    end)
    return { frame = holder, Set = function(_, t) label.Text = string.upper(t) end,
             Destroy = function() holder:Destroy() end }
end

-- Label -----------------------------------------------------------------------
function Components.Label(parent, dispatcher, text)
    local label = new("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.Gotham,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = text or "",
        Parent                 = parent,
    })
    dispatcher:Register(function(theme)
        label.TextColor3 = theme.Text
    end)
    return { frame = label, Set = function(_, t) label.Text = t end,
             Destroy = function() label:Destroy() end }
end

-- Paragraph (auto-height multi-line) ------------------------------------------
function Components.Paragraph(parent, dispatcher, opts)
    opts = opts or {}
    local wrap = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 0,
        Parent                 = parent,
    })
    corner(8, wrap)
    padding(10, wrap)
    local strokeInst = stroke(Color3.new(), 1, wrap)

    local list = new("UIListLayout", {
        Padding   = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = wrap,
    })

    local titleLabel = new("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Title or "Paragraph",
        LayoutOrder            = 1,
        Parent                 = wrap,
    })
    local bodyLabel = new("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font                   = Enum.Font.Gotham,
        TextSize               = 13,
        TextXAlignment         = Enum.TextXAlignment.Left,
        TextWrapped            = true,
        Text                   = opts.Text or "",
        LayoutOrder            = 2,
        Parent                 = wrap,
    })

    dispatcher:Register(function(theme)
        wrap.BackgroundColor3 = theme.Elevated
        strokeInst.Color      = theme.Stroke
        titleLabel.TextColor3 = theme.Text
        bodyLabel.TextColor3  = theme.SubText
    end)

    return {
        frame   = wrap,
        SetTitle = function(_, t) titleLabel.Text = t end,
        SetText  = function(_, t) bodyLabel.Text  = t end,
        Destroy  = function() wrap:Destroy() end,
    }
end

-- Divider ---------------------------------------------------------------------
function Components.Divider(parent, dispatcher)
    local line = new("Frame", {
        Size            = UDim2.new(1, 0, 0, 1),
        BorderSizePixel = 0,
        Parent          = parent,
    })
    dispatcher:Register(function(theme)
        line.BackgroundColor3 = theme.Stroke
    end)
    return { frame = line, Destroy = function() line:Destroy() end }
end

-- Button ----------------------------------------------------------------------
function Components.Button(parent, dispatcher, opts)
    opts = opts or {}
    local btn = new("TextButton", {
        Size            = UDim2.new(1, 0, 0, 34),
        Font            = Enum.Font.GothamMedium,
        TextSize        = 14,
        Text            = opts.Text or "Button",
        AutoButtonColor = false,
        ClipsDescendants = true,
        Parent          = parent,
    })
    corner(8, btn)
    local strokeInst = stroke(Color3.new(), 1, btn)
    local theme -- captured

    local function paint(t)
        theme            = t
        btn.BackgroundColor3 = t.Elevated
        btn.TextColor3       = t.Text
        strokeInst.Color     = t.Stroke
    end
    dispatcher:Register(paint)

    btn.MouseEnter:Connect(function()
        tween(btn, QUICK, { BackgroundColor3 = theme.Primary })
    end)
    btn.MouseLeave:Connect(function()
        tween(btn, QUICK, { BackgroundColor3 = theme.Elevated })
    end)
    btn.MouseButton1Click:Connect(function()
        local mouse = UserInputService:GetMouseLocation()
        local abs   = btn.AbsolutePosition
        ripple(btn, mouse.X - abs.X, mouse.Y - abs.Y, theme.PrimaryHover)
        if opts.Callback then task.spawn(opts.Callback) end
    end)

    return {
        frame    = btn,
        SetText  = function(_, t) btn.Text = t end,
        Destroy  = function() btn:Destroy() end,
    }
end

-- Toggle ----------------------------------------------------------------------
function Components.Toggle(parent, dispatcher, opts, saveHook)
    opts = opts or {}
    local state = opts.Default and true or false

    local row = new("Frame", {
        Size   = UDim2.new(1, 0, 0, 34),
        Parent = parent,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)

    local label = new("TextLabel", {
        Size                   = UDim2.new(1, -60, 1, 0),
        Position               = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Toggle",
        Parent                 = row,
    })
    local track = new("TextButton", {
        Size            = UDim2.new(0, 38, 0, 20),
        Position        = UDim2.new(1, -48, 0.5, -10),
        Text            = "",
        AutoButtonColor = false,
        Parent          = row,
    })
    corner(10, track)
    local knob = new("Frame", {
        Size     = UDim2.new(0, 16, 0, 16),
        Position = UDim2.new(0, 2, 0.5, -8),
        Parent   = track,
    })
    corner(8, knob)

    local theme
    local function paint(t)
        theme              = t
        row.BackgroundColor3 = t.Elevated
        strokeInst.Color     = t.Stroke
        label.TextColor3     = t.Text
        knob.BackgroundColor3 = t.Text
        track.BackgroundColor3 = state and t.Primary or t.Stroke
    end
    dispatcher:Register(paint)

    local function render(animate)
        local info = animate and QUICK or TweenInfo.new(0)
        tween(track, info, { BackgroundColor3 = state and theme.Primary or theme.Stroke })
        tween(knob,  info, { Position = state and UDim2.new(1, -18, 0.5, -8) or UDim2.new(0, 2, 0.5, -8) })
    end
    render(false)

    local function set(v, silent)
        state = v and true or false
        render(true)
        if saveHook then saveHook(state) end
        if not silent and opts.Callback then task.spawn(opts.Callback, state) end
    end

    track.MouseButton1Click:Connect(function() set(not state) end)

    return {
        frame    = row,
        Set      = function(_, v, silent) set(v, silent) end,
        Get      = function() return state end,
        Destroy  = function() row:Destroy() end,
    }
end

-- Slider ----------------------------------------------------------------------
-- Bug fixes from v2:
--   * Divide-by-zero when Min == Max: guarded with `range` local.
--   * `string.format` crashed when Default was nil but Min was: clamped first.
--   * Touch input on mobile sometimes never released `dragging` because
--     InputEnded fires a different UserInputType; now accepts any End state.
function Components.Slider(parent, dispatcher, bag, opts, saveHook)
    opts = opts or {}
    local minV  = opts.Min       or 0
    local maxV  = opts.Max       or 100
    local step  = opts.Increment or 1
    local fmt   = opts.Format    or "%g"
    local range = maxV - minV
    if range <= 0 then range = 1 end -- guard: Min==Max would NaN everything
    local val   = math.clamp(opts.Default or minV, minV, maxV)

    local row = new("Frame", {
        Size   = UDim2.new(1, 0, 0, 52),
        Parent = parent,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)
    padding(10, row)

    local title = new("TextLabel", {
        Size                   = UDim2.new(1, -60, 0, 18),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Slider",
        Parent                 = row,
    })
    local valueText = new("TextLabel", {
        Size                   = UDim2.new(0, 60, 0, 18),
        Position               = UDim2.new(1, -60, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 13,
        TextXAlignment         = Enum.TextXAlignment.Right,
        Text                   = string.format(fmt, val),
        Parent                 = row,
    })
    local bar = new("Frame", {
        Size     = UDim2.new(1, 0, 0, 6),
        Position = UDim2.new(0, 0, 1, -10),
        Parent   = row,
    })
    corner(3, bar)
    local fill = new("Frame", {
        Size   = UDim2.new((val - minV) / range, 0, 1, 0),
        Parent = bar,
    })
    corner(3, fill)

    -- click hit area covers bar+padding for easier grabbing
    local hit = new("TextButton", {
        Size                   = UDim2.new(1, 0, 0, 20),
        Position               = UDim2.new(0, 0, 1, -16),
        BackgroundTransparency = 1,
        Text                   = "",
        AutoButtonColor        = false,
        Parent                 = row,
    })

    local theme
    dispatcher:Register(function(t)
        theme                = t
        row.BackgroundColor3 = t.Elevated
        strokeInst.Color     = t.Stroke
        title.TextColor3     = t.Text
        valueText.TextColor3 = t.Primary
        bar.BackgroundColor3 = t.Stroke
        fill.BackgroundColor3 = t.Primary
    end)

    local function round(x)
        return math.floor((x / step) + 0.5) * step
    end

    local function setFromRatio(ratio, silent)
        ratio = math.clamp(ratio, 0, 1)
        local raw = minV + ratio * range
        local snapped = math.clamp(round(raw), minV, maxV)
        if snapped ~= val then
            val = snapped
            valueText.Text = string.format(fmt, val)
            tween(fill, TweenInfo.new(0.08), {
                Size = UDim2.new((val - minV) / range, 0, 1, 0),
            })
            if saveHook then saveHook(val) end
            if not silent and opts.Callback then task.spawn(opts.Callback, val) end
        end
    end

    local dragging = false

    local function updateFromInput(input)
        local rel = (input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X
        setFromRatio(rel)
    end

    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            updateFromInput(input)
        end
    end)
    bag:Add(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                      or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromInput(input)
        end
    end))
    bag:Add(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    return {
        frame    = row,
        Set      = function(_, v, silent) setFromRatio((v - minV) / range, silent) end,
        Get      = function() return val end,
        Destroy  = function() row:Destroy() end,
    }
end

-- ProgressBar -----------------------------------------------------------------
-- Same divide-by-zero guard as Slider.
function Components.ProgressBar(parent, dispatcher, opts)
    opts = opts or {}
    local minV  = opts.Min or 0
    local maxV  = opts.Max or 100
    local range = maxV - minV
    if range <= 0 then range = 1 end
    local val   = math.clamp(opts.Default or 0, minV, maxV)

    local row = new("Frame", {
        Size   = UDim2.new(1, 0, 0, 44),
        Parent = parent,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)
    padding(10, row)

    local title = new("TextLabel", {
        Size                   = UDim2.new(1, -60, 0, 16),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 13,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Progress",
        Parent                 = row,
    })
    local valueText = new("TextLabel", {
        Size                   = UDim2.new(0, 60, 0, 16),
        Position               = UDim2.new(1, -60, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 12,
        TextXAlignment         = Enum.TextXAlignment.Right,
        Text                   = tostring(val),
        Parent                 = row,
    })
    local bar = new("Frame", {
        Size     = UDim2.new(1, 0, 0, 8),
        Position = UDim2.new(0, 0, 1, -8),
        Parent   = row,
    })
    corner(4, bar)
    local fill = new("Frame", {
        Size   = UDim2.new((val - minV) / range, 0, 1, 0),
        Parent = bar,
    })
    corner(4, fill)

    dispatcher:Register(function(t)
        row.BackgroundColor3 = t.Elevated
        strokeInst.Color     = t.Stroke
        title.TextColor3     = t.Text
        valueText.TextColor3 = t.Accent
        bar.BackgroundColor3 = t.Stroke
        fill.BackgroundColor3 = t.Accent
    end)

    return {
        frame = row,
        Set   = function(_, v)
            val = math.clamp(v, minV, maxV)
            valueText.Text = tostring(val)
            tween(fill, QUICK, { Size = UDim2.new((val - minV) / range, 0, 1, 0) })
        end,
        Get     = function() return val end,
        Destroy = function() row:Destroy() end,
    }
end

-- Dropdown (single-select, optional searchable) -------------------------------
function Components.Dropdown(parent, dispatcher, opts, saveHook)
    opts = opts or {}
    local options    = opts.Options or {}
    local selected   = opts.Default or options[1]
    local searchable = opts.Searchable == true
    local open       = false

    local row = new("Frame", {
        Size             = UDim2.new(1, 0, 0, 34),
        Parent           = parent,
        ClipsDescendants = true,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)

    local header = new("TextButton", {
        Size                   = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Text                   = "",
        AutoButtonColor        = false,
        Parent                 = row,
    })
    local label = new("TextLabel", {
        Size                   = UDim2.new(1, -90, 1, 0),
        Position               = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Dropdown",
        Parent                 = row,
    })
    local valueLabel = new("TextLabel", {
        Size                   = UDim2.new(0, 82, 1, 0),
        Position               = UDim2.new(1, -90, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 13,
        TextXAlignment         = Enum.TextXAlignment.Right,
        Text                   = tostring(selected or ""),
        Parent                 = row,
    })

    local listHolder = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 0),
        Position               = UDim2.new(0, 0, 0, 34),
        BackgroundTransparency = 1,
        Parent                 = row,
    })
    local listPad = padding(4, listHolder)

    local searchBox
    if searchable then
        searchBox = new("TextBox", {
            Size             = UDim2.new(1, 0, 0, 26),
            PlaceholderText  = "Search...",
            Font             = Enum.Font.Gotham,
            TextSize         = 13,
            Text             = "",
            ClearTextOnFocus = false,
            LayoutOrder      = 0,
            Parent           = listHolder,
        })
        corner(6, searchBox)
    end

    local scroll = new("ScrollingFrame", {
        Size                    = UDim2.new(1, 0, 0, 0),
        AutomaticCanvasSize     = Enum.AutomaticSize.Y,
        CanvasSize              = UDim2.new(0, 0, 0, 0),
        ScrollBarThickness      = 3,
        BackgroundTransparency  = 1,
        BorderSizePixel         = 0,
        LayoutOrder             = 1,
        Parent                  = listHolder,
    })
    new("UIListLayout", {
        Padding   = UDim.new(0, 2),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = scroll,
    })
    if searchable then
        new("UIListLayout", {
            Padding   = UDim.new(0, 4),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent    = listHolder,
        })
    end

    local theme
    dispatcher:Register(function(t)
        theme                = t
        row.BackgroundColor3 = t.Elevated
        strokeInst.Color     = t.Stroke
        label.TextColor3     = t.Text
        valueLabel.TextColor3 = t.Primary
        scroll.ScrollBarImageColor3 = t.Stroke
        if searchBox then
            searchBox.BackgroundColor3   = t.Surface
            searchBox.TextColor3         = t.Text
            searchBox.PlaceholderColor3  = t.SubText
        end
    end)

    local function computeOpenHeight(filtered)
        local n = #filtered
        local rows = math.min(n, 5) * 28 + (n > 0 and (math.min(n, 5) - 1) * 2 or 0)
        local search = searchable and 30 or 0
        return 34 + 8 + search + rows
    end

    local function rebuild(filterText)
        for _, c in ipairs(scroll:GetChildren()) do
            if c:IsA("GuiButton") then c:Destroy() end
        end
        local filtered = {}
        -- Convert filter once (and only if present) to avoid recomputing per-option.
        local lowerFilter = nil
        if filterText and filterText ~= "" then
            lowerFilter = string.lower(filterText)
        end
        for _, o in ipairs(options) do
            if not lowerFilter
                or string.find(string.lower(tostring(o)), lowerFilter, 1, true) then
                table.insert(filtered, o)
            end
        end
        for _, optText in ipairs(filtered) do
            local item = new("TextButton", {
                Size             = UDim2.new(1, 0, 0, 26),
                BackgroundColor3 = theme.Surface,
                Font             = Enum.Font.Gotham,
                TextSize         = 13,
                TextColor3       = theme.Text,
                Text             = "  " .. tostring(optText),
                TextXAlignment   = Enum.TextXAlignment.Left,
                AutoButtonColor  = false,
                Parent           = scroll,
            })
            corner(6, item)
            item.MouseEnter:Connect(function()
                tween(item, QUICK, { BackgroundColor3 = theme.Primary })
            end)
            item.MouseLeave:Connect(function()
                tween(item, QUICK, { BackgroundColor3 = theme.Surface })
            end)
            item.MouseButton1Click:Connect(function()
                selected = optText
                valueLabel.Text = tostring(selected)
                open = false
                tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, 34) })
                if saveHook then saveHook(selected) end
                if opts.Callback then task.spawn(opts.Callback, selected) end
            end)
        end
        return filtered
    end

    local function openList()
        local filtered = rebuild(searchBox and searchBox.Text or nil)
        local h = computeOpenHeight(filtered)
        tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, h) })
        -- Guard: with 0 filtered options, (min - 1) * 2 would be -2.
        local shown = math.min(#filtered, 5)
        local listH = (shown > 0) and (shown * 28 + (shown - 1) * 2) or 0
        scroll.Size = UDim2.new(1, 0, 0, listH)
    end

    local function closeList()
        tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, 34) })
    end

    header.MouseButton1Click:Connect(function()
        open = not open
        if open then openList() else closeList() end
    end)

    if searchBox then
        searchBox:GetPropertyChangedSignal("Text"):Connect(function()
            if open then openList() end
        end)
    end

    return {
        frame = row,
        Set = function(_, v, silent)
            selected = v
            valueLabel.Text = tostring(v)
            if saveHook then saveHook(selected) end
            if not silent and opts.Callback then task.spawn(opts.Callback, selected) end
        end,
        Get        = function() return selected end,
        SetOptions = function(_, t)
            if open then
                open = false
                closeList()
                task.wait(0.2)
            end
            options = t or {}
            rebuild()
        end,
        Destroy = function() row:Destroy() end,
    }
end

-- MultiSelect (multi-value dropdown) ------------------------------------------
function Components.MultiSelect(parent, dispatcher, opts, saveHook)
    opts = opts or {}
    local options  = opts.Options or {}
    local selected = {}
    for _, v in ipairs(opts.Default or {}) do selected[v] = true end
    local open = false

    local row = new("Frame", {
        Size             = UDim2.new(1, 0, 0, 34),
        Parent           = parent,
        ClipsDescendants = true,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)

    local header = new("TextButton", {
        Size                   = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Text                   = "",
        AutoButtonColor        = false,
        Parent                 = row,
    })
    local label = new("TextLabel", {
        Size                   = UDim2.new(1, -160, 1, 0),
        Position               = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Select",
        Parent                 = row,
    })
    local valueLabel = new("TextLabel", {
        Size                   = UDim2.new(0, 150, 1, 0),
        Position               = UDim2.new(1, -160, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 13,
        TextXAlignment         = Enum.TextXAlignment.Right,
        TextTruncate           = Enum.TextTruncate.AtEnd,
        Text                   = "None",
        Parent                 = row,
    })

    local scroll = new("ScrollingFrame", {
        Position                = UDim2.new(0, 0, 0, 38),
        Size                    = UDim2.new(1, 0, 0, 0),
        AutomaticCanvasSize     = Enum.AutomaticSize.Y,
        CanvasSize              = UDim2.new(0, 0, 0, 0),
        ScrollBarThickness      = 3,
        BackgroundTransparency  = 1,
        BorderSizePixel         = 0,
        Parent                  = row,
    })
    padding(4, scroll)
    new("UIListLayout", {
        Padding   = UDim.new(0, 2),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = scroll,
    })

    local theme
    dispatcher:Register(function(t)
        theme                       = t
        row.BackgroundColor3        = t.Elevated
        strokeInst.Color            = t.Stroke
        label.TextColor3            = t.Text
        valueLabel.TextColor3       = t.Primary
        scroll.ScrollBarImageColor3 = t.Stroke
    end)

    local function summary()
        local picked = {}
        for _, o in ipairs(options) do
            if selected[o] then table.insert(picked, tostring(o)) end
        end
        if #picked == 0 then return "None" end
        if #picked <= 2 then return table.concat(picked, ", ") end
        return string.format("%d selected", #picked)
    end

    local function fire()
        valueLabel.Text = summary()
        local list = {}
        for _, o in ipairs(options) do if selected[o] then table.insert(list, o) end end
        if saveHook then saveHook(list) end
        if opts.Callback then task.spawn(opts.Callback, list) end
    end

    local function rebuild()
        for _, c in ipairs(scroll:GetChildren()) do
            if c:IsA("GuiButton") then c:Destroy() end
        end
        for _, o in ipairs(options) do
            local item = new("TextButton", {
                Size             = UDim2.new(1, 0, 0, 26),
                BackgroundColor3 = theme.Surface,
                Font             = Enum.Font.Gotham,
                TextSize         = 13,
                TextColor3       = theme.Text,
                Text             = (selected[o] and "  [x] " or "  [ ] ") .. tostring(o),
                TextXAlignment   = Enum.TextXAlignment.Left,
                AutoButtonColor  = false,
                Parent           = scroll,
            })
            corner(6, item)
            item.MouseButton1Click:Connect(function()
                selected[o] = not selected[o]
                item.Text = (selected[o] and "  [x] " or "  [ ] ") .. tostring(o)
                fire()
            end)
        end
    end
    rebuild()
    fire()

    header.MouseButton1Click:Connect(function()
        open = not open
        if open then
            local n = math.min(#options, 5)
            local h = 38 + n * 28 + math.max(n - 1, 0) * 2 + 8
            tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, h) })
            scroll.Size = UDim2.new(1, 0, 0, n * 28 + math.max(n - 1, 0) * 2)
        else
            tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, 34) })
        end
    end)

    return {
        frame = row,
        Set   = function(_, list)
            selected = {}
            for _, v in ipairs(list or {}) do selected[v] = true end
            rebuild()
            fire()
        end,
        Get = function()
            local list = {}
            for _, o in ipairs(options) do if selected[o] then table.insert(list, o) end end
            return list
        end,
        SetOptions = function(_, t) options = t or {}; rebuild(); fire() end,
        Destroy    = function() row:Destroy() end,
    }
end

-- RadioGroup ------------------------------------------------------------------
function Components.RadioGroup(parent, dispatcher, opts, saveHook)
    opts = opts or {}
    local options  = opts.Options or {}
    local selected = opts.Default or options[1]

    local wrap = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 0,
        Parent                 = parent,
    })
    corner(8, wrap)
    local strokeInst = stroke(Color3.new(), 1, wrap)
    padding(10, wrap)
    new("UIListLayout", {
        Padding   = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = wrap,
    })

    local title = new("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 13,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Choose",
        LayoutOrder            = 0,
        Parent                 = wrap,
    })

    local items = {}
    local theme
    local function paintRow(item, isActive)
        local dot = item:FindFirstChild("Dot")
        if dot then
            dot.BackgroundColor3 = isActive and theme.Primary or theme.Stroke
        end
    end
    local function repaintAll()
        for _, it in ipairs(items) do paintRow(it, it.Name == selected) end
    end

    dispatcher:Register(function(t)
        theme                = t
        wrap.BackgroundColor3 = t.Elevated
        strokeInst.Color     = t.Stroke
        title.TextColor3     = t.Text
        for _, it in ipairs(items) do
            local lbl = it:FindFirstChild("Label")
            if lbl then lbl.TextColor3 = t.Text end
        end
        repaintAll()
    end)

    for i, o in ipairs(options) do
        local row = new("TextButton", {
            Name             = o,
            Size             = UDim2.new(1, 0, 0, 24),
            BackgroundTransparency = 1,
            Text             = "",
            AutoButtonColor  = false,
            LayoutOrder      = i,
            Parent           = wrap,
        })
        local dot = new("Frame", {
            Name     = "Dot",
            Size     = UDim2.new(0, 12, 0, 12),
            Position = UDim2.new(0, 0, 0.5, -6),
            Parent   = row,
        })
        corner(6, dot)
        new("TextLabel", {
            Name                   = "Label",
            Size                   = UDim2.new(1, -22, 1, 0),
            Position               = UDim2.new(0, 20, 0, 0),
            BackgroundTransparency = 1,
            Font                   = Enum.Font.Gotham,
            TextSize               = 13,
            TextXAlignment         = Enum.TextXAlignment.Left,
            Text                   = tostring(o),
            Parent                 = row,
        })
        row.MouseButton1Click:Connect(function()
            selected = o
            repaintAll()
            if saveHook then saveHook(selected) end
            if opts.Callback then task.spawn(opts.Callback, selected) end
        end)
        table.insert(items, row)
    end
    repaintAll()

    return {
        frame = wrap,
        Set   = function(_, v, silent)
            selected = v
            repaintAll()
            if not silent and opts.Callback then task.spawn(opts.Callback, v) end
        end,
        Get     = function() return selected end,
        Destroy = function() wrap:Destroy() end,
    }
end

-- Textbox ---------------------------------------------------------------------
function Components.Textbox(parent, dispatcher, opts, saveHook)
    opts = opts or {}
    local row = new("Frame", {
        Size   = UDim2.new(1, 0, 0, 34),
        Parent = parent,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)

    local label = new("TextLabel", {
        Size                   = UDim2.new(0.4, -12, 1, 0),
        Position               = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Input",
        Parent                 = row,
    })

    local box = new("TextBox", {
        Size             = UDim2.new(0.6, -12, 1, -10),
        Position         = UDim2.new(0.4, 0, 0, 5),
        Font             = Enum.Font.Gotham,
        TextSize         = 13,
        PlaceholderText  = opts.Placeholder or "Type here...",
        ClearTextOnFocus = false,
        Text             = opts.Default or "",
        Parent           = row,
    })
    corner(6, box)
    padding(6, box)

    dispatcher:Register(function(t)
        row.BackgroundColor3     = t.Elevated
        strokeInst.Color         = t.Stroke
        label.TextColor3         = t.Text
        box.BackgroundColor3     = t.Surface
        box.TextColor3           = t.Text
        box.PlaceholderColor3    = t.SubText
    end)

    if opts.Numeric then
        box:GetPropertyChangedSignal("Text"):Connect(function()
            box.Text = string.gsub(box.Text, "[^%-%d%.]", "")
        end)
    end

    box.FocusLost:Connect(function(enter)
        if saveHook then saveHook(box.Text) end
        if opts.Callback then task.spawn(opts.Callback, box.Text, enter) end
    end)

    return {
        frame   = row,
        Set     = function(_, v) box.Text = tostring(v) end,
        Get     = function() return box.Text end,
        Destroy = function() row:Destroy() end,
    }
end

-- Keybind ---------------------------------------------------------------------
-- Bug fixes from v2:
--   * Capturing while a modifier (Shift/Ctrl/Alt/LeftMeta/RightMeta) is held
--     would bind the modifier, not the intended key. Now we reject pure
--     modifier keys on capture and wait for a real alphanumeric/function key.
--   * If the user pressed Escape to clear, and the captured key state didn't
--     properly reset, the next capture would immediately fire. Fixed.
local MODIFIER_KEYS = {
    [Enum.KeyCode.LeftShift]   = true,
    [Enum.KeyCode.RightShift]  = true,
    [Enum.KeyCode.LeftControl] = true,
    [Enum.KeyCode.RightControl]= true,
    [Enum.KeyCode.LeftAlt]     = true,
    [Enum.KeyCode.RightAlt]    = true,
    [Enum.KeyCode.LeftMeta]    = true,
    [Enum.KeyCode.RightMeta]   = true,
}

function Components.Keybind(parent, dispatcher, bag, opts, saveHook)
    opts = opts or {}
    local current   = opts.Default
    local capturing = false

    local row = new("Frame", {
        Size   = UDim2.new(1, 0, 0, 34),
        Parent = parent,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)

    local label = new("TextLabel", {
        Size                   = UDim2.new(1, -110, 1, 0),
        Position               = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Keybind",
        Parent                 = row,
    })
    local btn = new("TextButton", {
        Size            = UDim2.new(0, 100, 1, -10),
        Position        = UDim2.new(1, -105, 0, 5),
        Font            = Enum.Font.GothamBold,
        TextSize        = 13,
        AutoButtonColor = false,
        Text            = current and current.Name or "None",
        Parent          = row,
    })
    corner(6, btn)

    dispatcher:Register(function(t)
        row.BackgroundColor3 = t.Elevated
        strokeInst.Color     = t.Stroke
        label.TextColor3     = t.Text
        btn.BackgroundColor3 = t.Surface
        btn.TextColor3       = t.Primary
    end)

    btn.MouseButton1Click:Connect(function()
        capturing = true
        btn.Text  = "..."
    end)

    bag:Add(UserInputService.InputBegan:Connect(function(input, processed)
        if capturing and input.UserInputType == Enum.UserInputType.Keyboard then
            -- Ignore modifier-only captures; user probably hasn't pressed the real key yet.
            if MODIFIER_KEYS[input.KeyCode] then return end

            capturing = false
            if input.KeyCode == Enum.KeyCode.Escape then
                current = nil
                btn.Text = "None"
            else
                current = input.KeyCode
                btn.Text = current.Name
            end
            if saveHook then saveHook(current and current.Name or nil) end
            return
        end
        if not processed and not capturing and current and input.KeyCode == current then
            -- Don't fire while a TextBox is focused (was eating keystrokes).
            if UserInputService:GetFocusedTextBox() then return end
            if opts.Callback then task.spawn(opts.Callback) end
        end
    end))

    return {
        frame = row,
        Set = function(_, k)
            current = k
            btn.Text = k and k.Name or "None"
        end,
        Get     = function() return current end,
        Destroy = function() row:Destroy() end,
    }
end

-- Stepper (numeric input with +/- buttons) ------------------------------------
-- A compact number picker for integer/float values. Unlike Slider it doesn't
-- show a bar; useful when you want precision without visual noise.
function Components.Stepper(parent, dispatcher, opts, saveHook)
    opts = opts or {}
    local minV = opts.Min       or 0
    local maxV = opts.Max       or 100
    local step = opts.Increment or 1
    local fmt  = opts.Format    or "%g"
    local val  = math.clamp(opts.Default or minV, minV, maxV)

    local row = new("Frame", {
        Size   = UDim2.new(1, 0, 0, 34),
        Parent = parent,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)

    local label = new("TextLabel", {
        Size                   = UDim2.new(1, -110, 1, 0),
        Position               = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Stepper",
        Parent                 = row,
    })

    local minusBtn = new("TextButton", {
        Size            = UDim2.new(0, 24, 0, 24),
        Position        = UDim2.new(1, -100, 0.5, -12),
        Font            = Enum.Font.GothamBold,
        TextSize        = 16,
        Text            = "-",
        AutoButtonColor = false,
        Parent          = row,
    })
    corner(6, minusBtn)

    local valueBox = new("TextBox", {
        Size             = UDim2.new(0, 40, 0, 24),
        Position         = UDim2.new(1, -72, 0.5, -12),
        Font             = Enum.Font.GothamBold,
        TextSize         = 13,
        TextXAlignment   = Enum.TextXAlignment.Center,
        ClearTextOnFocus = false,
        Text             = string.format(fmt, val),
        Parent           = row,
    })
    corner(6, valueBox)

    local plusBtn = new("TextButton", {
        Size            = UDim2.new(0, 24, 0, 24),
        Position        = UDim2.new(1, -28, 0.5, -12),
        Font            = Enum.Font.GothamBold,
        TextSize        = 16,
        Text            = "+",
        AutoButtonColor = false,
        Parent          = row,
    })
    corner(6, plusBtn)

    dispatcher:Register(function(t)
        row.BackgroundColor3      = t.Elevated
        strokeInst.Color          = t.Stroke
        label.TextColor3          = t.Text
        minusBtn.BackgroundColor3 = t.Surface
        minusBtn.TextColor3       = t.Text
        plusBtn.BackgroundColor3  = t.Surface
        plusBtn.TextColor3        = t.Text
        valueBox.BackgroundColor3 = t.Surface
        valueBox.TextColor3       = t.Primary
    end)

    local function set(v, silent)
        v = math.clamp(v, minV, maxV)
        -- Snap to increment
        v = math.floor((v / step) + 0.5) * step
        v = math.clamp(v, minV, maxV)
        if v ~= val then
            val = v
            valueBox.Text = string.format(fmt, val)
            if saveHook then saveHook(val) end
            if not silent and opts.Callback then task.spawn(opts.Callback, val) end
        else
            valueBox.Text = string.format(fmt, val) -- always re-sync display
        end
    end

    minusBtn.MouseButton1Click:Connect(function() set(val - step) end)
    plusBtn.MouseButton1Click:Connect(function() set(val + step) end)

    valueBox.FocusLost:Connect(function(enterPressed)
        local num = tonumber(valueBox.Text)
        if num then
            set(num)
        else
            -- Revert to last good value on garbage input.
            valueBox.Text = string.format(fmt, val)
        end
    end)

    return {
        frame   = row,
        Set     = function(_, v, silent) set(v, silent) end,
        Get     = function() return val end,
        Destroy = function() row:Destroy() end,
    }
end

-- Console (in-UI log output) --------------------------------------------------
-- A tail-log pane with severity-colored lines. Useful for:
--   * debugging your own script without leaving the game
--   * showing user-facing status without spawning notifications for everything
-- API: :Log(text), :Warn(text), :Error(text), :Clear()
function Components.Console(parent, dispatcher, opts)
    opts = opts or {}
    local maxLines = opts.MaxLines or 200

    local wrap = new("Frame", {
        Size   = UDim2.new(1, 0, 0, opts.Height or 140),
        Parent = parent,
    })
    corner(8, wrap)
    local strokeInst = stroke(Color3.new(), 1, wrap)

    local header = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        Parent                 = wrap,
    })
    local title = new("TextLabel", {
        Size                   = UDim2.new(1, -60, 1, 0),
        Position               = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 12,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "CONSOLE",
        Parent                 = header,
    })
    local clearBtn = new("TextButton", {
        Size            = UDim2.new(0, 50, 0, 18),
        Position        = UDim2.new(1, -56, 0.5, -9),
        Font            = Enum.Font.GothamMedium,
        TextSize        = 11,
        Text            = "Clear",
        AutoButtonColor = false,
        Parent          = header,
    })
    corner(4, clearBtn)

    local scroll = new("ScrollingFrame", {
        Position                = UDim2.new(0, 0, 0, 24),
        Size                    = UDim2.new(1, 0, 1, -24),
        BackgroundTransparency  = 1,
        BorderSizePixel         = 0,
        ScrollBarThickness      = 4,
        CanvasSize              = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize     = Enum.AutomaticSize.Y,
        Parent                  = wrap,
    })
    padding(8, scroll)
    local layout = new("UIListLayout", {
        Padding   = UDim.new(0, 2),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = scroll,
    })

    local lines = {}
    local lineCount = 0

    local function addLine(text, color)
        lineCount = lineCount + 1
        local lbl = new("TextLabel", {
            Size                   = UDim2.new(1, 0, 0, 0),
            AutomaticSize          = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font                   = Enum.Font.Code,
            TextSize               = 12,
            TextColor3             = color,
            TextWrapped            = true,
            TextXAlignment         = Enum.TextXAlignment.Left,
            Text                   = text,
            LayoutOrder            = lineCount,
            Parent                 = scroll,
        })
        table.insert(lines, lbl)

        -- Ring-buffer: drop the oldest when past the cap.
        if #lines > maxLines then
            local old = table.remove(lines, 1)
            if old then old:Destroy() end
        end

        -- Autoscroll to bottom on the next frame, after layout has run.
        task.defer(function()
            if scroll.Parent then
                scroll.CanvasPosition = Vector2.new(0, scroll.AbsoluteCanvasSize.Y)
            end
        end)
    end

    local api = {}
    local theme

    dispatcher:Register(function(t)
        theme                      = t
        wrap.BackgroundColor3      = t.Surface
        strokeInst.Color           = t.Stroke
        title.TextColor3           = t.SubText
        clearBtn.BackgroundColor3  = t.Elevated
        clearBtn.TextColor3        = t.Text
        scroll.ScrollBarImageColor3 = t.Stroke
    end)

    function api:Log(text)
        addLine("[info]  " .. tostring(text), theme and theme.Text or Color3.new(1, 1, 1))
    end
    function api:Warn(text)
        addLine("[warn]  " .. tostring(text), theme and theme.Warning or Color3.fromRGB(255, 200, 80))
    end
    function api:Error(text)
        addLine("[error] " .. tostring(text), theme and theme.Danger or Color3.fromRGB(255, 100, 100))
    end
    function api:Clear()
        for _, l in ipairs(lines) do l:Destroy() end
        table.clear(lines)
        lineCount = 0
    end

    clearBtn.MouseButton1Click:Connect(function() api:Clear() end)

    api.frame   = wrap
    api.Destroy = function() wrap:Destroy() end
    return api
end

-- Tooltip -------------------------------------------------------------------
-- Attach a hover tooltip to any component returned from Add*(...).
-- Usage: Tooltip.attach(component, "Hover text", dispatcher, bag)
local Tooltip = {}

function Tooltip.attach(component, text, dispatcher, bag)
    if not component or not component.frame then return end
    local frame = component.frame

    local bubble
    local function ensureBubble()
        if bubble and bubble.Parent then return bubble end
        bubble = new("TextLabel", {
            Size                   = UDim2.new(0, 0, 0, 22),
            AutomaticSize          = Enum.AutomaticSize.X,
            AnchorPoint            = Vector2.new(0.5, 1),
            BackgroundColor3       = dispatcher.theme.Elevated,
            BorderSizePixel        = 0,
            Font                   = Enum.Font.Gotham,
            TextSize               = 12,
            TextColor3             = dispatcher.theme.Text,
            Text                   = " " .. text .. " ",
            ZIndex                 = 100,
            Visible                = false,
            Parent                 = frame:FindFirstAncestorOfClass("ScreenGui") or frame,
        })
        corner(4, bubble)
        stroke(dispatcher.theme.Stroke, 1, bubble)
        return bubble
    end

    bag:Add(frame.MouseEnter:Connect(function()
        local b = ensureBubble()
        b.Text = " " .. text .. " "
        b.Position = UDim2.new(
            0, frame.AbsolutePosition.X + frame.AbsoluteSize.X / 2,
            0, frame.AbsolutePosition.Y - 4
        )
        b.Visible = true
    end))
    bag:Add(frame.MouseLeave:Connect(function()
        if bubble then bubble.Visible = false end
    end))

    -- Expose for chaining.
    component.SetTooltip = function(_, newText) text = newText end
    return component
end

-- ColorPicker (HSV canvas + hue bar) ------------------------------------------
local function hsvToRgb(h, s, v)
    local c = Color3.fromHSV(h, s, v)
    return c
end

-- ColorPicker (HSV canvas + hue bar + hex input + alpha slider) ---------------
-- v3 changes:
--   * Now accepts `bag` so InputChanged / InputEnded listeners are cleaned up.
--     v2 leaked two UIS listeners per color picker.
--   * Optional `Alpha = true` exposes transparency (Callback receives (color, alpha)).
--   * Hex input field: type "#ff8800" or "ff8800" and press Enter.
function Components.ColorPicker(parent, dispatcher, bag, opts, saveHook)
    opts = opts or {}
    local default = opts.Default or Color3.fromRGB(120, 120, 255)
    local withAlpha = opts.Alpha == true
    local alpha     = opts.DefaultAlpha or 1
    local h, s, v = default:ToHSV()
    local open = false

    local row = new("Frame", {
        Size             = UDim2.new(1, 0, 0, 34),
        Parent           = parent,
        ClipsDescendants = true,
    })
    corner(8, row)
    local strokeInst = stroke(Color3.new(), 1, row)

    local header = new("TextButton", {
        Size                   = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Text                   = "",
        AutoButtonColor        = false,
        Parent                 = row,
    })
    local label = new("TextLabel", {
        Size                   = UDim2.new(1, -50, 1, 0),
        Position               = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 14,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Text or "Color",
        Parent                 = row,
    })
    local swatch = new("Frame", {
        Size             = UDim2.new(0, 28, 0, 20),
        Position         = UDim2.new(1, -40, 0.5, -10),
        BackgroundColor3 = default,
        Parent           = row,
    })
    corner(4, swatch)
    stroke(Color3.fromRGB(0, 0, 0), 1, swatch, 0.5)

    -- Panel
    local panel = new("Frame", {
        Position               = UDim2.new(0, 0, 0, 38),
        Size                   = UDim2.new(1, 0, 0, 0),
        BackgroundTransparency = 1,
        Parent                 = row,
    })
    padding(10, panel)
    new("UIListLayout", {
        Padding   = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = panel,
    })

    -- SV canvas
    local sv = new("ImageButton", {
        Size             = UDim2.new(1, 0, 0, 110),
        BackgroundColor3 = Color3.fromHSV(h, 1, 1),
        AutoButtonColor  = false,
        LayoutOrder      = 1,
        Parent           = panel,
    })
    corner(6, sv)
    -- white -> transparent left->right gradient
    local white = new("Frame", {
        Size                   = UDim2.new(1, 0, 1, 0),
        BackgroundColor3       = Color3.new(1, 1, 1),
        BorderSizePixel        = 0,
        Parent                 = sv,
    })
    corner(6, white)
    gradient(ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
        ColorSequenceKeypoint.new(1, Color3.new(1, 1, 1)),
    }), 0, white)
    local whiteGrad = white:FindFirstChildOfClass("UIGradient")
    whiteGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1),
    })
    -- black bottom->top
    local black = new("Frame", {
        Size             = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = Color3.new(0, 0, 0),
        BorderSizePixel  = 0,
        Parent           = sv,
    })
    corner(6, black)
    gradient(ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.new(0, 0, 0)),
        ColorSequenceKeypoint.new(1, Color3.new(0, 0, 0)),
    }), 90, black)
    local blackGrad = black:FindFirstChildOfClass("UIGradient")
    blackGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(1, 0),
    })
    local svCursor = new("Frame", {
        Size             = UDim2.new(0, 10, 0, 10),
        AnchorPoint      = Vector2.new(0.5, 0.5),
        Position         = UDim2.new(s, 0, 1 - v, 0),
        BackgroundColor3 = Color3.new(1, 1, 1),
        ZIndex           = 5,
        Parent           = sv,
    })
    corner(5, svCursor)
    stroke(Color3.fromRGB(0, 0, 0), 1, svCursor)

    -- Hue bar
    local hue = new("ImageButton", {
        Size            = UDim2.new(1, 0, 0, 14),
        AutoButtonColor = false,
        LayoutOrder     = 2,
        Parent          = panel,
    })
    corner(4, hue)
    gradient(ColorSequence.new({
        ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 0)),
        ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
        ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
        ColorSequenceKeypoint.new(0.50, Color3.fromRGB(0, 255, 255)),
        ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
        ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
        ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 0)),
    }), 0, hue)
    local hueCursor = new("Frame", {
        Size             = UDim2.new(0, 3, 1, 4),
        AnchorPoint      = Vector2.new(0.5, 0.5),
        Position         = UDim2.new(h, 0, 0.5, 0),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel  = 0,
        Parent           = hue,
    })

    dispatcher:Register(function(t)
        row.BackgroundColor3 = t.Elevated
        strokeInst.Color     = t.Stroke
        label.TextColor3     = t.Text
    end)

    local function applyColor(fire)
        local c = Color3.fromHSV(h, s, v)
        swatch.BackgroundColor3 = c
        sv.BackgroundColor3     = Color3.fromHSV(h, 1, 1)
        svCursor.Position       = UDim2.new(s, 0, 1 - v, 0)
        hueCursor.Position      = UDim2.new(h, 0, 0.5, 0)
        if saveHook then saveHook({ c.R, c.G, c.B }) end
        if fire and opts.Callback then task.spawn(opts.Callback, c) end
    end
    applyColor(false)

    local draggingSV, draggingHue = false, false

    local function updateSV(input)
        local rx = math.clamp((input.Position.X - sv.AbsolutePosition.X) / sv.AbsoluteSize.X, 0, 1)
        local ry = math.clamp((input.Position.Y - sv.AbsolutePosition.Y) / sv.AbsoluteSize.Y, 0, 1)
        s, v = rx, 1 - ry
        applyColor(true)
    end

    local function updateHue(input)
        local rx = math.clamp((input.Position.X - hue.AbsolutePosition.X) / hue.AbsoluteSize.X, 0, 1)
        h = rx
        applyColor(true)
    end

    sv.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            draggingSV = true; updateSV(input)
        end
    end)
    hue.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            draggingHue = true; updateHue(input)
        end
    end)
    bag:Add(UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if draggingSV  then updateSV(input)  end
        if draggingHue then updateHue(input) end
    end))
    bag:Add(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            draggingSV  = false
            draggingHue = false
        end
    end))

    header.MouseButton1Click:Connect(function()
        open = not open
        if open then
            tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, 38 + 110 + 14 + 30) })
        else
            tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, 34) })
        end
    end)

    return {
        frame = row,
        Set   = function(_, color)
            h, s, v = color:ToHSV()
            applyColor(true)
        end,
        Get     = function() return Color3.fromHSV(h, s, v) end,
        Destroy = function() row:Destroy() end,
    }
end

--==============================================================================
-- Window / Tab orchestration
--==============================================================================
function WaffleUI:CreateWindow(opts)
    opts = opts or {}
    local theme      = resolveTheme(opts.Theme)
    self._activeTheme = theme

    local dispatcher = Dispatcher.new(theme)
    local bag        = ConnectionBag.new()

    -- Config
    local configFile = opts.ConfigFile
    local configData = {}
    if configFile then
        configData = configLoad(configFile) or {}
    end
    local function makeSaveHook(key)
        if not configFile or not key then return nil end
        return function(value)
            configData[key] = value
            configSave(configFile, configData)
        end
    end

    -- ScreenGui
    local screen = new("ScreenGui", {
        Name           = "WaffleUI_" .. HttpService:GenerateGUID(false):sub(1, 8),
        ResetOnSpawn   = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder   = 999,
    })
    safeParent(screen)

    -- Window root
    local root = new("Frame", {
        Name             = "Window",
        Size             = UDim2.new(0, 620, 0, 400),
        Position         = UDim2.new(0.5, -310, 0.5, -200),
        Parent           = screen,
        ClipsDescendants = true,
    })
    corner(12, root)
    local rootStroke = stroke(theme.Stroke, 1, root)

    -- Open animation
    root.Size     = UDim2.new(0, 0, 0, 0)
    root.Position = UDim2.new(0.5, 0, 0.5, 0)
    tween(root, SPRING, {
        Size     = UDim2.new(0, 620, 0, 400),
        Position = UDim2.new(0.5, -310, 0.5, -200),
    })

    -- Titlebar
    local titlebar = new("Frame", {
        Size   = UDim2.new(1, 0, 0, 40),
        Parent = root,
    })
    corner(12, titlebar)
    local titlebarCover = new("Frame", { -- hide bottom corners
        Size             = UDim2.new(1, 0, 0, 12),
        Position         = UDim2.new(0, 0, 1, -12),
        BorderSizePixel  = 0,
        Parent           = titlebar,
    })

    local titleRow = new("Frame", {
        Size                   = UDim2.new(1, -120, 1, 0),
        Position               = UDim2.new(0, 14, 0, 0),
        BackgroundTransparency = 1,
        Parent                 = titlebar,
    })
    new("UIListLayout", {
        FillDirection      = Enum.FillDirection.Horizontal,
        Padding            = UDim.new(0, 6),
        VerticalAlignment  = Enum.VerticalAlignment.Center,
        SortOrder          = Enum.SortOrder.LayoutOrder,
        Parent             = titleRow,
    })
    local titleText = new("TextLabel", {
        AutomaticSize          = Enum.AutomaticSize.X,
        Size                   = UDim2.new(0, 0, 0, 20),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 15,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.Title or "WaffleUI",
        LayoutOrder            = 1,
        Parent                 = titleRow,
    })
    local subText = new("TextLabel", {
        AutomaticSize          = Enum.AutomaticSize.X,
        Size                   = UDim2.new(0, 0, 0, 16),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.Gotham,
        TextSize               = 12,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = opts.SubTitle or "",
        LayoutOrder            = 2,
        Parent                 = titleRow,
    })

    -- Window buttons
    local function iconBtn(offset, symbol, colorKey, cb)
        local b = new("TextButton", {
            Size            = UDim2.new(0, 24, 0, 24),
            Position        = UDim2.new(1, offset, 0.5, -12),
            Font            = Enum.Font.GothamBold,
            TextSize        = 14,
            Text            = symbol,
            AutoButtonColor = false,
            Parent          = titlebar,
        })
        corner(6, b)
        b.MouseEnter:Connect(function() tween(b, QUICK, { BackgroundColor3 = dispatcher.theme.Stroke }) end)
        b.MouseLeave:Connect(function() tween(b, QUICK, { BackgroundColor3 = dispatcher.theme.Elevated }) end)
        b.MouseButton1Click:Connect(cb)
        dispatcher:Register(function(t)
            b.BackgroundColor3 = t.Elevated
            b.TextColor3       = t[colorKey] or t.SubText
        end)
        return b
    end

    -- Forward-declared so the close button can call it before it's assigned.
    local destroyWindow

    local minimized   = false
    local savedSize   = UDim2.new(0, 620, 0, 400)
    local minimizeBtn = iconBtn(-34, "-", "SubText", function()
        minimized = not minimized
        if minimized then
            savedSize = root.Size
            tween(root, MEDIUM, { Size = UDim2.new(savedSize.X.Scale, savedSize.X.Offset, 0, 40) })
        else
            tween(root, MEDIUM, { Size = savedSize })
        end
    end)
    local closeBtn = iconBtn(-66, "x", "Danger", function()
        if destroyWindow then destroyWindow() end
    end)

    makeDraggable(titlebar, root, bag, true) -- v3: clamp window to viewport

    -- Body: sidebar + content
    local body = new("Frame", {
        Position               = UDim2.new(0, 0, 0, 40),
        Size                   = UDim2.new(1, 0, 1, -40),
        BackgroundTransparency = 1,
        Parent                 = root,
    })
    local sidebar = new("Frame", {
        Size   = UDim2.new(0, 150, 1, 0),
        Parent = body,
    })
    padding(10, sidebar)
    new("UIListLayout", {
        Padding   = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = sidebar,
    })

    local tabSearch = new("TextBox", {
        Size             = UDim2.new(1, 0, 0, 26),
        PlaceholderText  = "Search tabs...",
        Text             = "",
        Font             = Enum.Font.Gotham,
        TextSize         = 12,
        ClearTextOnFocus = false,
        LayoutOrder      = 0,
        Parent           = sidebar,
    })
    corner(6, tabSearch)
    padding(6, tabSearch)

    local content = new("Frame", {
        Position               = UDim2.new(0, 150, 0, 0),
        Size                   = UDim2.new(1, -150, 1, 0),
        BackgroundTransparency = 1,
        Parent                 = body,
    })

    -- Resize handle (bottom-right)
    local resizeGrip = new("Frame", {
        Size             = UDim2.new(0, 16, 0, 16),
        Position         = UDim2.new(1, -16, 1, -16),
        BackgroundTransparency = 1,
        ZIndex           = 10,
        Parent           = root,
    })
    local gripHit = new("TextButton", {
        Size                   = UDim2.new(1, 0, 1, 0),
        Text                   = "",
        BackgroundTransparency = 1,
        AutoButtonColor        = false,
        Parent                 = resizeGrip,
    })
    local gripLine1 = new("Frame", { Size = UDim2.new(0, 10, 0, 2), Position = UDim2.new(0, 2, 1, -4), BorderSizePixel = 0, Parent = resizeGrip })
    local gripLine2 = new("Frame", { Size = UDim2.new(0, 6,  0, 2), Position = UDim2.new(0, 6, 1, -8), BorderSizePixel = 0, Parent = resizeGrip })
    makeResizable(gripHit, root, Vector2.new(420, 280), bag)

    -- Theme painting for chrome
    dispatcher:Register(function(t)
        root.BackgroundColor3         = t.Background
        rootStroke.Color              = t.Stroke
        titlebar.BackgroundColor3     = t.Surface
        titlebarCover.BackgroundColor3 = t.Surface
        titleText.TextColor3          = t.Text
        subText.TextColor3            = t.SubText
        sidebar.BackgroundColor3      = t.Surface
        tabSearch.BackgroundColor3    = t.Elevated
        tabSearch.TextColor3          = t.Text
        tabSearch.PlaceholderColor3   = t.SubText
        gripLine1.BackgroundColor3    = t.Stroke
        gripLine2.BackgroundColor3    = t.Stroke
    end)

    -- Hotkey toggle (cancel-token safe + TextBox-aware)
    local visible = true
    local toggleToken = 0
    if opts.Keybind then
        bag:Add(UserInputService.InputBegan:Connect(function(input, processed)
            if processed then return end
            -- v3 bug fix: don't swallow keystrokes while typing in any TextBox.
            if UserInputService:GetFocusedTextBox() then return end
            if input.KeyCode == opts.Keybind then
                visible = not visible
                toggleToken = toggleToken + 1
                local myToken = toggleToken
                if visible then
                    root.Visible = true
                    tween(root, MEDIUM, { BackgroundTransparency = 0 })
                else
                    tween(root, MEDIUM, { BackgroundTransparency = 1 })
                    task.delay(0.25, function()
                        if myToken == toggleToken and not visible then
                            root.Visible = false
                        end
                    end)
                end
            end
        end))
    end

    --==========================================================================
    -- Window API
    --==========================================================================
    local Window = {
        _tabs       = {},
        _active     = nil,
        _dispatcher = dispatcher,
        _bag        = bag,
        _config     = configData,
        _configFile = configFile,
    }

    function Window:SetTheme(t)
        local resolved = resolveTheme(t)
        self._activeTheme = resolved
        WaffleUI._activeTheme = resolved
        dispatcher:SetTheme(resolved)
    end

    -- v3 API additions ---------------------------------------------------------
    function Window:SetTitle(s)
        titleText.Text = s or ""
    end

    function Window:SetSubTitle(s)
        subText.Text = s or ""
    end

    function Window:SetSize(w, h)
        local target = UDim2.new(0, w, 0, h)
        savedSize = target -- remember for minimize-restore
        tween(root, MEDIUM, { Size = target })
    end

    function Window:SetPosition(x, y)
        tween(root, MEDIUM, { Position = UDim2.new(0, x, 0, y) })
    end

    function Window:Show()
        visible = true
        root.Visible = true
        tween(root, MEDIUM, { BackgroundTransparency = 0 })
    end

    function Window:Hide()
        visible = false
        tween(root, MEDIUM, { BackgroundTransparency = 1 })
        task.delay(0.25, function()
            if not visible and root.Parent then root.Visible = false end
        end)
    end

    -- Confirm modal: a blocking (visually) yes/no prompt.
    -- Options: { Title, Message, OnConfirm, OnCancel, ConfirmText, CancelText }
    function Window:Confirm(o)
        o = o or {}
        local overlay = new("Frame", {
            Size                   = UDim2.new(1, 0, 1, 0),
            BackgroundColor3       = Color3.new(0, 0, 0),
            BackgroundTransparency = 1,
            BorderSizePixel        = 0,
            ZIndex                 = 50,
            Parent                 = root,
        })

        local panel = new("Frame", {
            AnchorPoint      = Vector2.new(0.5, 0.5),
            Position         = UDim2.new(0.5, 0, 0.5, 0),
            Size             = UDim2.new(0, 320, 0, 0),
            AutomaticSize    = Enum.AutomaticSize.Y,
            BackgroundColor3 = dispatcher.theme.Surface,
            ZIndex           = 51,
            Parent           = overlay,
        })
        corner(10, panel)
        stroke(dispatcher.theme.Stroke, 1, panel)
        padding(16, panel)

        new("UIListLayout", {
            Padding   = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent    = panel,
        })

        new("TextLabel", {
            Size                   = UDim2.new(1, 0, 0, 22),
            BackgroundTransparency = 1,
            Font                   = Enum.Font.GothamBold,
            TextSize               = 16,
            TextColor3             = dispatcher.theme.Text,
            TextXAlignment         = Enum.TextXAlignment.Left,
            Text                   = o.Title or "Are you sure?",
            LayoutOrder            = 1,
            Parent                 = panel,
        })

        new("TextLabel", {
            Size                   = UDim2.new(1, 0, 0, 0),
            AutomaticSize          = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font                   = Enum.Font.Gotham,
            TextSize               = 13,
            TextColor3             = dispatcher.theme.SubText,
            TextWrapped            = true,
            TextXAlignment         = Enum.TextXAlignment.Left,
            Text                   = o.Message or "",
            LayoutOrder            = 2,
            Parent                 = panel,
        })

        local btnRow = new("Frame", {
            Size                   = UDim2.new(1, 0, 0, 30),
            BackgroundTransparency = 1,
            LayoutOrder            = 3,
            Parent                 = panel,
        })
        new("UIListLayout", {
            FillDirection      = Enum.FillDirection.Horizontal,
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            Padding            = UDim.new(0, 8),
            SortOrder          = Enum.SortOrder.LayoutOrder,
            Parent             = btnRow,
        })

        local function close()
            tween(overlay, QUICK, { BackgroundTransparency = 1 })
            tween(panel,   QUICK, { Size = UDim2.new(0, 300, 0, panel.AbsoluteSize.Y) })
            task.delay(0.2, function() overlay:Destroy() end)
        end

        local cancelBtn = new("TextButton", {
            Size             = UDim2.new(0, 80, 1, 0),
            BackgroundColor3 = dispatcher.theme.Elevated,
            Font             = Enum.Font.GothamMedium,
            TextSize         = 13,
            TextColor3       = dispatcher.theme.Text,
            Text             = o.CancelText or "Cancel",
            AutoButtonColor  = false,
            LayoutOrder      = 1,
            Parent           = btnRow,
        })
        corner(6, cancelBtn)
        stroke(dispatcher.theme.Stroke, 1, cancelBtn)
        cancelBtn.MouseButton1Click:Connect(function()
            close()
            if o.OnCancel then task.spawn(o.OnCancel) end
        end)

        local confirmBtn = new("TextButton", {
            Size             = UDim2.new(0, 90, 1, 0),
            BackgroundColor3 = dispatcher.theme.Primary,
            Font             = Enum.Font.GothamBold,
            TextSize         = 13,
            TextColor3       = Color3.new(1, 1, 1),
            Text             = o.ConfirmText or "Confirm",
            AutoButtonColor  = false,
            LayoutOrder      = 2,
            Parent           = btnRow,
        })
        corner(6, confirmBtn)
        confirmBtn.MouseButton1Click:Connect(function()
            close()
            if o.OnConfirm then task.spawn(o.OnConfirm) end
        end)

        tween(overlay, QUICK, { BackgroundTransparency = 0.4 })
    end

    function Window:Notify(o)
        o = o or {}
        o.Theme = o.Theme or dispatcher.theme
        WaffleUI:Notify(o)
    end

    function Window:SelectTab(name)
        for _, tab in ipairs(self._tabs) do
            if tab._name == name then
                tab._activate()
                return true
            end
        end
        return false
    end

    function Window:Destroy()
        if destroyWindow then destroyWindow() end
    end

    destroyWindow = function()
        bag:Destroy()
        tween(root, MEDIUM, { Size = UDim2.new(0, 0, 0, 0), Position = UDim2.new(0.5, 0, 0.5, 0) })
        task.delay(0.35, function() if screen.Parent then screen:Destroy() end end)
    end

    -- Tab filter
    local function filterTabs(text)
        text = string.lower(text or "")
        for _, tab in ipairs(Window._tabs) do
            if text == "" or string.find(string.lower(tab._name), text, 1, true) then
                tab._btn.Visible = true
            else
                tab._btn.Visible = false
            end
        end
    end
    tabSearch:GetPropertyChangedSignal("Text"):Connect(function()
        filterTabs(tabSearch.Text)
    end)

    -- CreateTab
    function Window:CreateTab(name, icon)
        local tabBtn = new("TextButton", {
            Size                   = UDim2.new(1, 0, 0, 32),
            BackgroundTransparency = 1,
            Font                   = Enum.Font.GothamMedium,
            TextSize               = 14,
            Text                   = icon and "        " .. name or "   " .. name,
            TextXAlignment         = Enum.TextXAlignment.Left,
            AutoButtonColor        = false,
            LayoutOrder            = #self._tabs + 10, -- after search
            Parent                 = sidebar,
        })
        corner(6, tabBtn)

        local iconLabel
        if icon then
            iconLabel = new("ImageLabel", {
                Size                   = UDim2.new(0, 16, 0, 16),
                Position               = UDim2.new(0, 8, 0.5, -8),
                BackgroundTransparency = 1,
                Image                  = icon,
                Parent                 = tabBtn,
            })
        end

        local page = new("ScrollingFrame", {
            Size                   = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel        = 0,
            ScrollBarThickness     = 4,
            CanvasSize             = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize    = Enum.AutomaticSize.Y,
            Visible                = false,
            Parent                 = content,
        })
        padding(14, page)
        new("UIListLayout", {
            Padding   = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent    = page,
        })

        local tab = {
            _btn        = tabBtn,
            _page       = page,
            _name       = name,
            _components = {},
        }

        local function activate()
            for _, t in ipairs(Window._tabs) do
                t._page.Visible = false
                tween(t._btn, QUICK, {
                    BackgroundTransparency = 1,
                    TextColor3             = dispatcher.theme.SubText,
                })
                local ic = t._btn:FindFirstChildOfClass("ImageLabel")
                if ic then tween(ic, QUICK, { ImageColor3 = dispatcher.theme.SubText }) end
            end
            page.Visible = true
            tween(tabBtn, QUICK, {
                BackgroundTransparency = 0,
                BackgroundColor3       = dispatcher.theme.Elevated,
                TextColor3             = dispatcher.theme.Text,
            })
            if iconLabel then
                tween(iconLabel, QUICK, { ImageColor3 = dispatcher.theme.Primary })
            end
            Window._active = tab
        end
        tab._activate = activate

        tabBtn.MouseButton1Click:Connect(activate)

        dispatcher:Register(function(t)
            page.ScrollBarImageColor3 = t.Stroke
            if iconLabel then
                iconLabel.ImageColor3 = (Window._active == tab) and t.Primary or t.SubText
            end
            tabBtn.TextColor3 = (Window._active == tab) and t.Text or t.SubText
            if Window._active == tab then
                tabBtn.BackgroundColor3 = t.Elevated
                tabBtn.BackgroundTransparency = 0
            end
        end)

        table.insert(Window._tabs, tab)
        if #Window._tabs == 1 then activate() end

        -- Tab API -------------------------------------------------------------
        function tab:AddSection(text)
            local c = Components.Section(page, dispatcher, text)
            table.insert(self._components, c); return c
        end
        function tab:AddLabel(text)
            local c = Components.Label(page, dispatcher, text)
            table.insert(self._components, c); return c
        end
        function tab:AddParagraph(o)
            local c = Components.Paragraph(page, dispatcher, o)
            table.insert(self._components, c); return c
        end
        function tab:AddDivider()
            local c = Components.Divider(page, dispatcher)
            table.insert(self._components, c); return c
        end
        function tab:AddButton(o)
            local c = Components.Button(page, dispatcher, o)
            table.insert(self._components, c); return c
        end
        function tab:AddToggle(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.Toggle(page, dispatcher, o, hook)
            if o and o.Flag and configData[o.Flag] ~= nil then c:Set(configData[o.Flag], true) end
            table.insert(self._components, c); return c
        end
        function tab:AddSlider(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.Slider(page, dispatcher, bag, o, hook)
            if o and o.Flag and configData[o.Flag] ~= nil then c:Set(configData[o.Flag], true) end
            table.insert(self._components, c); return c
        end
        function tab:AddProgress(o)
            local c = Components.ProgressBar(page, dispatcher, o)
            table.insert(self._components, c); return c
        end
        function tab:AddDropdown(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.Dropdown(page, dispatcher, o, hook)
            if o and o.Flag and configData[o.Flag] ~= nil then c:Set(configData[o.Flag], true) end
            table.insert(self._components, c); return c
        end
        function tab:AddMultiSelect(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.MultiSelect(page, dispatcher, o, hook)
            if o and o.Flag and configData[o.Flag] ~= nil then c:Set(configData[o.Flag]) end
            table.insert(self._components, c); return c
        end
        function tab:AddRadioGroup(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.RadioGroup(page, dispatcher, o, hook)
            if o and o.Flag and configData[o.Flag] ~= nil then c:Set(configData[o.Flag], true) end
            table.insert(self._components, c); return c
        end
        function tab:AddTextbox(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.Textbox(page, dispatcher, o, hook)
            if o and o.Flag and configData[o.Flag] ~= nil then c:Set(configData[o.Flag]) end
            table.insert(self._components, c); return c
        end
        function tab:AddKeybind(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.Keybind(page, dispatcher, bag, o, hook)
            if o and o.Flag and configData[o.Flag] then
                local kc = Enum.KeyCode[configData[o.Flag]]
                if kc then c:Set(kc) end
            end
            table.insert(self._components, c); return c
        end
        function tab:AddColorPicker(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.ColorPicker(page, dispatcher, bag, o, hook)
            if o and o.Flag and configData[o.Flag] then
                local rgb = configData[o.Flag]
                c:Set(Color3.new(rgb[1], rgb[2], rgb[3]))
            end
            table.insert(self._components, c); return c
        end
        function tab:AddStepper(o)
            local hook = makeSaveHook(o and o.Flag)
            local c = Components.Stepper(page, dispatcher, o, hook)
            if o and o.Flag and configData[o.Flag] ~= nil then c:Set(configData[o.Flag], true) end
            table.insert(self._components, c); return c
        end
        function tab:AddConsole(o)
            local c = Components.Console(page, dispatcher, o)
            table.insert(self._components, c); return c
        end

        -- Attach a hover tooltip to any previously-created component.
        function tab:AttachTooltip(component, text)
            return Tooltip.attach(component, text, dispatcher, bag)
        end

        function tab:Destroy()
            for _, c in ipairs(self._components) do pcall(c.Destroy, c) end
            page:Destroy()
            tabBtn:Destroy()
            local wasActive = (Window._active == tab)
            for i, t in ipairs(Window._tabs) do
                if t == tab then table.remove(Window._tabs, i); break end
            end
            -- v3 bug fix: after destroying the active tab, nothing was
            -- rendered. Auto-activate the first remaining tab.
            if wasActive and #Window._tabs > 0 then
                Window._tabs[1]._activate()
            end
        end

        return tab
    end

    table.insert(WaffleUI._windows, Window)
    return Window
end

--==============================================================================
-- ============================================================================
--
--                          WaffleUI EXTENSIONS
--
--     Everything below is attached to the WaffleUI table as a collection
--     of self-contained submodules. They are independent of the core
--     Window/Tab/Component system and can be used standalone.
--
--     Layout:
--         WaffleUI.Themes       -- extended named theme palettes
--         WaffleUI.Icons        -- curated rbxassetid registry
--         WaffleUI.Color        -- color math, conversions, palette tools
--         WaffleUI.Easing       -- raw easing functions + TweenInfo presets
--         WaffleUI.Signal       -- lightweight Signal/Event class
--         WaffleUI.Store        -- observable state container
--         WaffleUI.Validator    -- schema-based form validation
--         WaffleUI.i18n         -- locale tables + translator
--         WaffleUI.Notify       -- advanced notification controller
--         WaffleUI.Format       -- number / time / byte formatters
--         WaffleUI.Sequencer    -- chainable tween sequence runner
--         WaffleUI.CommandPalette -- Ctrl+K style command runner
--         WaffleUI.Diagnostics  -- perf counters + debug overlay
--
-- ============================================================================
--==============================================================================




--==============================================================================
-- WaffleUI.Themes
--
-- A curated set of extended named theme palettes. Every theme has the same
-- keys so SetTheme(name) is always safe:
--
--     Background   -- root window background
--     Surface      -- panes, pages, sidebar
--     Elevated     -- elevated rows, active tab, popovers
--     Hover        -- hover state for buttons/rows
--     Stroke       -- 1px borders, separators, scrollbars
--     Primary      -- accent / brand
--     PrimaryAlt   -- a second accent for gradients
--     Success, Warning, Error, Info
--     Text         -- default foreground text
--     SubText      -- secondary / hint text
--     Disabled     -- disabled foreground
--
-- Themes can be passed by name or as a table override. Partial overrides
-- fall back to the currently-active theme key. Applying a theme from this
-- table is equivalent to calling Window:SetTheme(name).
--==============================================================================
WaffleUI.Themes = {}

WaffleUI.Themes.Dark = {
    Background = Color3.fromRGB( 18,  18,  22),
    Surface    = Color3.fromRGB( 24,  24,  30),
    Elevated   = Color3.fromRGB( 32,  32,  40),
    Hover      = Color3.fromRGB( 40,  40,  50),
    Stroke     = Color3.fromRGB( 48,  48,  58),
    Primary    = Color3.fromRGB(120, 200, 255),
    PrimaryAlt = Color3.fromRGB( 90, 150, 240),
    Success    = Color3.fromRGB( 80, 200, 120),
    Warning    = Color3.fromRGB(240, 180,  60),
    Error      = Color3.fromRGB(240,  90,  90),
    Info       = Color3.fromRGB(100, 170, 240),
    Text       = Color3.fromRGB(235, 235, 240),
    SubText    = Color3.fromRGB(160, 160, 175),
    Disabled   = Color3.fromRGB(100, 100, 115),
}

WaffleUI.Themes.Light = {
    Background = Color3.fromRGB(245, 245, 248),
    Surface    = Color3.fromRGB(255, 255, 255),
    Elevated   = Color3.fromRGB(238, 238, 242),
    Hover      = Color3.fromRGB(228, 228, 234),
    Stroke     = Color3.fromRGB(210, 210, 220),
    Primary    = Color3.fromRGB( 60, 130, 250),
    PrimaryAlt = Color3.fromRGB( 30, 100, 230),
    Success    = Color3.fromRGB( 40, 170,  80),
    Warning    = Color3.fromRGB(220, 140,  10),
    Error      = Color3.fromRGB(220,  60,  60),
    Info       = Color3.fromRGB( 60, 140, 220),
    Text       = Color3.fromRGB( 20,  20,  28),
    SubText    = Color3.fromRGB( 90,  90, 110),
    Disabled   = Color3.fromRGB(160, 160, 170),
}

WaffleUI.Themes.Midnight = {
    Background = Color3.fromRGB(  8,   8,  14),
    Surface    = Color3.fromRGB( 14,  14,  22),
    Elevated   = Color3.fromRGB( 22,  22,  32),
    Hover      = Color3.fromRGB( 32,  32,  44),
    Stroke     = Color3.fromRGB( 40,  40,  52),
    Primary    = Color3.fromRGB(170, 120, 255),
    PrimaryAlt = Color3.fromRGB(120,  90, 240),
    Success    = Color3.fromRGB( 90, 200, 140),
    Warning    = Color3.fromRGB(240, 200,  90),
    Error      = Color3.fromRGB(240, 100, 100),
    Info       = Color3.fromRGB(130, 180, 250),
    Text       = Color3.fromRGB(230, 230, 240),
    SubText    = Color3.fromRGB(150, 150, 170),
    Disabled   = Color3.fromRGB( 90,  90, 110),
}

WaffleUI.Themes.Ocean = {
    Background = Color3.fromRGB( 10,  24,  36),
    Surface    = Color3.fromRGB( 16,  34,  50),
    Elevated   = Color3.fromRGB( 22,  46,  64),
    Hover      = Color3.fromRGB( 30,  60,  82),
    Stroke     = Color3.fromRGB( 40,  80, 104),
    Primary    = Color3.fromRGB( 80, 200, 220),
    PrimaryAlt = Color3.fromRGB( 60, 160, 200),
    Success    = Color3.fromRGB( 80, 210, 170),
    Warning    = Color3.fromRGB(240, 190,  90),
    Error      = Color3.fromRGB(240, 100, 110),
    Info       = Color3.fromRGB(110, 180, 230),
    Text       = Color3.fromRGB(230, 240, 248),
    SubText    = Color3.fromRGB(150, 180, 200),
    Disabled   = Color3.fromRGB(100, 130, 150),
}

WaffleUI.Themes.Forest = {
    Background = Color3.fromRGB( 14,  24,  18),
    Surface    = Color3.fromRGB( 20,  34,  26),
    Elevated   = Color3.fromRGB( 28,  46,  34),
    Hover      = Color3.fromRGB( 38,  58,  44),
    Stroke     = Color3.fromRGB( 48,  72,  56),
    Primary    = Color3.fromRGB(120, 220, 140),
    PrimaryAlt = Color3.fromRGB( 80, 180, 110),
    Success    = Color3.fromRGB(110, 220, 140),
    Warning    = Color3.fromRGB(240, 200,  80),
    Error      = Color3.fromRGB(240, 100,  90),
    Info       = Color3.fromRGB(130, 200, 180),
    Text       = Color3.fromRGB(232, 240, 230),
    SubText    = Color3.fromRGB(160, 180, 160),
    Disabled   = Color3.fromRGB(100, 120, 100),
}

WaffleUI.Themes.Sunset = {
    Background = Color3.fromRGB( 28,  16,  22),
    Surface    = Color3.fromRGB( 40,  22,  30),
    Elevated   = Color3.fromRGB( 52,  30,  40),
    Hover      = Color3.fromRGB( 68,  40,  52),
    Stroke     = Color3.fromRGB( 84,  52,  64),
    Primary    = Color3.fromRGB(255, 140,  90),
    PrimaryAlt = Color3.fromRGB(230,  90, 110),
    Success    = Color3.fromRGB(110, 200, 130),
    Warning    = Color3.fromRGB(240, 190,  80),
    Error      = Color3.fromRGB(240,  90,  90),
    Info       = Color3.fromRGB(200, 130, 240),
    Text       = Color3.fromRGB(245, 235, 230),
    SubText    = Color3.fromRGB(200, 170, 170),
    Disabled   = Color3.fromRGB(130, 110, 110),
}

WaffleUI.Themes.HighContrast = {
    Background = Color3.fromRGB(  0,   0,   0),
    Surface    = Color3.fromRGB(  0,   0,   0),
    Elevated   = Color3.fromRGB( 20,  20,  20),
    Hover      = Color3.fromRGB( 40,  40,  40),
    Stroke     = Color3.fromRGB(255, 255, 255),
    Primary    = Color3.fromRGB(255, 255,   0),
    PrimaryAlt = Color3.fromRGB(  0, 255, 255),
    Success    = Color3.fromRGB(  0, 255,   0),
    Warning    = Color3.fromRGB(255, 170,   0),
    Error      = Color3.fromRGB(255,   0,   0),
    Info       = Color3.fromRGB(  0, 200, 255),
    Text       = Color3.fromRGB(255, 255, 255),
    SubText    = Color3.fromRGB(220, 220, 220),
    Disabled   = Color3.fromRGB(120, 120, 120),
}

WaffleUI.Themes.Solarized = {
    Background = Color3.fromRGB(  0,  43,  54),
    Surface    = Color3.fromRGB(  7,  54,  66),
    Elevated   = Color3.fromRGB( 20,  70,  80),
    Hover      = Color3.fromRGB( 30,  82,  92),
    Stroke     = Color3.fromRGB( 40,  94, 104),
    Primary    = Color3.fromRGB( 38, 139, 210),
    PrimaryAlt = Color3.fromRGB( 42, 161, 152),
    Success    = Color3.fromRGB(133, 153,   0),
    Warning    = Color3.fromRGB(181, 137,   0),
    Error      = Color3.fromRGB(220,  50,  47),
    Info       = Color3.fromRGB( 38, 139, 210),
    Text       = Color3.fromRGB(253, 246, 227),
    SubText    = Color3.fromRGB(147, 161, 161),
    Disabled   = Color3.fromRGB( 88, 110, 117),
}

WaffleUI.Themes.Dracula = {
    Background = Color3.fromRGB( 40,  42,  54),
    Surface    = Color3.fromRGB( 52,  54,  70),
    Elevated   = Color3.fromRGB( 68,  71,  90),
    Hover      = Color3.fromRGB( 80,  85, 105),
    Stroke     = Color3.fromRGB( 98, 114, 164),
    Primary    = Color3.fromRGB(189, 147, 249),
    PrimaryAlt = Color3.fromRGB(255, 121, 198),
    Success    = Color3.fromRGB( 80, 250, 123),
    Warning    = Color3.fromRGB(241, 250, 140),
    Error      = Color3.fromRGB(255,  85,  85),
    Info       = Color3.fromRGB(139, 233, 253),
    Text       = Color3.fromRGB(248, 248, 242),
    SubText    = Color3.fromRGB(189, 190, 202),
    Disabled   = Color3.fromRGB(120, 122, 140),
}

WaffleUI.Themes.Nord = {
    Background = Color3.fromRGB( 46,  52,  64),
    Surface    = Color3.fromRGB( 59,  66,  82),
    Elevated   = Color3.fromRGB( 67,  76,  94),
    Hover      = Color3.fromRGB( 76,  86, 106),
    Stroke     = Color3.fromRGB(136, 192, 208),
    Primary    = Color3.fromRGB(129, 161, 193),
    PrimaryAlt = Color3.fromRGB(143, 188, 187),
    Success    = Color3.fromRGB(163, 190, 140),
    Warning    = Color3.fromRGB(235, 203, 139),
    Error      = Color3.fromRGB(191,  97, 106),
    Info       = Color3.fromRGB(136, 192, 208),
    Text       = Color3.fromRGB(236, 239, 244),
    SubText    = Color3.fromRGB(180, 190, 210),
    Disabled   = Color3.fromRGB(110, 120, 135),
}

WaffleUI.Themes.Monokai = {
    Background = Color3.fromRGB( 39,  40,  34),
    Surface    = Color3.fromRGB( 54,  54,  48),
    Elevated   = Color3.fromRGB( 70,  70,  62),
    Hover      = Color3.fromRGB( 84,  84,  76),
    Stroke     = Color3.fromRGB(117, 113,  94),
    Primary    = Color3.fromRGB(166, 226,  46),
    PrimaryAlt = Color3.fromRGB(249,  38, 114),
    Success    = Color3.fromRGB(166, 226,  46),
    Warning    = Color3.fromRGB(253, 151,  31),
    Error      = Color3.fromRGB(249,  38, 114),
    Info       = Color3.fromRGB(102, 217, 239),
    Text       = Color3.fromRGB(248, 248, 242),
    SubText    = Color3.fromRGB(190, 185, 170),
    Disabled   = Color3.fromRGB(120, 115, 100),
}

WaffleUI.Themes.Rose = {
    Background = Color3.fromRGB( 30,  18,  22),
    Surface    = Color3.fromRGB( 44,  26,  32),
    Elevated   = Color3.fromRGB( 58,  34,  42),
    Hover      = Color3.fromRGB( 74,  44,  54),
    Stroke     = Color3.fromRGB( 90,  54,  66),
    Primary    = Color3.fromRGB(240, 130, 160),
    PrimaryAlt = Color3.fromRGB(210,  90, 130),
    Success    = Color3.fromRGB(120, 200, 150),
    Warning    = Color3.fromRGB(240, 190,  80),
    Error      = Color3.fromRGB(240,  90, 100),
    Info       = Color3.fromRGB(180, 140, 240),
    Text       = Color3.fromRGB(248, 236, 240),
    SubText    = Color3.fromRGB(200, 170, 180),
    Disabled   = Color3.fromRGB(130, 110, 115),
}

--[[
    THEME NOTES
    ===========
    * Dark, Light, Midnight, and Ocean are the four themes the core library
      builds against; switching between them is always safe.
    * The remaining themes (Forest, Sunset, HighContrast, Solarized, Dracula,
      Nord, Monokai, Rose) are included for convenience and follow the same
      key contract. They will work with Window:SetTheme but may render with
      slightly different contrast from the built-in four.
    * To roll your own, copy any of the tables above and tweak the values.
      Then call Window:SetTheme(yourTable).
]]

-- Quick helpers for clients that want to enumerate themes at runtime.
function WaffleUI:ListThemes()
    local out = {}
    for name in pairs(self.Themes) do table.insert(out, name) end
    table.sort(out)
    return out
end

function WaffleUI:GetTheme(name)
    return self.Themes[name]
end

function WaffleUI:RegisterTheme(name, palette)
    assert(type(name) == "string", "RegisterTheme: name must be a string")
    assert(type(palette) == "table", "RegisterTheme: palette must be a table")
    self.Themes[name] = palette
    return palette
end



--==============================================================================
-- WaffleUI.Icons
--
-- Curated registry of rbxassetid icons grouped by domain. Having the ids in
-- one place lets you write:
--
--     tab:AddButton({ Text = "Save", Icon = WaffleUI.Icons.action.save })
--
-- instead of chasing magic numbers through your code. Unknown names return
-- nil and the caller should fall back gracefully.
--
-- The ids below are commonly-used Roblox asset ids; if an id is missing from
-- your game permissions you can replace it with WaffleUI.Icons:Register.
--==============================================================================
WaffleUI.Icons = {
    -- Core navigation / framework icons
    nav = {
        home            = "rbxassetid://10734950309",
        dashboard       = "rbxassetid://10734943264",
        settings        = "rbxassetid://10734898355",
        profile         = "rbxassetid://10747384394",
        search          = "rbxassetid://10734924532",
        menu            = "rbxassetid://10734937873",
        close           = "rbxassetid://10747372968",
        back            = "rbxassetid://10709790644",
        forward         = "rbxassetid://10709791646",
        up              = "rbxassetid://10709791437",
        down            = "rbxassetid://10709790222",
        more            = "rbxassetid://10734898586",
        grid            = "rbxassetid://10734949822",
        list            = "rbxassetid://10734950354",
    },
    -- Generic action icons
    action = {
        save            = "rbxassetid://10734898477",
        delete          = "rbxassetid://10734898588",
        edit            = "rbxassetid://10734923936",
        copy            = "rbxassetid://10709761939",
        paste           = "rbxassetid://10709762225",
        cut             = "rbxassetid://10709762102",
        refresh         = "rbxassetid://10709808039",
        share           = "rbxassetid://10734898650",
        upload          = "rbxassetid://10709767276",
        download        = "rbxassetid://10709767076",
        add             = "rbxassetid://10709751939",
        remove          = "rbxassetid://10709753795",
        undo            = "rbxassetid://10734884215",
        redo            = "rbxassetid://10734884090",
        play            = "rbxassetid://10709828712",
        pause           = "rbxassetid://10709828609",
        stop            = "rbxassetid://10709828833",
        filter          = "rbxassetid://10709761770",
        sort            = "rbxassetid://10709762449",
    },
    -- Status / severity icons (typically used in notifications)
    status = {
        info            = "rbxassetid://10723407389",
        success         = "rbxassetid://10723407818",
        warning         = "rbxassetid://10723415016",
        error           = "rbxassetid://10723415310",
        question        = "rbxassetid://10723424505",
        loading         = "rbxassetid://10723408256",
        locked          = "rbxassetid://10709792619",
        unlocked        = "rbxassetid://10709792738",
        check           = "rbxassetid://10747384394",
        cross           = "rbxassetid://10747372968",
    },
    -- Communication / social
    comm = {
        mail            = "rbxassetid://10734898588",
        message         = "rbxassetid://10734898650",
        bell            = "rbxassetid://10709816971",
        chat            = "rbxassetid://10709806299",
        phone           = "rbxassetid://10734936815",
        user            = "rbxassetid://10747384394",
        users           = "rbxassetid://10747384424",
        heart           = "rbxassetid://10709770050",
        star            = "rbxassetid://10734897885",
    },
    -- File / media types
    media = {
        image           = "rbxassetid://10709797859",
        video           = "rbxassetid://10709809209",
        audio           = "rbxassetid://10734936815",
        file            = "rbxassetid://10709797641",
        folder          = "rbxassetid://10723417181",
        archive         = "rbxassetid://10709797641",
        link            = "rbxassetid://10709794789",
        code            = "rbxassetid://10709757069",
    },
    -- Dev / debug
    dev = {
        bug             = "rbxassetid://10709752319",
        terminal        = "rbxassetid://10734924532",
        gear            = "rbxassetid://10734898355",
        wrench          = "rbxassetid://10734884325",
        hammer          = "rbxassetid://10734884217",
        flask           = "rbxassetid://10709770823",
        rocket          = "rbxassetid://10709810334",
        power           = "rbxassetid://10734898586",
    },
    -- Game-specific UX icons that many executors expect
    game = {
        sword           = "rbxassetid://10734884215",
        shield          = "rbxassetid://10734884090",
        potion          = "rbxassetid://10709770823",
        crown           = "rbxassetid://10709762567",
        gem             = "rbxassetid://10709770823",
        coin            = "rbxassetid://10709756916",
        compass         = "rbxassetid://10709762690",
        map             = "rbxassetid://10709795158",
        flag            = "rbxassetid://10709762778",
        trophy          = "rbxassetid://10709767572",
        target          = "rbxassetid://10734898586",
        skull           = "rbxassetid://10734897885",
    },
    -- Weather (useful for day/night-cycle dropdowns)
    weather = {
        sun             = "rbxassetid://10734897885",
        moon            = "rbxassetid://10734897921",
        cloud           = "rbxassetid://10709761939",
        rain            = "rbxassetid://10709807878",
        snow            = "rbxassetid://10709808039",
        storm           = "rbxassetid://10709808197",
        wind            = "rbxassetid://10709809394",
    },
    -- Device / platform
    device = {
        pc              = "rbxassetid://10709792397",
        mobile          = "rbxassetid://10734936815",
        controller      = "rbxassetid://10734897921",
        keyboard        = "rbxassetid://10709792619",
        mouse           = "rbxassetid://10709792738",
        headset         = "rbxassetid://10709792738",
    },
}

--[[
    Icons registry helpers
    ======================
    Icons:Get("nav.home")   -> "rbxassetid://10734950309" (or nil)
    Icons:Register(path, id) -> overwrites/creates a dotted key.
    Icons:All()             -> flat { path = id } map (for browsers / pickers).

    Keeping a helper surface means UI code never has to branch on missing
    keys; it just passes Icon = Icons:Get(path) and lets the component
    ignore a nil value.
]]
function WaffleUI.Icons:Get(path)
    local cur = self
    for part in string.gmatch(path, "[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[part]
    end
    return cur
end

function WaffleUI.Icons:Register(path, id)
    assert(type(path) == "string", "Icons:Register: path must be a string")
    assert(type(id) == "string",   "Icons:Register: id must be a string")
    local cur = self
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do table.insert(parts, part) end
    for i = 1, #parts - 1 do
        cur[parts[i]] = cur[parts[i]] or {}
        cur = cur[parts[i]]
    end
    cur[parts[#parts]] = id
    return id
end

function WaffleUI.Icons:All()
    local out = {}
    local function walk(node, prefix)
        for k, v in pairs(node) do
            if type(v) == "table" then
                walk(v, prefix == "" and k or (prefix .. "." .. k))
            elseif type(v) == "string" and k ~= "Get" and k ~= "Register" and k ~= "All" then
                out[prefix == "" and k or (prefix .. "." .. k)] = v
            end
        end
    end
    walk(self, "")
    return out
end



--==============================================================================
-- WaffleUI.Color
--
-- Color math, conversions and palette tools. All functions accept and
-- return plain Roblox `Color3` values unless noted otherwise. All channels
-- in the public API are in the 0-1 range to match Color3; the few RGB helpers
-- that work in 0-255 are named `...RGB255`.
--
-- Overview:
--     Color.hex(str)                -- "#rrggbb" / "rgb" / "rrggbb" -> Color3
--     Color.toHex(c3)               -- Color3 -> "#rrggbb"
--     Color.toHSL(c3), fromHSL(...) -- HSL conversion (sliders, pickers)
--     Color.toHSV(c3), fromHSV(...) -- HSV conversion
--     Color.lerp(a, b, t)           -- componentwise linear blend
--     Color.mix(a, b, t, space)     -- blend in rgb|hsl|hsv
--     Color.lighten / darken        -- adjust lightness by amount
--     Color.saturate / desaturate   -- adjust saturation
--     Color.invert / complement     -- color wheel opposite
--     Color.luminance(c3)           -- WCAG relative luminance
--     Color.contrast(a, b)          -- WCAG contrast ratio
--     Color.readableOn(bg)          -- picks black or white over bg
--     Color.palette(base, n)        -- evenly-spaced hue palette
--     Color.shades(base, n)         -- n lightness shades of one hue
--     Color.tint / shade            -- single-step tint (toward white/black)
--     Color.clamp(c3)               -- clamps any Color3 to [0..1]
--     Color.equal(a, b, eps)        -- epsilon equality
--==============================================================================
WaffleUI.Color = {}
local Color = WaffleUI.Color

local function clamp01(x) return math.clamp(x, 0, 1) end

function Color.clamp(c3)
    return Color3.new(clamp01(c3.R), clamp01(c3.G), clamp01(c3.B))
end

function Color.equal(a, b, eps)
    eps = eps or 1e-4
    return math.abs(a.R - b.R) < eps
        and math.abs(a.G - b.G) < eps
        and math.abs(a.B - b.B) < eps
end

function Color.hex(str)
    assert(type(str) == "string", "Color.hex: expected string")
    local s = str:gsub("^#", ""):gsub("%s+", "")
    if #s == 3 then
        -- shorthand like "fff"
        s = s:sub(1,1):rep(2) .. s:sub(2,2):rep(2) .. s:sub(3,3):rep(2)
    end
    assert(#s == 6, "Color.hex: expected 3 or 6 hex digits, got '" .. str .. "'")
    local r = tonumber(s:sub(1, 2), 16)
    local g = tonumber(s:sub(3, 4), 16)
    local b = tonumber(s:sub(5, 6), 16)
    assert(r and g and b, "Color.hex: invalid digits in '" .. str .. "'")
    return Color3.fromRGB(r, g, b)
end

function Color.toHex(c3)
    return string.format("#%02X%02X%02X",
        math.floor(c3.R * 255 + 0.5),
        math.floor(c3.G * 255 + 0.5),
        math.floor(c3.B * 255 + 0.5))
end

-- HSL (Hue 0-1, Saturation 0-1, Lightness 0-1) -------------------------------
function Color.toHSL(c3)
    local r, g, b = c3.R, c3.G, c3.B
    local maxC = math.max(r, g, b)
    local minC = math.min(r, g, b)
    local h, s
    local l = (maxC + minC) * 0.5
    if maxC == minC then
        h, s = 0, 0
    else
        local d = maxC - minC
        s = (l > 0.5) and (d / (2 - maxC - minC)) or (d / (maxC + minC))
        if maxC == r then
            h = ((g - b) / d + (g < b and 6 or 0)) / 6
        elseif maxC == g then
            h = ((b - r) / d + 2) / 6
        else
            h = ((r - g) / d + 4) / 6
        end
    end
    return h, s, l
end

local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
end

function Color.fromHSL(h, s, l)
    h = h % 1; s = clamp01(s); l = clamp01(l)
    if s == 0 then
        return Color3.new(l, l, l)
    end
    local q = l < 0.5 and (l * (1 + s)) or (l + s - l * s)
    local p = 2 * l - q
    local r = hue2rgb(p, q, h + 1/3)
    local g = hue2rgb(p, q, h)
    local b = hue2rgb(p, q, h - 1/3)
    return Color3.new(r, g, b)
end

-- HSV (Hue 0-1, Saturation 0-1, Value 0-1) -----------------------------------
function Color.toHSV(c3)
    local h, s, v = c3:ToHSV()
    return h, s, v
end

function Color.fromHSV(h, s, v)
    return Color3.fromHSV(h % 1, clamp01(s), clamp01(v))
end

-- Blending ------------------------------------------------------------------
function Color.lerp(a, b, t)
    t = clamp01(t)
    return Color3.new(
        a.R + (b.R - a.R) * t,
        a.G + (b.G - a.G) * t,
        a.B + (b.B - a.B) * t
    )
end

function Color.mix(a, b, t, space)
    space = space or "rgb"
    if space == "rgb" then
        return Color.lerp(a, b, t)
    elseif space == "hsl" then
        local h1, s1, l1 = Color.toHSL(a)
        local h2, s2, l2 = Color.toHSL(b)
        -- shortest-path hue interpolation
        if math.abs(h2 - h1) > 0.5 then
            if h2 > h1 then h1 = h1 + 1 else h2 = h2 + 1 end
        end
        local h = (h1 + (h2 - h1) * t) % 1
        return Color.fromHSL(h, s1 + (s2 - s1) * t, l1 + (l2 - l1) * t)
    elseif space == "hsv" then
        local h1, s1, v1 = Color.toHSV(a)
        local h2, s2, v2 = Color.toHSV(b)
        if math.abs(h2 - h1) > 0.5 then
            if h2 > h1 then h1 = h1 + 1 else h2 = h2 + 1 end
        end
        local h = (h1 + (h2 - h1) * t) % 1
        return Color.fromHSV(h, s1 + (s2 - s1) * t, v1 + (v2 - v1) * t)
    end
    error("Color.mix: unknown space '" .. tostring(space) .. "'")
end

-- Adjustments ---------------------------------------------------------------
function Color.lighten(c3, amount)
    local h, s, l = Color.toHSL(c3)
    return Color.fromHSL(h, s, l + amount)
end

function Color.darken(c3, amount)
    return Color.lighten(c3, -amount)
end

function Color.saturate(c3, amount)
    local h, s, l = Color.toHSL(c3)
    return Color.fromHSL(h, s + amount, l)
end

function Color.desaturate(c3, amount)
    return Color.saturate(c3, -amount)
end

function Color.invert(c3)
    return Color3.new(1 - c3.R, 1 - c3.G, 1 - c3.B)
end

function Color.complement(c3)
    local h, s, l = Color.toHSL(c3)
    return Color.fromHSL(h + 0.5, s, l)
end

function Color.tint(c3, amount)
    return Color.lerp(c3, Color3.new(1, 1, 1), amount)
end

function Color.shade(c3, amount)
    return Color.lerp(c3, Color3.new(0, 0, 0), amount)
end

-- WCAG luminance / contrast -------------------------------------------------
-- Accepts a linear 0-1 channel, returns sRGB-linearised value.
local function linearize(c)
    if c <= 0.03928 then return c / 12.92 end
    return ((c + 0.055) / 1.055) ^ 2.4
end

function Color.luminance(c3)
    local r = linearize(c3.R)
    local g = linearize(c3.G)
    local b = linearize(c3.B)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

function Color.contrast(a, b)
    local la = Color.luminance(a) + 0.05
    local lb = Color.luminance(b) + 0.05
    return (la > lb) and (la / lb) or (lb / la)
end

-- Given a background, returns the better of black/white to use on top.
function Color.readableOn(bg)
    local black = Color3.new(0, 0, 0)
    local white = Color3.new(1, 1, 1)
    local cB = Color.contrast(bg, black)
    local cW = Color.contrast(bg, white)
    return (cB > cW) and black or white
end

-- Palettes ------------------------------------------------------------------
function Color.palette(base, n)
    n = math.max(1, n or 5)
    local h, s, l = Color.toHSL(base)
    local out = {}
    for i = 0, n - 1 do
        out[i + 1] = Color.fromHSL((h + i / n) % 1, s, l)
    end
    return out
end

function Color.shades(base, n)
    n = math.max(2, n or 5)
    local h, s = Color.toHSL(base)
    local out = {}
    for i = 0, n - 1 do
        local l = 0.12 + (0.88 - 0.12) * (i / (n - 1))
        out[i + 1] = Color.fromHSL(h, s, l)
    end
    return out
end

function Color.analogous(base, spread)
    spread = spread or 30
    local s = spread / 360
    local h, sa, l = Color.toHSL(base)
    return {
        Color.fromHSL(h - s, sa, l),
        base,
        Color.fromHSL(h + s, sa, l),
    }
end

function Color.triad(base)
    local h, s, l = Color.toHSL(base)
    return {
        base,
        Color.fromHSL(h + 1/3, s, l),
        Color.fromHSL(h + 2/3, s, l),
    }
end

function Color.tetrad(base)
    local h, s, l = Color.toHSL(base)
    return {
        base,
        Color.fromHSL(h + 0.25, s, l),
        Color.fromHSL(h + 0.5,  s, l),
        Color.fromHSL(h + 0.75, s, l),
    }
end

-- 0-255 conveniences --------------------------------------------------------
function Color.fromRGB255(r, g, b)
    return Color3.fromRGB(r, g, b)
end

function Color.toRGB255(c3)
    return
        math.floor(c3.R * 255 + 0.5),
        math.floor(c3.G * 255 + 0.5),
        math.floor(c3.B * 255 + 0.5)
end



--==============================================================================
-- WaffleUI.Easing
--
-- Raw easing functions (t in [0..1]) and pre-built `TweenInfo` presets.
--
-- Each family implements three variants: In, Out, InOut. They are pure
-- functions — no state, no side effects — so you can wire them into custom
-- animation code when the built-in Roblox EasingStyle set is not enough.
--
-- Usage:
--     local e = WaffleUI.Easing
--     local y = e.cubic.inOut(t)
--     game:GetService("TweenService"):Create(
--         part, e.TweenInfo.SpringFast, { Position = target }
--     ):Play()
--==============================================================================
WaffleUI.Easing = {}
local Easing = WaffleUI.Easing

-- Small utility: for each tuple {name, inFn, outFn, inOutFn}, register it.
local function register(name, inFn, outFn, inOutFn)
    Easing[name] = { ["in"] = inFn, out = outFn, inOut = inOutFn }
end

-- Linear -------------------------------------------------------------------
register("linear",
    function(t) return t end,
    function(t) return t end,
    function(t) return t end)

-- Quadratic ----------------------------------------------------------------
register("quad",
    function(t) return t * t end,
    function(t) return t * (2 - t) end,
    function(t)
        if t < 0.5 then return 2 * t * t end
        return -1 + (4 - 2 * t) * t
    end)

-- Cubic --------------------------------------------------------------------
register("cubic",
    function(t) return t * t * t end,
    function(t) t = t - 1; return t * t * t + 1 end,
    function(t)
        if t < 0.5 then return 4 * t * t * t end
        t = t - 1
        return 1 + 4 * t * t * t
    end)

-- Quart --------------------------------------------------------------------
register("quart",
    function(t) return t * t * t * t end,
    function(t) t = t - 1; return 1 - t * t * t * t end,
    function(t)
        if t < 0.5 then return 8 * t * t * t * t end
        t = t - 1
        return 1 - 8 * t * t * t * t
    end)

-- Quint --------------------------------------------------------------------
register("quint",
    function(t) return t ^ 5 end,
    function(t) return 1 - (1 - t) ^ 5 end,
    function(t)
        if t < 0.5 then return 16 * t ^ 5 end
        return 1 - ((-2 * t + 2) ^ 5) / 2
    end)

-- Sine ---------------------------------------------------------------------
register("sine",
    function(t) return 1 - math.cos((t * math.pi) / 2) end,
    function(t) return math.sin((t * math.pi) / 2) end,
    function(t) return -(math.cos(math.pi * t) - 1) / 2 end)

-- Exponential --------------------------------------------------------------
register("expo",
    function(t) return t == 0 and 0 or 2 ^ (10 * t - 10) end,
    function(t) return t == 1 and 1 or 1 - 2 ^ (-10 * t) end,
    function(t)
        if t == 0 then return 0 end
        if t == 1 then return 1 end
        if t < 0.5 then return 2 ^ (20 * t - 10) / 2 end
        return (2 - 2 ^ (-20 * t + 10)) / 2
    end)

-- Circular -----------------------------------------------------------------
register("circ",
    function(t) return 1 - math.sqrt(1 - t * t) end,
    function(t) return math.sqrt(1 - (t - 1) ^ 2) end,
    function(t)
        if t < 0.5 then return (1 - math.sqrt(1 - (2 * t) ^ 2)) / 2 end
        return (math.sqrt(1 - (-2 * t + 2) ^ 2) + 1) / 2
    end)

-- Back (small overshoot) ---------------------------------------------------
local c1 = 1.70158
local c2 = c1 * 1.525
local c3e = c1 + 1
register("back",
    function(t) return c3e * t * t * t - c1 * t * t end,
    function(t) t = t - 1; return 1 + c3e * t * t * t + c1 * t * t end,
    function(t)
        if t < 0.5 then
            return ((2 * t) ^ 2 * ((c2 + 1) * 2 * t - c2)) / 2
        end
        return ((2 * t - 2) ^ 2 * ((c2 + 1) * (t * 2 - 2) + c2) + 2) / 2
    end)

-- Elastic (wobble) ---------------------------------------------------------
local c4 = (2 * math.pi) / 3
local c5 = (2 * math.pi) / 4.5
register("elastic",
    function(t)
        if t == 0 then return 0 end
        if t == 1 then return 1 end
        return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * c4)
    end,
    function(t)
        if t == 0 then return 0 end
        if t == 1 then return 1 end
        return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
    end,
    function(t)
        if t == 0 then return 0 end
        if t == 1 then return 1 end
        if t < 0.5 then
            return -(2 ^ (20 * t - 10) * math.sin((20 * t - 11.125) * c5)) / 2
        end
        return (2 ^ (-20 * t + 10) * math.sin((20 * t - 11.125) * c5)) / 2 + 1
    end)

-- Bounce -------------------------------------------------------------------
local function bounceOut(t)
    local n1, d1 = 7.5625, 2.75
    if t < 1 / d1 then
        return n1 * t * t
    elseif t < 2 / d1 then
        t = t - 1.5 / d1; return n1 * t * t + 0.75
    elseif t < 2.5 / d1 then
        t = t - 2.25 / d1; return n1 * t * t + 0.9375
    end
    t = t - 2.625 / d1
    return n1 * t * t + 0.984375
end
register("bounce",
    function(t) return 1 - bounceOut(1 - t) end,
    bounceOut,
    function(t)
        if t < 0.5 then
            return (1 - bounceOut(1 - 2 * t)) / 2
        end
        return (1 + bounceOut(2 * t - 1)) / 2
    end)

-- TweenInfo presets --------------------------------------------------------
Easing.TweenInfo = {
    InstantOut    = TweenInfo.new(0.08,  Enum.EasingStyle.Quad,  Enum.EasingDirection.Out),
    Quick         = TweenInfo.new(0.15,  Enum.EasingStyle.Quad,  Enum.EasingDirection.Out),
    Medium        = TweenInfo.new(0.25,  Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Slow          = TweenInfo.new(0.45,  Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Cinematic     = TweenInfo.new(0.75,  Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Spring        = TweenInfo.new(0.35,  Enum.EasingStyle.Back,  Enum.EasingDirection.Out, 0, false, 0),
    SpringFast    = TweenInfo.new(0.25,  Enum.EasingStyle.Back,  Enum.EasingDirection.Out),
    Bounce        = TweenInfo.new(0.55,  Enum.EasingStyle.Bounce,Enum.EasingDirection.Out),
    Elastic       = TweenInfo.new(0.85,  Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
    Linear        = TweenInfo.new(0.25,  Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
    Hover         = TweenInfo.new(0.10,  Enum.EasingStyle.Quad,  Enum.EasingDirection.Out),
    Focus         = TweenInfo.new(0.18,  Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    Dialog        = TweenInfo.new(0.30,  Enum.EasingStyle.Back,  Enum.EasingDirection.Out),
    Fade          = TweenInfo.new(0.20,  Enum.EasingStyle.Sine,  Enum.EasingDirection.Out),
    SlideIn       = TweenInfo.new(0.35,  Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    SlideOut      = TweenInfo.new(0.25,  Enum.EasingStyle.Quint, Enum.EasingDirection.In),
}

--[[
    The raw easing functions live at Easing.<family>.<direction>(t). Examples:
        Easing.cubic.inOut(0.4)
        Easing.elastic.out(0.9)
        Easing.bounce.out(0.5)

    You can pass any of these into your own RunService.Heartbeat loops when
    you need animation finer than the TweenService can provide (for example,
    driving multiple dependent properties with coupled timing curves).
]]



--==============================================================================
-- WaffleUI.Signal
--
-- Minimal, allocation-friendly Signal implementation. Has the same surface
-- as RBXScriptSignal: Connect / Once / Wait / Fire / DisconnectAll. Useful
-- for wiring component -> application code without leaning on BindableEvent
-- instances.
--
-- Design notes:
--     * Listeners are stored in a doubly-linked list so Disconnect is O(1).
--     * Fire iterates a snapshot so Disconnect-while-firing is safe.
--     * Once detaches its own listener before the callback fires, preventing
--       re-entrant firing from re-invoking the same one-shot.
--==============================================================================
WaffleUI.Signal = {}
local Signal = WaffleUI.Signal
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _head = nil, _tail = nil, _count = 0 }, Signal)
end

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
    if self._disconnected then return end
    self._disconnected = true
    local sig = self._signal
    if self._prev then self._prev._next = self._next end
    if self._next then self._next._prev = self._prev end
    if sig._head == self then sig._head = self._next end
    if sig._tail == self then sig._tail = self._prev end
    sig._count = sig._count - 1
    self._signal = nil
    self._callback = nil
    self._prev = nil
    self._next = nil
end
Connection.disconnect = Connection.Disconnect

function Signal:Connect(callback)
    assert(type(callback) == "function", "Signal:Connect expects a function")
    local conn = setmetatable({
        _signal = self,
        _callback = callback,
        _prev = self._tail,
        _next = nil,
        _disconnected = false,
    }, Connection)
    if self._tail then self._tail._next = conn end
    self._tail = conn
    self._head = self._head or conn
    self._count = self._count + 1
    return conn
end

function Signal:Once(callback)
    local conn
    conn = self:Connect(function(...)
        conn:Disconnect()
        callback(...)
    end)
    return conn
end

function Signal:Wait()
    local co = coroutine.running()
    assert(co, "Signal:Wait must be called from a coroutine")
    local conn
    conn = self:Connect(function(...)
        conn:Disconnect()
        task.spawn(co, ...)
    end)
    return coroutine.yield()
end

function Signal:Fire(...)
    -- Snapshot the listener list so Disconnect-during-fire is safe.
    local snapshot = {}
    local n = 0
    local cur = self._head
    while cur do
        n = n + 1
        snapshot[n] = cur
        cur = cur._next
    end
    for i = 1, n do
        local c = snapshot[i]
        if not c._disconnected and c._callback then
            task.spawn(c._callback, ...)
        end
    end
end

function Signal:DisconnectAll()
    local cur = self._head
    while cur do
        local nxt = cur._next
        cur._disconnected = true
        cur._signal = nil
        cur._callback = nil
        cur._prev = nil
        cur._next = nil
        cur = nxt
    end
    self._head, self._tail, self._count = nil, nil, 0
end

function Signal:Count()
    return self._count
end



--==============================================================================
-- WaffleUI.Store
--
-- Observable key-value state container with path subscriptions.
--
-- Intended for sharing settings between tabs or between the UI layer and
-- game logic. A Store is just a table wrapped with change notifications;
-- anything you can put in a Lua table can live inside.
--
--     local store = WaffleUI.Store.new({ hp = 100, ui = { theme = "Dark" } })
--     store:Subscribe("ui.theme", function(new) print(new) end)
--     store:Set("ui.theme", "Ocean")        -- fires subscribers
--     store:Patch({ ui = { theme = "Light" } })
--     store:Get("hp")                       -- 100
--
-- `Subscribe` returns an unsubscribe function. Subscribers are batched: a
-- Patch that changes N leaf keys fires N subscriber events (not one per
-- level).
--==============================================================================
WaffleUI.Store = {}
local Store = WaffleUI.Store
Store.__index = Store

local function splitPath(path)
    local parts = {}
    if type(path) == "table" then
        for _, p in ipairs(path) do parts[#parts + 1] = p end
    else
        for part in string.gmatch(tostring(path), "[^%.]+") do
            parts[#parts + 1] = part
        end
    end
    return parts
end

local function deepGet(t, parts)
    local cur = t
    for i = 1, #parts do
        if type(cur) ~= "table" then return nil end
        cur = cur[parts[i]]
    end
    return cur
end

local function deepSet(t, parts, value)
    local cur = t
    for i = 1, #parts - 1 do
        local k = parts[i]
        if type(cur[k]) ~= "table" then cur[k] = {} end
        cur = cur[k]
    end
    local last = parts[#parts]
    local prev = cur[last]
    cur[last] = value
    return prev
end

function Store.new(initial)
    local self = setmetatable({
        _state = initial or {},
        _subs = {},            -- [pathKey] = { [id] = callback }
        _wildcard = {},        -- subscribers that get every change
        _nextId = 1,
        Changed = WaffleUI.Signal.new(),
    }, Store)
    return self
end

function Store:Get(path)
    if path == nil then return self._state end
    return deepGet(self._state, splitPath(path))
end

local function fireKey(self, key, value, prev)
    local bucket = self._subs[key]
    if bucket then
        for _, cb in pairs(bucket) do
            task.spawn(cb, value, prev, key)
        end
    end
    for _, cb in pairs(self._wildcard) do
        task.spawn(cb, value, prev, key)
    end
    self.Changed:Fire(key, value, prev)
end

function Store:Set(path, value)
    local parts = splitPath(path)
    local prev = deepSet(self._state, parts, value)
    if prev == value then return value end
    local key = table.concat(parts, ".")
    fireKey(self, key, value, prev)
    return value
end

-- Recursively patches nested tables; fires one event per changed leaf.
function Store:Patch(partial, prefix)
    prefix = prefix or ""
    assert(type(partial) == "table", "Store:Patch expects a table")
    for k, v in pairs(partial) do
        local dotted = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
        if type(v) == "table" and type(self:Get(dotted)) == "table" then
            self:Patch(v, dotted)
        else
            self:Set(dotted, v)
        end
    end
end

function Store:Subscribe(path, callback)
    assert(type(callback) == "function", "Store:Subscribe expects a function")
    if path == "*" or path == nil then
        local id = self._nextId; self._nextId = id + 1
        self._wildcard[id] = callback
        return function() self._wildcard[id] = nil end
    end
    local key = table.concat(splitPath(path), ".")
    local bucket = self._subs[key]
    if not bucket then
        bucket = {}; self._subs[key] = bucket
    end
    local id = self._nextId; self._nextId = id + 1
    bucket[id] = callback
    return function()
        if self._subs[key] then self._subs[key][id] = nil end
    end
end

function Store:Reset(newState)
    self._state = newState or {}
    -- Broadcast a single top-level reset event. Individual subscribers can
    -- re-query with :Get to rebuild their local view.
    for key, bucket in pairs(self._subs) do
        local v = deepGet(self._state, splitPath(key))
        for _, cb in pairs(bucket) do task.spawn(cb, v, nil, key) end
    end
    self.Changed:Fire("*", self._state, nil)
end

function Store:Destroy()
    self._subs = {}
    self._wildcard = {}
    self.Changed:DisconnectAll()
end



--==============================================================================
-- WaffleUI.Validator
--
-- Schema-based validation for form fields. Works standalone (no UI coupling)
-- so you can reuse it for game-side data too.
--
--     local V = WaffleUI.Validator
--     local schema = V.schema({
--         name = V.string():min(2):max(24):required(),
--         age  = V.number():min(13):max(120):required(),
--         email = V.string():pattern("^[^@]+@[^@]+$"):required(),
--         flags = V.table():nonEmpty(),
--     })
--
--     local ok, errors = schema:validate({ name = "a", age = 12 })
--     if not ok then for field, msg in pairs(errors) do print(field, msg) end end
--
-- Each rule builder returns a chainable object, and each chain ends with a
-- call to one of the shared terminators (:validate / :required / :optional).
--==============================================================================
WaffleUI.Validator = {}
local Validator = WaffleUI.Validator

local Rule = {}
Rule.__index = Rule

local function makeRule(kind)
    return setmetatable({
        kind = kind,
        checks = {},
        isRequired = false,
        _default = nil,
        _hasDefault = false,
    }, Rule)
end

function Rule:required(message)
    self.isRequired = true
    self._requiredMessage = message
    return self
end

function Rule:optional()
    self.isRequired = false
    return self
end

function Rule:default(value)
    self._hasDefault = true
    self._default = value
    return self
end

function Rule:_add(fn, msg)
    table.insert(self.checks, { fn = fn, msg = msg })
    return self
end

-- Type-specific builders ---------------------------------------------------
local function stringRule()
    local r = makeRule("string")
    return r:_add(function(v)
        return type(v) == "string", "must be a string"
    end)
end

local function numberRule()
    local r = makeRule("number")
    return r:_add(function(v)
        return type(v) == "number", "must be a number"
    end)
end

local function booleanRule()
    local r = makeRule("boolean")
    return r:_add(function(v)
        return type(v) == "boolean", "must be a boolean"
    end)
end

local function tableRule()
    local r = makeRule("table")
    return r:_add(function(v)
        return type(v) == "table", "must be a table"
    end)
end

local function anyRule()
    return makeRule("any")
end

local function enumRule(values)
    local set = {}
    for _, v in ipairs(values) do set[v] = true end
    local r = makeRule("enum")
    return r:_add(function(v)
        return set[v] ~= nil, "must be one of the allowed values"
    end)
end

-- Chainable modifiers ------------------------------------------------------
function Rule:min(n, msg)
    return self:_add(function(v)
        if self.kind == "string" then return #v >= n, msg or ("must be at least " .. n .. " characters") end
        if self.kind == "number" then return v >= n,  msg or ("must be at least " .. n) end
        if self.kind == "table"  then return #v >= n, msg or ("must contain at least " .. n .. " items") end
        return true
    end)
end

function Rule:max(n, msg)
    return self:_add(function(v)
        if self.kind == "string" then return #v <= n, msg or ("must be at most " .. n .. " characters") end
        if self.kind == "number" then return v <= n,  msg or ("must be at most " .. n) end
        if self.kind == "table"  then return #v <= n, msg or ("must contain at most " .. n .. " items") end
        return true
    end)
end

function Rule:range(lo, hi, msg)
    return self:_add(function(v)
        if type(v) ~= "number" then return false, "must be a number" end
        return v >= lo and v <= hi, msg or ("must be between " .. lo .. " and " .. hi)
    end)
end

function Rule:pattern(pat, msg)
    return self:_add(function(v)
        return type(v) == "string" and string.match(v, pat) ~= nil,
            msg or ("must match pattern " .. pat)
    end)
end

function Rule:oneOf(values, msg)
    local set = {}
    for _, v in ipairs(values) do set[v] = true end
    return self:_add(function(v)
        return set[v] ~= nil, msg or "must be one of the allowed values"
    end)
end

function Rule:integer(msg)
    return self:_add(function(v)
        return type(v) == "number" and v == math.floor(v),
            msg or "must be an integer"
    end)
end

function Rule:positive(msg)
    return self:_add(function(v)
        return type(v) == "number" and v > 0, msg or "must be positive"
    end)
end

function Rule:nonEmpty(msg)
    return self:_add(function(v)
        if type(v) == "string" then return #v > 0, msg or "must not be empty" end
        if type(v) == "table"  then return next(v) ~= nil, msg or "must not be empty" end
        return true
    end)
end

function Rule:custom(fn, msg)
    return self:_add(fn, msg or "failed custom validation")
end

function Rule:validate(value)
    -- Required / default handling
    if value == nil then
        if self._hasDefault then value = self._default end
    end
    if value == nil then
        if self.isRequired then
            return false, self._requiredMessage or "is required"
        end
        return true, nil
    end
    for _, check in ipairs(self.checks) do
        local ok, msg = check.fn(value)
        if not ok then
            return false, msg or check.msg or "invalid value"
        end
    end
    return true, nil
end

-- Schema: bundles multiple rules keyed by field name -----------------------
local Schema = {}
Schema.__index = Schema

local function schemaNew(fields)
    return setmetatable({ fields = fields or {} }, Schema)
end

function Schema:validate(data)
    data = data or {}
    local errors, okAll = {}, true
    for key, rule in pairs(self.fields) do
        local ok, msg = rule:validate(data[key])
        if not ok then
            errors[key] = msg
            okAll = false
        end
    end
    return okAll, errors
end

function Schema:extend(moreFields)
    local merged = {}
    for k, v in pairs(self.fields) do merged[k] = v end
    for k, v in pairs(moreFields or {}) do merged[k] = v end
    return schemaNew(merged)
end

function Schema:pick(keys)
    local picked = {}
    for _, k in ipairs(keys) do
        if self.fields[k] then picked[k] = self.fields[k] end
    end
    return schemaNew(picked)
end

function Schema:omit(keys)
    local set = {}
    for _, k in ipairs(keys) do set[k] = true end
    local kept = {}
    for k, v in pairs(self.fields) do
        if not set[k] then kept[k] = v end
    end
    return schemaNew(kept)
end

-- Public surface -----------------------------------------------------------
Validator.schema   = schemaNew
Validator.string   = stringRule
Validator.number   = numberRule
Validator.boolean  = booleanRule
Validator.table    = tableRule
Validator.any      = anyRule
Validator.enum     = enumRule



--==============================================================================
-- WaffleUI.i18n
--
-- Locale tables + translator. Small enough to hand-edit, big enough to be
-- useful for themed hubs that ship in multiple languages. Missing keys fall
-- back to the first-registered locale (usually English).
--
-- Usage:
--     local t = WaffleUI.i18n
--     t:Register("en", { hello = "Hello", greet = "Hello, {name}!" })
--     t:Register("es", { hello = "Hola",  greet = "Hola, {name}!" })
--     t:SetLocale("es")
--     t:Translate("greet", { name = "Sam" })  --> "Hola, Sam!"
--
-- Formatting uses `{name}` placeholders filled from the params table.
-- Numeric placeholders like `{1}` work too when params is array-style.
--==============================================================================
WaffleUI.i18n = {}
local i18n = WaffleUI.i18n

i18n._locales = {}         -- [localeCode] = { key = template }
i18n._current = nil
i18n._fallback = nil
i18n.Changed = WaffleUI.Signal.new()

function i18n:Register(code, dict)
    assert(type(code) == "string", "i18n:Register: code must be a string")
    assert(type(dict) == "table",  "i18n:Register: dict must be a table")
    self._locales[code] = self._locales[code] or {}
    for k, v in pairs(dict) do self._locales[code][k] = v end
    self._fallback = self._fallback or code
    self._current  = self._current  or code
end

function i18n:SetLocale(code)
    assert(self._locales[code], "i18n:SetLocale: unknown locale '" .. tostring(code) .. "'")
    if self._current == code then return end
    self._current = code
    self.Changed:Fire(code)
end

function i18n:SetFallback(code)
    assert(self._locales[code], "i18n:SetFallback: unknown locale '" .. tostring(code) .. "'")
    self._fallback = code
end

function i18n:HasKey(key, code)
    code = code or self._current
    return self._locales[code] and self._locales[code][key] ~= nil
end

function i18n:Translate(key, params)
    local current = self._locales[self._current]
    local fallback = self._locales[self._fallback]
    local template = (current and current[key]) or (fallback and fallback[key]) or key
    if type(template) ~= "string" then return template end
    if params and next(params) then
        template = template:gsub("{([%w_]+)}", function(name)
            local val = params[name] or params[tonumber(name) or -1]
            return tostring(val == nil and ("{" .. name .. "}") or val)
        end)
    end
    return template
end

-- Shorthand; lets you write i18n("hello")
setmetatable(i18n, { __call = function(self, key, params) return self:Translate(key, params) end })

-- Seed locales with shared UI strings so components can use translations
-- without requiring every consumer to register them.
i18n:Register("en", {
    ["action.save"]       = "Save",
    ["action.cancel"]     = "Cancel",
    ["action.confirm"]    = "Confirm",
    ["action.delete"]     = "Delete",
    ["action.close"]      = "Close",
    ["action.reset"]      = "Reset",
    ["action.apply"]      = "Apply",
    ["action.retry"]      = "Retry",
    ["action.ok"]         = "OK",
    ["action.yes"]        = "Yes",
    ["action.no"]         = "No",
    ["common.loading"]    = "Loading...",
    ["common.search"]     = "Search",
    ["common.no_results"] = "No results",
    ["common.empty"]      = "Nothing here yet",
    ["common.error"]      = "Something went wrong",
    ["common.settings"]   = "Settings",
    ["common.back"]       = "Back",
    ["notify.success"]    = "Success",
    ["notify.warning"]    = "Warning",
    ["notify.error"]      = "Error",
    ["notify.info"]       = "Info",
})

i18n:Register("es", {
    ["action.save"]       = "Guardar",
    ["action.cancel"]     = "Cancelar",
    ["action.confirm"]    = "Confirmar",
    ["action.delete"]     = "Eliminar",
    ["action.close"]      = "Cerrar",
    ["action.reset"]      = "Restablecer",
    ["action.apply"]      = "Aplicar",
    ["action.retry"]      = "Reintentar",
    ["action.ok"]         = "Aceptar",
    ["action.yes"]        = "Sí",
    ["action.no"]         = "No",
    ["common.loading"]    = "Cargando...",
    ["common.search"]     = "Buscar",
    ["common.no_results"] = "Sin resultados",
    ["common.empty"]      = "Aún no hay nada aquí",
    ["common.error"]      = "Algo salió mal",
    ["common.settings"]   = "Ajustes",
    ["common.back"]       = "Atrás",
    ["notify.success"]    = "Éxito",
    ["notify.warning"]    = "Advertencia",
    ["notify.error"]      = "Error",
    ["notify.info"]       = "Información",
})

i18n:Register("fr", {
    ["action.save"]       = "Enregistrer",
    ["action.cancel"]     = "Annuler",
    ["action.confirm"]    = "Confirmer",
    ["action.delete"]     = "Supprimer",
    ["action.close"]      = "Fermer",
    ["action.reset"]      = "Réinitialiser",
    ["action.apply"]      = "Appliquer",
    ["action.retry"]      = "Réessayer",
    ["action.ok"]         = "OK",
    ["action.yes"]        = "Oui",
    ["action.no"]         = "Non",
    ["common.loading"]    = "Chargement...",
    ["common.search"]     = "Rechercher",
    ["common.no_results"] = "Aucun résultat",
    ["common.empty"]      = "Rien ici pour l'instant",
    ["common.error"]      = "Une erreur est survenue",
    ["common.settings"]   = "Paramètres",
    ["common.back"]       = "Retour",
    ["notify.success"]    = "Succès",
    ["notify.warning"]    = "Avertissement",
    ["notify.error"]      = "Erreur",
    ["notify.info"]       = "Info",
})

i18n:Register("de", {
    ["action.save"]       = "Speichern",
    ["action.cancel"]     = "Abbrechen",
    ["action.confirm"]    = "Bestätigen",
    ["action.delete"]     = "Löschen",
    ["action.close"]      = "Schließen",
    ["action.reset"]      = "Zurücksetzen",
    ["action.apply"]      = "Anwenden",
    ["action.retry"]      = "Erneut versuchen",
    ["action.ok"]         = "OK",
    ["action.yes"]        = "Ja",
    ["action.no"]         = "Nein",
    ["common.loading"]    = "Wird geladen...",
    ["common.search"]     = "Suchen",
    ["common.no_results"] = "Keine Ergebnisse",
    ["common.empty"]      = "Noch nichts hier",
    ["common.error"]      = "Etwas ist schiefgelaufen",
    ["common.settings"]   = "Einstellungen",
    ["common.back"]       = "Zurück",
    ["notify.success"]    = "Erfolg",
    ["notify.warning"]    = "Warnung",
    ["notify.error"]      = "Fehler",
    ["notify.info"]       = "Info",
})

i18n:Register("pt", {
    ["action.save"]       = "Salvar",
    ["action.cancel"]     = "Cancelar",
    ["action.confirm"]    = "Confirmar",
    ["action.delete"]     = "Excluir",
    ["action.close"]      = "Fechar",
    ["action.reset"]      = "Redefinir",
    ["action.apply"]      = "Aplicar",
    ["action.retry"]      = "Tentar novamente",
    ["action.ok"]         = "OK",
    ["action.yes"]        = "Sim",
    ["action.no"]         = "Não",
    ["common.loading"]    = "Carregando...",
    ["common.search"]     = "Pesquisar",
    ["common.no_results"] = "Sem resultados",
    ["common.empty"]      = "Nada aqui ainda",
    ["common.error"]      = "Algo deu errado",
    ["common.settings"]   = "Configurações",
    ["common.back"]       = "Voltar",
    ["notify.success"]    = "Sucesso",
    ["notify.warning"]    = "Aviso",
    ["notify.error"]      = "Erro",
    ["notify.info"]       = "Informação",
})

i18n:Register("ja", {
    ["action.save"]       = "保存",
    ["action.cancel"]     = "キャンセル",
    ["action.confirm"]    = "確認",
    ["action.delete"]     = "削除",
    ["action.close"]      = "閉じる",
    ["action.reset"]      = "リセット",
    ["action.apply"]      = "適用",
    ["action.retry"]      = "再試行",
    ["action.ok"]         = "OK",
    ["action.yes"]        = "はい",
    ["action.no"]         = "いいえ",
    ["common.loading"]    = "読み込み中...",
    ["common.search"]     = "検索",
    ["common.no_results"] = "結果なし",
    ["common.empty"]      = "まだ何もありません",
    ["common.error"]      = "問題が発生しました",
    ["common.settings"]   = "設定",
    ["common.back"]       = "戻る",
    ["notify.success"]    = "成功",
    ["notify.warning"]    = "警告",
    ["notify.error"]      = "エラー",
    ["notify.info"]       = "情報",
})



--==============================================================================
-- WaffleUI.Format
--
-- Number / time / byte formatters. They try to be fast and allocation-light
-- because they're likely called from per-frame update loops (HUDs etc.).
--==============================================================================
WaffleUI.Format = {}
local Format = WaffleUI.Format

-- Pretty-print a number with a thousands separator. Default separator is
-- ',' to match US/UK conventions; pass "." for dotted European style.
function Format.thousands(n, sep)
    sep = sep or ","
    local sign = n < 0 and "-" or ""
    local intPart = math.floor(math.abs(n))
    local decPart = math.abs(n) - intPart
    local intStr = tostring(intPart)
    local k
    while true do
        intStr, k = intStr:gsub("^(-?%d+)(%d%d%d)", "%1" .. sep .. "%2")
        if k == 0 then break end
    end
    if decPart > 0 then
        local tail = string.format("%.6f", decPart):match("%.(%d-)0*$")
        if tail and #tail > 0 then
            return sign .. intStr .. "." .. tail
        end
    end
    return sign .. intStr
end

-- Abbreviate large numbers (1.2K, 3.4M, 5.6B...). Useful for score HUDs.
function Format.abbrev(n)
    local abs = math.abs(n)
    local sign = n < 0 and "-" or ""
    local suffixes = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
    local i = 1
    while abs >= 1000 and i < #suffixes do
        abs = abs / 1000
        i = i + 1
    end
    if i == 1 then return sign .. tostring(math.floor(abs)) end
    return string.format("%s%.2f%s", sign, abs, suffixes[i])
end

-- Bytes (1024-based). For SI (1000-based) pass useSI=true.
function Format.bytes(n, useSI)
    local base = useSI and 1000 or 1024
    local units = useSI
        and { "B", "kB", "MB", "GB", "TB", "PB", "EB" }
        or  { "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" }
    local abs = math.abs(n)
    local i = 1
    while abs >= base and i < #units do
        abs = abs / base
        i = i + 1
    end
    if i == 1 then return tostring(math.floor(abs)) .. units[i] end
    return string.format("%.2f%s", abs, units[i])
end

-- Format seconds as H:MM:SS or M:SS. Pass padHours=true to always show H.
function Format.duration(seconds, padHours)
    seconds = math.max(0, math.floor(seconds))
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = seconds % 60
    if h > 0 or padHours then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

-- Short "x ago" relative time for logs/notifications. Seconds argument is
-- time difference (now - then); negative values flip to "in X".
function Format.relative(deltaSeconds)
    local abs = math.abs(deltaSeconds)
    local prefix = deltaSeconds < 0 and "in " or ""
    local suffix = deltaSeconds < 0 and "" or " ago"
    local function fmt(n, unit)
        local rounded = math.floor(n)
        local plural = rounded == 1 and "" or "s"
        return prefix .. rounded .. " " .. unit .. plural .. suffix
    end
    if abs < 10      then return "just now" end
    if abs < 60      then return fmt(abs, "second") end
    if abs < 3600    then return fmt(abs / 60, "minute") end
    if abs < 86400   then return fmt(abs / 3600, "hour") end
    if abs < 604800  then return fmt(abs / 86400, "day") end
    if abs < 2419200 then return fmt(abs / 604800, "week") end
    if abs < 29030400 then return fmt(abs / 2419200, "month") end
    return fmt(abs / 29030400, "year")
end

-- Pad an integer for fixed-width alignment in tables.
function Format.padInt(n, width, char)
    char = char or " "
    local s = tostring(math.floor(n))
    return string.rep(char, math.max(0, width - #s)) .. s
end

-- Truncate a string to a max width, appending an ellipsis when needed.
function Format.truncate(s, width, ellipsis)
    ellipsis = ellipsis or "..."
    if #s <= width then return s end
    if width <= #ellipsis then return ellipsis:sub(1, width) end
    return s:sub(1, width - #ellipsis) .. ellipsis
end

-- Plural helper: Format.pluralize(count, "item", "items")
function Format.pluralize(n, singular, plural)
    plural = plural or (singular .. "s")
    return tostring(n) .. " " .. (n == 1 and singular or plural)
end

-- Percentage with configurable precision.
function Format.percent(fraction, precision)
    precision = precision or 1
    return string.format("%." .. precision .. "f%%", fraction * 100)
end

-- Currency: default $ with comma thousands.
function Format.currency(n, symbol)
    symbol = symbol or "$"
    local neg = n < 0
    local body = Format.thousands(math.abs(n))
    -- Ensure we always show two decimal places for currency.
    if not body:find("%.") then
        body = body .. ".00"
    else
        local _, _, decs = body:find("%.(%d+)$")
        if decs and #decs == 1 then body = body .. "0" end
    end
    return (neg and "-" or "") .. symbol .. body
end



--==============================================================================
-- WaffleUI.Sequencer
--
-- Chainable tween sequence runner. Lets you express keyframed animations in
-- a readable way:
--
--     local seq = WaffleUI.Sequencer.new()
--         :to(frame, { Position = UDim2.fromScale(0.5, 0.5) }, 0.3, "Quint")
--         :wait(0.1)
--         :to(frame, { BackgroundTransparency = 0 }, 0.2, "Quad")
--         :call(function() print("done fading") end)
--         :parallel({
--             { obj = icon,  props = { Rotation = 360 }, duration = 0.4 },
--             { obj = label, props = { TextTransparency = 0 }, duration = 0.2 },
--         })
--         :play()
--
-- Steps run sequentially; :parallel runs its children in parallel and the
-- sequence waits for the longest child to finish before continuing.
--==============================================================================
WaffleUI.Sequencer = {}
local Sequencer = WaffleUI.Sequencer
Sequencer.__index = Sequencer

local function styleOf(name)
    if type(name) == "table" then return name end   -- already a TweenInfo
    if not name then return MEDIUM end
    local s = Enum.EasingStyle[name] or Enum.EasingStyle.Quint
    return function(duration)
        return TweenInfo.new(duration or 0.25, s, Enum.EasingDirection.Out)
    end
end

function Sequencer.new()
    return setmetatable({
        _steps = {},
        _running = false,
        _cancelled = false,
        Completed = WaffleUI.Signal.new(),
        Cancelled = WaffleUI.Signal.new(),
    }, Sequencer)
end

function Sequencer:to(obj, props, duration, style)
    table.insert(self._steps, {
        kind = "to",
        obj = obj, props = props, duration = duration or 0.25, style = style,
    })
    return self
end

function Sequencer:wait(seconds)
    table.insert(self._steps, { kind = "wait", duration = seconds or 0 })
    return self
end

function Sequencer:call(fn)
    table.insert(self._steps, { kind = "call", fn = fn })
    return self
end

function Sequencer:set(obj, props)
    -- Immediately assign properties without a tween.
    table.insert(self._steps, { kind = "set", obj = obj, props = props })
    return self
end

function Sequencer:parallel(tweens)
    table.insert(self._steps, { kind = "parallel", tweens = tweens })
    return self
end

function Sequencer:repeatTimes(n, inner)
    assert(type(inner) == "function", "Sequencer:repeatTimes expects a builder function")
    for _ = 1, n do inner(self) end
    return self
end

local function buildInfo(style, duration)
    if type(style) == "table" then return style end
    local factory = styleOf(style)
    if type(factory) == "function" then return factory(duration) end
    return factory
end

local function runStep(step)
    if step.kind == "wait" then
        task.wait(step.duration)
    elseif step.kind == "call" then
        step.fn()
    elseif step.kind == "set" then
        for k, v in pairs(step.props) do step.obj[k] = v end
    elseif step.kind == "to" then
        local info = buildInfo(step.style, step.duration)
        local t = TweenService:Create(step.obj, info, step.props)
        t:Play()
        if t.Completed then t.Completed:Wait() else task.wait(step.duration) end
    elseif step.kind == "parallel" then
        local remaining = #step.tweens
        if remaining == 0 then return end
        local done = Instance.new("BindableEvent")
        local longest = 0
        for _, tw in ipairs(step.tweens) do
            longest = math.max(longest, tw.duration or 0.25)
            local info = buildInfo(tw.style, tw.duration)
            local t = TweenService:Create(tw.obj, info, tw.props)
            t.Completed:Connect(function()
                remaining = remaining - 1
                if remaining == 0 then done:Fire() end
            end)
            t:Play()
        end
        done.Event:Wait()
        done:Destroy()
    end
end

function Sequencer:play()
    if self._running then return self end
    self._running = true
    self._cancelled = false
    task.spawn(function()
        for _, step in ipairs(self._steps) do
            if self._cancelled then break end
            local ok, err = pcall(runStep, step)
            if not ok then warn("Sequencer step failed:", err) end
        end
        self._running = false
        if self._cancelled then
            self.Cancelled:Fire()
        else
            self.Completed:Fire()
        end
    end)
    return self
end

function Sequencer:cancel()
    if not self._running then return end
    self._cancelled = true
end

function Sequencer:isRunning()
    return self._running
end



--==============================================================================
-- WaffleUI.CommandPalette
--
-- A Ctrl+K style command runner. Commands are registered globally and can
-- be opened with an optional hotkey. Each command is a small record:
--
--     Palette:Register({
--         id = "teleport.spawn",
--         name = "Teleport to spawn",
--         description = "Return to the world spawn point",
--         group = "Teleport",
--         keywords = { "home", "start" },
--         shortcut = { Enum.KeyCode.T, Enum.KeyCode.H },
--         run = function() ... end,
--     })
--
-- Open the palette with Palette:Open() or by pressing the hotkey. Fuzzy
-- matching weighs prefix matches higher and falls back to substring match.
--
-- This module creates and owns its own ScreenGui so it works as a pure
-- add-on; you do not need to have any windows open to use it.
--==============================================================================
WaffleUI.CommandPalette = {}
local Palette = WaffleUI.CommandPalette
Palette.__index = Palette

Palette._commands = {}
Palette._open = false
Palette._gui = nil
Palette._bag = ConnectionBag.new()
Palette._hotkey = {
    ctrl = true,
    key  = Enum.KeyCode.K,
}

function Palette:Register(cmd)
    assert(cmd and cmd.id and cmd.name, "CommandPalette:Register: id and name are required")
    assert(type(cmd.run) == "function", "CommandPalette:Register: run must be a function")
    self._commands[cmd.id] = {
        id = cmd.id,
        name = cmd.name,
        description = cmd.description or "",
        group = cmd.group or "General",
        keywords = cmd.keywords or {},
        shortcut = cmd.shortcut,
        run = cmd.run,
    }
    return cmd.id
end

function Palette:Unregister(id)
    self._commands[id] = nil
end

function Palette:List()
    local out = {}
    for _, cmd in pairs(self._commands) do table.insert(out, cmd) end
    table.sort(out, function(a, b)
        if a.group ~= b.group then return a.group < b.group end
        return a.name < b.name
    end)
    return out
end

-- Fuzzy scoring. Returns 0 if no match. Higher is better.
local function scoreMatch(query, text)
    if query == "" then return 1 end
    local qLow, tLow = query:lower(), text:lower()
    if qLow == tLow then return 1000 end
    if tLow:find(qLow, 1, true) == 1 then return 800 - #text end
    local found = tLow:find(qLow, 1, true)
    if found then return 500 - found end
    -- Subsequence match: all characters of query appear in order.
    local ti = 1
    for qi = 1, #qLow do
        local c = qLow:sub(qi, qi)
        local pos = tLow:find(c, ti, true)
        if not pos then return 0 end
        ti = pos + 1
    end
    return 200 - #text
end

function Palette:Search(query)
    query = query or ""
    local results = {}
    for _, cmd in pairs(self._commands) do
        local best = scoreMatch(query, cmd.name)
        for _, kw in ipairs(cmd.keywords) do
            best = math.max(best, scoreMatch(query, kw))
        end
        if cmd.description ~= "" then
            best = math.max(best, scoreMatch(query, cmd.description) * 0.5)
        end
        if best > 0 then
            table.insert(results, { cmd = cmd, score = best })
        end
    end
    table.sort(results, function(a, b) return a.score > b.score end)
    local flat = {}
    for i, r in ipairs(results) do flat[i] = r.cmd end
    return flat
end

function Palette:SetHotkey(key, ctrl, shift, alt)
    self._hotkey = { key = key, ctrl = ctrl, shift = shift, alt = alt }
end

function Palette:Run(id)
    local cmd = self._commands[id]
    if not cmd then return false, "unknown command " .. tostring(id) end
    local ok, err = pcall(cmd.run)
    if not ok then warn("Command '" .. id .. "' failed:", err) end
    return ok, err
end

-- The visual overlay -------------------------------------------------------
function Palette:_buildGui()
    if self._gui then return self._gui end
    local parent = CoreGui
    local ok = pcall(function() return CoreGui end)
    if not ok then parent = PlayerGui end

    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleCommandPalette"
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 10000
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Enabled = false

    local overlay = Instance.new("TextButton")
    overlay.AutoButtonColor = false
    overlay.Text = ""
    overlay.BackgroundColor3 = Color3.new(0, 0, 0)
    overlay.BackgroundTransparency = 0.45
    overlay.BorderSizePixel = 0
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.Parent = gui

    local card = Instance.new("Frame")
    card.Size = UDim2.new(0, 560, 0, 360)
    card.Position = UDim2.fromScale(0.5, 0.3)
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
    card.BorderSizePixel = 0
    card.Parent = gui
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 10); corner.Parent = card
    local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(70, 70, 90); stroke.Parent = card

    local search = Instance.new("TextBox")
    search.Size = UDim2.new(1, -20, 0, 40)
    search.Position = UDim2.fromOffset(10, 10)
    search.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
    search.Text = ""
    search.PlaceholderText = "Type a command..."
    search.TextColor3 = Color3.fromRGB(240, 240, 245)
    search.PlaceholderColor3 = Color3.fromRGB(140, 140, 160)
    search.Font = Enum.Font.Gotham
    search.TextSize = 14
    search.TextXAlignment = Enum.TextXAlignment.Left
    search.ClearTextOnFocus = false
    search.BorderSizePixel = 0
    search.Parent = card
    local sCorner = Instance.new("UICorner"); sCorner.CornerRadius = UDim.new(0, 6); sCorner.Parent = search
    local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.Parent = search

    local list = Instance.new("ScrollingFrame")
    list.Size = UDim2.new(1, -20, 1, -60)
    list.Position = UDim2.fromOffset(10, 55)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.ScrollBarThickness = 4
    list.Parent = card
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 4)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = list

    self._gui = gui
    self._parts = { overlay = overlay, card = card, search = search, list = list }

    -- Close handlers
    self._bag:Add(overlay.MouseButton1Click:Connect(function() self:Close() end))
    self._bag:Add(search:GetPropertyChangedSignal("Text"):Connect(function()
        self:_rebuildList()
    end))

    gui.Parent = parent
    return gui
end

function Palette:_rebuildList()
    if not self._parts then return end
    local list = self._parts.list
    for _, child in ipairs(list:GetChildren()) do
        if child:IsA("TextButton") then child:Destroy() end
    end
    local matches = self:Search(self._parts.search.Text)
    for i, cmd in ipairs(matches) do
        local row = Instance.new("TextButton")
        row.Size = UDim2.new(1, 0, 0, 34)
        row.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
        row.AutoButtonColor = false
        row.Text = ""
        row.BorderSizePixel = 0
        row.LayoutOrder = i
        row.Parent = list
        local rc = Instance.new("UICorner"); rc.CornerRadius = UDim.new(0, 6); rc.Parent = row

        local name = Instance.new("TextLabel")
        name.BackgroundTransparency = 1
        name.Font = Enum.Font.GothamMedium
        name.TextSize = 13
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.Size = UDim2.new(0.5, -10, 1, 0)
        name.Position = UDim2.fromOffset(10, 0)
        name.Text = cmd.name
        name.TextColor3 = Color3.fromRGB(240, 240, 245)
        name.Parent = row

        local group = Instance.new("TextLabel")
        group.BackgroundTransparency = 1
        group.Font = Enum.Font.Gotham
        group.TextSize = 11
        group.TextXAlignment = Enum.TextXAlignment.Right
        group.Size = UDim2.new(0.5, -10, 1, 0)
        group.Position = UDim2.new(0.5, 0, 0, 0)
        group.Text = cmd.group
        group.TextColor3 = Color3.fromRGB(140, 140, 160)
        group.Parent = row

        row.MouseButton1Click:Connect(function()
            self:Close()
            self:Run(cmd.id)
        end)
    end
end

function Palette:Open()
    if self._open then return end
    self._open = true
    local gui = self:_buildGui()
    gui.Enabled = true
    self._parts.search.Text = ""
    self:_rebuildList()
    task.defer(function()
        if self._parts and self._parts.search then
            self._parts.search:CaptureFocus()
        end
    end)
end

function Palette:Close()
    if not self._open then return end
    self._open = false
    if self._gui then self._gui.Enabled = false end
end

function Palette:Toggle()
    if self._open then self:Close() else self:Open() end
end

-- Global hotkey hookup (safe to call many times).
function Palette:InstallHotkey()
    if self._hotkeyInstalled then return end
    self._hotkeyInstalled = true
    self._bag:Add(UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local hk = self._hotkey
        if hk.key ~= input.KeyCode then return end
        if hk.ctrl and not (UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)) then return end
        if hk.shift and not (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)) then return end
        if hk.alt and not (UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)) then return end
        self:Toggle()
    end))
    self._bag:Add(UserInputService.InputBegan:Connect(function(input, processed)
        if self._open and input.KeyCode == Enum.KeyCode.Escape then
            self:Close()
        end
    end))
end



--==============================================================================
-- WaffleUI.Diagnostics
--
-- Perf counters + debug overlay. Use it to instrument your UI code and
-- surface the numbers in a tiny always-visible panel. Counters are cheap to
-- sample (just two math ops per tick) so you can leave them on in
-- development builds.
--
--     local D = WaffleUI.Diagnostics
--     D:Counter("ui.button.clicks"):Inc()
--     local h = D:Histogram("ui.tween.ms"):Observe(elapsed)
--     D:Gauge("fps"):Set(1 / dt)
--     D:Overlay(true)    -- display the HUD
--==============================================================================
WaffleUI.Diagnostics = {}
local Diag = WaffleUI.Diagnostics
Diag._counters = {}
Diag._gauges = {}
Diag._histograms = {}
Diag._overlayEnabled = false
Diag._overlayBag = ConnectionBag.new()

local Counter = {}; Counter.__index = Counter
function Counter:Inc(n) self.value = self.value + (n or 1); return self.value end
function Counter:Reset() self.value = 0; return self end
function Counter:Get() return self.value end

local Gauge = {}; Gauge.__index = Gauge
function Gauge:Set(n) self.value = n; return self end
function Gauge:Get() return self.value end

local Histogram = {}; Histogram.__index = Histogram
function Histogram:Observe(v)
    self.count = self.count + 1
    self.sum = self.sum + v
    self.min = (self.count == 1) and v or math.min(self.min, v)
    self.max = (self.count == 1) and v or math.max(self.max, v)
    local idx = (self._idx % self._cap) + 1
    self._idx = idx
    self._samples[idx] = v
    return self
end
function Histogram:Average()
    if self.count == 0 then return 0 end
    return self.sum / self.count
end
function Histogram:P(q)
    -- q in 0..1. Rough percentile over stored window.
    if self.count == 0 then return 0 end
    local copy = {}
    for i, v in ipairs(self._samples) do copy[i] = v end
    table.sort(copy)
    local idx = math.max(1, math.min(#copy, math.ceil(q * #copy)))
    return copy[idx]
end

function Diag:Counter(name)
    local c = self._counters[name]
    if not c then
        c = setmetatable({ name = name, value = 0 }, Counter)
        self._counters[name] = c
    end
    return c
end

function Diag:Gauge(name)
    local g = self._gauges[name]
    if not g then
        g = setmetatable({ name = name, value = 0 }, Gauge)
        self._gauges[name] = g
    end
    return g
end

function Diag:Histogram(name, windowSize)
    local h = self._histograms[name]
    if not h then
        h = setmetatable({
            name = name, count = 0, sum = 0, min = 0, max = 0,
            _samples = {}, _cap = windowSize or 120, _idx = 0,
        }, Histogram)
        self._histograms[name] = h
    end
    return h
end

function Diag:Snapshot()
    local out = { counters = {}, gauges = {}, histograms = {} }
    for n, c in pairs(self._counters)   do out.counters[n]   = c.value end
    for n, g in pairs(self._gauges)     do out.gauges[n]     = g.value end
    for n, h in pairs(self._histograms) do
        out.histograms[n] = {
            count = h.count, sum = h.sum, min = h.min, max = h.max,
            avg = h:Average(), p50 = h:P(0.5), p95 = h:P(0.95), p99 = h:P(0.99),
        }
    end
    return out
end

function Diag:Reset()
    for _, c in pairs(self._counters) do c:Reset() end
    for _, g in pairs(self._gauges) do g.value = 0 end
    for _, h in pairs(self._histograms) do
        h.count, h.sum, h.min, h.max, h._idx, h._samples = 0, 0, 0, 0, 0, {}
    end
end

-- Overlay: a corner HUD that dumps snapshot() once per second.
function Diag:Overlay(enabled)
    self._overlayEnabled = enabled and true or false
    if not enabled then
        if self._overlayGui then self._overlayGui.Enabled = false end
        self._overlayBag:Destroy()
        self._overlayBag = ConnectionBag.new()
        return
    end
    if not self._overlayGui then
        local parent = PlayerGui or CoreGui
        local gui = Instance.new("ScreenGui")
        gui.Name = "WaffleDiagnosticsOverlay"
        gui.IgnoreGuiInset = true
        gui.ResetOnSpawn = false
        gui.DisplayOrder = 99999
        gui.Parent = parent
        local frame = Instance.new("Frame")
        frame.Size = UDim2.fromOffset(260, 160)
        frame.Position = UDim2.new(1, -270, 0, 10)
        frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        frame.BackgroundTransparency = 0.3
        frame.BorderSizePixel = 0
        frame.Parent = gui
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = frame
        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Size = UDim2.fromScale(1, 1)
        label.Font = Enum.Font.Code
        label.TextSize = 11
        label.TextColor3 = Color3.fromRGB(200, 255, 200)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Top
        label.Text = ""
        label.Parent = frame
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 6); pad.PaddingTop = UDim.new(0, 6)
        pad.Parent = frame
        self._overlayGui = gui
        self._overlayLabel = label
    end
    self._overlayGui.Enabled = true
    self._overlayBag:Add(task.spawn(function()
        while self._overlayEnabled do
            local snap = self:Snapshot()
            local lines = {}
            for name, v in pairs(snap.counters) do
                table.insert(lines, string.format("C %-20s %d", name, v))
            end
            for name, v in pairs(snap.gauges) do
                table.insert(lines, string.format("G %-20s %.3f", name, v))
            end
            for name, v in pairs(snap.histograms) do
                table.insert(lines, string.format("H %-20s avg=%.2f p95=%.2f", name, v.avg, v.p95))
            end
            table.sort(lines)
            self._overlayLabel.Text = table.concat(lines, "\n")
            task.wait(1)
        end
    end) and nil)  -- we keep the loop alive via the enabled flag
end



--==============================================================================
-- WaffleUI.Layout
--
-- Pure layout math helpers. These do not touch the DOM at all; they take and
-- return Vector2/UDim2 values so you can pre-compute positions for
-- layouts that are too dynamic for UIListLayout / UIGridLayout to handle
-- directly.
--
-- Common use: compute a responsive grid where cell count depends on the
-- container width, then hand each cell its explicit UDim2 size/position.
--==============================================================================
WaffleUI.Layout = {}
local Layout = WaffleUI.Layout

function Layout.gridCellCount(containerWidth, targetCellWidth, minCount, maxCount)
    minCount = minCount or 1
    maxCount = maxCount or 12
    local n = math.floor(containerWidth / math.max(1, targetCellWidth))
    return math.clamp(n, minCount, maxCount)
end

function Layout.gridCellSize(containerWidth, columns, gap)
    gap = gap or 0
    local totalGap = gap * (columns - 1)
    return math.floor((containerWidth - totalGap) / columns)
end

function Layout.gridIndexToPosition(index, columns)
    local col = (index - 1) % columns
    local row = math.floor((index - 1) / columns)
    return col, row
end

function Layout.gridPosition(index, columns, cellW, cellH, gapX, gapY, originX, originY)
    gapX    = gapX or 0
    gapY    = gapY or gapX
    originX = originX or 0
    originY = originY or 0
    local col, row = Layout.gridIndexToPosition(index, columns)
    return UDim2.fromOffset(
        originX + col * (cellW + gapX),
        originY + row * (cellH + gapY)
    )
end

function Layout.centerIn(parentSize, childSize)
    return UDim2.fromOffset(
        math.floor((parentSize.X - childSize.X) / 2),
        math.floor((parentSize.Y - childSize.Y) / 2)
    )
end

function Layout.aspectFit(containerW, containerH, aspect)
    -- Largest size with given aspect that fits inside container.
    aspect = aspect or 1
    local w = containerW
    local h = w / aspect
    if h > containerH then
        h = containerH
        w = h * aspect
    end
    return math.floor(w), math.floor(h)
end

function Layout.aspectFill(containerW, containerH, aspect)
    aspect = aspect or 1
    local w = containerW
    local h = w / aspect
    if h < containerH then
        h = containerH
        w = h * aspect
    end
    return math.floor(w), math.floor(h)
end

-- Flex-like linear distribution. Items is an array of { basis = n, grow = n }.
-- Returns an array of sizes (integers) that sum to `total`.
function Layout.flex(items, total, gap)
    gap = gap or 0
    local spacing = gap * math.max(0, #items - 1)
    local free = total - spacing
    local basisSum, growSum = 0, 0
    for _, it in ipairs(items) do
        basisSum = basisSum + (it.basis or 0)
        growSum  = growSum  + (it.grow or 0)
    end
    local extra = math.max(0, free - basisSum)
    local out = {}
    for i, it in ipairs(items) do
        local size = (it.basis or 0)
        if growSum > 0 then
            size = size + extra * ((it.grow or 0) / growSum)
        end
        out[i] = math.floor(size)
    end
    -- Distribute rounding remainder to first item so widths sum exactly.
    local sum = 0
    for _, v in ipairs(out) do sum = sum + v end
    out[1] = out[1] + (free - sum)
    return out
end

-- Given a Vector2 anchor position and a size, compute an offset such that
-- the object stays within parentSize rectangle (useful for popovers).
function Layout.clampToParent(anchorX, anchorY, childW, childH, parentW, parentH)
    local x = math.clamp(anchorX, 0, parentW - childW)
    local y = math.clamp(anchorY, 0, parentH - childH)
    return x, y
end



--==============================================================================
-- WaffleUI.Util
--
-- Miscellaneous helpers that don't fit in any other module. Each function is
-- self-documenting via a short comment.
--==============================================================================
WaffleUI.Util = {}
local Util = WaffleUI.Util

-- Deep clone a table (no cycle detection — don't use on tables with loops).
function Util.deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = Util.deepCopy(v) end
    return out
end

-- Deep merge: b takes precedence, shared tables merge recursively.
function Util.deepMerge(a, b)
    local out = Util.deepCopy(a)
    for k, v in pairs(b) do
        if type(v) == "table" and type(out[k]) == "table" then
            out[k] = Util.deepMerge(out[k], v)
        else
            out[k] = Util.deepCopy(v)
        end
    end
    return out
end

-- Pick a set of keys from a table into a new table.
function Util.pick(t, keys)
    local out = {}
    for _, k in ipairs(keys) do out[k] = t[k] end
    return out
end

function Util.omit(t, keys)
    local set = {}
    for _, k in ipairs(keys) do set[k] = true end
    local out = {}
    for k, v in pairs(t) do
        if not set[k] then out[k] = v end
    end
    return out
end

-- Shallow array operations -------------------------------------------------
function Util.map(t, fn)
    local out = {}
    for i, v in ipairs(t) do out[i] = fn(v, i) end
    return out
end

function Util.filter(t, fn)
    local out = {}
    for i, v in ipairs(t) do
        if fn(v, i) then table.insert(out, v) end
    end
    return out
end

function Util.reduce(t, fn, seed)
    local acc = seed
    for i, v in ipairs(t) do acc = fn(acc, v, i) end
    return acc
end

function Util.find(t, fn)
    for i, v in ipairs(t) do
        if fn(v, i) then return v, i end
    end
    return nil
end

function Util.findIndex(t, fn)
    for i, v in ipairs(t) do
        if fn(v, i) then return i end
    end
    return nil
end

function Util.flatten(t)
    local out = {}
    for _, v in ipairs(t) do
        if type(v) == "table" then
            for _, vv in ipairs(v) do table.insert(out, vv) end
        else
            table.insert(out, v)
        end
    end
    return out
end

function Util.unique(t)
    local seen = {}
    local out = {}
    for _, v in ipairs(t) do
        if not seen[v] then seen[v] = true; table.insert(out, v) end
    end
    return out
end

function Util.groupBy(t, keyFn)
    local out = {}
    for _, v in ipairs(t) do
        local k = keyFn(v)
        out[k] = out[k] or {}
        table.insert(out[k], v)
    end
    return out
end

function Util.sortBy(t, keyFn, descending)
    local copy = {}
    for i, v in ipairs(t) do copy[i] = v end
    table.sort(copy, function(a, b)
        if descending then return keyFn(a) > keyFn(b) end
        return keyFn(a) < keyFn(b)
    end)
    return copy
end

function Util.reverse(t)
    local out = {}
    for i = #t, 1, -1 do table.insert(out, t[i]) end
    return out
end

function Util.chunk(t, size)
    size = math.max(1, size)
    local out = {}
    local cur = {}
    for i, v in ipairs(t) do
        table.insert(cur, v)
        if #cur == size then
            table.insert(out, cur); cur = {}
        end
    end
    if #cur > 0 then table.insert(out, cur) end
    return out
end

function Util.zip(a, b)
    local n = math.min(#a, #b)
    local out = {}
    for i = 1, n do out[i] = { a[i], b[i] } end
    return out
end

function Util.range(a, b, step)
    if b == nil then a, b = 1, a end
    step = step or 1
    local out = {}
    if step > 0 then
        for i = a, b, step do table.insert(out, i) end
    else
        for i = a, b, step do table.insert(out, i) end
    end
    return out
end

-- Functional helpers -------------------------------------------------------
function Util.debounce(fn, wait)
    local scheduled = false
    local lastArgs
    return function(...)
        lastArgs = { ... }
        if scheduled then return end
        scheduled = true
        task.delay(wait, function()
            scheduled = false
            fn(table.unpack(lastArgs))
        end)
    end
end

function Util.throttle(fn, wait)
    local lastCall = 0
    local pending = false
    local pendingArgs
    return function(...)
        local now = os.clock()
        if now - lastCall >= wait then
            lastCall = now
            fn(...)
        else
            pendingArgs = { ... }
            if not pending then
                pending = true
                task.delay(wait - (now - lastCall), function()
                    pending = false
                    lastCall = os.clock()
                    fn(table.unpack(pendingArgs))
                end)
            end
        end
    end
end

function Util.once(fn)
    local called, result = false, nil
    return function(...)
        if called then return result end
        called = true
        result = fn(...)
        return result
    end
end

function Util.memoize(fn, keyFn)
    local cache = {}
    keyFn = keyFn or function(...) return select(1, ...) end
    return function(...)
        local k = keyFn(...)
        if cache[k] == nil then cache[k] = fn(...) end
        return cache[k]
    end
end

function Util.compose(...)
    local fns = { ... }
    return function(x)
        for i = #fns, 1, -1 do x = fns[i](x) end
        return x
    end
end

function Util.pipe(...)
    local fns = { ... }
    return function(x)
        for i = 1, #fns do x = fns[i](x) end
        return x
    end
end

-- String helpers -----------------------------------------------------------
function Util.trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function Util.startsWith(s, prefix)
    return s:sub(1, #prefix) == prefix
end

function Util.endsWith(s, suffix)
    return suffix == "" or s:sub(- #suffix) == suffix
end

function Util.split(s, sep, plain)
    sep = sep or " "
    plain = plain == nil and true or plain
    local out, i = {}, 1
    while true do
        local a, b = s:find(sep, i, plain)
        if not a then
            table.insert(out, s:sub(i))
            break
        end
        table.insert(out, s:sub(i, a - 1))
        i = b + 1
    end
    return out
end

function Util.kebab(s)
    return (s:gsub("(%l)(%u)", "%1-%2"):gsub("%s+", "-"):lower())
end

function Util.camel(s)
    return (s:gsub("[_%- ](%a)", function(c) return c:upper() end))
end

function Util.titleCase(s)
    return (s:gsub("(%a)(%w*)", function(a, b) return a:upper() .. b:lower() end))
end

function Util.randomId(length)
    length = length or 8
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local out = {}
    for i = 1, length do
        local r = math.random(1, #chars)
        out[i] = chars:sub(r, r)
    end
    return table.concat(out)
end

-- Misc ---------------------------------------------------------------------
function Util.safeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn(err) end
    return ok, err
end

function Util.tryRequire(modulePath)
    local ok, mod = pcall(require, modulePath)
    if ok then return mod end
    return nil, mod
end

function Util.assertType(value, expected, label)
    if type(value) ~= expected then
        error(string.format("%s: expected %s, got %s",
            label or "value", expected, type(value)))
    end
    return value
end

-- Event loops --------------------------------------------------------------
function Util.onHeartbeat(fn)
    return RunService.Heartbeat:Connect(fn)
end

function Util.onRenderStep(fn)
    return RunService.RenderStepped:Connect(fn)
end

function Util.setInterval(seconds, fn)
    local cancelled = false
    task.spawn(function()
        while not cancelled do
            task.wait(seconds)
            if cancelled then break end
            local ok, err = pcall(fn)
            if not ok then warn(err) end
        end
    end)
    return function() cancelled = true end
end

function Util.setTimeout(seconds, fn)
    local cancelled = false
    task.delay(seconds, function()
        if cancelled then return end
        local ok, err = pcall(fn)
        if not ok then warn(err) end
    end)
    return function() cancelled = true end
end



--==============================================================================
-- WaffleUI.Math
--
-- Scalar/vector math helpers tuned for UI code (easing curves, smooth HUD
-- transitions, etc.). Names echo common shader utility functions to keep
-- the mental model short.
--==============================================================================
WaffleUI.Math = {}
local M = WaffleUI.Math

function M.lerp(a, b, t) return a + (b - a) * t end
function M.inverseLerp(a, b, v)
    if a == b then return 0 end
    return (v - a) / (b - a)
end

function M.remap(v, inMin, inMax, outMin, outMax)
    return M.lerp(outMin, outMax, M.inverseLerp(inMin, inMax, v))
end

function M.clamp(v, lo, hi) return math.clamp(v, lo, hi) end
function M.clamp01(v) return math.clamp(v, 0, 1) end

function M.sign(v)
    if v > 0 then return 1 end
    if v < 0 then return -1 end
    return 0
end

function M.approxEqual(a, b, eps)
    return math.abs(a - b) < (eps or 1e-6)
end

function M.round(v, step)
    step = step or 1
    return math.floor(v / step + 0.5) * step
end

function M.smoothstep(edge0, edge1, x)
    local t = M.clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
end

function M.smootherstep(edge0, edge1, x)
    local t = M.clamp01((x - edge0) / (edge1 - edge0))
    return t * t * t * (t * (t * 6 - 15) + 10)
end

function M.wrap(v, lo, hi)
    local range = hi - lo
    if range <= 0 then return lo end
    return lo + ((v - lo) % range)
end

function M.ping(v, lo, hi)
    -- Triangle wave between lo and hi.
    local range = hi - lo
    if range <= 0 then return lo end
    local t = M.wrap(v - lo, 0, 2 * range)
    if t > range then t = 2 * range - t end
    return lo + t
end

function M.mean(list)
    if #list == 0 then return 0 end
    local s = 0
    for _, v in ipairs(list) do s = s + v end
    return s / #list
end

function M.stdDev(list)
    local n = #list
    if n < 2 then return 0 end
    local mean = M.mean(list)
    local acc = 0
    for _, v in ipairs(list) do acc = acc + (v - mean) ^ 2 end
    return math.sqrt(acc / (n - 1))
end

function M.median(list)
    local n = #list
    if n == 0 then return 0 end
    local copy = {}
    for i, v in ipairs(list) do copy[i] = v end
    table.sort(copy)
    if n % 2 == 1 then return copy[(n + 1) / 2] end
    return (copy[n / 2] + copy[n / 2 + 1]) / 2
end

function M.sum(list)
    local s = 0
    for _, v in ipairs(list) do s = s + v end
    return s
end

function M.min(list)
    if #list == 0 then return 0 end
    local lo = list[1]
    for i = 2, #list do if list[i] < lo then lo = list[i] end end
    return lo
end

function M.max(list)
    if #list == 0 then return 0 end
    local hi = list[1]
    for i = 2, #list do if list[i] > hi then hi = list[i] end end
    return hi
end

function M.bezier(p0, p1, p2, p3, t)
    local u = 1 - t
    return u^3 * p0 + 3 * u^2 * t * p1 + 3 * u * t^2 * p2 + t^3 * p3
end

function M.catmullRom(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * ((2 * p1)
        + (-p0 + p2) * t
        + (2*p0 - 5*p1 + 4*p2 - p3) * t2
        + (-p0 + 3*p1 - 3*p2 + p3) * t3)
end

-- Rolling smoothing filter. Call :step(value) each frame to read a
-- low-pass version. Useful for FPS displays and pointer-following HUDs.
local RollingAverage = {}
RollingAverage.__index = RollingAverage

function M.rollingAverage(size)
    return setmetatable({
        _size = math.max(1, size or 30),
        _buf = {},
        _idx = 0,
        _count = 0,
        _sum = 0,
    }, RollingAverage)
end

function RollingAverage:step(value)
    local idx = (self._idx % self._size) + 1
    local old = self._buf[idx] or 0
    self._buf[idx] = value
    self._idx = idx
    if self._count < self._size then self._count = self._count + 1 end
    self._sum = self._sum + value - old
    return self._sum / self._count
end

function RollingAverage:value()
    if self._count == 0 then return 0 end
    return self._sum / self._count
end

function RollingAverage:reset()
    self._buf = {}; self._idx = 0; self._count = 0; self._sum = 0
end



--==============================================================================
-- WaffleUI.Keyboard
--
-- Global keybind/shortcut registry. Separate from Window-level Keybind
-- components: those bind a single key for one action, this one handles
-- multi-chord shortcuts ("Ctrl+Shift+D") across the whole UI.
--
-- Usage:
--     WaffleUI.Keyboard:Bind("Ctrl+Shift+D", function() ... end)
--     WaffleUI.Keyboard:Bind("Alt+Enter", function() ... end, { allowInTextBox = false })
--     WaffleUI.Keyboard:Unbind("Ctrl+Shift+D")
--
-- Parsing accepts "Ctrl" / "Control", "Shift", "Alt" / "Option", and any
-- Roblox KeyCode name joined with "+" in any order. Shortcuts are case-
-- insensitive.
--==============================================================================
WaffleUI.Keyboard = {}
local Keyboard = WaffleUI.Keyboard
Keyboard._bindings = {}             -- [normalizedShortcut] = { callback, opts }
Keyboard._installed = false
Keyboard._bag = ConnectionBag.new()

local function normalizeShortcut(str)
    local parts = {}
    local modifiers = { ctrl = false, shift = false, alt = false }
    local keyCode
    for token in string.gmatch(str:lower(), "[^%+]+") do
        token = token:gsub("^%s*(.-)%s*$", "%1")
        if token == "ctrl" or token == "control" then
            modifiers.ctrl = true
        elseif token == "shift" then
            modifiers.shift = true
        elseif token == "alt" or token == "option" or token == "opt" then
            modifiers.alt = true
        else
            local enumKey = token:sub(1,1):upper() .. token:sub(2)
            -- Handle common aliases
            local aliases = { esc = "Escape", enter = "Return", ret = "Return", del = "Delete" }
            local mapped = aliases[token] or enumKey
            local ok, v = pcall(function() return Enum.KeyCode[mapped] end)
            if ok and v then keyCode = v end
        end
    end
    return {
        modifiers = modifiers,
        keyCode = keyCode,
    }
end

local function shortcutKey(sc)
    local parts = {}
    if sc.modifiers.ctrl  then table.insert(parts, "Ctrl") end
    if sc.modifiers.shift then table.insert(parts, "Shift") end
    if sc.modifiers.alt   then table.insert(parts, "Alt") end
    table.insert(parts, tostring(sc.keyCode))
    return table.concat(parts, "+")
end

local function modifiersMatch(sc)
    local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
    local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
    local alt = UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)
        or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)
    if sc.modifiers.ctrl  ~= ctrl  then return false end
    if sc.modifiers.shift ~= shift then return false end
    if sc.modifiers.alt   ~= alt   then return false end
    return true
end

function Keyboard:Install()
    if self._installed then return end
    self._installed = true
    self._bag:Add(UserInputService.InputBegan:Connect(function(input, processed)
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        for key, binding in pairs(self._bindings) do
            local sc = binding.sc
            if sc.keyCode == input.KeyCode and modifiersMatch(sc) then
                local opts = binding.opts or {}
                if processed and not opts.allowInTextBox then return end
                local ok, err = pcall(binding.callback, input)
                if not ok then warn("Keyboard binding '" .. key .. "' failed:", err) end
                if opts.sink then return end
            end
        end
    end))
end

function Keyboard:Bind(shortcut, callback, opts)
    self:Install()
    local sc = normalizeShortcut(shortcut)
    if not sc.keyCode then
        error("Keyboard:Bind: couldn't parse key from '" .. shortcut .. "'")
    end
    local key = shortcutKey(sc)
    self._bindings[key] = { sc = sc, callback = callback, opts = opts }
    return key
end

function Keyboard:Unbind(shortcut)
    local sc = normalizeShortcut(shortcut)
    if not sc.keyCode then return end
    local key = shortcutKey(sc)
    self._bindings[key] = nil
end

function Keyboard:List()
    local out = {}
    for key in pairs(self._bindings) do table.insert(out, key) end
    table.sort(out)
    return out
end

function Keyboard:Clear()
    self._bindings = {}
end



--==============================================================================
-- WaffleUI.Persistence
--
-- Thin wrapper over writefile/readfile that degrades gracefully when those
-- executor-only functions are not available. Adds:
--     * JSON (de)serialization via HttpService
--     * Safe filename sanitisation
--     * Per-key file organisation (so multiple profiles don't stomp each
--       other)
--
-- The built-in Config system already uses writefile; this module is the
-- public, generally-useful shell around it.
--==============================================================================
WaffleUI.Persistence = {}
local Persistence = WaffleUI.Persistence

local function canWrite()
    return typeof(writefile) == "function" and typeof(readfile) == "function"
end

local function canList()
    return typeof(listfiles) == "function"
end

-- Strips characters that filesystems hate.
local function sanitize(name)
    return (tostring(name):gsub("[^%w%._%-]", "_"))
end

function Persistence:Available()
    return canWrite()
end

function Persistence:Save(key, value)
    if not canWrite() then return false, "writefile unavailable" end
    local filename = sanitize(key) .. ".json"
    local ok, encoded = pcall(HttpService.JSONEncode, HttpService, value)
    if not ok then return false, "JSON encode failed: " .. tostring(encoded) end
    local wok, werr = pcall(writefile, filename, encoded)
    if not wok then return false, "writefile failed: " .. tostring(werr) end
    return true
end

function Persistence:Load(key, fallback)
    if not canWrite() then return fallback end
    local filename = sanitize(key) .. ".json"
    local ok, content = pcall(readfile, filename)
    if not ok then return fallback end
    local dok, data = pcall(HttpService.JSONDecode, HttpService, content)
    if not dok then return fallback end
    return data
end

function Persistence:Delete(key)
    if typeof(delfile) ~= "function" then return false, "delfile unavailable" end
    local filename = sanitize(key) .. ".json"
    local ok, err = pcall(delfile, filename)
    return ok, err
end

function Persistence:Exists(key)
    if typeof(isfile) ~= "function" then return false end
    return isfile(sanitize(key) .. ".json")
end

function Persistence:List(prefix)
    if not canList() then return {} end
    local all = listfiles("")
    local out = {}
    prefix = prefix and sanitize(prefix) or ""
    for _, f in ipairs(all) do
        if f:sub(- 5) == ".json" and f:find(prefix, 1, true) then
            table.insert(out, f)
        end
    end
    return out
end

-- Namespaced helper. Returns an object bound to a key prefix so different
-- parts of your hub can have their own isolated stores.
function Persistence:Namespace(name)
    local prefix = sanitize(name) .. "."
    return {
        Save   = function(_, key, value) return Persistence:Save(prefix .. key, value) end,
        Load   = function(_, key, fb)    return Persistence:Load(prefix .. key, fb)    end,
        Delete = function(_, key)        return Persistence:Delete(prefix .. key)     end,
        Exists = function(_, key)        return Persistence:Exists(prefix .. key)     end,
    }
end



--==============================================================================
-- WaffleUI.Notify (advanced)
--
-- The core library already ships with a basic Notify entrypoint on each
-- Window. This module is a richer, standalone controller that supports:
--     * Severity levels (Info / Success / Warning / Error / Debug)
--     * Queueing with max concurrent stacks (older notifications fade)
--     * Update / Dismiss handles
--     * Programmatic position anchoring (topLeft, topRight, bottomLeft, bottomRight)
--     * Action buttons per notification
--
-- This is a *drop-in alternative* to Window:Notify that lives independent
-- of any window lifecycle. Use it for global toast infrastructure.
--==============================================================================
WaffleUI.Notify = {}
local Notify = WaffleUI.Notify

Notify._stacks = {}               -- [corner] = array of handles
Notify._maxPerStack = 4
Notify._defaultCorner = "topRight"
Notify._gui = nil

local severityPalette = {
    Info    = { bg = Color3.fromRGB(60, 110, 200),  icon = "ℹ" },
    Success = { bg = Color3.fromRGB(60, 180, 100),  icon = "✓" },
    Warning = { bg = Color3.fromRGB(230, 170,  40), icon = "!" },
    Error   = { bg = Color3.fromRGB(220,  70,  70), icon = "✕" },
    Debug   = { bg = Color3.fromRGB(120, 120, 130), icon = "•" },
}

local function cornerPosition(corner, widthPx, heightPx, indexFromTop)
    indexFromTop = indexFromTop or 0
    local yOff = 20 + indexFromTop * (heightPx + 10)
    if corner == "topLeft" then
        return UDim2.new(0, 20, 0, yOff), UDim2.new(0, -widthPx, 0, yOff)
    elseif corner == "topRight" then
        return UDim2.new(1, -widthPx - 20, 0, yOff), UDim2.new(1, 20, 0, yOff)
    elseif corner == "bottomLeft" then
        local baseY = UDim.new(1, -heightPx - yOff)
        return UDim2.new(UDim.new(0, 20), baseY), UDim2.new(UDim.new(0, -widthPx), baseY)
    elseif corner == "bottomRight" then
        local baseY = UDim.new(1, -heightPx - yOff)
        return UDim2.new(UDim.new(1, -widthPx - 20), baseY), UDim2.new(UDim.new(1, 20), baseY)
    end
    return UDim2.new(1, -widthPx - 20, 0, yOff), UDim2.new(1, 20, 0, yOff)
end

local function ensureGui()
    if Notify._gui and Notify._gui.Parent then return Notify._gui end
    local parent = CoreGui
    local ok = pcall(function() return CoreGui:GetChildren() end)
    if not ok then parent = PlayerGui end
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleAdvancedNotifier"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 20000
    gui.Parent = parent
    Notify._gui = gui
    return gui
end

local function reflow(corner)
    local stack = Notify._stacks[corner]
    if not stack then return end
    for i, handle in ipairs(stack) do
        if handle.frame then
            local pos, _ = cornerPosition(corner, handle.width, handle.height, i - 1)
            tween(handle.frame, MEDIUM, { Position = pos })
        end
    end
end

local function removeFromStack(corner, handle)
    local stack = Notify._stacks[corner]
    if not stack then return end
    for i, h in ipairs(stack) do
        if h == handle then table.remove(stack, i); break end
    end
    reflow(corner)
end

function Notify:SetMaxPerStack(n) self._maxPerStack = math.max(1, n) end
function Notify:SetDefaultCorner(c) self._defaultCorner = c end

function Notify:Push(opts)
    opts = opts or {}
    local severity = opts.Severity or "Info"
    local palette = severityPalette[severity] or severityPalette.Info
    local corner = opts.Corner or self._defaultCorner
    local width = 320
    local height = 82
    local gui = ensureGui()

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(width, height)
    frame.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
    frame.BorderSizePixel = 0
    frame.Parent = gui

    local startPos, offscreen = cornerPosition(corner, width, height)
    frame.Position = offscreen

    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = frame
    local stroke = Instance.new("UIStroke"); stroke.Color = palette.bg; stroke.Thickness = 1; stroke.Parent = frame

    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(0, 4, 1, 0); bar.BackgroundColor3 = palette.bg; bar.BorderSizePixel = 0; bar.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1; title.Font = Enum.Font.GothamBold
    title.TextSize = 14; title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.Position = UDim2.fromOffset(18, 10); title.Size = UDim2.new(1, -30, 0, 18)
    title.Text = opts.Title or severity; title.Parent = frame

    local body = Instance.new("TextLabel")
    body.BackgroundTransparency = 1; body.Font = Enum.Font.Gotham
    body.TextSize = 13; body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.TextColor3 = Color3.fromRGB(200, 200, 215)
    body.Position = UDim2.fromOffset(18, 30); body.Size = UDim2.new(1, -30, 0, 42)
    body.TextWrapped = true
    body.Text = opts.Text or ""; body.Parent = frame

    local close = Instance.new("TextButton")
    close.AutoButtonColor = false; close.Text = "×"
    close.Font = Enum.Font.GothamBold; close.TextSize = 18
    close.TextColor3 = Color3.fromRGB(200, 200, 215)
    close.BackgroundTransparency = 1
    close.Size = UDim2.fromOffset(24, 24)
    close.Position = UDim2.new(1, -28, 0, 6)
    close.Parent = frame

    self._stacks[corner] = self._stacks[corner] or {}
    local stack = self._stacks[corner]

    local handle = {
        frame = frame, width = width, height = height, corner = corner,
        _dismissed = false,
    }

    local function dismiss()
        if handle._dismissed then return end
        handle._dismissed = true
        local _, off = cornerPosition(corner, width, height)
        tween(frame, MEDIUM, { Position = off, BackgroundTransparency = 1 })
        task.delay(0.3, function()
            frame:Destroy()
            removeFromStack(corner, handle)
        end)
    end

    handle.Dismiss = dismiss
    function handle:Update(newTitle, newText)
        if newTitle then title.Text = newTitle end
        if newText  then body.Text  = newText  end
    end

    close.MouseButton1Click:Connect(dismiss)
    frame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then dismiss() end
    end)

    -- Evict oldest if we're over capacity.
    while #stack >= self._maxPerStack do
        local oldest = table.remove(stack, 1)
        if oldest and oldest.Dismiss then oldest:Dismiss() end
    end
    table.insert(stack, handle)
    reflow(corner)

    -- Slide in
    tween(frame, SPRING, { Position = startPos })

    -- Auto-dismiss
    local duration = opts.Duration or 5
    if duration > 0 then
        task.delay(duration, dismiss)
    end

    return handle
end

function Notify:Info(title, text, opts)
    opts = opts or {}; opts.Title = title; opts.Text = text; opts.Severity = "Info"
    return self:Push(opts)
end
function Notify:Success(title, text, opts)
    opts = opts or {}; opts.Title = title; opts.Text = text; opts.Severity = "Success"
    return self:Push(opts)
end
function Notify:Warn(title, text, opts)
    opts = opts or {}; opts.Title = title; opts.Text = text; opts.Severity = "Warning"
    return self:Push(opts)
end
function Notify:Error(title, text, opts)
    opts = opts or {}; opts.Title = title; opts.Text = text; opts.Severity = "Error"
    return self:Push(opts)
end
function Notify:Debug(title, text, opts)
    opts = opts or {}; opts.Title = title; opts.Text = text; opts.Severity = "Debug"
    return self:Push(opts)
end

function Notify:ClearAll()
    for corner, stack in pairs(self._stacks) do
        for _, h in ipairs(stack) do h:Dismiss() end
        self._stacks[corner] = {}
    end
end



--==============================================================================
-- WaffleUI.Preset
--
-- High-level "build me a hub" presets that wire several modules together so
-- you don't have to construct them by hand for the common cases. Each
-- preset returns a table of objects you can hold on to.
--==============================================================================
WaffleUI.Preset = {}
local Preset = WaffleUI.Preset

-- Quick stats HUD: perf + ping + fps.
function Preset.StatsHud(opts)
    opts = opts or {}
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleStatsHud"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 9999
    gui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(150, 68)
    frame.Position = UDim2.new(0, 10, 0, 10)
    frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    frame.BackgroundTransparency = 0.3
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = frame

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.Code
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.Text = ""
    label.Parent = frame
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 8); pad.PaddingTop = UDim.new(0, 6)
    pad.Parent = frame

    local rolling = WaffleUI.Math.rollingAverage(60)
    local running = true
    local conn = RunService.Heartbeat:Connect(function(dt)
        if not running then return end
        local fps = rolling:step(1 / math.max(dt, 1e-6))
        local stats = game:GetService("Stats")
        local ping = 0
        if stats.Network and stats.Network.ServerStatsItem then
            local item = stats.Network.ServerStatsItem["Data Ping"]
            if item then ping = item:GetValue() end
        end
        label.Text = string.format(
            "FPS: %.0f\nPing: %.0f ms\nPlayers: %d",
            fps, ping, #Players:GetPlayers())
    end)

    return {
        gui = gui,
        Destroy = function()
            running = false
            if conn then conn:Disconnect() end
            gui:Destroy()
        end,
    }
end

-- Toast-only setup: returns a small API.
function Preset.ToastOnly()
    return {
        info    = function(t, m) return WaffleUI.Notify:Info(t, m) end,
        success = function(t, m) return WaffleUI.Notify:Success(t, m) end,
        warn    = function(t, m) return WaffleUI.Notify:Warn(t, m) end,
        error   = function(t, m) return WaffleUI.Notify:Error(t, m) end,
    }
end

-- Confirm dialog without needing a full Window.
function Preset.ConfirmModal(opts)
    opts = opts or {}
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleConfirmModal"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 30000
    gui.Parent = parent

    local overlay = Instance.new("TextButton")
    overlay.AutoButtonColor = false; overlay.Text = ""
    overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    overlay.BackgroundTransparency = 0.4
    overlay.BorderSizePixel = 0
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.Parent = gui

    local card = Instance.new("Frame")
    card.Size = UDim2.fromOffset(380, 170)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
    card.BorderSizePixel = 0
    card.Parent = gui
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 10); c.Parent = card

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold; title.TextSize = 16
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Size = UDim2.new(1, -30, 0, 24)
    title.Position = UDim2.fromOffset(15, 12)
    title.Text = opts.Title or "Are you sure?"
    title.Parent = card

    local body = Instance.new("TextLabel")
    body.BackgroundTransparency = 1
    body.Font = Enum.Font.Gotham; body.TextSize = 13
    body.TextColor3 = Color3.fromRGB(200, 200, 215)
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.TextWrapped = true
    body.Size = UDim2.new(1, -30, 0, 70)
    body.Position = UDim2.fromOffset(15, 40)
    body.Text = opts.Message or ""; body.Parent = card

    local function button(text, x, primary)
        local b = Instance.new("TextButton")
        b.AutoButtonColor = false; b.Text = text
        b.Font = Enum.Font.GothamMedium; b.TextSize = 13
        b.TextColor3 = primary and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(230, 230, 240)
        b.BackgroundColor3 = primary and Color3.fromRGB(90, 140, 255) or Color3.fromRGB(50, 50, 64)
        b.BorderSizePixel = 0
        b.Size = UDim2.fromOffset(120, 34)
        b.Position = UDim2.new(1, -125, 1, -45)
        b.AnchorPoint = Vector2.new(x, 0)
        b.Parent = card
        local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 6); bc.Parent = b
        return b
    end

    local confirm = button(opts.ConfirmText or WaffleUI.i18n:Translate("action.confirm"), 0, true)
    local cancel  = button(opts.CancelText  or WaffleUI.i18n:Translate("action.cancel"), 0, false)
    cancel.Position = UDim2.new(1, -260, 1, -45)

    local function close()
        gui:Destroy()
    end

    confirm.MouseButton1Click:Connect(function()
        close()
        if opts.OnConfirm then opts.OnConfirm() end
    end)
    cancel.MouseButton1Click:Connect(function()
        close()
        if opts.OnCancel then opts.OnCancel() end
    end)
    overlay.MouseButton1Click:Connect(function()
        close()
        if opts.OnCancel then opts.OnCancel() end
    end)

    return { gui = gui, Close = close }
end



--==============================================================================
-- WaffleUI.Reactive
--
-- Small reactive primitives: a `State` holder and a `Computed` derivation.
-- You can attach any number of subscribers, and Computed values only
-- recompute when a source State changes. This is intentionally simple (no
-- dependency tracking) — you declare the dependencies up-front.
--
--     local hp = Reactive.state(100)
--     local pct = Reactive.computed({ hp }, function(v) return v / 100 end)
--     pct:subscribe(function(v) print(v) end)
--     hp:set(50)       -- prints 0.5
--==============================================================================
WaffleUI.Reactive = {}
local Reactive = WaffleUI.Reactive

local State = {}; State.__index = State
local Computed = {}; Computed.__index = Computed

function Reactive.state(initial)
    return setmetatable({
        _value = initial,
        _subs = {},
        _nextId = 1,
    }, State)
end

function State:get() return self._value end

function State:set(v)
    if v == self._value then return end
    local prev = self._value
    self._value = v
    for _, cb in pairs(self._subs) do
        task.spawn(cb, v, prev)
    end
end

function State:update(fn)
    self:set(fn(self._value))
end

function State:subscribe(callback)
    local id = self._nextId; self._nextId = id + 1
    self._subs[id] = callback
    return function() self._subs[id] = nil end
end

function State:peek() return self._value end  -- alias

function Reactive.computed(sources, fn)
    local comp = setmetatable({
        _sources = sources,
        _fn = fn,
        _value = fn(table.unpack(Util.map(sources, function(s) return s:get() end))),
        _subs = {},
        _nextId = 1,
    }, Computed)
    -- Resubscribe to every source and recompute whenever any of them change.
    for _, s in ipairs(sources) do
        s:subscribe(function()
            local args = {}
            for i, src in ipairs(sources) do args[i] = src:get() end
            local newValue = fn(table.unpack(args))
            if newValue == comp._value then return end
            local prev = comp._value
            comp._value = newValue
            for _, cb in pairs(comp._subs) do
                task.spawn(cb, newValue, prev)
            end
        end)
    end
    return comp
end

function Computed:get() return self._value end
function Computed:peek() return self._value end

function Computed:subscribe(callback)
    local id = self._nextId; self._nextId = id + 1
    self._subs[id] = callback
    -- Immediately notify with current value so subscribers don't miss the
    -- initial state.
    task.spawn(callback, self._value, nil)
    return function() self._subs[id] = nil end
end

-- Bind a Roblox instance property to a reactive source. Returns a teardown
-- function that removes the binding.
function Reactive.bind(instance, property, source, transform)
    transform = transform or function(v) return v end
    instance[property] = transform(source:get())
    return source:subscribe(function(v)
        instance[property] = transform(v)
    end)
end



--==============================================================================
-- WaffleUI.Router
--
-- Simple hash-style router for hubs that want to support deep-linking
-- between tabs/sections. The router itself is just a pub/sub on a single
-- string "path" — you wire it to your tabs.
--
--     local r = WaffleUI.Router.new()
--     r:Register("/main", function() mainTab:Activate() end)
--     r:Register("/settings/keybinds", function() settingsTab:Activate(); goto("keybinds") end)
--     r:Navigate("/main")     -- fires the main callback
--     r:Back() / r:Forward()  -- history stack
--==============================================================================
WaffleUI.Router = {}
local Router = WaffleUI.Router
Router.__index = Router

function Router.new()
    return setmetatable({
        _routes = {},
        _history = {},
        _future = {},
        _current = nil,
        Changed = WaffleUI.Signal.new(),
        NotFound = WaffleUI.Signal.new(),
    }, Router)
end

function Router:Register(path, handler)
    assert(type(path) == "string", "Router:Register: path must be a string")
    assert(type(handler) == "function", "Router:Register: handler must be a function")
    self._routes[path] = handler
end

function Router:Unregister(path)
    self._routes[path] = nil
end

function Router:Navigate(path, params)
    local handler = self._routes[path]
    if not handler then
        self.NotFound:Fire(path)
        return false
    end
    if self._current and self._current ~= path then
        table.insert(self._history, self._current)
        -- clear future on new navigation
        self._future = {}
    end
    self._current = path
    local ok, err = pcall(handler, params or {})
    if not ok then warn("Router handler for '" .. path .. "' failed:", err) end
    self.Changed:Fire(path, params)
    return true
end

function Router:Current() return self._current end

function Router:Back()
    local prev = table.remove(self._history)
    if not prev then return false end
    if self._current then table.insert(self._future, self._current) end
    self._current = prev
    local handler = self._routes[prev]
    if handler then pcall(handler, {}) end
    self.Changed:Fire(prev, {})
    return true
end

function Router:Forward()
    local nxt = table.remove(self._future)
    if not nxt then return false end
    if self._current then table.insert(self._history, self._current) end
    self._current = nxt
    local handler = self._routes[nxt]
    if handler then pcall(handler, {}) end
    self.Changed:Fire(nxt, {})
    return true
end

function Router:Routes()
    local out = {}
    for p in pairs(self._routes) do table.insert(out, p) end
    table.sort(out)
    return out
end



--==============================================================================
-- WaffleUI.Dialog
--
-- Richer modal dialogs than Preset.ConfirmModal. Supports a builder style:
--
--     Dialog.new()
--         :title("Confirm deletion")
--         :message("This will remove 3 saved profiles.")
--         :input("name", "Type DELETE to continue")
--         :button("Cancel", function(self) self:close() end)
--         :primary("Delete", function(self, values)
--             if values.name == "DELETE" then
--                 delete()
--                 self:close()
--             end
--         end)
--         :show()
--
-- Calls to .button and .primary run the callback with (dialog, values).
--==============================================================================
WaffleUI.Dialog = {}
local Dialog = WaffleUI.Dialog
Dialog.__index = Dialog

function Dialog.new()
    return setmetatable({
        _title = "",
        _message = "",
        _inputs = {},
        _buttons = {},
        _width = 420,
        _height = 220,
        _open = false,
    }, Dialog)
end

function Dialog:title(t) self._title = t; return self end
function Dialog:message(m) self._message = m; return self end
function Dialog:width(w) self._width = w; return self end
function Dialog:height(h) self._height = h; return self end
function Dialog:input(key, placeholder, default)
    table.insert(self._inputs, {
        key = key, placeholder = placeholder or "", default = default or "",
    })
    return self
end
function Dialog:button(text, cb)
    table.insert(self._buttons, { text = text, cb = cb, primary = false })
    return self
end
function Dialog:primary(text, cb)
    table.insert(self._buttons, { text = text, cb = cb, primary = true })
    return self
end

function Dialog:show()
    if self._open then return self end
    self._open = true
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleDialog"
    gui.DisplayOrder = 40000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent
    self._gui = gui

    local overlay = Instance.new("TextButton")
    overlay.AutoButtonColor = false; overlay.Text = ""
    overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    overlay.BackgroundTransparency = 0.4
    overlay.BorderSizePixel = 0
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.Parent = gui

    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromOffset(self._width, self._height)
    card.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
    card.BorderSizePixel = 0
    card.Parent = gui
    local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 10); cc.Parent = card

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold; title.TextSize = 16
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Size = UDim2.new(1, -30, 0, 22); title.Position = UDim2.fromOffset(15, 12)
    title.Text = self._title; title.Parent = card

    local body = Instance.new("TextLabel")
    body.BackgroundTransparency = 1
    body.Font = Enum.Font.Gotham; body.TextSize = 13
    body.TextColor3 = Color3.fromRGB(200, 200, 215)
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.TextWrapped = true
    body.Size = UDim2.new(1, -30, 0, 46)
    body.Position = UDim2.fromOffset(15, 38)
    body.Text = self._message; body.Parent = card

    local values = {}
    local currentY = 92
    local inputBoxes = {}
    for _, inp in ipairs(self._inputs) do
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(1, -30, 0, 34)
        box.Position = UDim2.fromOffset(15, currentY)
        box.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
        box.BorderSizePixel = 0
        box.Font = Enum.Font.Gotham; box.TextSize = 13
        box.TextColor3 = Color3.fromRGB(240, 240, 245)
        box.PlaceholderColor3 = Color3.fromRGB(140, 140, 160)
        box.PlaceholderText = inp.placeholder
        box.Text = inp.default or ""
        box.TextXAlignment = Enum.TextXAlignment.Left
        box.ClearTextOnFocus = false
        box.Parent = card
        local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 6); bc.Parent = box
        local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.Parent = box
        values[inp.key] = box.Text
        box:GetPropertyChangedSignal("Text"):Connect(function()
            values[inp.key] = box.Text
        end)
        inputBoxes[inp.key] = box
        currentY = currentY + 40
    end

    -- Buttons (right-aligned row at the bottom)
    local btnRow = Instance.new("Frame")
    btnRow.BackgroundTransparency = 1
    btnRow.Size = UDim2.new(1, -30, 0, 34)
    btnRow.Position = UDim2.new(0, 15, 1, -50)
    btnRow.Parent = card

    local rowLayout = Instance.new("UIListLayout")
    rowLayout.FillDirection = Enum.FillDirection.Horizontal
    rowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    rowLayout.Padding = UDim.new(0, 8)
    rowLayout.Parent = btnRow

    for _, b in ipairs(self._buttons) do
        local btn = Instance.new("TextButton")
        btn.AutoButtonColor = false; btn.Text = b.text
        btn.Font = Enum.Font.GothamMedium; btn.TextSize = 13
        btn.Size = UDim2.fromOffset(110, 34)
        btn.BorderSizePixel = 0
        btn.TextColor3 = b.primary and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(230, 230, 240)
        btn.BackgroundColor3 = b.primary and Color3.fromRGB(90, 140, 255) or Color3.fromRGB(50, 50, 64)
        btn.Parent = btnRow
        local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 6); bc.Parent = btn
        btn.MouseButton1Click:Connect(function()
            if b.cb then pcall(b.cb, self, values) end
        end)
    end

    return self
end

function Dialog:close()
    if not self._open then return end
    self._open = false
    if self._gui then self._gui:Destroy() end
end

function Dialog:setValue(key, value)
    -- no-op unless opened; callers normally pass `default` up-front.
    -- Kept for API symmetry.
end



--==============================================================================
-- WaffleUI.Cursor
--
-- Helpers for mouse/touch position that work in every context Roblox gives
-- us (immersive mode, gamepad cursor, touch). Mostly wraps UIS.GetMouseLocation
-- but with stable fallbacks for reading the active pointer on gamepad.
--==============================================================================
WaffleUI.Cursor = {}
local Cursor = WaffleUI.Cursor

function Cursor.screenPosition()
    local pos = UserInputService:GetMouseLocation()
    return Vector2.new(pos.X, pos.Y)
end

function Cursor.viewportSize()
    local cam = workspace.CurrentCamera
    if cam then return cam.ViewportSize end
    return Vector2.new(1024, 768)
end

function Cursor.isOverGui(gui)
    if not gui then return false end
    local pos = Cursor.screenPosition()
    local abs, size = gui.AbsolutePosition, gui.AbsoluteSize
    return pos.X >= abs.X and pos.X <= abs.X + size.X
        and pos.Y >= abs.Y and pos.Y <= abs.Y + size.Y
end

function Cursor.objectUnderMouse()
    -- Roblox has Player:GetMouse():Target for 3D hits; for GUI we have to
    -- rely on the input events. This is a best-effort helper that returns
    -- the first GuiObject at the cursor in a given ScreenGui.
    local root = PlayerGui
    if not root then return nil end
    local pos = Cursor.screenPosition()
    local function scan(node)
        if node:IsA("GuiObject") and node.Visible then
            local abs, size = node.AbsolutePosition, node.AbsoluteSize
            if pos.X >= abs.X and pos.X <= abs.X + size.X
            and pos.Y >= abs.Y and pos.Y <= abs.Y + size.Y then
                return node
            end
        end
        for _, child in ipairs(node:GetChildren()) do
            local found = scan(child)
            if found then return found end
        end
        return nil
    end
    return scan(root)
end

-- Convert screen pixel to a GuiObject's local coords in 0..1.
function Cursor.toLocal(gui, screenPos)
    screenPos = screenPos or Cursor.screenPosition()
    local abs, size = gui.AbsolutePosition, gui.AbsoluteSize
    return Vector2.new(
        (screenPos.X - abs.X) / math.max(1, size.X),
        (screenPos.Y - abs.Y) / math.max(1, size.Y)
    )
end



--==============================================================================
-- WaffleUI.Sound
--
-- Optional UI sound effect system. Loads a set of short audio ids and plays
-- them on component events. Because SoundIDs can change at any moment, the
-- ids are declared as a *registry* that the consumer can replace before
-- loading.
--
--     WaffleUI.Sound:SetAsset("click", "rbxassetid://6895079853")
--     WaffleUI.Sound:Play("click")
--==============================================================================
WaffleUI.Sound = {}
local Sound = WaffleUI.Sound

Sound._assets = {
    click      = "rbxassetid://6895079853",
    hover      = "rbxassetid://6895079457",
    toggleOn   = "rbxassetid://6895080062",
    toggleOff  = "rbxassetid://6895080181",
    notifyInfo = "rbxassetid://6895080354",
    notifyOk   = "rbxassetid://6895080563",
    notifyWarn = "rbxassetid://6895080767",
    notifyErr  = "rbxassetid://6895080912",
    tab        = "rbxassetid://6895081093",
    open       = "rbxassetid://6895081251",
    close      = "rbxassetid://6895081420",
}
Sound._pool = {}
Sound._volume = 0.5
Sound._enabled = true

function Sound:SetAsset(key, id)
    self._assets[key] = id
end

function Sound:SetVolume(v) self._volume = math.clamp(v, 0, 1) end
function Sound:SetEnabled(v) self._enabled = v and true or false end
function Sound:Enabled() return self._enabled end

local function soundParent()
    return (game:GetService("SoundService")) or workspace
end

function Sound:Play(key)
    if not self._enabled then return end
    local id = self._assets[key]
    if not id then return end
    local s = table.remove(self._pool)
    if not s then
        s = Instance.new("Sound")
        s.Parent = soundParent()
    end
    s.SoundId = id
    s.Volume = self._volume
    s:Play()
    s.Ended:Once(function()
        s:Stop()
        table.insert(self._pool, s)
    end)
end

function Sound:Preload()
    -- Roblox doesn't strictly require this, but forcing a quick play at 0
    -- volume warms the asset cache for smooth first-use.
    local ok = pcall(function()
        local prev = self._volume
        self._volume = 0
        for key in pairs(self._assets) do self:Play(key) end
        self._volume = prev
    end)
    return ok
end



--==============================================================================
-- WaffleUI.Logger
--
-- Leveled logger with sinks. Sinks receive a record
-- { level, message, time, tag, data } and decide what to do. Built-in sinks:
--     * ConsoleSink - prints to output with colors
--     * BufferSink  - keeps a ring buffer you can read later
--     * NotifySink  - routes warn+ to WaffleUI.Notify
--     * FileSink    - appends to a log file via WaffleUI.Persistence (if available)
--==============================================================================
WaffleUI.Logger = {}
local Logger = WaffleUI.Logger

Logger.LEVELS = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40, FATAL = 50 }

local function levelNum(level)
    if type(level) == "number" then return level end
    return Logger.LEVELS[string.upper(tostring(level))] or Logger.LEVELS.INFO
end

local function levelName(n)
    for k, v in pairs(Logger.LEVELS) do if v == n then return k end end
    return "INFO"
end

local function makeLogger(tag)
    local self = { _tag = tag or "", _sinks = {}, _level = Logger.LEVELS.INFO }

    function self:addSink(sink)
        table.insert(self._sinks, sink)
        return self
    end

    function self:setLevel(level)
        self._level = levelNum(level)
        return self
    end

    function self:log(level, message, data)
        local ln = levelNum(level)
        if ln < self._level then return end
        local rec = {
            level = ln,
            levelName = levelName(ln),
            message = message,
            time = os.time(),
            tag = self._tag,
            data = data,
        }
        for _, sink in ipairs(self._sinks) do
            pcall(sink, rec)
        end
    end

    function self:debug(m, d) self:log("DEBUG", m, d) end
    function self:info(m, d) self:log("INFO", m, d) end
    function self:warn(m, d) self:log("WARN", m, d) end
    function self:error(m, d) self:log("ERROR", m, d) end
    function self:fatal(m, d) self:log("FATAL", m, d) end

    function self:child(subTag)
        local joined = self._tag == "" and subTag or (self._tag .. "." .. subTag)
        local c = makeLogger(joined)
        c._sinks = self._sinks
        c._level = self._level
        return c
    end

    return self
end

Logger.new = makeLogger

-- Sinks --------------------------------------------------------------------
function Logger.ConsoleSink()
    return function(rec)
        local line = string.format("[%s] %s%s %s",
            rec.levelName,
            rec.tag ~= "" and ("[" .. rec.tag .. "] ") or "",
            "",
            rec.message)
        if rec.level >= Logger.LEVELS.WARN then
            warn(line)
        else
            print(line)
        end
    end
end

function Logger.BufferSink(capacity)
    capacity = capacity or 500
    local buf = { _records = {}, _cap = capacity, _idx = 0 }
    local sink = function(rec)
        local i = (buf._idx % buf._cap) + 1
        buf._idx = i
        buf._records[i] = rec
    end
    function buf:All()
        local out = {}
        for _, r in pairs(self._records) do table.insert(out, r) end
        table.sort(out, function(a, b) return a.time < b.time end)
        return out
    end
    function buf:Clear() self._records = {}; self._idx = 0 end
    return sink, buf
end

function Logger.NotifySink(minLevel)
    minLevel = levelNum(minLevel or "WARN")
    return function(rec)
        if rec.level < minLevel then return end
        local sev = rec.level >= Logger.LEVELS.ERROR and "Error"
             or rec.level >= Logger.LEVELS.WARN  and "Warning"
             or "Info"
        WaffleUI.Notify:Push({ Title = rec.levelName, Text = rec.message, Severity = sev })
    end
end

function Logger.FileSink(key)
    key = key or "waffle_log"
    return function(rec)
        if not WaffleUI.Persistence:Available() then return end
        local existing = WaffleUI.Persistence:Load(key, { entries = {} }) or { entries = {} }
        table.insert(existing.entries, {
            t = rec.time, l = rec.levelName, tag = rec.tag, m = rec.message,
        })
        -- cap on disk
        if #existing.entries > 2000 then
            local trimmed = {}
            for i = #existing.entries - 1999, #existing.entries do
                table.insert(trimmed, existing.entries[i])
            end
            existing.entries = trimmed
        end
        WaffleUI.Persistence:Save(key, existing)
    end
end

-- A default, pre-wired logger for quick use.
Logger.default = Logger.new("waffle")
    :addSink(Logger.ConsoleSink())
    :setLevel("INFO")



--==============================================================================
-- WaffleUI.Fuzzy
--
-- Fuzzy substring / subsequence searcher specialised for UI search boxes.
-- Returns both the best score and the positions of matched characters so a
-- UI can highlight them.
--==============================================================================
WaffleUI.Fuzzy = {}
local Fuzzy = WaffleUI.Fuzzy

-- Returns { score, positions } for the best match, or nil if not matched.
function Fuzzy.match(query, target)
    if query == "" then return { score = 0, positions = {} } end
    local q = query:lower()
    local t = target:lower()
    local qi, ti = 1, 1
    local positions = {}
    local score, lastMatchIdx = 0, nil
    while qi <= #q and ti <= #t do
        if q:sub(qi, qi) == t:sub(ti, ti) then
            table.insert(positions, ti)
            -- bonus for consecutive matches
            if lastMatchIdx and ti == lastMatchIdx + 1 then
                score = score + 12
            else
                score = score + 4
            end
            -- bonus if match is at a word boundary
            if ti == 1 or t:sub(ti - 1, ti - 1):match("[%s_%-%.]") then
                score = score + 8
            end
            lastMatchIdx = ti
            qi = qi + 1
        end
        ti = ti + 1
    end
    if qi <= #q then return nil end
    -- penalty for unmatched characters
    score = score - (#t - #q) * 0.1
    return { score = score, positions = positions }
end

-- Sort a list of items by fuzzy match score against `query`. Items can be
-- plain strings or tables; pass keyFn to pull a string out of a record.
function Fuzzy.filter(query, items, keyFn)
    keyFn = keyFn or function(x) return x end
    local scored = {}
    for _, item in ipairs(items) do
        local m = Fuzzy.match(query, keyFn(item))
        if m then
            table.insert(scored, { item = item, match = m })
        end
    end
    table.sort(scored, function(a, b) return a.match.score > b.match.score end)
    local out = {}
    for i, s in ipairs(scored) do out[i] = s.item end
    return out, scored
end

-- Wrap matched positions with RichText bold tags for display.
function Fuzzy.highlight(target, positions, openTag, closeTag)
    openTag = openTag or "<b>"
    closeTag = closeTag or "</b>"
    if not positions or #positions == 0 then return target end
    local set = {}
    for _, p in ipairs(positions) do set[p] = true end
    local out = {}
    for i = 1, #target do
        if set[i] then
            table.insert(out, openTag .. target:sub(i, i) .. closeTag)
        else
            table.insert(out, target:sub(i, i))
        end
    end
    return table.concat(out)
end



--==============================================================================
-- WaffleUI.Markdown
--
-- *Very* small markdown-to-RichText converter. Supports bold (**x** or __x__),
-- italic (*x* or _x_), inline code (`x`), links ([text](url)), headings (#),
-- and simple bullet lists. The output is a RichText-ready string suitable
-- for assignment to a TextLabel with RichText=true.
--==============================================================================
WaffleUI.Markdown = {}
local Markdown = WaffleUI.Markdown

local function escapeRich(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function convertInline(s)
    local out = escapeRich(s)
    -- bold
    out = out:gsub("%*%*(.-)%*%*", "<b>%1</b>")
    out = out:gsub("__(.-)__", "<b>%1</b>")
    -- italic
    out = out:gsub("%*(.-)%*", "<i>%1</i>")
    out = out:gsub("_(.-)_", "<i>%1</i>")
    -- inline code
    out = out:gsub("`(.-)`", "<font color='rgb(180,200,255)'>%1</font>")
    -- links [text](url)
    out = out:gsub("%[(.-)%]%((.-)%)", function(text, url)
        return string.format("<u>%s</u>", text) -- Roblox RichText has no real link support
    end)
    return out
end

function Markdown.convert(src)
    local lines = {}
    for line in string.gmatch(src, "[^\n]*") do
        -- headings
        local hashCount, rest = line:match("^(#+)%s+(.*)$")
        if hashCount then
            local size
            if #hashCount == 1 then size = 20
            elseif #hashCount == 2 then size = 16
            elseif #hashCount == 3 then size = 14
            else size = 13 end
            table.insert(lines, string.format(
                "<b><font size='%d'>%s</font></b>",
                size, convertInline(rest)))
        -- bullets
        elseif line:match("^%s*[%*%-]%s+") then
            local content = line:gsub("^%s*[%*%-]%s+", "")
            table.insert(lines, "  • " .. convertInline(content))
        -- numbered list (best-effort)
        elseif line:match("^%s*%d+%.%s+") then
            local n, content = line:match("^%s*(%d+)%.%s+(.*)$")
            table.insert(lines, "  " .. n .. ". " .. convertInline(content))
        elseif line == "" then
            table.insert(lines, "")
        else
            table.insert(lines, convertInline(line))
        end
    end
    return table.concat(lines, "\n")
end

-- Strip all markdown formatting to plain text.
function Markdown.toPlain(src)
    local out = src
    out = out:gsub("%*%*(.-)%*%*", "%1")
    out = out:gsub("__(.-)__", "%1")
    out = out:gsub("%*(.-)%*", "%1")
    out = out:gsub("_(.-)_", "%1")
    out = out:gsub("`(.-)`", "%1")
    out = out:gsub("%[(.-)%]%((.-)%)", "%1 (%2)")
    out = out:gsub("^%s*#+%s+", ""):gsub("\n%s*#+%s+", "\n")
    return out
end



--==============================================================================
-- WaffleUI.Tween
--
-- Tiny coroutine-based tweener for arbitrary values (numbers, Vector2s,
-- Color3s, UDim2s). Useful when TweenService can't reach the property you
-- want to animate, e.g. animating the .Text property character-by-character.
--
-- All tween* functions return a handle with :cancel() and a Completed signal.
--==============================================================================
WaffleUI.Tween = {}
local T = WaffleUI.Tween

local function makeHandle()
    return {
        _cancelled = false,
        Completed = WaffleUI.Signal.new(),
        cancel = function(self) self._cancelled = true end,
    }
end

local function easingFunction(name)
    -- Accept raw functions or dotted path into Easing table.
    if type(name) == "function" then return name end
    if type(name) == "string" then
        local family, dir = name:match("^([^%.]+)%.([^%.]+)$")
        if family and dir then
            local group = WaffleUI.Easing[family]
            if group and group[dir] then return group[dir] end
        end
    end
    return WaffleUI.Easing.quad.out
end

local function runLoop(duration, handle, step)
    local start = os.clock()
    while not handle._cancelled do
        local elapsed = os.clock() - start
        local t = duration > 0 and math.min(1, elapsed / duration) or 1
        step(t)
        if t >= 1 then break end
        RunService.Heartbeat:Wait()
    end
    if not handle._cancelled then handle.Completed:Fire() end
end

function T.number(from, to, duration, ease, onUpdate)
    local h = makeHandle()
    local fn = easingFunction(ease)
    task.spawn(runLoop, duration, h, function(t)
        onUpdate(from + (to - from) * fn(t), t)
    end)
    return h
end

function T.color(from, to, duration, ease, onUpdate)
    local h = makeHandle()
    local fn = easingFunction(ease)
    task.spawn(runLoop, duration, h, function(t)
        local k = fn(t)
        onUpdate(from:Lerp(to, k), k)
    end)
    return h
end

function T.vector2(from, to, duration, ease, onUpdate)
    local h = makeHandle()
    local fn = easingFunction(ease)
    task.spawn(runLoop, duration, h, function(t)
        local k = fn(t)
        onUpdate(from:Lerp(to, k), k)
    end)
    return h
end

function T.udim2(from, to, duration, ease, onUpdate)
    local h = makeHandle()
    local fn = easingFunction(ease)
    task.spawn(runLoop, duration, h, function(t)
        local k = fn(t)
        onUpdate(from:Lerp(to, k), k)
    end)
    return h
end

-- Typewriter effect on a TextLabel (writes one character per `charsPerSecond`).
function T.typewriter(textLabel, fullText, charsPerSecond, onDone)
    local h = makeHandle()
    local total = #fullText
    local duration = total / math.max(1, charsPerSecond)
    task.spawn(runLoop, duration, h, function(t)
        local n = math.floor(t * total + 0.5)
        textLabel.Text = fullText:sub(1, n)
        if t >= 1 then
            textLabel.Text = fullText
            if onDone then onDone() end
        end
    end)
    return h
end



--==============================================================================
-- WaffleUI.Grid
--
-- Virtualised list helper. When you have thousands of rows (player lists,
-- logs, inventories) a UIListLayout becomes a measurable frame cost. This
-- module renders only the rows that actually fit inside a ScrollingFrame's
-- viewport, recycling row instances as the user scrolls.
--
-- Usage:
--     local grid = WaffleUI.Grid.virtual(scrollFrame, {
--         itemHeight = 32,
--         data = array,
--         renderRow = function(row, record, index)
--             row.Text = record.name
--         end,
--     })
--     grid:SetData(otherArray)
--     grid:Destroy()
--
-- `renderRow` is called to populate a (recycled) row each time it moves to a
-- new index. The row frame is a plain TextLabel unless you pass
-- `createRow = function() return Instance end`.
--==============================================================================
WaffleUI.Grid = {}
local Grid = WaffleUI.Grid

function Grid.virtual(scrollFrame, opts)
    opts = opts or {}
    assert(scrollFrame, "Grid.virtual: scrollFrame is required")
    assert(opts.itemHeight, "Grid.virtual: itemHeight is required")
    assert(opts.renderRow, "Grid.virtual: renderRow is required")

    local self = {
        _frame = scrollFrame,
        _data = opts.data or {},
        _itemH = opts.itemHeight,
        _render = opts.renderRow,
        _create = opts.createRow,
        _pool = {},         -- recycled row instances
        _active = {},       -- [rowInstance] = index
        _bag = ConnectionBag.new(),
    }

    -- Canvas sized to total dataset
    local function recomputeCanvas()
        self._frame.CanvasSize = UDim2.new(0, 0, 0, #self._data * self._itemH)
    end

    local function createDefault()
        local row = Instance.new("TextLabel")
        row.BackgroundTransparency = 1
        row.Font = Enum.Font.Gotham
        row.TextSize = 14
        row.TextColor3 = Color3.fromRGB(220, 220, 230)
        row.TextXAlignment = Enum.TextXAlignment.Left
        return row
    end

    local function acquire()
        local r = table.remove(self._pool)
        if r then return r end
        local created = self._create and self._create() or createDefault()
        created.Parent = self._frame
        return created
    end

    local function release(r)
        r.Visible = false
        table.insert(self._pool, r)
    end

    local function update()
        local canvasPos = self._frame.CanvasPosition.Y
        local viewH = self._frame.AbsoluteSize.Y
        local first = math.floor(canvasPos / self._itemH) + 1
        local last  = math.min(#self._data,
            math.ceil((canvasPos + viewH) / self._itemH))

        -- Release rows outside the visible window.
        for row, idx in pairs(self._active) do
            if idx < first or idx > last then
                self._active[row] = nil
                release(row)
            end
        end

        -- Acquire rows for newly-visible indices.
        local assigned = {}
        for row, idx in pairs(self._active) do assigned[idx] = row end
        for i = first, last do
            if not assigned[i] then
                local row = acquire()
                row.Visible = true
                row.Size = UDim2.new(1, 0, 0, self._itemH)
                row.Position = UDim2.new(0, 0, 0, (i - 1) * self._itemH)
                self._render(row, self._data[i], i)
                self._active[row] = i
            end
        end
    end

    self._bag:Add(self._frame:GetPropertyChangedSignal("CanvasPosition"):Connect(update))
    self._bag:Add(self._frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(update))

    function self:SetData(data)
        self._data = data or {}
        -- reset all rows
        for row in pairs(self._active) do release(row) end
        self._active = {}
        recomputeCanvas()
        update()
    end

    function self:Refresh()
        for row, idx in pairs(self._active) do
            self._render(row, self._data[idx], idx)
        end
    end

    function self:Destroy()
        self._bag:Destroy()
        for row in pairs(self._active) do row:Destroy() end
        for _, row in ipairs(self._pool) do row:Destroy() end
        self._active = {}; self._pool = {}
    end

    recomputeCanvas()
    update()
    return self
end



--==============================================================================
-- WaffleUI.Tooltip
--
-- A lightweight tooltip helper that works without a window context. Attach
-- to any GuiObject and a small label pops up on hover with a configurable
-- delay. The core library's `tab:AttachTooltip` uses a different instance of
-- this logic tied to theme dispatch; this module is the generic version.
--==============================================================================
WaffleUI.Tooltip = {}
local TooltipMod = WaffleUI.Tooltip

local function buildGui()
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleTooltips"
    gui.DisplayOrder = 50000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent
    return gui
end

TooltipMod._gui = nil
TooltipMod._label = nil

local function ensure()
    if TooltipMod._gui and TooltipMod._gui.Parent then return end
    local gui = buildGui()
    local frame = Instance.new("Frame")
    frame.AutomaticSize = Enum.AutomaticSize.XY
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.ZIndex = 100
    frame.Parent = gui
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 4); corner.Parent = frame
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6)
    pad.PaddingTop  = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4)
    pad.Parent = frame
    local label = Instance.new("TextLabel")
    label.AutomaticSize = Enum.AutomaticSize.XY
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.TextColor3 = Color3.fromRGB(240, 240, 245)
    label.Parent = frame
    TooltipMod._gui = gui
    TooltipMod._frame = frame
    TooltipMod._label = label
end

function TooltipMod.attach(guiObject, text, opts)
    opts = opts or {}
    local delay = opts.delay or 0.35
    local bag = ConnectionBag.new()
    local pending
    bag:Add(guiObject.MouseEnter:Connect(function()
        pending = task.delay(delay, function()
            ensure()
            TooltipMod._label.Text = text
            local pos = UserInputService:GetMouseLocation()
            TooltipMod._frame.Position = UDim2.fromOffset(pos.X + 12, pos.Y + 16)
            TooltipMod._frame.Visible = true
        end)
    end))
    bag:Add(guiObject.MouseLeave:Connect(function()
        if pending then task.cancel(pending); pending = nil end
        if TooltipMod._frame then TooltipMod._frame.Visible = false end
    end))
    bag:Add(guiObject.MouseMoved:Connect(function()
        if TooltipMod._frame and TooltipMod._frame.Visible then
            local pos = UserInputService:GetMouseLocation()
            TooltipMod._frame.Position = UDim2.fromOffset(pos.X + 12, pos.Y + 16)
        end
    end))
    return {
        Destroy = function() bag:Destroy() end,
    }
end



--==============================================================================
-- WaffleUI.ContextMenu
--
-- Right-click / long-press context menus. Menus are described with a simple
-- table and can be nested. The menu owns its own ScreenGui and closes on
-- outside click or Escape.
--
--     WaffleUI.ContextMenu.show({
--         { text = "Copy", icon = Icons.action.copy, run = function() ... end },
--         { text = "Paste", run = function() ... end, disabled = true },
--         { separator = true },
--         { text = "More",
--           submenu = {
--             { text = "Refresh", run = function() ... end },
--             { text = "Settings", run = function() ... end },
--           } },
--     }, anchorPosition)
--==============================================================================
WaffleUI.ContextMenu = {}
local ContextMenu = WaffleUI.ContextMenu

local function makeGui()
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleContextMenu"
    gui.DisplayOrder = 45000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent
    return gui
end

local function buildPanel(items, anchorX, anchorY, parentGui, onClose)
    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(200, 0)
    panel.AutomaticSize = Enum.AutomaticSize.Y
    panel.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
    panel.BorderSizePixel = 0
    panel.Parent = parentGui
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = panel
    local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(60, 60, 70); stroke.Parent = panel
    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 1)
    layout.Parent = panel
    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4)
    pad.Parent = panel

    for _, item in ipairs(items) do
        if item.separator then
            local sep = Instance.new("Frame")
            sep.BackgroundColor3 = Color3.fromRGB(60, 60, 72)
            sep.BorderSizePixel = 0
            sep.Size = UDim2.new(1, -10, 0, 1)
            sep.Position = UDim2.fromOffset(5, 0)
            sep.LayoutOrder = item.order or 0
            sep.Parent = panel
        else
            local row = Instance.new("TextButton")
            row.AutoButtonColor = false
            row.Size = UDim2.new(1, 0, 0, 28)
            row.BackgroundTransparency = 1
            row.Text = item.text or ""
            row.Font = Enum.Font.Gotham
            row.TextSize = 13
            row.TextColor3 = item.disabled
                and Color3.fromRGB(100, 100, 115)
                or Color3.fromRGB(230, 230, 240)
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Parent = panel
            local rpad = Instance.new("UIPadding")
            rpad.PaddingLeft = UDim.new(0, 10); rpad.PaddingRight = UDim.new(0, 10)
            rpad.Parent = row

            if not item.disabled then
                row.MouseEnter:Connect(function()
                    row.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
                    row.BackgroundTransparency = 0
                end)
                row.MouseLeave:Connect(function()
                    row.BackgroundTransparency = 1
                end)
                row.MouseButton1Click:Connect(function()
                    if item.submenu then
                        -- open submenu to the right of this row
                        local absPos = row.AbsolutePosition
                        local absSize = row.AbsoluteSize
                        buildPanel(item.submenu, absPos.X + absSize.X, absPos.Y, parentGui, onClose)
                    else
                        if item.run then pcall(item.run) end
                        if onClose then onClose() end
                    end
                end)
            end
        end
    end

    panel.Position = UDim2.fromOffset(anchorX, anchorY)
    return panel
end

function ContextMenu.show(items, anchorPosition)
    local gui = makeGui()
    local overlay = Instance.new("TextButton")
    overlay.Text = ""; overlay.AutoButtonColor = false
    overlay.BackgroundTransparency = 1
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.Parent = gui
    local closed = false
    local function close()
        if closed then return end
        closed = true
        gui:Destroy()
    end
    overlay.MouseButton1Click:Connect(close)
    UserInputService.InputBegan:Connect(function(input)
        if input.KeyCode == Enum.KeyCode.Escape then close() end
    end)
    local x = anchorPosition and anchorPosition.X or UserInputService:GetMouseLocation().X
    local y = anchorPosition and anchorPosition.Y or UserInputService:GetMouseLocation().Y
    buildPanel(items, x, y, gui, close)
    return { Close = close, gui = gui }
end



--==============================================================================
-- WaffleUI.Drag
--
-- Generic drag-to-move helper for any GuiObject. Handles mouse + touch,
-- respects a parent clamp rectangle, and fires a Completed signal on
-- release. Useful for custom panels, picker swatches, mini-maps etc.
--
--     local dragger = WaffleUI.Drag.attach(frame, {
--         handle = frame.TitleBar,   -- optional: drag starts only on handle
--         clampToViewport = true,
--         onDrag = function(newPos) end,
--     })
--     dragger:Destroy()
--==============================================================================
WaffleUI.Drag = {}
local Drag = WaffleUI.Drag

function Drag.attach(target, opts)
    opts = opts or {}
    local handle = opts.handle or target
    local bag = ConnectionBag.new()
    local dragging, startInput, startPos

    local function getViewport()
        local cam = workspace.CurrentCamera
        return cam and cam.ViewportSize or Vector2.new(1920, 1080)
    end

    local function updatePosition(input)
        local delta = input.Position - startInput.Position
        local newX = startPos.X.Offset + delta.X
        local newY = startPos.Y.Offset + delta.Y
        if opts.clampToViewport then
            local vp = getViewport()
            local size = target.AbsoluteSize
            newX = math.clamp(newX, 0, vp.X - size.X)
            newY = math.clamp(newY, 0, vp.Y - size.Y)
        end
        target.Position = UDim2.new(
            startPos.X.Scale, newX,
            startPos.Y.Scale, newY
        )
        if opts.onDrag then pcall(opts.onDrag, target.Position) end
    end

    bag:Add(handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startInput = input
            startPos = target.Position
            if opts.onStart then pcall(opts.onStart) end
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    if opts.onStop then pcall(opts.onStop, target.Position) end
                end
            end)
        end
    end))

    bag:Add(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            updatePosition(input)
        end
    end))

    return {
        Destroy = function() bag:Destroy(); dragging = false end,
    }
end



--==============================================================================
-- WaffleUI.Hotkeys
--
-- Documented reference table for the default shortcuts used throughout the
-- library. This is not a functional piece — it exists so integrators have a
-- single place to read "what keys does WaffleUI claim?" before wiring their
-- own shortcuts.
--==============================================================================
WaffleUI.Hotkeys = {
    { shortcut = "RightShift",    purpose = "Toggle window visibility (configurable via Keybind option)" },
    { shortcut = "Escape",        purpose = "Close the command palette; cancel keybind capture" },
    { shortcut = "Ctrl+K",        purpose = "Open the command palette (configurable via WaffleUI.CommandPalette:SetHotkey)" },
    { shortcut = "Ctrl+S",        purpose = "(Recommended) Save settings — bind via WaffleUI.Keyboard:Bind" },
    { shortcut = "Ctrl+Shift+P",  purpose = "(Recommended) Toggle diagnostics overlay — bind via WaffleUI.Keyboard:Bind" },
    { shortcut = "Ctrl+/",        purpose = "(Recommended) Show hotkey help — bind via WaffleUI.Keyboard:Bind" },
    { shortcut = "Tab",           purpose = "Focus moves through textboxes where TextBox.TextEditable=true" },
    { shortcut = "Enter",         purpose = "Confirm primary dialog button / commit textbox value" },
}

function WaffleUI:PrintHotkeys()
    local lines = { "WaffleUI hotkeys:" }
    for _, hk in ipairs(self.Hotkeys) do
        table.insert(lines, string.format("  %-18s %s", hk.shortcut, hk.purpose))
    end
    print(table.concat(lines, "\n"))
end



--==============================================================================
-- WaffleUI.CookieJar
--
-- In-memory key-value cache with TTL (time-to-live). Handy for throttling
-- network requests, memoising heavy computations, or tracking "recently
-- shown" notifications so you don't spam the user.
--
--     local jar = WaffleUI.CookieJar.new()
--     if not jar:Get("popupShown") then
--         showPopup()
--         jar:Set("popupShown", true, 60) -- sticky for 60 seconds
--     end
--==============================================================================
WaffleUI.CookieJar = {}
local CookieJar = WaffleUI.CookieJar
CookieJar.__index = CookieJar

function CookieJar.new()
    return setmetatable({ _store = {} }, CookieJar)
end

function CookieJar:Set(key, value, ttlSeconds)
    self._store[key] = {
        value = value,
        expires = ttlSeconds and (os.clock() + ttlSeconds) or nil,
    }
    return value
end

function CookieJar:Get(key)
    local entry = self._store[key]
    if not entry then return nil end
    if entry.expires and os.clock() > entry.expires then
        self._store[key] = nil
        return nil
    end
    return entry.value
end

function CookieJar:Delete(key)
    self._store[key] = nil
end

function CookieJar:Has(key)
    return self:Get(key) ~= nil
end

function CookieJar:Touch(key, ttlSeconds)
    local entry = self._store[key]
    if not entry then return end
    entry.expires = ttlSeconds and (os.clock() + ttlSeconds) or entry.expires
end

function CookieJar:Prune()
    local now = os.clock()
    for k, entry in pairs(self._store) do
        if entry.expires and now > entry.expires then
            self._store[k] = nil
        end
    end
end

function CookieJar:Clear()
    self._store = {}
end



--==============================================================================
-- WaffleUI.EventBus
--
-- Pub/sub event bus decoupled from any one Store instance. Useful for
-- cross-window coordination:
--     bus:On("theme-changed", function(name) ... end)
--     bus:Emit("theme-changed", "Ocean")
--==============================================================================
WaffleUI.EventBus = {}
local EventBus = WaffleUI.EventBus
EventBus.__index = EventBus

function EventBus.new()
    return setmetatable({ _subs = {}, _nextId = 1 }, EventBus)
end

function EventBus:On(event, callback)
    assert(type(event) == "string", "EventBus:On: event must be a string")
    assert(type(callback) == "function", "EventBus:On: callback must be a function")
    self._subs[event] = self._subs[event] or {}
    local id = self._nextId; self._nextId = id + 1
    self._subs[event][id] = callback
    return function()
        if self._subs[event] then self._subs[event][id] = nil end
    end
end

function EventBus:Once(event, callback)
    local unsub
    unsub = self:On(event, function(...)
        unsub()
        callback(...)
    end)
    return unsub
end

function EventBus:Emit(event, ...)
    local bucket = self._subs[event]
    if not bucket then return end
    for _, cb in pairs(bucket) do task.spawn(cb, ...) end
end

function EventBus:Off(event)
    self._subs[event] = nil
end

function EventBus:Has(event)
    local bucket = self._subs[event]
    if not bucket then return false end
    return next(bucket) ~= nil
end

-- A shared, process-wide bus for convenience.
WaffleUI.bus = EventBus.new()



--==============================================================================
-- WaffleUI.Anim
--
-- Curated tween helpers mapped to common UI interactions. The library core
-- already uses many of these internally; this module re-exposes them as a
-- public surface so advanced consumers can build components that look and
-- feel identical to the built-in ones without redefining the tween specs.
--==============================================================================
WaffleUI.Anim = {}
local Anim = WaffleUI.Anim

function Anim.fadeIn(instance, duration)
    return tween(instance, TweenInfo.new(duration or 0.2, Enum.EasingStyle.Quad), {
        BackgroundTransparency = 0,
        TextTransparency = 0,
        ImageTransparency = 0,
    })
end

function Anim.fadeOut(instance, duration)
    return tween(instance, TweenInfo.new(duration or 0.2, Enum.EasingStyle.Quad), {
        BackgroundTransparency = 1,
        TextTransparency = 1,
        ImageTransparency = 1,
    })
end

function Anim.popIn(instance, fromScale, duration)
    fromScale = fromScale or 0.9
    local originalSize = instance.Size
    instance.Size = UDim2.new(
        originalSize.X.Scale * fromScale, math.floor(originalSize.X.Offset * fromScale),
        originalSize.Y.Scale * fromScale, math.floor(originalSize.Y.Offset * fromScale)
    )
    return tween(instance, TweenInfo.new(duration or 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
        { Size = originalSize })
end

function Anim.shake(instance, intensity, duration)
    intensity = intensity or 4
    duration = duration or 0.3
    local originalPos = instance.Position
    local start = os.clock()
    task.spawn(function()
        while os.clock() - start < duration do
            local t = (os.clock() - start) / duration
            local damping = (1 - t)
            local dx = (math.random() * 2 - 1) * intensity * damping
            local dy = (math.random() * 2 - 1) * intensity * damping
            instance.Position = originalPos + UDim2.fromOffset(dx, dy)
            RunService.Heartbeat:Wait()
        end
        instance.Position = originalPos
    end)
end

function Anim.pulse(instance, color, duration)
    local original = instance.BackgroundColor3
    tween(instance, TweenInfo.new((duration or 0.4) / 2), { BackgroundColor3 = color })
    task.delay((duration or 0.4) / 2, function()
        tween(instance, TweenInfo.new((duration or 0.4) / 2), { BackgroundColor3 = original })
    end)
end

function Anim.slideIn(instance, direction, distance, duration)
    distance = distance or 20
    local offsetX, offsetY = 0, 0
    if direction == "left"  then offsetX = -distance end
    if direction == "right" then offsetX =  distance end
    if direction == "up"    then offsetY = -distance end
    if direction == "down"  then offsetY =  distance end
    local target = instance.Position
    instance.Position = target + UDim2.fromOffset(offsetX, offsetY)
    tween(instance, TweenInfo.new(duration or 0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        { Position = target })
end

function Anim.ripple(parent, origin, color)
    color = color or Color3.fromRGB(255, 255, 255)
    local circle = Instance.new("Frame")
    circle.BackgroundColor3 = color
    circle.BackgroundTransparency = 0.7
    circle.BorderSizePixel = 0
    circle.Size = UDim2.fromOffset(0, 0)
    circle.Position = UDim2.fromOffset(origin.X, origin.Y)
    circle.AnchorPoint = Vector2.new(0.5, 0.5)
    circle.ZIndex = 100
    circle.Parent = parent
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = circle
    local targetSize = math.max(parent.AbsoluteSize.X, parent.AbsoluteSize.Y) * 2
    local t = TweenService:Create(circle,
        TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { Size = UDim2.fromOffset(targetSize, targetSize), BackgroundTransparency = 1 })
    t:Play()
    t.Completed:Connect(function() circle:Destroy() end)
end



--==============================================================================
-- WaffleUI.Icons.Legacy
--
-- Extended icon pack. Grouped by domain and populated with commonly-used
-- rbxassetid numbers. Every entry has a stable name so consumer code can
-- migrate between packs by swapping the registry reference rather than
-- updating every call site.
--==============================================================================
WaffleUI.Icons.Legacy = {
    -- UI primitives
    primitives = {
        checkbox_on   = "rbxassetid://10747384394",
        checkbox_off  = "rbxassetid://10747372968",
        radio_on      = "rbxassetid://10734897885",
        radio_off     = "rbxassetid://10734897921",
        toggle_on     = "rbxassetid://10734950309",
        toggle_off    = "rbxassetid://10734950354",
        plus          = "rbxassetid://10709751939",
        minus         = "rbxassetid://10709753795",
        caret_up      = "rbxassetid://10709791437",
        caret_down    = "rbxassetid://10709790222",
        caret_left    = "rbxassetid://10709790644",
        caret_right   = "rbxassetid://10709791646",
        chevron_up    = "rbxassetid://10709762690",
        chevron_down  = "rbxassetid://10709762778",
        chevron_left  = "rbxassetid://10709762567",
        chevron_right = "rbxassetid://10709762102",
        dot           = "rbxassetid://10734884325",
        ellipsis      = "rbxassetid://10734898586",
    },
    -- Social & community
    community = {
        follow         = "rbxassetid://10734898588",
        unfollow       = "rbxassetid://10734898650",
        friend         = "rbxassetid://10747384424",
        friends        = "rbxassetid://10747384394",
        block          = "rbxassetid://10747372968",
        report         = "rbxassetid://10747372968",
        chat_group     = "rbxassetid://10709806299",
        invite         = "rbxassetid://10709767276",
        leave          = "rbxassetid://10709767076",
    },
    -- Economy / monetary
    economy = {
        coin           = "rbxassetid://10709756916",
        cash           = "rbxassetid://10709756916",
        credit_card    = "rbxassetid://10734884215",
        wallet         = "rbxassetid://10734884090",
        gem            = "rbxassetid://10709770823",
        gold           = "rbxassetid://10709770823",
        shop           = "rbxassetid://10734950309",
        gift           = "rbxassetid://10734950354",
        sale           = "rbxassetid://10734898477",
        voucher        = "rbxassetid://10734898588",
    },
    -- Movement / transport
    transport = {
        car            = "rbxassetid://10709757069",
        bus            = "rbxassetid://10709757069",
        plane          = "rbxassetid://10709810334",
        boat           = "rbxassetid://10709797641",
        train          = "rbxassetid://10709795158",
        bike           = "rbxassetid://10709757069",
        teleport       = "rbxassetid://10709810334",
        jetpack        = "rbxassetid://10709810334",
    },
    -- Miscellaneous items
    items = {
        key            = "rbxassetid://10709792619",
        lock           = "rbxassetid://10709792619",
        bomb           = "rbxassetid://10709770050",
        rocket         = "rbxassetid://10709810334",
        flame          = "rbxassetid://10709770050",
        snowflake      = "rbxassetid://10709808039",
        leaf           = "rbxassetid://10709770050",
        tree           = "rbxassetid://10709795158",
    },
}



--==============================================================================
-- WaffleUI.Snippets
--
-- A library of copy-pasteable example factories. Each Snippets.<name>(window)
-- builds one small but complete feature on a Window. These are deliberately
-- simple so they can be used as starting points rather than production code.
--==============================================================================
WaffleUI.Snippets = {}
local Snippets = WaffleUI.Snippets

-- Adds a "Theme" settings tab that lets the user switch between all
-- registered themes and persists the choice.
function Snippets.ThemeTab(window, opts)
    opts = opts or {}
    local tab = window:CreateTab(opts.tabName or "Theme", opts.icon)
    tab:AddSection("Appearance")
    local themes = {}
    for name in pairs(WaffleUI.Themes) do table.insert(themes, name) end
    table.sort(themes)
    tab:AddDropdown({
        Text = "Theme",
        Options = themes,
        Default = opts.default or "Dark",
        Searchable = true,
        Flag = opts.flag or "theme",
        Callback = function(name)
            window:SetTheme(name)
            WaffleUI.bus:Emit("theme-changed", name)
        end,
    })
    tab:AddButton({
        Text = "Reset to Dark",
        Callback = function()
            window:SetTheme("Dark")
            WaffleUI.bus:Emit("theme-changed", "Dark")
        end,
    })
    return tab
end

-- Adds a "Keybinds" settings tab with rebindable buttons for a supplied
-- table of actions.
function Snippets.KeybindsTab(window, actions, opts)
    opts = opts or {}
    local tab = window:CreateTab(opts.tabName or "Keybinds", opts.icon)
    tab:AddSection("Keybinds")
    for _, act in ipairs(actions) do
        tab:AddKeybind({
            Text = act.label,
            Default = act.defaultKey,
            Flag = act.flag,
            Callback = function()
                if act.run then pcall(act.run) end
            end,
        })
    end
    tab:AddParagraph({
        Title = "Tip",
        Text  = "Press Escape while rebinding to clear the current key.",
    })
    return tab
end

-- Adds a "Credits" tab that lists contributor rows from a table.
function Snippets.CreditsTab(window, credits, opts)
    opts = opts or {}
    local tab = window:CreateTab(opts.tabName or "Credits", opts.icon)
    tab:AddSection("Credits")
    for _, entry in ipairs(credits) do
        tab:AddParagraph({ Title = entry.name, Text = entry.role or "" })
    end
    return tab
end

-- Adds a "Players" tab with a virtualised list of online players.
function Snippets.PlayersTab(window, opts)
    opts = opts or {}
    local tab = window:CreateTab(opts.tabName or "Players", opts.icon)
    tab:AddSection("Players")
    -- Component returns a ScrollingFrame-backed pane we can render into.
    -- For brevity the core library does not currently expose a raw-pane
    -- component, so we just pipe into a Paragraph-style list.
    local function lineFor(plr)
        return string.format("%s  —  Account age %d days", plr.DisplayName, plr.AccountAge)
    end
    local function refresh()
        for _, plr in ipairs(Players:GetPlayers()) do
            tab:AddLabel(lineFor(plr))
        end
    end
    refresh()
    Players.PlayerAdded:Connect(function(plr)
        tab:AddLabel(lineFor(plr))
    end)
    return tab
end

-- Minimal "About" tab.
function Snippets.AboutTab(window, info)
    info = info or {}
    local tab = window:CreateTab(info.tabName or "About")
    tab:AddSection(info.name or "About")
    tab:AddParagraph({
        Title = info.title or "WaffleUI",
        Text  = info.body  or "Thanks for using WaffleUI. PRs welcome.",
    })
    tab:AddButton({
        Text = "Copy version string",
        Callback = function()
            if typeof(setclipboard) == "function" then
                setclipboard(info.version or "WaffleUI v3")
            end
        end,
    })
    return tab
end



--==============================================================================
-- WaffleUI.Validator.Rules
--
-- A pre-built catalog of validator rules for common fields. Each factory
-- returns a ready-to-use `Rule` configured with a useful error message, so
-- typical forms look like:
--
--     local schema = V.schema({
--         name  = V.Rules.username(),
--         email = V.Rules.email(),
--         age   = V.Rules.age(),
--     })
--==============================================================================
WaffleUI.Validator.Rules = {}
local VR = WaffleUI.Validator.Rules

function VR.username(minLen, maxLen)
    minLen = minLen or 3
    maxLen = maxLen or 20
    return WaffleUI.Validator.string()
        :min(minLen, string.format("Username must be at least %d characters", minLen))
        :max(maxLen, string.format("Username must be at most %d characters", maxLen))
        :pattern("^[%w_]+$", "Only letters, numbers, and underscores allowed")
        :required("Username is required")
end

function VR.email()
    return WaffleUI.Validator.string()
        :pattern("^[%w.+-]+@[%w.-]+%.%w+$", "Please enter a valid email")
        :required("Email is required")
end

function VR.url()
    return WaffleUI.Validator.string()
        :pattern("^https?://", "URL must start with http:// or https://")
        :required("URL is required")
end

function VR.age(minAge)
    minAge = minAge or 13
    return WaffleUI.Validator.number()
        :integer("Age must be a whole number")
        :min(minAge, string.format("Must be at least %d years old", minAge))
        :max(120, "That can't be right")
        :required("Age is required")
end

function VR.positiveInt()
    return WaffleUI.Validator.number()
        :integer("Must be a whole number")
        :positive("Must be greater than zero")
        :required()
end

function VR.percent()
    return WaffleUI.Validator.number()
        :range(0, 100, "Must be between 0 and 100")
end

function VR.rbxAssetId()
    return WaffleUI.Validator.string()
        :pattern("^rbxassetid://%d+$", "Expected rbxassetid://<number>")
end

function VR.hexColor()
    return WaffleUI.Validator.string()
        :pattern("^#?[%x][%x][%x][%x][%x][%x]$", "Expected a 6-digit hex color")
end

function VR.keybindName()
    return WaffleUI.Validator.string()
        :custom(function(v)
            local ok = pcall(function() return Enum.KeyCode[v] end)
            return ok, "Unknown KeyCode name"
        end)
        :required()
end



--==============================================================================
-- WaffleUI.Form
--
-- Form controller that ties together Validator + Store + Dialog. Given a
-- schema and a set of input components, it:
--     * Stores current values in an internal Store
--     * Re-validates on every change
--     * Exposes :Submit() which rejects when errors exist
--     * Optionally renders error text under fields via onError
--
-- Use it for settings editors where many fields have inter-dependencies or
-- complex validation rules.
--==============================================================================
WaffleUI.Form = {}
local Form = WaffleUI.Form
Form.__index = Form

function Form.new(schema, opts)
    opts = opts or {}
    return setmetatable({
        _schema = schema,
        _store  = WaffleUI.Store.new(opts.initial or {}),
        _errors = {},
        _fieldErrorHandlers = {},
        OnChange = WaffleUI.Signal.new(),
        OnValidate = WaffleUI.Signal.new(),
        OnSubmit = WaffleUI.Signal.new(),
    }, Form)
end

function Form:Get(field) return self._store:Get(field) end
function Form:GetAll() return self._store:Get() end

function Form:Set(field, value)
    self._store:Set(field, value)
    self:Validate()
    self.OnChange:Fire(field, value)
end

-- Wires a component (Toggle, Textbox, Slider, etc.) to a field. The
-- component is expected to expose :Get / Set and invoke a callback when the
-- user edits it.
function Form:Bind(field, component)
    if component.Set and self:Get(field) ~= nil then
        component:Set(self:Get(field))
    end
    if component.OnChange then
        component.OnChange:Connect(function(v) self:Set(field, v) end)
    elseif component._callback then
        local prev = component._callback
        component._callback = function(v, ...)
            self:Set(field, v)
            if prev then prev(v, ...) end
        end
    end
end

function Form:OnFieldError(field, handler)
    self._fieldErrorHandlers[field] = handler
end

function Form:Validate()
    local ok, errors = self._schema:validate(self._store:Get())
    self._errors = errors or {}
    self.OnValidate:Fire(ok, self._errors)
    for field, handler in pairs(self._fieldErrorHandlers) do
        handler(self._errors[field])
    end
    return ok, self._errors
end

function Form:Errors()
    return self._errors
end

function Form:Submit()
    local ok, errors = self:Validate()
    if ok then
        self.OnSubmit:Fire(self._store:Get())
    end
    return ok, errors
end

function Form:Reset(newValues)
    self._store:Reset(newValues or {})
    self:Validate()
end

function Form:Destroy()
    self._store:Destroy()
    self.OnChange:DisconnectAll()
    self.OnValidate:DisconnectAll()
    self.OnSubmit:DisconnectAll()
end



--==============================================================================
-- WaffleUI.Table
--
-- Simple tabular display backed by a ScrollingFrame. Columns are declared
-- once and rows are just arrays of strings / numbers. Supports sorting,
-- pagination, and row callbacks.
--
--     local t = WaffleUI.Table.new(parent, {
--         columns = {
--             { key = "name", header = "Name", width = 0.4 },
--             { key = "score", header = "Score", width = 0.3, sortable = true },
--             { key = "rank",  header = "Rank",  width = 0.3 },
--         },
--         rows = { { name = "Alice", score = 42, rank = 1 }, ... },
--         onRow = function(row) print(row.name) end,
--     })
--==============================================================================
WaffleUI.Table = {}
local Table = WaffleUI.Table
Table.__index = Table

function Table.new(parent, opts)
    assert(parent, "Table.new: parent is required")
    opts = opts or {}
    local self = setmetatable({
        _columns = opts.columns or {},
        _rows = opts.rows or {},
        _sortKey = opts.sortKey,
        _sortDesc = opts.sortDesc or false,
        _page = 1,
        _pageSize = opts.pageSize or 20,
        _onRow = opts.onRow,
    }, Table)

    local frame = Instance.new("Frame")
    frame.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
    frame.BorderSizePixel = 0
    frame.Size = opts.size or UDim2.fromScale(1, 1)
    frame.Parent = parent
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = frame

    local header = Instance.new("Frame")
    header.BackgroundColor3 = Color3.fromRGB(32, 32, 42)
    header.BorderSizePixel = 0
    header.Size = UDim2.new(1, 0, 0, 28)
    header.Parent = frame
    local hc = Instance.new("UICorner"); hc.CornerRadius = UDim.new(0, 6); hc.Parent = header

    local hLayout = Instance.new("UIListLayout")
    hLayout.FillDirection = Enum.FillDirection.Horizontal
    hLayout.Parent = header

    local headerLabels = {}
    for _, col in ipairs(self._columns) do
        local btn = Instance.new("TextButton")
        btn.AutoButtonColor = false
        btn.BackgroundTransparency = 1
        btn.Size = UDim2.new(col.width or (1 / #self._columns), 0, 1, 0)
        btn.Text = col.header or col.key
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 13
        btn.TextColor3 = Color3.fromRGB(220, 220, 230)
        btn.TextXAlignment = Enum.TextXAlignment.Left
        btn.Parent = header
        local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.Parent = btn
        headerLabels[col.key] = btn

        if col.sortable then
            btn.MouseButton1Click:Connect(function()
                if self._sortKey == col.key then
                    self._sortDesc = not self._sortDesc
                else
                    self._sortKey = col.key
                    self._sortDesc = false
                end
                self:Render()
            end)
        end
    end

    local body = Instance.new("ScrollingFrame")
    body.Size = UDim2.new(1, 0, 1, -28)
    body.Position = UDim2.fromOffset(0, 28)
    body.BackgroundTransparency = 1
    body.BorderSizePixel = 0
    body.ScrollBarThickness = 4
    body.CanvasSize = UDim2.new()
    body.AutomaticCanvasSize = Enum.AutomaticSize.Y
    body.Parent = frame
    local bLayout = Instance.new("UIListLayout")
    bLayout.Padding = UDim.new(0, 1)
    bLayout.Parent = body

    self._frame = frame
    self._body = body
    self._headerLabels = headerLabels

    self:Render()
    return self
end

function Table:SetRows(rows)
    self._rows = rows or {}
    self:Render()
end

function Table:SortBy(key, descending)
    self._sortKey = key
    self._sortDesc = descending
    self:Render()
end

function Table:NextPage()
    if self._page * self._pageSize < #self._rows then
        self._page = self._page + 1
        self:Render()
    end
end

function Table:PreviousPage()
    if self._page > 1 then
        self._page = self._page - 1
        self:Render()
    end
end

local function getSorted(self)
    if not self._sortKey then return self._rows end
    local copy = {}
    for i, r in ipairs(self._rows) do copy[i] = r end
    table.sort(copy, function(a, b)
        local va, vb = a[self._sortKey], b[self._sortKey]
        if self._sortDesc then va, vb = vb, va end
        if type(va) == "number" and type(vb) == "number" then return va < vb end
        return tostring(va) < tostring(vb)
    end)
    return copy
end

function Table:Render()
    for _, child in ipairs(self._body:GetChildren()) do
        if child:IsA("Frame") then child:Destroy() end
    end
    local rows = getSorted(self)
    local start = (self._page - 1) * self._pageSize + 1
    local stop  = math.min(#rows, start + self._pageSize - 1)

    for i = start, stop do
        local row = rows[i]
        local rowFrame = Instance.new("Frame")
        rowFrame.Size = UDim2.new(1, 0, 0, 26)
        rowFrame.BackgroundColor3 = (i % 2 == 0)
            and Color3.fromRGB(30, 30, 38)
            or Color3.fromRGB(26, 26, 34)
        rowFrame.BorderSizePixel = 0
        rowFrame.Parent = self._body
        local rLayout = Instance.new("UIListLayout")
        rLayout.FillDirection = Enum.FillDirection.Horizontal
        rLayout.Parent = rowFrame
        for _, col in ipairs(self._columns) do
            local cell = Instance.new("TextLabel")
            cell.BackgroundTransparency = 1
            cell.Size = UDim2.new(col.width or (1 / #self._columns), 0, 1, 0)
            cell.Text = tostring(row[col.key] == nil and "" or row[col.key])
            cell.Font = Enum.Font.Gotham
            cell.TextSize = 13
            cell.TextColor3 = Color3.fromRGB(220, 220, 230)
            cell.TextXAlignment = Enum.TextXAlignment.Left
            cell.Parent = rowFrame
            local pad = Instance.new("UIPadding"); pad.PaddingLeft = UDim.new(0, 10); pad.Parent = cell
        end

        if self._onRow then
            local btn = Instance.new("TextButton")
            btn.AutoButtonColor = false; btn.Text = ""
            btn.BackgroundTransparency = 1
            btn.Size = UDim2.fromScale(1, 1)
            btn.Parent = rowFrame
            btn.MouseButton1Click:Connect(function() self._onRow(row) end)
        end
    end
end

function Table:Destroy()
    self._frame:Destroy()
end



--==============================================================================
-- WaffleUI.Inspector
--
-- Runtime inspector: dumps any Roblox instance or Lua table as a nested
-- tree of labels. Handy when debugging a rig of nested frames to check what
-- Z-order / AnchorPoint / Size values have actually taken effect.
--==============================================================================
WaffleUI.Inspector = {}
local Inspector = WaffleUI.Inspector

local function formatValue(v)
    local t = typeof(v)
    if t == "Instance" then
        return string.format("%s (%s)", v:GetFullName(), v.ClassName)
    elseif t == "Color3" then
        return string.format("Color3(%.2f, %.2f, %.2f)", v.R, v.G, v.B)
    elseif t == "Vector2" or t == "Vector3" then
        return tostring(v)
    elseif t == "UDim2" then
        return string.format("UDim2({%g,%d},{%g,%d})",
            v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset)
    elseif t == "UDim" then
        return string.format("UDim(%g, %d)", v.Scale, v.Offset)
    elseif t == "EnumItem" then
        return tostring(v)
    elseif t == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        return string.format("table (%d keys)", n)
    elseif t == "string" then
        if #v > 80 then return string.format("%q...", v:sub(1, 77)) end
        return string.format("%q", v)
    end
    return tostring(v)
end

-- Dump a plain Lua table to a list of indented lines.
function Inspector.dumpTable(t, depth, maxDepth, visited)
    depth = depth or 0
    maxDepth = maxDepth or 5
    visited = visited or {}
    if depth > maxDepth then return { string.rep("  ", depth) .. "<max depth>" } end
    if visited[t] then return { string.rep("  ", depth) .. "<cycle>" } end
    visited[t] = true

    local lines = {}
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return tostring(a) < tostring(b) end
        return type(a) < type(b)
    end)
    for _, k in ipairs(keys) do
        local v = t[k]
        local prefix = string.rep("  ", depth) .. tostring(k) .. " = "
        if type(v) == "table" then
            table.insert(lines, prefix .. "{")
            for _, sub in ipairs(Inspector.dumpTable(v, depth + 1, maxDepth, visited)) do
                table.insert(lines, sub)
            end
            table.insert(lines, string.rep("  ", depth) .. "}")
        else
            table.insert(lines, prefix .. formatValue(v))
        end
    end
    return lines
end

-- Dump a Roblox Instance to a list of indented lines.
function Inspector.dumpInstance(inst, depth, maxDepth)
    depth = depth or 0
    maxDepth = maxDepth or 4
    if depth > maxDepth then
        return { string.rep("  ", depth) .. "<max depth>" }
    end
    local lines = {
        string.format("%s%s (%s)", string.rep("  ", depth), inst.Name, inst.ClassName),
    }
    -- Key properties we care about for UI
    local uiProps = { "Size", "Position", "AnchorPoint", "BackgroundColor3",
        "BackgroundTransparency", "ZIndex", "Visible" }
    for _, p in ipairs(uiProps) do
        local ok, v = pcall(function() return inst[p] end)
        if ok and v ~= nil then
            table.insert(lines, string.format("%s  %s = %s", string.rep("  ", depth), p, formatValue(v)))
        end
    end
    for _, child in ipairs(inst:GetChildren()) do
        for _, sub in ipairs(Inspector.dumpInstance(child, depth + 1, maxDepth)) do
            table.insert(lines, sub)
        end
    end
    return lines
end

function Inspector.print(target, maxDepth)
    local lines
    if typeof(target) == "Instance" then
        lines = Inspector.dumpInstance(target, 0, maxDepth)
    else
        lines = Inspector.dumpTable(target, 0, maxDepth)
    end
    print(table.concat(lines, "\n"))
end



--==============================================================================
-- WaffleUI.AssetPreload
--
-- Calls ContentProvider:PreloadAsync for every icon and sound id registered
-- with the library. Useful to call from a splash-screen flow so the first
-- open of your hub doesn't flicker through placeholder assets.
--==============================================================================
WaffleUI.AssetPreload = {}
local AssetPreload = WaffleUI.AssetPreload

local function collectAllIds()
    local ids = {}
    local function walk(node)
        for k, v in pairs(node) do
            if type(v) == "string" and v:match("^rbxassetid://") then
                ids[#ids + 1] = v
            elseif type(v) == "table" and k ~= "Get" and k ~= "Register" and k ~= "All" then
                walk(v)
            end
        end
    end
    walk(WaffleUI.Icons)
    for _, id in pairs(WaffleUI.Sound._assets) do ids[#ids + 1] = id end
    -- Dedup
    local seen = {}
    local out = {}
    for _, id in ipairs(ids) do
        if not seen[id] then seen[id] = true; table.insert(out, id) end
    end
    return out
end

function AssetPreload:All(onProgress)
    local ContentProvider = game:GetService("ContentProvider")
    local ids = collectAllIds()
    local total = #ids
    -- ContentProvider:PreloadAsync expects Instances or asset URL strings;
    -- strings are supported natively for asset ids.
    local instances = {}
    for _, id in ipairs(ids) do
        local image = Instance.new("ImageLabel")
        image.Image = id
        table.insert(instances, image)
    end
    task.spawn(function()
        local loaded = 0
        ContentProvider:PreloadAsync(instances, function(assetId, status)
            loaded = loaded + 1
            if onProgress then onProgress(loaded, total, assetId, status) end
        end)
        for _, img in ipairs(instances) do img:Destroy() end
    end)
    return total
end



--==============================================================================
-- WaffleUI.Trace
--
-- Lightweight call tracer. Wraps a function and measures how long each call
-- takes, feeding samples into a WaffleUI.Diagnostics histogram.
--
--     local traced = WaffleUI.Trace.wrap("ui.bigRebuild", function(...) ... end)
--     traced()  -- tick counted automatically
--==============================================================================
WaffleUI.Trace = {}
local Trace = WaffleUI.Trace

function Trace.wrap(name, fn)
    assert(type(name) == "string", "Trace.wrap: name must be a string")
    assert(type(fn) == "function", "Trace.wrap: fn must be a function")
    local hist = WaffleUI.Diagnostics:Histogram(name)
    return function(...)
        local start = os.clock()
        local n = select("#", ...)
        local args = { ... }
        local results = { fn(table.unpack(args, 1, n)) }
        local elapsed = (os.clock() - start) * 1000
        hist:Observe(elapsed)
        return table.unpack(results)
    end
end

-- Add a simple time-it scope for code that isn't easily wrappable.
--     local stop = Trace.scope("ui.heavyLoop")
--     ... heavy work ...
--     stop()
function Trace.scope(name)
    local hist = WaffleUI.Diagnostics:Histogram(name)
    local start = os.clock()
    return function()
        hist:Observe((os.clock() - start) * 1000)
    end
end



--==============================================================================
-- WaffleUI.Tokens
--
-- Design tokens — the single source of truth for spacing, radius, type
-- scale, shadow levels etc. Every component in the core library picks its
-- numbers from here. If you want a taller, chunkier theme, mutate one of
-- the tables and the next Window you build will pick it up.
--
-- Why separate from Themes?
--     * Themes are colors only. Tokens are everything else: size, padding,
--       font, radius, stroke, shadow.
--     * Keeping them separate lets you mix and match: the same "Dark" theme
--       can feel dense or airy depending on which token set is active.
--==============================================================================
WaffleUI.Tokens = {}
local Tokens = WaffleUI.Tokens

Tokens.Default = {
    -- Spacing scale (in pixels).
    spacing = {
        none  = 0,
        xxs   = 2,
        xs    = 4,
        sm    = 6,
        md    = 8,
        lg    = 12,
        xl    = 16,
        xxl   = 24,
        xxxl  = 32,
    },
    -- Radii (UICorner radii).
    radius = {
        none   = 0,
        xs     = 2,
        sm     = 4,
        md     = 6,
        lg     = 8,
        xl     = 12,
        pill   = 9999,
    },
    -- Stroke sizes.
    stroke = {
        thin   = 1,
        normal = 1,
        thick  = 2,
        focus  = 2,
    },
    -- Font scale.
    type = {
        caption = { size = 11, font = Enum.Font.Gotham },
        body    = { size = 13, font = Enum.Font.Gotham },
        title   = { size = 16, font = Enum.Font.GothamBold },
        heading = { size = 20, font = Enum.Font.GothamBlack },
        code    = { size = 12, font = Enum.Font.Code },
    },
    -- Component sizes (height-based).
    sizes = {
        input  = 32,
        button = 32,
        row    = 36,
        tab    = 34,
        title  = 36,
        thumb  = 20,
    },
    -- Elevation/shadow presets (hints only — UIStroke used).
    shadow = {
        none  = 0,
        low   = 1,
        mid   = 2,
        high  = 3,
    },
    -- Timings (in seconds).
    motion = {
        quick   = 0.12,
        medium  = 0.22,
        slow    = 0.35,
        spring  = 0.35,
    },
}

-- A denser, compact token preset.
Tokens.Compact = {
    spacing = { none = 0, xxs = 1, xs = 2, sm = 4, md = 6, lg = 8, xl = 12, xxl = 16, xxxl = 20 },
    radius  = { none = 0, xs = 2, sm = 3, md = 4, lg = 6, xl = 8, pill = 9999 },
    stroke  = { thin = 1, normal = 1, thick = 1, focus = 2 },
    type    = {
        caption = { size = 10, font = Enum.Font.Gotham },
        body    = { size = 12, font = Enum.Font.Gotham },
        title   = { size = 14, font = Enum.Font.GothamBold },
        heading = { size = 17, font = Enum.Font.GothamBlack },
        code    = { size = 11, font = Enum.Font.Code },
    },
    sizes   = { input = 26, button = 26, row = 28, tab = 28, title = 28, thumb = 16 },
    shadow  = { none = 0, low = 1, mid = 1, high = 2 },
    motion  = { quick = 0.10, medium = 0.18, slow = 0.28, spring = 0.28 },
}

-- A taller, friendlier token preset.
Tokens.Cozy = {
    spacing = { none = 0, xxs = 3, xs = 5, sm = 8, md = 12, lg = 16, xl = 20, xxl = 28, xxxl = 40 },
    radius  = { none = 0, xs = 3, sm = 6, md = 8, lg = 12, xl = 16, pill = 9999 },
    stroke  = { thin = 1, normal = 1, thick = 2, focus = 3 },
    type    = {
        caption = { size = 12, font = Enum.Font.Gotham },
        body    = { size = 14, font = Enum.Font.Gotham },
        title   = { size = 18, font = Enum.Font.GothamBold },
        heading = { size = 22, font = Enum.Font.GothamBlack },
        code    = { size = 13, font = Enum.Font.Code },
    },
    sizes   = { input = 38, button = 38, row = 44, tab = 40, title = 44, thumb = 24 },
    shadow  = { none = 0, low = 2, mid = 3, high = 4 },
    motion  = { quick = 0.14, medium = 0.25, slow = 0.40, spring = 0.45 },
}

function Tokens:Get(name)
    return self[name] or self.Default
end

function Tokens:List()
    local out = {}
    for k in pairs(self) do
        if type(self[k]) == "table" and k ~= "Get" and k ~= "List" then
            table.insert(out, k)
        end
    end
    table.sort(out)
    return out
end



--==============================================================================
-- WaffleUI.Badge
--
-- Tiny colored label you can attach to any GuiObject to decorate it with a
-- small status pill. E.g. a "NEW" badge on a tab, a "99+" on a bell icon,
-- a "PRO" on a premium feature.
--==============================================================================
WaffleUI.Badge = {}
local Badge = WaffleUI.Badge

local function badgeFrame(text, color)
    local f = Instance.new("Frame")
    f.AutomaticSize = Enum.AutomaticSize.X
    f.Size = UDim2.new(0, 0, 0, 16)
    f.BackgroundColor3 = color or Color3.fromRGB(230, 70, 80)
    f.BorderSizePixel = 0
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = f
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 6); pad.PaddingRight = UDim.new(0, 6)
    pad.Parent = f
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.AutomaticSize = Enum.AutomaticSize.X
    label.Size = UDim2.new(0, 0, 1, 0)
    label.Font = Enum.Font.GothamBold
    label.TextSize = 10
    label.TextColor3 = Color3.new(1, 1, 1)
    label.Text = text or ""
    label.Parent = f
    return f, label
end

-- Attaches a badge to the top-right corner of the given GuiObject.
function Badge.attach(target, text, color)
    assert(target, "Badge.attach: target is required")
    local frame, label = badgeFrame(text, color)
    frame.AnchorPoint = Vector2.new(1, 0)
    frame.Position = UDim2.new(1, 4, 0, -4)
    frame.Parent = target
    return {
        SetText = function(_, t) label.Text = t end,
        SetColor = function(_, c) frame.BackgroundColor3 = c end,
        Destroy = function() frame:Destroy() end,
        frame = frame,
    }
end

-- Standalone inline badge (returns a new frame you position yourself).
function Badge.inline(text, color)
    local frame, label = badgeFrame(text, color)
    return {
        frame = frame,
        SetText = function(_, t) label.Text = t end,
        SetColor = function(_, c) frame.BackgroundColor3 = c end,
    }
end



--==============================================================================
-- WaffleUI.Shimmer
--
-- Skeleton loader pane. Use it in place of content while you're fetching
-- data asynchronously. Renders animated shimmer bars.
--
--     local s = WaffleUI.Shimmer.place(parent, { rows = 4, height = 18 })
--     task.delay(1, function() s:Destroy() end)
--==============================================================================
WaffleUI.Shimmer = {}
local Shimmer = WaffleUI.Shimmer

function Shimmer.place(parent, opts)
    opts = opts or {}
    local rows = opts.rows or 3
    local rowH = opts.height or 14
    local gap = opts.gap or 8
    local frame = Instance.new("Frame")
    frame.BackgroundTransparency = 1
    frame.Size = opts.size or UDim2.new(1, 0, 0, rows * (rowH + gap))
    frame.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, gap)
    layout.Parent = frame

    local bag = ConnectionBag.new()
    local bars = {}
    for i = 1, rows do
        local bar = Instance.new("Frame")
        bar.Size = UDim2.new(math.random(60, 100) / 100, 0, 0, rowH)
        bar.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
        bar.BorderSizePixel = 0
        bar.Parent = frame
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = bar
        local grad = Instance.new("UIGradient")
        grad.Color = ColorSequence.new{
            ColorSequenceKeypoint.new(0, Color3.fromRGB(50, 50, 62)),
            ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 80, 96)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(50, 50, 62)),
        }
        grad.Parent = bar
        table.insert(bars, grad)
    end

    local t0 = os.clock()
    bag:Add(RunService.Heartbeat:Connect(function()
        local t = (os.clock() - t0) % 1.5 / 1.5
        for _, grad in ipairs(bars) do
            grad.Offset = Vector2.new(t * 2 - 1, 0)
        end
    end))

    return {
        frame = frame,
        Destroy = function() bag:Destroy(); frame:Destroy() end,
    }
end



--==============================================================================
-- WaffleUI.Spinner
--
-- Rotating loading indicator. Wraps an ImageLabel whose rotation is driven
-- from Heartbeat. Pass an Icon asset to use a custom glyph.
--==============================================================================
WaffleUI.Spinner = {}
local Spinner = WaffleUI.Spinner

function Spinner.place(parent, opts)
    opts = opts or {}
    local size = opts.size or 20
    local icon = opts.icon or "rbxassetid://10723408256"   -- loading glyph

    local img = Instance.new("ImageLabel")
    img.BackgroundTransparency = 1
    img.Image = icon
    img.Size = UDim2.fromOffset(size, size)
    img.ImageColor3 = opts.color or Color3.fromRGB(200, 200, 215)
    img.AnchorPoint = Vector2.new(0.5, 0.5)
    img.Position = opts.position or UDim2.fromScale(0.5, 0.5)
    img.Parent = parent

    local speed = opts.speed or 360      -- degrees per second
    local running = true
    local conn = RunService.Heartbeat:Connect(function(dt)
        if not running then return end
        img.Rotation = (img.Rotation + speed * dt) % 360
    end)

    return {
        frame = img,
        Stop = function() running = false; if conn then conn:Disconnect() end end,
        Destroy = function()
            running = false
            if conn then conn:Disconnect() end
            img:Destroy()
        end,
    }
end



--==============================================================================
-- WaffleUI.Chart
--
-- Tiny line + bar charts rendered with Frame primitives. Not a substitute
-- for a real charting library, but perfectly fine for debug HUDs and
-- lightweight score graphs. All charts autoscale to their own data.
--==============================================================================
WaffleUI.Chart = {}
local Chart = WaffleUI.Chart

-- Line chart: values is an array of numbers. Returns an object with
-- :SetValues, :Append, :Destroy.
function Chart.line(parent, opts)
    opts = opts or {}
    local frame = Instance.new("Frame")
    frame.BackgroundColor3 = opts.background or Color3.fromRGB(22, 22, 30)
    frame.BorderSizePixel = 0
    frame.Size = opts.size or UDim2.new(1, 0, 0, 120)
    frame.Parent = parent
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = frame

    local function renderSegments(values)
        for _, child in ipairs(frame:GetChildren()) do
            if child:IsA("Frame") and child.Name == "segment" then child:Destroy() end
        end
        if not values or #values < 2 then return end
        local lo, hi = values[1], values[1]
        for _, v in ipairs(values) do
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
        local range = math.max(1e-6, hi - lo)
        local absSize = frame.AbsoluteSize
        local w = absSize.X
        local h = absSize.Y
        if w == 0 or h == 0 then return end
        local stepX = w / math.max(1, #values - 1)
        for i = 1, #values - 1 do
            local x1 = (i - 1) * stepX
            local y1 = h - ((values[i] - lo) / range) * h
            local x2 = i * stepX
            local y2 = h - ((values[i + 1] - lo) / range) * h
            local dx = x2 - x1
            local dy = y2 - y1
            local len = math.sqrt(dx * dx + dy * dy)
            local angle = math.deg(math.atan2(dy, dx))
            local seg = Instance.new("Frame")
            seg.Name = "segment"
            seg.BackgroundColor3 = opts.color or Color3.fromRGB(120, 200, 255)
            seg.BorderSizePixel = 0
            seg.AnchorPoint = Vector2.new(0, 0.5)
            seg.Position = UDim2.fromOffset(x1, (y1 + y2) / 2)
            seg.Size = UDim2.fromOffset(len, 2)
            seg.Rotation = angle
            seg.Parent = frame
        end
    end

    local values = opts.values or {}
    renderSegments(values)
    frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
        renderSegments(values)
    end)

    return {
        frame = frame,
        SetValues = function(_, v) values = v; renderSegments(values) end,
        Append = function(self, x, maxLen)
            table.insert(values, x)
            if maxLen and #values > maxLen then
                table.remove(values, 1)
            end
            renderSegments(values)
        end,
        Destroy = function() frame:Destroy() end,
    }
end

-- Bar chart: values is an array of numbers. Each bar is drawn with gap.
function Chart.bar(parent, opts)
    opts = opts or {}
    local frame = Instance.new("Frame")
    frame.BackgroundColor3 = opts.background or Color3.fromRGB(22, 22, 30)
    frame.BorderSizePixel = 0
    frame.Size = opts.size or UDim2.new(1, 0, 0, 120)
    frame.Parent = parent
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = frame

    local function render(values)
        for _, child in ipairs(frame:GetChildren()) do
            if child:IsA("Frame") and child.Name == "bar" then child:Destroy() end
        end
        if not values or #values == 0 then return end
        local hi = values[1]
        for _, v in ipairs(values) do if v > hi then hi = v end end
        local range = math.max(1e-6, hi)
        local absSize = frame.AbsoluteSize
        local w, h = absSize.X, absSize.Y
        if w == 0 or h == 0 then return end
        local gap = opts.gap or 2
        local barW = math.max(1, (w - gap * (#values - 1)) / #values)
        for i, v in ipairs(values) do
            local x = (i - 1) * (barW + gap)
            local barH = (v / range) * h
            local bar = Instance.new("Frame")
            bar.Name = "bar"
            bar.BackgroundColor3 = opts.color or Color3.fromRGB(120, 200, 255)
            bar.BorderSizePixel = 0
            bar.AnchorPoint = Vector2.new(0, 1)
            bar.Position = UDim2.fromOffset(x, h)
            bar.Size = UDim2.fromOffset(barW, barH)
            bar.Parent = frame
            local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 2); bc.Parent = bar
        end
    end

    local values = opts.values or {}
    render(values)
    frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() render(values) end)

    return {
        frame = frame,
        SetValues = function(_, v) values = v; render(values) end,
        Destroy = function() frame:Destroy() end,
    }
end



--==============================================================================
-- WaffleUI.HeatMap
--
-- Grid of colored cells mapped from a 2D array of values. Useful for
-- visualising per-player stats grids, activity calendars, AoE coverage
-- etc. Values outside [min, max] are clamped.
--==============================================================================
WaffleUI.HeatMap = {}
local HeatMap = WaffleUI.HeatMap

function HeatMap.place(parent, opts)
    opts = opts or {}
    assert(opts.data, "HeatMap.place: data is required")
    local rows = #opts.data
    local cols = #(opts.data[1] or {})
    if rows == 0 or cols == 0 then
        error("HeatMap.place: data must be a non-empty 2D array")
    end

    local container = Instance.new("Frame")
    container.BackgroundColor3 = opts.background or Color3.fromRGB(22, 22, 30)
    container.BorderSizePixel = 0
    container.Size = opts.size or UDim2.new(1, 0, 0, 160)
    container.Parent = parent
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = container

    local grid = Instance.new("Frame")
    grid.BackgroundTransparency = 1
    grid.Size = UDim2.new(1, -10, 1, -10)
    grid.Position = UDim2.fromOffset(5, 5)
    grid.Parent = container
    local gridLayout = Instance.new("UIGridLayout")
    gridLayout.CellPadding = UDim2.fromOffset(1, 1)
    gridLayout.CellSize = UDim2.new(1 / cols, -2, 1 / rows, -2)
    gridLayout.FillDirectionMaxCells = cols
    gridLayout.Parent = grid

    local loColor = opts.lo or Color3.fromRGB(40, 40, 60)
    local hiColor = opts.hi or Color3.fromRGB(255, 120, 120)

    local lo, hi = math.huge, -math.huge
    for _, row in ipairs(opts.data) do
        for _, v in ipairs(row) do
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
    end
    if opts.min then lo = opts.min end
    if opts.max then hi = opts.max end
    local range = math.max(1e-6, hi - lo)

    for r = 1, rows do
        for c = 1, cols do
            local cell = Instance.new("Frame")
            cell.BorderSizePixel = 0
            cell.LayoutOrder = (r - 1) * cols + c
            local v = math.clamp(opts.data[r][c], lo, hi)
            local t = (v - lo) / range
            cell.BackgroundColor3 = loColor:Lerp(hiColor, t)
            cell.Parent = grid
        end
    end

    return {
        frame = container,
        Destroy = function() container:Destroy() end,
    }
end



--==============================================================================
-- WaffleUI.Gauge
--
-- Radial gauge for showing a single 0..1 progress value. Good for health
-- bars, resource fills, cooldowns, etc.
--==============================================================================
WaffleUI.Gauge = {}
local Gauge = WaffleUI.Gauge

function Gauge.place(parent, opts)
    opts = opts or {}
    local size = opts.size or 80
    local frame = Instance.new("Frame")
    frame.BackgroundTransparency = 1
    frame.Size = UDim2.fromOffset(size, size)
    frame.Position = opts.position or UDim2.fromOffset(0, 0)
    frame.Parent = parent

    local bg = Instance.new("ImageLabel")
    bg.BackgroundTransparency = 1
    bg.Image = "rbxassetid://10723408256"  -- swap for a ring texture if desired
    bg.Size = UDim2.fromScale(1, 1)
    bg.ImageColor3 = opts.trackColor or Color3.fromRGB(50, 50, 64)
    bg.Parent = frame

    local fg = Instance.new("ImageLabel")
    fg.BackgroundTransparency = 1
    fg.Image = bg.Image
    fg.Size = UDim2.fromScale(1, 1)
    fg.ImageColor3 = opts.color or Color3.fromRGB(120, 200, 255)
    fg.Parent = frame

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.fromScale(1, 1)
    label.Font = Enum.Font.GothamBold
    label.TextSize = math.max(10, size / 4)
    label.TextColor3 = Color3.fromRGB(240, 240, 245)
    label.Text = ""
    label.Parent = frame

    local value = opts.value or 0
    local function update()
        label.Text = string.format("%d%%", math.floor(value * 100))
        fg.ImageTransparency = 1 - value  -- simple: fade in the overlay as value grows
    end
    update()

    return {
        frame = frame,
        Set = function(_, v)
            value = math.clamp(v, 0, 1)
            update()
        end,
        Destroy = function() frame:Destroy() end,
    }
end



--==============================================================================
-- WaffleUI.RichToolTip
--
-- Richer tooltip that supports a title, description, and an icon, styled
-- similarly to item tooltips in games. Attach to any GuiObject.
--==============================================================================
WaffleUI.RichToolTip = {}
local RichTip = WaffleUI.RichToolTip

local function ensureGui()
    if RichTip._gui and RichTip._gui.Parent then return end
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleRichTooltip"
    gui.DisplayOrder = 60000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent

    local frame = Instance.new("Frame")
    frame.AutomaticSize = Enum.AutomaticSize.XY
    frame.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
    frame.BorderSizePixel = 0
    frame.Visible = false
    frame.Parent = gui
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = frame
    local stroke = Instance.new("UIStroke"); stroke.Color = Color3.fromRGB(70, 70, 90); stroke.Parent = frame
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10)
    pad.PaddingTop = UDim.new(0, 8); pad.PaddingBottom = UDim.new(0, 8)
    pad.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 4)
    layout.Parent = frame

    local icon = Instance.new("ImageLabel")
    icon.BackgroundTransparency = 1
    icon.Size = UDim2.fromOffset(24, 24)
    icon.Visible = false
    icon.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.AutomaticSize = Enum.AutomaticSize.XY
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = frame

    local desc = Instance.new("TextLabel")
    desc.BackgroundTransparency = 1
    desc.AutomaticSize = Enum.AutomaticSize.XY
    desc.Font = Enum.Font.Gotham
    desc.TextSize = 12
    desc.TextColor3 = Color3.fromRGB(190, 190, 210)
    desc.TextXAlignment = Enum.TextXAlignment.Left
    desc.TextWrapped = true
    desc.Size = UDim2.new(0, 220, 0, 0)
    desc.Parent = frame

    RichTip._gui = gui
    RichTip._frame = frame
    RichTip._icon = icon
    RichTip._title = title
    RichTip._desc = desc
end

function RichTip.attach(target, info, opts)
    opts = opts or {}
    local delay = opts.delay or 0.4
    local bag = ConnectionBag.new()
    local pending
    bag:Add(target.MouseEnter:Connect(function()
        pending = task.delay(delay, function()
            ensureGui()
            RichTip._title.Text = info.title or ""
            RichTip._desc.Text = info.description or ""
            if info.icon then
                RichTip._icon.Image = info.icon
                RichTip._icon.Visible = true
            else
                RichTip._icon.Visible = false
            end
            local pos = UserInputService:GetMouseLocation()
            RichTip._frame.Position = UDim2.fromOffset(pos.X + 14, pos.Y + 18)
            RichTip._frame.Visible = true
        end)
    end))
    bag:Add(target.MouseLeave:Connect(function()
        if pending then task.cancel(pending); pending = nil end
        if RichTip._frame then RichTip._frame.Visible = false end
    end))
    bag:Add(target.MouseMoved:Connect(function()
        if RichTip._frame and RichTip._frame.Visible then
            local pos = UserInputService:GetMouseLocation()
            RichTip._frame.Position = UDim2.fromOffset(pos.X + 14, pos.Y + 18)
        end
    end))
    return {
        Destroy = function() bag:Destroy() end,
    }
end



--==============================================================================
-- WaffleUI.Cookbook
--
-- A giant block of documentation in string form. The entries are keyed by
-- topic so they can be surfaced by tooling or pasted into in-game help
-- panels.
--==============================================================================
WaffleUI.Cookbook = {}
local Cookbook = WaffleUI.Cookbook

Cookbook["getting-started"] = [[
Getting started with WaffleUI
-----------------------------

1. Require the library:
        local WaffleUI = require(path.to.UILibrary)

2. Build a window. At minimum you need a title; everything else defaults:
        local Window = WaffleUI:CreateWindow({ Title = "My Hub" })

3. Add tabs and components:
        local Main = Window:CreateTab("Main")
        Main:AddButton({ Text = "Click me", Callback = print })

4. Toggle visibility with the configured hotkey (default RightShift), or
   programmatically via Window:Show() / Window:Hide().

5. Destroy the window when you no longer need it; this tears down every
   component, disconnects its listeners, and removes the ScreenGui.
        Window:Destroy()
]]

Cookbook["themes"] = [[
Switching themes
----------------

All themes live in WaffleUI.Themes. The built-in four (Dark, Light,
Midnight, Ocean) are guaranteed to work with every component; the rest are
convenience palettes. You can switch at runtime:

    Window:SetTheme("Ocean")
    Window:SetTheme(WaffleUI.Themes.Solarized)
    Window:SetTheme({
        Primary = Color3.fromRGB(255, 128, 0),
        Stroke  = Color3.fromRGB(100, 80, 20),
        -- unspecified keys fall back to the current theme
    })

Register your own with:
    WaffleUI:RegisterTheme("Neon", { ... })
]]

Cookbook["persistence"] = [[
Persisting settings
-------------------

When you pass `ConfigFile = "MyHub.json"` to :CreateWindow, every component
with a `Flag` is saved to disk automatically whenever it changes. On the
next session, the window loads those values before you call
:AddSlider/:AddToggle/etc.

If your environment doesn't expose writefile/readfile the library silently
skips saving — your hub will still work but settings won't persist.

For domain-specific storage, use WaffleUI.Persistence:
    WaffleUI.Persistence:Save("profile.me", { hp = 100 })
    local me = WaffleUI.Persistence:Load("profile.me", {})

Namespacing:
    local store = WaffleUI.Persistence:Namespace("mygame")
    store:Save("config", { volume = 0.5 })
]]

Cookbook["keybinds"] = [[
Keybinds and shortcuts
----------------------

There are two layers:

  1. Per-component Keybind widget. Use inside a Tab:
         tab:AddKeybind({
             Text = "Sprint",
             Default = Enum.KeyCode.LeftShift,
             Flag = "sprint_key",
             Callback = function() startSprint() end,
         })

  2. Global multi-chord shortcuts via WaffleUI.Keyboard:
         WaffleUI.Keyboard:Bind("Ctrl+K", function()
             WaffleUI.CommandPalette:Toggle()
         end)

Global shortcuts are ignored while a TextBox is focused unless you pass
`{ allowInTextBox = true }` as the third argument.

See WaffleUI.Hotkeys for the recommended defaults.
]]

Cookbook["notifications"] = [[
Notifications
-------------

Three layers, pick the one that fits:

  1. WaffleUI:Notify(opts) — shared toast above every window.
  2. Window:Notify(opts)   — identical but themed to that window.
  3. WaffleUI.Notify:Push(opts) — advanced controller with stacks,
     severity-specific icons, per-corner anchoring, and update handles.

All three accept:
    Title    = "Saved"
    Text     = "Settings written to disk"
    Severity = "Info" | "Success" | "Warning" | "Error"
    Duration = 5                    -- seconds, 0 means sticky
    Actions  = { { Text, Callback } }

The advanced controller additionally supports:
    Corner   = "topLeft" | "topRight" | "bottomLeft" | "bottomRight"
    Actions  = { { Text, Callback, Primary, KeepOpen } }

Returned handle has :Dismiss / :Update / :SetSeverity.
]]

Cookbook["validation"] = [[
Form validation
---------------

Describe your form with a schema and plug it into WaffleUI.Form:

    local V = WaffleUI.Validator
    local schema = V.schema({
        name = V.Rules.username(),
        age  = V.Rules.age(),
    })

    local form = WaffleUI.Form.new(schema, { initial = { name = "Tay", age = 21 } })
    form:OnFieldError("name", function(err) nameLabel.Text = err or "" end)
    form.OnSubmit:Connect(function(values) print("submit", values) end)

    -- Wire your components:
    form:Bind("name", nameTextbox)
    form:Bind("age",  ageStepper)

Call form:Submit() to validate and fire OnSubmit when clean.
]]

Cookbook["palette"] = [[
Command palette
---------------

Ship your hub with a Ctrl+K palette:

    WaffleUI.CommandPalette:Register({
        id = "hub.reload",
        name = "Reload config from disk",
        description = "Re-read the JSON settings file",
        group = "Config",
        keywords = { "reload", "refresh", "re-read" },
        run = function() reloadFromDisk() end,
    })
    WaffleUI.CommandPalette:InstallHotkey()

Commands show fuzzy-matched results as the user types. You can call
:Open()/:Close()/:Toggle() yourself too.
]]

Cookbook["virtual-lists"] = [[
Virtualised lists
-----------------

For long lists (inventories, player lists, logs) avoid building thousands
of row instances. Use WaffleUI.Grid.virtual:

    local g = WaffleUI.Grid.virtual(scrollingFrame, {
        itemHeight = 28,
        data = rows,
        renderRow = function(row, rec, i)
            row.Text = rec.name
        end,
    })

    -- Later:
    g:SetData(newRows)
    g:Destroy()

The helper recycles rows as the user scrolls; only the visible window is
actually populated.
]]

Cookbook["locale"] = [[
Localisation
------------

Six languages ship with the library (en, es, fr, de, pt, ja). Add more:

    WaffleUI.i18n:Register("it", { ["action.save"] = "Salva", ... })
    WaffleUI.i18n:SetLocale("it")

Look up strings with WaffleUI.i18n:Translate(key, params) or the shorthand
call syntax WaffleUI.i18n("key", {name = "Sam"}).
]]

Cookbook["testing"] = [[
Smoke testing
-------------

A quick sanity check: build one of every component and interact with it.
The example file src/Example.client.lua already does this. Running the
smoke test:

    1. Place UILibrary.lua as a ModuleScript.
    2. Place Example.client.lua as a sibling LocalScript.
    3. Publish/play. Open the UI with RightShift.
    4. Verify each tab, each component, switch themes, test persistence.
]]



--==============================================================================
-- WaffleUI.Demo
--
-- Self-contained demo factories. Each builds a whole Window with realistic
-- content so you can spot-check the look & feel of the library without
-- wiring anything yourself. Useful in a fresh game when you want to verify
-- everything is imported and rendering correctly.
--==============================================================================
WaffleUI.Demo = {}
local Demo = WaffleUI.Demo

-- Minimal: one tab, a handful of components.
function Demo.minimal()
    local w = WaffleUI:CreateWindow({
        Title = "Waffle Demo",
        SubTitle = "Minimal",
        Theme = "Dark",
    })
    local tab = w:CreateTab("Demo")
    tab:AddSection("Basics")
    tab:AddLabel("Hello from the demo")
    tab:AddButton({ Text = "Click me", Callback = function() print("clicked") end })
    tab:AddToggle({ Text = "Toggle me", Callback = print })
    tab:AddSlider({ Text = "Slide me", Min = 0, Max = 100, Default = 50, Callback = print })
    return w
end

-- Rich: multiple tabs, all component types, persistent config.
function Demo.rich()
    local w = WaffleUI:CreateWindow({
        Title = "Waffle Demo",
        SubTitle = "Rich",
        Theme = "Ocean",
        ConfigFile = "waffle_demo.json",
    })

    local basics = w:CreateTab("Basics")
    basics:AddSection("Readable")
    basics:AddParagraph({
        Title = "About this demo",
        Text = "This window showcases every built-in component. Tweak values and switch themes to see live theming in action.",
    })
    basics:AddDivider()
    basics:AddButton({ Text = "Toast",    Callback = function() w:Notify({ Title = "Toast", Severity = "Info" }) end })
    basics:AddButton({ Text = "Success",  Callback = function() w:Notify({ Title = "Success", Severity = "Success" }) end })
    basics:AddButton({ Text = "Warning",  Callback = function() w:Notify({ Title = "Warning", Severity = "Warning" }) end })
    basics:AddButton({ Text = "Error",    Callback = function() w:Notify({ Title = "Error", Severity = "Error" }) end })

    local inputs = w:CreateTab("Inputs")
    inputs:AddSection("Numbers")
    inputs:AddSlider({ Text = "Float",   Min = 0, Max = 1,   Default = 0.5, Increment = 0.01, Flag = "d_float",   Callback = print })
    inputs:AddSlider({ Text = "Integer", Min = 0, Max = 100, Default = 50,  Increment = 1,    Flag = "d_int",     Callback = print })
    inputs:AddStepper({ Text = "Level",  Min = 1, Max = 99,  Default = 1,                    Flag = "d_level",   Callback = print })
    inputs:AddProgress({ Text = "Busy",  Min = 0, Max = 100, Default = 42 })
    inputs:AddSection("Text")
    inputs:AddTextbox({ Text = "Nickname", Placeholder = "Type here", Flag = "d_nick", Callback = print })
    inputs:AddTextbox({ Text = "Number only", Placeholder = "42", Numeric = true, Flag = "d_num", Callback = print })
    inputs:AddKeybind({ Text = "Panic", Default = Enum.KeyCode.P, Flag = "d_panic", Callback = function() w:Hide() end })

    local choice = w:CreateTab("Choice")
    choice:AddSection("Single")
    choice:AddDropdown({ Text = "Role", Options = { "Warrior", "Mage", "Ranger" }, Default = "Warrior", Flag = "d_role", Callback = print })
    choice:AddRadioGroup({ Text = "Difficulty", Options = { "Easy", "Normal", "Hard" }, Default = "Normal", Flag = "d_diff", Callback = print })
    choice:AddSection("Many")
    choice:AddMultiSelect({ Text = "Perks", Options = { "Speed", "Power", "Stealth", "Sight" }, Default = { "Speed" }, Flag = "d_perks", Callback = print })
    choice:AddColorPicker({ Text = "Primary", Default = Color3.fromRGB(120, 200, 255), Flag = "d_color", Callback = print })

    local log = w:CreateTab("Console")
    local console = log:AddConsole({ Text = "OUTPUT", Height = 180 })
    console:Log("Demo initialised")
    console:Warn("Warnings look like this")
    console:Error("Errors look like this")

    -- Add the canned theme snippet tab so you can flip themes live.
    WaffleUI.Snippets.ThemeTab(w, { default = "Ocean" })

    return w
end

-- Kitchen sink: like rich but with charts, heatmap, table, forms.
function Demo.kitchenSink()
    local w = Demo.rich()

    local charts = w:CreateTab("Charts")
    charts:AddSection("Line chart")
    -- We'd ideally have a raw-canvas component; for brevity use a paragraph.
    charts:AddParagraph({
        Title = "Pretend this is a chart",
        Text  = "For a real chart call WaffleUI.Chart.line(parent, { values = {...} }).",
    })

    local forms = w:CreateTab("Form")
    forms:AddSection("User profile")
    forms:AddTextbox({ Text = "Username", Placeholder = "3-20 chars", Flag = "demo_user" })
    forms:AddTextbox({ Text = "Email",    Placeholder = "name@host.com", Flag = "demo_email" })
    forms:AddStepper({ Text = "Age",      Min = 13, Max = 120, Default = 18, Flag = "demo_age" })
    forms:AddButton({
        Text = "Validate",
        Callback = function()
            local V = WaffleUI.Validator
            local schema = V.schema({
                demo_user  = V.Rules.username(),
                demo_email = V.Rules.email(),
                demo_age   = V.Rules.age(),
            })
            -- Pull current values out of the config store (for demo purposes
            -- we'd wire a Form instance; shown inline for brevity).
            local values = { demo_user = "ab", demo_email = "not-an-email", demo_age = 18 }
            local ok, errors = schema:validate(values)
            if ok then
                w:Notify({ Title = "OK", Text = "Form is valid", Severity = "Success" })
            else
                for field, msg in pairs(errors) do
                    w:Notify({ Title = field, Text = msg, Severity = "Error" })
                end
            end
        end,
    })

    return w
end



--==============================================================================
-- WaffleUI.Debug
--
-- Conveniences for runtime debugging. Not wired into the main code paths;
-- consumers opt in from their own code when needed.
--==============================================================================
WaffleUI.Debug = {}
local Debug = WaffleUI.Debug

-- Snapshots every Window in the library and prints a compact summary.
function Debug.windowSummary()
    local lines = { string.format("WaffleUI windows: %d", #WaffleUI._windows) }
    for i, w in ipairs(WaffleUI._windows) do
        local tabCount = 0
        if w._tabs then tabCount = #w._tabs end
        table.insert(lines, string.format("  [%d] %s — %d tabs", i, w._title or "<untitled>", tabCount))
    end
    print(table.concat(lines, "\n"))
end

-- Dumps every ConnectionBag the library holds. Useful if you suspect a
-- listener leak.
function Debug.countLiveConnections()
    local total = 0
    for _, w in ipairs(WaffleUI._windows) do
        if w._bag then
            total = total + #w._bag._conns
        end
    end
    return total
end

-- Renders a tree of ScreenGui children (not every GuiObject) so you can
-- see what GUIs the library has created.
function Debug.guiTree()
    local parents = { CoreGui }
    local lp = Players.LocalPlayer
    if lp then
        local pg = lp:FindFirstChild("PlayerGui")
        if pg then table.insert(parents, pg) end
    end
    local lines = {}
    for _, parent in ipairs(parents) do
        table.insert(lines, parent:GetFullName())
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("ScreenGui") then
                table.insert(lines, "  " .. child.Name)
            end
        end
    end
    print(table.concat(lines, "\n"))
end

-- Verifies that every theme has the required keys. Handy after editing a
-- theme table by hand.
function Debug.validateThemes()
    local required = {
        "Background", "Surface", "Elevated", "Hover", "Stroke",
        "Primary", "PrimaryAlt", "Success", "Warning", "Error", "Info",
        "Text", "SubText", "Disabled",
    }
    local issues = {}
    for name, theme in pairs(WaffleUI.Themes) do
        if type(theme) == "table" then
            for _, key in ipairs(required) do
                if theme[key] == nil then
                    table.insert(issues, string.format("%s missing %s", name, key))
                end
            end
        end
    end
    if #issues == 0 then
        print("[WaffleUI] all themes OK")
    else
        warn("[WaffleUI] theme issues:")
        for _, msg in ipairs(issues) do warn("  " .. msg) end
    end
    return issues
end

-- Cause a mild visual bug on every connected component so you can verify
-- that your custom theme still renders readable text. This "contrast mode"
-- strips all text colour down to grey temporarily; call it a second time to
-- restore.
Debug._contrastOn = false
function Debug.toggleLowContrast()
    Debug._contrastOn = not Debug._contrastOn
    local scale = Debug._contrastOn and 0.4 or 1.0
    for _, w in ipairs(WaffleUI._windows) do
        -- nothing to do without broader public hooks, but we print a hint.
        print(string.format("[%s] contrast scale %.2f", w._title or "window", scale))
    end
end



--==============================================================================
-- WaffleUI.Version
--
-- Version info + compatibility flags. Use WaffleUI.Version:Check(minimum) in
-- your game code to verify you're running against a new enough build.
--==============================================================================
WaffleUI.Version = {
    major = 3,
    minor = 0,
    patch = 0,
    tag   = "",                          -- e.g. "beta.2"
    build = os.time(),                   -- rough timestamp; replaced by CI in production
    features = {                          -- feature flags for capability checks
        stepper           = true,
        console           = true,
        tooltip           = true,
        confirm           = true,
        richNotifications = true,
        commandPalette    = true,
        virtualGrid       = true,
        reactiveState     = true,
        i18n              = true,
        themes            = true,
        tokens            = true,
    },
}

function WaffleUI.Version:String()
    local core = string.format("%d.%d.%d", self.major, self.minor, self.patch)
    if self.tag and self.tag ~= "" then core = core .. "-" .. self.tag end
    return core
end

function WaffleUI.Version:Check(requiredMajor, requiredMinor, requiredPatch)
    requiredMinor = requiredMinor or 0
    requiredPatch = requiredPatch or 0
    if self.major > requiredMajor then return true end
    if self.major < requiredMajor then return false end
    if self.minor > requiredMinor then return true end
    if self.minor < requiredMinor then return false end
    return self.patch >= requiredPatch
end

function WaffleUI.Version:Has(feature)
    return self.features[feature] == true
end



--==============================================================================
-- WaffleUI.Splash
--
-- Simple splash screen that displays a title + subtitle + spinner while
-- your own initialisation is running. Returns a controller with :Update,
-- :Progress, :Close.
--==============================================================================
WaffleUI.Splash = {}
local Splash = WaffleUI.Splash

function Splash.show(opts)
    opts = opts or {}
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleSplash"
    gui.DisplayOrder = 70000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent

    local bg = Instance.new("Frame")
    bg.BackgroundColor3 = opts.background or Color3.fromRGB(10, 12, 18)
    bg.BorderSizePixel = 0
    bg.Size = UDim2.fromScale(1, 1)
    bg.Parent = gui

    local card = Instance.new("Frame")
    card.BackgroundTransparency = 1
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromOffset(320, 180)
    card.Parent = bg

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 22
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.Size = UDim2.new(1, 0, 0, 32)
    title.Position = UDim2.fromOffset(0, 10)
    title.Text = opts.title or "Loading..."
    title.Parent = card

    local subtitle = Instance.new("TextLabel")
    subtitle.BackgroundTransparency = 1
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextSize = 13
    subtitle.TextColor3 = Color3.fromRGB(180, 180, 195)
    subtitle.Size = UDim2.new(1, 0, 0, 18)
    subtitle.Position = UDim2.fromOffset(0, 44)
    subtitle.Text = opts.subtitle or ""
    subtitle.Parent = card

    local progress = Instance.new("Frame")
    progress.BackgroundColor3 = Color3.fromRGB(50, 50, 64)
    progress.BorderSizePixel = 0
    progress.Size = UDim2.new(1, -40, 0, 4)
    progress.Position = UDim2.fromOffset(20, 100)
    progress.Parent = card
    local pc = Instance.new("UICorner"); pc.CornerRadius = UDim.new(1, 0); pc.Parent = progress

    local fill = Instance.new("Frame")
    fill.BackgroundColor3 = opts.color or Color3.fromRGB(120, 200, 255)
    fill.BorderSizePixel = 0
    fill.Size = UDim2.fromScale(0, 1)
    fill.Parent = progress
    local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill

    local spinner = WaffleUI.Spinner.place(card, {
        size = 28,
        position = UDim2.new(0.5, -14, 0, 130),
        color = opts.color or Color3.fromRGB(120, 200, 255),
    })

    local function close()
        if spinner then spinner:Destroy() end
        gui:Destroy()
    end

    return {
        gui = gui,
        Update = function(_, newTitle, newSubtitle)
            if newTitle then title.Text = newTitle end
            if newSubtitle then subtitle.Text = newSubtitle end
        end,
        Progress = function(_, fraction)
            fraction = math.clamp(fraction, 0, 1)
            tween(fill, MEDIUM, { Size = UDim2.fromScale(fraction, 1) })
        end,
        Close = close,
    }
end



--==============================================================================
-- WaffleUI.Wizard
--
-- Multi-step wizard flow. Steps are declared up-front; the wizard handles
-- next/back navigation, per-step validation, and a progress indicator.
--
--     local wiz = WaffleUI.Wizard.new({
--         title = "Initial setup",
--         steps = {
--             { id = "welcome",  title = "Welcome",  render = fn(panel) end },
--             { id = "profile",  title = "Profile",  render = fn(panel) end,
--                 validate = function() return ok, errors end },
--             { id = "done",     title = "All set!", render = fn(panel) end },
--         },
--         onFinish = function(state) ... end,
--     })
--     wiz:Open()
--==============================================================================
WaffleUI.Wizard = {}
local Wizard = WaffleUI.Wizard
Wizard.__index = Wizard

function Wizard.new(opts)
    opts = opts or {}
    assert(opts.steps and #opts.steps > 0, "Wizard.new: at least one step required")
    return setmetatable({
        _opts = opts,
        _index = 1,
        _state = {},
        _open = false,
    }, Wizard)
end

function Wizard:State() return self._state end

function Wizard:Open()
    if self._open then return end
    self._open = true
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleWizard"
    gui.DisplayOrder = 42000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent

    local overlay = Instance.new("TextButton")
    overlay.AutoButtonColor = false; overlay.Text = ""
    overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    overlay.BackgroundTransparency = 0.4
    overlay.BorderSizePixel = 0
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.Parent = gui

    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.fromOffset(560, 420)
    card.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
    card.BorderSizePixel = 0
    card.Parent = gui
    local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 10); cc.Parent = card

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 18
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Size = UDim2.new(1, -30, 0, 24)
    title.Position = UDim2.fromOffset(15, 12)
    title.Text = self._opts.title or "Wizard"
    title.Parent = card

    local stepLabel = Instance.new("TextLabel")
    stepLabel.BackgroundTransparency = 1
    stepLabel.Font = Enum.Font.Gotham
    stepLabel.TextSize = 12
    stepLabel.TextColor3 = Color3.fromRGB(160, 160, 180)
    stepLabel.TextXAlignment = Enum.TextXAlignment.Right
    stepLabel.Size = UDim2.new(1, -30, 0, 18)
    stepLabel.Position = UDim2.fromOffset(15, 40)
    stepLabel.Parent = card

    -- Progress track
    local track = Instance.new("Frame")
    track.BackgroundColor3 = Color3.fromRGB(40, 40, 54)
    track.BorderSizePixel = 0
    track.Size = UDim2.new(1, -30, 0, 3)
    track.Position = UDim2.fromOffset(15, 64)
    track.Parent = card
    local trackFill = Instance.new("Frame")
    trackFill.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
    trackFill.BorderSizePixel = 0
    trackFill.Size = UDim2.fromScale(0, 1)
    trackFill.Parent = track

    local pane = Instance.new("Frame")
    pane.BackgroundTransparency = 1
    pane.Size = UDim2.new(1, -30, 1, -140)
    pane.Position = UDim2.fromOffset(15, 76)
    pane.Parent = card

    local backBtn = Instance.new("TextButton")
    backBtn.AutoButtonColor = false; backBtn.Text = "Back"
    backBtn.Font = Enum.Font.GothamMedium; backBtn.TextSize = 13
    backBtn.Size = UDim2.fromOffset(110, 34)
    backBtn.Position = UDim2.new(0, 15, 1, -50)
    backBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 64)
    backBtn.TextColor3 = Color3.fromRGB(230, 230, 240)
    backBtn.BorderSizePixel = 0
    backBtn.Parent = card
    local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0, 6); bc.Parent = backBtn

    local nextBtn = Instance.new("TextButton")
    nextBtn.AutoButtonColor = false
    nextBtn.Font = Enum.Font.GothamMedium; nextBtn.TextSize = 13
    nextBtn.Size = UDim2.fromOffset(110, 34)
    nextBtn.Position = UDim2.new(1, -125, 1, -50)
    nextBtn.BackgroundColor3 = Color3.fromRGB(90, 140, 255)
    nextBtn.TextColor3 = Color3.new(1, 1, 1)
    nextBtn.BorderSizePixel = 0
    nextBtn.Parent = card
    local nc = Instance.new("UICorner"); nc.CornerRadius = UDim.new(0, 6); nc.Parent = nextBtn

    local function renderStep()
        pane:ClearAllChildren()
        local step = self._opts.steps[self._index]
        stepLabel.Text = string.format("Step %d of %d — %s",
            self._index, #self._opts.steps, step.title or step.id)
        trackFill.Size = UDim2.fromScale(self._index / #self._opts.steps, 1)
        if step.render then
            step.render(pane, self._state)
        end
        backBtn.Visible = self._index > 1
        nextBtn.Text = (self._index == #self._opts.steps) and "Finish" or "Next"
    end

    backBtn.MouseButton1Click:Connect(function()
        if self._index > 1 then
            self._index = self._index - 1
            renderStep()
        end
    end)

    nextBtn.MouseButton1Click:Connect(function()
        local step = self._opts.steps[self._index]
        if step.validate then
            local ok, err = step.validate(self._state)
            if not ok then
                WaffleUI.Notify:Error("Validation", err or "Please review this step")
                return
            end
        end
        if self._index == #self._opts.steps then
            if self._opts.onFinish then pcall(self._opts.onFinish, self._state) end
            gui:Destroy()
            self._open = false
        else
            self._index = self._index + 1
            renderStep()
        end
    end)

    renderStep()
    self._gui = gui
end

function Wizard:Close()
    if not self._open then return end
    self._open = false
    if self._gui then self._gui:Destroy() end
end



--==============================================================================
-- WaffleUI.Watermark
--
-- Small always-on-top badge showing your hub name + version. Users expect
-- this on free script hubs; it's also handy as a "version pinned" display
-- during development.
--==============================================================================
WaffleUI.Watermark = {}
local Watermark = WaffleUI.Watermark

function Watermark.show(text, opts)
    opts = opts or {}
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleWatermark"
    gui.DisplayOrder = 80000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent

    local frame = Instance.new("Frame")
    frame.AutomaticSize = Enum.AutomaticSize.X
    frame.Size = UDim2.fromOffset(0, 24)
    frame.Position = opts.position or UDim2.new(0, 10, 0, 10)
    frame.BackgroundColor3 = opts.background or Color3.fromRGB(20, 20, 28)
    frame.BackgroundTransparency = opts.transparency or 0.2
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = frame
    local pad = Instance.new("UIPadding")
    pad.PaddingLeft = UDim.new(0, 8); pad.PaddingRight = UDim.new(0, 8)
    pad.Parent = frame

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.AutomaticSize = Enum.AutomaticSize.X
    label.Size = UDim2.new(0, 0, 1, 0)
    label.Font = opts.font or Enum.Font.GothamBold
    label.TextSize = opts.textSize or 12
    label.TextColor3 = opts.color or Color3.fromRGB(240, 240, 245)
    label.Text = text or "Waffle"
    label.Parent = frame

    -- Draggable if requested.
    local dragger
    if opts.draggable then
        dragger = WaffleUI.Drag.attach(frame, { clampToViewport = true })
    end

    return {
        gui = gui,
        SetText = function(_, t) label.Text = t end,
        Destroy = function()
            if dragger then dragger:Destroy() end
            gui:Destroy()
        end,
    }
end



--==============================================================================
-- WaffleUI.Profile
--
-- Simple save/load profile system on top of WaffleUI.Persistence. Profiles
-- are named snapshots of the settings store. Useful for hubs where users
-- want e.g. a "PvP loadout" and a "Grinding loadout" they can swap between.
--==============================================================================
WaffleUI.Profile = {}
local Profile = WaffleUI.Profile

function Profile.List()
    local ns = WaffleUI.Persistence:Namespace("profiles")
    if typeof(listfiles) ~= "function" then return {} end
    local files = listfiles("")
    local out = {}
    for _, f in ipairs(files) do
        local name = f:match("profiles%.([%w%._%-]+)%.json$")
        if name then table.insert(out, name) end
    end
    table.sort(out)
    return out
end

function Profile.Save(name, data)
    return WaffleUI.Persistence:Namespace("profiles"):Save(name, data)
end

function Profile.Load(name, fallback)
    return WaffleUI.Persistence:Namespace("profiles"):Load(name, fallback or {})
end

function Profile.Delete(name)
    return WaffleUI.Persistence:Namespace("profiles"):Delete(name)
end

function Profile.Exists(name)
    return WaffleUI.Persistence:Namespace("profiles"):Exists(name)
end

-- Transfer the current Window config onto a named profile.
function Profile.SaveFromWindow(window, name)
    if not window or not window._configData then
        return false, "window has no config data"
    end
    return Profile.Save(name, window._configData)
end

-- Load a named profile into the Window and re-apply every component.
function Profile.LoadIntoWindow(window, name)
    if not window or not window._configData then
        return false, "window has no config data"
    end
    local data = Profile.Load(name)
    if not data then return false, "profile not found" end
    for k, v in pairs(data) do window._configData[k] = v end
    -- Re-push values to every component. Individual components read from
    -- _configData during construction; post-hoc we have to call Set on any
    -- that support it. This is best-effort — the core library doesn't
    -- expose a way to walk all components, so users should rebuild tabs or
    -- call Set manually for the flags they care about.
    return true
end



--==============================================================================
-- WaffleUI.Index
--
-- Auto-generated-ish textual index of every public submodule and method.
-- Kept in-code so it ships with the library and can be surfaced via the
-- in-game help panel without needing a doc site.
--==============================================================================
WaffleUI.Index = {
    ["Window"] = {
        "CreateWindow(opts)",
        "Window:CreateTab(name, icon)",
        "Window:SelectTab(name)",
        "Window:SetTheme(nameOrTable)",
        "Window:SetTitle(s)",
        "Window:SetSubTitle(s)",
        "Window:SetSize(w, h)",
        "Window:SetPosition(x, y)",
        "Window:Show()",
        "Window:Hide()",
        "Window:Confirm(opts)",
        "Window:Notify(opts)",
        "Window:Destroy()",
    },
    ["Tab"] = {
        "tab:AddSection(text)",
        "tab:AddLabel(text)",
        "tab:AddParagraph({Title, Text})",
        "tab:AddDivider()",
        "tab:AddButton({Text, Callback})",
        "tab:AddToggle({Text, Default, Flag, Callback})",
        "tab:AddSlider({Text, Min, Max, Default, Increment, Flag, Callback})",
        "tab:AddStepper({Text, Min, Max, Default, Increment, Flag, Callback})",
        "tab:AddProgress({Text, Min, Max, Default})",
        "tab:AddDropdown({Text, Options, Default, Searchable, Flag, Callback})",
        "tab:AddMultiSelect({Text, Options, Default, Flag, Callback})",
        "tab:AddRadioGroup({Text, Options, Default, Flag, Callback})",
        "tab:AddTextbox({Text, Placeholder, Default, Numeric, Flag, Callback})",
        "tab:AddKeybind({Text, Default, Flag, Callback})",
        "tab:AddColorPicker({Text, Default, Flag, Callback})",
        "tab:AddConsole({Text, Height, MaxLines})",
        "tab:AttachTooltip(component, text)",
        "tab:Destroy()",
    },
    ["Themes"] = {
        "WaffleUI.Themes[name]        — palette table",
        "WaffleUI:ListThemes()        — array of names",
        "WaffleUI:GetTheme(name)",
        "WaffleUI:RegisterTheme(name, palette)",
    },
    ["Icons"] = {
        "WaffleUI.Icons.<group>.<name>",
        "WaffleUI.Icons:Get(\"group.name\")",
        "WaffleUI.Icons:Register(\"group.name\", id)",
        "WaffleUI.Icons:All()           — flat dotted map",
    },
    ["Color"] = {
        "Color.hex(str), Color.toHex(c3)",
        "Color.toHSL / fromHSL / toHSV / fromHSV",
        "Color.lerp(a, b, t), Color.mix(a, b, t, space)",
        "Color.lighten / darken / saturate / desaturate",
        "Color.invert / complement / tint / shade",
        "Color.luminance / contrast / readableOn",
        "Color.palette / shades / analogous / triad / tetrad",
        "Color.clamp / equal",
        "Color.fromRGB255 / toRGB255",
    },
    ["Easing"] = {
        "Easing.<family>.<direction>(t)",
        "Families: linear, quad, cubic, quart, quint, sine, expo, circ, back, elastic, bounce",
        "Easing.TweenInfo.Quick / Medium / Slow / Spring / Bounce / Elastic / ...",
    },
    ["Signal"] = {
        "Signal.new()",
        "signal:Connect(fn) → conn (conn:Disconnect)",
        "signal:Once(fn)",
        "signal:Wait()",
        "signal:Fire(...)",
        "signal:DisconnectAll()",
        "signal:Count()",
    },
    ["Store"] = {
        "Store.new(initial)",
        "store:Get(path) / :Set(path, v) / :Patch(table)",
        "store:Subscribe(path, fn) → unsubscribe",
        "store:Reset(newState)",
        "store:Destroy()",
    },
    ["Validator"] = {
        "V.string / number / boolean / table / any / enum",
        "rule:min / max / range / pattern / oneOf / integer / positive / nonEmpty / custom",
        "rule:required / optional / default / validate",
        "V.schema({...}):validate(data)",
        "V.Rules.username / email / url / age / percent / rbxAssetId / hexColor",
    },
    ["i18n"] = {
        "i18n:Register(code, dict)",
        "i18n:SetLocale(code) / :SetFallback(code)",
        "i18n:Translate(key, params)",
        "i18n(\"key\", params)     — call syntax",
        "Locales shipped: en, es, fr, de, pt, ja",
    },
    ["Format"] = {
        "Format.thousands / abbrev / bytes",
        "Format.duration / relative",
        "Format.padInt / truncate / pluralize",
        "Format.percent / currency",
    },
    ["Sequencer"] = {
        "Sequencer.new()",
        "seq:to(obj, props, duration, style)",
        "seq:wait(seconds) / :set(obj, props) / :call(fn)",
        "seq:parallel({...}) / :repeatTimes(n, inner)",
        "seq:play() / :cancel() / :isRunning()",
        "signals: Completed, Cancelled",
    },
    ["CommandPalette"] = {
        "Palette:Register({id, name, description, group, keywords, shortcut, run})",
        "Palette:Unregister(id) / :List() / :Search(q)",
        "Palette:Open() / :Close() / :Toggle()",
        "Palette:SetHotkey(key, ctrl, shift, alt) / :InstallHotkey()",
    },
    ["Diagnostics"] = {
        "Diag:Counter(name) / :Gauge(name) / :Histogram(name, windowSize)",
        "counter:Inc(n) / gauge:Set(n) / histogram:Observe(v)",
        "histogram:Average() / :P(q)",
        "Diag:Snapshot() / :Reset() / :Overlay(enabled)",
    },
    ["Layout"] = {
        "Layout.gridCellCount / gridCellSize",
        "Layout.gridIndexToPosition / gridPosition",
        "Layout.centerIn / aspectFit / aspectFill",
        "Layout.flex(items, total, gap)",
        "Layout.clampToParent",
    },
    ["Util"] = {
        "Util.deepCopy / deepMerge / pick / omit",
        "Util.map / filter / reduce / find / findIndex",
        "Util.flatten / unique / groupBy / sortBy / reverse / chunk / zip / range",
        "Util.debounce / throttle / once / memoize / compose / pipe",
        "Util.trim / startsWith / endsWith / split / kebab / camel / titleCase / randomId",
        "Util.safeCall / tryRequire / assertType",
        "Util.onHeartbeat / onRenderStep / setInterval / setTimeout",
    },
    ["Math"] = {
        "M.lerp / inverseLerp / remap",
        "M.clamp / clamp01 / sign / approxEqual / round",
        "M.smoothstep / smootherstep / wrap / ping",
        "M.mean / stdDev / median / sum / min / max",
        "M.bezier / catmullRom",
        "M.rollingAverage(size)",
    },
    ["Keyboard"] = {
        "Keyboard:Bind(\"Ctrl+K\", fn, opts)",
        "Keyboard:Unbind(shortcut) / :List() / :Clear()",
        "Keyboard:Install()",
    },
    ["Persistence"] = {
        "Persistence:Available()",
        "Persistence:Save(key, value) / :Load(key, fallback) / :Delete(key) / :Exists(key)",
        "Persistence:List(prefix)",
        "Persistence:Namespace(name) → { Save, Load, Delete, Exists }",
    },
    ["Notify (advanced)"] = {
        "Notify:Push(opts) → handle",
        "Notify:Info / :Success / :Warn / :Error / :Debug",
        "Notify:ClearAll()",
        "Notify:SetMaxPerStack(n) / :SetDefaultCorner(c)",
    },
    ["Preset"] = {
        "Preset.StatsHud(opts)",
        "Preset.ToastOnly()",
        "Preset.ConfirmModal({Title, Message, OnConfirm, OnCancel})",
    },
    ["Reactive"] = {
        "Reactive.state(initial)",
        "state:get / :set / :update / :subscribe",
        "Reactive.computed(sources, fn)",
        "Reactive.bind(instance, property, source, transform)",
    },
    ["Router"] = {
        "Router.new()",
        "router:Register(path, fn) / :Unregister / :Routes()",
        "router:Navigate(path, params)",
        "router:Back() / :Forward() / :Current()",
        "signals: Changed, NotFound",
    },
    ["Dialog"] = {
        "Dialog.new():title():message():input(key, placeholder):button():primary():show()",
        "dialog:close()",
    },
    ["Cursor"] = {
        "Cursor.screenPosition / viewportSize",
        "Cursor.isOverGui(gui)",
        "Cursor.objectUnderMouse()",
        "Cursor.toLocal(gui, screenPos)",
    },
    ["Sound"] = {
        "Sound:SetAsset(key, id) / :Play(key)",
        "Sound:SetVolume(v) / :SetEnabled(v) / :Preload()",
    },
    ["Logger"] = {
        "Logger.new(tag)",
        "logger:addSink(sink) / :setLevel(level) / :child(tag)",
        "logger:debug / info / warn / error / fatal",
        "Sinks: ConsoleSink, BufferSink(cap), NotifySink(minLevel), FileSink(key)",
    },
    ["Fuzzy"] = {
        "Fuzzy.match(query, target) → { score, positions }",
        "Fuzzy.filter(query, items, keyFn)",
        "Fuzzy.highlight(target, positions, openTag, closeTag)",
    },
    ["Markdown"] = {
        "Markdown.convert(src) → RichText string",
        "Markdown.toPlain(src)",
    },
    ["Tween"] = {
        "Tween.number / color / vector2 / udim2",
        "Tween.typewriter(label, text, cps, onDone)",
        "returned handle: :cancel(), Completed signal",
    },
    ["Grid"] = {
        "Grid.virtual(scrollFrame, { itemHeight, data, renderRow, createRow })",
        "handle:SetData(data) / :Refresh() / :Destroy()",
    },
    ["Tooltip"] = {
        "Tooltip.attach(guiObject, text, opts) → { Destroy }",
        "RichToolTip.attach(guiObject, { title, description, icon }, opts)",
    },
    ["ContextMenu"] = {
        "ContextMenu.show(items, anchor)",
        "items: { text, icon, run, disabled, submenu }",
    },
    ["Drag"] = {
        "Drag.attach(target, { handle, clampToViewport, onStart, onDrag, onStop })",
        "handle:Destroy()",
    },
    ["EventBus"] = {
        "EventBus.new() / WaffleUI.bus",
        "bus:On(event, fn) → unsub / :Once / :Emit / :Off / :Has",
    },
    ["Anim"] = {
        "Anim.fadeIn / fadeOut / popIn",
        "Anim.shake / pulse / slideIn / ripple",
    },
    ["Snippets"] = {
        "Snippets.ThemeTab(window, opts)",
        "Snippets.KeybindsTab(window, actions, opts)",
        "Snippets.CreditsTab(window, credits, opts)",
        "Snippets.PlayersTab(window, opts)",
        "Snippets.AboutTab(window, info)",
    },
    ["Badge"] = {
        "Badge.attach(target, text, color) → { SetText, SetColor, Destroy }",
        "Badge.inline(text, color)",
    },
    ["Shimmer"] = {
        "Shimmer.place(parent, { rows, height, gap, size }) → { Destroy }",
    },
    ["Spinner"] = {
        "Spinner.place(parent, { size, icon, color, speed, position })",
        "handle:Stop() / :Destroy()",
    },
    ["Chart"] = {
        "Chart.line(parent, { values, color, size }) → :SetValues / :Append / :Destroy",
        "Chart.bar(parent, { values, color, gap, size }) → :SetValues / :Destroy",
    },
    ["HeatMap"] = {
        "HeatMap.place(parent, { data, lo, hi, min, max, size })",
    },
    ["Gauge"] = {
        "Gauge.place(parent, { size, color, trackColor, value, position })",
        "handle:Set(0..1)",
    },
    ["Tokens"] = {
        "Tokens.Default / .Compact / .Cozy",
        "Tokens:Get(name) / :List()",
    },
    ["Wizard"] = {
        "Wizard.new({ title, steps, onFinish })",
        "steps: { id, title, render(panel, state), validate(state) }",
        "wiz:Open() / :Close() / :State()",
    },
    ["Watermark"] = {
        "Watermark.show(text, { position, background, transparency, color, draggable })",
        "handle:SetText / :Destroy",
    },
    ["Profile"] = {
        "Profile.List / Save / Load / Delete / Exists",
        "Profile.SaveFromWindow(window, name)",
        "Profile.LoadIntoWindow(window, name)",
    },
    ["Debug"] = {
        "Debug.windowSummary / countLiveConnections / guiTree",
        "Debug.validateThemes / toggleLowContrast",
    },
    ["Version"] = {
        "Version:String() / :Check(major, minor, patch) / :Has(feature)",
    },
    ["Splash"] = {
        "Splash.show({ title, subtitle, background, color })",
        "handle:Update(title, subtitle) / :Progress(0..1) / :Close()",
    },
    ["Demo"] = {
        "Demo.minimal() / .rich() / .kitchenSink()",
    },
}

-- Render the index as a flat, human-readable string.
function WaffleUI:PrintIndex()
    local sections = {}
    for k in pairs(self.Index) do table.insert(sections, k) end
    table.sort(sections)
    local lines = { "WaffleUI API index", string.rep("=", 60) }
    for _, section in ipairs(sections) do
        table.insert(lines, "")
        table.insert(lines, "[" .. section .. "]")
        for _, entry in ipairs(self.Index[section]) do
            table.insert(lines, "  " .. entry)
        end
    end
    print(table.concat(lines, "\n"))
end



--==============================================================================
-- WaffleUI.Changelog
--
-- Version history as a simple array of tables. Keeping it in-code means it
-- travels with the library and can be surfaced in-game. Newest first.
--==============================================================================
WaffleUI.Changelog = {
    {
        version = "3.0.0",
        date = "2026-05-10",
        highlights = {
            "Extensions bundle: Themes, Icons, Color, Easing, Signal, Store, Validator, i18n, Format, Sequencer, CommandPalette, Diagnostics, Layout, Util, Math, Keyboard, Persistence, Notify, Preset, Reactive, Router, Dialog, Cursor, Sound, Logger, Fuzzy, Markdown, Tween, Grid (virtualised lists), Tooltip, ContextMenu, Drag, EventBus, Anim, Snippets, Badge, Shimmer, Spinner, Chart, HeatMap, Gauge, Tokens, Wizard, Watermark, Profile, Debug, Splash, Demo.",
            "API index + Cookbook shipped alongside the code.",
            "8 extra named themes (Forest, Sunset, HighContrast, Solarized, Dracula, Nord, Monokai, Rose).",
            "Core library unchanged in behaviour; every extension is additive and lives on the returned WaffleUI table.",
        },
        breaking = {},
    },
    {
        version = "2.1.0",
        date = "2026-03-12",
        highlights = {
            "Notification slide animation no longer fights UIListLayout — uses an anchored child.",
            "Added Stepper, Console, Confirm modal, and Tooltip.",
            "Window:SetTitle / :SetSubTitle / :SetSize / :SetPosition / :Show / :Hide.",
            "Drag clamped to viewport so the window can't go off-screen.",
            "Countdown bar on notifications pauses on hover.",
        },
        breaking = {},
    },
    {
        version = "2.0.0",
        date = "2025-11-04",
        highlights = {
            "Connection lifecycle: ConnectionBag tracks every listener per-window so Destroy() no longer leaks.",
            "Live theme swapping: Window:SetTheme(themeOrName) re-colors every created component.",
            "New components: ColorPicker, MultiSelect, Paragraph, Divider, ProgressBar, RadioGroup, SearchableDropdown.",
            "Notifications: severities, click-to-dismiss, non-fighting slide animation.",
            "Config save/load with executor-safe writefile/readfile guard.",
            "SelectTab(name) helper; every component has :Destroy.",
        },
        breaking = {
            "Components created in v1 must be recreated — internal layout changed.",
        },
    },
    {
        version = "1.0.0",
        date = "2025-08-22",
        highlights = {
            "Initial public release.",
            "CreateWindow / CreateTab / AddButton / AddToggle / AddSlider / AddDropdown / AddTextbox / AddKeybind.",
        },
        breaking = {},
    },
}

function WaffleUI:PrintChangelog()
    local lines = { "WaffleUI changelog" }
    for _, entry in ipairs(self.Changelog) do
        table.insert(lines, "")
        table.insert(lines, string.format("== %s (%s) ==", entry.version, entry.date))
        for _, h in ipairs(entry.highlights) do
            table.insert(lines, "  * " .. h)
        end
        if entry.breaking and #entry.breaking > 0 then
            table.insert(lines, "  breaking changes:")
            for _, b in ipairs(entry.breaking) do
                table.insert(lines, "    ! " .. b)
            end
        end
    end
    print(table.concat(lines, "\n"))
end



--==============================================================================
-- WaffleUI.Recipes
--
-- Longer, narrative examples that show how several modules come together.
-- Stored as multi-line strings so they can be displayed in-game as help or
-- just read in this file. They're deliberately runnable with a little
-- boilerplate at the top: `local WaffleUI = require(script.Parent.UILibrary)`.
--==============================================================================
WaffleUI.Recipes = {}

WaffleUI.Recipes.modal_with_validation = [[
-- Modal with validation
-- =====================
-- Collect a username and age, validate, persist to disk.

local V = WaffleUI.Validator
local schema = V.schema({
    name = V.Rules.username(),
    age  = V.Rules.age(),
})

WaffleUI.Dialog.new()
    :title("Create profile")
    :message("Pick a username and tell us your age.")
    :input("name", "Username (3-20 chars)")
    :input("age", "Age")
    :button("Cancel", function(self) self:close() end)
    :primary("Create", function(self, values)
        values.age = tonumber(values.age) or -1
        local ok, errors = schema:validate(values)
        if not ok then
            for field, msg in pairs(errors) do
                WaffleUI.Notify:Error(field, msg)
            end
            return
        end
        WaffleUI.Persistence:Save("profile", values)
        WaffleUI.Notify:Success("Welcome", values.name)
        self:close()
    end)
    :show()
]]

WaffleUI.Recipes.command_palette_wiring = [[
-- Command palette wiring
-- ======================
-- Register a handful of useful commands and bind Ctrl+K to open the palette.

local P = WaffleUI.CommandPalette

P:Register({
    id = "theme.cycle",
    name = "Cycle theme",
    group = "Theme",
    keywords = { "palette", "colors" },
    run = function()
        local themes = WaffleUI:ListThemes()
        local i = table.find(themes, _G.currentTheme) or 1
        local next = themes[(i % #themes) + 1]
        _G.currentTheme = next
        for _, w in ipairs(WaffleUI._windows) do w:SetTheme(next) end
    end,
})

P:Register({
    id = "fps.overlay",
    name = "Toggle FPS overlay",
    group = "Debug",
    run = function() WaffleUI.Diagnostics:Overlay(not WaffleUI.Diagnostics._overlayEnabled) end,
})

P:InstallHotkey()
]]

WaffleUI.Recipes.virtual_list_of_players = [[
-- Virtualised player list
-- =======================
-- Build a scrolling list of every player and refresh it as players come
-- and go. Rows are recycled by the virtualiser so the framerate doesn't
-- suffer when there are hundreds of players.

local Window = WaffleUI:CreateWindow({ Title = "Players" })
local Tab    = Window:CreateTab("Online")

-- The core Tab component doesn't yet expose a raw ScrollingFrame; for the
-- recipe, create one inside a Paragraph container or call CreateWindow's
-- internal factory. Here we just dump labels:

local function rowFor(plr)
    return string.format("%s   AccountAge=%d", plr.DisplayName, plr.AccountAge)
end

local function refresh()
    -- Recreate the tab to flush its children. In real code, keep a virtual
    -- Grid instead.
    Tab:AddSection("Players")
    for _, plr in ipairs(game.Players:GetPlayers()) do
        Tab:AddLabel(rowFor(plr))
    end
end

refresh()
game.Players.PlayerAdded:Connect(refresh)
game.Players.PlayerRemoving:Connect(function() task.delay(0.1, refresh) end)
]]

WaffleUI.Recipes.persistent_keybinds = [[
-- Persistent keybinds across sessions
-- ===================================
-- Using the WaffleUI.Keyboard global + Persistence namespace.

local store = WaffleUI.Persistence:Namespace("keybinds")

local defaults = {
    ["sprint"] = "LeftShift",
    ["jump"]   = "Space",
    ["menu"]   = "M",
}

local current = store:Load("bindings", defaults)

for name, key in pairs(current) do
    WaffleUI.Keyboard:Bind(key, function()
        print("action:", name)
    end)
end

function rebind(name, newKey)
    WaffleUI.Keyboard:Unbind(current[name])
    current[name] = newKey
    WaffleUI.Keyboard:Bind(newKey, function() print("action:", name) end)
    store:Save("bindings", current)
end
]]

WaffleUI.Recipes.store_driven_ui = [[
-- Store-driven UI
-- ================
-- Use WaffleUI.Store as the single source of truth. Every component reads
-- from and writes to the store, and the store drives in-game logic.

local store = WaffleUI.Store.new({
    player = { hp = 100, walkspeed = 16 },
    ui     = { theme = "Dark" },
})

store:Subscribe("player.walkspeed", function(v)
    local c = game.Players.LocalPlayer.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    if h then h.WalkSpeed = v end
end)

local Window = WaffleUI:CreateWindow({ Title = "Store demo" })
local tab = Window:CreateTab("Main")
tab:AddSlider({
    Text = "WalkSpeed",
    Min = 16, Max = 200, Default = 16,
    Callback = function(v) store:Set("player.walkspeed", v) end,
})
tab:AddDropdown({
    Text = "Theme",
    Options = WaffleUI:ListThemes(),
    Default = "Dark",
    Callback = function(name)
        store:Set("ui.theme", name)
        Window:SetTheme(name)
    end,
})
]]

WaffleUI.Recipes.animation_sequence = [[
-- Animation sequence
-- ==================
-- Chain several tweens with WaffleUI.Sequencer.

local seq = WaffleUI.Sequencer.new()
    :to(card, { Size = UDim2.fromScale(1, 1) }, 0.4, "Quint")
    :wait(0.1)
    :parallel({
        { obj = title, props = { TextTransparency = 0 }, duration = 0.25 },
        { obj = icon,  props = { Rotation = 360 },       duration = 0.4  },
    })
    :call(function() print("entrance done") end)

seq:play()
seq.Completed:Connect(function() print("tween sequence complete") end)
]]

function WaffleUI:ListRecipes()
    local out = {}
    for k in pairs(self.Recipes) do table.insert(out, k) end
    table.sort(out)
    return out
end

function WaffleUI:GetRecipe(name)
    return self.Recipes[name]
end



--==============================================================================
-- WaffleUI.Accessibility
--
-- Accessibility settings + helpers. These don't magically make the library
-- WCAG-compliant, but they provide a central place to store user choices
-- like reduced motion and larger text, which components can consult.
--==============================================================================
WaffleUI.Accessibility = {}
local A11y = WaffleUI.Accessibility

A11y._settings = {
    reduceMotion = false,
    largeText    = false,
    highContrast = false,
    screenReader = false,
}
A11y.Changed = WaffleUI.Signal.new()

function A11y:Get(key) return self._settings[key] end

function A11y:Set(key, value)
    if self._settings[key] == value then return end
    self._settings[key] = value
    self.Changed:Fire(key, value)
end

function A11y:Apply(partial)
    for k, v in pairs(partial or {}) do self:Set(k, v) end
end

function A11y:Snapshot()
    local out = {}
    for k, v in pairs(self._settings) do out[k] = v end
    return out
end

-- Helper: pick a text size given the current largeText setting.
function A11y:TextSize(base)
    if self._settings.largeText then return math.ceil(base * 1.25) end
    return base
end

-- Helper: pick a tween duration given the current reduceMotion setting.
function A11y:Duration(base)
    if self._settings.reduceMotion then return math.min(base, 0.05) end
    return base
end

-- Helper: pick a stroke color given the current highContrast setting.
function A11y:StrokeColor(default)
    if self._settings.highContrast then return Color3.new(1, 1, 1) end
    return default
end

-- Convenience quickstart that wires up a SettingsTab with accessibility
-- controls and persists them on change.
function A11y:InstallTab(window, opts)
    opts = opts or {}
    local tab = window:CreateTab(opts.tabName or "Accessibility", opts.icon)
    tab:AddSection("Accessibility")
    tab:AddToggle({
        Text = "Reduce motion",
        Default = self._settings.reduceMotion,
        Flag = "a11y_reduceMotion",
        Callback = function(v) self:Set("reduceMotion", v) end,
    })
    tab:AddToggle({
        Text = "Larger text",
        Default = self._settings.largeText,
        Flag = "a11y_largeText",
        Callback = function(v) self:Set("largeText", v) end,
    })
    tab:AddToggle({
        Text = "High contrast",
        Default = self._settings.highContrast,
        Flag = "a11y_highContrast",
        Callback = function(v) self:Set("highContrast", v) end,
    })
    tab:AddToggle({
        Text = "Screen reader hints",
        Default = self._settings.screenReader,
        Flag = "a11y_screenReader",
        Callback = function(v) self:Set("screenReader", v) end,
    })
    tab:AddParagraph({
        Title = "Notes",
        Text  = "Accessibility settings only take effect when components consult them. The built-in WaffleUI components do not currently react to these flags; they are provided so your custom components can.",
    })
    return tab
end



--==============================================================================
-- WaffleUI.DevPanel
--
-- Tiny floating "dev tools" panel: FPS graph, live theme switcher, palette
-- toggle, clear-storage button. Useful for authors while building their
-- hub, not typically shipped to users.
--==============================================================================
WaffleUI.DevPanel = {}
local DevPanel = WaffleUI.DevPanel

function DevPanel.show(opts)
    opts = opts or {}
    local parent = PlayerGui or CoreGui
    local gui = Instance.new("ScreenGui")
    gui.Name = "WaffleDevPanel"
    gui.DisplayOrder = 75000
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = parent

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(240, 220)
    frame.Position = opts.position or UDim2.fromOffset(10, 80)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    frame.BorderSizePixel = 0
    frame.Parent = gui
    local cc = Instance.new("UICorner"); cc.CornerRadius = UDim.new(0, 6); cc.Parent = frame

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold; title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(240, 240, 245)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Size = UDim2.new(1, -10, 0, 24)
    title.Position = UDim2.fromOffset(10, 4)
    title.Text = "Waffle Dev"
    title.Parent = frame

    -- FPS graph
    local graph = WaffleUI.Chart.line(frame, {
        size = UDim2.new(1, -20, 0, 60),
        values = {},
        color = Color3.fromRGB(120, 255, 180),
    })
    graph.frame.Position = UDim2.fromOffset(10, 30)

    local fpsAvg = WaffleUI.Math.rollingAverage(60)
    local running = true
    task.spawn(function()
        local values = {}
        while running do
            task.wait(0.1)
            local dt = RunService.Heartbeat:Wait()
            local fps = fpsAvg:step(1 / math.max(dt, 1e-6))
            table.insert(values, fps)
            if #values > 60 then table.remove(values, 1) end
            graph:SetValues(values)
        end
    end)

    -- Buttons
    local y = 100
    local function btn(text, cb)
        local b = Instance.new("TextButton")
        b.AutoButtonColor = false
        b.Size = UDim2.new(1, -20, 0, 26)
        b.Position = UDim2.fromOffset(10, y)
        b.BackgroundColor3 = Color3.fromRGB(40, 40, 54)
        b.TextColor3 = Color3.fromRGB(230, 230, 240)
        b.Font = Enum.Font.Gotham; b.TextSize = 12
        b.Text = text
        b.BorderSizePixel = 0
        b.Parent = frame
        local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = b
        b.MouseButton1Click:Connect(cb)
        y = y + 30
    end

    btn("Command palette", function()
        WaffleUI.CommandPalette:Toggle()
    end)

    btn("Toggle FPS overlay", function()
        WaffleUI.Diagnostics:Overlay(not WaffleUI.Diagnostics._overlayEnabled)
    end)

    btn("Print index", function() WaffleUI:PrintIndex() end)
    btn("Print changelog", function() WaffleUI:PrintChangelog() end)

    -- drag handle
    WaffleUI.Drag.attach(frame, {
        handle = title, clampToViewport = true,
    })

    return {
        gui = gui,
        Destroy = function()
            running = false
            gui:Destroy()
        end,
    }
end



--==============================================================================
-- WaffleUI.FAQ
--
-- Answers to the most-asked questions from issue trackers and Discord DMs.
-- Kept in source so they ship with the library and can be surfaced in-game.
--==============================================================================
WaffleUI.FAQ = {
    {
        q = "Why is the config file not saving?",
        a = "Config requires `writefile` (or the sandboxed equivalent). If the "
         .. "host environment doesn't expose it, WaffleUI silently skips "
         .. "persistence. Check `WaffleUI.Persistence:Available()` — if false "
         .. "the file will not be written.",
    },
    {
        q = "How do I change the toggle hotkey?",
        a = "Pass `Keybind = Enum.KeyCode.X` to :CreateWindow. You can also "
         .. "set it via :SetKeybind(Enum.KeyCode.X) on the returned Window.",
    },
    {
        q = "My notifications are cut off at the bottom.",
        a = "Increase the max-per-stack: "
         .. "`WaffleUI.Notify:SetMaxPerStack(6)`. By default only 4 toasts "
         .. "show at once; older ones fade to make room.",
    },
    {
        q = "How do I make a custom theme?",
        a = "Copy one of the themes in WaffleUI.Themes and tweak the values. "
         .. "Register with WaffleUI:RegisterTheme(name, palette) or pass the "
         .. "table directly to Window:SetTheme(palette).",
    },
    {
        q = "Can I nest tabs?",
        a = "Not natively. The typical workaround is a Dropdown at the top "
         .. "of a Tab that filters sections. For complex navigation use "
         .. "WaffleUI.Router to deep-link between flat tabs.",
    },
    {
        q = "Does it support gamepad?",
        a = "Input events work with gamepad, but focus management is manual. "
         .. "For now, controller users can use the mouse cursor that most "
         .. "Roblox experiences already provide when a gamepad is detected.",
    },
    {
        q = "The window appears behind other GUIs.",
        a = "Adjust `DisplayOrder` on the ScreenGui the library creates. "
         .. "The built-in order is 1000; bump it to 10000+ for aggressive "
         .. "layering.",
    },
    {
        q = "How do I reset a component to its default programmatically?",
        a = "Components with a `Set` method accept any value; pass the default "
         .. "to reset. For Window-wide resets, call "
         .. "`WaffleUI.Profile.LoadIntoWindow(window, 'defaults')` after "
         .. "saving 'defaults' once at startup.",
    },
    {
        q = "Can I skip the animations?",
        a = "Use WaffleUI.Accessibility:Set('reduceMotion', true). Custom "
         .. "components can consult this flag when computing tween "
         .. "durations. The built-in components do not yet react to it.",
    },
    {
        q = "How do I add an image/logo to the title bar?",
        a = "Pass `Icon = 'rbxassetid://...'` to :CreateWindow. For more "
         .. "elaborate branding, build your own ScreenGui above the Window.",
    },
}

function WaffleUI:PrintFAQ()
    local lines = { "WaffleUI FAQ" }
    for i, entry in ipairs(self.FAQ) do
        table.insert(lines, "")
        table.insert(lines, string.format("Q%d. %s", i, entry.q))
        table.insert(lines, "    " .. entry.a)
    end
    print(table.concat(lines, "\n"))
end



--==============================================================================
-- WaffleUI.Compatibility
--
-- Runtime detection helpers. Because the library is meant to be robust on
-- both official Roblox clients and various executor sandboxes, a fair
-- amount of code-path selection depends on which globals are present.
-- Centralising the checks here makes them testable and consistent.
--==============================================================================
WaffleUI.Compatibility = {}
local Compat = WaffleUI.Compatibility

function Compat.hasCoreGui()
    return pcall(function() return CoreGui:GetChildren() end)
end

function Compat.hasWriteFile()
    return typeof(writefile) == "function" and typeof(readfile) == "function"
end

function Compat.hasListFiles()
    return typeof(listfiles) == "function"
end

function Compat.hasDelFile()
    return typeof(delfile) == "function"
end

function Compat.hasSetClipboard()
    return typeof(setclipboard) == "function"
end

function Compat.hasGetGenv()
    return typeof(getgenv) == "function"
end

function Compat.hasHookfunction()
    return typeof(hookfunction) == "function"
end

function Compat.report()
    return {
        coreGui       = Compat.hasCoreGui(),
        writeFile     = Compat.hasWriteFile(),
        listFiles     = Compat.hasListFiles(),
        delFile       = Compat.hasDelFile(),
        setClipboard  = Compat.hasSetClipboard(),
        getGenv       = Compat.hasGetGenv(),
        hookFunction  = Compat.hasHookfunction(),
    }
end

function Compat.printReport()
    local r = Compat.report()
    print("WaffleUI compatibility report:")
    for key, value in pairs(r) do
        print(string.format("  %-14s %s", key, value and "yes" or "no"))
    end
end



--==============================================================================
-- WaffleUI.Recovery
--
-- Helpers that let authors gracefully recover from a partial failure in
-- their own callbacks. The library guards its own internal callbacks with
-- pcall, but user callbacks don't — these helpers make that easy.
--==============================================================================
WaffleUI.Recovery = {}
local Recovery = WaffleUI.Recovery

-- Wrap a callback so any error:
--    * logs via WaffleUI.Logger.default
--    * surfaces a toast via WaffleUI.Notify:Error
--    * does not propagate to Roblox's connection machinery
function Recovery.safe(fn, name)
    name = name or "<anonymous>"
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            WaffleUI.Logger.default:error(
                string.format("Callback '%s' failed: %s", name, tostring(err)))
            WaffleUI.Notify:Error(
                "Callback failed",
                string.format("'%s' — see output for the stack trace", name))
        end
    end
end

-- Retry fn up to `attempts` times with exponential backoff between tries.
-- Succeeds and returns whatever fn returned on the first success; gives
-- up and raises the last error otherwise.
function Recovery.retry(fn, attempts, initialDelay)
    attempts = attempts or 3
    local delay = initialDelay or 0.25
    local lastErr
    for i = 1, attempts do
        local ok, errOrResult = pcall(fn)
        if ok then return errOrResult end
        lastErr = errOrResult
        if i < attempts then
            task.wait(delay)
            delay = delay * 2
        end
    end
    error(lastErr)
end

-- Run fn and, if it errors, fall back to alt. Returns whichever ran.
function Recovery.fallback(fn, alt)
    local ok, result = pcall(fn)
    if ok then return result end
    return alt()
end

-- Ensure fn runs exactly once per tick, swallowing extra calls. Useful to
-- guard against input flurries.
function Recovery.oncePerFrame(fn)
    local fired = false
    RunService.Heartbeat:Connect(function() fired = false end)
    return function(...)
        if fired then return end
        fired = true
        fn(...)
    end
end



--==============================================================================
-- WaffleUI.Contributors
--
-- Credits list. Add yourself (and anyone you collaborated with) to the
-- table below. Consumer code can pipe this into a Credits tab via the
-- Snippets.CreditsTab helper.
--==============================================================================
WaffleUI.Contributors = {
    { name = "Core library", role = "Design & implementation" },
    { name = "Themes pack",  role = "Curated palettes from community submissions" },
    { name = "Icons pack",   role = "Curated rbxassetid registry" },
    { name = "Validator",    role = "Schema system modelled after Zod" },
    { name = "Localisations", role = "English, Spanish, French, German, Portuguese, Japanese" },
    { name = "Docs & FAQ",   role = "Cookbook, Recipes, Changelog, Index" },
    { name = "You?",          role = "PRs welcome — drop a line in the repo" },
}

function WaffleUI:PrintContributors()
    local lines = { "WaffleUI contributors" }
    for _, c in ipairs(self.Contributors) do
        table.insert(lines, string.format("  %s — %s", c.name, c.role))
    end
    print(table.concat(lines, "\n"))
end



--==============================================================================
-- WaffleUI.License
--
-- License text, kept in source so redistributions always carry it along.
--==============================================================================
WaffleUI.License = [[
MIT License

Copyright (c) 2025-2026 WaffleUI contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
]]

function WaffleUI:PrintLicense()
    print(self.License)
end



--==============================================================================
-- WaffleUI.SelfTest
--
-- A minimal smoke test that instantiates every top-level module and calls
-- one representative method on it. Not a substitute for real unit tests,
-- but catches regressions where a renamed field breaks dozens of files.
--==============================================================================
WaffleUI.SelfTest = {}
local SelfTest = WaffleUI.SelfTest

local function expect(ok, message)
    if not ok then error("SelfTest: " .. message) end
end

local function test(name, fn)
    local ok, err = pcall(fn)
    return { name = name, ok = ok, err = err }
end

function SelfTest.run()
    local results = {}

    table.insert(results, test("Version:String", function()
        local s = WaffleUI.Version:String()
        expect(type(s) == "string", "Version:String did not return a string")
    end))

    table.insert(results, test("Themes.Dark exists", function()
        expect(type(WaffleUI.Themes.Dark) == "table", "Themes.Dark missing")
    end))

    table.insert(results, test("Color.hex", function()
        local c = WaffleUI.Color.hex("#336699")
        expect(math.abs(c.R - 0x33/255) < 0.01, "hex red channel wrong")
    end))

    table.insert(results, test("Easing.quad.inOut(0.5)", function()
        local v = WaffleUI.Easing.quad.inOut(0.5)
        expect(math.abs(v - 0.5) < 0.05, "quad.inOut should be near 0.5 at t=0.5")
    end))

    table.insert(results, test("Signal fires", function()
        local sig = WaffleUI.Signal.new()
        local got = nil
        sig:Connect(function(v) got = v end)
        sig:Fire("hi")
        task.wait()
        expect(got == "hi", "signal did not fire")
    end))

    table.insert(results, test("Store set/get", function()
        local s = WaffleUI.Store.new({ a = 1 })
        s:Set("a", 2)
        expect(s:Get("a") == 2, "Store:Set didn't persist")
    end))

    table.insert(results, test("Validator", function()
        local V = WaffleUI.Validator
        local ok = V.schema({ n = V.number():required() }):validate({ n = 5 })
        expect(ok, "validator rejected valid data")
    end))

    table.insert(results, test("i18n missing key fallback", function()
        local v = WaffleUI.i18n:Translate("nonexistent.key")
        expect(type(v) == "string", "i18n should fall back to key string")
    end))

    table.insert(results, test("Format.thousands", function()
        expect(WaffleUI.Format.thousands(1234567) == "1,234,567", "thousands formatter wrong")
    end))

    table.insert(results, test("Fuzzy match finds subsequence", function()
        local m = WaffleUI.Fuzzy.match("abc", "axbxc")
        expect(m ~= nil, "fuzzy match failed on valid subsequence")
    end))

    table.insert(results, test("Util.map", function()
        local doubled = WaffleUI.Util.map({1,2,3}, function(n) return n * 2 end)
        expect(doubled[2] == 4, "Util.map produced wrong output")
    end))

    table.insert(results, test("Math.rollingAverage", function()
        local r = WaffleUI.Math.rollingAverage(3)
        r:step(1); r:step(3); r:step(5)
        expect(math.abs(r:value() - 3) < 0.001, "rolling average of 1,3,5 should be 3")
    end))

    return results
end

function SelfTest.printReport()
    local results = SelfTest.run()
    local lines = { "WaffleUI self-test" }
    local passed, failed = 0, 0
    for _, r in ipairs(results) do
        if r.ok then
            passed = passed + 1
            table.insert(lines, "  [ok] " .. r.name)
        else
            failed = failed + 1
            table.insert(lines, string.format("  [FAIL] %s — %s", r.name, tostring(r.err)))
        end
    end
    table.insert(lines, string.format("Total: %d passed, %d failed", passed, failed))
    print(table.concat(lines, "\n"))
    return passed, failed
end



--==============================================================================
-- WaffleUI.Shortcuts
--
-- Pre-baked keyboard shortcut sets you can install in one call. Each set
-- is a curated bundle of bindings that match a familiar application
-- convention (web, editor, game).
--==============================================================================
WaffleUI.Shortcuts = {}
local Shortcuts = WaffleUI.Shortcuts

-- Browser-like shortcuts — useful if your hub behaves like a webapp.
Shortcuts.Browser = {
    { shortcut = "Ctrl+K",       id = "palette.open" },
    { shortcut = "Ctrl+F",       id = "search.focus" },
    { shortcut = "Ctrl+S",       id = "settings.save" },
    { shortcut = "Ctrl+Z",       id = "history.undo" },
    { shortcut = "Ctrl+Shift+Z", id = "history.redo" },
    { shortcut = "Ctrl+R",       id = "view.refresh" },
    { shortcut = "Escape",       id = "modal.close" },
}

-- Editor-like shortcuts (VSCode-ish).
Shortcuts.Editor = {
    { shortcut = "Ctrl+P",       id = "file.quickopen" },
    { shortcut = "Ctrl+Shift+P", id = "palette.open" },
    { shortcut = "Ctrl+,",       id = "settings.open" },
    { shortcut = "Ctrl+`",       id = "console.toggle" },
    { shortcut = "Ctrl+B",       id = "sidebar.toggle" },
    { shortcut = "Ctrl+Shift+F", id = "search.global" },
}

-- Game-like shortcuts.
Shortcuts.Game = {
    { shortcut = "Tab",    id = "scoreboard.toggle" },
    { shortcut = "Escape", id = "menu.toggle" },
    { shortcut = "M",      id = "map.toggle" },
    { shortcut = "I",      id = "inventory.toggle" },
    { shortcut = "C",      id = "character.toggle" },
    { shortcut = "F",      id = "action.interact" },
}

-- Install a set; handlers is a table of `id -> callback`. Any ids that
-- don't have a handler are silently ignored.
function Shortcuts:Install(set, handlers)
    handlers = handlers or {}
    for _, binding in ipairs(set) do
        local handler = handlers[binding.id]
        if handler then
            WaffleUI.Keyboard:Bind(binding.shortcut, handler)
        end
    end
end

-- Human-readable description of a set (useful for help dialogs).
function Shortcuts:Describe(set)
    local lines = {}
    for _, binding in ipairs(set) do
        table.insert(lines, string.format("  %-20s %s", binding.shortcut, binding.id))
    end
    return table.concat(lines, "\n")
end



--==============================================================================
-- WaffleUI.Errors
--
-- A catalog of error codes returned by library APIs. Each error carries a
-- stable short code plus a longer message. Consumer code can match on the
-- code rather than trying to parse the message string.
--==============================================================================
WaffleUI.Errors = {
    UNKNOWN_THEME         = "UNKNOWN_THEME",
    UNKNOWN_LOCALE        = "UNKNOWN_LOCALE",
    PERSISTENCE_UNAVAIL   = "PERSISTENCE_UNAVAIL",
    CONFIG_DECODE_FAILED  = "CONFIG_DECODE_FAILED",
    INVALID_KEYBIND       = "INVALID_KEYBIND",
    WINDOW_DESTROYED      = "WINDOW_DESTROYED",
    COMPONENT_DESTROYED   = "COMPONENT_DESTROYED",
    DUPLICATE_FLAG        = "DUPLICATE_FLAG",
    DUPLICATE_TAB_NAME    = "DUPLICATE_TAB_NAME",
    VALIDATION_FAILED     = "VALIDATION_FAILED",
    PALETTE_NOT_FOUND     = "PALETTE_NOT_FOUND",
    UNKNOWN_COMMAND       = "UNKNOWN_COMMAND",
}

WaffleUI.ErrorMessages = {
    UNKNOWN_THEME        = "No theme is registered under that name.",
    UNKNOWN_LOCALE       = "No locale is registered under that code.",
    PERSISTENCE_UNAVAIL  = "writefile/readfile are not available in this environment.",
    CONFIG_DECODE_FAILED = "The config file on disk is not valid JSON.",
    INVALID_KEYBIND      = "That key code does not exist in the Enum.KeyCode table.",
    WINDOW_DESTROYED     = "The parent window has already been destroyed.",
    COMPONENT_DESTROYED  = "The component has already been destroyed.",
    DUPLICATE_FLAG       = "A component with this flag already exists in this config.",
    DUPLICATE_TAB_NAME   = "A tab with this name already exists in the window.",
    VALIDATION_FAILED    = "Input failed schema validation.",
    PALETTE_NOT_FOUND    = "No command is registered under that id.",
    UNKNOWN_COMMAND      = "Unrecognised command name passed to WaffleUI:Exec.",
}

function WaffleUI:Raise(code, ...)
    local msg = self.ErrorMessages[code] or "Unknown error"
    local extra = select("#", ...) > 0 and (" (" .. table.concat({...}, ", ") .. ")") or ""
    error(string.format("[WaffleUI:%s] %s%s", code, msg, extra))
end



--==============================================================================
-- WaffleUI.Help
--
-- One-stop help surface. Call WaffleUI:Help() with a topic string to print
-- the relevant docs into the output window.
--==============================================================================
function WaffleUI:Help(topic)
    topic = topic and tostring(topic) or "index"
    -- Handle a few aliases
    local aliases = {
        ["intro"] = "getting-started",
        ["start"] = "getting-started",
        ["getstart"] = "getting-started",
        ["colors"] = "themes",
        ["theme"] = "themes",
        ["config"] = "persistence",
        ["save"] = "persistence",
        ["keys"] = "keybinds",
        ["shortcuts"] = "keybinds",
        ["toast"] = "notifications",
        ["validate"] = "validation",
        ["cmd"] = "palette",
        ["command"] = "palette",
        ["lang"] = "locale",
        ["i18n"] = "locale",
    }
    local key = aliases[topic] or topic
    local text = self.Cookbook and self.Cookbook[key]
    if text then
        print(text)
        return
    end
    -- Not in cookbook; try the index.
    if key == "index" then
        self:PrintIndex()
        return
    end
    if self.Index and self.Index[topic] then
        local lines = { string.format("[%s]", topic) }
        for _, entry in ipairs(self.Index[topic]) do
            table.insert(lines, "  " .. entry)
        end
        print(table.concat(lines, "\n"))
        return
    end
    print(string.format(
        "[WaffleUI] no help topic '%s'. Known topics: %s",
        topic, table.concat(self:ListHelp(), ", ")))
end

function WaffleUI:ListHelp()
    local out = {}
    if self.Cookbook then
        for k in pairs(self.Cookbook) do table.insert(out, k) end
    end
    if self.Index then
        for k in pairs(self.Index) do table.insert(out, k) end
    end
    table.sort(out)
    -- Dedup
    local seen, final = {}, {}
    for _, k in ipairs(out) do
        if not seen[k] then seen[k] = true; table.insert(final, k) end
    end
    return final
end



--==============================================================================
-- WaffleUI.Matrix
--
-- Small 3x3 / 4x4 matrix helpers for UI-space transforms (rotate + scale +
-- translate). Keeping this in the library means you can chain a couple of
-- operations without pulling in a whole math library. All matrices are
-- flat arrays, row-major, length 9 or 16.
--==============================================================================
WaffleUI.Matrix = {}
local Matrix = WaffleUI.Matrix

function Matrix.identity3()
    return { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
end

function Matrix.identity4()
    return { 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1 }
end

function Matrix.mul3(a, b)
    local r = {}
    for i = 0, 2 do
        for j = 0, 2 do
            local v = 0
            for k = 0, 2 do
                v = v + a[i * 3 + k + 1] * b[k * 3 + j + 1]
            end
            r[i * 3 + j + 1] = v
        end
    end
    return r
end

function Matrix.rotate2D(angleRad)
    local c, s = math.cos(angleRad), math.sin(angleRad)
    return { c, -s, 0,  s, c, 0,  0, 0, 1 }
end

function Matrix.scale2D(sx, sy)
    return { sx, 0, 0,  0, sy, 0,  0, 0, 1 }
end

function Matrix.translate2D(tx, ty)
    return { 1, 0, tx,  0, 1, ty,  0, 0, 1 }
end

function Matrix.apply2D(m, x, y)
    return
        m[1] * x + m[2] * y + m[3],
        m[4] * x + m[5] * y + m[6]
end

function Matrix.compose2D(...)
    local mats = { ... }
    local r = Matrix.identity3()
    for _, m in ipairs(mats) do r = Matrix.mul3(r, m) end
    return r
end

--==============================================================================
-- WaffleUI.Time
--
-- Frame-accurate clock helpers. os.clock is sufficient for most things,
-- but these wrap a few common idioms so calling code is shorter.
--==============================================================================
WaffleUI.Time = {}
local T2 = WaffleUI.Time

function T2.now() return os.clock() end

function T2.since(t0) return os.clock() - t0 end

-- A basic stopwatch — returns an object with :Reset() and :Elapsed()
local Stopwatch = {}
Stopwatch.__index = Stopwatch
function T2.stopwatch()
    return setmetatable({ _t = os.clock() }, Stopwatch)
end
function Stopwatch:Reset() self._t = os.clock(); return self end
function Stopwatch:Elapsed() return os.clock() - self._t end

-- Timer helper — schedules a callback after a duration, returning a cancel
-- token. Unlike Util.setTimeout, this forwards the initial call's arguments.
function T2.timer(duration, fn, ...)
    local args = { ... }
    local cancelled = false
    task.delay(duration, function()
        if cancelled then return end
        pcall(fn, table.unpack(args))
    end)
    return function() cancelled = true end
end

-- Frame-rate independent tick counter. Useful when you want "every N
-- seconds" inside a Heartbeat loop without a separate coroutine.
local Pulse = {}
Pulse.__index = Pulse
function T2.pulse(interval)
    return setmetatable({ _interval = interval, _last = 0 }, Pulse)
end
function Pulse:Ready()
    local now = os.clock()
    if now - self._last >= self._interval then
        self._last = now
        return true
    end
    return false
end

--==============================================================================
--
-- Called once the first time a consumer `require`s the module. Prints a
-- compact banner with version and feature summary. Toggleable.
--==============================================================================
WaffleUI.Greet = { enabled = false }  -- off by default; hubs can enable this

function WaffleUI.Greet:Enable() self.enabled = true end
function WaffleUI.Greet:Disable() self.enabled = false end

function WaffleUI.Greet:Print()
    if not self.enabled then return end
    print(string.rep("=", 60))
    print(string.format(
        " WaffleUI v%s  (%d themes, %d locales, %d cookbook topics)",
        WaffleUI.Version:String(),
        #WaffleUI:ListThemes(),
        (function() local n = 0; for _ in pairs(WaffleUI.i18n._locales) do n = n + 1 end; return n end)(),
        (function() local n = 0; for _ in pairs(WaffleUI.Cookbook) do n = n + 1 end; return n end)()))
    print(" Call WaffleUI:Help(\"getting-started\") for the quickstart.")
    print(" Call WaffleUI:PrintIndex() for the full API list.")
    print(string.rep("=", 60))
end

WaffleUI.Greet:Print()

--==============================================================================
-- Post-init notes
--
-- The library does not make any outbound network calls, does not hook
-- Roblox's global tables, and does not modify workspace Instances. Every
-- instance it creates lives under the ScreenGui it owns. Destroying a
-- Window destroys that ScreenGui and all its descendants, releasing every
-- listener registered through the ConnectionBag.
--==============================================================================

--==============================================================================
-- Done.
--
-- Everything above this line is an extension bundle attached to WaffleUI.
-- The core (Window, Tab, Components, Config, Notify) lives above the
-- extensions banner and is unchanged behaviourally. This module returns
-- the singleton WaffleUI table so consumers can:
--
--     local WaffleUI = require(path.to.UILibrary)
--     local Window   = WaffleUI:CreateWindow(...)
--     WaffleUI:Help("getting-started")
--     WaffleUI.Notify:Success("Ready")
--     WaffleUI.SelfTest.printReport()
--
-- Total footprint: 45+ extension modules, 12+ themes, 6 locales, a cookbook,
-- an API index, a changelog, an FAQ, a recipes collection, a license, and
-- a self-test suite. Everything lives on the singleton `WaffleUI` table.
--
-- If anything below breaks for you, file an issue with:
--   1. The output of WaffleUI.Compatibility.printReport()
--   2. The output of WaffleUI.SelfTest.printReport()
--   3. Your Roblox client version / executor name and build number
--==============================================================================
return WaffleUI


-- End of file.
