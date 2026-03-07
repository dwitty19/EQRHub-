--[[
╔══════════════════════════════════════════════════════════════╗
║           EQR Hub  v2.1  ─  Criminality  (Public)          ║
║         By helloitsme#4243  |  Built for Dwitty19           ║
╠══════════════════════════════════════════════════════════════╣
║  Features: Autofarm, Aimbot, Ragebot, Melee Aura, ESP,     ║
║  Invisibility, Shadow, Fly, Noclip, No Recoil, High Jump,  ║
║  Auto-ATM Deposit, Respawn Timers, Target Priority,         ║
║  Milestone Alerts, Auto Server-Hop, Loot History Log        ║
╚══════════════════════════════════════════════════════════════╝
  DELETE key = panic kill-switch (disables everything)
  RightAlt   = toggle UI
]]

-- ════════════════════════════════════════════════════════════
--  ANTI-IDLE
-- ════════════════════════════════════════════════════════════
local VirtualUser = game:GetService("VirtualUser")
do
    local lp = game:GetService("Players").LocalPlayer
    if lp then
        lp.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end

-- ════════════════════════════════════════════════════════════
--  SERVICES
-- ════════════════════════════════════════════════════════════
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting          = game:GetService("Lighting")
local LocalPlayer       = Players.LocalPlayer
local PlayerGui         = LocalPlayer:WaitForChild("PlayerGui")

-- ════════════════════════════════════════════════════════════
--  SHARED STATE
-- ════════════════════════════════════════════════════════════
local CoolDowns        = { AutoPickUps = { MoneyCooldown = false } }
local Settings         = { IsDead = false }
local autofarmEnabled  = false
local autofarmCooldown = false
local ignoredSafes     = {}
local isPingHigh       = false
local pingThreshold    = 150
local panicActive      = false

-- Autofarm behaviour options
local TargetPriority   = "Nearest"    -- "Nearest" | "BigSafeFirst" | "RegisterFirst"
local AutoHop_Enabled  = false        -- hop server when map is fully depleted

-- ════════════════════════════════════════════════════════════
--  FARM STATS  (declared early — every module references this)
-- ════════════════════════════════════════════════════════════
local FarmStats = {
    SafesCracked      = 0,
    BigSafesCracked   = 0,
    RegistersCracked  = 0,
    BreadCollected    = 0,
    EarnedDollars     = 0,
    SessionStart      = os.time(),
    LastAction        = "Idle",
    CrowbarsBought    = 0,
    PeakEarnRate      = 0,
    Deaths            = 0,
    GoalDollars       = 10000,
    GoalReached       = false,
    LootLog           = {},
    MilestonesHit     = {},
}

local MILESTONES = {1000, 5000, 10000, 25000, 50000, 100000}

local function pushLootLog(entry)
    table.insert(FarmStats.LootLog, 1, entry)
    if #FarmStats.LootLog > 8 then table.remove(FarmStats.LootLog) end
end

-- ── Real cash tracking ─────────────────────────────────────
local _cashBaseline   = nil
local _cashLastSample = nil

local function getPlayerCash()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        local c = ls:FindFirstChild("Cash") or ls:FindFirstChild("Money") or ls:FindFirstChild("$")
        if c and typeof(c.Value) == "number" then return c.Value end
    end
    local pd = LocalPlayer:FindFirstChild("PlayerData")
    if pd then
        local c = pd:FindFirstChild("Cash") or pd:FindFirstChild("Money")
        if c and typeof(c.Value) == "number" then return c.Value end
    end
    for _, v in ipairs(LocalPlayer:GetChildren()) do
        if v:IsA("NumberValue") or v:IsA("IntValue") then
            local n = v.Name:lower()
            if n=="cash" or n=="money" or n=="wallet" or n=="dollars" then return v.Value end
        end
    end
    return nil
end

local function updateCashTracking()
    local current = getPlayerCash()
    if not current then return end
    if not _cashBaseline then
        _cashBaseline = current; _cashLastSample = current; return
    end
    local delta = current - _cashLastSample
    if delta > 0 then FarmStats.EarnedDollars = FarmStats.EarnedDollars + delta end
    _cashLastSample = current
end

local function FarmStats_Reset()
    FarmStats.SafesCracked     = 0
    FarmStats.BigSafesCracked  = 0
    FarmStats.RegistersCracked = 0
    FarmStats.BreadCollected   = 0
    FarmStats.EarnedDollars    = 0
    FarmStats.SessionStart     = os.time()
    FarmStats.LastAction       = "Idle"
    FarmStats.CrowbarsBought   = 0
    FarmStats.PeakEarnRate     = 0
    FarmStats.Deaths           = 0
    FarmStats.GoalReached      = false
    FarmStats.LootLog          = {}
    FarmStats.MilestonesHit    = {}
    _cashBaseline   = getPlayerCash()
    _cashLastSample = _cashBaseline
end

-- ── Death counter ──────────────────────────────────────────
local function hookDeathCounter(char)
    local hum = char:WaitForChild("Humanoid", 5)
    if hum then
        hum.Died:Connect(function()
            FarmStats.Deaths = FarmStats.Deaths + 1
            FarmStats.LastAction = "💀 Died — respawning..."
        end)
    end
end
if LocalPlayer.Character then task.spawn(hookDeathCounter, LocalPlayer.Character) end
LocalPlayer.CharacterAdded:Connect(function(c) task.spawn(hookDeathCounter, c) end)

-- ════════════════════════════════════════════════════════════
--  PING CHECK
-- ════════════════════════════════════════════════════════════
task.spawn(function()
    while task.wait(5) do
        local ok, ms = pcall(function() return LocalPlayer:GetNetworkPing() * 1000 end)
        if ok then isPingHigh = ms > pingThreshold end
    end
end)

-- ════════════════════════════════════════════════════════════
--  AUTO ATM DEPOSIT
-- ════════════════════════════════════════════════════════════
local AutoDeposit_Enabled   = false
local AutoDeposit_Threshold = 400   -- deposit when in-hand cash exceeds this

local function findNearestATM()
    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local nearest, nearDist = nil, math.huge

    -- Search Map folder first (fast), then CoreGui containers, fall back to workspace root
    local searchRoots = {
        workspace:FindFirstChild("Map"),
        workspace:FindFirstChild("Filter"),
        workspace,
    }
    for _, root in ipairs(searchRoots) do
        if not root then continue end
        for _, obj in ipairs(root:GetDescendants()) do
            if obj:IsA("BasePart") then
                local n = obj.Name:lower()
                if n == "atm" or n == "atm_base" or n == "atmmachine" or n:find("^atm") then
                    local d = (hrp.Position - obj.Position).Magnitude
                    if d < nearDist then nearDist = d; nearest = obj end
                end
            end
        end
        if nearest then break end  -- stop once found in a closer scope
    end
    return nearest, nearDist
end

local function doATMDeposit()
    local atm = findNearestATM()
    if not atm then return false end
    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    -- Teleport to ATM
    hrp.CFrame = CFrame.new(atm.Position + Vector3.new(0, 3, 3))
    task.wait(0.8)
    -- Try known deposit remote names
    local evFolder = ReplicatedStorage:FindFirstChild("Events")
    if evFolder then
        for _, name in ipairs({"ATMDeposit","DepositMoney","ATMR","ATMEvent","BankDeposit","DPOSIT"}) do
            local rem = evFolder:FindFirstChild(name)
            if rem then
                pcall(function() rem:FireServer("deposit") end)
                task.wait(0.3)
                pcall(function() rem:InvokeServer("deposit") end)
            end
        end
    end
    -- Also try ATM's own events folder (some games store it on the model)
    if atm.Parent then
        for _, obj in ipairs(atm.Parent:GetDescendants()) do
            if obj:IsA("RemoteFunction") or obj:IsA("RemoteEvent") then
                local n = obj.Name:lower()
                if n:find("deposit") or n:find("bank") or n:find("atm") then
                    pcall(function() obj:FireServer("deposit") end)
                    pcall(function() obj:InvokeServer("deposit") end)
                end
            end
        end
    end
    FarmStats.LastAction = "🏧 Deposited at ATM"
    return true
end

-- Auto-deposit loop (runs independently of autofarm)
task.spawn(function()
    while task.wait(8) do
        if not AutoDeposit_Enabled then continue end
        local cash = getPlayerCash()
        if cash and cash >= AutoDeposit_Threshold then
            FarmStats.LastAction = "🏧 Auto-depositing cash..."
            pcall(doATMDeposit)
        end
    end
end)

-- ════════════════════════════════════════════════════════════
--  RESPAWN TIMER TRACKING
--  Tracks when each safe/register was cracked so we wait the
--  real respawn time before trying again (vs. blind ignore list)
-- ════════════════════════════════════════════════════════════
local RESPAWN_TIMES = {
    register = 10 * 60,   -- 10 minutes (wiki confirmed)
    safe     = 12 * 60,   -- 12 minutes
    bigsafe  = 12 * 60,   -- 12 minutes
}

local crackedTimestamps = {}  -- [modelRef] = {crackTime, kind}

local function markCracked(model, kind)
    crackedTimestamps[model] = { time = os.time(), kind = kind }
end

local function isOnCooldown(model)
    local entry = crackedTimestamps[model]
    if not entry then return false end
    local elapsed = os.time() - entry.time
    local respawn = RESPAWN_TIMES[entry.kind] or (12 * 60)
    return elapsed < respawn
end

local function cooldownRemaining(model)
    local entry = crackedTimestamps[model]
    if not entry then return 0 end
    local elapsed = os.time() - entry.time
    local respawn = RESPAWN_TIMES[entry.kind] or (12 * 60)
    return math.max(0, respawn - elapsed)
end

-- Periodically prune stale entries to avoid memory growth
task.spawn(function()
    while task.wait(120) do
        local now = os.time()
        for model, entry in pairs(crackedTimestamps) do
            if (now - entry.time) > 900 then   -- 15 min
                crackedTimestamps[model] = nil
            end
        end
    end
end)


-- ════════════════════════════════════════════════════════════
--  NO FAIL LOCKPICK
-- ════════════════════════════════════════════════════════════
local NoFailLockpick_Enabled  = false
local lockpickAddedConn       = nil

local function NoFailLockpick_Enable()
    if NoFailLockpick_Enabled then return end
    NoFailLockpick_Enabled = true
    local PG = LocalPlayer:FindFirstChild("PlayerGui"); if not PG then return end
    lockpickAddedConn = PG.ChildAdded:Connect(function(item)
        if item.Name ~= "LockpickGUI" then return end
        local mf     = item:WaitForChild("MF",      10); if not mf     then return end
        local lpf    = mf:WaitForChild("LP_Frame",  10); if not lpf    then return end
        local frames = lpf:WaitForChild("Frames",   10); if not frames then return end
        for _, bName in ipairs({"B1","B2","B3"}) do
            local b = frames:FindFirstChild(bName)
            if b and b:FindFirstChild("Bar") and b.Bar:FindFirstChild("UIScale") then
                b.Bar.UIScale.Scale = 10
            end
        end
    end)
end

local function NoFailLockpick_Disable()
    if not NoFailLockpick_Enabled then return end
    NoFailLockpick_Enabled = false
    if lockpickAddedConn then lockpickAddedConn:Disconnect(); lockpickAddedConn = nil end
    local lpg = PlayerGui:FindFirstChild("LockpickGUI")
    if not lpg then return end
    local mf = lpg:FindFirstChild("MF"); local lpf = mf and mf:FindFirstChild("LP_Frame")
    local frames = lpf and lpf:FindFirstChild("Frames")
    if frames then
        for _, bName in ipairs({"B1","B2","B3"}) do
            local b = frames:FindFirstChild(bName)
            if b and b:FindFirstChild("Bar") and b.Bar:FindFirstChild("UIScale") then
                b.Bar.UIScale.Scale = 1
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════
--  SAFE / REGISTER ESP  (BredMakurz billboard labels)
-- ════════════════════════════════════════════════════════════
local BredMakurz_Enabled   = false
local bredMakurzConn       = nil

local function cleanName(name)
    name = string.gsub(name, "([a-z])([A-Z])", "%1 %2")
    local u = string.find(name, "_"); if u then name = string.sub(name, 1, u-1) end
    return name
end

