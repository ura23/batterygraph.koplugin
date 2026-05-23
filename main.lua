local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local PowerD = require("device"):getPowerDevice()
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local BatteryGraph = WidgetContainer:extend{
    name = "batterygraph",
    title = _("Battery graph"),
    settings_file = DataStorage:getSettingsDir() .. "/battery_graph.lua",
}

function BatteryGraph:init()
    if not self.ui or not self.ui.menu then return end

    self.settings = LuaSettings:open(self.settings_file)
    self.history = self.settings:readSetting("history") or {ts={}, capacity={}, is_charging={}}

    -- Затираємо старі дані (якщо це формат масиву таблиць)
    if self.history[1] then
        self.history = {ts={}, capacity={}, is_charging={}}
        self:saveHistory(true)
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self:cleanHistory()
    self:recordPoint()
    self:scheduleNextRecord()
end

function BatteryGraph:cleanHistory()
    local history = self.history
    if not history.ts or #history.ts == 0 then return end

    local now = os.time()
    local retention_period = 365 * 24 * 60 * 60
    local cut_off = now - retention_period

    local keep_idx = 0
    for i = 1, #history.ts do
        if history.ts[i] >= cut_off then
            keep_idx = i
            break
        end
    end

    if keep_idx > 1 then
        local filtered = {ts={}, capacity={}, is_charging={}}
        local idx = 1
        for i = keep_idx, #history.ts do
            filtered.ts[idx] = history.ts[i]
            filtered.capacity[idx] = history.capacity[i]
            filtered.is_charging[idx] = history.is_charging[i]
            idx = idx + 1
        end
        self.history = filtered
        self:saveHistory(true)
    elseif keep_idx == 0 then
        self.history = {ts={}, capacity={}, is_charging={}}
        self:saveHistory(true)
    end
end

function BatteryGraph:recordPoint()
    local ts = os.time()
    local capacity = PowerD:getCapacityHW()
    local is_charging = PowerD:isCharging()

    local history = self.history
    local count = history.ts and #history.ts or 0
    local last_cap, last_charge
    if count > 0 then
        last_cap = history.capacity[count]
        last_charge = history.is_charging[count]
    end

    if count == 0 or last_cap ~= capacity or last_charge ~= is_charging then
        table.insert(history.ts, ts)
        table.insert(history.capacity, capacity)
        table.insert(history.is_charging, is_charging)
        self:saveHistory(false)
    else
        history.ts[count] = ts
        self:saveHistory(false)
    end
end

function BatteryGraph:saveHistory(hard_flush)
    self.settings:saveSetting("history", self.history)
    if hard_flush then
        self.settings:flush()
    end
end

function BatteryGraph:scheduleNextRecord()
    if self.record_task then
        UIManager:unschedule(self.record_task)
    end
    self.record_task = UIManager:scheduleIn(300, function()
        self:recordPoint()
        self:scheduleNextRecord()
    end)
end

function BatteryGraph:onDispatcherRegisterActions()
    Dispatcher:registerAction("battery_graph", {category="none", event="ShowBatteryGraph", title=self.title, device=true})
end

function BatteryGraph:addToMainMenu(menu_items)
    menu_items.battery_graph = {
        text = self.title,
        keep_menu_open = false,
        callback = function()
            self:onShowBatteryGraph()
        end,
    }
end

function BatteryGraph:onShowBatteryGraph()
    self:recordPoint()

    -- Читаємо збережений режим відображення (зберігається в тому ж файлі налаштувань)
    local view_mode   = self.settings:readSetting("view_mode")   or "cycle"
    local period_days = self.settings:readSetting("period_days") or 30

    local GraphWidget = require("graphwidget")
    UIManager:show(GraphWidget:new{
        history        = self.history,
        view_mode      = view_mode,
        period_days    = period_days,
        -- Callback викликається при кожній зміні режиму: зберігає вибір на диск
        on_mode_change = function(mode, period)
            self.settings:saveSetting("view_mode", mode)
            self.settings:saveSetting("period_days", period)
            self.settings:flush()
        end,
    })
end

function BatteryGraph:onSuspend()
    self:recordPoint()
    self:saveHistory(true)
end

function BatteryGraph:onResume()
    self:recordPoint()
end

function BatteryGraph:onCharging()
    self:recordPoint()
end

function BatteryGraph:onNotCharging()
    self:recordPoint()
end

return BatteryGraph
