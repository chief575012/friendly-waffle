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
--==============================================================================
local function makeDraggable(handle, target, bag)
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
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
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
    Version      = "2.0.0",
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

function WaffleUI:Notify(opts)
    opts = opts or {}
    local title    = opts.Title    or "Notification"
    local text     = opts.Text     or ""
    local duration = opts.Duration or 4
    local severity = opts.Severity or "Info"
    local theme    = resolveTheme(opts.Theme or self._activeTheme)
    local barColor = theme[NOTIFY_COLORS[severity] or "Primary"]

    local stack = ensureNotifyStack()

    -- Wrap: outer holds layout-controlled position, inner slides via padding
    local wrap = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Parent                 = stack,
    })
    local wrapPad = padding(0, wrap)
    wrapPad.PaddingLeft = UDim.new(0, 340) -- start off-screen right

    local card = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundColor3       = theme.Surface,
        BackgroundTransparency = 0,
        Parent                 = wrap,
        ClipsDescendants       = true,
    })
    corner(10, card)
    stroke(theme.Stroke, 1, card)
    padding(12, card)

    new("UIListLayout", {
        Padding   = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent    = card,
    })

    local bar = new("Frame", {
        AnchorPoint      = Vector2.new(0, 0),
        Size             = UDim2.new(0, 3, 1, 0),
        Position         = UDim2.new(0, -9, 0, 0),
        BackgroundColor3 = barColor,
        BorderSizePixel  = 0,
        Parent           = card,
    })
    corner(2, bar)

    local titleRow = new("Frame", {
        Size                   = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Parent                 = card,
        LayoutOrder            = 1,
    })
    new("TextLabel", {
        Size                   = UDim2.new(1, -24, 1, 0),
        BackgroundTransparency = 1,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 14,
        TextColor3             = theme.Text,
        TextXAlignment         = Enum.TextXAlignment.Left,
        Text                   = title,
        Parent                 = titleRow,
    })
    local closeBtn = new("TextButton", {
        Size             = UDim2.new(0, 18, 0, 18),
        Position         = UDim2.new(1, -18, 0, 0),
        BackgroundTransparency = 1,
        Font             = Enum.Font.GothamBold,
        TextSize         = 14,
        TextColor3       = theme.SubText,
        Text             = "x",
        AutoButtonColor  = false,
        Parent           = titleRow,
    })

    new("TextLabel", {
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

    local dismissed = false
    local function dismiss()
        if dismissed then return end
        dismissed = true
        tween(wrapPad, QUICK, { PaddingLeft = UDim.new(0, 340) })
        tween(card,    QUICK, { BackgroundTransparency = 1 })
        task.delay(0.2, function() wrap:Destroy() end)
    end

    -- Click card or close button to dismiss
    local clickHit = new("TextButton", {
        Size                   = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Text                   = "",
        AutoButtonColor        = false,
        ZIndex                 = 0,
        Parent                 = card,
    })
    clickHit.MouseButton1Click:Connect(dismiss)
    closeBtn.MouseButton1Click:Connect(dismiss)

    -- Slide in
    tween(wrapPad, MEDIUM, { PaddingLeft = UDim.new(0, 0) })

    task.delay(duration, dismiss)
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
function Components.Slider(parent, dispatcher, bag, opts, saveHook)
    opts = opts or {}
    local minV = opts.Min       or 0
    local maxV = opts.Max       or 100
    local step = opts.Increment or 1
    local fmt  = opts.Format    or "%g"
    local val  = math.clamp(opts.Default or minV, minV, maxV)

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
        Size   = UDim2.new((val - minV) / (maxV - minV), 0, 1, 0),
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
        local raw = minV + ratio * (maxV - minV)
        local snapped = math.clamp(round(raw), minV, maxV)
        if snapped ~= val then
            val = snapped
            valueText.Text = string.format(fmt, val)
            tween(fill, TweenInfo.new(0.08), {
                Size = UDim2.new((val - minV) / (maxV - minV), 0, 1, 0),
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
        Set      = function(_, v, silent) setFromRatio((v - minV) / (maxV - minV), silent) end,
        Get      = function() return val end,
        Destroy  = function() row:Destroy() end,
    }
end

-- ProgressBar -----------------------------------------------------------------
function Components.ProgressBar(parent, dispatcher, opts)
    opts = opts or {}
    local minV = opts.Min or 0
    local maxV = opts.Max or 100
    local val  = math.clamp(opts.Default or 0, minV, maxV)

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
        Size   = UDim2.new((val - minV) / (maxV - minV), 0, 1, 0),
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
            tween(fill, QUICK, { Size = UDim2.new((val - minV) / (maxV - minV), 0, 1, 0) })
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
        for _, o in ipairs(options) do
            if not filterText or filterText == ""
                or string.find(string.lower(tostring(o)), string.lower(filterText), 1, true) then
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
        scroll.Size = UDim2.new(1, 0, 0, math.min(#filtered, 5) * 28 + (math.min(#filtered, 5) - 1) * 2)
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

-- ColorPicker (HSV canvas + hue bar) ------------------------------------------
local function hsvToRgb(h, s, v)
    local c = Color3.fromHSV(h, s, v)
    return c
end

function Components.ColorPicker(parent, dispatcher, opts, saveHook)
    opts = opts or {}
    local default = opts.Default or Color3.fromRGB(120, 120, 255)
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
    UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        if draggingSV  then updateSV(input)  end
        if draggingHue then updateHue(input) end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            draggingSV  = false
            draggingHue = false
        end
    end)

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

    makeDraggable(titlebar, root, bag)

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

    -- Hotkey toggle (cancel-token safe)
    local visible = true
    local toggleToken = 0
    if opts.Keybind then
        bag:Add(UserInputService.InputBegan:Connect(function(input, processed)
            if processed then return end
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
            local c = Components.ColorPicker(page, dispatcher, o, hook)
            if o and o.Flag and configData[o.Flag] then
                local rgb = configData[o.Flag]
                c:Set(Color3.new(rgb[1], rgb[2], rgb[3]))
            end
            table.insert(self._components, c); return c
        end

        function tab:Destroy()
            for _, c in ipairs(self._components) do pcall(c.Destroy, c) end
            page:Destroy()
            tabBtn:Destroy()
            for i, t in ipairs(Window._tabs) do
                if t == tab then table.remove(Window._tabs, i); break end
            end
        end

        return tab
    end

    table.insert(WaffleUI._windows, Window)
    return Window
end

return WaffleUI
