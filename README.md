# WaffleUI v3

A modern, animated, feature-rich Roblox UI library in a single Lua file.

## What's new in v3

### Notification — actually fixed
The v2 notification tried to slide with `UIPadding.PaddingLeft`, but `UIPadding` *shrinks content*, it doesn't translate it — the card compressed instead of sliding. v3 uses an anchored child inside a fixed wrap, animating `Position.X.Offset` for a true slide. Also adds:
- **Countdown progress bar** drains over `Duration`; hovering pauses it
- **Action buttons** (`Actions = { {Text, Callback, Primary, KeepOpen}, ... }`) for inline confirms
- Returns a **handle** with `:Dismiss`, `:Update(title, text)`, `:SetSeverity(sev)`
- Click close button OR anywhere on the card to dismiss

### More bug fixes
- Slider / ProgressBar: **divide-by-zero** when `Min == Max` (`range` guard)
- Dropdown: **`string.lower` crash** on numeric options (tostring first)
- Dropdown: negative row count when 0 options filtered
- Window drag: clamped to viewport — **you can't drag the window off-screen**
- Hotkey: **no longer swallows keystrokes** while a TextBox is focused
- Keybind: rejects modifier-only captures (LShift/Ctrl/Alt alone)
- Keybind: doesn't fire while a TextBox is focused
- Tab destroy: if you destroyed the active tab, the pane went blank — now auto-activates the next tab
- ColorPicker: leaked 2 global `UserInputService` listeners per instance — now routed through the bag

### New components
- **Stepper** — numeric input with `+/-` buttons (`tab:AddStepper`)
- **Console** — scrolling log pane with `:Log`, `:Warn`, `:Error`, `:Clear` and autoscroll-to-bottom
- **Tooltip** — hover tip via `tab:AttachTooltip(component, "text")`

### New window features
- `Window:Confirm{Title, Message, OnConfirm, OnCancel, ConfirmText, CancelText}` — blocking modal
- `Window:SetTitle(s)`, `:SetSubTitle(s)`, `:SetSize(w, h)`, `:SetPosition(x, y)`
- `Window:Show()`, `:Hide()` (programmatic counterparts to the hotkey)
- Fourth theme: **Ocean**

## Files
- `src/UILibrary.lua` — the library (use as a `ModuleScript`)
- `src/Example.client.lua` — a demo `LocalScript` that exercises every component

## Quick start

```lua
local WaffleUI = require(script.Parent.UILibrary)

local Window = WaffleUI:CreateWindow({
    Title      = "My Hub",
    SubTitle   = "v1.0",
    Theme      = "Ocean",                  -- Dark | Light | Midnight | Ocean | table
    Keybind    = Enum.KeyCode.RightShift,
    ConfigFile = "MyHub.json",
})

local Main = Window:CreateTab("Main", "rbxassetid://10734950309")

Main:AddSection("Player")
Main:AddSlider({ Text = "Speed", Min = 16, Max = 200, Default = 16,
                 Flag = "speed", Callback = print })
Main:AddStepper({ Text = "Level", Min = 1, Max = 99, Default = 1,
                  Flag = "level", Callback = print })
Main:AddToggle({ Text = "God Mode", Flag = "god", Callback = print })

Main:AddButton({
    Text = "Do Dangerous Thing",
    Callback = function()
        Window:Confirm({
            Title = "Proceed?",
            Message = "This cannot be undone.",
            OnConfirm = function() print("yes") end,
        })
    end,
})

local log = Main:AddConsole({ Text = "OUTPUT", Height = 140 })
log:Log("Ready")
log:Warn("Check something")
log:Error("Oops")

WaffleUI:Notify({
    Title = "Hello", Text = "Welcome!", Severity = "Success",
    Duration = 6,
    Actions = {
        { Text = "Got it", Primary = true, Callback = function() print("ok") end },
    },
})
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
| `tab:AddStepper{Text, Min, Max, Default, Increment, Format, Flag, Callback}` | **NEW** `+/-` numeric input |
| `tab:AddProgress{Text, Min, Max, Default}` | Read-only progress bar |
| `tab:AddDropdown{Text, Options, Default, Searchable, Flag, Callback}` | Single-select |
| `tab:AddMultiSelect{Text, Options, Default, Flag, Callback}` | Multi-value |
| `tab:AddRadioGroup{Text, Options, Default, Flag, Callback}` | Exclusive radio |
| `tab:AddTextbox{Text, Placeholder, Default, Numeric, Flag, Callback}` | Text input |
| `tab:AddKeybind{Text, Default, Flag, Callback}` | Rebindable key (Esc clears) |
| `tab:AddColorPicker{Text, Default, Flag, Callback}` | HSV canvas + hue |
| `tab:AddConsole{Text, Height, MaxLines}` | **NEW** Log pane (`:Log/:Warn/:Error/:Clear`) |
| `tab:AttachTooltip(component, text)` | **NEW** Hover tip |

## Window API

| Method | Purpose |
|---|---|
| `Window:CreateTab(name, icon)` | Add a new tab |
| `Window:SelectTab(name)` | Switch to tab by name |
| `Window:SetTheme(nameOrTable)` | Live theme swap |
| `Window:SetTitle(s)`, `:SetSubTitle(s)` | **NEW** update header text |
| `Window:SetSize(w, h)`, `:SetPosition(x, y)` | **NEW** programmatic layout |
| `Window:Show()`, `:Hide()` | **NEW** programmatic visibility |
| `Window:Notify(opts)` | Same as `WaffleUI:Notify` but themed to this window |
| `Window:Confirm{Title, Message, OnConfirm, OnCancel}` | **NEW** Yes/No modal |
| `Window:Destroy()` | Close + clean up all connections |

Every component returns `{ frame, Set, Get, Destroy, ... }`.
