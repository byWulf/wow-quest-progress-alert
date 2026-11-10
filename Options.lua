local _, ns = ...
local L = ns.L

-- Options page in Blizzard's settings (Options > AddOns > Quest Progress Alert).

-- Settings that change the look show a sample popup, so the change is visible right away.
local PREVIEW_KEYS = {
    scale = true, width = true, spacing = true, font = true, fontSize = true, bgAlpha = true, glow = true,
    showIcon = true, showBar = true, showQuestTitle = true, colorProgress = true,
}

local function OnChanged(setting)
    ns.SettingsChanged()
    local key = setting and setting.GetVariable and setting:GetVariable()
    key = key and key:gsub("^QuestProgressAlert_", "")
    if key and PREVIEW_KEYS[key] then
        ns.Cards.Preview()
    end
end

function ns.InitOptions()
    if ns.settingsCategory or not (Settings and Settings.RegisterVerticalLayoutCategory) then
        return
    end
    local category, layout = Settings.RegisterVerticalLayoutCategory(L.TITLE)
    layout = layout or SettingsPanel:GetLayout(category)

    local function Header(text)
        if CreateSettingsListSectionHeaderInitializer then
            layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
        end
    end

    local function Register(key, varType, label, callback)
        local setting = Settings.RegisterAddOnSetting(category, "QuestProgressAlert_" .. key, key, ns.db,
            varType, label, ns.DEFAULTS[key])
        setting:SetValueChangedCallback(callback or OnChanged)
        return setting
    end

    local function Checkbox(key, label, tooltip)
        return Settings.CreateCheckbox(category, Register(key, Settings.VarType.Bool, label), tooltip)
    end

    local function Slider(key, label, minValue, maxValue, step, format, tooltip)
        local options = Settings.CreateSliderOptions(minValue, maxValue, step)
        if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
            options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, format)
        end
        return Settings.CreateSlider(category, Register(key, Settings.VarType.Number, label), options, tooltip)
    end

    local function Dropdown(key, label, list, tooltip, callback)
        local function GetOptions()
            local container = Settings.CreateControlTextContainer()
            for _, entry in ipairs(list) do
                container:Add(entry.key, entry.label)
            end
            return container:GetData()
        end
        return Settings.CreateDropdown(category, Register(key, Settings.VarType.String, label, callback), GetOptions,
            tooltip)
    end

    local function Color(key, label, tooltip)
        return Settings.CreateColorSwatch(category, Register(key, Settings.VarType.String, label), tooltip)
    end

    local function Button(label, buttonText, onClick, tooltip)
        if CreateSettingsButtonInitializer then
            layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, onClick, tooltip, true))
        end
    end

    -- Greys out a control while its checkbox is off.
    local function DependsOn(initializer, parent, key)
        if initializer and parent and initializer.SetParentInitializer then
            initializer:SetParentInitializer(parent, function()
                return ns.db[key]
            end)
        end
    end

    local function Seconds(value)
        return L.SECONDS:format(value)
    end
    local function Percent(value)
        return floor(value * 100 + 0.5) .. " %"
    end
    local function Pixels(value)
        return floor(value + 0.5) .. " px"
    end
    local function Number(value)
        return tostring(floor(value + 0.5))
    end

    Header(L.OPT_HEADER_GENERAL)
    Checkbox("enabled", L.OPT_ENABLED, L.OPT_ENABLED_TIP)
    Checkbox("showItems", L.OPT_SHOW_ITEMS, L.OPT_SHOW_ITEMS_TIP)
    Checkbox("showKills", L.OPT_SHOW_KILLS, L.OPT_SHOW_KILLS_TIP)
    Checkbox("showOther", L.OPT_SHOW_OTHER, L.OPT_SHOW_OTHER_TIP)
    Checkbox("showQuestComplete", L.OPT_SHOW_QUEST, L.OPT_SHOW_QUEST_TIP)
    Checkbox("showFailed", L.OPT_SHOW_FAILED, L.OPT_SHOW_FAILED_TIP)
    Checkbox("hideDefault", L.OPT_HIDE_DEFAULT, L.OPT_HIDE_DEFAULT_TIP)
    Button(L.OPT_TEST, L.BTN_TEST, function()
        ns.RunTest()
    end, L.OPT_TEST_TIP)

    Header(L.OPT_HEADER_TIMING)
    Slider("duration", L.OPT_DURATION, 1, 20, 0.5, Seconds, L.OPT_DURATION_TIP)
    Slider("durationComplete", L.OPT_DURATION_COMPLETE, 1, 30, 0.5, Seconds, L.OPT_DURATION_COMPLETE_TIP)
    Slider("fadeDuration", L.OPT_FADE, 0.1, 3, 0.1, Seconds, L.OPT_FADE_TIP)

    Header(L.OPT_HEADER_LAYOUT)
    Slider("maxCards", L.OPT_MAX, 1, 10, 1, Number, L.OPT_MAX_TIP)
    Dropdown("grow", L.OPT_GROW, {
        { key = "DOWN", label = L.GROW_DOWN },
        { key = "UP", label = L.GROW_UP },
    }, L.OPT_GROW_TIP)
    Slider("scale", L.OPT_SCALE, 0.5, 2, 0.05, Percent)
    Slider("width", L.OPT_WIDTH, 220, 600, 10, Pixels)
    Slider("spacing", L.OPT_SPACING, 0, 40, 1, Pixels)
    Button(L.OPT_POSITION, L.BTN_MOVE, function()
        ns.Cards.SetUnlocked(not ns.Cards.IsUnlocked())
    end, L.OPT_POSITION_TIP)
    Button(L.OPT_RESET, L.BTN_RESET, function()
        ns.ResetPosition()
    end)

    Header(L.OPT_HEADER_LOOK)
    Dropdown("font", L.OPT_FONT, ns.FONTS)
    Slider("fontSize", L.OPT_FONT_SIZE, 10, 30, 1, Number)
    Slider("bgAlpha", L.OPT_BG_ALPHA, 0, 1, 0.05, Percent)
    Slider("glow", L.OPT_GLOW, 0, 1, 0.05, Percent)
    local showIcon = Checkbox("showIcon", L.OPT_SHOW_ICON, L.OPT_SHOW_ICON_TIP)
    local portraits = Checkbox("showPortraits", L.OPT_SHOW_PORTRAITS, L.OPT_SHOW_PORTRAITS_TIP)
    DependsOn(portraits, showIcon, "showIcon")
    DependsOn(Checkbox("useQuestie", L.OPT_USE_QUESTIE, L.OPT_USE_QUESTIE_TIP), portraits, "showPortraits")
    Checkbox("showBar", L.OPT_SHOW_BAR)
    Checkbox("showQuestTitle", L.OPT_SHOW_QUEST_TITLE, L.OPT_SHOW_QUEST_TITLE_TIP)
    local animations = Checkbox("animations", L.OPT_ANIMATIONS, L.OPT_ANIMATIONS_TIP)
    DependsOn(Checkbox("particles", L.OPT_PARTICLES), animations, "animations")
    Color("colorProgress", L.OPT_COLOR_PROGRESS)
    Color("colorComplete", L.OPT_COLOR_COMPLETE)
    Color("colorQuest", L.OPT_COLOR_QUEST)
    Color("colorFailed", L.OPT_COLOR_FAILED)

    Header(L.OPT_HEADER_SOUND)
    local function PlayOnPick(setting, value)
        ns.PlaySoundKey(value)
    end
    local progress = Checkbox("soundProgress", L.OPT_SOUND_PROGRESS)
    DependsOn(Dropdown("soundProgressFile", L.OPT_SOUND_PROGRESS_FILE, ns.SOUNDS, L.OPT_SOUND_FILE_TIP, PlayOnPick),
        progress, "soundProgress")
    local objective = Checkbox("soundObjective", L.OPT_SOUND_OBJECTIVE)
    DependsOn(Dropdown("soundObjectiveFile", L.OPT_SOUND_OBJECTIVE_FILE, ns.SOUNDS, L.OPT_SOUND_FILE_TIP, PlayOnPick),
        objective, "soundObjective")
    local quest = Checkbox("soundQuest", L.OPT_SOUND_QUEST)
    DependsOn(Dropdown("soundQuestFile", L.OPT_SOUND_QUEST_FILE, ns.SOUNDS, L.OPT_SOUND_FILE_TIP, PlayOnPick),
        quest, "soundQuest")
    Dropdown("soundChannel", L.OPT_SOUND_CHANNEL, ns.CHANNELS, L.OPT_SOUND_CHANNEL_TIP)

    Settings.RegisterAddOnCategory(category)
    ns.settingsCategory = category
end
