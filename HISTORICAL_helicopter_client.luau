--[[
Snaphu-Dev
Contact me on ROBLOX for any concerns @Urdnot.
Uses full aero solver to resolve physics for this helicopter.
Controller is recommended, for that reason.
There's not much discussion to be had about the script, feel free to poke around, though.
This is open sourced, all I ask is for credit. I do not recommend this helicopter for gameplay, I really don't.
It's fun to fly, but it really is difficult to control.

TO-DO List:
Trim on DPad for hover controls.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Character = script.Parent.Parent
local Humanoid = Character:WaitForChild("Humanoid")

local gamepad = Enum.UserInputType.Gamepad1
local previousCFrame = nil

local rotorDirection = 1
local phase_leadRad = math.pi / 2
local maxPitch = 15
local pitch_smoothFactor = 0.2
local deg_toRad = math.pi / 180

local Kp, Ki, Kd = 5e12, 5e11, 3e12

local function lerp(a,b,t) return a + (b-a)*t end

local nameCandidates = {
	MainRotor   = {"Rotor1","MainRotor","Main","RotorMain","RotorA","MainStack"},
	TailRotor   = {"Rotor2","TailRotor","AntiTorque","Tail","RotorB"},
	MainTorque  = {"Torque","MainTorque","RotorTorque","TorqueMain"},
	TailTorque  = {"Torque","TailTorque","RotorTorqueTail"},
	RotorStack  = {"Rotor1Stack","MainStack","Mast","MastStack"},
	HydraulicF  = {"hydraulicF","HydraulicF","HydroF","HydraulicFront"},
	HydraulicB  = {"hydraulicB","HydraulicB","HydroB","HydraulicBack","HydraulicRear"},
	HydraulicL  = {"hydraulicL","HydraulicL","HydroL","HydraulicLeft"},
	HydraulicR  = {"hydraulicR","HydraulicR","HydroR","HydraulicRight"},
	Alignment   = {"alignmentStack","Alignment","Aligners","StrafeForces"},
	Barrel      = {"barrel","Barrel","GunBarrel","Muzzle"},
	WingFolder  = {"Wing","Wings","Hardpoints","Pylons"},
	TailVF      = {"TailRotorVectorForce","TailVF","YawVectorForce"},
}

local function findFirstChildAny(root, names)
	for _,n in ipairs(names) do
		local f = root:FindFirstChild(n, true)
		if f then return f end
	end
end

local function findFirstDescendantOfClass(root, className, namePrefix)
	for _,desc in ipairs(root:GetDescendants()) do
		if desc.ClassName == className then
			if not namePrefix or desc.Name:sub(1, #namePrefix) == namePrefix then
				return desc
			end
		end
	end
end

local function collectChildrenByPrefix(root, prefix)
	local out = {}
	for _,desc in ipairs(root:GetDescendants()) do
		if desc:IsA("BasePart") and desc.Name:sub(1,#prefix) == prefix then
			table.insert(out, desc)
		end
	end
	table.sort(out, function(a,b) return a.Name < b.Name end)
	return out
end

local function collectHubs(root)
	local out = {}
	for _,cc in ipairs(root:GetDescendants()) do
		if cc:IsA("CylindricalConstraint") then
			local attach = cc.Parent and cc.Parent:FindFirstChildWhichIsA("Attachment")
			if not attach then
				attach = findFirstDescendantOfClass(cc, "Attachment")
			end
			if attach then
				table.insert(out, {hub = cc, attachment = attach})
			end
		end
	end
	return out
end

local function getAncestorModel(partOrSeat)
	local a = partOrSeat
	while a and not a:IsA("Model") do a = a.Parent end
	return a
end

local function looksLikeHelicopter(model)
	if not model or not model:IsA("Model") then return false end
	local main = findFirstChildAny(model, nameCandidates.MainRotor) or model:FindFirstChildWhichIsA("Model")
	if not main then return false end
	local blades = collectChildrenByPrefix(model, "Blade")
	return #blades >= 2
end

local function newHelicopterState(model, seat)
	return {
		Model = model,
		Seat = seat,
		MainRotorModel = nil,
		TailRotorModel = nil,
		MainTorque = nil,
		TailTorque = nil,
		Rotor1Stack = nil,
		Blades = {},
		Hubs = {},
		Hydraulics = {
			F = { cyl=nil, pris=nil },
			B = { cyl=nil, pris=nil },
			L = { cyl=nil, pris=nil },
			R = { cyl=nil, pris=nil },
		},
		Barrel = nil,
		WingFolder = nil,
		TailVectorForce = nil,
		Strafe = { F=nil, B=nil, L=nil, R=nil },
		AlignmentStack = nil,
		
		CurrentYawAngle = 0,
		altitudeControlActive = false,
		collectivePitch = -15,
		desiredAltitude = 0,
		altitudeErrorSum = 0,
		previousAltitudeError = 0,
		
		referencePosition = nil,
		referenceOrientation = nil,
		
		orientationErrorSumX = 0,
		orientationErrorSumY = 0,
		orientationErrorSumZ = 0,
		previousOrientationErrorX = 0,
		previousOrientationErrorY = 0,
		previousOrientationErrorZ = 0,
		
		lastWingSide = nil,
		
		Connection = false,
		accumulator = 0,
		targetHz = 240,
        step = 1/240,
        TailHinges = {},
        TailPitchDeg = 0
	}
end

local function collectTailHinges(root)
    if not root then 
        warn("collectTailHinges was called with a nil root.")
        return {} 
    end

    local out = {}

    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("HingeConstraint") then
            local n = d.Name:lower()

            if n == "hinge" or n:match("^hinge%d+$") then
                table.insert(out, d)
            end
        end
    end
    table.sort(out, function(a, b)
        return a.Name < b.Name
    end)

    return out
end

local function isLocalPilot(H)
	return H and H.Seat and H.Seat.Occupant == Humanoid
end

local function beginExitMode(H)
	H.ExitMode = {t = 0, duration = 3.5}
end

local HelicoptersByModel = {}
local HelicoptersBySeat  = {}

local projectilePool = {}
local function getProjectileFromPool()
	if #projectilePool > 0 then
		local projectile = table.remove(projectilePool)
		projectile.Parent = workspace
		return projectile
	else
		local projectile = Instance.new("Part")
		projectile.Size = Vector3.new(0.22, 0.22, 0.22)
		projectile.Anchored = false
		projectile.CanCollide = false
		projectile.Material = Enum.Material.Neon
		projectile.Color = Color3.fromRGB(255, 255, 255)
		projectile.Parent = workspace
		local attachment0 = Instance.new("Attachment", projectile)
		attachment0.Position = Vector3.new(0, 0, -0.15)
		local attachment1 = Instance.new("Attachment", projectile)
		attachment1.Position = Vector3.new(0, 0, 0.15)
		local trail = Instance.new("Trail")
		trail.Attachment0 = attachment0
		trail.Attachment1 = attachment1
		trail.Lifetime = 0.125
		trail.Color = ColorSequence.new(Color3.fromRGB(255, 148, 42), Color3.fromRGB(128, 71, 1))
		trail.Transparency = NumberSequence.new{
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(1, 1)
		}
		trail.LightEmission = 1
		trail.Parent = projectile
		local fireSound = Instance.new("Sound")
		fireSound.SoundId = "rbxassetid://165593900"
		fireSound.Parent = projectile
		fireSound:Play()
		return projectile
	end
end

local function fireProjectile(h, sourcePart, speed, gravity, maxTime, maxBounces)
	if not sourcePart then return end
	local projectile = getProjectileFromPool()
	projectile.Position = sourcePart.Position
	local gunSound = sourcePart:FindFirstChild("MuzzleFire")
	if gunSound and gunSound:IsA("Sound") then gunSound:Play() end
	local bounceCount = 0
	local bounceDampening = 0.8
	local direction = (sourcePart.CFrame.LookVector).Unit
	local velocity = direction * (speed or 750)
	local previousPosition = sourcePart.Position
	local startTime = tick()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { projectile }
	
	local connection
	connection = RunService.PreRender:Connect(function(deltaTime)
		local elapsedTime = tick() - startTime
		if elapsedTime > (maxTime or math.huge) or bounceCount > (maxBounces or math.huge) then
			projectile.Parent = nil
			table.insert(projectilePool, projectile)
			connection:Disconnect()
			return
		end
		velocity = velocity + Vector3.new(0, -(gravity or 9.8) * deltaTime, 0)
		local nextPosition = projectile.Position + velocity * deltaTime
		local rayDirection = nextPosition - previousPosition
		local res = workspace:Raycast(previousPosition, rayDirection, rp)
		if res then
			local hitInstance = res.Instance
			local hitPos = res.Position
			if hitInstance == workspace.Baseplate then
				bounceCount += 1
				local hitNormal = res.Normal
				local dot = velocity:Dot(hitNormal)
				velocity = (velocity - 2 * dot * hitNormal) * bounceDampening
				projectile.Position = hitPos + hitNormal * 0.01
			else
				ReplicatedStorage.ProjectileHit:FireServer(hitPos, hitInstance)
				projectile.Parent = nil
				table.insert(projectilePool, projectile)
				connection:Disconnect()
				return
			end
		else
			projectile.Position = nextPosition
		end
		previousPosition = projectile.Position
	end)
end

local rocketPool = {}
local function getRocketFromPool()
	local r = table.remove(rocketPool)
	if not r then
		r = Instance.new("Part")
		r.Size = Vector3.new(1,3,1)
		r.Shape = Enum.PartType.Cylinder
		r.Material = Enum.Material.Metal
		r.Anchored, r.CanCollide = true, false
	end
	r.Parent = workspace
	return r
end
local function returnRocketToPool(r) r.Parent=nil; table.insert(rocketPool, r) end

local function resolveHelicopterForSeat(seat)
	local mdl = getAncestorModel(seat)
	if not mdl or not looksLikeHelicopter(mdl) then return nil end
	
	if HelicoptersByModel[mdl] then
		local existing = HelicoptersByModel[mdl]
		existing.Seat = seat
		HelicoptersBySeat[seat] = existing
		return existing
	end
	
	local H = newHelicopterState(mdl, seat)
	
	H.MainRotorModel = findFirstChildAny(mdl, nameCandidates.MainRotor) or mdl
    H.TailRotorModel = findFirstChildAny(mdl, nameCandidates.TailRotor)
	H.Rotor1Stack    = findFirstChildAny(mdl, nameCandidates.RotorStack)
	
	local mainRotor = H.MainRotorModel
	local tailRotor = H.TailRotorModel
	H.MainTorque = mainRotor and findFirstChildAny(mainRotor, nameCandidates.MainTorque)
	H.TailTorque = tailRotor and findFirstChildAny(tailRotor, nameCandidates.TailTorque)
	
	H.Blades = collectChildrenByPrefix(H.MainRotorModel or mdl, "Blade")
	H.Hubs   = collectHubs(H.MainRotorModel or mdl)
    H.TailHinges = collectTailHinges(H.TailRotorModel)
    
	local function getHydro(tblNames)
		local node = findFirstChildAny(mdl, tblNames)
		if not node then return nil,nil end
		local cyl = node:FindFirstChildWhichIsA("CylindricalConstraint", true)
		local pri = node:FindFirstChildWhichIsA("PrismaticConstraint", true)
		return cyl, pri
	end
	H.Hydraulics.F.cyl, H.Hydraulics.F.pris = getHydro(nameCandidates.HydraulicF)
	H.Hydraulics.B.cyl, H.Hydraulics.B.pris = getHydro(nameCandidates.HydraulicB)
	H.Hydraulics.L.cyl, H.Hydraulics.L.pris = getHydro(nameCandidates.HydraulicL)
	H.Hydraulics.R.cyl, H.Hydraulics.R.pris = getHydro(nameCandidates.HydraulicR)
	
	H.AlignmentStack = findFirstChildAny(mdl, nameCandidates.Alignment)
	local function vf(name)
		return H.AlignmentStack and H.AlignmentStack:FindFirstChild(name)
	end
	--[[H.Strafe.F = vf("VectorForceF")
	H.Strafe.B = vf("VectorForceB")
	H.Strafe.L = vf("VectorForceL")
	H.Strafe.R = vf("VectorForceR")]]
	
	H.Barrel = findFirstChildAny(mdl, nameCandidates.Barrel) or findFirstDescendantOfClass(mdl, "Attachment", "Muzzle")
	H.WingFolder = findFirstChildAny(mdl, nameCandidates.WingFolder)
	H.TailVectorForce = findFirstChildAny(mdl, nameCandidates.TailVF)
	
	HelicoptersByModel[mdl] = H
	HelicoptersBySeat[seat] = H
	return H
end

local function getNextWingAttachment(H)
	if not H.WingFolder then return nil end
	local left  = H.WingFolder:FindFirstChild("Left", true)
	local right = H.WingFolder:FindFirstChild("Right", true)
	local function asAttachment(node)
		if not node then return nil end
		return node:IsA("Attachment") and node or node:FindFirstChildWhichIsA("Attachment", true)
	end
	if right and (not H.lastWingSide or H.lastWingSide == "Left") then
		H.lastWingSide = "Right"
		return asAttachment(right)
	elseif left then
		H.lastWingSide = "Left"
		return asAttachment(left)
	end
	return findFirstDescendantOfClass(H.WingFolder, "Attachment")
end

local function rocketProjectile(H, sourcePart, speed, gravity, maxTime, burnTime, thrust)
	sourcePart = sourcePart or H.Barrel
	if not sourcePart then return end
	
	local rocket = getRocketFromPool()
	local startCF = sourcePart:IsA("Attachment") and sourcePart.WorldCFrame or sourcePart.CFrame
	rocket.CFrame = startCF
	
	local tail = rocket:FindFirstChild("TrailTail") or Instance.new("Attachment", rocket)
	tail.Name = "TrailTail"
	tail.Position = Vector3.new(0, 0, -0.7)
	
	local nose = rocket:FindFirstChild("TrailNose") or Instance.new("Attachment", rocket)
	nose.Name = "TrailNose"
	nose.Position = Vector3.new(0, 0, 0.3)
	
	local trail = rocket:FindFirstChild("ThrustTrail") or Instance.new("Trail", rocket)
	trail.Name = "ThrustTrail"
	trail.Attachment0 = tail
	trail.Attachment1 = nose
	trail.Enabled = true
	trail.Lifetime = 0.25
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255,255,255)),
		ColorSequenceKeypoint.new(0.20, Color3.fromRGB(255,200,120)),
		ColorSequenceKeypoint.new(0.50, Color3.fromRGB(255,150,50)),
		ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255,80,10)),
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1)
	})
	trail.WidthScale = NumberSequence.new(1, 0.1)
	
	task.spawn(function()
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://80846615479498"
		s.Volume = 3
		s.RollOffMode = Enum.RollOffMode.Inverse
		s.MaxDistance = 750
		s.Parent = rocket
		s:Play()
		game:GetService("Debris"):AddItem(s, 3)
	end)
	
	local function explodeAt(pos)
		ReplicatedStorage.RocketExplosion:FireServer(pos)
		task.spawn(function()
			local boom = Instance.new("Sound")
			boom.SoundId = "rbxassetid://138186576"
			boom.Volume = 1
			boom.RollOffMode = Enum.RollOffMode.Inverse
			boom.MaxDistance = 1500
			boom.Parent = workspace.Terrain
			boom:Play()
			game:GetService("Debris"):AddItem(boom, 4)
		end)
		local fireball = Instance.new("Part")
		fireball.Anchored = true
		fireball.CanCollide = false
		fireball.Shape = Enum.PartType.Ball
		fireball.Material = Enum.Material.Neon
		fireball.Color = Color3.fromRGB(255, 140, 30)
		fireball.Transparency = 0
		fireball.Size = Vector3.new(2,2,2)
		fireball.CFrame = CFrame.new(pos)
		fireball.Parent = workspace
		local sparks = Instance.new("ParticleEmitter")
		sparks.Texture = "rbxassetid://243660364"
		sparks.Speed = NumberRange.new(40, 70)
		sparks.Lifetime = NumberRange.new(0.15, 0.35)
		sparks.Rate = 0
		sparks.SpreadAngle = Vector2.new(180, 180)
		sparks.Parent = fireball
		sparks:Emit(60)
		local smoke = Instance.new("ParticleEmitter")
		smoke.Texture = "rbxassetid://7712212243"
		smoke.Transparency = NumberSequence.new{
			NumberSequenceKeypoint.new(0, 0.15),
			NumberSequenceKeypoint.new(1, 1)
		}
		smoke.Size = NumberSequence.new(6, 12)
		smoke.Lifetime = NumberRange.new(0.9, 1.6)
		smoke.Speed = NumberRange.new(2, 6)
		smoke.Rate = 0
		smoke.SpreadAngle = Vector2.new(35, 35)
		smoke.Parent = fireball
		smoke:Emit(35)
		task.spawn(function()
			for i = 1, 18 do
				fireball.Size += Vector3.new(1.2,1.2,1.2)
				fireball.Transparency = fireball.Transparency + 0.04
				task.wait(0.02)
			end
			fireball:Destroy()
		end)
	end
	
	local t, pos = 0, rocket.Position
	local vel = startCF.LookVector * (speed or 200)
	local fuel = 0
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {rocket, H.Model}
	
	local conn
	conn = RunService.PreRender:Connect(function(dt)
		t += dt
		if t > (maxTime or 5) then
			trail.Enabled = false
			returnRocketToPool(rocket)
			conn:Disconnect()
			return
		end
		local g = Vector3.new(0, -(gravity or 9.81), 0)
		local thrustAcc = fuel < (burnTime or 1.5) and (thrust or 15000) / math.max(rocket.Mass, 1) or 0
		local thrustVec = vel.Magnitude > 0 and vel.Unit * thrustAcc or Vector3.zero
		vel += (g + thrustVec) * dt
		local old = pos
		pos += vel * dt
		local hit = workspace:Raycast(old, pos - old, params)
		if hit then
			trail.Enabled = false
			explodeAt(hit.Position)
			returnRocketToPool(rocket)
			conn:Disconnect()
			return
		end
		rocket.CFrame = CFrame.new(pos, pos + vel)
		fuel += dt
	end)