local function ApplyBredESP()
    local folder = workspace.Map:FindFirstChild("BredMakurz"); if not folder then return end
    local char   = LocalPlayer.Character; if not char then return end
    local hrp    = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local pp     = hrp.Position
    for _, v in pairs(folder:GetChildren()) do
        local oPos
        if v.PrimaryPart then oPos = v.PrimaryPart.Position
        else local p = v:FindFirstChildOfClass("BasePart"); if p then oPos = p.Position else continue end end

        local dist = (oPos - pp).Magnitude
        local eg   = v:FindFirstChild("EQR_ESP")

        if dist <= 250 then
            if not eg then
                -- ── build billboard ──────────────────────────────
                local bg = Instance.new("BillboardGui", v)
                bg.Name="EQR_ESP"; bg.AlwaysOnTop=true
                bg.Size=UDim2.new(10,0,4,0); bg.MaxDistance=250; bg.Adornee=v

                local frame = Instance.new("Frame", bg)
                frame.Size=UDim2.new(1,0,1,0)
                frame.BackgroundColor3=Color3.fromRGB(8,8,12)
                frame.BackgroundTransparency=0.3
                frame.BorderSizePixel=0
                Instance.new("UICorner", frame).CornerRadius=UDim.new(0,6)

                local stroke = Instance.new("UIStroke", frame)
                stroke.Thickness=1; stroke.Color=Color3.fromRGB(60,60,80); stroke.Transparency=0.4

                local nameLbl = Instance.new("TextLabel", frame)
                nameLbl.Size=UDim2.new(1,-8,0.58,0); nameLbl.Position=UDim2.new(0,4,0.04,0)
                nameLbl.BackgroundTransparency=1
                nameLbl.Font=Enum.Font.GothamBold; nameLbl.TextSize=15
                nameLbl.TextStrokeTransparency=0.5; nameLbl.TextXAlignment=Enum.TextXAlignment.Left

                local distLbl = Instance.new("TextLabel", frame)
                distLbl.Size=UDim2.new(1,-8,0.34,0); distLbl.Position=UDim2.new(0,4,0.62,0)
                distLbl.BackgroundTransparency=1
                distLbl.Font=Enum.Font.Gotham; distLbl.TextSize=12
                distLbl.TextColor3=Color3.fromRGB(160,160,180)
                distLbl.TextStrokeTransparency=0.6; distLbl.TextXAlignment=Enum.TextXAlignment.Left

                -- ── color + name by broken state ────────────────────────
                local vals   = v:FindFirstChild("Values")
                local broken = vals and vals:FindFirstChild("Broken")

                -- dollar range label by type
                local nm2 = v.Name:lower()
                local valueLabel
                if nm2:find("register") then valueLabel = "$80-$330"
                elseif nm2:find("big") or nm2:find("large") then valueLabel = "$200-$1,080"
                else valueLabel = "$120-$720" end

                local function updateColor()
                    local isBroken = broken and broken.Value
                    local isCooling = isOnCooldown(v)
                    nameLbl.Text = (isBroken and "✗ " or "✓ ") .. cleanName(v.Name)
                    if isBroken then
                        nameLbl.TextColor3 = Color3.fromRGB(255,70,70)
                        stroke.Color       = Color3.fromRGB(200,50,50)
                        distLbl.Text       = string.format("📍 %.0f st  |  broken", (LocalPlayer.Character and LocalPlayer.Character.HumanoidRootPart and (LocalPlayer.Character.HumanoidRootPart.Position-oPos).Magnitude) or 0)
                    elseif isCooling then
                        local rem = math.ceil(cooldownRemaining(v))
                        nameLbl.TextColor3 = Color3.fromRGB(255,180,0)
                        stroke.Color       = Color3.fromRGB(180,120,0)
                        distLbl.Text       = string.format("⏳ respawn %ds  |  %s", rem, valueLabel)
                    else
                        nameLbl.TextColor3 = Color3.fromRGB(60,255,110)
                        stroke.Color       = Color3.fromRGB(40,200,80)
                        distLbl.Text       = string.format("📍 %.0f st  |  %s", 0, valueLabel)
                    end
                end
                updateColor()
                if broken then
                    broken:GetPropertyChangedSignal("Value"):Connect(updateColor)
                end

                -- ── live distance + status (throttled, self-cleaning) ───
                local distConn
                distConn = RunService.Heartbeat:Connect(function()
                    if not BredMakurz_Enabled or not bg or not bg.Parent then
                        distConn:Disconnect(); return
                    end
                    local c2 = LocalPlayer.Character
                    local h2 = c2 and c2:FindFirstChild("HumanoidRootPart")
                    if not h2 then return end
                    local d2 = (h2.Position - oPos).Magnitude
                    local isBroken2  = broken and broken.Value
                    local isCooling2 = isOnCooldown(v)
                    if isBroken2 then
                        distLbl.Text = string.format("📍 %.0f st  |  broken", d2)
                    elseif isCooling2 then
                        local rem2 = math.ceil(cooldownRemaining(v))
                        distLbl.Text = string.format("⏳ respawn %ds  |  %s", rem2, valueLabel)
                    else
                        distLbl.Text = string.format("📍 %.0f st  |  %s", d2, valueLabel)
                    end
                end)
                -- Clean up when billboard is destroyed (e.g. BredMakurz_Disable)
                bg.Destroying:Connect(function() distConn:Disconnect() end)
            end
        elseif eg then
            eg:Destroy()
        end
    end
end

local _bredESP_last = 0

local function BredMakurz_Enable()
    if BredMakurz_Enabled then return end
    BredMakurz_Enabled = true
    ApplyBredESP()
    bredMakurzConn = RunService.Heartbeat:Connect(function()
        if not BredMakurz_Enabled then return end
        if (tick() - _bredESP_last) >= 1 then
            _bredESP_last = tick()
            ApplyBredESP()
        end
    end)
end

local function BredMakurz_Disable()
    if not BredMakurz_Enabled then return end
    BredMakurz_Enabled = false
    if bredMakurzConn then bredMakurzConn:Disconnect(); bredMakurzConn = nil end
    local folder = workspace.Map:FindFirstChild("BredMakurz")
    if folder then
        for _, v in pairs(folder:GetChildren()) do
            pcall(function() local e=v:FindFirstChild("EQR_ESP"); if e then e:Destroy() end end)
        end
    end
end

-- ════════════════════════════════════════════════════════════
--  NEARBY DOOR INTERACTIONS
-- ════════════════════════════════════════════════════════════
local OpenNearbyDoors_Enabled   = false
local UnlockNearbyDoors_Enabled = false
local DoorLoop_Task             = nil

local function DoorLoop()
    while OpenNearbyDoors_Enabled or UnlockNearbyDoors_Enabled do
        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health<=0 then task.wait(0.5); continue end
        local doorsF = workspace.Map:FindFirstChild("Doors")
        if not doorsF then task.wait(1); continue end
        local pp = hrp.Position
        for _, door in ipairs(doorsF:GetChildren()) do
            local base = door:FindFirstChild("DoorBase")
            local vals = door:FindFirstChild("Values")
            local evs  = door:FindFirstChild("Events")
            if not (base and vals and evs) then continue end
            if (pp - base.Position).Magnitude > 7 then continue end
            local tog = evs:FindFirstChild("Toggle"); if not tog then continue end
            if UnlockNearbyDoors_Enabled then
                local lk = vals:FindFirstChild("Locked"); local la = door:FindFirstChild("Lock")
                if lk and la and lk.Value then pcall(function() tog:FireServer("Unlock",la) end) end
            end
            if OpenNearbyDoors_Enabled then
                local op = vals:FindFirstChild("Open"); local kn = door:FindFirstChild("Knob2") or door:FindFirstChild("Knob")
                if op and kn and not op.Value then
                    local lk2 = vals:FindFirstChild("Locked")
                    if not lk2 or not lk2.Value then pcall(function() tog:FireServer("Open",kn) end) end
                end
            end
        end
        task.wait(0.25)
    end
    DoorLoop_Task = nil
end

local function StartDoorLoop()
    if (OpenNearbyDoors_Enabled or UnlockNearbyDoors_Enabled) and not DoorLoop_Task then
        DoorLoop_Task = task.spawn(DoorLoop)
    end
end

local function OpenNearbyDoors_Enable()   if OpenNearbyDoors_Enabled   then return end; OpenNearbyDoors_Enabled=true;   StartDoorLoop() end
local function OpenNearbyDoors_Disable()  if not OpenNearbyDoors_Enabled   then return end; OpenNearbyDoors_Enabled=false  end
local function UnlockNearbyDoors_Enable() if UnlockNearbyDoors_Enabled then return end; UnlockNearbyDoors_Enabled=true;  StartDoorLoop() end
local function UnlockNearbyDoors_Disable()if not UnlockNearbyDoors_Enabled then return end; UnlockNearbyDoors_Enabled=false end

-- ════════════════════════════════════════════════════════════
--  BREAD COLLECTOR
-- ════════════════════════════════════════════════════════════
local Collector_Enabled = false
local Collector_Signal  = nil

local function RunCollectorLogic()
    if not Collector_Enabled or Settings.IsDead then return end
    local breadF  = workspace.Filter:FindFirstChild("SpawnedBread")
    local pickupR = ReplicatedStorage.Events:FindFirstChild("CZDPZUS")
    if not breadF or not pickupR then return end
    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp or CoolDowns.AutoPickUps.MoneyCooldown then return end
    for _, item in ipairs(breadF:GetChildren()) do
        if (hrp.Position - item.Position).Magnitude < 5 and not CoolDowns.AutoPickUps.MoneyCooldown then
            CoolDowns.AutoPickUps.MoneyCooldown = true
            local ok = pcall(function() pickupR:FireServer(item) end)
            if ok then FarmStats.BreadCollected = FarmStats.BreadCollected + 1 end
            task.wait(1.0)
            CoolDowns.AutoPickUps.MoneyCooldown = false
            break
        end
    end
end

local function Collector_Activate()
    if Collector_Enabled then return end
    Collector_Enabled = true
    Collector_Signal = RunService.RenderStepped:Connect(RunCollectorLogic)
end

local function Collector_Deactivate()
    if not Collector_Enabled then return end
    Collector_Enabled = false
    if Collector_Signal then Collector_Signal:Disconnect(); Collector_Signal = nil end
    CoolDowns.AutoPickUps.MoneyCooldown = false
end

-- ════════════════════════════════════════════════════════════
--  FLY
-- ════════════════════════════════════════════════════════════
local Fly_Enabled = false; local Fly_Conn = nil; local Fly_Speed = 50

local function Fly_Enable()
    if Fly_Enabled then return end
    Fly_Enabled = true
    Fly_Conn = RunService.RenderStepped:Connect(function(dt)
        if not Fly_Enabled then return end
        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
        local cam  = workspace.CurrentCamera; local mv = Vector3.new()
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then mv = mv + cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then mv = mv - cam.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then mv = mv - cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then mv = mv + cam.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space)       then mv = mv + Vector3.new(0,1,0) end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then mv = mv - Vector3.new(0,1,0) end
        if mv.Magnitude > 0 then hrp.CFrame = hrp.CFrame + mv.Unit * Fly_Speed * dt end
    end)
end

local function Fly_Disable()
    if not Fly_Enabled then return end; Fly_Enabled = false
    if Fly_Conn then Fly_Conn:Disconnect(); Fly_Conn = nil end
end

-- ════════════════════════════════════════════════════════════
--  WALKSPEED — REMOVED
--  Criminality validates movement server-side. Any WalkSpeed
--  above ~18 causes the server to kill the character regardless
--  of how it is set client-side. Feature removed to prevent crashes.
-- ════════════════════════════════════════════════════════════
local WalkSpeed_Enabled = false  -- kept for PanicAll compatibility
local function WalkSpeed_Enable()  end
local function WalkSpeed_Disable() end

-- ── High Jump — velocity impulse on Space press (NOT JumpPower) ──
--    Applying JumpPower > ~180 every frame crashes the physics.
--    Instead we detect the jump input and fire a single upward
--    AssemblyLinearVelocity impulse. Safe, one-shot, no physics spiral.
local JumpConn = nil
local _jumpCooldown = false

local function JumpPower_Enable()
    if JumpPower_Enabled then return end
    JumpPower_Enabled = true

    JumpConn = UserInputService.InputBegan:Connect(function(inp, gpe)
        if gpe or not JumpPower_Enabled or _jumpCooldown then return end
        if inp.KeyCode ~= Enum.KeyCode.Space then return end

        local char = LocalPlayer.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum or hum.Health <= 0 then return end
        -- Only fire if standing on something (FloorMaterial ~= Air)
        if hum.FloorMaterial == Enum.Material.Air then return end

        _jumpCooldown = true

        -- Scale: 80 = small hop, 160 = very high. Capped at 180 to avoid crashes.
        local force = math.clamp(JumpPower_Value, 50, 180)

        -- Apply once — replace Y velocity only so horizontal movement is unaffected
        local vel = hrp.AssemblyLinearVelocity
        hrp.AssemblyLinearVelocity = Vector3.new(vel.X, force, vel.Z)

        task.delay(0.4, function() _jumpCooldown = false end)
    end)
