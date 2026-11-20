-- Strict-ish UE4SS simulator: real gameplay is NOT executed by CI.
local path="ue4ss/Mods/GrainRotQOL/Scripts/main.lua"
local function fake(fields)
    local x=fields or {}
    function x:IsValid() return self._valid~=false end
    function x:GetFullName() return self._full or ("Object "..tostring(self)) end
    return x
end
local function datatype(label, rows)
    local dt=fake({_full="DataTable "..label,rows=rows})
    function dt:GetRowStruct() return {GetName=function() return label end} end
    function dt:ForEachRow(cb) for k,v in pairs(self.rows) do cb(k,v) end end
    return dt
end
local function game()
    local now, hooks, logs, clockCalls, searches, spawns=0,{},{},0,{},{}
    local charClass=fake({_full="Class /Script/Helden.HeldenEquipableItem"})
    local gunClass=fake({_full="Class /Script/Helden.HeldenRangedWeapon"})
    function gunClass:IsChildOf(cls) return cls==gunClass end
    function charClass:IsChildOf(cls) return false end
    local plant={XP=6,Parsed_ScrapValue_Common={Gold=1},Parsed_ScrapValue_Rare={Gold=20},Parsed_ScrapValue_Epic={Gold=0}}
    local chest={XP=12,Parsed_ScrapValue_Common={Gold=2},Parsed_ScrapValue_Rare={Gold=5},Parsed_ScrapValue_Epic={Gold=40}}
    local scrap={XP=4,Parsed_ScrapReward={Gold=1}}
    local sword={DataName="Sword",UseDurabilityLoss=5,MaxDurability=50}
    local rifle={DataName="Rifle",UseDurabilityLoss=2,MaxDurability=20}
    local construct=datatype("HeldenConstructAssetData",{SmallPlant=plant,Cabinet=chest})
    local phys=datatype("HeldenPhysActorData",{TrashHeap=scrap})
    local itemTable=datatype("HeldenItemData",{Sword=sword,Rifle=rifle})
    local asset1=fake({ItemStatsName="Sword",ItemClass=charClass,UniqueName="SwordAsset"})
    local asset2=fake({ItemStatsName="Rifle",ItemClass=gunClass,UniqueName="RifleAsset"})
    local singleton=fake({ConstructAssetDataTable=construct,PhysActorDataTable=phys,ItemDataTable=itemTable,
        ItemAssetContainer=fake({ItemAssets={asset1,asset2}})})
    local gs=fake({CurrentDungeonRun={State=0,Flags=0}})
    local elevator=fake()
    function elevator:K2_GetActorLocation() return {X=1000,Y=2000,Z=100} end
    local world=fake()
    function elevator:GetWorld() return world end
    function world:SpawnActor(klass,at,rot)
        local item=fake({ItemDurabilityMax=60,ItemDurability=60,ItemDataAsset=asset1,
            _full="Spawned Item "..tostring(#spawns+1)})
        function item:GetClass() return klass end
        function item:IsA(className)
            if className=="/Script/Helden.HeldenEquipableItem" then return true end
            return className=="/Script/Helden.HeldenRangedWeapon" and klass==gunClass
        end
        spawns[#spawns+1]={item=item,loc=at,rot=rot}
        return item
    end
    local main=fake({_full="Item /Game/Sword_1",ItemDataAsset=asset1,ItemDurability=12,ItemDurabilityMax=50,
        DynamicSaveName="Item_9"})
    function main:GetClass() return charClass end
    function main:IsA(n) return n=="/Script/Helden.HeldenEquipableItem" end
    local firearm=fake({_full="Item /Game/Rifle_1",ItemDataAsset=asset2,ItemDurability=6,ItemDurabilityMax=20,
        DynamicSaveName="Item_10"})
    function firearm:GetClass() return gunClass end
    function firearm:IsA(n) return n=="/Script/Helden.HeldenEquipableItem" or
        n=="/Script/Helden.HeldenRangedWeapon" end
    local player=fake({EquipedItems={main,firearm},ItemSlots={}})
    local objects={
        GameModeBase=fake(),HeldenGameState=gs,HeldenDataSingleton=singleton,
        HeldenGameInstance=fake({CurrentSaveGame=fake({MetaData={GameSlot=0}})}),
        HeldenDungeonElevator=elevator,
    }
    local lists={HeldenPlayerCharacter={player},HeldenEquipableItem={main,firearm}}
    local env=setmetatable({
        print=function(x) logs[#logs+1]=x end,
        os={clock=function() clockCalls=clockCalls+1;return now end},
        FindFirstOf=function(n) searches[n]=(searches[n] or 0)+1;return objects[n] end,
        FindAllOf=function(n) return lists[n] or {} end,
        StaticFindObject=function(path) if path:find("RangedWeapon") then return gunClass end end,
        RegisterHook=function(path,callback) hooks[path]=callback end,
    },{__index=_G})
    assert(loadfile(path,"t",env))()
    local frame="/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation"
    assert(hooks[frame])
    local t={gs=gs,main=main,firearm=firearm,player=player,objects=objects,lists=lists,logs=logs,
        plant=plant,chest=chest,scrap=scrap,sword=sword,rifle=rifle,spawns=spawns,
        trigger=function(dt)
            now=now+(dt or 1)
            for i=1,8 do hooks[frame]() end
        end,
        flood=function(n) for i=1,n do hooks[frame]() end end,
        stats=function() return clockCalls,searches end,
        host=function(yes) objects.GameModeBase=yes and fake() or nil end,
        tables={construct,phys,itemTable}
    }
    return t
end
local total=0
local function test(title,fn)
    fn()
    total=total+1
    print("PASS "..title)
end

test("furniture XP x5, from small plant 6 to 30",function()
    local t=game();t.trigger()
    assert(t.plant.XP==30)
    assert(t.chest.XP==60 and t.scrap.XP==20)
end)
test("gold reward: 1 -> 15, 20 -> 60, 2 -> 6; zero unchanged",function()
    local t=game();t.trigger()
    assert(t.plant.Parsed_ScrapValue_Common.Gold==15)
    assert(t.plant.Parsed_ScrapValue_Rare.Gold==60)
    assert(t.plant.Parsed_ScrapValue_Epic.Gold==0)
    assert(t.chest.Parsed_ScrapValue_Common.Gold==6)
    assert(t.scrap.Parsed_ScrapReward.Gold==15)
end)
test("data patch is not compounded by later refresh",function()
    local t=game();t.trigger()
    t.trigger(12);t.trigger(12)
    assert(t.plant.XP==30)
    assert(t.plant.Parsed_ScrapValue_Common.Gold==15)
end)
test("only melee item templates lose durability cost",function()
    local t=game();t.trigger()
    assert(t.sword.UseDurabilityLoss==0)
    assert(t.rifle.UseDurabilityLoss==2)
end)
test("infinite melee durability, firearm keeps wear in dungeon",function()
    local t=game()
    t.gs.CurrentDungeonRun.State=2
    t.trigger()
    t.main.ItemDurability=12;t.firearm.ItemDurability=6
    t.trigger(5)
    assert(t.main.ItemDurability==50)
    assert(t.firearm.ItemDurability==6)
end)
test("firearm resets to max durability after expedition",function()
    local t=game()
    t.gs.CurrentDungeonRun.State=2;t.trigger()
    t.firearm.ItemDurability=3
    t.trigger(5)
    assert(t.firearm.ItemDurability==3)
    t.gs.CurrentDungeonRun.State=0
    t.trigger(5)
    assert(t.firearm.ItemDurability==20)
end)
test("failed party run spawns gear once at lift after item actors disappear",function()
    local t=game()
    t.gs.CurrentDungeonRun.State=2;t.trigger(1)
    t.lists.HeldenEquipableItem={} -- destroyed by wipe
    t.gs.CurrentDungeonRun.State=3;t.gs.CurrentDungeonRun.Flags=1;t.trigger(1)
    t.gs.CurrentDungeonRun.State=0;t.trigger(1)
    assert(#t.spawns==2,"must return both captured equipped items")
    assert(t.spawns[1].loc.Z==210 and t.spawns[2].loc.Z==210)
    t.trigger(12)
    assert(#t.spawns==2,"must not duplicate on repeated tick")
end)
test("successful extraction must not manufacture extra items",function()
    local t=game()
    t.gs.CurrentDungeonRun.State=2;t.trigger()
    t.gs.CurrentDungeonRun.State=3;t.gs.CurrentDungeonRun.Flags=0;t.trigger()
    t.gs.CurrentDungeonRun.State=0;t.trigger()
    assert(#t.spawns==0)
end)
test("clients never modify tables or spawn items",function()
    local t=game();t.host(false)
    t.gs.CurrentDungeonRun.State=2;t.trigger()
    assert(t.plant.XP==6 and t.scrap.Parsed_ScrapReward.Gold==1)
    assert(t.main.ItemDurability==12)
    assert(#t.spawns==0)
end)
test("performance: 1600 animation calls require at most 201 clocks",function()
    local t=game();t.trigger()
    local c0=t.stats()
    t.flood(1600)
    local c1=t.stats()
    assert(c1-c0<=201,c1-c0)
end)
test("absent data singleton gracefully skips changes without exception",function()
    local t=game()
    t.objects.HeldenDataSingleton=nil
    t.trigger()
    assert(t.plant.XP==6)
end)
test("slotted but not actively equipped items are recovered",function()
    local t=game()
    t.player.EquipedItems={}
    t.main.PreviousOwner=t.player
    t.main.CurrentSlot=fake()
    t.gs.CurrentDungeonRun.State=2;t.trigger()
    t.lists.HeldenEquipableItem={}
    t.gs.CurrentDungeonRun.State=3;t.gs.CurrentDungeonRun.Flags=1;t.trigger()
    t.gs.CurrentDungeonRun.State=0;t.trigger()
    assert(#t.spawns==1)
end)
test("slot switch cancels insurance before returning to outpost",function()
    local t=game()
    t.gs.CurrentDungeonRun.State=2;t.trigger()
    t.gs.CurrentDungeonRun.State=3;t.gs.CurrentDungeonRun.Flags=1;t.trigger()
    t.objects.HeldenGameInstance.CurrentSaveGame.MetaData.GameSlot=1
    t.lists.HeldenEquipableItem={}
    t.gs.CurrentDungeonRun.State=0;t.trigger()
    assert(#t.spawns==0)
end)

print("ALL "..total.." TESTS PASSED")
