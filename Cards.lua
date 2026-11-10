local _, ns = ...
local L = ns.L

-- The popups ("cards"): a stack of animated frames below an anchor that can be moved.

local Cards = {}
ns.Cards = Cards

local MEDIA = ns.MEDIA
local PI = math.pi
local sin, min, max, floor, random = math.sin, math.min, math.max, math.floor, math.random

-- Card textures are 256x128 with the shape inside a 24 px padding; the shape is 80 px high.
local CARD_PAD, CARD_SHAPE_H, CARD_CAP = 24, 80, 64
local CARD_CAP_FRACTION = CARD_CAP / 256
local BAR_CAP_FRACTION = 8 / 128
local BAR_HEIGHT = 7

local DEFAULT_ICONS = {
    item = "Interface\\Icons\\INV_Misc_Bag_08",
    kill = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
    other = "Interface\\Icons\\INV_Misc_Note_01",
}

local anchor, mover
local active = {} -- newest first
local pool = {}
local unlocked = false

---------------------------------------------------------------------------
-- Helpers

local function Clamp01(t)
    return t < 0 and 0 or (t > 1 and 1 or t)
end

local function EaseOutCubic(t)
    local u = 1 - t
    return 1 - u * u * u
end

local function EaseOutBack(t)
    local u = t - 1
    return 1 + 2.70158 * u * u * u + 1.70158 * u * u
end

local function EaseInOut(t)
    return t < 0.5 and 2 * t * t or 1 - ((-2 * t + 2) ^ 2) / 2
end

local function NoSnap(texture)
    if texture.SetSnapToPixelGrid then
        texture:SetSnapToPixelGrid(false)
        texture:SetTexelSnappingBias(0)
    end
    return texture
end

local function NewTexture(parent, file, layer, sublevel, blend)
    local texture = NoSnap(parent:CreateTexture(nil, layer, nil, sublevel))
    if file then
        texture:SetTexture(file)
    end
    if blend then
        texture:SetBlendMode(blend)
    end
    return texture
end

-- Three textures (left cap, stretched middle, right cap) so the rounded shapes keep their corners
-- at any width.
local SLICE_PARTS = { "l", "m", "r" }

local function NewSlice(parent, file, layer, sublevel, capFraction, blend)
    local slice = {}
    for _, part in ipairs(SLICE_PARTS) do
        slice[part] = NewTexture(parent, file, layer, sublevel, blend)
    end
    slice.l:SetTexCoord(0, capFraction, 0, 1)
    slice.m:SetTexCoord(capFraction, 1 - capFraction, 0, 1)
    slice.r:SetTexCoord(1 - capFraction, 1, 0, 1)
    return slice
end

local function PlaceSlice(slice, region, outset, cap, offsetY)
    offsetY = offsetY or 0
    for _, part in ipairs(SLICE_PARTS) do
        slice[part]:ClearAllPoints()
    end
    slice.l:SetPoint("TOPLEFT", region, "TOPLEFT", -outset, outset + offsetY)
    slice.l:SetPoint("BOTTOMLEFT", region, "BOTTOMLEFT", -outset, -outset + offsetY)
    slice.l:SetWidth(cap)
    slice.r:SetPoint("TOPRIGHT", region, "TOPRIGHT", outset, outset + offsetY)
    slice.r:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", outset, -outset + offsetY)
    slice.r:SetWidth(cap)
    slice.m:SetPoint("TOPLEFT", slice.l, "TOPRIGHT")
    slice.m:SetPoint("BOTTOMRIGHT", slice.r, "BOTTOMLEFT")
end

local function SliceColor(slice, r, g, b, a)
    for _, part in ipairs(SLICE_PARTS) do
        slice[part]:SetVertexColor(r, g, b, a or 1)
    end
end

local function SliceAlpha(slice, alpha)
    for _, part in ipairs(SLICE_PARTS) do
        slice[part]:SetAlpha(alpha)
    end
end

local function SetFont(fontString, size, flags)
    if not fontString:SetFont(ns.FontPath(), size, flags) then
        fontString:SetFont(STANDARD_TEXT_FONT, size, flags)
    end
    fontString:SetShadowColor(0, 0, 0, 0.9)
    fontString:SetShadowOffset(1, -1)
end

