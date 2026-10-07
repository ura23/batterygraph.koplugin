-- v1.0: en/uk localization helpers (tr/trn) for batterygraph.koplugin (AGENTS.md convention).
-- Language is taken from G_reader_settings:readSetting("language").
local function current_lang()
    if G_reader_settings then
        return G_reader_settings:readSetting("language") or "en"
    end
    return "en"
end

local function is_uk()
    return current_lang():sub(1, 2) == "uk"
end

--- @param en string English text (fallback)
--- @param uk string Ukrainian text
local function tr(en, uk)
    if is_uk() then
        return uk or en
    end
    return en
end

--- Ukrainian-aware plural selection.
--- @param n number
--- @param en1 string English singular (no placeholder)
--- @param enN string English plural (with %1)
--- @param uk1 string Ukrainian singular (no placeholder)
--- @param ukFew string Ukrainian "few" form (2-4)
--- @param ukMany string Ukrainian "many" form (5+, 0, teens)
local function trn(n, en1, enN, uk1, ukFew, ukMany)
    if is_uk() then
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

return {
    tr = tr,
    trn = trn,
}
