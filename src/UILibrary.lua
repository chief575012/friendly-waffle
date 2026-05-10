--[[
    WaffleUI
    A modern, animated, feature-rich Roblox UI library.

    Usage (LocalScript in StarterPlayerScripts or StarterGui):
        local WaffleUI = require(path.to.UILibrary)

        local Window = WaffleUI:CreateWindow({
            Title     = "Waffle Hub",
            SubTitle  = "v1.0.0",
            Keybind   = Enum.KeyCode.RightShift,
            Theme     = "Dark", -- "Dark" | "Light" | table
        })

        local Main = Window:CreateTab("Main", "rbxassetid://10734950309")

        Main:AddLabel("Welcome to Waffle Hub")
        Main:AddButton({ Text = "Print Hello", Callback = function() print("hi") end })
        Main:AddToggle({ Text = "Infinite Jump", Default = false, Callback = function(v) print(v) end })
        Main:AddSlider({ Text = "WalkSpeed", Min = 16, Max = 250, Default = 16, Increment = 1,
                         Callback = function(v) print(v) end })
        Main:AddDropdown({ Text = "Weapon", Options = {"Sword","Gun","Bow"}, Default = "Sword",
                           Callback = function(v) print(v) end })
        Main:AddTextbox({ Text = "Message", Placeholder = "Type...",
                           Callback = function(s) print(s) end })
        Main:AddKeybind({ Text = "Panic Key", Default = Enum.KeyCode.P,
                           Callback = function() print("panic") end })

        WaffleUI:Notify({ Title = "Loaded", Text = "Enjoy!", Duration = 4 })

    Supports:
      - Draggable, resizable-safe windows (mobile + desktop)
      - Tabs with smooth transitions
      - Buttons, Toggles, Sliders, Dropdowns, Textboxes, Keybinds, Labels, Sections
      - Notifications (top-right stack)
      - Themes (Dark / Light / custom table)
      - Hotkey to toggle visibility
      - Safe-to-parent fallback (CoreGui -> PlayerGui)
]]

--==============================================================
--  Services
--==============================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui          = game:GetService("CoreGui")
local HttpService      = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer and LocalPlayer:WaitForChild("PlayerGui")

--==============================================================
--  Themes
--==============================================================
local Themes = {
    Dark = {
        Background     = Color3.fromRGB(24, 24, 28),
        Surface        = Color3.fromRGB(32, 32, 38),
        Elevated       = Color3.fromRGB(42, 42, 50),
        Stroke         = Color3.fromRGB(60, 60, 70),
        Primary        = Color3.fromRGB(120, 120, 255),
        PrimaryHover   = Color3.fromRGB(140, 140, 255),
        Text           = Color3.fromRGB(235, 235, 240),
        SubText        = Color3.fromRGB(170, 170, 180),
        Accent         = Color3.fromRGB(90, 200, 140),
        Danger         = Color3.fromRGB(230, 90, 90),
    },
    Light = {
        Background     = Color3.fromRGB(240, 240, 245),
        Surface        = Color3.fromRGB(255, 255, 255),
        Elevated       = Color3.fromRGB(250, 250, 252),
        Stroke         = Color3.fromRGB(210, 210, 220),
        Primary        = Color3.fromRGB(80, 100, 240),
        PrimaryHover   = Color3.fromRGB(100, 120, 255),
        Text           = Color3.fromRGB(25, 25, 30),
        SubText        = Color3.fromRGB(110, 110, 120),
        Accent         = Color3.fromRGB(30, 160, 100),
        Danger         = Color3.fromRGB(220, 70, 70),
    },
}

--==============================================================
--  Helpers
--==============================================================
local function new(className, props, children)
    local inst = Instance.new(className)
    if props then
        for k, v in pairs(props) do
            if k ~= "Parent" then
                inst[k] = v
            end
        end
        if props.Parent then
            inst.Parent = props.Parent
        end
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

local function stroke(color, thickness, parent)
    return new("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        Parent = parent,
    })
end

local function padding(px, parent)
    return new("UIPadding", {
        PaddingTop    = UDim.new(0, px),
        PaddingBottom = UDim.new(0, px),
        PaddingLeft   = UDim.new(0, px),
        PaddingRight  = UDim.new(0, px),
        Parent        = parent,
    })
end