end

local function JumpPower_Disable()
    if not JumpPower_Enabled then return end
    JumpPower_Enabled = false
    if JumpConn then JumpConn:Disconnect(); JumpConn = nil end
    _jumpCooldown = false
end

-- ════════════════════════════════════════════════════════════
--  FULLBRIGHT
-- ════════════════════════════════════════════════════════════
local FullBright_Enabled = false; local FullBright_Conn = nil
local OriginalLighting = {
    ClockTime=Lighting.ClockTime, Brightness=Lighting.Brightness,
    Ambient=Lighting.Ambient, OutdoorAmbient=Lighting.OutdoorAmbient,
    ColorShift_Top=Lighting.ColorShift_Top, FogStart=Lighting.FogStart, FogEnd=Lighting.FogEnd,
}

local function FullBright_Enable()
    if FullBright_Enabled then return end; FullBright_Enabled=true
    Lighting.Brightness=5; Lighting.ClockTime=14
    Lighting.Ambient=Color3.new(1,1,1); Lighting.OutdoorAmbient=Color3.new(1,1,1)
    Lighting.ColorShift_Top=Color3.new(0,0,0); Lighting.FogStart=1e5; Lighting.FogEnd=1e5
    FullBright_Conn = RunService.RenderStepped:Connect(function()
        if not FullBright_Enabled then FullBright_Conn:Disconnect(); return end
        if Lighting.Brightness~=5  then Lighting.Brightness=5 end
        if Lighting.ClockTime~=14  then Lighting.ClockTime=14 end
        if Lighting.FogStart~=1e5  then Lighting.FogStart=1e5 end
        if Lighting.FogEnd~=1e5    then Lighting.FogEnd=1e5 end
    end)
end

local function FullBright_Disable()
    if not FullBright_Enabled then return end; FullBright_Enabled=false
    if FullBright_Conn then FullBright_Conn:Disconnect(); FullBright_Conn=nil end
    for k,v in pairs(OriginalLighting) do Lighting[k]=v end
end

-- ════════════════════════════════════════════════════════════
--  FOV
-- ════════════════════════════════════════════════════════════
local Fov_Enabled=false; local Fov_Value=80
local Camera=workspace.CurrentCamera; local Original_Fov=Camera.FieldOfView

local function Fov_Enable()  Fov_Enabled=true end
local function Fov_Disable() Fov_Enabled=false; Camera.FieldOfView=Original_Fov end
RunService.RenderStepped:Connect(function() if Fov_Enabled then Camera.FieldOfView=Fov_Value end end)

-- ════════════════════════════════════════════════════════════
--  NOCLIP
-- ════════════════════════════════════════════════════════════
local Noclip_Enabled=false; local Noclip_Conn=nil; local origCollisions={}

