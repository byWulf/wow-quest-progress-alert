local ADDON, ns = ...
local L = ns.L

ns.MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"

ns.DEFAULTS = {
    enabled = true,
    showItems = true,
    showKills = true,
    showOther = true,
    showQuestComplete = true,
    showFailed = true,
    hideDefault = true,

    duration = 4,
    durationComplete = 6,
    fadeDuration = 0.6,

    maxCards = 5,
    grow = "DOWN",
    scale = 1,
    width = 340,
    spacing = 8,
    point = "TOP",
    relativePoint = "TOP",
    x = 0,
    y = -140,

    font = "DEFAULT",
    fontSize = 16,
    bgAlpha = 0.88,
    glow = 0.6,
    showIcon = true,
    showBar = true,
    showQuestTitle = true,
    animations = true,
    particles = true,
    colorProgress = "ff40c8ff",
    colorComplete = "ff4dff88",
    colorQuest = "ffffc933",
    colorFailed = "ffff4d4d",

    soundProgress = true,
    soundProgressFile = "questupdate",
    soundObjective = true,
    soundObjectiveFile = "chime",
    soundQuest = true,
    soundQuestFile = "questcomplete",
    soundChannel = "Master",
}

-- Sound files that exist in the WoW Forever client (file data IDs).
ns.SOUNDS = {
    { key = "questupdate", file = 567516, label = L.SND_QUEST_UPDATE },
    { key = "questcomplete", file = 567439, label = L.SND_QUEST_COMPLETE },
    { key = "chime", file = 566076, label = L.SND_CHIME },
    { key = "ping", file = 567416, label = L.SND_MAP_PING },
    { key = "pling", file = 567482, label = L.SND_PLING },
    { key = "humm", file = 569518, label = L.SND_HUMM },
    { key = "shing", file = 566240, label = L.SND_SHING },
    { key = "bellAlliance", file = 566564, label = L.SND_BELL_ALLIANCE },
    { key = "bellHorde", file = 565853, label = L.SND_BELL_HORDE },
    { key = "drums", file = 567275, label = L.SND_DRUMS },
    { key = "peon", file = 558132, label = L.SND_PEON },
}

ns.CHANNELS = {
    { key = "Master", label = L.CHANNEL_MASTER },
    { key = "SFX", label = L.CHANNEL_SFX },
    { key = "Dialog", label = L.CHANNEL_DIALOG },
    { key = "Ambience", label = L.CHANNEL_AMBIENCE },
}

