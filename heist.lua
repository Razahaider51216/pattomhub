-- Pattom Hub: Egg Smash + Steal helper. UI: ui.lua (same library as main.lua).
-- Built from the DevilDump of ClientRuntimeV8 / Run_20261108_230159_1 (map 114326934417838).
-- NOT run against the live game. Tags: [dump] = read from decompiled client scripts,
-- [unverified] = inferred, check in game (see the notes at the end of the answer).
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local VirtualUser = game:GetService("VirtualUser")
local LocalPlayer = Players.LocalPlayer

local Config = {
    Folder = "pattom-hub",
    UiFile = "pattom-hub/ui.lua",
    LogoFile = "pattom-hub/pattomhub.png",
    BaseUrl = "https://raw.githubusercontent.com/Razahaider51216/pattomhub/main/",
    LoadTimeout = 15,
    ExpectedPlaceId = 114326934417838, -- [unverified] taken from the DumpedMap file name
    Names = { -- [dump]
        Plots = "Plots", Build = "Build", ZoneHitboxes = "ZoneHitboxes", SafeZone = "SafeZone",
        PlotHitbox = "Hitbox", EggTag = "BreakableEgg", PickupTag = "AnimalPickup",
        StealPrompt = "StealPrompt", PickaxeTool = "Pickaxe", AnimalToolTag = "AnimalTool",
    },
    Remotes = { -- [dump] all direct children of ReplicatedStorage
        Swing = "MasteryPickaxeSwing", Sell = "BackpackSellRemote", UpgradePlot = "UpgradePlotRequest",
        Offline = "OfflineRewardRemote", PickaxeShop = "PickaxeShopRequest",
        Index = "IndexRemote", Pets = "PetsInventoryRemote",
    },
    HitRange = 8,           -- [dump] EggConfig.HitRange (server adds HitRangeServerSlack = 2)
    SellBatch = 200,        -- [dump] BackpackSellConfig.MaxPerRequest
}

if getgenv and getgenv().PattomHeistUnload then pcall(getgenv().PattomHeistUnload) end
if getgenv and getgenv().PattomHubUnload then pcall(getgenv().PattomHubUnload) end

local alive = true
local connections, cleanups = {}, {}

local S = {
    AutoEgg = false, EggTeleport = true, EggStandOff = 5, EggSwingGap = 0.05,
    AutoSteal = false, StealMinValue = 0, StealAllowUnknown = false, StealMaxDistance = 100000,
    StealGrabWait = 1.2, StealBankWait = 8, StealCooldown = 0.4, StealAvoidGuard = 0,
    AutoRide = true,
    AutoSell = false, SellInterval = 20, AutoUpgradePlot = false, AutoOffline = false,
    AutoBuyPickaxe = false, AutoIndex = false, AutoEquipBestBase = false, EquipBestInterval = 20,
}
local Stats = { Hits = 0, Steals = 0, Banked = 0, Sold = 0, Fails = 0, Last = "-", Scan = "-", Ride = "-" }
local Hooks = { Notify = function() end, Halt = function() end }

local function warnf(...) warn("[PattomHeist]", ...) end
local function sleep(seconds)
    local t = os.clock()
    while alive and os.clock() - t < seconds do task.wait(0.03) end
end
local function findPath(root, ...)
    local node = root
    for _, name in ipairs({ ... }) do node = node and node:FindFirstChild(name) end
    return node
end

local function loadModule(instance)
    if not instance then return nil end
    local ok, mod = pcall(require, instance)
    return ok and type(mod) == "table" and mod or nil
end

-- Pure helpers (no game access) ------------------------------------------------------------
-- Suffix list copied from the game's FormatNumber.Short [dump]
local SUFFIX = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Qi = 1e18, Sx = 1e21, Sp = 1e24, Oc = 1e27, No = 1e30, Dc = 1e33 }

local function parseMoney(text)
    if type(text) == "number" then return text == text and text or nil end
    if type(text) ~= "string" then return nil end
    local num, suffix = text:gsub(",", ""):match("(%d+%.?%d*)%s*(%a*)")
    num = tonumber(num)
    if not num then return nil end
    if suffix == "" then return num end
    local mult = SUFFIX[suffix] or SUFFIX[suffix:sub(1, 2)] or SUFFIX[suffix:sub(1, 1):upper()]
    return mult and num * mult or num
end

local function setHas(set, key) return type(set) == "table" and set[key] == true end
local function setIsEmpty(set)
    if type(set) ~= "table" then return true end
    return next(set) == nil
end

local function finite(v) return type(v) == "number" and v == v and math.abs(v) < 1e9 end
local function finiteVec(v) return finite(v.X) and finite(v.Y) and finite(v.Z) end

local function insideBox(part, point, yPad)
    local rel = part.CFrame:PointToObjectSpace(point)
    local half = part.Size * 0.5
    return math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y + (yPad or 0) and math.abs(rel.Z) <= half.Z
end

-- Game access ------------------------------------------------------------------------------
if game.PlaceId ~= Config.ExpectedPlaceId then
    warnf("PlaceId", game.PlaceId, "differs from the dumped place", Config.ExpectedPlaceId, "- features may not match")
end

local Shared = RS:WaitForChild("Shared", Config.LoadTimeout)
local function shared(name) return Shared and loadModule(Shared:FindFirstChild(name)) end
local ZonesConfig, EggTargeting, RideConfig = shared("ZonesConfig"), shared("EggTargeting"), shared("RideConfig")
local SpeedConfig, PotionConfig, SpeedBoostConfig = shared("SpeedConfig"), shared("PotionConfig"), shared("SpeedBoostConfig")
local MutationConfig, PickaxeConfig = shared("MutationConfig"), shared("PickaxeConfig")

local function remote(name, class)
    local r = RS:FindFirstChild(name)
    if r and (not class or r:IsA(class)) then return r end
    return nil
end

local PlayerScripts = LocalPlayer:WaitForChild("PlayerScripts", Config.LoadTimeout)
local PickaxeController
if PlayerScripts then
    for _, d in ipairs(PlayerScripts:GetDescendants()) do
        if d:IsA("ModuleScript") and d.Name == "PickaxeController" then
            PickaxeController = loadModule(d)
            break
        end
    end
end
if not (PickaxeController and PickaxeController.Swing) then
    warnf("PickaxeController not found - Auto Egg is gated (needs its Swing function)")
end

local function character()
    local ch = LocalPlayer.Character
    local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
    local hum = ch and ch:FindFirstChildOfClass("Humanoid")
    if hrp and hum and hum.Health > 0 then return hrp, hum, ch end
    return nil
end