local function tween(obj, info, goal)
    local t = TweenService:Create(obj, info, goal)
    t:Play()
    return t
end

local QUICK  = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MEDIUM = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SPRING = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local function tryParentToCoreGui(gui)
    local ok = pcall(function() gui.Parent = CoreGui end)
    if not ok then
        gui.Parent = PlayerGui
    end
end

--==============================================================
--  Library
--==============================================================
local WaffleUI = {}
WaffleUI.__index = WaffleUI
WaffleUI._windows = {}
WaffleUI._notifyStack = nil

--==============================================================
--  Notifications
--==============================================================
local function ensureNotifyStack(theme)
    if WaffleUI._notifyStack and WaffleUI._notifyStack.Parent then
        return WaffleUI._notifyStack
    end
    local screen = new("ScreenGui", {
        Name = "WaffleUI_Notifications",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 1000,
    })
    tryParentToCoreGui(screen)

    local stack = new("Frame", {
        Name = "Stack",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -16, 0, 16),
        Size = UDim2.new(0, 300, 1, -32),
        BackgroundTransparency = 1,
        Parent = screen,
    })
    new("UIListLayout", {
        Padding = UDim.new(0, 10),
        SortOrder = Enum.SortOrder.LayoutOrder,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Parent = stack,
    })
    WaffleUI._notifyStack = stack
    return stack
end

function WaffleUI:Notify(opts)
    opts = opts or {}
    local title    = opts.Title or "Notification"
    local text     = opts.Text  or ""
    local duration = opts.Duration or 4
    local theme    = (self._activeTheme) or Themes.Dark

    local stack = ensureNotifyStack(theme)

    local card = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = theme.Surface,
        BackgroundTransparency = 0,
        Parent = stack,
        ClipsDescendants = true,
    })
    corner(10, card)
    stroke(theme.Stroke, 1, card)
    padding(12, card)

    local layout = new("UIListLayout", {
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = card,
    })

    local bar = new("Frame", {
        Size = UDim2.new(0, 3, 1, 0),
        Position = UDim2.new(0, -9, 0, 0),
        BackgroundColor3 = theme.Primary,
        BorderSizePixel = 0,
        Parent = card,
    })
    corner(2, bar)

    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = title,
        Parent = card,
    })
    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextColor3 = theme.SubText,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = text,
        Parent = card,
    })

    -- Slide in
    card.Position = UDim2.new(1, 40, 0, 0)
    card.BackgroundTransparency = 1
    tween(card, MEDIUM, { Position = UDim2.new(0, 0, 0, 0), BackgroundTransparency = 0 })

    task.delay(duration, function()
        if not card.Parent then return end
        tween(card, QUICK, { BackgroundTransparency = 1, Position = UDim2.new(1, 40, 0, 0) })
        task.wait(0.2)
        card:Destroy()
    end)
end

--==============================================================
--  Component factories (used by Tab API)
--==============================================================
local Components = {}

function Components.Section(parent, theme, text)
    local holder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        Parent = parent,
    })
    new("TextLabel", {
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = theme.SubText,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = string.upper(text or "SECTION"),
        Parent = holder,
    })
    return holder
end

function Components.Label(parent, theme, text)
    local label = new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 22),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 14,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = text or "",
        Parent = parent,
    })
    local api = {}
    function api:Set(newText) label.Text = newText end
    return api
end

function Components.Button(parent, theme, opts)
    opts = opts or {}
    local btn = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = theme.Elevated,
        Text = opts.Text or "Button",
        TextColor3 = theme.Text,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        AutoButtonColor = false,
        Parent = parent,
    })
    corner(8, btn)
    stroke(theme.Stroke, 1, btn)

    btn.MouseEnter:Connect(function()
        tween(btn, QUICK, { BackgroundColor3 = theme.Primary })
    end)
    btn.MouseLeave:Connect(function()
        tween(btn, QUICK, { BackgroundColor3 = theme.Elevated })
    end)
    btn.MouseButton1Click:Connect(function()
        -- click pulse
        tween(btn, TweenInfo.new(0.08), { BackgroundColor3 = theme.PrimaryHover })
        task.wait(0.08)
        tween(btn, QUICK, { BackgroundColor3 = theme.Primary })
        if opts.Callback then
            task.spawn(opts.Callback)
        end
    end)
    return btn
end

