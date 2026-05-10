--[[
    WaffleUI v3.0.0 — example usage.
    Place this as a LocalScript in StarterPlayer > StarterPlayerScripts, with
    UILibrary.lua next to it as a ModuleScript.
]]

local UILibrary = require(script.Parent:WaitForChild("UILibrary"))

local Window = UILibrary:CreateWindow({
    Title      = "Waffle Hub",
    SubTitle   = "v3.0.0",
    Theme      = "Midnight",
    Keybind    = Enum.KeyCode.RightShift,
    ConfigFile = "WaffleHub.json",
})

-- ========= MAIN =========
local Main = Window:CreateTab("Main", "rbxassetid://10734950309")

Main:AddSection("Player")
Main:AddParagraph({
    Title = "Welcome",
    Text  = "Drag the window, type in the tab search, resize from the bottom-right. Flagged settings persist.",
})

local speed = Main:AddSlider({
    Text = "WalkSpeed", Min = 16, Max = 250, Default = 16, Increment = 1,
    Flag = "walkspeed",
    Callback = function(v)
        local c = game.Players.LocalPlayer.Character
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if h then h.WalkSpeed = v end
    end,
})
Main:AttachTooltip(speed, "Drag or click the bar")

Main:AddStepper({
    Text = "Jump Power", Min = 50, Max = 500, Increment = 10, Default = 50,
    Flag = "jumppower",
    Callback = function(v)
        local c = game.Players.LocalPlayer.Character
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if h then h.JumpPower = v; h.UseJumpPower = true end
    end,
})

Main:AddToggle({
    Text = "Infinite Jump", Default = false, Flag = "infjump",
    Callback = function(state) print("InfJump:", state) end,
})

Main:AddButton({
    Text = "Reset Character (confirm)",
    Callback = function()
        Window:Confirm({
            Title   = "Reset character?",
            Message = "Your current state will be lost. Continue?",
            ConfirmText = "Reset",
            OnConfirm = function()
                local c = game.Players.LocalPlayer.Character
                local h = c and c:FindFirstChildOfClass("Humanoid")
                if h then h.Health = 0 end
            end,
        })
    end,
})

-- ========= LOG =========
local LogTab = Window:CreateTab("Log", "rbxassetid://10734898355")
LogTab:AddSection("Console")
local console = LogTab:AddConsole({ Text = "OUTPUT", Height = 180, MaxLines = 300 })

LogTab:AddButton({ Text = "Log Info",  Callback = function() console:Log("Clicked at " .. os.date("%X")) end })
LogTab:AddButton({ Text = "Log Warn",  Callback = function() console:Warn("Something is suspicious") end })
LogTab:AddButton({ Text = "Log Error", Callback = function() console:Error("Boom!") end })

-- ========= VISUALS =========
local Visuals = Window:CreateTab("Visuals", "rbxassetid://10747384394")

Visuals:AddSection("Camera & Time")
Visuals:AddSlider({
    Text = "FOV", Min = 70, Max = 120, Default = 70, Increment = 1, Flag = "fov",
    Callback = function(v) workspace.CurrentCamera.FieldOfView = v end,
})
Visuals:AddDropdown({
    Text       = "Time of Day",
    Options    = { "Morning", "Noon", "Sunset", "Night" },
    Default    = "Noon",
    Flag       = "tod",
    Searchable = true,
    Callback = function(v)
        local L = game:GetService("Lighting")
        local map = { Morning = "07:00:00", Noon = "12:00:00", Sunset = "18:00:00", Night = "22:00:00" }
        L.TimeOfDay = map[v] or "12:00:00"
    end,
})

Visuals:AddColorPicker({
    Text = "Highlight", Default = Color3.fromRGB(120, 200, 255), Flag = "hl_color",
    Callback = function(c) print("color:", c) end,
})

-- ========= SETTINGS =========
local Settings = Window:CreateTab("Settings")

Settings:AddDropdown({
    Text = "Theme", Options = { "Dark", "Light", "Midnight", "Ocean" },
    Default = "Midnight", Searchable = true, Flag = "theme",
    Callback = function(v) Window:SetTheme(v) end,
})
Settings:AddButton({
    Text = "Notify With Actions",
    Callback = function()
        Window:Notify({
            Title    = "Confirm action",
            Text     = "This demonstrates notification action buttons.",
            Severity = "Warning",
            Duration = 10,
            Actions = {
                { Text = "Yes", Primary = true,  Callback = function() print("yes") end },
                { Text = "No",                    Callback = function() print("no")  end },
            },
        })
    end,
})
Settings:AddButton({
    Text = "Unload UI",
    Callback = function() Window:Destroy() end,
})

-- Notify on load (with severity + countdown bar)
UILibrary:Notify({
    Title    = "Waffle Hub v3 loaded",
    Text     = "Press Right Shift to toggle the menu.",
    Severity = "Success",
    Duration = 6,
})