function Cards.Metrics()
    local db = ns.db
    local fontSize = db.fontSize
    local questSize = max(9, floor(fontSize * 0.72 + 0.5))
    local height = 12 + fontSize + (db.showQuestTitle and (questSize + 4) or 0) + (db.showBar and 14 or 6)
    if db.showIcon then
        height = max(height, 46)
    end
    return {
        width = db.width,
        height = height,
        fontSize = fontSize,
        questSize = questSize,
        countSize = fontSize + 4,
        icon = height - 16,
    }
end

local function StateColor(data)
    local db = ns.db
    if data.failed then
        return ns.HexToRGB(db.colorFailed)
    elseif data.kind == "quest" then
        return ns.HexToRGB(db.colorQuest)
    elseif data.done then
        return ns.HexToRGB(db.colorComplete)
    end
    return ns.HexToRGB(db.colorProgress)
end

---------------------------------------------------------------------------
-- Creating a card

local function CreateCard()
    local card = CreateFrame("Frame", nil, anchor)
    card:SetFrameStrata("HIGH")
    card:EnableMouse(false)

    -- The content is centered in the card so scaling it (pop effect) keeps it in place.
    local content = CreateFrame("Frame", nil, card)
    content:SetPoint("CENTER")
    card.content = content
    local level = content:GetFrameLevel()

    card.shadow = NewSlice(content, MEDIA .. "CardGlow", "BACKGROUND", -8, CARD_CAP_FRACTION)
    card.glow = NewSlice(content, MEDIA .. "CardGlow", "BACKGROUND", -7, CARD_CAP_FRACTION, "ADD")
    card.body = NewSlice(content, MEDIA .. "CardBody", "BACKGROUND", 0, CARD_CAP_FRACTION)
    card.gloss = NewSlice(content, MEDIA .. "CardGloss", "BORDER", 0, CARD_CAP_FRACTION, "ADD")
    card.border = NewSlice(content, MEDIA .. "CardBorder", "ARTWORK", 0, CARD_CAP_FRACTION)

    -- Shine sweeping over the card, clipped to it.
    local shineClip = CreateFrame("Frame", nil, content)
    shineClip:SetAllPoints(content)
    shineClip:SetClipsChildren(true)
    shineClip:SetFrameLevel(level + 1)
    card.shine = NewTexture(shineClip, MEDIA .. "Shine", "OVERLAY", 0, "ADD")
    card.shine:Hide()

    -- Icon: the holder stays in place, the inner frame is scaled for the pop.
    local iconHolder = CreateFrame("Frame", nil, content)
    iconHolder:SetFrameLevel(level + 2)
    card.iconHolder = iconHolder
    local iconFrame = CreateFrame("Frame", nil, iconHolder)
    iconFrame:SetPoint("CENTER")
    card.iconFrame = iconFrame
    card.iconGlow = NewTexture(iconFrame, MEDIA .. "Glow", "BACKGROUND", 0, "ADD")
    card.iconGlow:SetPoint("CENTER")
    card.iconBg = NewTexture(iconFrame, MEDIA .. "IconMask", "BORDER", 0)
    card.iconBg:SetAllPoints(iconFrame)
    card.iconBg:SetVertexColor(0, 0, 0, 0.75)
    card.icon = NewTexture(iconFrame, nil, "ARTWORK", 0)
    card.icon:SetAllPoints(iconFrame)
    if iconFrame.CreateMaskTexture then
        local mask = iconFrame:CreateMaskTexture()
        mask:SetTexture(MEDIA .. "IconMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(iconFrame)
        card.icon:AddMaskTexture(mask)
        card.mask = mask
    end
    card.iconBorder = NewTexture(iconFrame, MEDIA .. "IconBorder", "OVERLAY", 0)
    card.iconBorder:SetAllPoints(iconFrame)
    card.symbolShadow = NewTexture(iconFrame, nil, "OVERLAY", 1)
    card.symbol = NewTexture(iconFrame, nil, "OVERLAY", 2)
    card.badgeShadow = NewTexture(iconFrame, MEDIA .. "Check", "OVERLAY", 3)
    card.badgeShadow:SetVertexColor(0, 0, 0, 0.85)
    card.badge = NewTexture(iconFrame, MEDIA .. "Check", "OVERLAY", 4)
    card.ring = NewTexture(iconHolder, MEDIA .. "Ring", "OVERLAY", 5, "ADD")
    card.ring:SetPoint("CENTER")
    card.ring:Hide()

    -- Progress bar: the fill is a full-width texture inside a clip frame that grows.
    local bar = CreateFrame("Frame", nil, content)
    bar:SetFrameLevel(level + 2)
    card.bar = bar
    card.barTrack = NewSlice(bar, MEDIA .. "BarTrack", "BACKGROUND", 0, BAR_CAP_FRACTION)
    SliceColor(card.barTrack, 0, 0, 0, 0.65)
    local fillClip = CreateFrame("Frame", nil, bar)
    fillClip:SetPoint("TOPLEFT")
    fillClip:SetPoint("BOTTOMLEFT")
    fillClip:SetWidth(1)
    fillClip:SetClipsChildren(true)
    card.fillClip = fillClip
    card.barFill = NewSlice(fillClip, MEDIA .. "Bar", "ARTWORK", 0, BAR_CAP_FRACTION)
    card.spark = NewTexture(bar, MEDIA .. "Spark", "OVERLAY", 0, "ADD")
    card.spark:SetSize(12, 22)
    card.spark:SetPoint("CENTER", fillClip, "RIGHT", 0, 0)

    -- Texts
    local textFrame = CreateFrame("Frame", nil, content)
    textFrame:SetAllPoints(content)
    textFrame:SetFrameLevel(level + 3)
    card.name = textFrame:CreateFontString(nil, "OVERLAY")
    card.name:SetFontObject(GameFontNormal)
    card.name:SetJustifyH("LEFT")
    card.name:SetWordWrap(false)
    card.quest = textFrame:CreateFontString(nil, "OVERLAY")
    card.quest:SetFontObject(GameFontNormalSmall)
    card.quest:SetJustifyH("LEFT")
    card.quest:SetWordWrap(false)
    card.countHolder = CreateFrame("Frame", nil, textFrame)
    card.countFrame = CreateFrame("Frame", nil, card.countHolder)
    card.countFrame:SetPoint("CENTER")
    card.count = card.countFrame:CreateFontString(nil, "OVERLAY")
    card.count:SetFontObject(GameFontNormalLarge)
    card.count:SetPoint("CENTER")
    card.plus = textFrame:CreateFontString(nil, "OVERLAY")
    card.plus:SetFontObject(GameFontNormal)
    card.plus:Hide()

    -- Sparkles
    card.particleFrame = CreateFrame("Frame", nil, content)
    card.particleFrame:SetAllPoints(content)
    card.particleFrame:SetFrameLevel(level + 5)
    card.particles = {}

    card:SetScript("OnUpdate", Cards.OnUpdate)
    return card
end

---------------------------------------------------------------------------
-- Look and content

local function ApplyStyle(card)
    local db = ns.db
    local m = Cards.Metrics()
    local width, height = m.width, m.height
    card.metrics = m

    card:SetScale(db.scale)
    card:SetSize(width, height)
    card.content:SetSize(width, height)

    local s = height / CARD_SHAPE_H
    local outset, cap = CARD_PAD * s, CARD_CAP * s
    PlaceSlice(card.shadow, card.content, outset, cap, -3)
    PlaceSlice(card.glow, card.content, outset, cap)
    PlaceSlice(card.body, card.content, outset, cap)
    PlaceSlice(card.gloss, card.content, outset, cap)
    PlaceSlice(card.border, card.content, outset, cap)
    SliceColor(card.shadow, 0, 0, 0, 0.7 * db.bgAlpha)
    SliceColor(card.body, 0.05, 0.06, 0.09, db.bgAlpha)
    SliceColor(card.gloss, 1, 1, 1, 0.09)

    local textLeft = 16
    card.iconHolder:SetShown(db.showIcon)
    if db.showIcon then
        local size = m.icon
        card.iconHolder:ClearAllPoints()
        card.iconHolder:SetPoint("LEFT", card.content, "LEFT", 8, 0)
        card.iconHolder:SetSize(size, size)
        card.iconFrame:SetSize(size, size)
        card.iconGlow:SetSize(size * 2, size * 2)
        card.symbolShadow:ClearAllPoints()
        card.symbolShadow:SetPoint("CENTER", 1, -2)
        card.symbolShadow:SetSize(size * 0.85, size * 0.85)
        card.symbol:ClearAllPoints()
        card.symbol:SetPoint("CENTER")
        card.symbol:SetSize(size * 0.85, size * 0.85)
        local badge = size * 0.62
        card.badge:ClearAllPoints()
        card.badge:SetPoint("BOTTOMRIGHT", card.iconFrame, "BOTTOMRIGHT", badge * 0.3, -badge * 0.25)
        card.badge:SetSize(badge, badge)
        card.badgeShadow:ClearAllPoints()
        card.badgeShadow:SetPoint("CENTER", card.badge, "CENTER", 1, -1.5)
        card.badgeShadow:SetSize(badge * 1.15, badge * 1.15)
        textLeft = 8 + size + 11
    end
    card.textLeft = textLeft

    SetFont(card.name, m.fontSize, "OUTLINE")
    SetFont(card.quest, m.questSize, "")
    SetFont(card.count, m.countSize, "OUTLINE")
    SetFont(card.plus, m.fontSize, "OUTLINE")

    card.countHolder:ClearAllPoints()
    card.countHolder:SetPoint("TOPRIGHT", card.content, "TOPRIGHT", -14, -7)
    card.name:ClearAllPoints()
    card.name:SetPoint("TOPLEFT", card.content, "TOPLEFT", textLeft, -10)
    card.name:SetPoint("RIGHT", card.countHolder, "LEFT", -8, 0)
    card.quest:ClearAllPoints()
    card.quest:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -3)
    card.quest:SetPoint("RIGHT", card.content, "RIGHT", -14, 0)

    card.bar:ClearAllPoints()
    card.bar:SetPoint("BOTTOMLEFT", card.content, "BOTTOMLEFT", textLeft, 9)
    card.bar:SetPoint("BOTTOMRIGHT", card.content, "BOTTOMRIGHT", -14, 9)
    card.bar:SetHeight(BAR_HEIGHT)
    PlaceSlice(card.barTrack, card.bar, 0, BAR_HEIGHT / 2)
    PlaceSlice(card.barFill, card.bar, 0, BAR_HEIGHT / 2)

    card.shine:SetSize(height * 1.6, height)
