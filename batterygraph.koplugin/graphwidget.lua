local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local TitleBar = require("ui/widget/titlebar")
local Widget = require("ui/widget/widget")
local Size = require("ui/size")
local VerticalGroup = require("ui/widget/verticalgroup")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local _ = require("batterygraph_i18n").translate
local Screen = Device.screen

-- КЕШУВАННЯ ФУНКЦІЙ ДЛЯ ПРИСКОРЕННЯ (Upvalues)
local math_abs = math.abs
local math_floor = math.floor
local math_min = math.min
local os_date = os.date

-- Статичні рівні сітки
local PCT_LEVELS = {25, 50, 75, 100}

-- Статичні розміри відступів графіку
local PAD_LEFT   = Size.padding.large * 5
local PAD_RIGHT  = Size.padding.large * 2
local PAD_TOP    = Size.padding.large * 2
local PAD_BOTTOM = Size.padding.large * 4
local INNER_PAD  = Size.padding.default
local DOT_MARGIN = Size.padding.large

local CanvasWidget = Widget:extend{
    history = {},
    dimen   = nil,
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
    if self.view_mode == "cycle" then
        return _("Графік батареї") .. "  [" .. _("Поточний цикл") .. "]"
    else
        return _("Графік батареї") .. "  [" .. self.period_days .. _(" днів") .. "]"
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

    dialog = ButtonDialogTitle:new{
        title = _("Режим відображення"),
        buttons = {
            {
                {
                    text = mark(vm == "cycle") .. _("Поточний цикл"),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("cycle", nil)
                    end,
                },
            },
            {
                {
                    text = mark(vm == "all" and pd == 30) .. _("30 днів"),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 30)
                    end,
                },
                {
                    text = mark(vm == "all" and pd == 90) .. _("90 днів"),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 90)
                    end,
                },
            },
            {
                {
                    text = mark(vm == "all" and pd == 180) .. _("180 днів"),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 180)
                    end,
                },
                {
                    text = mark(vm == "all" and pd == 365) .. _("365 днів"),
                    callback = function()
                        UIManager:close(dialog)
                        self:switchMode("all", 365)
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
    local text_100 = TextWidget:new{text = "100%", face = font_face, padding = 0}
    local text_75  = TextWidget:new{text = " 75%", face = font_face, padding = 0}
    local text_50  = TextWidget:new{text = " 50%", face = font_face, padding = 0}
    local text_25  = TextWidget:new{text = " 25%", face = font_face, padding = 0}
    local text_0   = TextWidget:new{text = "  0%", face = font_face, padding = 0}

    local min_time_str, max_time_str = "", ""
    if filtered_history and filtered_history.ts and #filtered_history.ts >= 2 then
        min_time_str = os_date("%d.%m %H:%M", filtered_history.ts[1])
        max_time_str = os_date("%d.%m %H:%M", filtered_history.ts[#filtered_history.ts])
    end

    local text_start = TextWidget:new{text = min_time_str, face = font_face, padding = 0}
    local text_end   = TextWidget:new{text = max_time_str, face = font_face, padding = 0}

    local canvas_with_labels = OverlapGroup:new{
        dimen = Geom:new{w = self.dimen.w, h = canvas_h},
        CanvasWidget:new{
            dimen   = Geom:new{w = self.dimen.w, h = canvas_h},
            history = filtered_history,
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