ns.FONTS = {
    { key = "DEFAULT", label = L.FONT_DEFAULT },
    { key = "FRIZ", label = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { key = "ARIALN", label = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
    { key = "MORPHEUS", label = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
    { key = "SKURRI", label = "Skurri", path = "Fonts\\SKURRI.TTF" },
}

-- Quest messages of UI_INFO_MESSAGE (by the name GetGameMessageInfo returns) and what they are.
local KIND_BY_ERROR = {
    ERR_QUEST_ADD_ITEM_SII = "item",
    ERR_QUEST_ADD_KILL_SII = "kill",
    ERR_QUEST_ADD_PLAYER_KILL_SII = "kill",
    ERR_QUEST_ADD_FOUND_SII = "other",
    ERR_QUEST_OBJECTIVE_COMPLETE_S = "other",
    ERR_QUEST_UNKNOWN_COMPLETE = "other",
    ERR_QUEST_FAILED_S = "failed",
}
ns.KIND_BY_ERROR = KIND_BY_ERROR

local KIND_OPTION = {
    item = "showItems",
    kill = "showKills",
    other = "showOther",
    failed = "showFailed",
}

---------------------------------------------------------------------------
-- Helpers

local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) or false
end
ns.IsSecret = IsSecret

function ns.HexToRGB(hex)
    hex = type(hex) == "string" and hex or "ffffffff"
    if #hex == 8 then
        hex = hex:sub(3)
    end
    local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    return (r or 255) / 255, (g or 255) / 255, (b or 255) / 255
end

function ns.FontPath()
    for _, font in ipairs(ns.FONTS) do
        if font.key == ns.db.font and font.path then
            return font.path
        end
    end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

function ns.KindEnabled(kind)
    local option = KIND_OPTION[kind]
    return option == nil or ns.db[option]
end

function ns.Print(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40c8ff" .. L.TITLE .. ":|r " .. text)
end

---------------------------------------------------------------------------
-- Sounds

local lastSoundTime, lastSoundPriority = 0, 0

function ns.SoundFile(key)
    for _, sound in ipairs(ns.SOUNDS) do
        if sound.key == key then
            return sound.file
        end
    end
    return ns.SOUNDS[1].file
end

function ns.PlaySoundKey(key)
    PlaySoundFile(ns.SoundFile(key), ns.db.soundChannel or "Master")
end

-- priority: 1 progress, 2 objective complete, 3 quest complete. Several messages in the same
-- moment (looting a stack, killing two mobs at once) play only one sound, the most important one.
function ns.PlayEventSound(priority)
    local db = ns.db
    local enabledKey, fileKey
    if priority == 3 then
        enabledKey, fileKey = "soundQuest", "soundQuestFile"
    elseif priority == 2 then
        enabledKey, fileKey = "soundObjective", "soundObjectiveFile"
    else
        enabledKey, fileKey = "soundProgress", "soundProgressFile"
    end
    if not db[enabledKey] then
        return
    end
    local now = GetTime()
    if now - lastSoundTime < 0.25 and priority <= lastSoundPriority then
        return
    end
    lastSoundTime, lastSoundPriority = now, priority
    ns.PlaySoundKey(db[fileKey])
end

---------------------------------------------------------------------------
-- Parsing the message text

-- Turns a format string like "%s slain: %d/%d" (or with positions, "%2$d/%3$d %1$s") into a Lua
-- pattern plus the order of its values, so it works in every client language.
local patternCache = {}

local function FormatToPattern(format)
    local cached = patternCache[format]
    if cached then
        return cached.pattern, cached.order
    end
    local pattern, order, nextIndex = { "^" }, {}, 1
    local i, len = 1, #format
    while i <= len do
        local c = format:sub(i, i)
        if c == "%" then
            local pos, spec, stop = format:match("^%%(%d*)%$?([sd])()", i)
            if format:sub(i + 1, i + 1) == "%" then
                pattern[#pattern + 1] = "%%"
                i = i + 2
            elseif spec then
                local index = tonumber(pos) or nextIndex
                nextIndex = index + 1
                order[#order + 1] = { index = index, spec = spec }
                pattern[#pattern + 1] = spec == "d" and "(%-?%d+)" or "(.-)"
                i = stop
            else
                pattern[#pattern + 1] = "%%"
                i = i + 1
            end
        else
            pattern[#pattern + 1] = c:find("[%^%$%(%)%.%[%]%*%+%-%?]") and ("%" .. c) or c
            i = i + 1
        end
    end
    pattern[#pattern + 1] = "$"
    local result = { pattern = table.concat(pattern), order = order }
    patternCache[format] = result
    return result.pattern, result.order
end

-- The part of the format string in front of the numbers, e.g. "%s slain" for "%s slain: %d/%d".
local function FormatPrefix(format)
    local prefix = format:match("^(.-)%%%d*%$?d")
    return prefix and (prefix:gsub("[%s:：%-%(%[]+$", ""))
end

local function TitleFromFormat(format, name)
    local prefix = FormatPrefix(format)
    if not prefix or not prefix:find("%%%d*%$?s") then
        return name
    end
    -- A replacement function's result is used as is, so names with "%" stay intact.
    prefix = prefix:gsub("%%%d*%$?s", function()
        return name
    end)
    return prefix ~= "" and prefix or name
end

-- Returns name, have, need, title for a quest message. have/need are nil for messages without numbers.
function ns.ParseMessage(errorName, message)
    local format = _G[errorName]
    if type(format) == "string" and format ~= "" then
        local pattern, order = FormatToPattern(format)
        local captures = { message:match(pattern) }
        if #captures > 0 then
            local values, name, numbers = {}, nil, {}
            for position, info in ipairs(order) do
                values[info.index] = { spec = info.spec, value = captures[position] }
            end
            for index = 1, #order do
                local entry = values[index]
                if entry then
                    if entry.spec == "s" and not name then
                        name = entry.value
                    elseif entry.spec == "d" then
                        numbers[#numbers + 1] = tonumber(entry.value)
                    end
                end
            end
            local have, need = numbers[1], numbers[2]
            if not name then
                -- No name in the message (e.g. "Players slain: %d/%d"): use the text before the numbers.
                local prefix = FormatPrefix(format)
                name = prefix and prefix ~= "" and not prefix:find("%%") and prefix or message
            end
            local title = have and TitleFromFormat(format, name) or name
            return name, have, need, title
        end
    end
    -- Unknown format: try the usual "Text: 3/8".
    local text, have, need = message:match("^(.-)%s*[:：]%s*(%d+)%s*/%s*(%d+)%s*$")
    if text then
        return text, tonumber(have), tonumber(need), text
    end
    return message, nil, nil, message
end

---------------------------------------------------------------------------
-- Message type numbers (for hiding the default yellow text)

local messageIndexByName

local function MessageIndex(errorName)
    local constant = _G["LE_GAME_" .. errorName]
    if type(constant) == "number" then
        return constant
    end
    if not messageIndexByName then
        messageIndexByName = {}
        for index = 1, 2000 do
            local ok, name = pcall(GetGameMessageInfo, index)
            if ok and type(name) == "string" and KIND_BY_ERROR[name] then
                messageIndexByName[name] = index
            end
        end
    end
    return messageIndexByName[errorName]
end

function ns.ApplyDefaultMessages()
    local frame = UIErrorsFrame
    if not (frame and frame.SetMessageTypeEnabled) then
        return
    end
    for errorName, kind in pairs(KIND_BY_ERROR) do
        local index = MessageIndex(errorName)
        if index then
            local hide = ns.db.enabled and ns.db.hideDefault and ns.KindEnabled(kind)
            frame:SetMessageTypeEnabled(index, not hide)
        end
    end
end

---------------------------------------------------------------------------
-- Quest log

local GetInfo = C_QuestLog and C_QuestLog.GetInfo
local GetObjectives = C_QuestLog and C_QuestLog.GetQuestObjectives

local function NumEntries()
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
        return (C_QuestLog.GetNumQuestLogEntries())
    end
    return (GetNumQuestLogEntries())
end

-- Calls fn(questID, title, objectives, isComplete) for every quest in the log until fn returns true.
-- objectives: list of { text, type, finished, numFulfilled, numRequired }.
local function ForEachQuest(fn)
    for index = 1, NumEntries() or 0 do
        local title, isHeader, questID, isComplete
        if GetInfo then
            local info = GetInfo(index)
            if info then
                title, isHeader, questID = info.title, info.isHeader, info.questID
                isComplete = questID and C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID)
            end
        else
            local _, complete
            title, _, _, isHeader, _, complete, _, questID = GetQuestLogTitle(index)
            isComplete = complete == 1
        end
        if title and not isHeader then
            local objectives = {}
            if GetObjectives and questID then
                objectives = GetObjectives(questID) or {}
            elseif GetNumQuestLeaderBoards then
                for objective = 1, GetNumQuestLeaderBoards(index) or 0 do
                    local text, objectiveType, finished = GetQuestLogLeaderBoard(objective, index)
                    local have, need = (text or ""):match("(%d+)%s*/%s*(%d+)")
                    objectives[objective] = {
                        text = text, type = objectiveType, finished = finished,
                        numFulfilled = tonumber(have), numRequired = tonumber(need),
                    }
                end
            end
            if not isComplete and #objectives > 0 then
                isComplete = true
                for _, objective in ipairs(objectives) do
                    if not objective.finished then
                        isComplete = false
                        break
                    end
                end
            end
            if fn(questID, title, objectives, isComplete) then
                return
            end
        end
    end
end

-- Finds the quest of an objective by its name (and numbers, if known).
-- Returns a table { questID, title, objective, isComplete, upToDate } or nil.
function ns.FindObjective(name, have, need)
    if not name or name == "" then
        return nil
    end
    local best
    ForEachQuest(function(questID, title, objectives, isComplete)
        for _, objective in ipairs(objectives) do
            local text = objective.text
            if type(text) == "string" and text:find(name, 1, true) then
                local upToDate = have == nil or (objective.numFulfilled == have and objective.numRequired == need)
                local found = {
                    questID = questID, title = title, objective = objective,
                    isComplete = isComplete, upToDate = upToDate,
                }
                if upToDate then
                    best = found
                    return true
                end
                best = best or found
            end
        end
    end)
    return best
end

function ns.FindQuestByTitle(title)
    local found
    ForEachQuest(function(questID, questTitle)
        if questTitle == title then
            found = questID
            return true
        end
    end)
    return found
end

---------------------------------------------------------------------------
-- Icons

local iconCache = {}

local function BagItemIcon(name)
    if not (C_Container and C_Container.GetContainerNumSlots) then
        return nil
    end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local link = info and info.hyperlink
            if link and link:match("%[(.-)%]") == name then
                return info.iconFileID
            end
        end
    end
    return nil
end

function ns.ItemIcon(name)
    if iconCache[name] then
        return iconCache[name]
    end
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local icon = getInfo and select(10, getInfo(name))
    icon = icon or BagItemIcon(name)
    iconCache[name] = icon
    return icon
end

-- True if the current target (or mouseover) is the killed enemy, so its portrait can be shown.
function ns.PortraitUnitFor(name)
    for _, unit in ipairs({ "target", "mouseover" }) do
        local ok, matches = pcall(function()
            local unitName = UnitExists(unit) and UnitName(unit)
            if not unitName or IsSecret(unitName) then
                return false
            end
            return unitName == name
        end)
        if ok and matches then
            return unit
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Turning messages into popups

local announcedQuests = {}

local function ShowQuestComplete(questID, title)
    if not (ns.db.showQuestComplete and questID) or announcedQuests[questID] then
        return
    end
    announcedQuests[questID] = true
    C_Timer.After(0.45, function()
        ns.Cards.Push({
            key = "quest:" .. questID,
            kind = "quest",
            title = L.QUEST_COMPLETE,
            quest = title,
        })
        ns.PlayEventSound(3)
    end)
end
ns.ShowQuestComplete = ShowQuestComplete

-- Fills in the quest name and checks whether the quest is complete now. The quest log may update
-- a moment after the message, so this tries a few times.
local function Enrich(data, attempt)
    attempt = attempt or 1
    local found = ns.FindObjective(data.name, data.have, data.need)
    if found then
        if found.title and found.title ~= data.quest then
            data.quest = found.title
            ns.Cards.Update(data)
        end
        if found.upToDate or attempt >= 3 then
            if found.isComplete then
                ShowQuestComplete(found.questID, found.title)
            elseif found.questID then
                announcedQuests[found.questID] = nil
            end
            return
        end
    end
    if attempt < 3 then
        C_Timer.After(attempt * 0.35, function()
            Enrich(data, attempt + 1)
        end)
    end
end

-- Handles one quest message. Also used by the test sequence (with fake values).
function ns.HandleQuestMessage(errorName, message, testData)
    local kind = KIND_BY_ERROR[errorName]
    if not kind or not ns.db.enabled or not ns.KindEnabled(kind) then
        return
    end
    local name, have, need, title = ns.ParseMessage(errorName, message)
    local data = {
        key = kind .. ":" .. (name or message),
        kind = kind,
        name = name,
        title = title,
        have = have,
        need = need,
    }

    if kind == "failed" then
        data.key = "failed:" .. name
        data.title = L.QUEST_FAILED
        data.quest = name
        data.failed = true
        ns.Cards.Push(data)
        ns.PlayEventSound(2)
        return
    end

    data.done = (have and need and have >= need) or (have == nil)
    if errorName == "ERR_QUEST_UNKNOWN_COMPLETE" then
        data.key = "other:" .. message
    end

    if testData then
        for key, value in pairs(testData) do
            data[key] = value
        end
    elseif ns.db.showIcon then
        if kind == "item" then
            data.icon = ns.ItemIcon(name)
        elseif kind == "kill" then
            data.portraitUnit = ns.PortraitUnitFor(name)
        end
    end

    ns.Cards.Push(data)
    ns.PlayEventSound(data.done and 2 or 1)

    if not testData then
        Enrich(data)
    end
end

local function OnInfoMessage(messageType, message)
    if IsSecret(messageType) or IsSecret(message) or type(message) ~= "string" then
        return
    end
    local ok, errorName = pcall(GetGameMessageInfo, messageType)
    if ok and errorName and KIND_BY_ERROR[errorName] then
        ns.HandleQuestMessage(errorName, message)
    end
end

---------------------------------------------------------------------------
-- Test sequence

function ns.RunTest()
    local itemIcon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(2770)
    local herbIcon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(2447)
    local function Item(name, have, need, quest, icon)
        return function()
            local message = (ERR_QUEST_ADD_ITEM_SII or "%s: %d/%d"):format(name, have, need)
            ns.HandleQuestMessage("ERR_QUEST_ADD_ITEM_SII", message,
                { quest = quest, icon = icon or "Interface\\Icons\\INV_Misc_QuestionMark" })
        end
    end
    local function Kill(name, have, need, quest)
        return function()
            local message = (ERR_QUEST_ADD_KILL_SII or "%s slain: %d/%d"):format(name, have, need)
            ns.HandleQuestMessage("ERR_QUEST_ADD_KILL_SII", message, { quest = quest })
        end
    end
    local steps = {
        { 0.0, Item(L.TEST_ITEM, 1, 8, L.TEST_QUEST_1, itemIcon) },
        { 0.7, Item(L.TEST_ITEM, 2, 8, L.TEST_QUEST_1, itemIcon) },
        { 1.1, Item(L.TEST_ITEM, 3, 8, L.TEST_QUEST_1, itemIcon) },
        { 2.0, Kill(L.TEST_MOB, 6, 10, L.TEST_QUEST_2) },
        { 3.0, Item(L.TEST_HERB, 5, 5, L.TEST_QUEST_3, herbIcon) },
        { 3.6, function()
            if ns.db.showQuestComplete then
                ns.Cards.Push({ key = "quest:test", kind = "quest", title = L.QUEST_COMPLETE, quest = L.TEST_QUEST_3 })
                ns.PlayEventSound(3)
            end
        end },
    }
    for _, step in ipairs(steps) do
        C_Timer.After(step[1], step[2])
    end
end

---------------------------------------------------------------------------
-- Slash command

local function OpenOptions()
    if ns.settingsCategory and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(ns.settingsCategory:GetID())
    end
end

SLASH_QUESTPROGRESSALERT1 = "/qpa"
SLASH_QUESTPROGRESSALERT2 = "/questprogressalert"
SlashCmdList.QUESTPROGRESSALERT = function(input)
    local command = strtrim(input or ""):lower()
    if command == "test" then
        ns.RunTest()
    elseif command == "move" or command == "unlock" then
        ns.Cards.SetUnlocked(not ns.Cards.IsUnlocked())
    elseif command == "reset" then
        ns.ResetPosition()
    elseif command == "" then
        OpenOptions()
    else
        ns.Print(L.SLASH_HELP)
    end
end

function ns.ResetPosition()
    local db, defaults = ns.db, ns.DEFAULTS
    db.point, db.relativePoint, db.x, db.y = defaults.point, defaults.relativePoint, defaults.x, defaults.y
    ns.Cards.ApplySettings()
    ns.Print(L.POSITION_RESET)
end

---------------------------------------------------------------------------
-- Events

local function InitDB()
    QuestProgressAlertDB = QuestProgressAlertDB or {}
    for key, value in pairs(ns.DEFAULTS) do
        if QuestProgressAlertDB[key] == nil then
            QuestProgressAlertDB[key] = value
        end
    end
    ns.db = QuestProgressAlertDB
end

-- Called by the options page and the slash commands after a change.
function ns.SettingsChanged()
    ns.ApplyDefaultMessages()
    ns.Cards.ApplySettings()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "UI_INFO_MESSAGE" then
        if ns.db then
            OnInfoMessage(...)
        end
    elseif event == "ADDON_LOADED" then
        if ... == ADDON then
            InitDB()
        end
    elseif event == "PLAYER_LOGIN" then
        ns.Cards.Init()
        ns.InitOptions()
        ns.ApplyDefaultMessages()
    end
end)