end

-- Enemy portraits are textures kept by ns.Portraits; a card borrows one while it shows it.
local Refresh

local function DetachPortrait(card)
    local entry = card.portraitEntry
    if not entry then
        return
    end
    card.portraitEntry = nil
    if entry.card == card then
        ns.Portraits.Return(entry)
    end
end

local function AttachPortrait(card, entry)
    if card.portraitEntry == entry and entry.card == card then
        return
    end
    DetachPortrait(card)
    local other = entry.card
    if other and other ~= card then
        -- Another card shows the same enemy: it falls back to its normal icon.
        DetachPortrait(other)
        if other.data then
            other.data.portrait = nil
            Refresh(other)
        end
    end
    local texture = entry.tex
    texture:SetParent(card.iconFrame)
    texture:SetDrawLayer("ARTWORK", 1)
    texture:ClearAllPoints()
    texture:SetAllPoints(card.iconFrame)
    texture:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    if card.mask then
        texture:AddMaskTexture(card.mask)
        entry.mask = card.mask
    end
    texture:Show()
    entry.card = card
    card.portraitEntry = entry
end

function Refresh(card)
    local db = ns.db
    local data = card.data
    local m = card.metrics
    local r, g, b = StateColor(data)
    card.r, card.g, card.b = r, g, b
    local headline = data.kind == "quest" or data.failed

    SliceColor(card.border, r, g, b, 0.95)
    SliceColor(card.glow, r, g, b, 1)
    card.iconGlow:SetVertexColor(r, g, b, 1)
    card.ring:SetVertexColor(r, g, b, 1)
    card.iconBorder:SetVertexColor(r, g, b, 0.95)

    -- Texts
    card.name:SetText(data.title or "")
    if headline then
        SetFont(card.name, m.fontSize + 3, "OUTLINE")
        card.name:SetTextColor(r, g, b)
    else
        SetFont(card.name, m.fontSize, "OUTLINE")
        card.name:SetTextColor(1, 1, 1)
    end
    local questText = data.quest
    local showQuest = questText and questText ~= "" and (db.showQuestTitle or headline)
    card.quest:SetShown(showQuest and true or false)
    card.quest:SetText(showQuest and questText or "")
    if headline then
        card.quest:SetTextColor(1, 1, 1)
    else
        card.quest:SetTextColor(0.74, 0.8, 0.88)
    end

    if data.have and data.need then
        card.count:SetText(data.have .. "/" .. data.need)
        card.count:SetTextColor(r, g, b)
        card.count:Show()
        local w, h = card.count:GetStringWidth() + 2, m.countSize + 4
        card.countHolder:SetSize(w, h)
        card.countFrame:SetSize(w, h)
    else
        card.count:SetText("")
        card.count:Hide()
        card.countHolder:SetSize(0.1, m.countSize + 4)
    end
    card.plus:SetTextColor(r, g, b)

    -- Progress bar
    local showBar = db.showBar and not headline and (data.need or data.done) and true or false
    card.bar:SetShown(showBar)
    card.targetFill = data.need and data.need > 0 and Clamp01((data.have or 0) / data.need) or 1
    SliceColor(card.barFill, r, g, b, 1)

    -- Icon
    if db.showIcon then
        card.symbol:Hide()
        card.symbolShadow:Hide()
        card.icon:Show()
        card.iconBg:Show()
        card.iconBorder:Show()
        local portrait = not headline and db.showPortraits and data.portrait
        if portrait then
            AttachPortrait(card, portrait)
            card.icon:Hide()
        else
            DetachPortrait(card)
        end
        if headline then
            local file = MEDIA .. (data.failed and "Cross" or "Check")
            card.icon:Hide()
            card.iconBg:Hide()
            card.iconBorder:Hide()
            card.symbol:SetTexture(file)
            card.symbol:SetVertexColor(r, g, b)
            card.symbolShadow:SetTexture(file)
            card.symbolShadow:SetVertexColor(0, 0, 0, 0.85)
            card.symbol:Show()
            card.symbolShadow:Show()
        elseif not portrait then
            card.icon:SetTexture(data.icon or DEFAULT_ICONS[data.kind] or DEFAULT_ICONS.item)
            card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        local showBadge = data.done and not headline and true or false
        card.badge:SetShown(showBadge)
        card.badgeShadow:SetShown(showBadge)
        card.badge:SetVertexColor(r, g, b)
    end
