# WaffleUI

A modern, animated Roblox UI library in a single Lua file.

## Features

- Draggable window with open/close/minimize animations
- Tab sidebar with icons and smooth active-state transitions
- Components:
  - Section headers
  - Labels
  - Buttons (hover + click pulse)
  - Toggles (animated switch)
  - Sliders (snap + drag, mouse + touch)
  - Dropdowns (expand/collapse)
  - Textboxes
  - Keybinds (capture a key, then fire callback)
- Notifications (top-right stack with slide-in/out)
- Dark and Light themes, or pass a custom theme table
- Configurable hotkey to toggle UI visibility
- Auto-parents to `CoreGui` when possible, falls back to `PlayerGui`

## Files

- `src/UILibrary.lua` — the library (use as a `ModuleScript`)
- `src/Example.client.lua` — a demo `LocalScript` showing all components

## Quick start

Put both files in `StarterPlayer > StarterPlayerScripts`:

- `UILibrary` as a `ModuleScript`
- `Example` as a `LocalScript` next to it

Then run the game.

## Minimal example

```lua
local WaffleUI = require(script.Parent.UILibrary)

local Window = WaffleUI:CreateWindow({
    Title    = "My Hub",
    SubTitle = "v1.0",
    Theme    = "Dark",                 -- or "Light" or a table
    Keybind  = Enum.KeyCode.RightShift, -- toggle visibility
})

local Tab = Window:CreateTab("Main", "rbxassetid://10734950309")

Tab:AddSection("Player")
Tab:AddButton({ Text = "Hello", Callback = function() print("hi") end })
Tab:AddToggle({ Text = "Enable X", Default = false, Callback = print })
Tab:AddSlider({ Text = "Speed", Min = 16, Max = 200, Default = 16,
                Increment = 1, Callback = print })
Tab:AddDropdown({ Text = "Mode", Options = {"A","B","C"}, Default = "A",
                  Callback = print })
Tab:AddTextbox({ Text = "Name", Placeholder = "...", Callback = print })
Tab:AddKeybind({ Text = "Panic", Default = Enum.KeyCode.P,
                 Callback = function() print("panic") end })

WaffleUI:Notify({ Title = "Loaded", Text = "Welcome!", Duration = 4 })
```

## Custom theme

```lua
WaffleUI:CreateWindow({
    Title = "Custom",
    Theme = {
        Background   = Color3.fromRGB(18, 18, 22),
        Surface      = Color3.fromRGB(28, 28, 34),
        Elevated     = Color3.fromRGB(40, 40, 48),
        Stroke       = Color3.fromRGB(70, 70, 80),
        Primary      = Color3.fromRGB(255, 120, 200),
        PrimaryHover = Color3.fromRGB(255, 150, 215),
        Text         = Color3.fromRGB(240, 240, 245),
        SubText      = Color3.fromRGB(170, 170, 180),
        Accent       = Color3.fromRGB(120, 220, 160),
        Danger       = Color3.fromRGB(230, 90, 90),
    },
})
```
