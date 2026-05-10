# WaffleUI v2

A modern, animated, feature-rich Roblox UI library in a single Lua file.

## What's new in v2

### Bug fixes
- **No more listener leaks.** Every subsystem (slider, keybind, drag, hotkey, resize) routes its `UserInputService` connections through a `ConnectionBag` that's disconnected on `Window:Destroy()`.
- **Subtitle layout fixed.** No longer reads `TextBounds` on frame 0; uses `AutomaticSize` + horizontal `UIListLayout`.
- **Notification slide no longer fights `UIListLayout`.** Uses padding animation instead of `Position`.
- **Hotkey toggle race fixed.** Uses a cancel token instead of racing `task.wait` against the visibility flag.
- **Dropdown `SetOptions` glitch fixed.** Collapses the list before rebuilding.

### New components
- **ColorPicker** (HSV canvas + hue bar)
- **MultiSelect** (checkbox-style multi-value dropdown)
- **RadioGroup**
- **Paragraph** (title + wrapped body, auto-height)
- **Divider**
- **ProgressBar**
- **Searchable dropdowns** (`Searchable = true`)

### New features
- **Live theme swap**: `Window:SetTheme("Midnight")` repaints every component
- **Three built-in themes**: `Dark`, `Light`, `Midnight` — plus custom tables
- **Tab search** in the sidebar
- **Window resize handle** (drag the bottom-right corner)
- **Ripple effect** on buttons
- **Notification severities**: `Info`, `Success`, `Warning`, `Error` — click to dismiss, explicit close button
- **Config save/load** via `ConfigFile = "MyHub.json"`. Set `Flag = "..."` on any component to persist it. Uses executor `writefile` when available, falls back to in-memory.
- `Window:SelectTab(name)` helper
- `component:Destroy()` on everything

## Files
- `src/UILibrary.lua` — the library (use as a `ModuleScript`)
- `src/Example.client.lua` — a demo `LocalScript` that exercises every component

## Quick start

```lua
local WaffleUI = require(script.Parent.UILibrary)

local Window = WaffleUI:CreateWindow({
    Title      = "My Hub",
    SubTitle   = "v1.0",
    Theme      = "Midnight",               -- Dark | Light | Midnight | table
    Keybind    = Enum.KeyCode.RightShift,  -- toggle visibility
    ConfigFile = "MyHub.json",             -- optional persistence
})

local Main = Window:CreateTab("Main", "rbxassetid://10734950309")

Main:AddSection("Player")
Main:AddSlider({ Text = "Speed", Min = 16, Max = 200, Default = 16,
                 Flag = "speed", Callback = print })
Main:AddToggle({ Text = "God Mode", Flag = "god", Callback = print })
Main:AddDropdown({ Text = "Weapon", Options = {"Sword","Gun","Bow"},
                   Searchable = true, Flag = "weapon", Callback = print })
Main:AddColorPicker({ Text = "Tint", Default = Color3.new(1, 0.5, 0.2),
                      Flag = "tint", Callback = print })

WaffleUI:Notify({ Title = "Loaded", Text = "Welcome!", Severity = "Success" })
```

## Component reference

| Method | Purpose |
|---|---|
| `tab:AddSection(text)` | Uppercase header |
| `tab:AddLabel(text)` | Single-line label |
| `tab:AddParagraph{Title, Text}` | Auto-height boxed paragraph |
| `tab:AddDivider()` | 1px horizontal rule |
| `tab:AddButton{Text, Callback}` | Button with hover + ripple |
| `tab:AddToggle{Text, Default, Flag, Callback}` | Animated switch |
| `tab:AddSlider{Text, Min, Max, Default, Increment, Format, Flag, Callback}` | Snap slider (mouse + touch) |
| `tab:AddProgress{Text, Min, Max, Default}` | Read-only progress bar |
| `tab:AddDropdown{Text, Options, Default, Searchable, Flag, Callback}` | Single-select (optional search) |
| `tab:AddMultiSelect{Text, Options, Default, Flag, Callback}` | Multi-value dropdown |
| `tab:AddRadioGroup{Text, Options, Default, Flag, Callback}` | Exclusive radio |
| `tab:AddTextbox{Text, Placeholder, Default, Numeric, Flag, Callback}` | Text input, optional numeric filter |
| `tab:AddKeybind{Text, Default, Flag, Callback}` | Rebindable key (`Esc` to clear) |
| `tab:AddColorPicker{Text, Default, Flag, Callback}` | HSV canvas + hue |

Every component returns an API with `:Set`, `:Get` (where applicable), and `:Destroy`.

## Custom themes

```lua
Window:SetTheme({
    Background   = Color3.fromRGB(18, 18, 22),
    Surface      = Color3.fromRGB(28, 28, 34),
    Elevated     = Color3.fromRGB(40, 40, 48),
    Stroke       = Color3.fromRGB(70, 70, 80),
    Primary      = Color3.fromRGB(255, 120, 200),
    PrimaryHover = Color3.fromRGB(255, 150, 215),
    Text         = Color3.fromRGB(240, 240, 245),
    SubText      = Color3.fromRGB(170, 170, 180),
    Accent       = Color3.fromRGB(120, 220, 160),
    Warning      = Color3.fromRGB(240, 180, 70),
    Danger       = Color3.fromRGB(230, 90, 90),
})
```