end

---------------------------------------------------------------------------
-- Effects

local function StartShine(card)
    if ns.db.animations then
        card.shineT = 0
        card.shine:Show()
    end
end

local function SpawnParticles(card, amount, spread)
    if not (ns.db.particles and ns.db.animations) then
        return
    end
    local m = card.metrics
    local originX = ns.db.showIcon and (-m.width / 2 + 8 + m.icon / 2) or (-m.width / 2 + 30)
    for _ = 1, amount do
        local particle
        for _, existing in ipairs(card.particles) do
            if not existing.t then
                particle = existing
                break
            end
        end
        if not particle then
            particle = { tex = NewTexture(card.particleFrame, MEDIA .. "Star", "OVERLAY", 7, "ADD") }
            card.particles[#card.particles + 1] = particle
        end
        local angle = random() * 2 * PI
        local speed = (50 + random() * 70) * spread
        particle.t = 0
        particle.duration = 0.6 + random() * 0.5
        particle.x, particle.y = originX, 0
        particle.vx, particle.vy = math.cos(angle) * speed * 1.6, math.sin(angle) * speed
        particle.spin = (random() - 0.5) * 8
        particle.size = 8 + random() * 12
        local tint = random()
        particle.tex:SetVertexColor(card.r + (1 - card.r) * tint, card.g + (1 - card.g) * tint, card.b + (1 - card.b) * tint)
        particle.tex:SetSize(particle.size, particle.size)
        particle.tex:Show()
    end
end

local function StartComplete(card, big)
    card.flash = 1
    if ns.db.animations then
        card.ringT = 0
        card.ring:Show()
    end
    SpawnParticles(card, big and 22 or 12, big and 1.7 or 1)
    StartShine(card)
end

local function StartBump(card, delta)
    card.flash = max(card.flash or 0, 0.7)
    if ns.db.animations then
        card.bumpT = 0
        StartShine(card)
        if delta and delta > 0 then
            card.plus:SetText("+" .. delta)
            card.plusT = 0
            card.plus:Show()
        end
    end
end

---------------------------------------------------------------------------
-- Stack

local function Layout()
    local db = ns.db
    local index = 0
    for _, card in ipairs(active) do
        if not card.leaving then
            local offset = index * (card.metrics.height + db.spacing)
            card.targetY = db.grow == "UP" and offset or -offset
            if not card.y then
                card.y = card.targetY
            end
            index = index + 1
        end
    end
end

local function Release(card)
    for index, other in ipairs(active) do
        if other == card then
            table.remove(active, index)
            break
        end
    end
    card:Hide()
    DetachPortrait(card)
    card.data = nil
    for _, particle in ipairs(card.particles) do
        particle.t = nil
        particle.tex:Hide()
    end
    pool[#pool + 1] = card
end

local function StartLeaving(card, duration)
    if not card.leaving then
        card.leaving = true
        card.outT = 0
        card.outDuration = max(0.05, duration)
    end
end

-- Too many cards: the oldest ones fade out quickly.
local function Trim()
    local visible = 0
    for _, card in ipairs(active) do
        if not card.leaving then
            visible = visible + 1
            if visible > ns.db.maxCards then
                StartLeaving(card, 0.25)
            end
        end
    end
end

local function FindByKey(key)
    for index, card in ipairs(active) do
        if card.data and card.data.key == key then
            return card, index
        end
    end
end

local function Acquire()
    local card = table.remove(pool) or CreateCard()
    card.y, card.targetY = nil, nil
    card.leaving, card.outT = nil, nil
    card.bumpT, card.shineT, card.ringT, card.plusT = nil, nil, nil, nil
    card.flash = 0.6
    card.age = 0
    card.shine:Hide()
    card.ring:Hide()
    card.plus:Hide()
    card:SetAlpha(0)
    ApplyStyle(card)
    card:Show()
    return card
end

function Cards.Push(data)
    if not anchor or not ns.db.enabled then
        return
    end
    local card, index = FindByKey(data.key)
    local old = card and card.data
    if card then
        table.remove(active, index)
        if card.leaving then
            card.leaving, card.outT = nil, nil
        end
        table.insert(active, 1, card)
        -- Keep the portrait found for this objective before (e.g. through Questie).
        if data.portrait == nil and old.portrait then
            data.portrait = old.portrait
        end
        card.data = data
        local delta = data.have and old.have and data.have - old.have
        StartBump(card, delta)
    else
        card = Acquire()
        card.data = data
        table.insert(active, 1, card)
        -- The bar starts a step below, so the new progress fills in visibly.
        card.shownFill = (data.have and data.need and data.need > 0) and Clamp01((data.have - 1) / data.need) or 0
        StartShine(card)
    end

    Refresh(card)

    local headline = data.kind == "quest" or data.failed
    if (data.done and not (old and old.done)) or headline then
        StartComplete(card, headline)
    end

    local db = ns.db
    card.life = (data.done or headline) and db.durationComplete or db.duration

    Trim()
    Layout()
end

-- Updates the texts of a card (e.g. the quest name found a moment later) without effects.
function Cards.Update(data)
    local card = FindByKey(data.key)
    if card then
        card.data.quest = data.quest
        card.data.portrait = data.portrait or card.data.portrait
        Refresh(card)
    end
end

function Cards.Clear()
    for index = #active, 1, -1 do
        Release(active[index])
    end
end

---------------------------------------------------------------------------
-- Animation

function Cards.OnUpdate(card, elapsed)
    if not card.data then
        return
    end
    local db = ns.db
    local animate = db.animations
    local m = card.metrics
    card.age = card.age + elapsed

    -- Appear: fade in, slide in from the left, scale up with a little overshoot.
    local appear = animate and Clamp01(card.age / 0.4) or 1
    local alpha = EaseOutCubic(appear)
    local slideX = animate and (1 - EaseOutCubic(appear)) * -45 or 0
    local scale = animate and (0.75 + 0.25 * EaseOutBack(appear)) or 1

    -- Pop when the same objective makes progress again.
    local iconScale, countScale = 1, 1
    if card.bumpT then
        card.bumpT = card.bumpT + elapsed
        local p = card.bumpT / 0.35
        if p >= 1 then
            card.bumpT = nil
        else
            local wave = sin(p * PI)
            scale = scale + wave * 0.05
            iconScale = 1 + wave * 0.3
            countScale = 1 + wave * 0.5
        end
    end

    -- Lifetime and fade-out
    if not card.leaving and not unlocked then
        card.life = card.life - elapsed
        if card.life <= 0 then
            StartLeaving(card, db.fadeDuration)
            Layout()
        end
    end
    if card.leaving then
        card.outT = card.outT + elapsed
        local p = Clamp01(card.outT / card.outDuration)
        alpha = alpha * (1 - p * p)
        if animate then
            slideX = slideX + 35 * p * p
        end
        if p >= 1 then
            Release(card)
            Layout()
            return
        end
    end

    -- Sliding to the place in the stack
    if card.targetY then
        if animate then
            card.y = card.y + (card.targetY - card.y) * min(1, elapsed * 12)
        else
            card.y = card.targetY
        end
    end
    card:ClearAllPoints()
    if db.grow == "UP" then
        card:SetPoint("BOTTOM", anchor, "BOTTOM", slideX, card.y or 0)
    else
        card:SetPoint("TOP", anchor, "TOP", slideX, card.y or 0)
    end
    card:SetAlpha(alpha)
    card.content:SetScale(max(0.01, scale))
    card.iconFrame:SetScale(iconScale)
    card.countFrame:SetScale(countScale)

    -- Glow: base strength, a flash on every update, a soft pulse while complete.
    card.flash = max(0, (card.flash or 0) - elapsed * 1.4)
    local pulse = 0
    if animate and (card.data.done or card.data.kind == "quest") then
        pulse = 0.15 * (0.5 + 0.5 * sin(card.age * 4))
    end
    local glow = db.glow
    SliceAlpha(card.glow, Clamp01(glow * (0.55 + pulse + card.flash * 0.8)))
    card.iconGlow:SetAlpha(Clamp01(glow * (0.45 + pulse + card.flash * 0.7)))

    -- Bar
    if card.bar:IsShown() then
        local target = card.targetFill or 0
        local shown = card.shownFill or 0
        if animate then
            shown = shown + (target - shown) * min(1, elapsed * 6)
            if math.abs(target - shown) < 0.001 then
                shown = target
            end
        else
            shown = target
        end
        card.shownFill = shown
        local barWidth = card.bar:GetWidth()
        card.fillClip:SetWidth(max(0.5, barWidth * shown))
        card.spark:SetShown(shown > 0.01)
        card.spark:SetAlpha(min(1, 0.35 + math.abs(target - shown) * 10 + card.flash * 0.5))
    end

    -- Shine
    if card.shineT then
        card.shineT = card.shineT + elapsed
        local p = card.shineT / 0.85
        if p >= 1 then
            card.shineT = nil
            card.shine:Hide()
        else
            local travel = m.width + m.height * 3.2
            card.shine:ClearAllPoints()
            card.shine:SetPoint("CENTER", card.content, "LEFT", -m.height * 1.6 + travel * EaseInOut(p), 0)
            card.shine:SetAlpha(0.45 * sin(p * PI))
        end
    end

    -- Ring burst around the icon
    if card.ringT then
        card.ringT = card.ringT + elapsed
        local p = card.ringT / 0.6
        if p >= 1 or not db.showIcon then
            card.ringT = nil
            card.ring:Hide()
        else
            local size = m.icon * (1 + 1.5 * EaseOutCubic(p))
            card.ring:SetSize(size, size)
            card.ring:SetAlpha(0.95 * (1 - p))
        end
    end

    -- "+N" rising from the counter
    if card.plusT then
        card.plusT = card.plusT + elapsed
        local p = card.plusT / 0.9
        if p >= 1 then
            card.plusT = nil
            card.plus:Hide()
        else
            card.plus:ClearAllPoints()
            card.plus:SetPoint("BOTTOMRIGHT", card.countHolder, "TOPRIGHT", 0, -6 + 18 * EaseOutCubic(p))
            card.plus:SetAlpha(1 - p * p)
        end
    end

    -- Sparkles
    for _, particle in ipairs(card.particles) do
        if particle.t then
            particle.t = particle.t + elapsed
            local p = particle.t / particle.duration
            if p >= 1 then
                particle.t = nil
                particle.tex:Hide()
            else
                local drag = 1 - p * 0.55
                local x = particle.x + particle.vx * particle.t * drag
                local y = particle.y + particle.vy * particle.t * drag
                particle.tex:ClearAllPoints()
                particle.tex:SetPoint("CENTER", card.particleFrame, "CENTER", x, y)
                particle.tex:SetRotation(particle.spin * particle.t)
                particle.tex:SetAlpha((1 - p) ^ 1.4)
                local size = particle.size * (1 - p * 0.5)
                particle.tex:SetSize(size, size)
            end
        end
    end
end

---------------------------------------------------------------------------
-- Anchor and mover

local function SavePosition()
    local point, _, relativePoint, x, y = anchor:GetPoint(1)
    local db = ns.db
    db.point, db.relativePoint, db.x, db.y = point, relativePoint, floor(x + 0.5), floor(y + 0.5)
end

local function PlaceAnchor()
    local db = ns.db
    local m = Cards.Metrics()
    anchor:SetSize(m.width * db.scale, m.height * db.scale)
    anchor:ClearAllPoints()
    anchor:SetPoint(db.point, UIParent, db.relativePoint, db.x, db.y)
end

local function CreateMover()
    mover = CreateFrame("Frame", nil, anchor)
    mover:SetAllPoints(anchor)
    mover:SetFrameStrata("DIALOG")
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    mover.body = NewSlice(mover, MEDIA .. "CardBody", "BACKGROUND", 0, CARD_CAP_FRACTION)
    mover.border = NewSlice(mover, MEDIA .. "CardBorder", "ARTWORK", 0, CARD_CAP_FRACTION)
    mover.glow = NewSlice(mover, MEDIA .. "CardGlow", "BACKGROUND", -1, CARD_CAP_FRACTION, "ADD")
    mover.title = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    mover.title:SetPoint("BOTTOM", mover, "CENTER", 0, 1)
    mover.title:SetText(L.TITLE)
    mover.hint = mover:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mover.hint:SetPoint("TOP", mover, "CENTER", 0, -3)
    mover.hint:SetText(L.MOVER_HINT)
    mover:SetScript("OnDragStart", function()
        anchor:StartMoving()
    end)
    mover:SetScript("OnDragStop", function()
        anchor:StopMovingOrSizing()
        if anchor.SetUserPlaced then
            anchor:SetUserPlaced(false)
        end
        SavePosition()
    end)
    mover:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            Cards.SetUnlocked(false)
        end
    end)
    mover:Hide()
end

local function StyleMover()
    local height = anchor:GetHeight()
    local s = height / CARD_SHAPE_H
    for _, slice in ipairs({ mover.body, mover.border, mover.glow }) do
        PlaceSlice(slice, mover, CARD_PAD * s, CARD_CAP * s)
    end
    local r, g, b = ns.HexToRGB(ns.db.colorProgress)
    SliceColor(mover.body, 0.05, 0.06, 0.09, 0.8)
    SliceColor(mover.border, r, g, b, 1)
    SliceColor(mover.glow, r, g, b, 0.8)
end

function Cards.IsUnlocked()
    return unlocked
end

function Cards.SetUnlocked(value)
    unlocked = value and true or false
    StyleMover()
    mover:SetShown(unlocked)
end

---------------------------------------------------------------------------
-- Setup

function Cards.ApplySettings()
    if not anchor then
        return
    end
    PlaceAnchor()
    StyleMover()
    if not ns.db.enabled then
        Cards.Clear()
        return
    end
    for _, card in ipairs(active) do
        ApplyStyle(card)
        Refresh(card)
    end
    Trim()
    Layout()
end

-- Shows a sample card while the options are changed, so the effect is visible right away.
function Cards.Preview()
    if not anchor or not ns.db.enabled then
        return
    end
    local _, existing = FindByKey("preview")
    if #active > 0 and not existing then
        return
    end
    local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(2770)
    Cards.Push({
        key = "preview",
        kind = "item",
        title = L.TEST_ITEM,
        name = L.TEST_ITEM,
        have = 3,
        need = 8,
        quest = L.TEST_QUEST_1,
        icon = icon,
    })
end

function Cards.Init()
    anchor = CreateFrame("Frame", "QuestProgressAlertAnchor", UIParent)
    anchor:SetFrameStrata("HIGH")
    anchor:SetMovable(true)
    anchor:SetClampedToScreen(true)
    CreateMover()
    PlaceAnchor()
    StyleMover()
end
