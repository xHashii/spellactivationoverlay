local AddonName, SAO = ...

local hotStreakSpellID = 48108;
local heatingUpSpellID = 48107; -- Does not exist in Wrath Classic

-- Because the Heating Up buff does not exist in Wrath of the Lich King
-- We try to guess when the mage should virtually get this buff
local HotStreakHandler = {}

-- Initialize constants
HotStreakHandler.init = function(self, spellName)
    local fire_blast = { 2136, 2137, 2138, 8412, 8413, 10197, 10199, 27078, 27079, 42872, 42873 }
    local fireball = { 133, 143, 145, 3140, 8400, 8401, 8402, 10148, 10149, 10150, 10151, 25306, 27070, 38692, 42832, 42833 }
    local frostfire_bolt = { 44614, 47610 };
    -- local living_bomb = { 44457, 55359, 55360 } this is the DOT effect, which we do NOT want
    local living_bomb = { 44461, 55361, 55362 }
    local scorch = { 2948, 8444, 8445, 8446, 10205, 10206, 10207, 27073, 27074, 42858, 42859 }

    self.spells = {}
    local function addSpellPack(spellPack)
        for _, spellID in pairs(spellPack) do
            self.spells[spellID] = true;
        end
    end
    addSpellPack(fire_blast);
    addSpellPack(fireball);
    addSpellPack(frostfire_bolt);
    addSpellPack(living_bomb);
    addSpellPack(scorch);

    local _, _, tab, index = SAO:GetTalentByName(spellName);
    if (tab and index) then
        self.talent = { tab, index }
    end

    -- There are 4 states possible: cold, heating_up, hot_streak and hot_streak_heating_up
    -- The state always starts as cold
    self.state = 'cold';
    -- There is a known issue when the player disconnects with the virtual "Heating Up" buff, then reconnects
    -- Ideally, we'd keep track of the virtual buff, but it's really hard to do, and sometimes not even possible
    -- It's best not to over-design something to try to fix fringe cases, so we simply accept this limitation
end

HotStreakHandler.isSpellTracked = function(self, spellID)
    return self.spells[spellID];
end

local function activateHeatingUp(self)
    -- Heating Up uses the Hot Streak texture, but scaled at 50%
    self:ActivateOverlay(0, heatingUpSpellID, self.TexName["hot_streak"], "Left + Right (Flipped)", 0.5, 255, 255, 255, false);
end

local function deactivateHeatingUp(self)
    self:DeactivateOverlay(heatingUpSpellID);
end

