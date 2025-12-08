local engine = {}

local torque_Accel = 0.5;
local max_Torque = 3000000;
local tail_Torque = 18000;
local tail_VForce = 9250;
local base_Torque = 100;
local max_tailPitch = 35;

local max_liftForce = 9000;
local rotor_maxSpeed = 100;
local rotational_Friction = 100000;
local fuselage_drag = Vector3.new(25, 45, 2.5); 

local max_cyclicPitch = math.rad(35);
local max_flapAngle = math.rad(1.725);
local max_leadLag = math.rad(1.5);
local phase_offset = math.pi / 2;
local mast_tiltTrim = math.rad(1.725);

require(script.Parent:FindFirstChild("Packet"));

type InputVals = Packet.inputVals;
type BladeData = Packet.bladeData;

local input_state:InputVals = {
    Longitudinal = 0;
    Lateral = 0;
    Vertical = 0;
    Yaw = 0;
    HydraulicX = 0;
    HydraulicY = 0;
    Weapon = 0;
    Weapon1 = 0;
    Brake = 0;
};

local initBlade:BladeData = {};

local rs = game:GetService("ReplicatedStorage");
local cout = game:GetService("TestService");
local cs = game:GetService("CollectionService");

local HeliNet = rs:WaitForChild("HeliNet");
local Client_Information = HeliNet:WaitForChild("Client_Information");

local tag = "helicopter_chassis";

local function findHydraulicServo(model:Instance, partName:string):CylindricalConstraint?
    local part = model:FindFirstChild(partName, true);
    if part then return part:FindFirstChildWhichIsA("CylindricalConstraint"); end
    return nil;
end;

local function findMainRotor(model:Instance): Torque?
    local part = model:FindFirstChild("Rotor1", true);
    if part then return part:FindFirstChildWhichIsA("Torque"); end
    return nil;
end;

local function findTailRotor(model:Instance): Torque?
    local part = model:FindFirstChild("TailRotor", true);
    if part then return part:FindFirstChildWhichIsA("Torque"); end
    return nil;
end;

local function findBladeMotors(heliModel:Instance): {BladeData}
    local bladeData = {};
    local rotorModel = heliModel:FindFirstChild("Rotor1", true);

    if not rotorModel then return bladeData; end

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
        if cs:HasTag(current, tag) and current:IsA("Model") then return (current :: Model); end
        current = current.Parent;
    end
    return nil;
end;

