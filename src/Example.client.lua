--[[
    WaffleUI v2.0.0 — example usage.
    Place this as a LocalScript in StarterPlayer > StarterPlayerScripts, with
    UILibrary.lua next to it as a ModuleScript.
]]

local UILibrary = require(script.Parent:WaitForChild("UILibrary"))

local Window = UILibrary:CreateWindow({
    Title      = "Waffle Hub",
    SubTitle   = "v2.0.0",
    Theme      = "Dark",
    Keybind    = Enum.KeyCode.RightShift,
    ConfigFile = "WaffleHub.json", -- persisted via writefile on supported execs
})

-- ========= MAIN =========
local Main = Window:CreateTab("Main", "rbxassetid://10734950309")

Main:AddSection("Player")
Main:AddParagraph({
    Title = "Welcome",
    Text  = "Tweak your character here. Settings marked with a Flag are saved automatically.",
})

Main:AddSlider({
    Text = "WalkSpeed", Min = 16, Max = 250, Default = 16, Increment = 1,
    Flag = "walkspeed",
    Callback = function(v)
        local c = game.Players.LocalPlayer.Character
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if h then h.WalkSpeed = v end
    end,
})

Main:AddSlider({
    Text = "JumpPower", Min = 50, Max = 500, Default = 50, Increment = 5,
    Flag = "jumppower",
    Callback = function(v)
        local c = game.Players.LocalPlayer.Character
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if h then h.JumpPower = v; h.UseJumpPower = true end
    end,
})

Main:AddToggle({
    Text = "Infinite Jump", Default = false, Flag = "infjump",
    Callback = function(state)
        getgenv = getgenv or function() return _G end
        getgenv().InfJumpEnabled = state
        if state and not getgenv().InfJumpConn then
            getgenv().InfJumpConn = game:GetService("UserInputService").JumpRequest:Connect(function()
                if getgenv().InfJumpEnabled then
                    local c = game.Players.LocalPlayer.Character
                    local h = c and c:FindFirstChildOfClass("Humanoid")
                    if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
                end
            end)
        end
    end,
})

Main:AddButton({
    Text = "Reset Character",
    Callback = function()
        local c = game.Players.LocalPlayer.Character
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if h then h.Health = 0 end
    end,
})

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
    Searchable = false,
    Callback = function(v)
        local L = game:GetService("Lighting")
        local map = { Morning = "07:00:00", Noon = "12:00:00", Sunset = "18:00:00", Night = "22:00:00" }
        L.TimeOfDay = map[v] or "12:00:00"
    end,
})

Visuals:AddSection("Pick & Mix")
Visuals:AddColorPicker({
    Text = "Highlight Color", Default = Color3.fromRGB(120, 200, 255), Flag = "hl_color",
    Callback = function(c) print("color:", c) end,
})
Visuals:AddMultiSelect({
    Text    = "Effects",
    Options = { "Bloom", "Blur", "ColorCorrection", "DepthOfField", "SunRays" },
    Default = { "Bloom", "ColorCorrection" },
    Flag    = "effects",
    Callback = function(list) print("fx:", table.concat(list, ", ")) end,
})
Visuals:AddRadioGroup({
    Text    = "Render Mode",
    Options = { "Quality", "Balanced", "Performance" },
    Default = "Balanced",
    Flag    = "render_mode",
    Callback = print,
})

Visuals:AddDivider()
Visuals:AddProgress({ Text = "Loading Demo", Min = 0, Max = 100, Default = 35 })

-- ========= SETTINGS =========
local Settings = Window:CreateTab("Settings", "rbxassetid://10734898355")

Settings:AddSection("Library")
Settings:AddDropdown({
    Text       = "Theme",
    Options    = { "Dark", "Light", "Midnight" },
    Default    = "Dark",
    Searchable = true,
    Flag       = "theme",
    Callback = function(v) Window:SetTheme(v) end,
})
Settings:AddTextbox({
    Text = "Nickname", Placeholder = "Enter...", Flag = "nickname",
    Callback = function(text, enter)
        if enter then Window:Notify({
            Title = "Saved", Text = "Nickname: " .. text,
            Severity = "Success", Duration = 3,
        }) end
    end,
})
Settings:AddKeybind({
    Text = "Panic Hide", Default = Enum.KeyCode.P, Flag = "panic_key",
    Callback = function() Window:Notify({ Title = "Panic!", Severity = "Warning" }) end,
})
Settings:AddButton({
    Text = "Unload UI",
    Callback = function() Window:Destroy() end,
})

-- Notify once on load
UILibrary:Notify({
    Title    = "Waffle Hub loaded",
    Text     = "Press Right Shift to toggle the menu.",
    Severity = "Success",
    Duration = 5,
})