end

local function calculateAzimuth(bladePosition, rotorPosition, rotorForward)
	local forward = typeof(rotorForward) == "Vector3" and rotorForward.Unit or Vector3.new(0,0,-1)
	local rel = (bladePosition - rotorPosition)
	local up = rel:Cross(forward)
	if up.Magnitude == 0 then
		up = (math.abs(forward.X) > 0.99 and Vector3.new(0,0,1) or Vector3.new(1,0,0)):Cross(forward)
	end
	up = up.Unit
	local right = forward:Cross(up).Unit
	local angle = math.atan2(rel:Dot(right), rel:Dot(forward))
	return angle % (2*math.pi)
end


local function cyclicPitch(collectivePitch, throttleInput, steerInput, azimuthAngleRad, opts)
    opts = opts or {}
    local rotDir  = opts.rotDir or 1
    local phase0  = opts.phase0 or 0
    local longK   = opts.longGain or 1
    local latK    = opts.latGain  or 1

    local psi = azimuthAngleRad + phase0
    local theta1c = longK * throttleInput
    local theta1s = latK  * steerInput
    return collectivePitch + theta1c * math.cos(psi) + rotDir * theta1s * math.sin(psi)
end

local function manualUpControl(H)
    if H.MainTorque and H.MainTorque:IsA("Torque") then
        local oldMain = H.MainTorque.Torque.X
        local mainX = math.clamp(oldMain - 25500, -7057500, 0)
        H.MainTorque.Torque = Vector3.new(mainX, 0, 0)
        if H.TailTorque and H.TailTorque:IsA("Torque") then
            local k = 0.1
            local tailX = H.TailTorque.Torque.X
            local delta = (oldMain - mainX)
            local newTail = math.clamp(tailX + k * delta, 0, 73090)
            H.TailTorque.Torque = Vector3.new(newTail, 0, 0)
        end
    end
    H.collectivePitch += math.clamp(0.00003 * 0.5, -5, 5)
