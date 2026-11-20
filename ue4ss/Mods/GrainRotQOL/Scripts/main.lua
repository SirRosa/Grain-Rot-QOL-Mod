-- Grain Rot QOL v0.1.0-preview (Helden UE 5.7 / UE4SS 3.x)
-- Only the authoritative host changes game state. No hotkeys or async loops.
-- All feature gates are independent and errors are contained.
local CFG = {
    FurnitureXP = true, FurnitureXPMult = 2,
    LootGold = true, LootGoldMult = 3, JunkGoldMult = 15, JunkGoldThreshold = 1,
    InfiniteNonFirearmDurability = true,
    ResetFirearmsAtOutpost = true,
    InsuranceOnWipe = true,
    PollSeconds = 0.75, HookSample = 8,
    DataRetrySeconds = 10, InventorySnapshotSeconds = 2,
    DurabilitySweepSeconds = 4, DeliveryRetrySeconds = 4,
    MaxInsuranceItems = 64, MaxDeliveryAttempts = 4,
    OrphanItemSweepSamples = 4, -- inspect loose-but-owned items every fourth snapshot
    SlowPollWarnSeconds = 0.035, -- diagnostic only: measured CPU time
    Verbose = false,
}
local prefix = "[GrainRotQOL] "
local function log(msg) print(prefix .. tostring(msg) .. "\n") end
local function verbose(msg) if CFG.Verbose then log(msg) end end
local function valid(obj)
    if not obj then return false end
    local ok, yes = pcall(function() return obj:IsValid() end)
    return ok and yes == true
end
local function get(obj,key)
    local ok, value = pcall(function() return obj[key] end)
    if ok then return value end
end
local function set(obj,key,value)
    local ok,err=pcall(function() obj[key]=value end)
    return ok,err
end
local function num(x)
    local n = tonumber(x)
    if n and n == n and n < 1e12 and n > -1e12 then return n end
    return nil
end
local function name(obj)
    if not obj then return "?" end
    local ok, result = pcall(function() return obj:GetFullName() end)
    if ok and result then return tostring(result) end
    return tostring(obj)
end
local function asstr(obj)
    if obj == nil then return nil end
    local ok,r = pcall(function() return obj:ToString() end)
    if ok and r then return tostring(r) end
    return tostring(obj)
end
local function unwrap(value)
    if value == nil then return nil end
    local ok, r = pcall(function() return value:get() end)
    if ok then return r end
    return value
