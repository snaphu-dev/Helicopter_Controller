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
local MAX_TORQUE = 50000000;
local MAX_TAIL_TORQUE = 50000; 
local BASE_TORQUE = 100;
local MAX_TAIL_PITCH = 60;

local input_template = {
    Longitudinal = 0;
    Lateral = 0;
    Vertical = 0;
    Yaw = 0;
    Weapon = 0;
    Weapon1 = 0;
};

local function lerp(a:number, b:number, t:number)
    return a + (b - a) * math.clamp(t, 0, 1);
end;

local function findHydraulicServo(model:Instance, partName:string):Constraint?
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

local function setServoTarget(constraint:Constraint?, value:number)
    if not constraint then return; end

    if constraint:IsA("CylindricalConstraint") then
        (constraint ::any).TargetPosition = value; 
    end
end;

local function getHelicopterRoot(descendant:Instance):Model?
    local current = descendant;
    while current and current ~= game do
        if cs:HasTag(current, tag) and current:IsA("Model") then
            return current;
        end
        current = current.Parent;
    end;
    return nil;
end;

local function engineBehavior(seat:Seat|VehicleSeat, occupant:Humanoid, role:string)
    local current_input = table.clone(input_template);

    local model = getHelicopterRoot(seat);
    if not model then return; end;

    local hydF = findHydraulicServo(model, "hydraulicF");
    local hydB = findHydraulicServo(model, "hydraulicB");
    local hydL = findHydraulicServo(model, "hydraulicL");
    local hydR = findHydraulicServo(model, "hydraulicR");

    local mainRotor = findMainRotor(model);
    local tailRotor = findTailRotor(model);

    local tailBladeHinges = findTailBladeHinges(model); 

    if #tailBladeHinges > 0 then
        cout:Message("Found " .. #tailBladeHinges .. " tail blade hinges. Configuring Servos...");
    else
        warn("NO TAIL BLADE HINGES FOUND IN TAILROTOR MODEL");
    end;

    local connection = Client_Information.OnServerEvent:Connect(function(player, inputData)
        if player.Character == occupant.Parent and type(inputData) == "table" then
            current_input.Vertical = inputData.Vertical or 0;
            current_input.Yaw = inputData.Yaw or 0;
            current_input.Weapon = inputData.Weapon or 0;
            current_input.Weapon1 = inputData.Weapon1 or 0;

            if inputData.Longitudinal then current_input.Longitudinal = inputData.Longitudinal; end
            if inputData.Lateral then current_input.Lateral = inputData.Lateral; end
        end
    end);

    local smooth_vert, smooth_long, smooth_lat = 0, 0, 0;
    local engine_torque = BASE_TORQUE; 

    task.spawn(function() 
        repeat
            local now = os.clock();
            local start_dt = os.clock()-now; 
            local dt = task.wait(start_dt); 

            if seat.Occupant ~= occupant then 
                connection:Disconnect();
                break;
            end

            if seat:IsA("VehicleSeat") then
                current_input.Longitudinal = seat.ThrottleFloat;
                current_input.Lateral = seat.SteerFloat;
            end

            local valF, valB, valL, valR = 0, 0, 0, 0;

            if role == "Pilot" then
                smooth_vert = lerp(smooth_vert, current_input.Vertical, dt * 2.0);
                smooth_long = lerp(smooth_long, current_input.Longitudinal, dt * 2.0);
                smooth_lat = lerp(smooth_lat, current_input.Lateral, dt * 2.0);

                if current_input.Vertical ~= 0 then
                    local change = current_input.Vertical * torqueAccel * dt;
                    engine_torque = math.clamp(engine_torque + change, BASE_TORQUE, MAX_TORQUE);
                end
                
                if mainRotor then
                    mainRotor.Torque = Vector3.new(-engine_torque, 0, 0);
                    if mainRotor.Torque == Vector3.zero then mainRotor.Torque = Vector3.new(100,0,0); end
                end

                if tailRotor then
                    local tail_spin_torque = math.clamp(engine_torque * 0.15, 0, MAX_TAIL_TORQUE);
                    tailRotor.Torque = Vector3.new(-tail_spin_torque, 0, 0);
                end

                local target_pitch = current_input.Yaw * MAX_TAIL_PITCH;

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

                cout:Message(string.format("Tq:%.0f | TailPitch: %.2f", engine_torque, target_pitch));

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
                engineBehavior(seat, occupant, role::string);
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
        bind(desc::Instance);
    end
    heli.DescendantAdded:Connect(bind);
end);

return engine;
