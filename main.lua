-- Pattom Hub: animal-throwing game helper. UI: ui.lua (Theseus-based, restyled).
-- Built from the DevilDump of PlaceId 120219252362013. Not tested against the live game.
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local VirtualUser = game:GetService("VirtualUser")
local LocalPlayer = Players.LocalPlayer

local Config = {
    Folder = "pattom-hub",
    UiFile = "pattom-hub/ui.lua",
    LogoFile = "pattom-hub/pattomhub.png",
    LoadTimeout = 15,
    MaxFailures = 8,
    RetryDelay = 1,
}

if getgenv and getgenv().PattomHubUnload then
    pcall(getgenv().PattomHubUnload)
end

local alive = true
local connections, cleanups = {}, {}

local S = {
    AutoThrow = false, AutoPerfect = true,
    RevealBoost = true, RevealSpeed = 3,
    AutoTrain = false, TrainSeconds = 60, ThrowsPerCycle = 10,
    AutoBonus = false, BonusDelay = 0.35,
    AutoSell = false, SellInterval = 5,
    AutoFood = false, AutoStand = false, AutoFence = false,
    AutoEquipBest = false, AutoClaimFree = false,
}
local Stats = { Throws = 0, Sold = 0, Bonus = 0, Food = 0, Fails = 0, Last = "-" }
-- Filled in by the UI section; the farm loop calls these without knowing about the UI.
local Hooks = { Notify = function() end, Halt = function() end }

local function warnf(...) warn("[PattomHub]", ...) end

local function waitChild(parent, name, timeout)
    local ok, child = pcall(parent.WaitForChild, parent, name, timeout)
    return ok and child or nil
end

local function findPath(root, ...)
    local node = root
    for _, name in ipairs({ ... }) do
        node = node and node:FindFirstChild(name)
    end
    return node
end

-- Remotes are game-specific; missing them disables farm features but NOT the GUI
local RemotesFolder = waitChild(RS, "Remotes", Config.LoadTimeout)
if not RemotesFolder then
    warnf("ReplicatedStorage.Remotes not found — farm features disabled, GUI will still load")
end

local function invoke(name, ...)
    if not RemotesFolder then return { Ok = false, Reason = "NoRemotes" } end
    local r = RemotesFolder:FindFirstChild(name)
    if not r or not r:IsA("RemoteFunction") then return { Ok = false, Reason = "Missing:" .. name } end
    local ok, res = pcall(r.InvokeServer, r, ...)
    if not ok then return { Ok = false, Reason = tostring(res) } end
    if type(res) ~= "table" then return { Ok = false, Reason = "BadResponse" } end
    return res
end

local function sleep(seconds)
    local t = os.clock()
    while alive and os.clock() - t < seconds do task.wait(0.05) end
end

local function loadModule(instance)
    if not instance then return nil end
    local ok, mod = pcall(require, instance)
    return ok and type(mod) == "table" and mod or nil
end

-- Game modules. The game has already loaded them, so require returns the cached tables.
local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts", Config.LoadTimeout)
local Controllers = PlayerScripts and findPath(PlayerScripts, "Client", "Controllers")
local function controller(name) return Controllers and loadModule(Controllers:FindFirstChild(name)) end

local GameConfig = loadModule(findPath(RS, "Config", "GameConfig"))
local MeterMath = loadModule(findPath(RS, "Shared", "ThrowMeterMath"))
local FoodsConfig = loadModule(findPath(RS, "Config", "FoodsConfig"))
local BalanceCurve = loadModule(findPath(RS, "Shared", "BalanceCurve"))
local ThrowMeter = controller("ThrowMeter")
local Training = controller("TrainingController")
local ClientState = controller("ClientState")
local Data = controller("DataController")

local ThrowCfg = GameConfig and GameConfig.Throw or {}
local COOLDOWN = ThrowCfg.Cooldown or 1.5

-- Auto Perfect: ThrowMeter.Run has a built-in hook, TestAutoTap = seconds, that taps the meter by
-- itself after that delay. Tapping at the meter peak (ThrowMeterMath.HalfPeriod) gives +20 and the
-- meter, sounds and animations all play as normal.
local function applyPerfect(enabled)
    if not ThrowMeter then return false end
    local value = nil
    if enabled and MeterMath then value = math.max(0.1, MeterMath.HalfPeriod() - 0.01) end
    local ok = pcall(function() ThrowMeter.TestAutoTap = value end)
    if not ok and setreadonly then
        pcall(setreadonly, ThrowMeter, false)
        ok = pcall(function() ThrowMeter.TestAutoTap = value end)
    end
    return ok