local function Noclip_Enable()
    if Noclip_Enabled then return end; Noclip_Enabled=true
    local char=LocalPlayer.Character
    if char then
        for _,p in pairs(char:GetDescendants()) do
            if p:IsA("BasePart") and p.CanCollide then origCollisions[p]=true; p.CanCollide=false end
        end
    end
    Noclip_Conn = RunService.RenderStepped:Connect(function()
        if not Noclip_Enabled then return end
        local c=LocalPlayer.Character
        if c then for _,p in pairs(c:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide=false end end end
    end)
end

local function Noclip_Disable()
    if not Noclip_Enabled then return end; Noclip_Enabled=false
    if Noclip_Conn then Noclip_Conn:Disconnect(); Noclip_Conn=nil end
    local char=LocalPlayer.Character
    if char then for _,p in pairs(char:GetDescendants()) do if origCollisions[p] then p.CanCollide=true end end end
    origCollisions={}
end

-- ════════════════════════════════════════════════════════════
--  STAFF DETECTOR
-- ════════════════════════════════════════════════════════════
local AdminCheck_Enabled=false; local AdminCheck_Conn=nil

local staffData = {
    groups = {
        [4165692]  = {["Tester"]=true,["Contributor"]=true,["Tester+"]=true,["Developer"]=true,["Developer+"]=true,["Community Manager"]=true,["Manager"]=true,["Owner"]=true},
        [32406137] = {["Junior"]=true,["Moderator"]=true,["Senior"]=true,["Administrator"]=true,["Manager"]=true,["Holder"]=true},
        [8024440]  = {["zzzz"]=true,["reshape enjoyer"]=true,["i heart reshape"]=true,["reshape superfan"]=true},
        [14927228] = {["♞"]=true},
    },
    users = {
        3294804378,93676120,54087314,81275825,140837601,1229486091,46567801,418086275,29706395,
        3717066084,1424338327,5046662686,5046661126,5046659439,418199326,1024216621,1810535041,
        63238912,111250044,63315426,730176906,141193516,194512073,193945439,412741116,195538733,
        102045519,955294,957835150,25689921,366613818,281593651,455275714,208929505,96783330,
        156152502,93281166,959606619,142821118,632886139,175931803,122209625,278097946,142989311,
        1517131734,446849296,87189764,67180844,9212846,47352513,48058122,155413858,10497435,
        513615792,55893752,55476024,151691292,136584758,16983447,3111449,94693025,271400893,
        5005262660,295331237,64489098,244844600,114332275,25048901,69262878,50801509,92504899,
        42066711,50585425,31365111,166406495,2457253857,29761878,21831137,948293345,439942262,
        38578487,1163048,7713309208,3659305297,15598614,34616594,626833004,198610386,153835477,
        3923114296,3937697838,102146039,119861460,371665775,1206543842,93428604,1863173316,90814576,
        374665997,423005063,140172831,42662179,9066859,438805620,14855669,727189337,1871290386,608073286
    }
}

local function isStaff(p)
    if not p then return false end
    for gid, roles in pairs(staffData.groups) do
        local ok,rank=pcall(function() return p:GetRankInGroup(gid) end)
        if ok and rank and rank>0 then
            local ok2,role=pcall(function() return p:GetRoleInGroup(gid) end)
            if ok2 and role and roles[role] then return true, role end
        end
    end
    for _,uid in ipairs(staffData.users) do if p.UserId==uid then return true,"Listed UID" end end
    return false
end

local function checkAndKick(p)
    if not AdminCheck_Enabled then return end
    local found,role=isStaff(p)
    if found then LocalPlayer:Kick("⚠ EQR Hub — Staff Detected\n"..p.Name.." ("..tostring(role)..")") end
end

local function AdminCheck_Enable()
    if AdminCheck_Enabled then return end; AdminCheck_Enabled=true
    AdminCheck_Conn = Players.PlayerAdded:Connect(checkAndKick)
    task.spawn(function() for _,p in ipairs(Players:GetPlayers()) do if p~=LocalPlayer then checkAndKick(p) end end end)
end

local function AdminCheck_Disable()
    if not AdminCheck_Enabled then return end; AdminCheck_Enabled=false
    if AdminCheck_Conn then AdminCheck_Conn:Disconnect(); AdminCheck_Conn=nil end
end

-- ════════════════════════════════════════════════════════════
--  MELEE AURA
-- ════════════════════════════════════════════════════════════
local MeleeAura_Enabled=false; local MeleeAura_Conn=nil; local MeleeAura_Range=5

local function MeleeAura_Enable()
    if MeleeAura_Enabled then return end; MeleeAura_Enabled=true
    local evF = ReplicatedStorage:WaitForChild("Events")
    local r1  = evF:WaitForChild("XMHH.2")
    local r2  = evF:WaitForChild("XMHH2.2")

    local function Attack(tc)
        if not (tc and tc:FindFirstChild("Head")) then return end
        local char=LocalPlayer.Character; if not char then return end
        local tool=char:FindFirstChildOfClass("Tool")
        local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
        local a1={[1]="🍞",[2]=tick(),[3]=tool,[4]="43TRFWX",[5]="Normal",[6]=tick(),[7]=true}
        local ok,res=pcall(function() return r1:InvokeServer(unpack(a1)) end); if not ok then return end
        -- small jitter to avoid server-side pattern detection
        task.wait(0.08 + math.random()*0.05)
        local handle=tool and (tool:FindFirstChild("WeaponHandle") or tool:FindFirstChild("Handle")) or char:FindFirstChild("Right Arm")
        local head=tc:FindFirstChild("Head")
        if handle and head then
            local a2={[1]="🍞",[2]=tick(),[3]=tool,[4]="2389ZFX34",[5]=res,[6]=false,[7]=handle,[8]=head,[9]=tc,[10]=hrp.Position,[11]=head.Position}
            pcall(function() r2:FireServer(unpack(a2)) end)
        end
    end

    MeleeAura_Conn = RunService.RenderStepped:Connect(function()
        if not MeleeAura_Enabled then return end
        local char=LocalPlayer.Character; local hrp=char and char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
        for _,pl in ipairs(Players:GetPlayers()) do
            if pl~=LocalPlayer then
                local c=pl.Character; local h2=c and c:FindFirstChild("HumanoidRootPart"); local hum=c and c:FindFirstChildOfClass("Humanoid")
                if h2 and hum and (hrp.Position-h2.Position).Magnitude<MeleeAura_Range and hum.Health>15 and not c:FindFirstChildOfClass("ForceField") then
                    Attack(c)
                end
            end
        end
    end)
end

local function MeleeAura_Disable()
    if not MeleeAura_Enabled then return end; MeleeAura_Enabled=false
    if MeleeAura_Conn then MeleeAura_Conn:Disconnect(); MeleeAura_Conn=nil end
end

-- ════════════════════════════════════════════════════════════
--  RAGEBOT
-- ════════════════════════════════════════════════════════════
local Ragebot_Enabled=false; local Ragebot_Coro=nil
local GNX_S_Remote,ZFKLF_H_Remote

pcall(function()
    local ev=ReplicatedStorage:WaitForChild("Events",10)
    GNX_S_Remote   = ev and ev:WaitForChild("GNX_S",   5)
    ZFKLF_H_Remote = ev and ev:WaitForChild("ZFKLF__H",5)
end)

local function RandStr(n)
    local s=""
    for _=1,n do s=s..string.char(math.random(97,122)) end
    return s
end

local function GetClosestEnemy()
    local best,bestD=nil,200
    local mc=LocalPlayer.Character; local mh=mc and mc:FindFirstChild("HumanoidRootPart"); if not mh then return nil end
    for _,pl in ipairs(Players:GetPlayers()) do
        if pl~=LocalPlayer then
            local ec=pl.Character; local eh=ec and ec:FindFirstChild("HumanoidRootPart"); local hum=ec and ec:FindFirstChildOfClass("Humanoid")
            if eh and hum and hum.Health>15 and not ec:FindFirstChildOfClass("ForceField") then
                local d=(mh.Position-eh.Position).Magnitude; if d<bestD then bestD=d; best=pl end
            end
        end
    end
    return best
end

local function Shoot(tp)
    if not (tp and tp.Character and GNX_S_Remote and ZFKLF_H_Remote) then return end
    local tPart=tp.Character:FindFirstChild("Head") or tp.Character:FindFirstChild("HumanoidRootPart"); if not tPart then return end
    local mc=LocalPlayer.Character; local tool=mc and mc:FindFirstChildOfClass("Tool"); if not tool then return end
    local cam=workspace.CurrentCamera; local hp=tPart.Position
    local hd=(hp-cam.CFrame.Position).Unit; local rk=RandStr(30).."0"
    pcall(function() GNX_S_Remote:FireServer(tick(),rk,tool,"FDS9I83",cam.CFrame.Position,{hd},false) end)
    pcall(function() ZFKLF_H_Remote:FireServer("🧈",tool,rk,1,tPart,hp,hd,nil,nil) end)
end

local function RagebotLoop()
    while Ragebot_Enabled do
        local t=GetClosestEnemy()
        if t then Shoot(t); task.wait(0.05+math.random()*0.02)
        else task.wait(0.1) end
    end
    Ragebot_Coro=nil
end

local function Ragebot_Enable()
    if Ragebot_Enabled then return end; Ragebot_Enabled=true
    if not Ragebot_Coro then Ragebot_Coro=coroutine.create(RagebotLoop); coroutine.resume(Ragebot_Coro) end
end

local function Ragebot_Disable()
    if not Ragebot_Enabled then return end; Ragebot_Enabled=false
end

-- ════════════════════════════════════════════════════════════
--  NO RECOIL
-- ════════════════════════════════════════════════════════════
local NoRecoil_Enabled=false; local NoRecoil_Conns={}
local GlobalOrigVals={}; local WeaponCache={}
local GunSettings={NoRecoil=true,Spread=false,SpreadAmount=0}

local function cacheWeapons()
    WeaponCache={}
    for _,v in pairs(getgc(true)) do
        if type(v)=="table" and rawget(v,"EquipTime") then
            table.insert(WeaponCache,v)
            if not GlobalOrigVals[v] then
                GlobalOrigVals[v]={Recoil=v.Recoil,CameraRecoilingEnabled=v.CameraRecoilingEnabled,AngleX_Min=v.AngleX_Min,AngleX_Max=v.AngleX_Max,AngleY_Min=v.AngleY_Min,AngleY_Max=v.AngleY_Max,AngleZ_Min=v.AngleZ_Min,AngleZ_Max=v.AngleZ_Max,Spread=v.Spread}
            end
        end
    end
end

local function applyGunMods()
    for _,w in ipairs(WeaponCache) do
        if GunSettings.NoRecoil then w.Recoil=0;w.CameraRecoilingEnabled=false;w.AngleX_Min=0;w.AngleX_Max=0;w.AngleY_Min=0;w.AngleY_Max=0;w.AngleZ_Min=0;w.AngleZ_Max=0 end
        if GunSettings.Spread then w.Spread=GunSettings.SpreadAmount end
    end
end

local function resetGunMods()
    for w,vals in pairs(GlobalOrigVals) do for k,v in pairs(vals) do w[k]=v end end
end

local function NoRecoil_Enable()
    if NoRecoil_Enabled then return end; NoRecoil_Enabled=true; cacheWeapons(); applyGunMods()
    table.insert(NoRecoil_Conns, LocalPlayer.CharacterAdded:Connect(function(char)
        for _,c in ipairs(char:GetChildren()) do if c:IsA("Tool") then task.wait(0.1);cacheWeapons();applyGunMods() end end
        char.ChildAdded:Connect(function(c) if c:IsA("Tool") then task.wait(0.1);cacheWeapons();applyGunMods() end end)
    end))
end

local function NoRecoil_Disable()
    if not NoRecoil_Enabled then return end; NoRecoil_Enabled=false; resetGunMods()
    for _,c in ipairs(NoRecoil_Conns) do c:Disconnect() end; NoRecoil_Conns={}
end

-- ════════════════════════════════════════════════════════════
--  PLAYER ESP  (external loader)
-- ════════════════════════════════════════════════════════════
local ESP_Enabled=false; local ESP_Loading=false; local LastESP=0

local function ESP_Enable()
    if os.clock()-LastESP<0.5 then return end; LastESP=os.clock()
    if ESP_Loading or ESP_Enabled then return end
    ESP_Loading=true
    local ok,err=pcall(function()
        loadstring(game:HttpGet("https://raw.githubusercontent.com/kskdkdkdmsmdmdm0-dot/lolsjkskf/refs/heads/main/walhaczek",true))()
        ESP_Enabled=true; ESP_Loading=false
    end)
    if not ok then warn("ESP:"..tostring(err)); ESP_Loading=false; ESP_Enabled=false end
end

local function ESP_Disable()
    if os.clock()-LastESP<0.5 then return end; LastESP=os.clock()
    if not ESP_Enabled then return end; ESP_Enabled=false
    for _,n in ipairs({"Folder","ESP_Holder","ESP_Folder","ESP"}) do
        local f=game:GetService("CoreGui"):FindFirstChild(n); if f then f:Destroy() end
    end
end

-- ════════════════════════════════════════════════════════════
--  AIMBOT
-- ════════════════════════════════════════════════════════════
local AimBot = {
    Enabled=false, WallCheck=true, StickyAim=false,
    Fov=100, Smoothing=0.02, AimPart="HumanoidRootPart",
    IsDown=false, Target=nil, Tween=nil,
}

local function aliveP(p) return p and p.Character and p.Character:FindFirstChildOfClass("Humanoid") and p.Character.Humanoid.Health>0 end

local function visible(pos, char)
    if not AimBot.WallCheck then return true end
    local ign={workspace.CurrentCamera}
    if LocalPlayer.Character then table.insert(ign,LocalPlayer.Character) end
    if char then table.insert(ign,char) end
    local ok,obs=pcall(function() return workspace.CurrentCamera:GetPartsObscuringTarget({pos},ign) end)
    if not ok or not obs then return false end
    return #obs==0
end

local function closestToMouse()
    local fov,t=AimBot.Fov,nil
    for _,pl in ipairs(Players:GetPlayers()) do
        if pl~=LocalPlayer and aliveP(pl) then
            local c=pl.Character; local ap=c and c:FindFirstChild(AimBot.AimPart)
            if ap then
                local ok,sp,on=pcall(function() return Camera:WorldToViewportPoint(ap.Position) end)
                if ok and on then
                    local d=(Vector2.new(sp.X,sp.Y)-UserInputService:GetMouseLocation()).Magnitude
                    if d<fov and visible(ap.Position,c) then fov=d; t=pl end
                end
            end
        end
    end
    return t
end

UserInputService.InputBegan:Connect(function(inp,gpe)
    if gpe or not AimBot.Enabled then return end
    if inp.UserInputType==Enum.UserInputType.MouseButton2 then
        AimBot.Target=closestToMouse(); AimBot.IsDown=true
    end
end)
UserInputService.InputEnded:Connect(function(inp,gpe)
    if gpe or not AimBot.Enabled then return end
    if inp.UserInputType==Enum.UserInputType.MouseButton2 then
        AimBot.IsDown=false; AimBot.Target=nil
        if AimBot.Tween then AimBot.Tween:Cancel(); AimBot.Tween=nil end
    end
end)
RunService.Heartbeat:Connect(function()
    if not AimBot.Enabled or not AimBot.IsDown then return end
    local t=AimBot.StickyAim and AimBot.Target or closestToMouse()
    if not t or not aliveP(t) then if AimBot.Tween then AimBot.Tween:Cancel(); AimBot.Tween=nil end; return end
    local ap=t.Character and t.Character:FindFirstChild(AimBot.AimPart); if not ap then return end
    local pred=ap.Velocity*(LocalPlayer:GetNetworkPing()*0.1)
    local cf=CFrame.new(Camera.CFrame.Position,ap.Position+pred)
    if AimBot.Tween then AimBot.Tween:Cancel() end
    pcall(function()
        AimBot.Tween=TweenService:Create(Camera,TweenInfo.new(AimBot.Smoothing,Enum.EasingStyle.Sine,Enum.EasingDirection.Out),{CFrame=cf})
        AimBot.Tween:Play()
    end)
end)

local function Aimbot_Enable()  AimBot.Enabled=true end
local function Aimbot_Disable()
    AimBot.Enabled=false; AimBot.IsDown=false; AimBot.Target=nil
    if AimBot.Tween then AimBot.Tween:Cancel(); AimBot.Tween=nil end
end

-- ════════════════════════════════════════════════════════════
--  INFINITE STAMINA
-- ════════════════════════════════════════════════════════════
local isInfStamina=false; local oldStamFunc=nil
pcall(function()
    local env; pcall(function() env=getrenv() end)
    if env and env._G and env._G.S_Take then
        local ok,upval=pcall(getupvalue,env._G.S_Take,2)
        if ok and type(upval)=="function" then
            oldStamFunc=hookfunction(upval,function(v,...)
                if isInfStamina then return oldStamFunc(0,...) end
                return oldStamFunc(v,...)
            end)
        end
    end
end)

local function InfiniteStamina_Enable()  isInfStamina=true  end
local function InfiniteStamina_Disable() isInfStamina=false end

-- ════════════════════════════════════════════════════════════
--  INVISIBILITY
-- ════════════════════════════════════════════════════════════
local InvisEnabled=false; local Invis_Fixed=true
local InvisTrack=nil
local InvisChar,InvisHum,InvisHRP
local InvisAnim=Instance.new("Animation"); InvisAnim.AnimationId="rbxassetid://215384594"

local function UpdateInvisRefs()
    InvisChar=LocalPlayer.Character
    if InvisChar then InvisHRP=InvisChar:FindFirstChild("HumanoidRootPart"); InvisHum=InvisChar:FindFirstChildOfClass("Humanoid")
    else InvisHRP=nil; InvisHum=nil end
end
UpdateInvisRefs()
if InvisChar and not InvisChar:FindFirstChild("Torso") then Invis_Fixed=false end

local function LoadInvisTrack()
    if InvisTrack then pcall(function() InvisTrack:Stop() end); InvisTrack=nil end
    if InvisHum then
        local ok,r=pcall(function() return InvisHum:LoadAnimation(InvisAnim) end)
        if ok then InvisTrack=r; InvisTrack.Priority=Enum.AnimationPriority.Action4 end
    end
end

local function Invis_Disable()
    if not InvisEnabled then return end; InvisEnabled=false
    if InvisTrack then pcall(function() InvisTrack:Stop() end) end
    if InvisHum then Camera.CameraSubject=InvisHum end
    if InvisChar then for _,v in pairs(InvisChar:GetDescendants()) do if v:IsA("BasePart") and v.Transparency==0.5 then v.Transparency=0 end end end
end

local function Invis_Enable()
    if InvisEnabled or not Invis_Fixed then return end
    UpdateInvisRefs()
    if not InvisChar or not InvisHum or not InvisHRP or not InvisChar:FindFirstChild("Torso") then return end
    InvisEnabled=true; Camera.CameraSubject=InvisHRP; LoadInvisTrack()
end

RunService.Heartbeat:Connect(function(dt)
    if not InvisEnabled or not Invis_Fixed then
        if not InvisEnabled and InvisChar then
            for _,v in pairs(InvisChar:GetDescendants()) do if v:IsA("BasePart") and v.Transparency==0.5 then v.Transparency=0 end end
        end; return
    end
    if not InvisChar or not InvisHum or not InvisHRP or not InvisHum:IsDescendantOf(workspace) or InvisHum.Health<=0 then return end
    local spd=12; if InvisHum.MoveDirection.Magnitude>0 then InvisHRP.CFrame=InvisHRP.CFrame+InvisHum.MoveDirection*spd*dt end
    local OC=InvisHRP.CFrame; local OCO=InvisHum.CameraOffset
    local _,y=Camera.CFrame:ToOrientation()
    InvisHRP.CFrame=CFrame.new(InvisHRP.CFrame.Position)*CFrame.fromOrientation(0,y,0)*CFrame.Angles(math.rad(90),0,0)
    InvisHum.CameraOffset=Vector3.new(0,1.44,0)
    if InvisTrack then pcall(function() if not InvisTrack.IsPlaying then InvisTrack:Play() end; InvisTrack:AdjustSpeed(0); InvisTrack.TimePosition=0.3 end)
    else LoadInvisTrack() end
    RunService.RenderStepped:Wait()
    if InvisHum and InvisHum:IsDescendantOf(workspace) then InvisHum.CameraOffset=OCO end
    if InvisHRP and InvisHRP:IsDescendantOf(workspace) then InvisHRP.CFrame=OC end
    if InvisTrack then pcall(function() InvisTrack:Stop() end) end
    if InvisHRP and InvisHRP:IsDescendantOf(workspace) then
        local lv=Camera.CFrame.LookVector; local hl=Vector3.new(lv.X,0,lv.Z).Unit
        if hl.Magnitude>0.1 then InvisHRP.CFrame=CFrame.new(InvisHRP.Position,InvisHRP.Position+hl) end
    end
    if InvisChar then for _,v in pairs(InvisChar:GetDescendants()) do if v:IsA("BasePart") and v.Transparency~=1 then v.Transparency=0.5 end end end
end)

LocalPlayer.CharacterAdded:Connect(function()
    if InvisTrack then pcall(function() InvisTrack:Stop() end); InvisTrack=nil end
    task.wait(); UpdateInvisRefs()
    if not InvisHum then task.wait(0.5); UpdateInvisRefs() end
    Invis_Fixed = InvisHum and InvisHum.RigType==Enum.HumanoidRigType.R6 or false
    if InvisEnabled and Invis_Fixed then Camera.CameraSubject=InvisHRP; LoadInvisTrack() end
end)

-- ════════════════════════════════════════════════════════════
--  SHADOW MODE
-- ════════════════════════════════════════════════════════════
local Shadow_Active=false; local Shadow_Usable=true

do
    repeat task.wait() until game:IsLoaded()
    local ref=cloneref or function(...) return ... end
    local GS=setmetatable({},{__index=function(_,k) return ref(game:GetService(k)) end})
    local P=GS.Players.LocalPlayer
    local SChar,SHMND,SHRP

    local function RefShadow()
        SChar=P.Character
        if SChar then SHRP=SChar:FindFirstChild("HumanoidRootPart"); SHMND=SChar:FindFirstChildOfClass("Humanoid")
        else SHRP=nil; SHMND=nil end
    end
    RefShadow()

    local SAnim=Instance.new("Animation"); SAnim.AnimationId="rbxassetid://215384594"
    local STrack=nil
    if SChar and not SChar:FindFirstChild("Torso") then Shadow_Usable=false end

    local function CacheTrack()
        if STrack then pcall(function() STrack:Stop() end); STrack=nil end
        if SHMND then
            local ok,r=pcall(function() return SHMND:LoadAnimation(SAnim) end)
            if ok then STrack=r; STrack.Priority=Enum.AnimationPriority.Action4 end
        end
    end

    local function DeactivateShadow()
        if not Shadow_Active then return end; Shadow_Active=false
        if STrack then pcall(function() STrack:Stop() end) end
        if SHMND then GS.Workspace.CurrentCamera.CameraSubject=SHMND end
        if SChar then for _,v in pairs(SChar:GetDescendants()) do if v:IsA("BasePart") and v.Transparency==0.5 then v.Transparency=0 end end end
    end

    local function ActivateShadow()
        if Shadow_Active or not Shadow_Usable then return end
        RefShadow()
        if not SChar or not SHMND or not SHRP or not SChar:FindFirstChild("Torso") then return end
        Shadow_Active=true; GS.Workspace.CurrentCamera.CameraSubject=SHRP; CacheTrack()
    end

    GS.RunService.Heartbeat:Connect(function(dt)
        if not Shadow_Active or not Shadow_Usable then
            if not Shadow_Active and SChar then for _,v in pairs(SChar:GetDescendants()) do if v:IsA("BasePart") and v.Transparency==0.5 then v.Transparency=0 end end end; return
        end
        if not SChar or not SHMND or not SHRP or not SHMND:IsDescendantOf(GS.Workspace) or SHMND.Health<=0 then return end
        local spd=12; if SHMND.MoveDirection.Magnitude>0 then SHRP.CFrame=SHRP.CFrame+SHMND.MoveDirection*spd*dt end
        local OC=SHRP.CFrame; local OCO=SHMND.CameraOffset
        local _,y=GS.Workspace.CurrentCamera.CFrame:ToOrientation()
        SHRP.CFrame=CFrame.new(SHRP.CFrame.Position)*CFrame.fromOrientation(0,y,0)*CFrame.Angles(math.rad(90),0,0)
        SHMND.CameraOffset=Vector3.new(0,1.44,0)
        if STrack then pcall(function() if not STrack.IsPlaying then STrack:Play() end; STrack:AdjustSpeed(0); STrack.TimePosition=0.3 end)
        else CacheTrack() end
        GS.RunService.RenderStepped:Wait()
        if SHMND and SHMND:IsDescendantOf(GS.Workspace) then SHMND.CameraOffset=OCO end
        if SHRP  and SHRP:IsDescendantOf(GS.Workspace)  then SHRP.CFrame=OC end
        if STrack then pcall(function() STrack:Stop() end) end
        if SHRP and SHRP:IsDescendantOf(GS.Workspace) then
            local lv=GS.Workspace.CurrentCamera.CFrame.LookVector; local hl=Vector3.new(lv.X,0,lv.Z).Unit
            if hl.Magnitude>0.1 then SHRP.CFrame=CFrame.new(SHRP.Position,SHRP.Position+hl) end
        end
        if SChar then for _,v in pairs(SChar:GetDescendants()) do if v:IsA("BasePart") and v.Transparency~=1 then v.Transparency=0.5 end end end
    end)

    P.CharacterAdded:Connect(function()
        if STrack then pcall(function() STrack:Stop() end); STrack=nil end
        if Shadow_Active then DeactivateShadow() end
        task.wait(); RefShadow()
        Shadow_Usable = SHMND and SHMND.RigType==Enum.HumanoidRigType.R6 or false
        if autofarmEnabled and Shadow_Usable then ActivateShadow() end
    end)

    _G.ActivateShadow   = ActivateShadow
    _G.DeactivateShadow = DeactivateShadow
    _G.IsShadowActive   = function() return Shadow_Active end
end

-- ════════════════════════════════════════════════════════════
--  PANIC  (Delete key — kills every feature instantly)
-- ════════════════════════════════════════════════════════════
local function PanicAll()
    panicActive=true
    pcall(Fly_Disable); pcall(Noclip_Disable); pcall(FullBright_Disable); pcall(Fov_Disable)
    pcall(WalkSpeed_Disable); pcall(JumpPower_Disable)
    pcall(MeleeAura_Disable); pcall(Aimbot_Disable); pcall(NoRecoil_Disable); pcall(Ragebot_Disable)
    pcall(ESP_Disable); pcall(Invis_Disable); pcall(BredMakurz_Disable)
    pcall(NoFailLockpick_Disable); pcall(OpenNearbyDoors_Disable); pcall(UnlockNearbyDoors_Disable)
    pcall(AdminCheck_Disable); pcall(Collector_Deactivate); pcall(InfiniteStamina_Disable)
    pcall(function() _G.DeactivateShadow() end)
    if autofarmEnabled then autofarmEnabled=false; pcall(function() _G.DeactivateShadow() end); pcall(Collector_Deactivate) end
    FarmStats.LastAction="⚠ PANIC — all features killed"
    task.wait(0.5); panicActive=false
end

UserInputService.InputBegan:Connect(function(inp,gpe)
    if gpe then return end
    if inp.KeyCode==Enum.KeyCode.Delete then
        pcall(PanicAll)
        pcall(function()
            game:GetService("StarterGui"):SetCore("SendNotification",{Title="⚠ PANIC",Text="All EQR features disabled.",Duration=5})
        end)
    end
end)

-- ════════════════════════════════════════════════════════════
--  AUTOFARM HELPERS
-- ════════════════════════════════════════════════════════════
local function teleportTo(tp)
    local char=LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local hrp=char:WaitForChild("HumanoidRootPart",10)
    if not hrp or not (tp and tp:IsA("BasePart")) then return false end
    local ok,att=false,0
    while not ok and att<4 do
        local pos=(tp.CFrame + tp.CFrame.LookVector*2).Position
        hrp.CFrame=CFrame.new(pos)*CFrame.Angles(0,math.pi/2,0)
        task.wait(0.5)
        local stable=true
        for _=1,8 do
            task.wait(0.2)
            if not hrp or not hrp.Parent or (hrp.Position-pos).Magnitude>6 then stable=false; break end
        end
        if stable then ok=true else att=att+1; task.wait(1) end
    end
    return ok
end

local function hasTool(name)
    return LocalPlayer.Backpack:FindFirstChild(name) or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild(name))
