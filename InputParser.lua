--!strict
local Parse = {};

local cas = game:GetService("ContextActionService");
local rs = game:GetService("ReplicatedStorage");
local cout = game:GetService("TestService");

local HeliNet = rs:WaitForChild("HeliNet");
local Client_Information = HeliNet:WaitForChild("Client_Information");

local ACTION_LIFT = "HeliLift";
local ACTION_YAW = "HeliYaw";
local ACTION_FIRE_1 = "HeliFire1";
local ACTION_FIRE_2 = "HeliFire2";

type NetworkPacket = {
    Longitudinal: number;
    Lateral: number;
    Vertical: number;
    Yaw: number;
    Weapon: number;
    Weapon1: number;
};

type InputClass = {
    Longitudinal: number;
    Lateral: number;
    Vertical: number;
    Yaw: number;
    Weapon: number;
    Weapon1: number;
    [any]: any;
};

local inputState = {
    Vertical = 0;
    Yaw = 0;
    Fire1 = 0;
    Fire2 = 0;
};

local function handleInput(actionName: string, inputStateEnum: Enum.UserInputState, inputObject: InputObject)
    local value = (inputStateEnum == Enum.UserInputState.Begin) and 1 or 0;

    local sign = 1;
    if inputObject.KeyCode == Enum.KeyCode.V or inputObject.KeyCode == Enum.KeyCode.ButtonB or 
        inputObject.KeyCode == Enum.KeyCode.Q or inputObject.KeyCode == Enum.KeyCode.ButtonL1 then
        sign = -1;
    end

    if actionName == ACTION_LIFT then
        if inputStateEnum == Enum.UserInputState.Begin then
            inputState.Vertical = sign;
        elseif inputStateEnum == Enum.UserInputState.End then
            if inputState.Vertical == sign then inputState.Vertical = 0; end
        end
        return Enum.ContextActionResult.Sink;

    elseif actionName == ACTION_YAW then
        if inputStateEnum == Enum.UserInputState.Begin then
            inputState.Yaw = sign;
        elseif inputStateEnum == Enum.UserInputState.End then
            if inputState.Yaw == sign then inputState.Yaw = 0; end
        end

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

    cas:BindActionAtPriority(ACTION_LIFT, handleInput, false, 2000, 
        Enum.KeyCode.F, Enum.KeyCode.V, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonB);

    cas:BindActionAtPriority(ACTION_YAW, handleInput, false, 2000, 
        Enum.KeyCode.E, Enum.KeyCode.Q, Enum.KeyCode.ButtonR1, Enum.KeyCode.ButtonL1);

    cas:BindAction(ACTION_FIRE_1, handleInput, false, 
        Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2);
    cas:BindAction(ACTION_FIRE_2, handleInput, false, 
        Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2);

    task.spawn(function()
        repeat
            local dt = task.wait();

            if seat.Occupant ~= currentOccupant then 
                cas:UnbindAction(ACTION_LIFT);
                cas:UnbindAction(ACTION_YAW);
                cas:UnbindAction(ACTION_FIRE_1);
                cas:UnbindAction(ACTION_FIRE_2);

                inputState.Vertical = 0; inputState.Yaw = 0; inputState.Fire1 = 0; inputState.Fire2 = 0;
                break; 
            end

            input_object.Lateral = seat.SteerFloat;
            input_object.Longitudinal = seat.ThrottleFloat;
            input_object.Vertical = inputState.Vertical;
            input_object.Yaw = inputState.Yaw;
            input_object.Weapon = inputState.Fire1;
            input_object.Weapon1 = inputState.Fire2;

            local packet: NetworkPacket = {
                Lateral = seat.SteerFloat;
                Longitudinal = seat.ThrottleFloat;
                Vertical = inputState.Vertical;
                Yaw = inputState.Yaw;
                Weapon = inputState.Fire1;
                Weapon1 = inputState.Fire2;
            };

            Client_Information:FireServer(packet);

            if inputState.Yaw ~= 0 then
                cout:Message("Client Sending Yaw: " .. tostring(inputState.Yaw));
            end

        until (false);
    end);
end;

return Parse;
