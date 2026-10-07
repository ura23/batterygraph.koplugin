-- v1.1: inlined tr/trn localization helpers (en/uk); dropped the batterygraph_i18n module.
-- v1.0: 12/24-hour clock support (global twelve_hour_clock setting + toggle in the
--       display-mode dialog), time labels and dashed guides at charge-state turning
--       points.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local datetime = require("datetime")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TitleBar = require("ui/widget/titlebar")
local Widget = require("ui/widget/widget")
local Size = require("ui/size")
local T = require("ffi/util").template
local VerticalGroup = require("ui/widget/verticalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local Screen = Device.screen

-- ── Localization (en/uk) ────────────────────────────────────────────
-- Language is read from G_reader_settings:readSetting("language"); any
-- locale other than "uk*" falls back to English.
local function is_uk_language()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    return type(lang) == "string" and lang:sub(1, 2) == "uk"
end

--- Pick the English or Ukrainian variant of a string.
local function tr(en, uk)
    if is_uk_language() then
        return uk or en
    end
    return en
end

--- Ukrainian-aware plural selection (kept for plural strings).
local function trn(n, en1, enN, uk1, ukFew, ukMany)
    if is_uk_language() then
        local n10 = n % 10
        local n100 = n % 100
        if n10 == 1 and n100 ~= 11 then
            return uk1
        elseif n10 >= 2 and n10 <= 4 and (n100 < 12 or n100 > 14) then
            return ukFew
        else
            return ukMany
        end
    end
    return (n == 1) and en1 or enN
end

-- КЕШУВАННЯ ФУНКЦІЙ ДЛЯ ПРИСКОРЕННЯ (Upvalues)
local math_abs = math.abs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local os_date = os.date

-- Максимум підписів біля точок перегину (щоб не захаращувати графік).
local MAX_TURNING_LABELS = 20

-- Статичні рівні сітки
local PCT_LEVELS = {25, 50, 75, 100}

-- Статичні розміри відступів графіку
local PAD_LEFT   = Size.padding.large * 5
local PAD_RIGHT  = Size.padding.large * 2
local PAD_TOP    = Size.padding.large * 2
local PAD_BOTTOM = Size.padding.large * 4
local INNER_PAD  = Size.padding.default
local DOT_MARGIN = Size.padding.large

-- true, якщо ввімкнено глобальний 12-годинний формат KOReader.
local function is_twelve_hour()
    return G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock")
end

-- Формат дати й часу з урахуванням 12/24-годинного формату.
local function formatDateTime(ts)
    return os_date("%d.%m", ts) .. " " .. datetime.secondsToHour(ts, is_twelve_hour())
end

local CanvasWidget = Widget:extend{
    history = {},
    dimen   = nil,
    -- X-координати вертикальних пунктирів у точках перегину (заповнює battery graph).
    turning_x = {},
}

local function drawLine(bb, x0, y0, x1, y1, thickness, color)
    local offset = math_floor(thickness / 2)
    
    -- Fast-path для горизонтальних та вертикальних ліній
    if y0 == y1 then
        local x = math_min(x0, x1)
        local w = math_abs(x1 - x0) + thickness
        bb:paintRect(x - offset, y0 - offset, w, thickness, color)
        return
    elseif x0 == x1 then
        local y = math_min(y0, y1)
        local h = math_abs(y1 - y0) + thickness
        bb:paintRect(x0 - offset, y - offset, thickness, h, color)
        return
    end

    local dx = math_abs(x1 - x0)
    local sx = x0 < x1 and 1 or -1
    local dy = -math_abs(y1 - y0)
    local sy = y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        bb:paintRect(x0 - offset, y0 - offset, thickness, thickness, color)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end

local function drawDashedLine(bb, x0, y, x1, color)
    for i = x0, x1, 10 do
        local w = math_min(4, x1 - i)
        if w > 0 then bb:paintRect(i, y, w, 1, color) end
    end
end

-- Вертикальний пунктир (для позначок точок перегину).
local function drawDashedVLine(bb, x, y0, y1, color)
    for i = y0, y1, 10 do
        local h = math_min(4, y1 - i)
        if h > 0 then bb:paintRect(x, i, 1, h, color) end
    end
end

function CanvasWidget:paintTo(bb, x, y)
    local w = self.dimen.w
    local h = self.dimen.h
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)

    local graph_x = x + PAD_LEFT
    local graph_y = y + PAD_TOP
    local graph_w = w - PAD_LEFT - PAD_RIGHT
    local graph_h = h - PAD_TOP - PAD_BOTTOM

    -- Сітка
    for i = 1, #PCT_LEVELS do
        local pct = PCT_LEVELS[i]
        local py = graph_y + graph_h - math_floor((pct / 100) * graph_h)
        drawDashedLine(bb, graph_x, py, graph_x + graph_w, Blitbuffer.COLOR_DARK_GRAY)
    end

    -- Осі
    bb:paintRect(graph_x, graph_y + graph_h, graph_w, 2, Blitbuffer.COLOR_BLACK)
    bb:paintRect(graph_x, graph_y, 2, graph_h + 2, Blitbuffer.COLOR_BLACK)

    -- Вертикальні пунктири в точках перегину (під даними, щоб не перекривати лінію).
    if self.turning_x then
        for i = 1, #self.turning_x do
            drawDashedVLine(bb, self.turning_x[i], graph_y, graph_y + graph_h, Blitbuffer.COLOR_DARK_GRAY)
        end
    end

    local history = self.history
    if not history or not history.ts or #history.ts < 2 then return end

    local min_ts = history.ts[1]
    local max_ts = history.ts[#history.ts]
    if max_ts == min_ts then max_ts = min_ts + 1 end

    local prev_x, prev_y, prev_charging = nil, nil, nil
    local draw_w  = graph_w - 2 * INNER_PAD - 2 * DOT_MARGIN
    local ts_diff = max_ts - min_ts
    local ts_scale = draw_w / ts_diff
    local cap_scale = graph_h / 100

    for i = 1, #history.ts do
        local px = graph_x + INNER_PAD + DOT_MARGIN + math_floor((history.ts[i] - min_ts) * ts_scale)
        local py = graph_y + graph_h - math_floor(history.capacity[i] * cap_scale)

        -- Зарядка — сірий, розрядка — чорний
        local dot_color = history.is_charging[i] and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
        if prev_x and prev_y then
            local line_color = prev_charging and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
            drawLine(bb, prev_x, prev_y, px, py, 2, line_color)
        end
        bb:paintRect(px - 3, py - 3, 6, 6, dot_color)

        prev_x        = px
        prev_y        = py
        prev_charging = history.is_charging[i]
    end
end

-- ---------------------------------------------------------------------------

local BatteryGraphWidget = FocusManager:extend{
    history         = {},
    view_mode       = "cycle",  -- "cycle" | "all"
    period_days     = 30,
    on_mode_change  = nil,      -- callback(mode, period_days) — для збереження з main.lua
}

-- Повертає відфільтровану копію history згідно з поточним режимом
function BatteryGraphWidget:getFilteredHistory()
    local history = self.history
    if not history or not history.ts or #history.ts == 0 then return {ts={}, capacity={}, is_charging={}} end

    local filtered = {ts={}, capacity={}, is_charging={}}
    local idx = 1

    if self.view_mode == "cycle" then
        -- Знаходимо початок останньої сесії зарядки (перехід false → true)
        local start_idx = 1
        for i = #history.ts, 2, -1 do
            if history.is_charging[i] and not history.is_charging[i-1] then
                start_idx = i
                break
            end
        end
        for i = start_idx, #history.ts do
            filtered.ts[idx] = history.ts[i]
            filtered.capacity[idx] = history.capacity[i]
            filtered.is_charging[idx] = history.is_charging[i]
            idx = idx + 1
        end
    else
        -- Відображаємо дані за останні N днів
        local cutoff = os.time() - self.period_days * 24 * 3600
        local start_idx = 1
        for i = 1, #history.ts do
            if history.ts[i] >= cutoff then
                start_idx = i
                break
            end
        end
        for i = start_idx, #history.ts do
            filtered.ts[idx] = history.ts[i]
            filtered.capacity[idx] = history.capacity[i]
            filtered.is_charging[idx] = history.is_charging[i]
            idx = idx + 1
        end
    end

    return filtered
end

-- Формує рядок заголовку із зазначенням активного режиму
function BatteryGraphWidget:getModeTitle()
    local title = tr("Battery graph", "Графік батареї")
    if self.view_mode == "cycle" then
        return title .. "  [" .. tr("Current cycle", "Поточний цикл") .. "]"
    else
        return title .. "  [" .. T(tr("%1 days", "%1 днів"), self.period_days) .. "]"
    end
end

-- Показує діалог вибору режиму відображення
function BatteryGraphWidget:showViewMenu()
    local UIManager = require("ui/uimanager")
    local vm  = self.view_mode
    local pd  = self.period_days
    local dialog

    local function mark(active)
        return active and "✓ " or ""
    end

    local function days_label(days)
        return T(tr("%1 days", "%1 днів"), days)
    end

    dialog = ButtonDialogTitle:new{
        title = tr("Display mode", "Режим відображення"),
        buttons = {
            {
                {
                    text = mark(vm == "cycle") .. tr("Current cycle", "Поточний цикл"),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("cycle", nil)
                    end,
                },
            },
            {
                {
                    text = mark(vm == "all" and pd == 30) .. days_label(30),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 30)
                    end,
                },
                {
                    text = mark(vm == "all" and pd == 90) .. days_label(90),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 90)
                    end,
                },
            },
            {
                {
                    text = mark(vm == "all" and pd == 180) .. days_label(180),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 180)
                    end,
                },
                {
                    text = mark(vm == "all" and pd == 365) .. days_label(365),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 365)
                    end,
                },
            },
            {
                {
                    -- Перемикач глобального 12-годинного формату KOReader.
                    text = mark(is_twelve_hour()) .. tr("12-hour clock", "12-годинний формат"),
                    callback = function()
                        UIManager:close(dialog)
                        G_reader_settings:flipNilOrFalse("twelve_hour_clock")
                        pcall(function()
                            local Event = require("ui/event")
                            UIManager:broadcastEvent(Event:new("TimeFormatChanged"))
                        end)
                        self:updateLayout()
                        UIManager:setDirty(self, function()
                            return "ui", self.dimen
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- Оновлює режим відображення графіку без закриття і повторного відкриття віджету.
-- Оновлення in-place запобігає конфліктам і некоректному відображенню (або мерехтінню)
-- на пристроях з e-ink екранами, коли при зміні режиму екран міг відображатися неправильно
-- до повторного відкриття.
function BatteryGraphWidget:switchMode(mode, period)
    local UIManager = require("ui/uimanager")
    local new_period = period or 30

    self.view_mode   = mode
    self.period_days = new_period

    -- Зберігаємо вибір через зовнішній callback (main.lua)
    if self.on_mode_change then
        self.on_mode_change(mode, new_period)
    end

    self:updateLayout()

    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Збирає позначки точок перегину (зміна стану заряджання) і розміщує підписи з
-- часом, уникаючи накладання. Повертає список { line_x, label, x, y }.
function BatteryGraphWidget:buildTurningAnnotations(history, graph_x, graph_y, graph_w, graph_h, face)
    local annotations = {}
    if not history or not history.ts or #history.ts < 3 then return annotations end

    local min_ts = history.ts[1]
    local max_ts = history.ts[#history.ts]
    if max_ts == min_ts then max_ts = min_ts + 1 end

    local draw_w    = graph_w - 2 * INNER_PAD - 2 * DOT_MARGIN
    local ts_scale  = draw_w / (max_ts - min_ts)
    local cap_scale = graph_h / 100
    local gap       = Size.padding.small

    -- Найширший можливий підпис, щоб заздалегідь зарезервувати місце.
    local probe = TextWidget:new{
        text = is_twelve_hour() and "00.00 12:00 PM" or "00.00 00:00",
        face = face, padding = 0,
    }
    local probe_w = probe:getWidth()
    local probe_h = probe:getSize().h
    probe:free()

    local max_label_y = graph_y + graph_h - probe_h
    if max_label_y < 0 then max_label_y = 0 end

    local placed = {}
    local function overlaps(x, y)
        for i = 1, #placed do
            local r = placed[i]
            if x < r.x + r.w and x + r.w > r.x and y < r.y + r.h and y + r.h > r.y then
                return true
            end
        end
        return false
    end

    -- Від найновіших до найстаріших, щоб за обмеженого бюджету лишалися свіжіші точки.
    for i = #history.ts, 2, -1 do
        if #annotations >= MAX_TURNING_LABELS then break end
        if history.is_charging[i] ~= history.is_charging[i - 1] then
            local ts = history.ts[i]
            local line_x = graph_x + INNER_PAD + DOT_MARGIN + math_floor((ts - min_ts) * ts_scale)
            local point_y = graph_y + graph_h - math_floor(history.capacity[i] * cap_scale)
            local is_peak = not history.is_charging[i] -- заряджання спинилося: локальний максимум

            local anchor_x = math_max(0, math_min(line_x - math_floor(probe_w / 2), self.dimen.w - probe_w))
            local base_y = is_peak and (point_y - probe_h - gap) or (point_y + gap)
            local step = probe_h + 2

            local chosen_y
            for _, k in ipairs({0, 1, -1, 2, -2, 3, -3}) do
                local ly = math_max(0, math_min(base_y + k * step, max_label_y))
                if not overlaps(anchor_x, ly) then
                    chosen_y = ly
                    break
                end
            end

            if chosen_y then
                placed[#placed + 1] = {x = anchor_x, y = chosen_y, w = probe_w, h = probe_h}
                local label = TextWidget:new{text = formatDateTime(ts), face = face, padding = 0}
                local lw = label:getWidth()
                local lx = math_max(0, math_min(line_x - math_floor(lw / 2), self.dimen.w - lw))
                annotations[#annotations + 1] = {
                    line_x = line_x,
                    label  = label,
                    x      = lx,
                    y      = chosen_y,
                }
            end
        end
    end

    return annotations
end

function BatteryGraphWidget:updateLayout()
    if self.title_bar then
        self.title_bar:setTitle(self:getModeTitle())
    end

    local filtered_history = self:getFilteredHistory()
    local canvas_h = self.dimen.h - self.title_bar:getHeight()

    local graph_x = PAD_LEFT
    local graph_y = PAD_TOP
    local graph_w = self.dimen.w - PAD_LEFT - PAD_RIGHT
    local graph_h = canvas_h - PAD_TOP - PAD_BOTTOM

    local font_face = Font:getFace("cfont", 16)
    local small_face = Font:getFace("cfont", 14)
    local text_100 = TextWidget:new{text = "100%", face = font_face, padding = 0}
    local text_75  = TextWidget:new{text = " 75%", face = font_face, padding = 0}
    local text_50  = TextWidget:new{text = " 50%", face = font_face, padding = 0}
    local text_25  = TextWidget:new{text = " 25%", face = font_face, padding = 0}
    local text_0   = TextWidget:new{text = "  0%", face = font_face, padding = 0}

    local min_time_str, max_time_str = "", ""
    if filtered_history and filtered_history.ts and #filtered_history.ts >= 2 then
        min_time_str = formatDateTime(filtered_history.ts[1])
        max_time_str = formatDateTime(filtered_history.ts[#filtered_history.ts])
    end

    local text_start = TextWidget:new{text = min_time_str, face = font_face, padding = 0}
    local text_end   = TextWidget:new{text = max_time_str, face = font_face, padding = 0}

    -- Позначки точок перегину з підписами часу.
    local annotations = self:buildTurningAnnotations(
        filtered_history, graph_x, graph_y, graph_w, graph_h, small_face)

    local turning_x = {}
    for i = 1, #annotations do
        turning_x[i] = annotations[i].line_x
    end

    local children = {
        dimen = Geom:new{w = self.dimen.w, h = canvas_h},
        CanvasWidget:new{
            dimen     = Geom:new{w = self.dimen.w, h = canvas_h},
            history   = filtered_history,
            turning_x = turning_x,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_100:getWidth() - Size.padding.small, graph_y - text_100:getSize().h/2},
            text_100,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_75:getWidth() - Size.padding.small, graph_y + graph_h*0.25 - text_75:getSize().h/2},
            text_75,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_50:getWidth() - Size.padding.small, graph_y + graph_h*0.5 - text_50:getSize().h/2},
            text_50,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_25:getWidth() - Size.padding.small, graph_y + graph_h*0.75 - text_25:getSize().h/2},
            text_25,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x - text_0:getWidth() - Size.padding.small, graph_y + graph_h - text_0:getSize().h/2},
            text_0,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x + INNER_PAD, graph_y + graph_h + Size.padding.small},
            text_start,
        },
        FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {graph_x + graph_w - INNER_PAD - text_end:getWidth(), graph_y + graph_h + Size.padding.small},
            text_end,
        },
    }

    for i = 1, #annotations do
        local a = annotations[i]
        children[#children + 1] = FrameContainer:new{
            padding = 0, bordersize = 0, margin = 0,
            overlap_offset = {a.x, a.y},
            a.label,
        }
    end

    local canvas_with_labels = OverlapGroup:new(children)

    self[1] = FrameContainer:new{
        height     = self.dimen.h,
        width      = self.dimen.w,
        padding    = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.title_bar,
            canvas_with_labels,
        }
    }
end

function BatteryGraphWidget:init()
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        local GestureRange = require("ui/gesturerange")
        self.ges_events.Tap   = { GestureRange:new{ ges = "tap",   range = self.dimen } }
        self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    end

    self.title_bar = TitleBar:new{
        fullscreen             = true,
        width                  = self.dimen.w,
        align                  = "left",
        title                  = self:getModeTitle(),
        left_icon              = "appbar.menu",
        left_icon_tap_callback = function() self:showViewMenu() end,
        close_callback         = function() self:onClose() end,
        show_parent            = self,
    }

    self:updateLayout()
end

function BatteryGraphWidget:onTap()
    self:onClose()
    return true
end

function BatteryGraphWidget:onSwipe()
    self:onClose()
    return true
end

function BatteryGraphWidget:onClose()
    local UIManager = require("ui/uimanager")
    UIManager:close(self)
    return true
end

return BatteryGraphWidget