end

local function classifyTarget(v)
    local n=v.Name:lower()
    if n:find("register") then return "register"
    elseif n:find("big") or n:find("large") then return "bigsafe"
    else return "safe" end
end

local function findNearestTarget(ignore)
    local folder=workspace.Map:FindFirstChild("BredMakurz") or (workspace.Filter and workspace.Filter:FindFirstChild("BredMakurz"))
    local char=LocalPlayer.Character
    if not folder or not char then return nil end
    local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end

    local candidates = {}
    for _,v in ipairs(folder:GetChildren()) do
        local nm = v.Name:lower()
        if not (nm:find("safe") or nm:find("register")) then continue end
        if table.find(ignore, v) then continue end
        if isOnCooldown(v) then continue end   -- skip if not respawned yet

        local vals=v:FindFirstChild("Values"); local broken=vals and vals:FindFirstChild("Broken")
        if not (broken and broken:IsA("BoolValue") and not broken.Value) then continue end

        local tp=v.PrimaryPart or v:FindFirstChild("MainPart") or v:FindFirstChild("PosPart")
        if not tp then continue end

        local d=(tp.Position-hrp.Position).Magnitude
        local kind=classifyTarget(v)
        table.insert(candidates, {model=v, dist=d, kind=kind})
    end

    if #candidates == 0 then return nil end

    -- Sort by priority mode
    if TargetPriority == "BigSafeFirst" then
        table.sort(candidates, function(a, b)
            local rankA = (a.kind=="bigsafe") and 0 or (a.kind=="safe") and 1 or 2
            local rankB = (b.kind=="bigsafe") and 0 or (b.kind=="safe") and 1 or 2
            if rankA ~= rankB then return rankA < rankB end
            return a.dist < b.dist
        end)
    elseif TargetPriority == "RegisterFirst" then
        table.sort(candidates, function(a, b)
            local rankA = (a.kind=="register") and 0 or (a.kind=="safe") and 1 or 2
            local rankB = (b.kind=="register") and 0 or (b.kind=="safe") and 1 or 2
            if rankA ~= rankB then return rankA < rankB end
            return a.dist < b.dist
        end)
    else  -- Nearest
        table.sort(candidates, function(a, b) return a.dist < b.dist end)
    end

    return candidates[1].model
end

local function findNearestDealer()
    local shopz=workspace.Map:FindFirstChild("Shopz"); local char=LocalPlayer.Character
    if not shopz or not char then return nil end
    local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
    local nearest,shortest=nil,math.huge
    for _,d in ipairs(shopz:GetChildren()) do
        local cs=d:FindFirstChild("CurrentStocks") and d.CurrentStocks:FindFirstChild("Crowbar")
        if cs and cs.Value>0 and d:FindFirstChild("MainPart") then
            local dist=(d.MainPart.Position-hrp.Position).Magnitude
            if dist<shortest then shortest=dist; nearest=d end
        end
    end
    return nearest
end

-- ── Post-crack bread sweep (collects all dropped stacks) ──
local function sweepBreadNear(anchorPos, radius, timeout)
    local breadF  = workspace.Filter:FindFirstChild("SpawnedBread")
    local pickupR = ReplicatedStorage.Events:FindFirstChild("CZDPZUS")
    if not breadF or not pickupR then return end
    local deadline=tick()+timeout; local cd=false
    while tick()<deadline do
        local char=LocalPlayer.Character; local hrp=char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then task.wait(0.2); continue end
        local found=false
        for _,item in ipairs(breadF:GetChildren()) do
            if not item or not item.Parent then continue end
            if (anchorPos-item.Position).Magnitude<=radius then
                found=true
                if not cd then
                    cd=true
                    hrp.CFrame=CFrame.new(item.Position)
                    task.wait(0.05)
                    local ok=pcall(function() pickupR:FireServer(item) end)
                    if ok then FarmStats.BreadCollected=FarmStats.BreadCollected+1 end
                    task.wait(0.75); cd=false
                end
                break
            end
        end
        if not found then break end
        task.wait(0.1)
    end
    -- Return to anchor
    local char=LocalPlayer.Character; local hrp=char and char:FindFirstChild("HumanoidRootPart")
    if hrp then hrp.CFrame=CFrame.new(anchorPos) end
end

