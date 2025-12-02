--!strict
local cs = game:GetService("CollectionService");
local Players = game:GetService("Players");
local player = Players.LocalPlayer;

local Parse = require(script.Parent:WaitForChild("InputParser"));

local tag = "helicopter_chassis";

local function setupHeli(heli: Model)
    
    local seat = heli:FindFirstChildWhichIsA("VehicleSeat", true);
    if not seat then return; end

    seat:GetPropertyChangedSignal("Occupant"):Connect(function()
        local humanoid = seat.Occupant;
        if humanoid and humanoid.Parent == player.Character then

            local myInputs = {
                Longitudinal = 0; Lateral = 0; Vertical = 0;
                Yaw = 0; Weapon = 0; Weapon1 = 0;
            };

            Parse.bind(seat, myInputs);
        end
    end);
end;

for _, heli in ipairs(cs:GetTagged(tag)) do
    setupHeli(heli::Model);
end

cs:GetInstanceAddedSignal(tag):Connect(setupHeli);

return 0;
