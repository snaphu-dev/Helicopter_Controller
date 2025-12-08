local packet = {}

export type inputVals = {
    
    --throttle
    Up:number;-- 1;
    Down:number; -- -1;

    --hover
    Left:number; -- -1;
    Right:number; -- 1;
    Forward:number; -- 1;
    Backward:number; -- -1;

    --hydraulics
    left_arrow:number; -- -1;
    right_arrow:number; -- 1;
    up_arrow:number; -- 1;
    down_arrow:number; -- -1;

};

type bladeData = {
    Motor: Motor6D;
    OriginalC0: CFrame;
    OriginalC1: CFrame;
    BladePart: BasePart;
    HubPart: BasePart;
};

return packet;