-- ════════════════════════════════════════════════════════════
--  OPEN SAFE / REGISTER
-- ════════════════════════════════════════════════════════════
local function openSafe(model)
    local function getCrowbar() return hasTool("Crowbar") end
    local crowbar=getCrowbar(); if not crowbar then return end
    local r1=ReplicatedStorage:WaitForChild("Events"):WaitForChild("XMHH.2")
    local r2=ReplicatedStorage:WaitForChild("Events"):WaitForChild("XMHH2.2")
    local smp=model:WaitForChild("MainPart",5); if not smp then return end

    local kind=classifyTarget(model)
    local labels={register="🏪 Register",bigsafe="🏛 Big Safe",safe="🏦 Safe"}
    FarmStats.LastAction="🔨 Cracking "..labels[kind]..": "..model.Name

    local maxTime=kind=="bigsafe" and 25 or 18
    local startT=tick()

    while model and model.Parent
        and model:FindFirstChild("Values") and model.Values:FindFirstChild("Broken")
        and not model.Values.Broken.Value
        and (tick()-startT<maxTime) and autofarmEnabled do

        local char=LocalPlayer.Character; if not char then break end

        -- Re-equip crowbar if dropped
        crowbar=char:FindFirstChild("Crowbar")
        if not crowbar then
            crowbar=getCrowbar(); if not crowbar then break end
            pcall(function() char.Humanoid:EquipTool(crowbar) end); task.wait(0.3)
            crowbar=char:FindFirstChild("Crowbar"); if not crowbar then break end
        end

        local hitR=r1:InvokeServer("\240\159\141\158",tick(),crowbar,"DZDRRRKI",model,"Register")
        if hitR==nil then task.wait(0.5); continue end

        local ra=char:FindFirstChild("Right Arm")
        if ra then r2:FireServer("\240\159\141\158",tick(),crowbar,"2389ZFX34",hitR,false,ra,smp,model,smp.Position,smp.Position) end

        -- Anti-pattern jitter on hit interval
        task.wait(0.12 + math.random()*0.06)
    end

    -- Stats
    if kind=="register" then
        FarmStats.RegistersCracked=FarmStats.RegistersCracked+1
    elseif kind=="bigsafe" then
        FarmStats.BigSafesCracked=FarmStats.BigSafesCracked+1
    else
        FarmStats.SafesCracked=FarmStats.SafesCracked+1
    end

    -- Record respawn timer so we don't revisit too early
    markCracked(model, kind)

    -- Loot log entry
    local avgEst = (kind=="register") and 205 or (kind=="bigsafe") and 640 or 420
    local ts = os.date("%H:%M:%S")
    local icons = {register="🏪", bigsafe="🏛", safe="🏦"}
    pushLootLog(string.format("[%s] %s %s  ~$%s", ts, icons[kind] or "🏦", model.Name, tostring(avgEst)))

    FarmStats.LastAction="💰 Collecting from "..labels[kind].."..."
    task.wait(1.5)                        -- let server spawn bread
    sweepBreadNear(smp.Position, 22, 15)  -- collect all stacks in 22 stud radius
    FarmStats.LastAction="✅ Done — finding next target"
    task.wait(2)
end

-- ════════════════════════════════════════════════════════════
--  AUTOFARM  ENABLE / DISABLE
-- ════════════════════════════════════════════════════════════
local function Autofarm_Enable()
    if autofarmEnabled then return end; autofarmEnabled=true
    _G.ActivateShadow(); Collector_Activate()
end

local function Autofarm_Disable()
    if not autofarmEnabled then return end; autofarmEnabled=false
    _G.DeactivateShadow(); Collector_Deactivate()
    FarmStats.LastAction="Idle"
end

-- Respawn loop
task.spawn(function()
    local deathEv=ReplicatedStorage:WaitForChild("Events"):WaitForChild("DeathRespawn")
    while task.wait() do
        local char=LocalPlayer.Character
        if char then
            local hum=char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health<=0 and autofarmEnabled then
                deathEv:InvokeServer("KMG4R904"); task.wait(2.5)
            end
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    if not autofarmEnabled then return end
    char:WaitForChild("HumanoidRootPart",5); task.wait(1.5)
    autofarmCooldown=false; ignoredSafes={}; Autofarm_Enable()
end)

-- ── Main autofarm loop ─────────────────────────────────────
local noTargetCt=0
task.spawn(function()
    while true do
        task.wait(1)
        if panicActive then continue end
        local char=LocalPlayer.Character; local hum=char and char:FindFirstChildOfClass("Humanoid")
        if hum then Settings.IsDead=hum.Health<=0 end
        if not autofarmEnabled or autofarmCooldown or not char or not hum or hum.Health<=0 then continue end
        if isPingHigh then FarmStats.LastAction="⚠ High ping — paused"; continue end

        local crowbar=hasTool("Crowbar")
        if not crowbar then
            FarmStats.LastAction="🔍 No crowbar — finding dealer..."
            local dealer=findNearestDealer()
            if dealer then
                FarmStats.LastAction="🏪 Teleporting to dealer..."
                if teleportTo(dealer:WaitForChild("MainPart")) then
                    task.wait(1)
                    ReplicatedStorage.Events.BYZERSPROTEC:FireServer(true,"shop",dealer.MainPart,"IllegalStore")
                    task.wait(1)
                    FarmStats.LastAction="💳 Buying Crowbar..."
                    ReplicatedStorage.Events.SSHPRMTE1:InvokeServer("IllegalStore","Melees","Crowbar",dealer.MainPart,nil,true)
                    FarmStats.CrowbarsBought=FarmStats.CrowbarsBought+1
                    task.wait(20)
                    ReplicatedStorage.Events.BYZERSPROTEC:FireServer(false)
                else task.wait(5) end
            else FarmStats.LastAction="❌ No dealer found — waiting..."; task.wait(10) end
        else
            local target=findNearestTarget(ignoredSafes)
            if target then
                noTargetCt=0
                FarmStats.LastAction="📍 Teleporting to "..target.Name
                if teleportTo(target:WaitForChild("MainPart")) then
                    if not char:FindFirstChild("Crowbar") then
                        pcall(function() char.Humanoid:EquipTool(crowbar) end); task.wait(0.5)
                    end
                    task.wait(0.5); openSafe(target)
                else
                    FarmStats.LastAction="⚠ Teleport failed — skipping"
                    table.insert(ignoredSafes,target); task.wait(0.5)
                end
            else
                noTargetCt=noTargetCt+1

                -- Find the soonest respawn among tracked cooldowns
                local soonestRespawn = math.huge
                local folder2 = workspace.Map:FindFirstChild("BredMakurz") or (workspace.Filter and workspace.Filter:FindFirstChild("BredMakurz"))
                if folder2 then
                    for _, v in ipairs(folder2:GetChildren()) do
                        local rem = cooldownRemaining(v)
                        if rem > 0 and rem < soonestRespawn then soonestRespawn = rem end
                    end
                end

                if soonestRespawn < math.huge and soonestRespawn < 60 then
                    -- A safe is about to respawn — just wait for it
                    FarmStats.LastAction = string.format("⏳ Next respawn in %ds — waiting...", math.ceil(soonestRespawn))
                    task.wait(math.min(soonestRespawn + 2, 15))
                elseif noTargetCt >= 3 then
                    -- All safes depleted — clear ignore list first
                    ignoredSafes = {}; noTargetCt = 0

                    if AutoHop_Enabled then
                        FarmStats.LastAction = "🔀 Map depleted — hopping server..."
                        task.wait(3)
                        pcall(function() game:GetService("TeleportService"):Teleport(game.PlaceId, LocalPlayer) end)
                    else
                        local waitSecs = soonestRespawn < math.huge and math.ceil(soonestRespawn) or 45
                        FarmStats.LastAction = string.format("⏳ Map clear — next respawn ~%ds", waitSecs)
                        task.wait(math.min(waitSecs, 45))
                    end
                else
                    FarmStats.LastAction = "⏳ No targets — waiting..."
                    task.wait(6)
                end
            end
        end
    end
end)

-- ════════════════════════════════════════════════════════════
--  ██   ██ ██
--  ██   ██ ██
--  ██   ██ ██
--  ██   ██ ██
--   █████  ██
--  R A Y F I E L D
-- ════════════════════════════════════════════════════════════
-- ════════════════════════════════════════════════════════════
--  R A Y F I E L D  (self-hosted first, then CDN fallbacks)
-- ════════════════════════════════════════════════════════════
local Rayfield
local rayfieldURLs = {
    "https://raw.githubusercontent.com/dwitty19/EQRHub-/main/rayfield.lua",  -- self-hosted (most reliable)
    "https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua", -- official GitHub
    "https://sirius.menu/rayfield",  -- official CDN (sometimes down)
}
for _, url in ipairs(rayfieldURLs) do
    local ok, result = pcall(function()
        return loadstring(game:HttpGet(url, true))()
    end)
    if ok and result then Rayfield = result; break end
    task.wait(1)
end
assert(Rayfield, "[EQR Hub] Failed to load Rayfield UI. Make sure rayfield.lua is uploaded to your GitHub repo.")

local Window = Rayfield:CreateWindow({
    Name            = "EQR Hub  |  v2.1",
    LoadingTitle    = "EQR Hub  v2.1",
    LoadingSubtitle = "Criminality  •  Built for Dwitty19",
    ConfigurationSaving = { Enabled=true, FolderName="EQRHub", FileName="config" },
    KeySystem = {
        Enabled   = true,
        Title     = "EQR Hub  v2.1",
        Subtitle  = "Enter your access key",
        Note      = "Contact Dwitty19 for a key.",
        FileName  = "EQRHubKey",   -- saves key locally so you only type it once
        SaveKey   = true,
        GrabKeyFromSite = false,
        Key       = {
            "EQR-DWITTY-2025",    -- primary key — change or delete this
            -- add more keys here as extra lines, e.g.:
            -- "EQR-FRIEND-0001",
            -- "EQR-FRIEND-0002",
        },
    },
})

-- ════════════════════════════════════════════════════════════
--  🏠  HOME  (Dashboard + Quick Toggles)
-- ════════════════════════════════════════════════════════════
local HomeTab = Window:CreateTab("🏠  Home", 4483362458)

HomeTab:CreateSection("EQR Hub  v2.1  ─  Criminality  |  Dwitty19")

HomeTab:CreateParagraph({
    Title   = "👋 Welcome, Dwitty19",
    Content = "Quick start:\n"
           .. "1.  Go to 🌾 Farming → enable Autofarm\n"
           .. "2.  Go to ⚙ Settings → set Target Priority\n"
           .. "3.  Enable 🛡 Staff Detector in 🔧 Misc\n"
           .. "4.  Watch live earnings in 📊 Stats\n\n"
           .. "🔑 RightAlt       — toggle this UI\n"
           .. "🗑 Delete key    — panic (kills everything)\n"
           .. "⚠️  R6 avatar required for Invisibility & Shadow",
})

HomeTab:CreateSection("⚡ Quick Toggles")

HomeTab:CreateToggle({ Name="🌾 Autofarm", CurrentValue=false, Flag="QT_Farm",
    Callback=function(v) if v then Autofarm_Enable() else Autofarm_Disable() end end })

HomeTab:CreateToggle({ Name="🏦 Safe / Register ESP", CurrentValue=false, Flag="QT_SafeESP",
    Callback=function(v) if v then BredMakurz_Enable() else BredMakurz_Disable() end end })

HomeTab:CreateToggle({ Name="🛡 Staff Detector", CurrentValue=false, Flag="QT_Staff",
    Callback=function(v) if v then AdminCheck_Enable() else AdminCheck_Disable() end end })

HomeTab:CreateToggle({ Name="🌞 FullBright", CurrentValue=false, Flag="QT_FB",
    Callback=function(v) if v then FullBright_Enable() else FullBright_Disable() end end })

HomeTab:CreateToggle({ Name="🔫 No Recoil", CurrentValue=false, Flag="QT_NR",
    Callback=function(v) if v then NoRecoil_Enable() else NoRecoil_Disable() end end })

HomeTab:CreateSection("🚨 Emergency")

HomeTab:CreateButton({ Name="🗑  PANIC — Disable Everything  (or press Delete)",
    Callback=function()
        pcall(PanicAll)
        Rayfield:Notify({Title="⚠ PANIC ACTIVATED",Content="Every feature has been killed.",Duration=5,Image=4483362458})
    end
})

-- ════════════════════════════════════════════════════════════
--  ⚔  COMBAT
-- ════════════════════════════════════════════════════════════
local CombatTab = Window:CreateTab("⚔  Combat", 4483362458)

CombatTab:CreateSection("🥊 Melee")

CombatTab:CreateToggle({ Name="Melee Aura  (hits nearby players)", CurrentValue=false, Flag="MeleeAura",
    Callback=function(v) if v then MeleeAura_Enable() else MeleeAura_Disable() end end })

CombatTab:CreateSlider({ Name="Aura Range", Range={3,25}, Increment=1, Suffix=" studs", CurrentValue=5, Flag="MeleeRange",
    Callback=function(v) MeleeAura_Range=v end })

CombatTab:CreateSection("🎯 Aimbot")

CombatTab:CreateToggle({ Name="Aimbot  (hold RMB)", CurrentValue=false, Flag="Aimbot",
    Callback=function(v) if v then Aimbot_Enable() else Aimbot_Disable() end end })

CombatTab:CreateSlider({ Name="FOV Radius", Range={10,500}, Increment=5, Suffix=" px", CurrentValue=100, Flag="AimFov",
    Callback=function(v) AimBot.Fov=v end })

CombatTab:CreateSlider({ Name="Smoothing  (lower = snappier)", Range={1,100}, Increment=1, Suffix="", CurrentValue=2, Flag="AimSmooth",
    Callback=function(v) AimBot.Smoothing=v/100 end })

