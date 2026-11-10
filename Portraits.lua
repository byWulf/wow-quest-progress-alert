local _, ns = ...

-- Portraits of enemies, for kill objectives.
--
-- The game only draws a portrait while the unit exists (SetPortraitTexture(texture, unit)), but the
-- texture keeps the picture afterwards. So every enemy you see (target, mouseover, nameplates, targets of
-- group members) gets its own texture, painted once and kept for the session. A kill card later borrows
-- that texture, even if the enemy is long gone or a group member killed it.
-- Keyed by NPC ID (from the GUID) and by name. Questie (optional) maps an objective like "Murlocs slain"
-- to the NPC IDs that count for it.

local Portraits = {}
ns.Portraits = Portraits

local MAX_ENTRIES = 100 -- least recently seen ones are dropped (textures are reused)
local REPAINT_AFTER = 30 -- seconds; seeing the enemy again after that paints it again

local holder
local entries, byName, byNpc, freeTextures = {}, {}, {}, {}

local function IsSecret(value)
    return ns.IsSecret(value)
end

-- Name and NPC ID of an attackable non-player unit, or nil. In combat, names and GUIDs can be secret;
-- such units are skipped (they were usually seen before the fight).
local function UnitInfo(unit)
    local ok, name, npcId = pcall(function()
        if not UnitExists(unit) or UnitIsPlayer(unit) or not UnitCanAttack("player", unit) then
            return nil
        end
        local unitName = UnitName(unit)
        if type(unitName) ~= "string" or IsSecret(unitName) or unitName == "" then
            return nil
        end
        local id
        local guid = UnitGUID(unit)
        if type(guid) == "string" and not IsSecret(guid) then
            local kind, _, _, _, _, npc = strsplit("-", guid)
            if kind == "Creature" or kind == "Vehicle" then
                id = tonumber(npc)
            end
        end
        return unitName, id
    end)
    if ok then
        return name, npcId
    end
end

local function RemoveEntry(index)
    local entry = table.remove(entries, index)
    if byName[entry.name] == entry then
        byName[entry.name] = nil
    end
    if entry.npcId and byNpc[entry.npcId] == entry then
        byNpc[entry.npcId] = nil
    end
    entry.tex:Hide()
    freeTextures[#freeTextures + 1] = entry.tex
end

local function Evict()
    while #entries > MAX_ENTRIES do
        local oldestIndex, oldestSeen
        for index, entry in ipairs(entries) do
            if not entry.card and (not oldestSeen or entry.seen < oldestSeen) then
                oldestIndex, oldestSeen = index, entry.seen
            end
        end
        if not oldestIndex then
            return
        end
        RemoveEntry(oldestIndex)
    end
end

function Portraits.Remember(unit)
    if not (holder and ns.db and ns.db.showPortraits) then
        return
    end
    local name, npcId = UnitInfo(unit)
    if not name then
        return
    end
    local now = GetTime()
    local entry = (npcId and byNpc[npcId]) or byName[name]
    if entry and entry.name == name and now - entry.painted < REPAINT_AFTER then
        entry.seen = now
        return
    end
    if not entry or entry.name ~= name then
        local texture = table.remove(freeTextures) or holder:CreateTexture(nil, "ARTWORK")
        entry = { tex = texture }
        entries[#entries + 1] = entry
    end
    entry.name = name
    entry.npcId = npcId or entry.npcId
    entry.seen, entry.painted = now, now
    byName[name] = entry
    if npcId then
        byNpc[npcId] = entry
    end
    SetPortraitTexture(entry.tex, unit)
    Evict()
end

-- Finds a remembered portrait by NPC IDs (first match) or by names.
function Portraits.Find(names, npcIds)
    if not (ns.db and ns.db.showPortraits) then
        return nil
    end
    for _, id in ipairs(npcIds or {}) do
        local entry = byNpc[id]
        if entry then
            entry.seen = GetTime()
            return entry
        end
    end
    for _, name in ipairs(names or {}) do
        local entry = byName[name]
        if entry then
            entry.seen = GetTime()
            return entry
        end
    end
    return nil
end

-- NPC IDs and names that count for a quest objective, from Questie's database (if installed and enabled).
function Portraits.QuestieTargets(questID, objectiveIndex)
    if not (ns.db.useQuestie and questID and objectiveIndex and QuestieLoader) then
        return nil
    end
    local ok, ids, names = pcall(function()
        local QuestieDB = QuestieLoader:ImportModule("QuestieDB")
        local quest = QuestieDB and QuestieDB.GetQuest and QuestieDB.GetQuest(questID)
        local objective = quest and quest.ObjectiveData and quest.ObjectiveData[objectiveIndex]
        if not objective then
            return nil
        end
        local list = {}
        if objective.Type == "monster" then
            list[1] = objective.Id
        elseif objective.Type == "killcredit" then
            for _, id in ipairs(objective.IdList or {}) do
                list[#list + 1] = id
            end
            if objective.RootId then
                list[#list + 1] = objective.RootId
            end
        else
            return nil
        end
        local nameList = {}
        if QuestieDB.QueryNPCSingle then
            for _, id in ipairs(list) do
                local name = QuestieDB.QueryNPCSingle(id, "name")
                if type(name) == "string" then
                    nameList[#nameList + 1] = name
                end
            end
        end
        return list, nameList
    end)
    if ok and ids and #ids > 0 then
        return ids, names
    end
    return nil
end

-- A card shows the texture; it goes back here when the card no longer needs it.
function Portraits.Return(entry)
    local texture = entry.tex
    if entry.mask then
        texture:RemoveMaskTexture(entry.mask)
        entry.mask = nil
    end
    texture:SetParent(holder)
    texture:ClearAllPoints()
    texture:Hide()
    entry.card = nil
end

function Portraits.Init()
    holder = CreateFrame("Frame")
    holder:Hide()
    holder:RegisterEvent("PLAYER_TARGET_CHANGED")
    holder:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    holder:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    holder:RegisterEvent("UNIT_TARGET")
    holder:SetScript("OnEvent", function(_, event, unit)
        if event == "PLAYER_TARGET_CHANGED" then
            Portraits.Remember("target")
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            Portraits.Remember("mouseover")
        elseif event == "NAME_PLATE_UNIT_ADDED" then
            Portraits.Remember(unit)
        elseif event == "UNIT_TARGET" and type(unit) == "string" and not IsSecret(unit)
            and (unit:match("^party%d$") or unit:match("^raid%d+$")) then
            Portraits.Remember(unit .. "target")
        end
    end)
end