end

-- Reveal boost: GameConfig.Sequence holds the timings of the zoom, name reveal and "tap to continue"
-- screen. They are read on every reveal, so dividing them speeds up the name display only.
local SEQUENCE_KEYS = { "POVDuration", "RevealZoomNormal", "RevealZoomDramatic", "ShowTimeNormal", "ShowTimeShort", "SkipAfterRevealDelay" }
local SEQUENCE_FLOOR = { POVDuration = 1.5, RevealZoomNormal = 0.3, RevealZoomDramatic = 0.7, ShowTimeNormal = 0.8, ShowTimeShort = 0.6, SkipAfterRevealDelay = 0.2 }
local Sequence = GameConfig and GameConfig.Sequence
local originalSequence = {}
if Sequence then
    for _, key in ipairs(SEQUENCE_KEYS) do originalSequence[key] = Sequence[key] end
end

local function applyReveal()
    if not Sequence then return false end
    local speed = S.RevealBoost and math.max(1, S.RevealSpeed) or 1
    for key, base in pairs(originalSequence) do
        if type(base) == "number" then
            local value = math.max(base / speed, math.min(base, SEQUENCE_FLOOR[key] or base))
            pcall(function() Sequence[key] = value end)
        end
    end
    return true
end

local function character()
    local ch = LocalPlayer.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hrp and hum and hum.Health > 0 then return hrp, hum end
    return nil
end

local function busyWith() return ClientState and ClientState.Busy or nil end
local function trainingRunning() return Training and Training.IsRunning and Training.IsRunning() or false end

local function teleport(hrp, position)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.CFrame = CFrame.new(position) * (hrp.CFrame - hrp.CFrame.Position)
end

-- Waits for the game to free the player (reveal screens, shops) instead of failing at once.
local function waitUntilFree(limit)
    local t = os.clock()
    while alive and busyWith() and os.clock() - t < limit do task.wait(0.2) end
    return not busyWith()
end

-- The game starts a throw by itself when the character is inside workspace.StarterArea and past
-- its CrossLine (ThrowController.pollLine). Teleporting there lets the normal throw sequence,
-- animations and reveal run from anywhere on the map.
local function throwPosition(hrp, hum)
    local area = workspace:FindFirstChild("StarterArea")
    if not area then return nil end
    local line = area:FindFirstChild("CrossLine")
    local half = area.Size / 2
    local lineZ = line and line.Position.Z or area.Position.Z + half.Z
    local z = math.max(area.Position.Z - half.Z + 1, lineZ - 2)
    if z >= lineZ then z = lineZ - 0.5 end
    local y = area.Position.Y + half.Y + hum.HipHeight + hrp.Size.Y / 2 + 0.1
    return Vector3.new(area.Position.X, y, z)
end

local lastThrowEnd = 0

local function throwOnce()
    if not waitUntilFree(15) then return false, "busy: " .. tostring(busyWith()) end
    local gap = COOLDOWN + 0.2 - (os.clock() - lastThrowEnd)
    if gap > 0 then sleep(gap) end
    local hrp, hum = character()
    if not hrp then return false, "no character" end
    local target = throwPosition(hrp, hum)
    if not target then return false, "StarterArea not found" end
    teleport(hrp, target)
    local t = os.clock()
    while alive and busyWith() ~= "Throw" and os.clock() - t < 4 do task.wait(0.05) end
    if busyWith() ~= "Throw" then return false, "throw did not start" end
    t = os.clock()
    while alive and busyWith() == "Throw" and os.clock() - t < 90 do task.wait(0.1) end
    lastThrowEnd = os.clock()
    if busyWith() == "Throw" then return false, "throw timed out" end
    return true
end

-- Training starts when the character stands on the training circle (TrainingController.pollCircle).
local function trainingSpot()
    return findPath(workspace, "LocalPlotProps", "TrainingArea", "TrainingSpot")
end

local function startTraining()
    if trainingRunning() then return true end
    if not waitUntilFree(15) then return false, "busy: " .. tostring(busyWith()) end
    if Data and (Data:Get("Stand") or 0) < 1 then return false, "buy the pull-up bar first" end
    local hrp = character()
    local spot = trainingSpot()
    if not (hrp and spot) then return false, "training spot not found" end
    local radius = math.min(spot.Size.Y, spot.Size.Z) / 2 * 0.64
    -- step off the circle first so the game's own enter-the-circle check fires again
    teleport(hrp, spot.Position + Vector3.new(0, 4, radius + 8))
    sleep(0.35)
    teleport(hrp, spot.Position + Vector3.new(0, 3, 0))
    local t = os.clock()
    while alive and os.clock() - t < 6 do
        if trainingRunning() then return true end
        task.wait(0.1)
    end
    return false, "training did not start"