function Components.Toggle(parent, theme, opts)
    opts = opts or {}
    local state = opts.Default and true or false

    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = theme.Elevated,
        Parent = parent,
    })
    corner(8, row)
    stroke(theme.Stroke, 1, row)

    new("TextLabel", {
        Size = UDim2.new(1, -60, 1, 0),
        Position = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.Text or "Toggle",
        Parent = row,
    })

    local track = new("TextButton", {
        Size = UDim2.new(0, 38, 0, 20),
        Position = UDim2.new(1, -48, 0.5, -10),
        BackgroundColor3 = theme.Stroke,
        Text = "",
        AutoButtonColor = false,
        Parent = row,
    })
    corner(10, track)

    local knob = new("Frame", {
        Size = UDim2.new(0, 16, 0, 16),
        Position = UDim2.new(0, 2, 0.5, -8),
        BackgroundColor3 = theme.Text,
        Parent = track,
    })
    corner(8, knob)

    local function render()
        if state then
            tween(track, QUICK, { BackgroundColor3 = theme.Primary })
            tween(knob, QUICK, { Position = UDim2.new(1, -18, 0.5, -8) })
        else
            tween(track, QUICK, { BackgroundColor3 = theme.Stroke })
            tween(knob, QUICK, { Position = UDim2.new(0, 2, 0.5, -8) })
        end
    end
    render()

    local function set(v)
        state = v and true or false
        render()
        if opts.Callback then task.spawn(opts.Callback, state) end
    end

    track.MouseButton1Click:Connect(function() set(not state) end)

    local api = {}
    function api:Set(v) set(v) end
    function api:Get() return state end
    return api
end

function Components.Slider(parent, theme, opts)
    opts = opts or {}
    local minV = opts.Min or 0
    local maxV = opts.Max or 100
    local step = opts.Increment or 1
    local val  = math.clamp(opts.Default or minV, minV, maxV)

    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 52),
        BackgroundColor3 = theme.Elevated,
        Parent = parent,
    })
    corner(8, row)
    stroke(theme.Stroke, 1, row)
    padding(10, row)

    local title = new("TextLabel", {
        Size = UDim2.new(1, -50, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.Text or "Slider",
        Parent = row,
    })
    local valueText = new("TextLabel", {
        Size = UDim2.new(0, 50, 0, 18),
        Position = UDim2.new(1, -50, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = theme.Primary,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(val),
        Parent = row,
    })

    local bar = new("Frame", {
        Size = UDim2.new(1, 0, 0, 6),
        Position = UDim2.new(0, 0, 1, -10),
        BackgroundColor3 = theme.Stroke,
        Parent = row,
    })
    corner(3, bar)
    local fill = new("Frame", {
        Size = UDim2.new((val - minV) / (maxV - minV), 0, 1, 0),
        BackgroundColor3 = theme.Primary,
        Parent = bar,
    })
    corner(3, fill)

    local dragging = false
    local function updateFromX(x)
        local rel = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
        local raw = minV + rel * (maxV - minV)
        local snapped = math.floor((raw / step) + 0.5) * step
        snapped = math.clamp(snapped, minV, maxV)
        if snapped ~= val then
            val = snapped
            valueText.Text = tostring(val)
            tween(fill, TweenInfo.new(0.08), { Size = UDim2.new((val - minV) / (maxV - minV), 0, 1, 0) })
            if opts.Callback then task.spawn(opts.Callback, val) end
        end
    end

    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            updateFromX(input.Position.X)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                      or input.UserInputType == Enum.UserInputType.Touch) then
            updateFromX(input.Position.X)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    local api = {}
    function api:Set(v)
        val = math.clamp(v, minV, maxV)
        valueText.Text = tostring(val)
        fill.Size = UDim2.new((val - minV) / (maxV - minV), 0, 1, 0)
        if opts.Callback then task.spawn(opts.Callback, val) end
    end
    function api:Get() return val end
    return api
end

function Components.Dropdown(parent, theme, opts)
    opts = opts or {}
    local options = opts.Options or {}
    local selected = opts.Default or options[1]
    local open = false

    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = theme.Elevated,
        Parent = parent,
        ClipsDescendants = true,
    })
    corner(8, row)
    stroke(theme.Stroke, 1, row)

    local button = new("TextButton", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        Parent = row,
    })

    new("TextLabel", {
        Size = UDim2.new(1, -90, 1, 0),
        Position = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.Text or "Dropdown",
        Parent = row,
    })
    local valueLabel = new("TextLabel", {
        Size = UDim2.new(0, 80, 1, 0),
        Position = UDim2.new(1, -90, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = theme.Primary,
        TextXAlignment = Enum.TextXAlignment.Right,
        Text = tostring(selected or ""),
        Parent = row,
    })

    local list = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        Position = UDim2.new(0, 0, 0, 34),
        BackgroundTransparency = 1,
        Parent = row,
    })
    local listLayout = new("UIListLayout", {
        Padding = UDim.new(0, 2),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = list,
    })

    local function rebuild()
        for _, c in ipairs(list:GetChildren()) do
            if c:IsA("GuiButton") then c:Destroy() end
        end
        for _, optText in ipairs(options) do
            local item = new("TextButton", {
                Size = UDim2.new(1, -8, 0, 26),
                Position = UDim2.new(0, 4, 0, 0),
                BackgroundColor3 = theme.Surface,
                Font = Enum.Font.Gotham,
                TextSize = 13,
                TextColor3 = theme.Text,
                Text = tostring(optText),
                AutoButtonColor = false,
                Parent = list,
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
                if opts.Callback then task.spawn(opts.Callback, selected) end
            end)
        end
    end
    rebuild()

    button.MouseButton1Click:Connect(function()
        open = not open
        if open then
            local h = 34 + 4 + (#options * 28)
            tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, h) })
        else
            tween(row, MEDIUM, { Size = UDim2.new(1, 0, 0, 34) })
        end
    end)

    local api = {}
    function api:Set(v)
        selected = v
        valueLabel.Text = tostring(v)
        if opts.Callback then task.spawn(opts.Callback, selected) end
    end
    function api:Get() return selected end
    function api:SetOptions(t)
        options = t or {}
        rebuild()
    end
    return api
