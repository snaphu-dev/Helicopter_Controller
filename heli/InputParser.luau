--!strict
local Parse = {};

local cas = game:GetService("ContextActionService");
local rs = game:GetService("ReplicatedStorage");
local cout = game:GetService("TestService");

local HeliNet = rs:WaitForChild("HeliNet");
local Client_Information = HeliNet:WaitForChild("Client_Information");

local ACTION_LIFT = "HeliLift";      -- F / V
local ACTION_YAW = "HeliYaw";        -- E / Q
local ACTION_PITCH = "HeliPitch";    -- W / S
local ACTION_ROLL = "HeliRoll";      -- A / D

local ACTION_HYD_Y = "HeliHydY";     -- P / ; (Forward/Backward)
local ACTION_HYD_X = "HeliHydX";     -- L / ' (Left/Right)

local ACTION_FIRE_1 = "HeliFire1";
local ACTION_FIRE_2 = "HeliFire2";

type NetworkPacket = {
    Longitudinal: number;
    Lateral: number;
    Vertical: number;
    Yaw: number;
    HydraulicX: number;
    HydraulicY: number;
    Weapon: number;
    Weapon1: number;
    Brake: number;
};

type InputClass = {
    Longitudinal: number;
    Lateral: number;
    Vertical: number;
    Yaw: number;
    HydraulicX: number;
    HydraulicY: number;
    Weapon: number;
    Weapon1: number;
    Brake: number;
    [any]: any;
};

local inputState = {
    Pitch = 0;
    Roll = 0;
    Vertical = 0;
    Yaw = 0;
    HydX = 0;
    HydY = 0;
    Fire1 = 0;
    Fire2 = 0;
};

local function handleInput(actionName: string, inputStateEnum: Enum.UserInputState, inputObject: InputObject)
    local isBegin = (inputStateEnum == Enum.UserInputState.Begin);
    local isEnd = (inputStateEnum == Enum.UserInputState.End);
    local value = isBegin and 1 or 0;

    if actionName == ACTION_PITCH then
        local sign = (inputObject.KeyCode == Enum.KeyCode.W) and 1 or -1;
        if isBegin then inputState.Pitch = sign;
        elseif isEnd and inputState.Pitch == sign then inputState.Pitch = 0; end
        return Enum.ContextActionResult.Sink;

    elseif actionName == ACTION_ROLL then
        local sign = (inputObject.KeyCode == Enum.KeyCode.D) and 1 or -1;
        if isBegin then inputState.Roll = sign;
        elseif isEnd and inputState.Roll == sign then inputState.Roll = 0; end
        return Enum.ContextActionResult.Sink;

    elseif actionName == ACTION_LIFT then
        local sign = (inputObject.KeyCode == Enum.KeyCode.F or inputObject.KeyCode == Enum.KeyCode.ButtonY) and 1 or -1;
        if isBegin then inputState.Vertical = sign;
        elseif isEnd and inputState.Vertical == sign then inputState.Vertical = 0; end
        return Enum.ContextActionResult.Sink;

    elseif actionName == ACTION_YAW then
        local sign = (inputObject.KeyCode == Enum.KeyCode.E or inputObject.KeyCode == Enum.KeyCode.ButtonR1) and 1 or -1;
        if isBegin then inputState.Yaw = sign;
        elseif isEnd and inputState.Yaw == sign then inputState.Yaw = 0; end
        return Enum.ContextActionResult.Sink;

    elseif actionName == ACTION_HYD_Y then
        local sign = (inputObject.KeyCode == Enum.KeyCode.P) and 1 or -1;

        if isBegin then 
            inputState.HydY = sign;
        elseif isEnd and inputState.HydY == sign then 
            inputState.HydY = 0; 
        end
        return Enum.ContextActionResult.Sink;

    elseif actionName == ACTION_HYD_X then
        local sign = (inputObject.KeyCode == Enum.KeyCode.Quote) and 1 or -1;

        if isBegin then 
            inputState.HydX = sign;
        elseif isEnd and inputState.HydX == sign then 
            inputState.HydX = 0; 
        end
        return Enum.ContextActionResult.Sink;

    elseif actionName == ACTION_FIRE_1 then
        inputState.Fire1 = value;
    elseif actionName == ACTION_FIRE_2 then
        inputState.Fire2 = value;
    end

    return Enum.ContextActionResult.Pass;
end;

function Parse.bind(seat: VehicleSeat | Seat, input_object: InputClass)
    cout:Message("Binding controls for seat: " .. seat.Name);

    if not seat:IsA("VehicleSeat") then return; end
    local currentOccupant = seat.Occupant;

    cas:BindActionAtPriority(ACTION_PITCH, handleInput, false, 2000, Enum.KeyCode.W, Enum.KeyCode.S);
    cas:BindActionAtPriority(ACTION_ROLL, handleInput, false, 2000, Enum.KeyCode.A, Enum.KeyCode.D);
    cas:BindActionAtPriority(ACTION_LIFT, handleInput, false, 2000, Enum.KeyCode.F, Enum.KeyCode.V, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonB);
    cas:BindActionAtPriority(ACTION_YAW, handleInput, false, 2000, Enum.KeyCode.E, Enum.KeyCode.Q, Enum.KeyCode.ButtonR1, Enum.KeyCode.ButtonL1);

    cas:BindActionAtPriority(ACTION_HYD_Y, handleInput, false, 2000, Enum.KeyCode.P, Enum.KeyCode.Semicolon);

    cas:BindActionAtPriority(ACTION_HYD_X, handleInput, false, 2000, Enum.KeyCode.L, Enum.KeyCode.Quote);

    cas:BindAction(ACTION_FIRE_1, handleInput, false, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2);
    cas:BindAction(ACTION_FIRE_2, handleInput, false, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2);

    task.spawn(function()
        repeat
            local dt = task.wait();

            if seat.Occupant ~= currentOccupant then 
                cas:UnbindAction(ACTION_PITCH);
                cas:UnbindAction(ACTION_ROLL);
                cas:UnbindAction(ACTION_LIFT);
                cas:UnbindAction(ACTION_YAW);
                cas:UnbindAction(ACTION_HYD_X);
                cas:UnbindAction(ACTION_HYD_Y);
                cas:UnbindAction(ACTION_FIRE_1);
                cas:UnbindAction(ACTION_FIRE_2);

                for k,v in pairs(inputState) do inputState[k] = 0 end;
                break; 
            end

            input_object.Lateral = inputState.Roll;
            input_object.Longitudinal = inputState.Pitch;
            input_object.Vertical = inputState.Vertical;
            input_object.Yaw = inputState.Yaw;
            input_object.HydraulicX = inputState.HydX;
            input_object.HydraulicY = inputState.HydY;
            input_object.Weapon = inputState.Fire1;
            input_object.Weapon1 = inputState.Fire2;
            input_object.Brake = 0; 

            local packet: NetworkPacket = {
                Lateral = inputState.Roll;
                Longitudinal = inputState.Pitch;
                Vertical = inputState.Vertical;
                Yaw = inputState.Yaw;
                HydraulicX = inputState.HydX;
                HydraulicY = inputState.HydY;
                Weapon = inputState.Fire1;
                Weapon1 = inputState.Fire2;
                Brake = 0;
            };

            Client_Information:FireServer(packet);

        until (false);
    end);
end;

return Parse;