end

local function stopTraining()
    if not trainingRunning() then return end
    pcall(Training.Stop)
    local t = os.clock()
    while alive and trainingRunning() and os.clock() - t < 25 do task.wait(0.1) end
    sleep(1.2)
end

-- Farm loop. Throw + Train both on: train for TrainSeconds, then ThrowsPerCycle throws, repeat.
local cycle = { phase = "throw", throws = 0, startedAt = os.clock() }
local failStreak = 0

local function noteResult(flag, ok, reason)
    if ok then failStreak = 0 return end
    Stats.Fails += 1
    failStreak += 1
    Stats.Last = tostring(reason)
    if failStreak >= Config.MaxFailures then
        failStreak = 0
        Hooks.Notify(flag .. " stopped: " .. tostring(reason), "Warning")
        Hooks.Halt(flag)
    end
    sleep(Config.RetryDelay)
end

local function throwStep()
    if trainingRunning() then stopTraining() end
    local ok, reason = throwOnce()
    noteResult("AutoThrow", ok, reason)
    if ok then Stats.Throws += 1 end
    return ok
end

local function trainStep()
    local ok, reason = startTraining()
    noteResult("AutoTrain", ok, reason)
    if ok then cycle.startedAt = os.clock() end
    return ok
end

local function farmStep()
    local throw, train = S.AutoThrow, S.AutoTrain
    if throw and train then
        if cycle.phase == "train" then
            if not trainingRunning() then
                trainStep()
            elseif os.clock() - cycle.startedAt >= S.TrainSeconds then
                stopTraining()
                cycle.phase, cycle.throws = "throw", 0
            end
            sleep(0.5)
        else
            if throwStep() then
                cycle.throws += 1
                if cycle.throws >= S.ThrowsPerCycle then cycle.phase = "train" end
            end
        end
    elseif throw then
        throwStep()
    elseif train then
        if not trainingRunning() then trainStep() end
        sleep(1)
    else
        sleep(0.5)
    end
end

task.spawn(function()
    while alive do
        local ok, err = pcall(farmStep)
        if not ok then warnf("farm loop:", err) sleep(1) end
    end
end)

-- Timed loops: each runs its action only while its flag is on.
local function every(flag, interval, action)
    task.spawn(function()
        while alive do
            if S[flag] then
                local ok, err = pcall(action)
                if not ok then warnf(flag, err) end
            end
            sleep(type(interval) == "function" and interval() or interval)
        end
    end)
end

local function sellAll()
    local res = invoke("Plot_SellAll")
    if res.Ok then Stats.Sold += res.Count or 0 end
    return res
end

-- Auto Food: buys the best food that is unlocked, not owned yet and affordable, then equips the
-- best owned one. Same calls as the shop cards: Shop_Buy(index) and Shop_Equip(index).
local function foodPrice(food)
    if BalanceCurve and BalanceCurve.GetItemPrice then
        local ok, price = pcall(BalanceCurve.GetItemPrice, LocalPlayer, food)
        if ok and type(price) == "number" then return price end
    end
    return food.Price
end

local function upgradeFood()
    if not (Data and FoodsConfig) then return end
    local money = Data:Get("Money") or 0
    local equipped = Data:Get("EquippedFood") or 0
    local bestOwned, buy = 0, nil
    for i = 1, FoodsConfig.CountAll() do
        local food = FoodsConfig.GetAny(i)
        if food and not FoodsConfig.IsLocked(i) then
            if Data:GetPath("OwnedFoods." .. i) == true then
                bestOwned = i
            else
                local price = foodPrice(food)
                if type(price) == "number" and price <= money then buy = i end
            end
        end
    end
    if buy and buy > bestOwned then
        local res = invoke("Shop_Buy", buy)
        if res.Ok then
            Stats.Food += 1
            bestOwned = buy
        else
            Stats.Last = "Food: " .. tostring(res.Reason)
        end
    end
    if bestOwned > 0 and equipped ~= bestOwned then invoke("Shop_Equip", bestOwned) end
end

