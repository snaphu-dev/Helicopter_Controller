--!strict
--!native
local Main = {}

local rs = game:GetService("ReplicatedStorage");
local cs = game:GetService("CollectionService");
local Players = game:GetService("Players");
local cout = game:GetService("TestService");

if not rs:FindFirstChild("HeliNet") then return; end;

local function lockOwnership(model: Instance)
    if not model:IsA("Model") then return; end;

    if not model.PrimaryPart then
        model:GetPropertyChangedSignal("PrimaryPart"):Wait();
    end

    local root = model.PrimaryPart;
    if not root then return; end

    local function getPilotSeat(): VehicleSeat?
        return model:FindFirstChildWhichIsA("VehicleSeat", true);
    end;

    task.spawn(function()
        local active = true;
        local seat = getPilotSeat();

        repeat
            if not model.Parent or not root.Parent then
                active = false;
                break;
            end

            if not seat then seat = getPilotSeat(); end

            local targetPlayer: Player? = nil;

            if seat and seat.Occupant and seat.Occupant.Parent then
                targetPlayer = Players:GetPlayerFromCharacter(seat.Occupant.Parent);
            end

            local success, err = pcall(function()
                local currentOwner = root:GetNetworkOwner();

                if targetPlayer then
                    if currentOwner ~= targetPlayer then
                        root:SetNetworkOwner(targetPlayer);
                    end
                else
                    if currentOwner ~= nil then
                        root:SetNetworkOwner(nil);
                    end
                end
            end);

            task.wait(1);
        until active == false;
    end);
end;

local tag = "helicopter_chassis";

for _, heli in ipairs(cs:GetTagged(tag)) do
    lockOwnership(heli);
end

cs:GetInstanceAddedSignal(tag):Connect(function(heli)
    lockOwnership(heli);
end);

local _ = require(script.Parent:WaitForChild("engine"));

cout:Message("[Server]: Engine Running");

return 0;