end

function Components.Textbox(parent, theme, opts)
    opts = opts or {}
    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = theme.Elevated,
        Parent = parent,
    })
    corner(8, row)
    stroke(theme.Stroke, 1, row)

    new("TextLabel", {
        Size = UDim2.new(0.4, -12, 1, 0),
        Position = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.Text or "Input",
        Parent = row,
    })

    local box = new("TextBox", {
        Size = UDim2.new(0.6, -12, 1, -10),
        Position = UDim2.new(0.4, 0, 0, 5),
        BackgroundColor3 = theme.Surface,
        Font = Enum.Font.Gotham,
        TextSize = 13,
        TextColor3 = theme.Text,
        PlaceholderText = opts.Placeholder or "Type here...",
        PlaceholderColor3 = theme.SubText,
        ClearTextOnFocus = false,
        Text = opts.Default or "",
        Parent = row,
    })
    corner(6, box)

    box.FocusLost:Connect(function(enterPressed)
        if opts.Callback then task.spawn(opts.Callback, box.Text, enterPressed) end
    end)

    local api = {}
    function api:Set(v) box.Text = tostring(v) end
    function api:Get() return box.Text end
    return api
end

function Components.Keybind(parent, theme, opts)
    opts = opts or {}
    local currentKey = opts.Default
    local capturing = false

    local row = new("Frame", {
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = theme.Elevated,
        Parent = parent,
    })
    corner(8, row)
    stroke(theme.Stroke, 1, row)

    new("TextLabel", {
        Size = UDim2.new(1, -100, 1, 0),
        Position = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.Text or "Keybind",
        Parent = row,
    })

    local keyBtn = new("TextButton", {
        Size = UDim2.new(0, 90, 1, -10),
        Position = UDim2.new(1, -95, 0, 5),
        BackgroundColor3 = theme.Surface,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = theme.Primary,
        AutoButtonColor = false,
        Text = currentKey and currentKey.Name or "None",
        Parent = row,
    })
    corner(6, keyBtn)

    keyBtn.MouseButton1Click:Connect(function()
        capturing = true
        keyBtn.Text = "..."
    end)

    UserInputService.InputBegan:Connect(function(input, processed)
        if capturing and input.UserInputType == Enum.UserInputType.Keyboard then
            capturing = false
            currentKey = input.KeyCode
            keyBtn.Text = currentKey.Name
            return
        end
        if not processed and currentKey and input.KeyCode == currentKey then
            if opts.Callback then task.spawn(opts.Callback) end
        end
    end)

    local api = {}
    function api:Set(k) currentKey = k; keyBtn.Text = k and k.Name or "None" end
    function api:Get() return currentKey end
    return api