every("AutoSell", function() return S.SellInterval end, sellAll)
every("AutoFood", 3, upgradeFood)
local function equipBest()
    local res = invoke("Plot_EquipBest")
    if not res.Ok then
        Stats.Last = "Equip: " .. tostring(res.Reason)
    end
end
every("AutoEquipBest", 5, equipBest)
every("AutoClaimFree", 30, function() invoke("Shop_ClaimFree") end)
every("AutoStand", 3, function() invoke("Stand_Upgrade") end)
every("AutoFence", 3, function() invoke("Plot_UpgradeFence") end)

-- Auto Bonus x2: the game shows a purple ImageButton named "TapBonus" inside "TapBonusLayer".
-- We fire that button's own Activated handlers so the game runs its normal claim code
-- (Training_TapBonus with the right id). A real mouse click is the second choice.
local GuiService = game:GetService("GuiService")
local CAN_PRESS = (getconnections or firesignal) ~= nil

local function pressButton(button)
    if getconnections then
        local ok, list = pcall(getconnections, button.Activated)
        if ok and type(list) == "table" and #list > 0 then
            for _, c in ipairs(list) do
                local fired = pcall(function() c:Fire() end)
                if not fired and c.Function then pcall(c.Function) end
            end
            return true
        end
    end
    if firesignal then return (pcall(firesignal, button.Activated)) end
    return false
end

local function clickButton(button)
    local ok, vim = pcall(game.GetService, game, "VirtualInputManager")
    if not (ok and vim) then return false end
    local gui = button:FindFirstAncestorOfClass("ScreenGui")
    local inset = (gui and gui.IgnoreGuiInset) and Vector2.zero or GuiService:GetGuiInset()
    local pos = button.AbsolutePosition + button.AbsoluteSize / 2 + inset
    return (pcall(function()
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
        task.wait(0.05)
        vim:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
    end))
end

local function claimBonus(button)
    sleep(math.max(S.BonusDelay, 0.15))
    if not (alive and S.AutoBonus and button.Parent and button.Active) then return end
    if CAN_PRESS then pressButton(button) end
    sleep(0.3)
    if button.Parent and button.Active then clickButton(button) sleep(0.3) end
    if not button.Active then Stats.Bonus += 1 end
end

local playerGui = LocalPlayer:WaitForChild("PlayerGui", Config.LoadTimeout)
if playerGui then
    table.insert(connections, playerGui.DescendantAdded:Connect(function(d)
        if S.AutoBonus and d.Name == "TapBonus" and d:IsA("ImageButton") then task.spawn(claimBonus, d) end
    end))
end

-- Executors with neither getconnections nor firesignal: claim straight from the server event.
local bonusEvent = RemotesFolder and RemotesFolder:FindFirstChild("Training_Bonus")
if bonusEvent and bonusEvent:IsA("RemoteEvent") and not CAN_PRESS then
    table.insert(connections, bonusEvent.OnClientEvent:Connect(function(id, deadline)
        if not S.AutoBonus then return end
        task.delay(math.max(S.BonusDelay, 0.3), function()
            if not (alive and S.AutoBonus) then return end
            if deadline and deadline - workspace:GetServerTimeNow() < 0.2 then return end
            if invoke("Training_TapBonus", id).Ok then Stats.Bonus += 1 end
        end)
    end))
end

-- Anti-AFK
table.insert(connections, LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end))

local function unload()
    alive = false
    for _, c in ipairs(connections) do pcall(c.Disconnect, c) end
    pcall(applyPerfect, false)
    if Sequence then
        for key, base in pairs(originalSequence) do pcall(function() Sequence[key] = base end) end
    end
    for _, fn in ipairs(cleanups) do pcall(fn) end
    if getgenv and getgenv().PattomHubUnload == unload then getgenv().PattomHubUnload = nil end
end
if getgenv then getgenv().PattomHubUnload = unload end

applyPerfect(S.AutoPerfect)
applyReveal()

local BaseUrl = "https://raw.githubusercontent.com/Razahaider51216/pattomhub/main/"

-- Ensure assets folder and files exist locally for getcustomasset to work
local function ensureAssets()
    local hasFs = writefile and makefolder
    if not hasFs then return end
    pcall(function()
        if isfolder and not isfolder(Config.Folder) then
            makefolder(Config.Folder)
        end
        if game.HttpGet then
            local okLogo, logoData = pcall(game.HttpGet, game, BaseUrl .. "pattomhub.png?t=" .. os.time())
            if okLogo and type(logoData) == "string" and #logoData > 100 then
                writefile(Config.LogoFile, logoData)
            end
        end
    end)