end
local function eachArray(arr,fn)
    if not arr then return end
    local ok,length = pcall(function() return #arr end)
    if not ok or type(length)~="number" then return end
    for i=1, math.min(length,256) do
        local good,item=pcall(function() return unwrap(arr[i]) end)
        if good and item then fn(item) end
    end
end
local cache={}
local function find(className)
    if valid(cache[className]) then return cache[className] end
    cache[className]=nil
    local ok,item=pcall(FindFirstOf,className)
    if ok and valid(item) then cache[className]=item; return item end
end
local function all(className)
    local ok,items=pcall(FindAllOf,className)
    if ok and items then return items end
    return {}
end
local function isA(item,className)
    if not valid(item) then return false end
    local ok,yes=pcall(function() return item:IsA("/Script/Helden."..className) end)
    if ok and type(yes)=="boolean" then return yes end
    local cls=get(item,"GetClass")
    if type(cls)=="function" then
        local success,klass=pcall(function() return item:GetClass() end)
        if success then
            for _=1,8 do
                if not valid(klass) then break end
                if name(klass):find(className,1,true) then return true end
                klass = get(klass,"GetSuperStruct") and klass:GetSuperStruct() or nil
            end
        end
    end
    return false
end
local function enum(v)
    if type(v)=="number" then return v end
    if v==nil then return nil end
    local s=tostring(v)
    return tonumber(s) or (s:find("Exploring",1,true) and 2)
        or (s:find("ElevatorRideDown",1,true) and 1)
        or (s:find("EndScreen",1,true) and 3)
        or (s:find("Failed",1,true) and 1)
        or (s:find("None",1,true) and 0)
        or (s:find("Default",1,true) and 0)
        or (s:find("Story",1,true) and 0)
        or (s:find("Expedition",1,true) and 1)
end
local function failed(v)
    local n=enum(v)
    if n then return n%2==1 end
    return tostring(v):find("Failed",1,true)~=nil
end

-- The DataSingleton references the ACTUAL game tables. Modifying row
-- structs changes the source used when rewards/objects are created, not UI.
local patched={}
local patchStats={xp=0,price=0,durability=0}
local function mutateRow(row,key,transform)
    local old=num(get(row,key))
    if old==nil then return false end
    local new=transform(old)
    if old==new then return false end
    local ok=set(row,key,new)
    return ok and num(get(row,key))==new
end
local function goldMultiplier(gold)
    if gold==CFG.JunkGoldThreshold then return CFG.JunkGoldMult end
    return CFG.LootGoldMult
end
local function multiplyGold(money)
    if not money then return false end
    return mutateRow(money,"Gold",function(old)
        if old <= 0 then return old end
        return math.floor(old*goldMultiplier(old)+0.5)
    end)
end
local function eachTableRow(dt, callback)
    if not valid(dt) then return false,"missing table" end
    local count=0
    local function apply(rname,r)
        if r then callback(tostring(rname),r); count=count+1 end
    end
    local ok,err=pcall(function() dt:ForEachRow(function(n,r) apply(n,r) end) end)
    if ok then return true,count end
    -- Fallback for UE4SS builds without ForEachRow; GetRowMap values are
    -- writable UScriptStruct references in compatible builds.
    ok,err=pcall(function()
        local rows=dt:GetRowMap()
        for n,r in pairs(rows) do apply(n,r) end
    end)
    if ok then return true,count end
    -- Some UE4SS builds support GetRowNames+FindRow instead.
    ok,err=pcall(function()
        local names=dt:GetRowNames()
        for _,n in ipairs(names) do apply(n,dt:FindRow(n)) end
    end)
    return ok,ok and count or err
end
local function tableRowType(dt)
    local ok,n=pcall(function() return dt:GetRowStruct():GetName() end)
    return ok and tostring(n) or nil
end
local function applyTable(dt, expected, tag, update)
    if not valid(dt) then return false end
    local kind=tableRowType(dt)
    if kind and not kind:find(expected,1,true) then
        log("SKIP "..tag..": unexpected row type "..kind)
        return false
    end
    local marker=name(dt)
    if patched[tag]==marker then return true end
    local stats={}
    local ok,result=eachTableRow(dt,function(rowname,row)
        local success,err=pcall(update,rowname,row,stats)
        if not success then verbose(tag.."/"..rowname.." error: "..tostring(err)) end
    end)
    if not ok then
        log("WAIT "..tag.." table unavailable on this UE4SS API: "..tostring(result))
        return false
    end
    if result==0 then return false end
    patched[tag]=marker
    log(string.format("%s ready: %d rows; %d changed",tag,result,stats.changed or 0))
    return true
end
local function getData()
    local obj=find("HeldenDataSingleton")
    if obj then return obj end
end
local function applyTables()
    local data=getData()
    if not data then log("WAIT: HeldenDataSingleton not loaded");return end
    if CFG.FurnitureXP or CFG.LootGold then
        applyTable(get(data,"ConstructAssetDataTable"),"HeldenConstructAssetData",
          "ConstructAssetData",function(_,row,stat)
            local changed=0
            if CFG.FurnitureXP and mutateRow(row,"XP",function(x) return math.floor(x*CFG.FurnitureXPMult) end) then
                patchStats.xp=patchStats.xp+1;changed=changed+1
            end
            if CFG.LootGold then
                for _,field in ipairs({"Parsed_ScrapValue_Common","Parsed_ScrapValue_Rare","Parsed_ScrapValue_Epic"}) do
                    if multiplyGold(get(row,field)) then patchStats.price=patchStats.price+1;changed=changed+1 end
                end
            end
            stat.changed=(stat.changed or 0)+changed
        end)
        applyTable(get(data,"PhysActorDataTable"),"HeldenPhysActorData",
          "PhysActorData",function(_,row,stat)
            local changed=0
            if CFG.FurnitureXP and mutateRow(row,"XP",function(x) return math.floor(x*CFG.FurnitureXPMult) end) then
                patchStats.xp=patchStats.xp+1;changed=changed+1
            end
            if CFG.LootGold and multiplyGold(get(row,"Parsed_ScrapReward")) then
                patchStats.price=patchStats.price+1;changed=changed+1
            end
            stat.changed=(stat.changed or 0)+changed
        end)
    end
    -- Avoid making firearms immortal: map ItemStatsName to item classes.
    if CFG.InfiniteNonFirearmDurability then
        local container=get(data,"ItemAssetContainer")
        local known={}
        if valid(container) then
            eachArray(get(container,"ItemAssets"),function(asset)
                if valid(asset) then
                    local key=asstr(get(asset,"ItemStatsName"))
                    local cls=get(asset,"ItemClass")
                    if key and valid(cls) then
                        local ranged=false
                        pcall(function() ranged=cls:IsChildOf(StaticFindObject("/Script/Helden.HeldenRangedWeapon")) end)
                        if not ranged then
                            local f=name(cls):lower()
                            ranged=f:find("ranged",1,true)~=nil or f:find("gun",1,true)~=nil
                        end
                        known[key]=ranged and "gun" or "other"
                    end
                end
            end)
        end
        if next(known)==nil then
            verbose("item class mapping not ready, leaving item DataTable unchanged")
        else
            applyTable(get(data,"ItemDataTable"),"HeldenItemData",
              "ItemData",function(rowname,row,stat)
                local id=asstr(get(row,"DataName")) or rowname
                if known[id]=="other" or known[rowname]=="other" then
                    if mutateRow(row,"UseDurabilityLoss",function() return 0 end) then
                        patchStats.durability=patchStats.durability+1
                        stat.changed=(stat.changed or 0)+1
                    end
                end
              end)
        end
    end
end

local S={run=0,flags=0,seenRun=false,beenFailed=false,seenSuccess=false,
    orphanSweep=CFG.OrphanItemSweepSamples-1,orphanItems={},durabilityCycle=0,
    lastTick=-1,nextTables=0,nextInventory=0,nextDurability=0,
    snapshot={},pending=nil,deliveryKey=nil,attempts=0,nextDelivery=0,
    warned=false,lastSummary=nil,delivered=0,slot=nil}
local function itemId(item)
    local id=asstr(get(item,"DynamicSaveName"))
    if id and id~="None" and id~="" then return id end
    return name(item)
end
local function itemRecord(item)
    if not valid(item) or not isA(item,"HeldenEquipableItem") then return nil end
    local cls
    pcall(function() cls=item:GetClass() end)
    if not valid(cls) then return nil end
    local asset=get(item,"ItemDataAsset")
    return {
        key=itemId(item), klass=cls, classPath=name(cls),
        assetName=valid(asset) and asstr(get(asset,"UniqueName")) or "?",
        durability=num(get(item,"ItemDurability")),
        enchant=asstr(get(item,"ItemEnchantment")),
        ranged=isA(item,"HeldenRangedWeapon")
    }
end
local function snapshotInventory()
    local records={}
    local players={}
    -- A player may have both inventory slots and equipped objects. Merge
    -- by DynamicSaveName/full UObject name, not by item type.
    for _,char in ipairs(all("HeldenPlayerCharacter")) do
        if valid(char) then
            players[name(char)]=true
            eachArray(get(char,"EquipedItems"),function(obj)
                local rec=itemRecord(obj)
                if rec then records[rec.key]=rec end
            end)
            eachArray(get(char,"ItemSlots"),function(slot)
                local rec=itemRecord(get(slot,"CurrentItemInSlot"))
                if rec then records[rec.key]=rec end
            end)
        end
    end
    -- A separate equipment actor can be slotted to the player but not
    -- included in EquipedItems (game uses both references). Accept only
    -- a valid current inventory slot AND the same previous owner; dropped
    -- world items lacking a current slot must not be collected.
    if next(players) then
        -- Full UObject scans are expensive and used to run every 2 seconds.
        -- Keep a small cache of special slotted items; only refresh it
        -- every fourth inventory snapshot. Primary slot arrays remain live.
        S.orphanSweep=S.orphanSweep+1
        if S.orphanSweep>=CFG.OrphanItemSweepSamples then
            S.orphanSweep=0
            S.orphanItems={}
            for _,item in ipairs(all("HeldenEquipableItem")) do
                if valid(item) then
                    local owner=get(item,"PreviousOwner")
                    local slot=get(item,"CurrentSlot")
                    if valid(owner) and players[name(owner)] and valid(slot) then
                        local key=itemId(item)
                        S.orphanItems[key]=item
                    end
                end
            end
        end
        for key,item in pairs(S.orphanItems) do
            if valid(item) then
                local owner=get(item,"PreviousOwner")
                local slot=get(item,"CurrentSlot")
                if valid(owner) and players[name(owner)] and valid(slot) then
                    local rec=itemRecord(item)
                    if rec then records[rec.key]=rec end
                else
                    S.orphanItems[key]=nil
                end
            else
                S.orphanItems[key]=nil
            end
        end
    end
    if next(records) then
        S.snapshot=records
        local count=0 for _ in pairs(records) do count=count+1 end
        verbose("cached "..count.." player items before wipe")
    end
end
local function positionOf(elevator)
    local loc
    pcall(function() loc=elevator:K2_GetActorLocation() end)
    if not loc then pcall(function() loc=elevator:GetActorLocation() end) end
    if not loc then return nil end
    local x,y,z=num(get(loc,"X")),num(get(loc,"Y")),num(get(loc,"Z"))
    if x and y and z then return {X=x,Y=y,Z=z} end
end
local function scanExisting(items, elevatorPos)
    local list={}
    for _,item in ipairs(all("HeldenEquipableItem")) do
        if valid(item) then
            -- Do not count stale dungeon actors as already delivered.
            local exists=true
            if elevatorPos then
                local v
                pcall(function() v=item:K2_GetActorLocation() end)
                if v then
                    local dx=(num(get(v,"X")) or 1e9)-elevatorPos.X
                    local dy=(num(get(v,"Y")) or 1e9)-elevatorPos.Y
                    local dz=(num(get(v,"Z")) or 1e9)-elevatorPos.Z
                    exists=dx*dx+dy*dy+dz*dz <= 900*900
                end
            end
            if exists then list[itemId(item)]=true end
        end
    end
    return list
end
local function deliver()
    if not CFG.InsuranceOnWipe or not S.pending then return end
    if S.attempts>=CFG.MaxDeliveryAttempts then return end
    local elevator=find("HeldenDungeonElevator")
    local pos=elevator and positionOf(elevator)
    if not pos then
        if S.attempts==0 then log("insurance: elevator location unavailable; retrying") end
        S.attempts=S.attempts+1
        return
    end
    local world
    pcall(function() world=elevator:GetWorld() end)
    if not valid(world) then
        S.attempts=S.attempts+1
        return
    end
    local existing=scanExisting(S.pending,pos)
    local total,created,errors=0,0,0
    for _,rec in pairs(S.pending) do
        total=total+1
        if total>CFG.MaxInsuranceItems then break end
        if not existing[rec.key] then
            if valid(rec.klass) then
                local ordinal=total
                local at={X=pos.X+70+(ordinal%5)*45,Y=pos.Y+50+math.floor(ordinal/5)*45,Z=pos.Z+110}
                local ok,item=pcall(function()
                    return world:SpawnActor(rec.klass,at,{Pitch=0,Yaw=0,Roll=0})
                end)
                if ok and valid(item) then
                    if rec.durability then
                        set(item,"ItemDurability",rec.durability)
                    end
                    if rec.enchant and rec.enchant~="None" then
                        -- Unreal FName cannot safely be constructed from a raw
                        -- string on this build; do not overwrite enchantments.
                        verbose("insurance: check enchantment for "..rec.key)
                    end
                    created=created+1
                    existing[rec.key]=true
                    S.delivered=S.delivered+1
                else
                    errors=errors+1
                end
            else
                errors=errors+1
            end
        end
    end
    log(string.format("insurance delivery: %d recorded, %d spawned, %d failures",
        total,created,errors))
    if errors==0 then
        S.pending=nil
        S.snapshot={}
    else
        -- No repeated automatic spawning after partial delivery, since the
        -- spawned actor might receive a new dynamic save name. Fail closed.
        S.pending=nil
        log("insurance incomplete; refusing further automatic spawns to prevent duplicates")
    end
end

local function durabilityItem(item,outpost)
    if not valid(item) or not isA(item,"HeldenEquipableItem") then return end
    local max=num(get(item,"ItemDurabilityMax"))
    if not max or max<=0 or max>1e9 then return end
    local current=num(get(item,"ItemDurability"))
    local gun=isA(item,"HeldenRangedWeapon")
    if gun and not (CFG.ResetFirearmsAtOutpost and outpost) then return end
    if not gun and not CFG.InfiniteNonFirearmDurability then return end
    if current and current<max then set(item,"ItemDurability",max) end
end
local function repairEquipment(outpost)
    local seen={}
    local ownersFound=false
    local function repair(item)
        item=unwrap(item)
        if not valid(item) then return end
        local key=name(item)
        if seen[key] then return end
        seen[key]=true
        durabilityItem(item,outpost)
    end
    -- Repair only what real players carry; do not iterate every loose item
    -- and every furniture/inventory actor in the entire world each sweep.
    for _,char in ipairs(all("HeldenPlayerCharacter")) do
        if valid(char) then
            ownersFound=true
            eachArray(get(char,"EquipedItems"),repair)
            eachArray(get(char,"ItemSlots"),function(slot)
                repair(get(slot,"CurrentItemInSlot"))
            end)
        end
    end
    for _,item in pairs(S.orphanItems) do repair(item) end
    -- No live players means there are no carried items to repair.
    -- Global scanning here was a visible hitch at death/respawn/menu.
    if not ownersFound then return end
end

local function poll(now)
    -- A GameMode only exists with authority; never mutate client's data.
    local gm=find("GameModeBase")
    if not gm then return end
    local gi=find("HeldenGameInstance")
    local save=gi and get(gi,"CurrentSaveGame")
    local slotData=valid(save) and get(save,"MetaData") or nil
    local slot=num(slotData and get(slotData,"GameSlot"))
    if slot~=nil then
        if S.slot~=nil and S.slot~=slot then
            S.snapshot={};S.pending=nil;S.seenRun=false;S.beenFailed=false
            log("save slot changed, discarded pending items from previous slot")
        end
        S.slot=slot
    end
    local gs=find("HeldenGameState")
    if not gs then return end
    local mode=enum(get(gs,"GameModeType"))
    if mode==nil then mode=enum(get(save,"GameMode")) end
    if mode~=0 and mode~=1 then return end
    local run=get(gs,"CurrentDungeonRun")
    if mode==1 and not run then return end
    -- EHeldenGameMode.Default=0 is Story. It has no mandatory active
    -- DungeonRun. Treat as gameplay for XP, loot tables and weapon wear,
    -- NOT as an outpost that repairs firearms every four seconds.
    local runState=mode==0 and 2 or (enum(get(run,"State")) or 0)
    local runFlags=mode==1 and get(run,"Flags") or 0
    now=now or os.clock()
    if now>=S.nextTables then
        S.nextTables=now+CFG.DataRetrySeconds
        applyTables()
    end
    if runState==1 or runState==2 then
        S.seenRun=true
        if S.beenFailed and S.pending then
            log("insurance cancelled: new run before a safe outpost delivery")
            S.pending=nil
        end
        S.beenFailed=false
        -- Story never reaches an Expedition wipe with elevator delivery.
        -- Sampling every player's items in Story wasted significant CPU.
        if CFG.InsuranceOnWipe and mode==1 and runState==2 and
           now>=S.nextInventory then
            S.nextInventory=now+CFG.InventorySnapshotSeconds
            snapshotInventory()
        end
    elseif runState==3 and S.seenRun and failed(runFlags) then
        if not S.beenFailed then
            S.beenFailed=true
            local pending={}
            local n=0
            for k,v in pairs(S.snapshot) do
                n=n+1
                if n<=CFG.MaxInsuranceItems then pending[k]=v end
            end
            if n>0 then S.pending=pending end
            log("failed expedition: queued "..math.min(n,CFG.MaxInsuranceItems).." items for elevator")
        end
    end
    if runState==0 and S.run~=0 then
        cache.HeldenDungeonElevator=nil
        -- A normal successful extraction already handles items; only the
        -- explicit failed flag leads to replacement spawns.
        if not S.beenFailed then S.snapshot={} end
    end
    if runState==0 and S.pending and now>=S.nextDelivery then
        S.nextDelivery=now+CFG.DeliveryRetrySeconds
        deliver()
    end
    if now>=S.nextDurability then
        S.nextDurability=now+CFG.DurabilitySweepSeconds
        repairEquipment(runState==0)
    end
    S.run=runState
end

-- A Lua hook on BlueprintUpdateAnimation is expensive even when sampled:
-- every animation update still enters UE4SS/Lua. Use a game-thread timer
-- whenever supported; only legacy UE4SS builds require the animation fallback.
local hookRegistered=false
local sample=CFG.HookSample-1
-- The Windows os.clock() is PROCESS CPU TIME, not wall-time.
-- Timer callbacks arrive at most every 750ms; count scheduled ticks instead
-- of letting heavy CPU activity accelerate expensive 2/4/10s sweeps.
local timerSeconds=0
local lastSlowPoll=-1000
local function safe_poll(fromTimer)
    local started=os.clock()
    if fromTimer then timerSeconds=timerSeconds+CFG.PollSeconds end
    local ok,err=pcall(poll,fromTimer and timerSeconds or nil)
    local ended=os.clock()
    if ended-started>=CFG.SlowPollWarnSeconds and
       ended-lastSlowPoll>=5 then
        lastSlowPoll=ended
        log(string.format("PERF slow poll CPU=%.1fms (inventory/tables/durability)",
            (ended-started)*1000))
    end
    if not ok and not S.warned then
        S.warned=true
        log("poll failed (continuing in fail-soft mode): "..tostring(err))
    end
end
local function heartbeat()
    sample=sample+1
    if sample<CFG.HookSample then return end
    sample=0
    local now=os.clock()
    if S.lastTick>=0 and now>=S.lastTick and now-S.lastTick<CFG.PollSeconds then return end
    S.lastTick=now
    safe_poll()
end
local function register()
    if hookRegistered then return end
    local ok,err=pcall(function()
        RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
            function() heartbeat() end)
    end)
    if ok then hookRegistered=true;log("WARNING: animation fallback hook active")
    else log("ERROR: cannot register heartbeat: "..tostring(err)) end
end

local scheduled=false
if type(LoopInGameThreadWithDelay)=="function" then
    local ok,handle=pcall(LoopInGameThreadWithDelay,750,function()
        safe_poll(true)
    end)
    if ok and handle~=nil then
        scheduled=true
        log("game-thread timer active (750 ms); no animation hook")
    end
end
if not scheduled and type(LoopAsync)=="function" and
   type(ExecuteInGameThread)=="function" then
    local ok,err=pcall(LoopAsync,750,function()
        local queued,why=pcall(ExecuteInGameThread,function()
            safe_poll(true)
        end)
        if not queued and not S.warned then
            S.warned=true
            log("game-thread poll queue failed: "..tostring(why))
        end
        return false
    end)
    if ok then
        scheduled=true
        log("UE4SS v3 async timer active (750 ms); no animation hook")
    else log("async timer unavailable: "..tostring(err)) end
end
if not scheduled then register() end

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart",function()
        cache={}
        S.lastTick=-1
        sample=CFG.HookSample-1
    end)
end)
log("v0.1.1 fps-timer-hotfix loaded ("..
    (scheduled and "timer" or "animation fallback").."). Host only.")