CombatTab:CreateSection("🔫 Gun Mods")

CombatTab:CreateToggle({ Name="No Recoil", CurrentValue=false, Flag="NoRecoil",
    Callback=function(v) if v then NoRecoil_Enable() else NoRecoil_Disable() end end })

CombatTab:CreateToggle({ Name="No Spread", CurrentValue=false, Flag="NoSpread",
    Callback=function(v) GunSettings.Spread=v; if NoRecoil_Enabled then cacheWeapons();applyGunMods() end end })

CombatTab:CreateSection("💥 Auto Kill")

CombatTab:CreateToggle({ Name="Ragebot  (auto shoots closest enemy)", CurrentValue=false, Flag="Ragebot",
    Callback=function(v) if v then Ragebot_Enable() else Ragebot_Disable() end end })

-- ════════════════════════════════════════════════════════════
--  🏃  MOVEMENT
-- ════════════════════════════════════════════════════════════
local MovTab = Window:CreateTab("🏃  Movement", 4483362458)

MovTab:CreateSection("✈️  Fly")

MovTab:CreateToggle({ Name="Fly  (WASD + Space / Ctrl)", CurrentValue=false, Flag="Fly",
    Callback=function(v) if v then Fly_Enable() else Fly_Disable() end end })

MovTab:CreateSlider({ Name="Fly Speed", Range={10,300}, Increment=5, Suffix=" u/s", CurrentValue=50, Flag="FlySpeed",
    Callback=function(v) Fly_Speed=v end })

MovTab:CreateSection("🚶 Physics")

MovTab:CreateToggle({ Name="Noclip  (walk through walls)", CurrentValue=false, Flag="Noclip",
    Callback=function(v) if v then Noclip_Enable() else Noclip_Disable() end end })

MovTab:CreateSection("💨 Speed")

MovTab:CreateParagraph({
    Title   = "⚠️  Speed Hack — Not Available",
    Content = "Criminality validates movement server-side.\nAny WalkSpeed above default causes an instant server kill regardless of how it is applied.\n\nUse Fly instead — it bypasses the movement check entirely.",
})

MovTab:CreateSection("🦘 High Jump")

MovTab:CreateToggle({ Name="High Jump  (velocity impulse — safe)", CurrentValue=false, Flag="HighJump",
    Callback=function(v)
        if v then
            JumpPower_Enable()
            Rayfield:Notify({Title="🦘 High Jump ON",Content="Press Space to jump. One impulse per jump, grounded only.",Duration=4,Image=4483362458})
        else JumpPower_Disable() end
    end })

MovTab:CreateSlider({ Name="Jump Height", Range={60,180}, Increment=5, Suffix="", CurrentValue=80, Flag="JumpVal",
    Callback=function(v) JumpPower_Value=v end })

MovTab:CreateSection("⚡ Stamina")

MovTab:CreateToggle({ Name="Infinite Stamina  (req. hookfunction)", CurrentValue=false, Flag="InfStam",
    Callback=function(v) if v then InfiniteStamina_Enable() else InfiniteStamina_Disable() end end })

-- ════════════════════════════════════════════════════════════
--  👁  VISUALS
-- ════════════════════════════════════════════════════════════
local VisTab = Window:CreateTab("👁  Visuals", 4483362458)

VisTab:CreateSection("🔍 ESP")

VisTab:CreateToggle({ Name="Player ESP  (wallhack)", CurrentValue=false, Flag="PlayerESP",
    Callback=function(v) if v then ESP_Enable() else ESP_Disable() end end })

VisTab:CreateToggle({ Name="Safe / Register ESP  (✓/✗ labels + distance)", CurrentValue=false, Flag="SafeESP",
    Callback=function(v) if v then BredMakurz_Enable() else BredMakurz_Disable() end end })

VisTab:CreateSection("👻 Stealth")

VisTab:CreateToggle({ Name="Invisibility  (R6 only)", CurrentValue=false, Flag="Invis",
    Callback=function(v)
        if v then
            Invis_Enable()
            Rayfield:Notify({Title="👻 Invisibility ON",Content="Semi-transparent. Stay grounded to remain hidden.",Duration=5,Image=4483362458})
        else Invis_Disable() end
    end })

VisTab:CreateSection("🌞 Lighting")

VisTab:CreateToggle({ Name="FullBright  (max visibility at night)", CurrentValue=false, Flag="FullBright",
    Callback=function(v) if v then FullBright_Enable() else FullBright_Disable() end end })

VisTab:CreateSection("📷 Camera")

VisTab:CreateToggle({ Name="Custom FOV", CurrentValue=false, Flag="FovToggle",
    Callback=function(v) if v then Fov_Enable() else Fov_Disable() end end })

VisTab:CreateSlider({ Name="FOV Value", Range={50,130}, Increment=1, Suffix="°", CurrentValue=80, Flag="FovVal",
    Callback=function(v) Fov_Value=v end })

-- ════════════════════════════════════════════════════════════
--  🌾  FARMING
-- ════════════════════════════════════════════════════════════
local FarmTab = Window:CreateTab("🌾  Farming", 4483362458)

FarmTab:CreateSection("🤖 Full Automation")

FarmTab:CreateToggle({ Name="Autofarm  (Shadow + Crack + Collect all stacks)", CurrentValue=false, Flag="Autofarm",
    Callback=function(v)
        if v then
            Autofarm_Enable()
            Rayfield:Notify({Title="🌾 Autofarm ON",Content="Cracking safes, collecting all bread.\nShadow mode active.",Duration=6,Image=4483362458})
        else
            Autofarm_Disable()
            Rayfield:Notify({Title="🌾 Autofarm OFF",Content="Farming stopped.",Duration=3,Image=4483362458})
        end
    end })

FarmTab:CreateSection("🍞 Standalone Collector")

FarmTab:CreateToggle({ Name="Auto Pickup Money  (standalone)", CurrentValue=false, Flag="AutoPickup",
    Callback=function(v) if v then Collector_Activate() else Collector_Deactivate() end end })

FarmTab:CreateSection("👤 Stealth")

FarmTab:CreateToggle({ Name="Shadow Mode  (R6 only)", CurrentValue=false, Flag="ShadowMode",
    Callback=function(v)
        if v then
            _G.ActivateShadow()
            Rayfield:Notify({Title="👤 Shadow ON",Content="Stay grounded — you're hidden while prone.",Duration=5,Image=4483362458})
        else _G.DeactivateShadow() end
    end })

FarmTab:CreateSection("🏧 Auto-Deposit")

FarmTab:CreateToggle({ Name="Auto-Deposit at ATM  (prevents death-loss)", CurrentValue=false, Flag="AutoDeposit",
    Callback=function(v)
        AutoDeposit_Enabled = v
        if v then
            Rayfield:Notify({Title="🏧 Auto-Deposit ON",Content=string.format("Will deposit when in-hand cash exceeds $%d.", AutoDeposit_Threshold),Duration=5,Image=4483362458})
        end
    end })

FarmTab:CreateSlider({ Name="Deposit Threshold  (deposit when cash ≥ this)", Range={100,2000}, Increment=50, Suffix="$", CurrentValue=400, Flag="DepositThresh",
    Callback=function(v) AutoDeposit_Threshold=v end })

FarmTab:CreateButton({ Name="🏧  Deposit Now  (teleport to nearest ATM)",
    Callback=function()
        FarmStats.LastAction="🏧 Manual deposit..."
        local ok = pcall(doATMDeposit)
        Rayfield:Notify({Title= ok and "🏧 Deposited!" or "🏧 ATM",Content= ok and "Cash sent to bank." or "Teleported near ATM — press E to deposit.",Duration=4,Image=4483362458})
    end })

FarmTab:CreateSection("🔀 Server Management")

FarmTab:CreateToggle({ Name="Auto Server-Hop  (when map is fully depleted)", CurrentValue=false, Flag="AutoHop",
    Callback=function(v)
        AutoHop_Enabled=v
        if v then Rayfield:Notify({Title="🔀 Auto-Hop ON",Content="Will hop to fresh server when all safes are broken.",Duration=5,Image=4483362458}) end
    end })

FarmTab:CreateSection("ℹ️  Loot Reference  (Criminality Wiki averages)")

FarmTab:CreateParagraph({
    Content = "🏪 Cash Register:   $80 – $330    avg ~$205\n"
           .. "🏦 Small Safe:       $120 – $720    avg ~$420\n"
           .. "🏛 Big Safe:          $200 – $1,080  avg ~$640\n\n"
           .. "💡 More players in server = higher payout per crack\n"
           .. "💡 Crowbar: 4 hits (small/register), 5 hits (big)\n"
           .. "💡 Safes respawn: 12 min  |  Registers: 10 min",
})

-- ════════════════════════════════════════════════════════════
--  🔧  MISC
-- ════════════════════════════════════════════════════════════
local MiscTab = Window:CreateTab("🔧  Misc", 4483362458)

MiscTab:CreateSection("🛡 Detection & Safety")

MiscTab:CreateToggle({ Name="Staff Detector  (auto-kick on join)", CurrentValue=false, Flag="StaffDet",
    Callback=function(v)
        if v then
            AdminCheck_Enable()
            Rayfield:Notify({Title="🛡 Staff Detector ON",Content="Scanning current players now...",Duration=4,Image=4483362458})
        else AdminCheck_Disable() end
    end })

MiscTab:CreateSection("🔓 Lockpick & Doors")

MiscTab:CreateToggle({ Name="No Fail Lockpick", CurrentValue=false, Flag="NoFailLP",
    Callback=function(v) if v then NoFailLockpick_Enable() else NoFailLockpick_Disable() end end })

MiscTab:CreateToggle({ Name="Auto Open Nearby Doors", CurrentValue=false, Flag="AutoOpen",
    Callback=function(v) if v then OpenNearbyDoors_Enable() else OpenNearbyDoors_Disable() end end })

MiscTab:CreateToggle({ Name="Auto Unlock Nearby Doors", CurrentValue=false, Flag="AutoUnlock",
    Callback=function(v) if v then UnlockNearbyDoors_Enable() else UnlockNearbyDoors_Disable() end end })

MiscTab:CreateSection("🔧 Server Tools")

MiscTab:CreateButton({ Name="🔀  Hop to New Server",
    Callback=function()
        Rayfield:Notify({Title="🔀 Hopping...",Content="Finding a fresh server to join.",Duration=3,Image=4483362458})
        task.wait(1.5)
        pcall(function() game:GetService("TeleportService"):Teleport(game.PlaceId,LocalPlayer) end)
    end })

MiscTab:CreateButton({ Name="🔁  Rejoin Same Server",
    Callback=function()
        pcall(function() game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId,game.JobId,LocalPlayer) end)
    end })

MiscTab:CreateButton({ Name="🗑  PANIC — Kill All Features  (or press Delete)",
    Callback=function()
        pcall(PanicAll)
        Rayfield:Notify({Title="⚠ PANIC",Content="All features disabled.",Duration=5,Image=4483362458})
    end })

-- ════════════════════════════════════════════════════════════
--  📊  STATS  (live earnings dashboard)
-- ════════════════════════════════════════════════════════════
local StatsTab = Window:CreateTab("📊  Stats", 4483362458)

StatsTab:CreateSection("💰 Earnings This Session")
local earningsPara = StatsTab:CreateParagraph({ Title="Cash Earned", Content="Waiting for first cycle..." })

StatsTab:CreateSection("📦 Loot Breakdown")
local lootPara = StatsTab:CreateParagraph({ Title="Targets Cracked", Content="No data yet." })

StatsTab:CreateSection("🎯 $ Goal Tracker")
local goalPara = StatsTab:CreateParagraph({ Title="Progress to Goal", Content="Set goal below." })

StatsTab:CreateSlider({ Name="Cash Goal", Range={1000,100000}, Increment=500, Suffix="$", CurrentValue=10000, Flag="CashGoal",
    Callback=function(v) FarmStats.GoalDollars=v end })

StatsTab:CreateSection("⏱ Session Info")
local sessionPara = StatsTab:CreateParagraph({ Title="Session Details", Content="Just started." })

StatsTab:CreateSection("📋 Loot History")
local logPara = StatsTab:CreateParagraph({ Title="Recent Loot Log  (last 8)", Content="No cracks yet." })

StatsTab:CreateSection("📍 Live Status")
local statusPara = StatsTab:CreateParagraph({ Title="Current Action", Content="🔴  Autofarm is OFF" })