end
ensureAssets()

-- UI: always fetch latest from GitHub with cache-buster, fallback to local file
local function loadLibrary()
    local body = nil
    -- 1. Fetch latest directly from GitHub
    if game.HttpGet then
        local okGet, res = pcall(game.HttpGet, game, BaseUrl .. "ui.lua?t=" .. os.time())
        if okGet and type(res) == "string" and res:sub(-64):find("return Library%s*$") then
            body = res
            if writefile and isfolder and isfolder(Config.Folder) then
                pcall(writefile, Config.UiFile, body)
            end
        end
    end
    -- 2. Fallback to cached local file
    if not body and isfile and readfile and isfile(Config.UiFile) then
        local okRead, res = pcall(readfile, Config.UiFile)
        if okRead and type(res) == "string" and res:sub(-64):find("return Library%s*$") then
            body = res
        end
    end
    if not body then
        warnf("could not load ui.lua from GitHub or local file")
        return nil
    end
    local chunk, compileErr = loadstring(body)
    if not chunk then warnf("UI compile error:", compileErr) return nil end
    local ok, lib = pcall(chunk)
    if not ok or type(lib) ~= "table" then warnf("UI init error:", lib) return nil end
    return lib
end

local Library = loadLibrary()
if not Library then unload() return end

local function T(en, th) return Library:T(en, th) end
Hooks.Notify = function(text, kind) Library:Notify("Pattom Hub", text, 4, kind or "Info") end
Hooks.Halt = function(flag)
    local toggle = Library.Toggles[flag]
    if toggle then toggle:SetValue(false) end
end
Library:OnUnload(unload)

local function addToggle(group, flag, text, description, default, onChange)
    return group:AddToggle(flag, {
        Text = text, Description = description, Default = default or false,
        Callback = function(value)
            S[flag] = value == true
            if onChange then onChange(S[flag]) end
        end,
    })
end

local function addSlider(group, flag, text, min, max, default, suffix, rounding, onChange)
    return group:AddSlider(flag, {
        Text = text, Min = min, Max = max, Default = default, Suffix = suffix or "",
        Rounding = rounding or 0,
        Callback = function(value)
            S[flag] = tonumber(value) or default
            if onChange then onChange(S[flag]) end
        end,
    })
end

local function buildFarmTab(window)
    local tab = window:AddTab(T("Farm", "ฟาร์ม"), "farm", T("Throw, train, bonus", "โยน เทรน โบนัส"))

    local throwBox = tab:AddLeftGroupbox(T("Throw", "โยน"), "throw")
    addToggle(throwBox, "AutoThrow", T("Auto Throw", "โยนอัตโนมัติ"),
        T("Teleports to the throw line, the game plays its own animation", "วาร์ปไปเส้นโยน เกมเล่นอนิเมชั่นเอง"))
    addToggle(throwBox, "AutoPerfect", T("Auto Perfect +20", "เพอร์เฟกต์ +20 อัตโนมัติ"),
        T("Taps the meter at its peak, also for manual throws", "กดมิเตอร์ตรงจุดสูงสุด ใช้กับโยนด้วยมือด้วย"),
        true, applyPerfect)
    addToggle(throwBox, "RevealBoost", T("Faster Name Reveal", "เร่งหน้าโชว์ชื่อ"),
        T("Shortens the reveal zoom and name screen only", "ย่อเฉพาะช่วงซูมและหน้าชื่อสัตว์"),
        true, applyReveal)
    addSlider(throwBox, "RevealSpeed", T("Reveal speed", "ความเร็วโชว์ชื่อ"), 1, 6, 3, "x", 1, applyReveal)

    local trainBox = tab:AddRightGroupbox(T("Training", "เทรนนิ่ง"), "training")
    addToggle(trainBox, "AutoTrain", T("Auto Training", "เทรนนิ่งอัตโนมัติ"),
        T("Teleports onto the training circle", "วาร์ปไปยืนบนวงเทรน"))
    addToggle(trainBox, "AutoBonus", T("Auto Bonus x2", "กดโบนัส x2 อัตโนมัติ"),
        T("Presses the purple tap bonus", "กดปุ่มโบนัสสีม่วงให้"))
    addSlider(trainBox, "BonusDelay", T("Bonus delay", "หน่วงก่อนกดโบนัส"), 0, 2, 0.35, "s", 2)
    addSlider(trainBox, "TrainSeconds", T("Train time per cycle", "เวลาเทรนต่อรอบ"), 10, 300, 60, "s")
    addSlider(trainBox, "ThrowsPerCycle", T("Throws per cycle", "จำนวนโยนต่อรอบ"), 1, 50, 10)

    local statusBox = tab:AddLeftGroupbox(T("Status", "สถานะ"), "info")
    local statusLabel = statusBox:AddLabel("-")
    task.spawn(function()
        while alive do
            pcall(statusLabel.SetText, statusLabel, string.format("Throws %d | Sold %d | Bonus %d | Food %d | Fails %d | %s",
                Stats.Throws, Stats.Sold, Stats.Bonus, Stats.Food, Stats.Fails, Stats.Last))
            sleep(1)
        end
    end)
