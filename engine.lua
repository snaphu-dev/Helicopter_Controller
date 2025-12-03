--!strict
local engine = {};

local rs = game:GetService("ReplicatedStorage");
local cout = game:GetService("TestService");
local cs = game:GetService("CollectionService");

local HeliNet = rs:WaitForChild("HeliNet");
local Client_Information = HeliNet:WaitForChild("Client_Information");

local tag = "helicopter_chassis";
local deflection = 5;

local torqueAccel = 1000000;
local MAX_TORQUE = 6000000;
local MAX_TAIL_TORQUE = 18000;
local MAX_TAIL_VECTOR_FORCE = 9250;
local BASE_TORQUE = 100;
local MAX_TAIL_PITCH = 35;

local MAX_LIFT_FORCE = 500000;
local ROTOR_MAX_SPEED = 100;
local ROTATIONAL_FRICTION = 1000000;

local FUSELAGE_DRAG = Vector3.new(25, 45, 2.5); 

local MAX_CYCLIC_PITCH = math.rad(15);
local MAX_FLAP_ANGLE = math.rad(1.5);
local MAX_LEAD_LAG = math.rad(1.5);
local PHASE_OFFSET = math.pi / 2;
local MAX_DROOP = math.rad(1.5);
local MAST_TILT_TRIM = math.rad(1.5);

local input_template = {
	Longitudinal = 0;
	Lateral = 0;
	Vertical = 0;
	Yaw = 0;
	Weapon = 0;
	Weapon1 = 0;
	Brake = 0;
};

type InputPacket = {
	Longitudinal: number?;
	Lateral: number?;
	Vertical: number?;
	Yaw: number?;
	Weapon: number?;
	Weapon1: number?;
	Brake: number?;
}

type BladeData = {
	Motor: Motor6D;
	OriginalC0: CFrame;
	OriginalC1: CFrame;
	BladePart: BasePart;
	HubPart: BasePart;
}

local function lerp(a:number, b:number, t:number)
	return a + (b - a) * math.clamp(t, 0, 1);
end;

local function findHydraulicServo(model:Instance, partName:string):CylindricalConstraint?
	local part = model:FindFirstChild(partName, true);
	if part then
		return part:FindFirstChildWhichIsA("CylindricalConstraint");
	end
	return nil;
end;

local function findMainRotor(model:Instance): Torque?
	local part = model:FindFirstChild("Rotor1", true);
	if part then
		return part:FindFirstChildWhichIsA("Torque");
	end
	return nil;
end;

local function findTailRotor(model:Instance): Torque?
	local part = model:FindFirstChild("TailRotor", true);
	if part then
		return part:FindFirstChildWhichIsA("Torque");
	end
	return nil;
end;

local function findTailBladeHinges(model:Instance): {HingeConstraint}
	local hinges = {};
	local tailRotorModel = model:FindFirstChild("TailRotor", true);

	if tailRotorModel then
		for _, desc in ipairs(tailRotorModel:GetDescendants()) do
			if desc:IsA("HingeConstraint") then
				table.insert(hinges, desc);
			end
		end
	end
	return hinges;
end;