local function customCLEU(self, ...)
    local timestamp, event, _, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo() -- For all events

    -- Special case: if player dies, we assumed the "Heating Up" virtual buff was lost
    -- However, data suggest that Heating Up is *not* lost on death, invalidating the code below
    -- The code is kept commented instead of removed, because Blizzard may change this behaviour
    --if (event == "UNIT_DIED" and destGUID == UnitGUID("player")) then
    --    if (HotStreakHandler.state == 'heating_up') then
    --        deactivateHeatingUp(self);
    --    end
    --    HotStreakHandler.state = 'cold';
    --
    --    return;
    --end

    -- Accept only certain events, and only when done by the player
    if (event ~= "SPELL_DAMAGE" and event ~= "SPELL_AURA_APPLIED" and event ~= "SPELL_AURA_REMOVED") then return end
    if (sourceGUID ~= UnitGUID("player")) then return end

    local spellID, spellName, spellSchool = select(12, CombatLogGetCurrentEventInfo()) -- For SPELL_*

    -- If Hot Streak buff was acquired or lost, we have our immediate answer
    -- We assume there is no third charge i.e., if a crit occurs under Hot Streak buff, there is no hidden Heating Up
    if (event == "SPELL_AURA_APPLIED") then
        if (spellID == hotStreakSpellID) then
            deactivateHeatingUp(self);
            HotStreakHandler.state = 'hot_streak';
        end
        return;
    elseif (event == "SPELL_AURA_REMOVED") then
        if (spellID == hotStreakSpellID) then
            if (HotStreakHandler.state == 'hot_streak_heating_up') then
                activateHeatingUp(self);
                HotStreakHandler.state = 'heating_up';
            else
                HotStreakHandler.state = 'cold';
            end
        end
        return;
    end

    -- The rest of the code is dedicated to try to catch the Heating Up buff, or if the buff is lost.

    -- Talent information could not be retrieved for Hot Streak
    if (not HotStreakHandler.talent) then return end

    -- Talent information must include at least one point in Hot Streak
    -- This may not be accurate, but it's almost impossible to do better
    -- Not to mention, almost no one will play with only 1 or 2 points
    local rank = select(5, GetTalentInfo(HotStreakHandler.talent[1], HotStreakHandler.talent[2]));
    if (not (rank > 0)) then return end

    -- Spell must be match a known spell ID that can proc Hot Streak
    if (not HotStreakHandler:isSpellTracked(spellID)) then return end

    local amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing, isOffHand = select(15, CombatLogGetCurrentEventInfo()); -- For SPELL_DAMAGE*

    if (HotStreakHandler.state == 'cold') then
        if (critical) then
            -- A crit while cold => Heating Up!
            HotStreakHandler.state = 'heating_up';
            activateHeatingUp(self);
        end
    elseif (HotStreakHandler.state == 'heating_up') then
        if (not critical) then
            -- No crit while Heating Up => cooling down
            HotStreakHandler.state = 'cold';
            deactivateHeatingUp(self);
        -- else
            -- We could put the state to 'hot_streak' here, but the truth is, we don't know for sure if it's accurate
            -- Either way, if the Hot Streak buff is deserved, we'll know soon enough with a "SPELL_AURA_APPLIED"
        end
    elseif (HotStreakHandler.state == 'hot_streak') then
        if (critical) then
            -- If crit during a Hot Streak, store this 'charge' to eventually restore it when Pyroblast is cast
            -- This is called "hot streaking heating up", which means Hot Streak has a pending Heating Up effect
            HotStreakHandler.state = 'hot_streak_heating_up';
            -- Please note this works only because we are fairly certain that SPELL_AURA_APPLIED of a Hot Streak
            -- always occur *after* the critical effect of the spell which triggered it.
            -- Should it be the other way around (SPELL_AURA_APPLIED before SPELL_DAMAGE, or worse, random order)
            -- we would be in big trouble to know whether the crit is piling up before or after a Hot Streak.
        end
    elseif (HotStreakHandler.state == 'hot_streak_heating_up') then
        if (not critical) then
            -- If Hot Streak had a pending Heating Up effect but a spell did not crit afterwards, the pending Heating Up is lost
            HotStreakHandler.state = 'hot_streak';
        end
    else
        print("Unknown HotStreakHandler state");
    end
end

local function customLogin(self, ...)
    -- Must initialize class on PLAYER_LOGIN instead of registerClass
    -- Because we need the talent tree, which is not always available right off the bat
    local hotStreakSpellName = GetSpellInfo(hotStreakSpellID);
    if (hotStreakSpellName) then
        HotStreakHandler:init(hotStreakSpellName);
    end
end

local function registerClass(self)
    -- Fire Procs
    self:RegisterAura("impact", 0, 64343, "impact", "Top", 1, 255, 255, 255, true, { (GetSpellInfo(2136)) });
    self:RegisterAura("hot_streak_full", 0, hotStreakSpellID, "hot_streak", "Left + Right (Flipped)", 1, 255, 255, 255, true, { (GetSpellInfo(11366)) });
    --self:RegisterAura("hot_streak_half", 0, heatingUpSpellID, "hot_streak", "Left + Right (Flipped)", 0.5, 255, 255, 255, false);
    -- Heating Up (spellID == 48107) doesn't exist in Wrath Classic, so we can't use the above aura
    -- Instead, we track Fire Blast, Fireball, Living Bomb and Scorch non-periodic critical strikes
    -- Please look at HotStreakHandler and customCLEU for more information

    -- Frost Procs
    self:RegisterAura("fingers_of_frost_1", 1, 74396, "frozen_fingers", "Left", 1, 255, 255, 255, true);
    self:RegisterAura("fingers_of_frost_2", 2, 74396, "frozen_fingers", "Left + Right (Flipped)", 1, 255, 255, 255, true);
    self:RegisterAura("brain_freeze", 0, 57761, "brain_freeze", "Top", 1, 255, 255, 255, true, { (GetSpellInfo(133)), (GetSpellInfo(44614)) });

    -- Arcane Procs
    self:RegisterAura("missile_barrage", 0, 44401, "arcane_missiles", "Left + Right (Flipped)", 1, 255, 255, 255, true, { (GetSpellInfo(5143)) });
end

SAO.Class["MAGE"] = {
    ["Register"] = registerClass,
    ["COMBAT_LOG_EVENT_UNFILTERED"] = customCLEU,
    ["PLAYER_LOGIN"] = customLogin,
}