end

local function notifyResult(res, okText, label)
    if res.Ok then
        Hooks.Notify(okText, "Success")
    else
        Hooks.Notify(label .. ": " .. tostring(res.Reason), "Warning")
    end
end

local function buildEconomyTab(window)
    local tab = window:AddTab(T("Economy", "เศรษฐกิจ"), "economy", T("Sell, food, upgrades", "ขาย อาหาร อัปเกรด"))

    local sellBox = tab:AddLeftGroupbox(T("Sell", "ขาย"), "sell")
    addToggle(sellBox, "AutoSell", T("Auto Sell", "ขายอัตโนมัติ"), T("Sell all animals on a timer", "ขายสัตว์ทั้งหมดตามเวลา"))
    addSlider(sellBox, "SellInterval", T("Sell every", "ขายทุก"), 1, 60, 5, "s")
    sellBox:AddButton({ Text = T("Sell All Now", "ขายทั้งหมดเดี๋ยวนี้"), Style = "Primary",
        Func = function() task.defer(function()
            local res = sellAll()
            notifyResult(res, "Sold " .. tostring(res.Count or 0), "Sell")
        end) end })

    local foodBox = tab:AddRightGroupbox(T("Food", "อาหาร"), "food")
    addToggle(foodBox, "AutoFood", T("Auto Upgrade Food", "อัปเกรดอาหารอัตโนมัติ"),
        T("Buys the best affordable food and equips it", "ซื้ออาหารที่ดีสุดที่เงินพอ แล้วใส่ให้"))
    foodBox:AddButton({ Text = T("Upgrade Food Now", "อัปเกรดอาหารเดี๋ยวนี้"), Style = "Primary",
        Func = function() task.defer(function() pcall(upgradeFood) end) end })

    local upgradeBox = tab:AddLeftGroupbox(T("Upgrades", "อัปเกรด"), "extras")
    addToggle(upgradeBox, "AutoStand", T("Auto Upgrade Stand", "อัปเกรดแท่นอัตโนมัติ"), T("Spends money", "ใช้เงิน"))
    addToggle(upgradeBox, "AutoFence", T("Auto Upgrade Fence", "อัปเกรดรั้วอัตโนมัติ"), T("Spends money", "ใช้เงิน"))
    addToggle(upgradeBox, "AutoEquipBest", T("Auto Equip Best", "ใส่สัตว์ดีสุดอัตโนมัติ"), "", false, function(enabled)
        if enabled then task.defer(equipBest) end
    end)

    local rewardBox = tab:AddRightGroupbox(T("Rewards", "รางวัล"), "gift")
    addToggle(rewardBox, "AutoClaimFree", T("Auto Claim Free Reward", "รับของฟรีอัตโนมัติ"), "")
    rewardBox:AddButton({ Text = T("Claim Offline Earnings", "รับรายได้ออฟไลน์"),
        Func = function() task.defer(function()
            notifyResult(invoke("Offline_Claim"), "Claimed", "Offline")
        end) end })
end

local UserInputService = game:GetService("UserInputService")
local phone = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

Library:CreateWindow({
    Title = "Pattom Hub",
    SubTitle = "PTM",
    MenuKey = Enum.KeyCode.LeftControl,
    ConfigFolder = Config.Folder,
    Language = "Auto",
    Theme = "Pattom",
    Scale = phone and 0.9 or 1,
    Assets = { logo = Config.LogoFile },
    OnUnlocked = function()
        local window = Library.Window
        buildFarmTab(window)
        buildEconomyTab(window)
        window:AddSettingsTab()
        Hooks.Notify("Loaded", "Success")
        pcall(Library.LoadAutoloadConfig, Library)
    end,
})