end

local function manualDownControl(H)
    if H.MainTorque and H.MainTorque:IsA("Torque") then
        local oldMain = H.MainTorque.Torque.X
        local mainX = math.clamp(oldMain + 25500, -7057500, 0)
        H.MainTorque.Torque = Vector3.new(mainX, 0, 0)
        if H.TailTorque and H.TailTorque:IsA("Torque") then
            local k = 0.1
            local tailX = H.TailTorque.Torque.X
            local delta = (oldMain - mainX)
            local newTail = math.clamp(tailX + k * delta, 0, 73090)
            H.TailTorque.Torque = Vector3.new(newTail, 0, 0)
        end
    end
    H.collectivePitch -= math.clamp(0.00003 * 0.5, -5, 5)
end

UserInputService.TouchStarted:Connect(function(touch, processed)
	if processed then return end
	local pos = touch.Position
	
	if pos.X > workspace.CurrentCamera.ViewportSize.X * 0.5 then
		isTouchingUp = true
	end
end)

UserInputService.TouchEnded:Connect(function(touch, processed)
	if processed then return end
	isTouchingUp = false
end)


local function loop(H, dt)
	if not H.Seat then return end
	local throttleFloat = -H.Seat.ThrottleFloat or 0
	local steerFloat    = -H.Seat.SteerFloat or 0
	local pilot = H.Seat and H.Seat.Occupant
	if not pilot or pilot ~= Humanoid then
		return
	end
	
	do
		if isLocalPilot(H) then
			if UserInputService:IsGamepadButtonDown(gamepad, Enum.KeyCode.ButtonR2) and not H._fireDebounce and H.Barrel then
				H._fireDebounce = true
				ReplicatedStorage.FireBullet:FireServer(H.Model, H.Barrel, 3000, 75, 500)
				fireProjectile(H, H.Barrel, 750, 9.8, 5)
				task.delay(0.15, function() H._fireDebounce = false end)
			end
			if UserInputService:IsGamepadButtonDown(gamepad, Enum.KeyCode.ButtonL2) and not H._fireDebounce1 then
				H._fireDebounce1 = true
				local hardpoint = getNextWingAttachment(H)
				ReplicatedStorage.FireRocket:FireServer(H.Model, hardpoint, 450, 9.81, 5.0, 1.5, 8000)
				rocketProjectile(H, hardpoint, 200, 9.8, 5, 1.5, 15000)
				task.delay(0.15*1.756, function() H._fireDebounce1 = false end)
			end
		end
	end
	
	
	if not H.altitudeControlActive then
		if UserInputService:IsKeyDown(Enum.KeyCode.F)
			or UserInputService:IsGamepadButtonDown(gamepad, Enum.KeyCode.ButtonY)
			or isTouchingUp then
			manualUpControl(H, dt)
			
		elseif UserInputService:IsKeyDown(Enum.KeyCode.V)
			or UserInputService:IsGamepadButtonDown(gamepad, Enum.KeyCode.ButtonB) then
			manualDownControl(H, dt)
		end
		
		
		local function driveHydro(h, target)
			if h.cyl then h.cyl.TargetPosition = lerp(h.cyl.TargetPosition,  target, 1.80) end
			if h.pris then h.pris.TargetPosition = lerp(h.pris.TargetPosition, target, 1.80) end
		end
		
		local throttleSign = math.sign(throttleFloat)
		local steerSign    = math.sign(steerFloat)
		local throttleTarget = math.clamp((11*0.333)^math.abs(throttleFloat), -math.abs(throttleFloat), math.abs(throttleFloat))
		local steerTarget    = math.clamp((11*0.333)^math.abs(steerFloat),    -math.abs(steerFloat),    math.abs(steerFloat))
		driveHydro(H.Hydraulics.F,  -throttleSign * throttleTarget)
		driveHydro(H.Hydraulics.B, throttleSign * throttleTarget)
		driveHydro(H.Hydraulics.R,  -steerSign    * steerTarget)
		driveHydro(H.Hydraulics.L, steerSign    * steerTarget)
			local inputCurve = 0.65
			local coord_roll, coord_pitch = 0.25, 0.10
			local roll_max, pitch_max = math.rad(20), math.rad(15)
			local kP_Roll, kD_Roll = 1.8, 0.45
			local kP_Pitch, kD_Pitch = 1.6, 0.40
			
			local maxTilt, smoothFactor = 45, 0.40
			local yawThrust_max, yawInput_sign = 50000, -1
			local yawRate_CMD, rate_limit = math.rad(65), math.rad(110)
			local deadzone_pedal = 0.04
			local k_Rate, kYaw_soft, kBias = 0.70, 0.35, 0.50
			
			local step, mobileStep = 0, 0
			do
				local maxTilt_gyro, deadzone = math.rad(30), 0.15
				local filterAlpha, curveMix = 0.25, 0.35
				local antiCreep_rad, antiCreep_dec = math.rad(1.0), 0.90
				H.mobileFilteredRoll = H.mobileFilteredRoll or 0
				if UserInputService.GyroscopeEnabled then
					local ok, cf = UserInputService:GetDeviceRotation()
					if ok and cf then
						local _,_,rawRoll = cf:ToOrientation()
						H.mobileFilteredRoll += (rawRoll - H.mobileFilteredRoll) * filterAlpha
                    if math.abs(H.mobileFilteredRoll) < antiCreep_rad then H.mobileFilteredRoll *= antiCreep_dec end
						local x = math.clamp(H.mobileFilteredRoll / maxTilt_gyro, -1, 1)
                    if math.abs(x) < deadzone then
                        x = 0 
                    else
                        x = (math.sign(x) * ((math.abs(x) - deadzone) / (1 - deadzone)))                                                
                    end
						mobileStep = (x*x*x)*(1-curveMix) + x*curveMix
					end
				end
			end
			
			H.CurrentYawAngle = H.CurrentYawAngle + (step - H.CurrentYawAngle) * smoothFactor
			local yawMix = (H.CurrentYawAngle / maxTilt) * yawInput_sign
			
			local function curve(x) x = math.clamp(x, -1, 1); return x*(1-inputCurve) + (x^3)*inputCurve end
			local rollCmd  = curve(steerFloat)    + yawMix * coord_roll
			local pitchCmd = curve(throttleFloat) + yawMix * coord_pitch
			
			local root = (H.Model and H.Model.PrimaryPart) or H.Seat
			if root then
				local pitchNow, yawNow, rollNow = root.CFrame:ToOrientation()
				local angVel = root.AssemblyAngularVelocity
				
				if not H.refPitch or not H.refRoll then
					H.refPitch = pitchNow
					H.refRoll  = rollNow
				end
				
				local pilotControls = isLocalPilot(H)
				local pilotDemandMag = math.max(math.abs(rollCmd), math.abs(pitchCmd))
				local pilotActive = pilotControls and (pilotDemandMag > 0.08)
				local SAS_AUTH = 0.35 + (1 - pilotDemandMag) * (0.85 - 0.35)
				
				if not pilotControls and H.ExitMode then
					H.ExitMode.t = H.ExitMode.t + (dt or 1/60)
					local s = math.clamp(1 - (H.ExitMode.t / H.ExitMode.duration), 0, 1)
					local desiredRoll  = lerp(rollNow,  H.refRoll,  s)
					local desiredPitch = lerp(pitchNow, H.refPitch, s)
					local rollError  = (desiredRoll  - rollNow)  * SAS_AUTH
					local pitchError = (desiredPitch - pitchNow) * SAS_AUTH
					H.TargetRollAngle  = rollNow  + rollError  * kP_Roll  - angVel.Z * kD_Roll
					H.TargetPitchAngle = pitchNow + pitchError * kP_Pitch - angVel.X * kD_Pitch
					H.collectivePitch = lerp(H.collectivePitch, -5, 0.02)
				else
					local desiredRoll  = pilotActive and (math.clamp(rollCmd,  -1, 1) * roll_max)  or H.refRoll
					local desiredPitch = pilotActive and (math.clamp(pitchCmd, -1, 1) * pitch_max) or H.refPitch
					local rollError  = (desiredRoll  - rollNow)  * SAS_AUTH
					local pitchError = (desiredPitch - pitchNow) * SAS_AUTH
					H.TargetRollAngle  = rollNow  + rollError  * kP_Roll  - angVel.Z * kD_Roll
					H.TargetPitchAngle = pitchNow + pitchError * kP_Pitch - angVel.X * kD_Pitch
				end
				
				local function wrapPi(a) return (a + math.pi) % (2*math.pi) - math.pi end
				H.TargetYawAngle = H.TargetYawAngle or yawNow
				
				local pedalActive = math.abs(yawMix) > deadzone_pedal
				local desiredYawRate
				local pedalActive = math.abs(yawMix) > deadzone_pedal
				local desiredYawRate
				
				if pedalActive and pilotControls then
					desiredYawRate = math.clamp(yawMix * yawRate_CMD, -rate_limit, rate_limit)
					H.TargetYawAngle = yawNow
                end
                
                local yawInput = 0

                if UserInputService:IsKeyDown(Enum.KeyCode.Q)
                    or UserInputService:IsGamepadButtonDown(gamepad, Enum.KeyCode.ButtonL1) then
                    for _, hinge in ipairs(H.TailHinges) do
                        local lo, hi = hinge.LowerAngle or -70, hinge.UpperAngle or 70
                        local a = hinge.TargetAngle or 0
                        a = math.clamp(a + 1, lo, hi)
                        hinge.TargetAngle = a
                    end

                elseif UserInputService:IsKeyDown(Enum.KeyCode.E)
                    or UserInputService:IsGamepadButtonDown(gamepad, Enum.KeyCode.ButtonR1) then
                    for _, hinge in ipairs(H.TailHinges) do
                        local lo, hi = hinge.LowerAngle or -70, hinge.UpperAngle or 70
                        local a = hinge.TargetAngle or 0
                        a = math.clamp(a - 1, lo, hi)
                        hinge.TargetAngle = a
                    end

                elseif mobileStep ~= 0 then
                    for _, hinge in ipairs(H.TailHinges) do
                        hinge.TargetAngle = 0
                    end
                else
                    for _, hinge in ipairs(H.TailHinges) do
                        hinge.TargetAngle = 0
                    end
                end

            end
		end

	if H.Rotor1Stack then
		local rotorPos = H.Rotor1Stack.Position
		local rotorForward = H.Rotor1Stack.CFrame.LookVector
		for _,blade in ipairs(H.Blades) do
			local initPitch = 0
            local az = calculateAzimuth(blade.Position, rotorPos, rotorForward)

            local long = throttleFloat * -1
            local lat  = steerFloat

            local thetaDeg = cyclicPitch(
                H.collectivePitch,
                long,
                lat,
                az,
                { rotDir = rotorDirection, phase0 = phase_leadRad,
                    longGain = maxPitch, latGain = maxPitch }
            )

            thetaDeg = math.clamp(thetaDeg, -maxPitch, maxPitch)

            local cur = blade.Orientation
            local finalZ = cur.Z + (thetaDeg - cur.Z) * pitch_smoothFactor
            blade.Orientation = Vector3.new(cur.X, cur.Y, finalZ)
		end
	end
	
	if #H.Hubs > 0 and H.Rotor1Stack then
		for _,h in ipairs(H.Hubs) do
			local att = h.attachment
			local hub = h.hub
			if hub and att then
				local az = calculateAzimuth(att.WorldPosition, H.Rotor1Stack.Position, H.Rotor1Stack.CFrame.LookVector)
                local long = (H.Seat.ThrottleFloat or 0) * -1
                local lat  = (H.Seat.SteerFloat or 0)

                local thetaDeg = cyclicPitch(
                    H.collectivePitch, long, lat, az,
                    { rotDir = rotorDirection, phase0 = phase_leadRad }
                )

                hub.TargetAngle = math.rad(thetaDeg)
            end
		end
	end