-- ── Helpers ───────────────────────────────────────────────
local function fmtTime(s)
    local h=math.floor(s/3600); local m=math.floor((s%3600)/60); local sec=s%60
    if h>0 then return string.format("%dh %dm %ds",h,m,sec)
    elseif m>0 then return string.format("%dm %ds",m,sec)
    else return string.format("%ds",sec) end
end

local function fmtDollars(n)
    n = math.max(math.floor(n), 0)
    local s = tostring(n); local r=""; local len=#s
    for i=1,len do if i>1 and (len-i+1)%3==0 then r=r.."," end; r=r..s:sub(i,i) end
    return "$"..r
end

local function progressBar(pct, width)
    width = width or 20
    local filled = math.floor(pct * width / 100)
    return "["..string.rep("█",filled)..string.rep("░",width-filled).."]  "..string.format("%.1f%%",pct)
end

-- ── Main refresh ──────────────────────────────────────────
local function refreshStats()
    pcall(updateCashTracking)

    local elapsed      = math.max(os.time()-FarmStats.SessionStart, 1)
    local totalCracks  = FarmStats.SafesCracked+FarmStats.BigSafesCracked+FarmStats.RegistersCracked
    local earnRate     = FarmStats.EarnedDollars / (elapsed/3600)
    if earnRate > FarmStats.PeakEarnRate then FarmStats.PeakEarnRate=earnRate end

    local estFromLoot = FarmStats.SafesCracked*420 + FarmStats.BigSafesCracked*640 + FarmStats.RegistersCracked*205
    local cashNow     = getPlayerCash()
    local hasReal     = FarmStats.EarnedDollars > 0
    local earned      = hasReal and FarmStats.EarnedDollars or estFromLoot
    local serverCount = #(Players:GetPlayers())

    -- ── Milestone notifications ─────────────────────────────
    for _, ms in ipairs(MILESTONES) do
        if earned >= ms and not FarmStats.MilestonesHit[ms] then
            FarmStats.MilestonesHit[ms] = true
            pcall(function()
                Rayfield:Notify({
                    Title   = "💰 Milestone Reached!",
                    Content = string.format("You've earned %s this session! Keep it up 🔥", fmtDollars(ms)),
                    Duration = 8,
                    Image    = 4483362458,
                })
            end)
        end
    end

    -- ── Goal reached (fires once) ──────────────────────────
    local goal = FarmStats.GoalDollars
    if earned >= goal and not FarmStats.GoalReached then
        FarmStats.GoalReached = true
        pcall(function()
            Rayfield:Notify({
                Title   = "🎯 GOAL REACHED!",
                Content = string.format("Hit %s earned this session! 🎉", fmtDollars(goal)),
                Duration = 10,
                Image    = 4483362458,
            })
        end)
    end
    if earned < goal then FarmStats.GoalReached = false end  -- reset if stats were cleared

    -- Earnings
    earningsPara:Set({ Title="💰 Cash Earned This Session",
        Content = hasReal
            and string.format("✅ Tracked:      %s\n📈 Rate:           ~%s / hr\n🏆 Peak rate:   ~%s / hr\n💼 In wallet:   %s",
                fmtDollars(FarmStats.EarnedDollars), fmtDollars(earnRate),
                fmtDollars(FarmStats.PeakEarnRate), cashNow and fmtDollars(cashNow) or "unknown")
            or string.format("📊 Estimated:  %s  (wiki avg)\n🔍 Tracking:    scanning cash value...\n📈 Est rate:     ~%s / hr\n💼 In wallet:   %s",
                fmtDollars(estFromLoot),
                fmtDollars(totalCracks>0 and estFromLoot/(elapsed/3600) or 0),
                cashNow and fmtDollars(cashNow) or "unknown"),
    })

    -- Loot breakdown
    lootPara:Set({ Title="📦 Loot Breakdown",
        Content = string.format(
            "🏦 Small Safes:     %d  (~%s avg)\n"
         .. "🏛 Big Safes:        %d  (~%s avg)\n"
         .. "🏪 Registers:        %d  (~%s avg)\n"
         .. "🍞 Bread Stacks:    %d  collected\n"
         .. "🔨 Crowbars Bought: %d\n"
         .. "💀 Deaths:            %d",
            FarmStats.SafesCracked,    fmtDollars(420),
            FarmStats.BigSafesCracked, fmtDollars(640),
            FarmStats.RegistersCracked,fmtDollars(205),
            FarmStats.BreadCollected,
            FarmStats.CrowbarsBought,
            FarmStats.Deaths),
    })

    -- Goal progress bar
    local pct     = math.min(earned/math.max(goal,1)*100, 100)
    local remain  = math.max(goal-earned, 0)
    local etaStr
    if pct >= 100 then etaStr = "🎉 GOAL REACHED!"
    elseif earnRate > 0 and remain > 0 then
        etaStr = "⏳ "..fmtTime(math.floor(remain/earnRate*3600)).." remaining"
    else etaStr = "calculating..." end

    goalPara:Set({ Title=string.format("🎯 Goal: %s", fmtDollars(goal)),
        Content = string.format("%s\n%s  /  %s\n%s",
            progressBar(pct, 22),
            fmtDollars(earned), fmtDollars(goal),
            etaStr),
    })

    -- Session + server info
    local pingMs=0; pcall(function() pingMs=math.floor(LocalPlayer:GetNetworkPing()*1000) end)
    sessionPara:Set({ Title="⏱ Session Details",
        Content = string.format(
            "🕒 Time:              %s\n"
         .. "🎯 Cracks / hr:      ~%.1f\n"
         .. "👥 Players in server: %d  (%s payout)\n"
         .. "📡 Ping:               %dms  %s\n"
         .. "🔥 Autofarm:          %s",
            fmtTime(elapsed),
            totalCracks/(elapsed/3600),
            serverCount, serverCount >= 15 and "high 💰" or serverCount >= 8 and "medium" or "low",
            pingMs, isPingHigh and "⚠ HIGH" or "✅ OK",
            autofarmEnabled and "🟢 Running" or "🔴 Stopped"),
    })

    -- Loot history log
    local logText = #FarmStats.LootLog > 0
        and table.concat(FarmStats.LootLog, "\n")
        or  "No cracks recorded yet."
    logPara:Set({ Title="📋 Recent Loot Log  (last 8)", Content=logText })

    -- Status
    statusPara:Set({ Title="📍 Current Action",
        Content = autofarmEnabled
            and ("🟢  "..FarmStats.LastAction)
            or   "🔴  Autofarm is OFF",
    })
end

-- Auto-refresh every 4 seconds
task.spawn(function() while task.wait(4) do pcall(refreshStats) end end)

StatsTab:CreateButton({ Name="🔄  Refresh Now",
    Callback=function()
        pcall(refreshStats)
        local earned = FarmStats.EarnedDollars>0
            and fmtDollars(FarmStats.EarnedDollars)
            or ("~"..fmtDollars(FarmStats.SafesCracked*420+FarmStats.BigSafesCracked*640+FarmStats.RegistersCracked*205).." est.")
        Rayfield:Notify({
            Title="📊 Stats Refreshed",
            Content=string.format("Earned: %s  |  S:%d  B:%d  R:%d  Bread:%d",
                earned, FarmStats.SafesCracked, FarmStats.BigSafesCracked,
                FarmStats.RegistersCracked, FarmStats.BreadCollected),
            Duration=6, Image=4483362458,
        })
    end })

StatsTab:CreateButton({ Name="🗑  Reset Session Stats",
    Callback=function()
        FarmStats_Reset(); pcall(refreshStats)
        Rayfield:Notify({Title="🗑 Stats Reset",Content="New session started. Cash baseline updated.",Duration=3,Image=4483362458})
    end })

-- ════════════════════════════════════════════════════════════
--  ⚙  SETTINGS
-- ════════════════════════════════════════════════════════════
local SetTab = Window:CreateTab("⚙  Settings", 4483362458)

SetTab:CreateSection("📡 Autofarm Performance")

SetTab:CreateSlider({ Name="Ping Threshold  (farm pauses above this)", Range={50,500}, Increment=10, Suffix=" ms", CurrentValue=150, Flag="PingThresh",
    Callback=function(v) pingThreshold=v end })

SetTab:CreateSection("🎯 Target Selection")

SetTab:CreateDropdown({ Name="Target Priority", Options={"Nearest","BigSafeFirst","RegisterFirst"}, CurrentOption={"Nearest"}, Flag="TargetPriority",
    Callback=function(opt)
        TargetPriority = opt[1]
        local labels = {Nearest="📍 Nearest target", BigSafeFirst="🏛 Big Safes first (most $)", RegisterFirst="🏪 Registers first (fastest)"}
        Rayfield:Notify({Title="🎯 Priority Changed",Content=labels[opt[1]] or opt[1],Duration=4,Image=4483362458})
    end })

SetTab:CreateSection("🔭 Aimbot Options")

SetTab:CreateToggle({ Name="Wall Check  (only aim at visible targets)", CurrentValue=true, Flag="WallCheck",
    Callback=function(v) AimBot.WallCheck=v end })

SetTab:CreateToggle({ Name="Sticky Aim  (lock target between shots)", CurrentValue=false, Flag="StickyAim",
    Callback=function(v) AimBot.StickyAim=v end })

SetTab:CreateDropdown({ Name="Aim Part", Options={"HumanoidRootPart","Head","Torso"}, CurrentOption={"HumanoidRootPart"}, Flag="AimPart",
    Callback=function(opt) AimBot.AimPart=opt[1] end })

SetTab:CreateSection("🔫 No Recoil Options")

SetTab:CreateToggle({ Name="Remove Spread", CurrentValue=false, Flag="RemSpread",
    Callback=function(v) GunSettings.Spread=v end })

SetTab:CreateSlider({ Name="Spread Amount  (0 = no spread)", Range={0,10}, Increment=1, Suffix="", CurrentValue=0, Flag="SpreadAmt",
    Callback=function(v) GunSettings.SpreadAmount=v end })

SetTab:CreateSection("📋 About EQR Hub")

SetTab:CreateParagraph({
    Title   = "EQR Hub  v2.1  —  Built for Dwitty19",
    Content = "👤 Script by:    helloitsme#4243\n"
           .. "🎮 Built for:    Dwitty19\n"
           .. "🎮 Game:          Criminality  (SECTOR-07)\n"
           .. "⚡ Executor:     Level 7+  (Synapse X / KRNL / Fluxus)\n"
           .. "🔑 Toggle UI:   RightAlt\n"
           .. "🗑 Panic:          Delete key\n\n"
           .. "✅ Features in this build:\n"
           .. "• Autofarm — small safe + big safe + register + full bread sweep\n"
           .. "• Respawn timer tracking (skips safes on cooldown, shows ETAs)\n"
           .. "• Target priority mode (Nearest / Big Safe first / Register first)\n"
           .. "• Auto ATM deposit when cash hits threshold\n"
           .. "• Auto server-hop when map is fully depleted\n"
           .. "• Real-time $ earnings tracker + goal progress bar\n"
           .. "• Milestone notifications ($1k → $100k)\n"
           .. "• Rolling 8-entry loot history log\n"
           .. "• Safe / Register ESP with $ range + respawn countdown\n"
           .. "• Shadow Mode + Invisibility stealth  (R6 only)\n"
           .. "• Aimbot (FOV, smoothing, wall check, sticky, aim part)\n"
           .. "• Ragebot, Melee Aura (adjustable range)\n"
           .. "• Staff Detector with instant auto-kick\n"
           .. "• No Recoil + No Spread\n"
           .. "• High Jump (safe velocity impulse)\n"
           .. "• No Fail Lockpick, Auto open/unlock doors\n"
           .. "• Fly, Noclip, FullBright, Custom FOV\n"
           .. "• Infinite Stamina\n"
           .. "• Server Hop + Rejoin\n"
           .. "• Panic kill-switch (Delete key)",
})

-- ════════════════════════════════════════════════════════════
--  BOOT SEQUENCE
-- ════════════════════════════════════════════════════════════
task.wait(0.5)

-- Baseline cash for real tracking
task.delay(3, function()
    _cashBaseline   = getPlayerCash()
    _cashLastSample = _cashBaseline
    pcall(refreshStats)
end)

Rayfield:Notify({
    Title   = "✅  EQR Hub v2.1  —  Hey Dwitty19!",
    Content = "All systems ready. Happy farming 💰\nRightAlt = toggle UI  |  Delete = panic",
    Duration = 8,
    Image   = 4483362458,
})

print("[EQR Hub v2.1] Loaded — by helloitsme#4243 — built for Dwitty19")