local function carrying() return LocalPlayer:GetAttribute("Carrying") ~= nil end -- [dump] ChaseState
local function ragdolled()
    local ch = LocalPlayer.Character
    return ch ~= nil and ch:GetAttribute("Ragdolled") == true
end

-- Movement -----------------------------------------------------------------------------------
-- The game does not use a fixed running speed. SpeedPower is converted by SpeedConfig, then the
-- ride/potion multipliers are applied. GroundGripController finally drives AssemblyLinearVelocity
-- from Humanoid.WalkSpeed. We only read those values here; movement is still performed by the
-- game's Humanoid:MoveTo path, so no CFrame/velocity/WalkSpeed spoofing is involved.
-- opts.done(hrp) -> true when close enough; opts.cancel() -> true to give up early.
local PathfindingService = game:GetService("PathfindingService")

local function finiteNumber(value)
    return type(value) == "number" and value == value and value > 0 and value < 1e9
end

local function gameMoveSpeed(hrp, hum)
    -- WalkSpeed is the authoritative value used by GroundGripController. On a few frames during
    -- respawn/mounting it can still be the base 18, so derive the game's configured value as a
    -- fallback from SpeedPower and apply multipliers only while WalkSpeed is still unscaled.
    local runtime = finiteNumber(hum and hum.WalkSpeed) and hum.WalkSpeed or 0
    local configured
    local power = LocalPlayer:GetAttribute("SpeedPower")
    if SpeedConfig and SpeedConfig.SpeedPowerToWalkSpeed and finiteNumber(power) then
        local ok, value = pcall(SpeedConfig.SpeedPowerToWalkSpeed, power)
        if ok and finiteNumber(value) then configured = value end
    end

    local multiplier = 1
    if LocalPlayer:GetAttribute("Mounted") == true and RideConfig and RideConfig.WalkSpeedMultiplierFor then
        local ok, value = pcall(RideConfig.WalkSpeedMultiplierFor, LocalPlayer)
        if ok and finiteNumber(value) then multiplier *= value end
    end
    if PotionConfig and PotionConfig.WalkSpeedMultiplierFor then
        local ok, value = pcall(PotionConfig.WalkSpeedMultiplierFor, LocalPlayer)
        if ok and finiteNumber(value) then multiplier *= value end
    end
    if SpeedBoostConfig and SpeedBoostConfig.MultiplierOf then
        local ok, value = pcall(SpeedBoostConfig.MultiplierOf, LocalPlayer)
        if ok and finiteNumber(value) then multiplier *= value end
    end

    local base = math.max(runtime, configured or 0)
    -- If the character still exposes the unscaled/base value, include the configured multipliers.
    -- A runtime value already above that base is trusted as the game's final speed.
    -- Only treat a near-default runtime value as unscaled. If WalkSpeed is already 30/100/240,
    -- it is the game's final value and multiplying it again would make the route timing wrong.
    local unscaledLimit = configured and math.max(18.5, math.min(configured * 1.08, 24)) or 18.5
    if runtime <= unscaledLimit then
        base = math.max(base, (configured or runtime) * multiplier)
    end

    -- Include measured horizontal velocity so temporary boosts, moving platforms and rides are
    -- reflected immediately. The small factor avoids a zero/low sample extending the trip budget.
    local measured = 0
    if hrp then
        local v = hrp.AssemblyLinearVelocity
        local sample = Vector3.new(v.X, 0, v.Z).Magnitude
        if finiteNumber(sample) then measured = sample end
    end
    return math.clamp(math.max(base, measured * 0.9, 8), 8, 2400)
end

local function computePath(from, to)
    local ok, path = pcall(PathfindingService.CreatePath, PathfindingService,
        { AgentRadius = 2, AgentHeight = 5, AgentCanJump = true }) -- agent size: ZonesConfig.Guard.Recovery [dump]
    if not ok then return nil end
    if not pcall(path.ComputeAsync, path, from, to) then return nil end
    if path.Status ~= Enum.PathStatus.Success then return nil end
    return path:GetWaypoints()
end

local function flatDistance(a, b)
    return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function walkTo(target, opts)
    opts = opts or {}
    local hrp, hum = character()
    if not (hrp and finiteVec(target)) then return false end
    local distance = (target - hrp.Position).Magnitude
    local speed = gameMoveSpeed(hrp, hum)
    -- Keep generous startup/pathfinding slack, but scale the travel budget with the game's current
    -- speed. The 0.5 factor covers acceleration, collisions and server correction at high speed.
    local deadline = os.clock() + distance / math.max(speed * 0.5, 8) + 10
    local lastPos, lastMoveAt = hrp.Position, os.clock()
    local waypoints, wpIndex, pathAt, jumpAt = nil, 1, 0, 0
    while alive and os.clock() < deadline do
        hrp, hum = character()
        if not hrp then return false end
        if opts.cancel and opts.cancel() then hum:MoveTo(hrp.Position) return false end
        -- arrival and waypoint radii are fixed distances; scaling them with WalkSpeed made the walker
        -- declare arrival early and skip waypoints (up to 12-14 studs at WalkSpeed 240)
        local arrived
        if opts.done then
            arrived = opts.done(hrp)
        else
            arrived = flatDistance(hrp.Position, target) <= 3 and math.abs(hrp.Position.Y - target.Y) < 12
        end
        if arrived then hum:MoveTo(hrp.Position) return true end
        if not ragdolled() then
            local aim = target
            if waypoints then
                local wp = waypoints[wpIndex]
                if wp and flatDistance(hrp.Position, wp.Position) < 3.5 then
                    wpIndex += 1
                    wp = waypoints[wpIndex]
                end
                aim = wp and wp.Position or target
            end
            -- steer at a speed-scaled lead point so the humanoid never reaches it, slows down or
            -- hits MoveTo's 8 s expiry; arrival is decided above, once per frame
            local flat = Vector3.new(aim.X - hrp.Position.X, 0, aim.Z - hrp.Position.Z)
            local leadDistance = math.clamp(gameMoveSpeed(hrp, hum) * 0.35, 12, 48)
            local lead = flat.Magnitude > leadDistance and hrp.Position + flat.Unit * leadDistance or aim
            hum:MoveTo(lead)
            if (hrp.Position - lastPos).Magnitude > 1.5 then
                lastPos, lastMoveAt = hrp.Position, os.clock()
            elseif os.clock() - lastMoveAt > 0.6 then
                if os.clock() - jumpAt > 1 then hum.Jump = true jumpAt = os.clock() end
                if os.clock() - lastMoveAt > 1.5 and os.clock() - pathAt > 3 then
                    pathAt = os.clock()
                    waypoints, wpIndex = computePath(hrp.Position, target), 1
                    lastMoveAt = os.clock()
                end
            end
        end
        RunService.Heartbeat:Wait()
    end
    return false