end

local function startHeli(H)
	local root = (H.Model and H.Model.PrimaryPart) or H.Seat
	if root then
		local _, yawNow, _ = root.CFrame:ToOrientation()
		H.TargetYawAngle = yawNow
		H.CurrentYawAngle = 0
	end
	
	H.IsActive = true
	H.IsFlying = true
	H.lastWingSide = nil
	
	local p,y,r = H.Seat.CFrame:ToOrientation()
	H.refPitch = p
	H.refRoll  = r
	H.TargetYawAngle = y
	
	if H.MainTorque then
		H.MainTorque.Enabled = true
		H.MainTorque.Torque = Vector3.new(-5, 0, 0)
	end
	if H.TailTorque then
		H.TailTorque.Enabled = true
		H.TailTorque.Torque = Vector3.new(-5, 0, 0)
	end
end

local function stopHeli(H)
	H.IsActive = false
	H.IsFlying = false
	
	if H.MainTorque then
		H.MainTorque.Enabled = false
	end
	if H.TailTorque then
		H.TailTorque.Enabled = false
	end
end

UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if (input.KeyCode == Enum.KeyCode.Z) or (input.UserInputType == gamepad and input.KeyCode == Enum.KeyCode.ButtonX) then
		for _,H in pairs(HelicoptersByModel) do
			if H.Seat and H.Seat.Occupant == Humanoid then
				H.altitudeControlActive = not H.altitudeControlActive
				if H.altitudeControlActive and H.Seat then
					H.desiredAltitude = H.Seat.Position.Y - (H.referencePosition and H.referencePosition.Y or 0)
					H.altitudeErrorSum, H.previousAltitudeError = 0, 0
					H.orientationErrorSumX, H.orientationErrorSumY, H.orientationErrorSumZ = 0,0,0
					H.previousOrientationErrorX, H.previousOrientationErrorY, H.previousOrientationErrorZ = 0,0,0
				end
				break
			end
		end
	end