end

--==============================================================
--  Window / Tab construction
--==============================================================
local function resolveTheme(t)
    if type(t) == "table" then return t end
    return Themes[t] or Themes.Dark
end

local function makeDraggable(handle, target)
    local dragging, startPos, startInput
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startInput = input.Position
            startPos = target.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
                      or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - startInput
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

function WaffleUI:CreateWindow(opts)
    opts = opts or {}
    local theme = resolveTheme(opts.Theme)
    self._activeTheme = theme

    local screen = new("ScreenGui", {
        Name = "WaffleUI_" .. HttpService:GenerateGUID(false):sub(1, 8),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 999,
    })
    tryParentToCoreGui(screen)

    local root = new("Frame", {
        Name = "Window",
        Size = UDim2.new(0, 560, 0, 360),
        Position = UDim2.new(0.5, -280, 0.5, -180),
        BackgroundColor3 = theme.Background,
        Parent = screen,
        ClipsDescendants = true,
    })
    corner(12, root)
    stroke(theme.Stroke, 1, root)

    -- open animation
    root.Size = UDim2.new(0, 0, 0, 0)
    root.Position = UDim2.new(0.5, 0, 0.5, 0)
    tween(root, SPRING, {
        Size = UDim2.new(0, 560, 0, 360),
        Position = UDim2.new(0.5, -280, 0.5, -180),
    })

    -- Titlebar
    local titlebar = new("Frame", {
        Size = UDim2.new(1, 0, 0, 38),
        BackgroundColor3 = theme.Surface,
        Parent = root,
    })
    corner(12, titlebar)
    new("Frame", { -- hide bottom corners on titlebar
        Size = UDim2.new(1, 0, 0, 12),
        Position = UDim2.new(0, 0, 1, -12),
        BackgroundColor3 = theme.Surface,
        BorderSizePixel = 0,
        Parent = titlebar,
    })

    local titleText = new("TextLabel", {
        Position = UDim2.new(0, 14, 0, 0),
        Size = UDim2.new(1, -120, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = opts.Title or "WaffleUI",
        Parent = titlebar,
    })
    if opts.SubTitle then
        new("TextLabel", {
            Position = UDim2.new(0, 14 + titleText.TextBounds.X + 6, 0, 0),
            Size = UDim2.new(0, 200, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextColor3 = theme.SubText,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = opts.SubTitle,
            Parent = titlebar,
        })
    end

    local function makeIconBtn(parentX, color, symbol, cb)
        local b = new("TextButton", {
            Size = UDim2.new(0, 24, 0, 24),
            Position = UDim2.new(1, parentX, 0.5, -12),
            BackgroundColor3 = theme.Elevated,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextColor3 = color,
            Text = symbol,
            AutoButtonColor = false,
            Parent = titlebar,
        })
        corner(6, b)
        b.MouseEnter:Connect(function() tween(b, QUICK, { BackgroundColor3 = theme.Stroke }) end)
        b.MouseLeave:Connect(function() tween(b, QUICK, { BackgroundColor3 = theme.Elevated }) end)
        b.MouseButton1Click:Connect(cb)
        return b
    end

    local minimized = false
    local savedSize = UDim2.new(0, 560, 0, 360)

    makeIconBtn(-32, theme.SubText, "-", function()
        minimized = not minimized
        if minimized then
            savedSize = root.Size
            tween(root, MEDIUM, { Size = UDim2.new(savedSize.X.Scale, savedSize.X.Offset, 0, 38) })
        else
            tween(root, MEDIUM, { Size = savedSize })
        end
    end)
    makeIconBtn(-62, theme.Danger, "x", function()
        tween(root, MEDIUM, { Size = UDim2.new(0, 0, 0, 0), Position = UDim2.new(0.5, 0, 0.5, 0) })
        task.wait(0.3)
        screen:Destroy()
    end)

    makeDraggable(titlebar, root)

    -- Body: left tab bar + content
    local body = new("Frame", {
        Position = UDim2.new(0, 0, 0, 38),
        Size = UDim2.new(1, 0, 1, -38),
        BackgroundTransparency = 1,
        Parent = root,
    })

    local tabBar = new("Frame", {
        Size = UDim2.new(0, 140, 1, 0),
        BackgroundColor3 = theme.Surface,
        Parent = body,
    })
    padding(10, tabBar)
    local tabLayout = new("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = tabBar,
    })

    local content = new("Frame", {
        Position = UDim2.new(0, 140, 0, 0),
        Size = UDim2.new(1, -140, 1, 0),
        BackgroundTransparency = 1,
        Parent = body,
    })

    -- Hotkey toggle
    if opts.Keybind then
        local visible = true
        UserInputService.InputBegan:Connect(function(input, processed)
            if processed then return end
            if input.KeyCode == opts.Keybind then
                visible = not visible
                if visible then
                    root.Visible = true
                    tween(root, MEDIUM, { BackgroundTransparency = 0 })
                else
                    tween(root, MEDIUM, { BackgroundTransparency = 1 })
                    task.wait(0.25)
                    if not visible then root.Visible = false end
                end
            end
        end)
    end

    local Window = {}
    Window._tabs = {}
    Window._active = nil
    Window._theme = theme

    function Window:CreateTab(name, icon)
        local tabBtn = new("TextButton", {
            Size = UDim2.new(1, 0, 0, 32),
            BackgroundColor3 = theme.Elevated,
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 14,
            TextColor3 = theme.SubText,
            Text = "  " .. (name or "Tab"),
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
            Parent = tabBar,
        })
        corner(6, tabBtn)

        if icon then
            local ok = pcall(function()
                local img = new("ImageLabel", {
                    Size = UDim2.new(0, 16, 0, 16),
                    Position = UDim2.new(0, 8, 0.5, -8),
                    BackgroundTransparency = 1,
                    Image = icon,
                    ImageColor3 = theme.SubText,
                    Parent = tabBtn,
                })
                tabBtn.Text = "        " .. (name or "Tab")
            end)
        end

        local page = new("ScrollingFrame", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 4,
            ScrollBarImageColor3 = theme.Stroke,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            Visible = false,
            Parent = content,
        })
        padding(14, page)
        new("UIListLayout", {
            Padding = UDim.new(0, 8),
            SortOrder = Enum.SortOrder.LayoutOrder,
            Parent = page,
        })

        local tab = { _btn = tabBtn, _page = page, _name = name }
        table.insert(Window._tabs, tab)

        local function activate()
            for _, t in ipairs(Window._tabs) do
                t._page.Visible = false
                tween(t._btn, QUICK, { BackgroundTransparency = 1, TextColor3 = theme.SubText })
                local img = t._btn:FindFirstChildOfClass("ImageLabel")
                if img then tween(img, QUICK, { ImageColor3 = theme.SubText }) end
            end
            page.Visible = true
            tween(tabBtn, QUICK, { BackgroundTransparency = 0, BackgroundColor3 = theme.Elevated, TextColor3 = theme.Text })
            local img = tabBtn:FindFirstChildOfClass("ImageLabel")
            if img then tween(img, QUICK, { ImageColor3 = theme.Primary }) end
            Window._active = tab
        end
        tabBtn.MouseButton1Click:Connect(activate)

        if #Window._tabs == 1 then activate() end

        -- Tab API
        function tab:AddSection(text)  return Components.Section(page, theme, text) end
        function tab:AddLabel(text)    return Components.Label(page, theme, text) end
        function tab:AddButton(o)      return Components.Button(page, theme, o) end
        function tab:AddToggle(o)      return Components.Toggle(page, theme, o) end
        function tab:AddSlider(o)      return Components.Slider(page, theme, o) end
        function tab:AddDropdown(o)    return Components.Dropdown(page, theme, o) end
        function tab:AddTextbox(o)     return Components.Textbox(page, theme, o) end
        function tab:AddKeybind(o)     return Components.Keybind(page, theme, o) end

        return tab
    end

    function Window:Destroy()
        tween(root, MEDIUM, { Size = UDim2.new(0, 0, 0, 0), Position = UDim2.new(0.5, 0, 0.5, 0) })
        task.wait(0.3)
        screen:Destroy()
    end

    function Window:Notify(o) WaffleUI:Notify(o) end

    table.insert(WaffleUI._windows, Window)
    return Window
end

return WaffleUI