local function init(seat:Seat|VehicleSeat, occupant:Humanoid, role:string)
    local current_input = table.clone(input_state);
    local model = getHelicopterRoot(seat);
    if not model then return; end;

    local rootPart = model.PrimaryPart or model:FindFirstChild("Main");
    if not rootPart then return; end
    local physicsRoot = rootPart :: BasePart;

    local mainRotorForce = physicsRoot:FindFirstChild("MainRotorForce");
    if not mainRotorForce or not mainRotorForce:IsA("VectorForce") then
        mainRotorForce = Instance.new("VectorForce", physicsRoot);
        mainRotorForce.Name = "MainRotorForce";
        mainRotorForce.ApplyAtCenterOfMass = true;
        mainRotorForce.RelativeTo = Enum.ActuatorRelativeTo.World; 
    end
    local mainForce = mainRotorForce :: VectorForce;

    local hydF = findHydraulicServo(model, "hydraulicF");
    local hydB = findHydraulicServo(model, "hydraulicB");
    local hydL = findHydraulicServo(model, "hydraulicL");
    local hydR = findHydraulicServo(model, "hydraulicR");

    local mainRotor = findMainRotor(model);
    local tailRotor = findTailRotor(model);
    local mainBlades = findBladeMotors(model);

    local yawForce = nil;
    local tailPart = model:FindFirstChild("TailRotor", true);
    if tailPart and tailPart:IsA("BasePart") then
        yawForce = tailPart:FindFirstChild("YawForce");
        if not yawForce then
            local att = tailPart:FindFirstChild("YawAttachment") or Instance.new("Attachment", tailPart);
            att.Name = "YawAttachment";
            yawForce = Instance.new("VectorForce", tailPart);
            yawForce.Name = "YawForce";
            (yawForce :: VectorForce).Attachment0 = (att :: Attachment);
            (yawForce :: VectorForce).RelativeTo = Enum.ActuatorRelativeTo.Attachment0;
        end
    end

    local connection = Client_Information.OnServerEvent:Connect(function(player: Player, inputData: InputPacket)
        if player.Character == occupant.Parent and type(inputData) == "table" then
            current_input.Vertical = inputData.Vertical or 0;
            current_input.Yaw = inputData.Yaw or 0;
            current_input.Longitudinal = inputData.Longitudinal or 0;
            current_input.Lateral = inputData.Lateral or 0;
            current_input.HydraulicX = inputData.HydraulicX or 0;
            current_input.HydraulicY = inputData.HydraulicY or 0;
        end
    end);

    local smooth_long, smooth_lat = 0, 0;
    local requestedThrottle = 0; 
    local engine_torque = base_Torque;

    task.spawn(function() 
        repeat
            local dt = task.wait();
            if seat.Occupant ~= occupant then 
                connection:Disconnect();
                if mainForce then mainForce.Force = Vector3.zero; end
                if mainRotor then mainRotor.Torque = Vector3.zero; end
                break;
            end

            local rotorSpeed = 0;
            if mainRotor and mainRotor.Parent and mainRotor.Parent:IsA("BasePart") then
                rotorSpeed = mainRotor.Parent.AssemblyAngularVelocity.X;
            end
            local rpmAlpha = math.clamp(math.abs(rotorSpeed) / rotor_maxSpeed, 0, 1);

            if role == "Pilot" then
                smooth_long = math.lerp(smooth_long, current_input.Longitudinal, dt * 5.0);
                smooth_lat = math.lerp(smooth_lat, current_input.Lateral, dt * 5.0);

                local total_long = smooth_long + current_input.HydraulicY;
                local total_lat = smooth_lat + current_input.HydraulicX;

                if current_input.Vertical > 0.1 then requestedThrottle = math.min(requestedThrottle + (torque_Accel * dt), 1);
                elseif current_input.Vertical < -0.1 then requestedThrottle = math.max(requestedThrottle - (torque_Accel * dt), 0); end

                local targetTorque = base_Torque + (requestedThrottle * (max_Torque - base_Torque));
                engine_torque = math.lerp(engine_torque, targetTorque, dt * 2); 

                if mainRotor then
                    local friction = Vector3.new(rotorSpeed, 0, 0) * -1 * rotational_Friction * dt;
                    mainRotor.Torque = Vector3.new(engine_torque, 0, 0) + friction;
                end

                if mainForce then
                    local liftForce = requestedThrottle * max_liftForce * rpmAlpha;

                    local tilt_long = total_long * max_cyclicPitch * rpmAlpha;
                    local tilt_lat = total_lat * max_cyclicPitch * rpmAlpha;

                    local thrustTilt = CFrame.Angles(-tilt_lat, 0, -tilt_long);
                    local totalThrustDirection = (physicsRoot.CFrame * thrustTilt * CFrame.fromAxisAngle(Vector3.new(0,0,1), -mast_tiltTrim)).UpVector;

                    local localVel = physicsRoot.CFrame:VectorToObjectSpace(physicsRoot.AssemblyLinearVelocity);
                    local drag = Vector3.new(-localVel.X*math.abs(localVel.X)*fuselage_drag.X, -localVel.Y*math.abs(localVel.Y)*fuselage_drag.Y, -localVel.Z*math.abs(localVel.Z)*fuselage_drag.Z);
                    mainForce.Force = (totalThrustDirection * liftForce) + physicsRoot.CFrame:VectorToWorldSpace(drag);
                end

                if tailRotor then tailRotor.Torque = Vector3.new(math.clamp(engine_torque * 0.15, 0, tail_Torque), 0, 0); end
                if yawForce then (yawForce :: VectorForce).Force = Vector3.new(-current_input.Yaw * tail_VForce, 0, 0); end

                local manual_x = -current_input.HydraulicX * 5;
                local manual_y = -current_input.HydraulicY * 5;

                setServoTarget(hydF, -manual_y); setServoTarget(hydB, manual_y);
                setServoTarget(hydL, -manual_x); setServoTarget(hydR, manual_x);

                if physicsRoot and #mainBlades > 0 then
                    local leadLagAngle = -requestedThrottle * max_leadLag;
                    for _, bData in ipairs(mainBlades) do
                        local hubRelCF = physicsRoot.CFrame:ToObjectSpace(bData.HubPart.CFrame);
                        local bladeRestCF = hubRelCF * bData.OriginalC0 * bData.OriginalC1:Inverse();
                        local azimuth = math.atan2(bladeRestCF.LookVector.X, -bladeRestCF.LookVector.Z);

                        local cyclicPitch = ((-total_long * math.cos(azimuth + phase_offset)) + (-total_lat * math.sin(azimuth + phase_offset))) * max_cyclicPitch;
                        local totalFlap = (requestedThrottle * max_flapAngle) + ((-total_long * math.sin(azimuth) - total_lat * math.cos(azimuth)) * max_flapAngle);

                        bData.Motor.C0 = bData.OriginalC0 * CFrame.Angles(totalFlap, leadLagAngle, cyclicPitch);
                    end
                end

                cout:Message(string.format("Thr: %.1f%% | HydL: %.1f | HydT: %.1f", requestedThrottle*100, total_long, total_lat));
            end
        until (false);
    end);
end;

local function bind(seat:Instance)
    if not (seat:IsA("Seat") or seat:IsA("VehicleSeat")) then return; end 
    local role = nil;
    if seat.Name == "PilotSeat" then role = "Pilot";
    elseif seat.Name == "CoPilotSeat" then role = "CoPilot"; end;
    if role then
        seat:GetPropertyChangedSignal("Occupant"):Connect(function()
            local occupant = seat.Occupant;
            if occupant and occupant:IsA("Humanoid") then init(seat, occupant, role :: string); end
        end);
    end
end;

for _, heli in ipairs(cs:GetTagged(tag)) do
    for _, desc in ipairs(heli:GetDescendants()) do bind(desc); end
    heli.DescendantAdded:Connect(bind);
end
cs:GetInstanceAddedSignal(tag):Connect(function(heli)
    for _, desc in ipairs(heli:GetDescendants()) do bind(desc); end
    heli.DescendantAdded:Connect(bind);
end);

return engine;