end)

local function bindSeat(seat)
	if not (seat and (seat:IsA("Seat") or seat:IsA("VehicleSeat"))) then return end
	
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local humanoid = seat.Occupant
		if humanoid then
			if not CollectionService:HasTag(seat, "Helicopter") then return end
			local H = resolveHelicopterForSeat(seat)
			if not H then return end
			if H.Connection then return end
			
			H.Connection = true
			startHeli(H)
			
			H.IsFlying = true
			while H.IsFlying and H.Seat and (H.Seat.Occupant or H.ExitMode) do
				local dt = RunService.PreRender:Wait()
				H.accumulator += dt
				if H.accumulator >= H.step then
					loop(H, H.accumulator)
					H.accumulator %= H.step
					if H.ExitMode and H.ExitMode.t >= H.ExitMode.duration then
						H.ExitMode = nil
						H.IsFlying = false
					end
				end
			end
			
			stopHeli(H)
			H.Connection = false
		else
			local H = HelicoptersBySeat[seat]
			if H and H.Seat == seat then
				beginExitMode(H)
			end
		end
	end)
end

for _,d in ipairs(workspace:GetDescendants()) do
	if d:IsA("Seat") or d:IsA("VehicleSeat") then
		bindSeat(d)
	end
end

workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("Seat") or inst:IsA("VehicleSeat") then
		bindSeat(inst)
	end

end)