end

-- Every trip (eggs, steals, the run home) mounts the best owned ride first, then runs.
local function moveTo(target, opts)
    if S.AutoRide and Hooks.EnsureRide then Hooks.EnsureRide() end
    return walkTo(target, opts)
end

-- Zones and eggs -------------------------------------------------------------------------------
-- Zone list comes from ZonesConfig.Zones [dump]; index N is the entry position, the hitbox part for
-- zone N is Workspace.Build.ZoneHitboxes[tostring(N)] [dump: ZoneHitboxLookup].
local function zoneLabels()
    local labels, byLabel = {}, {}
    local zones = ZonesConfig and ZonesConfig.Zones
    if type(zones) ~= "table" then return labels, byLabel end
    for i, z in ipairs(zones) do
        local label = ("Zone %d - %s (%s)"):format(i, tostring(z.Rarity or "?"), tostring(z.Guard or "?"))
        labels[#labels + 1] = label
        byLabel[label] = i
    end
    return labels, byLabel
end

local hitboxFolder
local function zoneHitbox(index)
    if not (hitboxFolder and hitboxFolder.Parent) then
        hitboxFolder = findPath(workspace, Config.Names.Build, Config.Names.ZoneHitboxes)
    end
    local part = hitboxFolder and hitboxFolder:FindFirstChild(tostring(index))
    return part and part:IsA("BasePart") and part or nil
end

local function eggZone(egg)
    local attr = egg:GetAttribute("ZoneIndex") -- [dump] EggCullQuality.EggZone
    if type(attr) == "number" then return attr end
    local count = ZonesConfig and ZonesConfig.Zones and #ZonesConfig.Zones or 0
    for i = 1, count do
        local box = zoneHitbox(i)
        if box and insideBox(box, egg.Position, 2) then return i end
    end
    return nil
end

local function eggLive(egg)
    if EggTargeting and EggTargeting.IsLive then return EggTargeting.IsLive(egg) end
    return egg.Parent ~= nil and not (egg:GetAttribute("Broken") or egg:GetAttribute("Hatching") or egg:GetAttribute("Despawning"))
end

local function surfaceDistance(egg, point)
    if EggTargeting and EggTargeting.SurfaceDistance then return EggTargeting.SurfaceDistance(egg, point) end
    return (egg.Position - point).Magnitude
end

local function reachOrigin(hrp)
    if RideConfig and RideConfig.ReachOrigin then
        local ok, v = pcall(RideConfig.ReachOrigin, hrp)
        if ok then return v end
    end
    return hrp.Position
end

local function pickEgg(zoneSet, from)
    local best, bestDist
    for _, egg in ipairs(CollectionService:GetTagged(Config.Names.EggTag)) do
        if egg:IsA("BasePart") and eggLive(egg) then
            local zone = eggZone(egg)
            if zone and (setIsEmpty(zoneSet) or setHas(zoneSet, zone)) then
                local d = (egg.Position - from).Magnitude
                if not bestDist or d < bestDist then best, bestDist = egg, d end
            end
        end
    end
    return best
end

-- Auto Ride ----------------------------------------------------------------------------------
-- Flow copied from the game's own UI [dump]: RideEggRemote (RemoteFunction):InvokeServer("Hold", name)
-- puts the animal in hand (attribute HeldRideable), then RideRemote (RemoteEvent):FireServer("Mount",
-- heldName). Owned animals are in the player attribute OwnedRideableCounts as "Name=3,Other=1".
-- Whether the server accepts a Mount from a script right after Hold is [unverified].
local RideEggConfig = shared("RideEggConfig")
local rideAttemptAt = 0

local function ownedRideables(countsText)
    local names = {}
    if type(countsText) ~= "string" then return names end
    for entry in string.gmatch(countsText, "[^,]+") do
        local name, count = string.match(entry, "^([^=]+)=(%d+)$")
        if name and tonumber(count) and tonumber(count) > 0 then names[#names + 1] = name end
    end
    return names
end

local function bestRideable(names)
    local best, bestBonus
    for _, name in ipairs(names) do
        local entry = RideConfig and RideConfig.Find and RideConfig.Find(name) -- [dump] SpeedBonus per animal
        local bonus = entry and entry.SpeedBonus
        if type(bonus) == "number" and (not bestBonus or bonus > bestBonus) then best, bestBonus = name, bonus end
    end
    return best, bestBonus
end

local function isMounted() return LocalPlayer:GetAttribute("Mounted") == true end

local function ensureRide()
    if not S.AutoRide or isMounted() or carrying() or ragdolled() then return end
    if os.clock() < rideAttemptAt then return end
    rideAttemptAt = os.clock() + 4
    local function fail(text)
        Stats.Last = text
        rideAttemptAt = os.clock() + 15 -- do not retry (and block movement) on every step after a refusal
    end
    local countsAttr = RideEggConfig and RideEggConfig.CountsAttribute or "OwnedRideableCounts"
    local best, bonus = bestRideable(ownedRideables(LocalPlayer:GetAttribute(countsAttr)))
    if not best then return fail("no rideable animal owned") end
    if LocalPlayer:GetAttribute("HeldRideable") ~= best then
        local fn = remote("RideEggRemote", "RemoteFunction")
        if not fn then return fail("RideEggRemote missing") end
        local ok, res = pcall(fn.InvokeServer, fn, "Hold", best)
        if not (ok and res) then return fail("ride hold refused: " .. best) end
        local t = os.clock()
        while alive and LocalPlayer:GetAttribute("HeldRideable") ~= best and os.clock() - t < 2 do task.wait(0.05) end
    end
    local r = remote("RideRemote", "RemoteEvent")
    if not r then return fail("RideRemote missing") end
    pcall(r.FireServer, r, "Mount", best)
    local t = os.clock()
    while alive and not isMounted() and os.clock() - t < 2 do task.wait(0.05) end
    if isMounted() then
        Stats.Ride = ("%s x%.2f"):format(best, 1 + (bonus or 0))
        Stats.Last = "riding " .. Stats.Ride
    else
        fail("mount not accepted: " .. best)
    end
end
Hooks.EnsureRide = ensureRide

-- Auto Egg -----------------------------------------------------------------------------------
local Sel = { EggZones = {}, Rarities = {}, Mutations = {} } -- sets filled by the UI dropdowns

local function equipPickaxe()
    local _, hum, ch = character()
    if not hum then return false end
    local name = Config.Names.PickaxeTool
    if ch:FindFirstChild(name) then return true end
    if carrying() or ragdolled() then return false end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local tool = backpack and backpack:FindFirstChild(name)
    if not (tool and tool:IsA("Tool")) then return false end
    hum:EquipTool(tool)
    sleep(0.15)
    return ch:FindFirstChild(name) ~= nil
end

local function standPointFor(egg, hrp, hum)
    local flat = Vector3.new(hrp.Position.X - egg.Position.X, 0, hrp.Position.Z - egg.Position.Z)
    if flat.Magnitude < 0.01 then flat = Vector3.new(1, 0, 0) end
    local radius = math.max(egg.Size.X, egg.Size.Z) / 2 + S.EggStandOff
    local ground = egg.Position.Y - egg.Size.Y / 2
    local y = ground + hum.HipHeight + hrp.Size.Y / 2 + 0.2
    return Vector3.new(egg.Position.X, y, egg.Position.Z) + flat.Unit * radius
end

local function eggStep()
    if not (PickaxeController and PickaxeController.Swing) then sleep(1) return false, "PickaxeController missing" end
    local hrp, hum = character()
    if not hrp then sleep(0.5) return false, "no character" end
    if carrying() then sleep(0.5) return true end
    ensureRide()
    if not equipPickaxe() then sleep(0.5) return false, "pickaxe not equipped" end
    local egg = pickEgg(Sel.EggZones, hrp.Position)
    if not egg then sleep(0.4) return true end
    local limit = Config.HitRange - 2
    if surfaceDistance(egg, reachOrigin(hrp)) > limit then
        if not S.EggTeleport then sleep(0.4) return true end
        -- walks at the game's speed and stops as soon as the egg is inside hit reach
        moveTo(standPointFor(egg, hrp, hum), {
            done = function(h) return surfaceDistance(egg, reachOrigin(h)) <= limit - 0.5 end,
            cancel = function()
                return not (S.AutoEgg and eggLive(egg)) or carrying()
                    or (Hooks.StealPending ~= nil and Hooks.StealPending())
            end,
        })
        if not equipPickaxe() then return false, "pickaxe not equipped" end
    end
    local started, lastCheck = os.clock(), os.clock()
    while alive and S.AutoEgg and eggLive(egg) and os.clock() - started < 60 do
        local now = character()
        if not now or carrying() then break end
        if os.clock() - lastCheck > 0.5 then
            lastCheck = os.clock()
            if Hooks.StealPending and Hooks.StealPending() then break end
        end
        if surfaceDistance(egg, reachOrigin(now)) > limit + 1 then break end
        local ok, swung = pcall(PickaxeController.Swing, egg)
        if ok and swung then Stats.Hits += 1 end
        sleep(S.EggSwingGap)
    end
    return true
end

-- Steal: reading and filtering animals ------------------------------------------------------------
-- Targets are Models tagged "AnimalPickup" [dump]. Attribute names AnimalName/Rarity/Mutation/Variant/
-- CashPerSecond/ReservedUserId/Despawning are confirmed on placed animals or eggs, NOT on pickups
-- [unverified], so every read has a fallback to the overhead label text.
local function labelText(model, name)
    local node = model:FindFirstChild(name, true)
    if node and not node:IsA("TextLabel") then node = node:FindFirstChildWhichIsA("TextLabel", true) end
    return node and node:IsA("TextLabel") and node.Text or nil
end

local function animalInfo(model)
    local mutation = model:GetAttribute("Mutation")
    local variant = model:GetAttribute("Variant")
    local rarity = model:GetAttribute("Rarity") or labelText(model, "Rarity")
    local value = parseMoney(model:GetAttribute("CashPerSecond") or labelText(model, "CashPerSecond"))
    return {
        Model = model, Name = model:GetAttribute("AnimalName") or model.Name,
        Rarity = rarity and tostring(rarity):gsub("^%s+", ""):gsub("%s+$", "") or nil,
        Mutation = mutation ~= "" and mutation or nil, Variant = variant ~= "" and variant or nil,
        Value = value, Reserved = model:GetAttribute("ReservedUserId"),
    }
end

local function matchesStatus(info)
    if setIsEmpty(Sel.Mutations) then return true end
    if info.Mutation == nil and info.Variant == nil then return setHas(Sel.Mutations, "None") end
    return (info.Mutation ~= nil and setHas(Sel.Mutations, info.Mutation))
        or (info.Variant ~= nil and setHas(Sel.Mutations, info.Variant))
end

local function guardNear(position, radius)
    if radius <= 0 then return false end
    for _, guard in ipairs(CollectionService:GetTagged("ZoneGuard")) do -- [dump] tag
        local ok, pivot = pcall(function() return guard:GetPivot().Position end)
        if ok and (pivot - position).Magnitude <= radius then return true end
    end
    return false
end

local function acceptable(info, fromPos)
    local model = info.Model
    if model:GetAttribute("Despawning") or model.Parent == nil then return false end
    if info.Reserved ~= nil and info.Reserved ~= LocalPlayer.UserId then return false end
    if not setIsEmpty(Sel.Rarities) and not (info.Rarity and setHas(Sel.Rarities, info.Rarity)) then return false end
    if not matchesStatus(info) then return false end
    if S.StealMinValue > 0 then
        if info.Value == nil then
            if not S.StealAllowUnknown then return false end
        elseif info.Value < S.StealMinValue then
            return false
        end
    end
    local pos = model:GetPivot().Position
    if (pos - fromPos).Magnitude > S.StealMaxDistance then return false end
    return not guardNear(pos, S.StealAvoidGuard)
end

-- Steal: grab and run home -----------------------------------------------------------------------------
-- The client's SmartPromptController/SurfacePrompt.Attach moves every SmartPrompt ProximityPrompt out
-- of its model onto a Part named "PromptAnchor" that is a direct child of Workspace [dump], and the
-- anchor starts at the target's pivot. So a pickup's StealPrompt is matched by position, not by parent.
local function stealAnchors()
    local list = {}
    for _, child in ipairs(workspace:GetChildren()) do
        if child.Name == "PromptAnchor" and child:IsA("BasePart") then
            local prompt = child:FindFirstChild(Config.Names.StealPrompt)
            if prompt and prompt:IsA("ProximityPrompt") then list[#list + 1] = { Prompt = prompt, Position = child.Position } end
        end
    end
    return list
end

local function stealPrompt(model, anchors)
    local inside = model:FindFirstChild(Config.Names.StealPrompt, true) -- not yet moved by the client
    if inside and inside:IsA("ProximityPrompt") then return inside end
    local pivot = model:GetPivot().Position
    local ok, size = pcall(model.GetExtentsSize, model)
    local reach = (ok and size.Magnitude / 2 or 6) + 8
    local best, bestDist
    for _, a in ipairs(anchors or stealAnchors()) do
        local d = (a.Position - pivot).Magnitude
        if d <= reach and (not bestDist or d < bestDist) then best, bestDist = a.Prompt, d end
    end
    return best
end

local function promptPosition(prompt, model)
    local parent = prompt.Parent
    if parent and parent:IsA("BasePart") then return parent.Position end
    if parent and parent:IsA("Attachment") then return parent.WorldPosition end
    return model:GetPivot().Position
end

local function triggerPrompt(prompt)
    -- the server still runs its own checks; these only remove the client-side hold/range/sight gates
    pcall(function()
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = false
        prompt.MaxActivationDistance = math.max(prompt.MaxActivationDistance, 12)
    end)
    if fireproximityprompt then
        pcall(fireproximityprompt, prompt)
    else
        pcall(function() prompt:InputHoldBegin() task.wait(0.05) prompt:InputHoldEnd() end)
    end
end

local function homeTargets()
    local list = {}
    local plots = workspace:FindFirstChild(Config.Names.Plots)
    if plots then
        for _, plot in ipairs(plots:GetChildren()) do
            if plot:GetAttribute("OwnerUserId") == LocalPlayer.UserId then -- [dump] OwnBase
                local box = plot:FindFirstChild(Config.Names.PlotHitbox)
                if box and box:IsA("BasePart") then list.plot = box end
            end
        end
    end
    local build = workspace:FindFirstChild(Config.Names.Build)
    local hrp = character()
    if build and hrp then
        local bestDist
        for _, d in ipairs(build:GetDescendants()) do
            if d.Name == Config.Names.SafeZone and d:IsA("BasePart") then -- [dump] SafeZoneQuery
                local dist = (d.Position - hrp.Position).Magnitude
                if not bestDist or dist < bestDist then list.safe, bestDist = d, dist end
            end
        end
    end
    return list
end

local ReturnMode = "Own Plot" -- "Own Plot" | "Nearest Safe Zone" | "Safe Zone then Own Plot"

local function goHome()
    local t = homeTargets()
    local order = {}
    local function add(v) if v then order[#order + 1] = v end end
    if ReturnMode == "Own Plot" then add(t.plot or t.safe)
    elseif ReturnMode == "Nearest Safe Zone" then add(t.safe or t.plot)
    else add(t.safe) add(t.plot) end
    if #order == 0 then return false end
    local reached = false
    for _, part in ipairs(order) do
        -- done = standing inside the part, the same box test the server-side SafeZoneQuery uses [dump]
        reached = moveTo(part.Position + Vector3.new(0, 3, 0), {
            done = function(h) return insideBox(part, h.Position, 2) end,
            cancel = function() return not S.AutoSteal end,
        })
        if not reached then return false end
        sleep(0.15)
    end
    return reached
end

-- Steal: target choice and one full run ----------------------------------------------------------------
local blacklist = setmetatable({}, { __mode = "k" })

local function capacityFull()
    local count, cap = LocalPlayer:GetAttribute("CarryCount"), LocalPlayer:GetAttribute("SatchelCapacity")
    return type(count) == "number" and type(cap) == "number" and count >= cap -- [dump] StealPromptVisibility
end

local function bestTarget(fromPos)
    local best, bestValue, bestDist
    local anchors = stealAnchors()
    local seen, noPrompt, matched = 0, 0, 0
    for _, model in ipairs(CollectionService:GetTagged(Config.Names.PickupTag)) do
        local banned = blacklist[model]
        if model:IsA("Model") and not (banned and banned > os.clock()) then
            seen += 1
            local info = animalInfo(model)
            info.Prompt = stealPrompt(model, anchors)
            if info.Prompt then
                local reserved = info.Prompt:GetAttribute("ReservedUserId") -- [dump] CustomPromptRenderer
                if info.Reserved == nil and type(reserved) == "number" then info.Reserved = reserved end
            else
                noPrompt += 1
            end
            if info.Prompt and acceptable(info, fromPos) then
                matched += 1
                local value = info.Value or 0
                local dist = (model:GetPivot().Position - fromPos).Magnitude
                if not best or value > bestValue or (value == bestValue and dist < bestDist) then
                    best, bestValue, bestDist = info, value, dist
                end
            end
        end
    end
    -- shown on the Status tab so a silent "nothing to steal" can be told apart from a filter or prompt problem
    Stats.Scan = ("pickups %d | with prompt %d | pass filters %d"):format(seen, seen - noPrompt, matched)
    return best
end

local function waitCarrying(state, limit)
    local t = os.clock()
    while alive and os.clock() - t < limit do
        if carrying() == state then return true end
        task.wait(0.05)
    end
    return carrying() == state
end

local function finishRun()
    if not goHome() then return false, "could not reach home" end
    if waitCarrying(false, S.StealBankWait) then return true end
    return false, "not banked within " .. S.StealBankWait .. "s"
end

local function stealPending()
    if not S.AutoSteal then return false end
    if carrying() then return true end
    local hrp = character()
    return hrp ~= nil and not capacityFull() and bestTarget(hrp.Position) ~= nil
end

Hooks.StealPending = stealPending

local function stealStep()
    local hrp = character()
    if not hrp then sleep(0.5) return true end
    if ragdolled() then sleep(0.3) return true end
    if carrying() then return finishRun() end
    local info = bestTarget(hrp.Position)
    if not info then return true end
    local model = info.Model
    local prompt = info.Prompt
    if not (prompt and prompt.Parent) then
        blacklist[model] = os.clock() + 10
        return false, "no prompt on " .. tostring(info.Name)
    end
    local target = promptPosition(prompt, model)
    local away = Vector3.new(hrp.Position.X - target.X, 0, hrp.Position.Z - target.Z)
    if away.Magnitude < 0.01 then away = Vector3.new(1, 0, 0) end
    moveTo(target + away.Unit * 3 + Vector3.new(0, 1.5, 0), {
        done = function(h) return (h.Position - target).Magnitude <= 6 end,
        cancel = function() return not S.AutoSteal or model.Parent == nil or model:GetAttribute("Despawning") == true end,
    })
    local t = os.clock()
    while alive and S.AutoSteal and os.clock() - t < S.StealGrabWait and not carrying() do
        triggerPrompt(prompt)
        task.wait(0.1)
    end
    if not carrying() then
        blacklist[model] = os.clock() + 5
        return false, "grab rejected: " .. tostring(info.Name)
    end
    Stats.Steals += 1
    Stats.Last = ("grabbed %s [%s] %s"):format(tostring(info.Name), tostring(info.Rarity), tostring(info.Value))
    return finishRun()
end

-- Shared farm loop: one thing moves the character at a time. Steal has priority over eggs.
local failStreak = 0
local function noteResult(flag, ok, reason)
    if ok then failStreak = 0 return end
    Stats.Fails += 1
    failStreak += 1
    Stats.Last = tostring(reason)
    if failStreak >= 8 then
        failStreak = 0
        Hooks.Notify(flag .. " stopped: " .. tostring(reason), "Warning")
        Hooks.Halt(flag)
    end
    sleep(1)
end

local function farmStep()
    if S.AutoSteal and stealPending() then
        local ok, reason = stealStep()
        noteResult("AutoSteal", ok, reason)
        sleep(S.StealCooldown)
    elseif S.AutoEgg then
        local ok, reason = eggStep()
        noteResult("AutoEgg", ok, reason)
    else
        sleep(0.4)
    end
end

task.spawn(function()
    while alive do
        local ok, err = pcall(farmStep)
        if not ok then warnf("farm loop:", err) sleep(1) end
    end
end)

-- Economy ------------------------------------------------------------------------------------------
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

-- BackpackSellRemote:InvokeServer({ Tool, ... }), up to MaxPerRequest tools [dump: confirmSell].
-- The return value is not documented in the dump, so Stats.Sold counts tools sent.
local function sellAll()
    local sellRemote = remote(Config.Remotes.Sell, "RemoteFunction")
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    if not (sellRemote and backpack) then return false, "sell remote or backpack missing" end
    local batch, sent = {}, 0
    local function flush()
        if #batch == 0 then return end
        local ok, err = pcall(sellRemote.InvokeServer, sellRemote, batch)
        if ok then sent += #batch else warnf("sell failed:", err) end
        batch = {}
    end
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") and CollectionService:HasTag(tool, Config.Names.AnimalToolTag) then
            batch[#batch + 1] = tool
            if #batch >= Config.SellBatch then flush() end
        end
    end
    flush()
    Stats.Sold += sent
    return true, sent
end

local function fireRemote(name, ...)
    local r = remote(name, "RemoteEvent")
    if not r then return false end
    return (pcall(r.FireServer, r, ...))
end

local function buyNextPickaxe()
    local tiers = PickaxeConfig and PickaxeConfig.Tiers
    if type(tiers) ~= "table" then return end
    local current = LocalPlayer:GetAttribute("PickaxeTier")
    local cash = LocalPlayer:GetAttribute("Cash")
    if type(current) ~= "number" or type(cash) ~= "number" then return end
    local nextTier = tiers[current + 1]
    if nextTier and type(nextTier.Price) == "number" and cash >= nextTier.Price then
        -- [unverified] the shop sends the tier index as id; the controller binds GetPrice(entry)
        fireRemote(Config.Remotes.PickaxeShop, "Buy", current + 1)
        sleep(0.5)
        fireRemote(Config.Remotes.PickaxeShop, "Equip", current + 1)
    end
end

every("AutoSell", function() return S.SellInterval end, function()
    if not carrying() then sellAll() end
end)
every("AutoUpgradePlot", 3, function() fireRemote(Config.Remotes.UpgradePlot) end)
every("AutoOffline", 60, function() fireRemote(Config.Remotes.Offline, "Claim") end) -- [dump] OfflineRewardController

-- Auto Index: IndexController's "Claim!" buttons send these actions to IndexRemote [dump]:
-- "ClaimAllNormal", "ClaimAllLimited", "ClaimAllMutations" (all with nil, nil). "Get" asks the server
-- for the state; the server answers with OnClientEvent("State", entries, mutationEntries) where a
-- claimable entry is "Ready" and a taken one is "Claimed". The reply is used to claim as soon as
-- something becomes Ready, and a slow timer covers a missed reply. Server cooldowns are unknown.
local function stateHasReady(state)
    if type(state) ~= "table" then return false end
    for _, v in pairs(state) do
        if v == "Ready" then return true end
        if type(v) == "table" and stateHasReady(v) then return true end
    end
    return false
end

local function claimIndexAll()
    for _, action in ipairs({ "ClaimAllNormal", "ClaimAllLimited", "ClaimAllMutations" }) do
        fireRemote(Config.Remotes.Index, action, nil, nil)
        sleep(0.25)
    end
end

local indexRemote = remote(Config.Remotes.Index, "RemoteEvent")
if indexRemote then
    table.insert(connections, indexRemote.OnClientEvent:Connect(function(kind, entries, mutations)
        if kind ~= "State" or not S.AutoIndex then return end
        if stateHasReady(entries) or stateHasReady(mutations) then task.spawn(claimIndexAll) end
    end))
end

every("AutoIndex", 15, function()
    fireRemote(Config.Remotes.Index, "Get", nil, nil)
    sleep(1.5) -- let the State reply claim first, then claim anyway as a fallback
    claimIndexAll()
end)

-- Auto Equip Best (base): PetsInventoryController's "Equip Best" button sends ("EquipBest", nil) to
-- PetsInventoryRemote [dump]. The game has an "EquipBestCooldown" error notice, so the interval is
-- a slider. What "best" means (cash per second) is decided by the server.
every("AutoEquipBestBase", function() return S.EquipBestInterval end, function()
    fireRemote(Config.Remotes.Pets, "EquipBest", nil)
end)
every("AutoBuyPickaxe", 4, buyNextPickaxe)

local bankedRemote = remote("AnimalBankedRemote", "RemoteEvent")
if bankedRemote then
    table.insert(connections, bankedRemote.OnClientEvent:Connect(function() Stats.Banked += 1 end))
end

table.insert(connections, LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end))

-- Unload and UI loading ----------------------------------------------------------------------------------
local function unload()
    alive = false
    for _, c in ipairs(connections) do pcall(c.Disconnect, c) end
    for _, fn in ipairs(cleanups) do pcall(fn) end
    if getgenv and getgenv().PattomHeistUnload == unload then getgenv().PattomHeistUnload = nil end
end
if getgenv then getgenv().PattomHeistUnload = unload end

local function ensureAssets()
    if not (writefile and makefolder) then return end
    pcall(function()
        if isfolder and not isfolder(Config.Folder) then makefolder(Config.Folder) end
        if game.HttpGet then
            local ok, data = pcall(game.HttpGet, game, Config.BaseUrl .. "pattomhub.png?t=" .. os.time())
            if ok and type(data) == "string" and #data > 100 then writefile(Config.LogoFile, data) end
        end
    end)
end
ensureAssets()

local function validUi(body) return type(body) == "string" and body:sub(-64):find("return Library%s*$") ~= nil end

local function loadLibrary()
    local body
    if game.HttpGet then
        local ok, res = pcall(game.HttpGet, game, Config.BaseUrl .. "ui.lua?t=" .. os.time())
        if ok and validUi(res) then
            body = res
            if writefile and isfolder and isfolder(Config.Folder) then pcall(writefile, Config.UiFile, body) end
        end
    end
    if not body and isfile and readfile and isfile(Config.UiFile) then
        local ok, res = pcall(readfile, Config.UiFile)
        if ok and validUi(res) then body = res end
    end
    if not body then warnf("could not load ui.lua from GitHub or the local cache") return nil end
    local chunk, err = loadstring(body)
    if not chunk then warnf("UI compile error:", err) return nil end
    local ok, lib = pcall(chunk)
    if not ok or type(lib) ~= "table" then warnf("UI init error:", lib) return nil end
    return lib
end

local Library = loadLibrary()
if not Library then unload() return end

local function T(en, th) return Library:T(en, th) end
Hooks.Notify = function(text, kind) Library:Notify("Pattom Heist", text, 4, kind or "Info") end
Hooks.Halt = function(flag)
    local toggle = Library.Toggles[flag]
    if toggle then toggle:SetValue(false) end
end
Library:OnUnload(unload)

-- UI helpers ---------------------------------------------------------------------------------------------
local function addToggle(group, flag, text, description, default, onChange)
    return group:AddToggle(flag, {
        Text = text, Description = description, Default = default or false,
        Callback = function(value)
            S[flag] = value == true
            if onChange then onChange(S[flag]) end
        end,
    })
end

local function addSlider(group, flag, text, min, max, default, suffix, rounding)
    return group:AddSlider(flag, {
        Text = text, Min = min, Max = max, Default = default, Suffix = suffix or "", Rounding = rounding or 0,
        Callback = function(value) S[flag] = tonumber(value) or default end,
    })
end

-- Multi dropdowns store a set {[label] = true}; read it through GetActiveValues (ui.lua) so the
-- game-side tables never depend on the callback argument shape.
local function syncSet(flag, target, convert)
    for k in pairs(target) do target[k] = nil end
    local option = Library.Options[flag]
    if not option then return end
    for _, label in ipairs(option:GetActiveValues()) do
        local key = convert and convert(label) or label
        if key then target[key] = true end
    end
end

local function uniqueList(...)
    local out, seen = {}, {}
    for _, list in ipairs({ ... }) do
        for _, v in ipairs(list) do
            if type(v) == "string" and not seen[v] then seen[v] = true out[#out + 1] = v end
        end
    end
    return out
end

local function rarityValues()
    local list = {}
    local zones = ZonesConfig and ZonesConfig.Zones
    if type(zones) == "table" then
        for _, z in ipairs(zones) do if z.Rarity then list[#list + 1] = z.Rarity end end
    end
    local ok, ladder = pcall(function() return shared("EggRarity").Ladder() end) -- [dump] EggRarity.Ladder
    return uniqueList(list, ok and type(ladder) == "table" and ladder or {})
end

local function statusValues()
    local list = { "None", "Gold", "Diamond" } -- Gold/Diamond: RequiresVariant in MutationConfig [dump]
    if MutationConfig then
        for _, m in ipairs(MutationConfig.Mutations or {}) do list[#list + 1] = m.Name end
        for _, m in ipairs(MutationConfig.WeatherMutations or {}) do list[#list + 1] = m.Name end
    end
    return uniqueList(list)
end

-- Tabs ---------------------------------------------------------------------------------------------------
local zoneLabelList, zoneByLabel = zoneLabels()

local function buildEggTab(window)
    local tab = window:AddTab(T("Egg", "ไข่"), "farm", T("Smash eggs by zone", "ทุบไข่ตามโซน"))
    local box = tab:AddLeftGroupbox(T("Auto Egg", "ทุบไข่อัตโนมัติ"), "farm")
    addToggle(box, "AutoEgg", T("Auto Egg", "ทุบไข่อัตโนมัติ"),
        T("Swings the game's own pickaxe at the nearest egg in the chosen zones", "ใช้ฟังก์ชันตีของเกมกับไข่ที่ใกล้ที่สุดในโซนที่เลือก"))
    box:AddDropdown("EggZones", {
        Text = T("Zones", "โซน"), Values = zoneLabelList, Multi = true, Default = {},
        Callback = function() syncSet("EggZones", Sel.EggZones, function(l) return zoneByLabel[l] end) end,
    })
    addToggle(box, "EggTeleport", T("Move to the egg", "เดินไปหาไข่"),
        T("Walks at the game's speed. Off: only hits eggs already in reach", "เดินด้วยความเร็วของเกม ปิด: ตีเฉพาะไข่ที่อยู่ในระยะ"), true)
    addToggle(box, "AutoRide", T("Ride the best animal", "ขี่สัตว์ที่ดีที่สุด"),
        T("Mounts the owned rideable with the highest speed bonus before every trip (eggs, steals, run home)",
            "ขี่สัตว์ที่มีโบนัสความเร็วสูงสุดก่อนเดินทางทุกครั้ง (ไข่ ขโมย วิ่งกลับ)"), true)
    addSlider(box, "EggStandOff", T("Stand-off from egg", "ระยะยืนห่างไข่"), 2, 5, 5, " studs", 1)
    addSlider(box, "EggSwingGap", T("Swing retry gap", "ช่วงลองตีซ้ำ"), 0.02, 0.5, 0.05, "s", 2)
    local info = tab:AddRightGroupbox(T("Notes", "หมายเหตุ"), "info")
    info:AddLabel(T("No zone selected = every zone. Reach is 8 studs plus 2 server slack, so the stand-off stays under 6.",
        "ไม่เลือกโซน = ทุกโซน ระยะตี 8 + slack ฝั่งเซิร์ฟเวอร์ 2 จึงจำกัดระยะยืนไม่เกิน 6"), true)
end

local function buildStealTab(window)
    local tab = window:AddTab(T("Steal", "ขโมย"), "extras", T("Grab animals and run home", "คว้าสัตว์แล้ววิ่งกลับ"))
    local box = tab:AddLeftGroupbox(T("Auto Steal", "ขโมยอัตโนมัติ"), "extras")
    addToggle(box, "AutoSteal", T("Auto Steal", "ขโมยอัตโนมัติ"),
        T("Best match first: highest value, then nearest", "เลือกตัวมูลค่าสูงสุดก่อน แล้วตัวที่ใกล้สุด"))
    box:AddDropdown("StealRarities", {
        Text = T("Animal rarity", "ระดับสัตว์"), Values = rarityValues(), Multi = true, Default = {},
        Callback = function() syncSet("StealRarities", Sel.Rarities) end,
    })
    box:AddDropdown("StealStatus", {
        Text = T("Status / mutation", "สถานะที่ติด"), Values = statusValues(), Multi = true, Default = {},
        Callback = function() syncSet("StealStatus", Sel.Mutations) end,
    })
    box:AddInput("StealMinValueText", {
        Text = T("Minimum $/s (1.5M, 20B ...)", "ค่าเงินขั้นต่ำ $/s (1.5M, 20B ...)"), Default = "0", Finished = true,
        Callback = function(text)
            local v = parseMoney(text)
            if v and v >= 0 then S.StealMinValue = v else Hooks.Notify("Not a number: " .. tostring(text), "Warning") end
        end,
    })
    addToggle(box, "StealAllowUnknown", T("Allow unknown value", "อนุญาตตัวที่อ่านค่าไม่ได้"),
        T("Only matters when a minimum is set", "มีผลเมื่อกำหนดค่าขั้นต่ำเท่านั้น"))
    addSlider(box, "StealAvoidGuard", T("Skip animals near a guard", "ข้ามตัวที่อยู่ใกล้การ์ด"), 0, 150, 0, " studs")
    local run = tab:AddRightGroupbox(T("Run home", "วิ่งกลับ"), "farm")
    run:AddDropdown("ReturnMode", {
        Text = T("Return to", "กลับไปที่"), Values = { "Own Plot", "Nearest Safe Zone", "Safe Zone then Own Plot" },
        Default = "Own Plot", Callback = function(v) ReturnMode = Library.Options.ReturnMode.Value or v end,
    })
    addSlider(run, "StealGrabWait", T("Grab timeout", "เวลารอคว้า"), 0.3, 4, 1.2, "s", 1)
    addSlider(run, "StealBankWait", T("Bank timeout", "เวลารอเก็บเข้าแปลง"), 2, 20, 8, "s", 1)
    addSlider(run, "StealCooldown", T("Pause between runs", "พักระหว่างรอบ"), 0, 3, 0.4, "s", 2)
    addSlider(run, "StealMaxDistance", T("Max distance", "ระยะสูงสุด"), 50, 5000, 5000, " studs")
end

local function buildEconomyTab(window)
    local tab = window:AddTab(T("Economy", "เศรษฐกิจ"), "economy", T("Sell, upgrade, claim", "ขาย อัปเกรด รับรางวัล"))
    local sell = tab:AddLeftGroupbox(T("Sell", "ขาย"), "sell")
    addToggle(sell, "AutoSell", T("Auto Sell backpack animals", "ขายสัตว์ในกระเป๋าอัตโนมัติ"),
        T("Sells EVERY unplaced animal tool, including valuable ones", "ขายสัตว์ที่ยังไม่วางทุกตัว รวมตัวแพง"))
    addSlider(sell, "SellInterval", T("Sell every", "ขายทุก"), 5, 120, 20, "s")
    sell:AddButton({ Text = T("Sell All Now", "ขายทั้งหมดเดี๋ยวนี้"), Style = "Primary",
        Func = function() task.defer(function()
            local ok, sent = sellAll()
            Hooks.Notify(ok and ("Sent " .. tostring(sent) .. " animals") or tostring(sent), ok and "Success" or "Warning")
        end) end })
    local up = tab:AddRightGroupbox(T("Upgrades", "อัปเกรด"), "extras")
    addToggle(up, "AutoEquipBestBase", T("Auto Equip Best on Base", "ใส่สัตว์ที่ดีที่สุดบนเบสอัตโนมัติ"),
        T("Presses the pets inventory 'Equip Best' button on a timer", "กดปุ่ม Equip Best ของกระเป๋าสัตว์ตามเวลา"))
    addSlider(up, "EquipBestInterval", T("Equip Best every", "Equip Best ทุก"), 5, 120, 20, "s")
    addToggle(up, "AutoUpgradePlot", T("Auto Upgrade Plot", "อัปเกรดแปลงอัตโนมัติ"), T("Spends money", "ใช้เงิน"))
    addToggle(up, "AutoBuyPickaxe", T("Auto Buy Next Pickaxe", "ซื้อพิกแอกซ์ถัดไปอัตโนมัติ"), T("Spends money", "ใช้เงิน"))
    local rewards = tab:AddRightGroupbox(T("Rewards", "รางวัล"), "gift")
    addToggle(rewards, "AutoOffline", T("Auto Claim Offline Earnings", "รับรายได้ออฟไลน์อัตโนมัติ"), "")
    addToggle(rewards, "AutoIndex", T("Auto Claim Index Rewards", "กดรับของรางวัล Index อัตโนมัติ"),
        T("Claims normal, limited and mutation index rewards as soon as they are Ready", "กดรับรางวัล Index ปกติ/จำกัด/มิวเทชัน ทันทีที่พร้อม"))
end

local function buildStatusTab(window)
    local tab = window:AddTab(T("Status", "สถานะ"), "info", T("Counters", "ตัวนับ"))
    local box = tab:AddLeftGroupbox(T("Status", "สถานะ"), "info")
    local label = box:AddLabel("-")
    task.spawn(function()
        while alive do
            local hrp, hum = character()
            local real = hrp and Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z).Magnitude
            local gameSpeed = hrp and hum and gameMoveSpeed(hrp, hum)
            pcall(label.SetText, label, string.format("Real speed %s | Game speed %s | WalkSpeed %s | Hits %d | Steals %d | Banked %d | Sold %d | Fails %d | %s",
                real and tostring(math.floor(real)) or "-", gameSpeed and tostring(math.floor(gameSpeed)) or "-",
                hum and tostring(math.floor(hum.WalkSpeed)) or "-",
                Stats.Hits, Stats.Steals, Stats.Banked, Stats.Sold,
                Stats.Fails, Stats.Last) .. "\nRide: " .. (isMounted() and Stats.Ride or "not mounted")
                .. "\nSteal scan: " .. Stats.Scan)
            sleep(1)
        end
    end)
    box:AddButton({ Text = T("Drop carried animal", "ทิ้งสัตว์ที่แบกอยู่"),
        Func = function() fireRemote("DropCarriedRemote") end }) -- [dump] ChaseAlertController.requestDrop
end

local UserInputService = game:GetService("UserInputService")
local phone = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

Library:CreateWindow({
    Title = "Pattom Hub", SubTitle = "Egg / Steal", MenuKey = Enum.KeyCode.LeftControl,
    ConfigFolder = "pattom-hub-heist", Language = "Auto", Theme = "Pattom", Scale = phone and 0.9 or 1,
    Assets = { logo = Config.LogoFile },
    OnUnlocked = function()
        local window = Library.Window
        buildEggTab(window)
        buildStealTab(window)
        buildEconomyTab(window)
        buildStatusTab(window)
        window:AddSettingsTab()
        Hooks.Notify("Loaded", "Success")
        pcall(Library.LoadAutoloadConfig, Library)
        for _, flag in ipairs({ "EggZones", "StealRarities", "StealStatus" }) do
            local option = Library.Options[flag]
            if option and option.Callback then pcall(option.Callback) end
        end
    end,
})