local function findBladeMotors(heliModel:Instance): {BladeData}
	local bladeData = {};
	local rotorModel = heliModel:FindFirstChild("Rotor1", true);

	if not rotorModel then 
		cout:Message("!! CRITICAL: 'Rotor1' model not found in " .. heliModel.Name);
		return bladeData;
	end

	for _, desc in ipairs(heliModel:GetDescendants()) do
		if desc:IsA("Motor6D") then
			local p1 = desc.Part1;
			local p0 = desc.Part0;
			if p1 and p0 then
				local isP1Blade = p1.Name:lower():find("blade") and p1:IsDescendantOf(rotorModel);
				local isP0Blade = p0.Name:lower():find("blade") and p0:IsDescendantOf(rotorModel);

				if isP1Blade then
					table.insert(bladeData, {Motor = desc; OriginalC0 = desc.C0; OriginalC1 = desc.C1; BladePart = p1; HubPart = p0});
				elseif isP0Blade then
					table.insert(bladeData, {Motor = desc; OriginalC0 = desc.C0; OriginalC1 = desc.C1; BladePart = p0; HubPart = p1});
				end
			end
		end
	end

	if #bladeData == 0 then
		cout:Message("No Motors found. Running Auto-Rigger using 'Hub' & 'Hub1' Attachments...");

		local hubPart: BasePart? = nil;
		local torque = findMainRotor(heliModel);
		if torque then hubPart = torque.Parent :: BasePart; end
		if not hubPart then hubPart = rotorModel:FindFirstChild("Hub", true) :: BasePart; end

		local blades = {};
		for _, desc in ipairs(rotorModel:GetDescendants()) do
			if desc:IsA("BasePart") and desc.Name:lower():find("blade") then
				table.insert(blades, desc);
			end
		end

		if hubPart then
			for _, blade in ipairs(blades) do
				local bladeAtt = blade:FindFirstChild("Hub1") or blade:FindFirstChild("Hub");

				if bladeAtt and bladeAtt:IsA("Attachment") then
					cout:Message(">> Auto-Rigging Blade: " .. blade.Name);

					for _, w in ipairs(blade:GetChildren()) do
						if (w:IsA("Weld") or w:IsA("WeldConstraint") or w:IsA("ManualWeld")) then w:Destroy(); end
					end
					
					local currentHub = hubPart :: BasePart;
					for _, w in ipairs(currentHub:GetChildren()) do
						if (w:IsA("Weld") or w:IsA("WeldConstraint") or w:IsA("ManualWeld")) and (w.Part1 == blade or w.Part0 == blade) then
							w:Destroy();
						end
					end

					local motor = Instance.new("Motor6D");
					motor.Name = "AutoRig_Motor";
					motor.Part0 = currentHub;
					motor.Part1 = blade;

					motor.C1 = bladeAtt.CFrame;
					motor.C0 = currentHub.CFrame:Inverse() * blade.CFrame * motor.C1;

					motor.Parent = currentHub;

					table.insert(bladeData, {
						Motor = motor;
						OriginalC0 = motor.C0;
						OriginalC1 = motor.C1;
						BladePart = blade;
						HubPart = currentHub;
					});
				end
			end
		end
	end

	return bladeData;
end;

local function setServoTarget(constraint:Constraint?, value:number)
	if not constraint then return; end

	if constraint:IsA("CylindricalConstraint") then
		(constraint :: CylindricalConstraint).TargetPosition = value;
	end
end;

local function getHelicopterRoot(descendant:Instance):Model?
	local current = descendant;
	while current and current ~= game do
		if cs:HasTag(current, tag) and current:IsA("Model") then
			return (current :: Model);
		end
		current = current.Parent;
	end
	return nil;
end;

