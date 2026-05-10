--[[
    Example usage of WaffleUI.
    Place this as a LocalScript in StarterPlayer > StarterPlayerScripts.
    Place UILibrary.lua as a ModuleScript in the same folder (or adjust the require path).
]]

local UILibrary = require(script.Parent:WaitForChild("UILibrary"))

-- If you downloaded the module as a loadstring, you can also do:
-- local UILibrary = loadstring(game:HttpGet("https://raw.githubusercontent.com/.../UILibrary.lua"))()

local Window = UILibrary:CreateWindow({
    Title    = "Waffle Hub",
    SubTitle = "v1.0.0",
    Theme    = "Dark",
    Keybind  = Enum.KeyCode.RightShift, -- toggle UI on/off
})

-- MAIN TAB -----------------------------------------------------
local Main = Window:CreateTab("Main", "rbxassetid://10734950309")

Main:AddSection("Player")

Main:AddLabel("Tweak your character below")

Main:AddSlider({
    Text      = "WalkSpeed",
    Min       = 16,
    Max       = 250,
    Default   = 16,
    Increment = 1,
    Callback  = function(v)
        local char = game.Players.LocalPlayer.Character
        if char and char:FindFirstChildOfClass("Humanoid") then
            char.Humanoid.WalkSpeed = v
        end
    end,
})

Main:AddSlider({
    Text      = "JumpPower",
    Min       = 50,
    Max       = 500,
    Default   = 50,
    Increment = 5,
    Callback  = function(v)
        local char = game.Players.LocalPlayer.Character
        if char and char:FindFirstChildOfClass("Humanoid") then
            char.Humanoid.JumpPower = v
            char.Humanoid.UseJumpPower = true
        end
    end,
})

Main:AddToggle({
    Text    = "Infinite Jump",
    Default = false,
    Callback = function(state)
        getgenv = getgenv or function() return _G end
        getgenv().InfJumpEnabled = state
        if state and not getgenv().InfJumpConn then
            getgenv().InfJumpConn = game:GetService("UserInputService").JumpRequest:Connect(function()
                if getgenv().InfJumpEnabled then
                    local char = game.Players.LocalPlayer.Character
                    local hum  = char and char:FindFirstChildOfClass("Humanoid")
                    if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
                end
            end)
        end
    end,
})

Main:AddButton({
    Text = "Reset Character",
    Callback = function()
        local char = game.Players.LocalPlayer.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum.Health = 0 end
    end,
})

-- VISUALS TAB --------------------------------------------------
local Visuals = Window:CreateTab("Visuals", "rbxassetid://10747384394")

Visuals:AddSection("FOV & Effects")

Visuals:AddSlider({
    Text = "Camera FOV", Min = 70, Max = 120, Default = 70, Increment = 1,
    Callback = function(v) workspace.CurrentCamera.FieldOfView = v end,
})

Visuals:AddDropdown({
    Text = "Time of Day",
    Options = { "Morning", "Noon", "Sunset", "Night" },
    Default = "Noon",
    Callback = function(v)
        local Lighting = game:GetService("Lighting")
        local map = { Morning = "07:00:00", Noon = "12:00:00", Sunset = "18:00:00", Night = "22:00:00" }
        Lighting.TimeOfDay = map[v] or "12:00:00"
    end,
})

-- SETTINGS TAB -------------------------------------------------
local Settings = Window:CreateTab("Settings", "rbxassetid://10734898355")

Settings:AddTextbox({
    Text = "Nickname",
    Placeholder = "Enter a name...",
    Callback = function(text, enterPressed)
        if enterPressed then print("Nickname set to", text) end
    end,
})

Settings:AddKeybind({
    Text = "Panic Hide",
    Default = Enum.KeyCode.P,
    Callback = function()
        Window:Notify({ Title = "Panic", Text = "Keybind pressed!", Duration = 2 })
    end,
})

Settings:AddButton({
    Text = "Unload UI",
    Callback = function() Window:Destroy() end,
})

-- NOTIFY ON LOAD -----------------------------------------------
UILibrary:Notify({
    Title    = "Waffle Hub loaded",
    Text     = "Press Right Shift to toggle.",
    Duration = 5,
})