local function init(seat:Seat|VehicleSeat, occupant:Humanoid, role:string)
	local current_input = table.clone(input_template);

	local model = getHelicopterRoot(seat);
	if not model then return; end;

	local rootPart = model.PrimaryPart 
		or model:FindFirstChild("Main") 
		or model:FindFirstChild("Chassis") 
		or model:FindFirstChild("Fuselage")
		or model:FindFirstChild("Body");

	if not rootPart then
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				rootPart = p;
				break;
			end
		end
		if rootPart then warn("Warning: No PrimaryPart found. Using " .. rootPart.Name .. " as reference."); end
	end

	if not rootPart then
		warn("CRITICAL ERROR: Helicopter has no BaseParts to calculate physics against!");
		return;
	end
	
	local physicsRoot = rootPart :: BasePart;

	local mainRotorForce = physicsRoot:FindFirstChild("MainRotorForce");
	if not mainRotorForce or not mainRotorForce:IsA("VectorForce") then
		mainRotorForce = Instance.new("VectorForce");
		mainRotorForce.Name = "MainRotorForce";
		mainRotorForce.ApplyAtCenterOfMass = true;
		mainRotorForce.Attachment0 = Instance.new("Attachment");
		mainRotorForce.Attachment0.Parent = physicsRoot;
		mainRotorForce.Parent = physicsRoot;
		mainRotorForce.RelativeTo = Enum.ActuatorRelativeTo.World; 
		mainRotorForce.Force = Vector3.zero;
	end
	
	local mainForce = mainRotorForce :: VectorForce;
	mainForce.RelativeTo = Enum.ActuatorRelativeTo.World;

	local hydF = findHydraulicServo(model, "hydraulicF");
	local hydB = findHydraulicServo(model, "hydraulicB");
	local hydL = findHydraulicServo(model, "hydraulicL");
	local hydR = findHydraulicServo(model, "hydraulicR");

	local mainRotor = findMainRotor(model);
	local tailRotor = findTailRotor(model);

	local tailPart = nil;
	if tailRotor then
		tailPart = tailRotor.Parent :: BasePart;
	else
		tailPart = model:FindFirstChild("TailRotor", true) :: BasePart;
	end

	local yawForce = nil;
	
	if tailPart then
		local existingAtt = tailPart:FindFirstChild("YawAttachment");
		if not existingAtt then
			existingAtt = Instance.new("Attachment");
			existingAtt.Name = "YawAttachment";
			existingAtt.Parent = tailPart;
		end
		
		yawForce = tailPart:FindFirstChild("YawForce");
		if not yawForce then
			yawForce = Instance.new("VectorForce");
			yawForce.Name = "YawForce";
			yawForce.Attachment0 = existingAtt :: Attachment;
			yawForce.RelativeTo = Enum.ActuatorRelativeTo.Attachment0;
			yawForce.Parent = tailPart;
		end
	else
		cout:Message("!! NO TAIL ROTOR PART FOUND. YAW WILL NOT WORK !!");
	end

	local tailBladeHinges = findTailBladeHinges(model);
	local mainBlades = findBladeMotors(model);

	cout:Message("------------------------------------------------");
	cout:Message("HELICOPTER INIT: " .. model.Name);
	cout:Message("Root Ref: " .. physicsRoot.Name);
	cout:Message("Blades Articulated: " .. #mainBlades);
	cout:Message("------------------------------------------------");

	local connection = Client_Information.OnServerEvent:Connect(function(player: Player, inputData: InputPacket)
		if player.Character == occupant.Parent and type(inputData) == "table" then
			current_input.Vertical = inputData.Vertical or 0;
			current_input.Yaw = inputData.Yaw or 0;
			current_input.Weapon = inputData.Weapon or 0;
			current_input.Weapon1 = inputData.Weapon1 or 0;
			current_input.Brake = inputData.Brake or 0;

			if inputData.Longitudinal then current_input.Longitudinal = inputData.Longitudinal; end
			if inputData.Lateral then current_input.Lateral = inputData.Lateral; end
		end
	end);

	local smooth_vert, smooth_long, smooth_lat = 0, 0, 0;
	local engine_torque = BASE_TORQUE;
	local engine_latched = false;

	task.spawn(function() 
		repeat
			local now = os.clock();
			local start_dt = os.clock() - now;
			local dt = task.wait(start_dt);

			if seat.Occupant ~= occupant then 
				connection:Disconnect();
				if yawForce then (yawForce :: VectorForce).Force = Vector3.zero; end
				if mainForce then mainForce.Force = Vector3.zero; end
				for _, bData in ipairs(mainBlades) do
					bData.Motor.C0 = bData.OriginalC0;
				end
				break;
			end

			local valF, valB, valL, valR = 0, 0, 0, 0;
			local rotorPart = nil;
			if mainRotor then
				rotorPart = mainRotor.Parent :: BasePart;
			end

			if role == "Pilot" then
				smooth_vert = lerp(smooth_vert, current_input.Vertical, dt * 5.0);
				smooth_long = lerp(smooth_long, current_input.Longitudinal, dt * 5.0);
				smooth_lat = lerp(smooth_lat, current_input.Lateral, dt * 5.0);

				local rotorSpeed = 0;
				
				if rotorPart then
					rotorSpeed = rotorPart.AssemblyAngularVelocity.X or 0;
				end

				local rpmAlpha = math.clamp(math.abs(rotorSpeed) / ROTOR_MAX_SPEED, 0, 1);

				if math.abs(current_input.Vertical) > 0.1 then
					engine_latched = true;
				end

				if current_input.Brake > 0 then
					engine_latched = false;
				end

				local targetTorque = engine_latched and MAX_TORQUE or BASE_TORQUE;

				local torqueRate = torqueAccel * dt;

				if targetTorque > engine_torque then
					engine_torque = math.min(engine_torque + torqueRate, targetTorque);
				elseif targetTorque < engine_torque then
					engine_torque = math.max(engine_torque - torqueRate, BASE_TORQUE);
				end

				if mainRotor then
					local frictionVector = Vector3.new(rotorSpeed, 0, 0) * -1 * ROTATIONAL_FRICTION * dt;
					mainRotor.Torque = Vector3.new(engine_torque, 0, 0) + frictionVector;
					if mainRotor.Torque.X < BASE_TORQUE then mainRotor.Torque = Vector3.new(BASE_TORQUE,0,0); end
				end

				if mainForce then
					local collectiveAlpha = (engine_torque - BASE_TORQUE) / (MAX_TORQUE - BASE_TORQUE);
					collectiveAlpha = math.clamp(collectiveAlpha, 0, 1);

					local liftForce = collectiveAlpha * MAX_LIFT_FORCE * rpmAlpha;

					local tilt_long = smooth_long * MAX_CYCLIC_PITCH * rpmAlpha;
					local tilt_lat = smooth_lat * MAX_CYCLIC_PITCH * rpmAlpha;

					local thrustTilt = CFrame.Angles(-tilt_lat, 0, -tilt_long);

					local totalThrustDirection = (physicsRoot.CFrame * thrustTilt * CFrame.fromAxisAngle(Vector3.new(0,0,1), -MAST_TILT_TRIM)).UpVector;

					local mainRotorForceVector = totalThrustDirection * liftForce;

					local worldVelocity = physicsRoot.AssemblyLinearVelocity;
					local localVelocity = physicsRoot.CFrame:VectorToObjectSpace(worldVelocity);

					local dragForceLocal = Vector3.new(
						-localVelocity.X * math.abs(localVelocity.X) * FUSELAGE_DRAG.X,
						-localVelocity.Y * math.abs(localVelocity.Y) * FUSELAGE_DRAG.Y,
						-localVelocity.Z * math.abs(localVelocity.Z) * FUSELAGE_DRAG.Z
					);

					local dragForceWorld = physicsRoot.CFrame:VectorToWorldSpace(dragForceLocal);

					mainForce.Force = mainRotorForceVector + dragForceWorld;
				end

				if tailRotor then
					local tail_spin_torque = math.clamp(engine_torque * 0.15, 0, MAX_TAIL_TORQUE);
					tailRotor.Torque = Vector3.new(tail_spin_torque, 0, 0);
				end

				if yawForce then
					local yawInput = current_input.Yaw;
					local appliedForce = -yawInput * MAX_TAIL_VECTOR_FORCE;
					(yawForce :: VectorForce).Force = Vector3.new(appliedForce, 0, 0);
				end
				
				local target_pitch = math.rad(current_input.Yaw * MAX_TAIL_PITCH);
				for _, hinge in ipairs(tailBladeHinges) do
					hinge.TargetAngle = target_pitch;
				end

				valF = (-smooth_long * deflection) - (smooth_vert * 2);
				valB = (smooth_long * deflection) - (smooth_vert * 2);
				valL = (smooth_lat * deflection) + (smooth_vert * 2);
				valR = (-smooth_lat * deflection) + (smooth_vert * 2);

				setServoTarget(hydF, valF);
				setServoTarget(hydB, valB);
				setServoTarget(hydL, valL);
				setServoTarget(hydR, valR);

				local lastBladePitch = 0;
				local lastBladeFlap = 0;

				if physicsRoot and #mainBlades > 0 then
					local torqueAlpha = math.clamp((engine_torque - BASE_TORQUE) / (MAX_TORQUE - BASE_TORQUE), 0, 1);
					local leadLagAngle = -torqueAlpha * MAX_LEAD_LAG;

					for _, bData in ipairs(mainBlades) do
						local hubRelCF = physicsRoot.CFrame:ToObjectSpace(bData.HubPart.CFrame);
						local bladeRestCF = hubRelCF * bData.OriginalC0 * bData.OriginalC1:Inverse();

						local azimuth;
						local posVec = bladeRestCF.Position;

						if posVec.Magnitude > 0.1 then
							azimuth = math.atan2(posVec.X, -posVec.Z);
						else
							local dirVec = bladeRestCF.LookVector;
							azimuth = math.atan2(dirVec.X, -dirVec.Z);
						end

						local cyclicPitchInput = 
							(-smooth_long * math.cos(azimuth + PHASE_OFFSET)) + 
							(-smooth_lat * math.sin(azimuth + PHASE_OFFSET));

						local cyclicPitch = cyclicPitchInput * MAX_CYCLIC_PITCH * torqueAlpha;

						local liftConing = math.clamp(smooth_vert, 0, 1) * MAX_FLAP_ANGLE * torqueAlpha;

						local staticDroop = MAX_DROOP * (1 - torqueAlpha);

						local cyclicFlapInput = (-smooth_long * math.sin(azimuth) - smooth_lat * math.cos(azimuth));
						local cyclicFlap = cyclicFlapInput * (MAX_FLAP_ANGLE * 2.0) * torqueAlpha;

						local trimFlap = MAST_TILT_TRIM * math.cos(azimuth) * torqueAlpha;

						local totalFlap = (liftConing - staticDroop) + cyclicFlap + trimFlap;

						local animationCF = CFrame.Angles(totalFlap, leadLagAngle, cyclicPitch);

						bData.Motor.C0 = bData.OriginalC0 * animationCF;

						lastBladePitch = math.deg(cyclicPitch);
						lastBladeFlap = math.deg(totalFlap);
					end
				end

				cout:Message(string.format("Tq:%.0f | RPM: %.0f | Cyc: %.0f°/%.0f° | In: %.1f/%.1f", engine_torque, math.abs(rotorSpeed), lastBladePitch, lastBladeFlap, smooth_long, smooth_lat));

			elseif role == "CoPilot" then
				if current_input.Weapon > 0 then cout:Message("CoPilot Firing Weapon 1"); end
				if current_input.Weapon1 > 0 then cout:Message("CoPilot Firing Weapon 2"); end
			end

		until (false);
	end);
end;

local function bind(seat:Instance)
	if not (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then return; end

	local role = nil;
	if seat.Name == "PilotSeat" then
		role = "Pilot";
	elseif seat.Name == "CoPilotSeat" then
		role = "CoPilot";
	end;

	if role then
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant;
			if occupant and occupant:IsA("Humanoid") then
				init(seat, occupant, role :: string);
			end
		end);
	end
end;

for _, heli in ipairs(cs:GetTagged(tag)) do
	for _, desc in ipairs(heli:GetDescendants()) do
		bind(desc);
	end
	heli.DescendantAdded:Connect(bind);
end

cs:GetInstanceAddedSignal(tag):Connect(function(heli)
	for _, desc in ipairs(heli:GetDescendants()) do
		bind(desc);
		heli.DescendantAdded:Connect(bind);
	end
end);

return engine;
