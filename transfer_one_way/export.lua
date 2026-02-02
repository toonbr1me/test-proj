local component = require("component")
local term = require("term")
local serialization = require("serialization")
local filesystem = require("filesystem")
local os = require("os")

local CFG_PATH = "/home/relay_final.cfg"

-- =========================================================
-- КОНФИГ
-- =========================================================

local function saveConfig(data)
    local f = io.open(CFG_PATH, "w")
    f:write(serialization.serialize(data))
    f:close()
end

local function loadConfig()
    if not filesystem.exists(CFG_PATH) then return nil end
    local f = io.open(CFG_PATH, "r")
    local d = serialization.unserialize(f:read("*a"))
    f:close()
    return d
end

local function selectComp(title, cType)
    local list = {}
    for addr in component.list(cType) do table.insert(list, addr) end
    if #list == 0 then return nil end

    term.clear()
    print("--- " .. title .. " ---")
    for i, addr in ipairs(list) do
        print(string.format("[%d] %s...", i, addr:sub(1, 8)))
    end

    io.write("Номер: ")
    local idx = tonumber(io.read())
    if not idx or not list[idx] then return nil end
    return list[idx]
end

local function setupWizard()
    term.clear()
    print("=== SETUP RELAY v17 ===")

    local cfg = {}
    cfg.me = selectComp("ME Interface", "me_interface")
    cfg.db = selectComp("Database", "database")
    cfg.tp = selectComp("Transposer", "transposer")

    if not cfg.me or not cfg.db or not cfg.tp then
        print("Ошибка выбора компонентов")
        return nil
    end

    local tp = component.proxy(cfg.tp)

    print("\nСтороны транспозера с инвентарём:")
    for i = 0, 5 do
        if tp.getInventorySize(i) then
            print("  ["..i.."] OK")
        end
    end

    io.write("\nСторона МЭ-источника (основная сеть): ")
    cfg.s1 = tonumber(io.read())

    io.write("Сторона приёмника (вторичная сеть): ")
    cfg.s2 = tonumber(io.read())

    saveConfig(cfg)
    print("Сохранено.")
    os.sleep(1)
    return cfg
end

local function normalizeConfig(cfg)
    if not cfg then return nil end
    if cfg.main_side and not cfg.s1 then cfg.s1 = cfg.main_side end
    if cfg.secondary_side and not cfg.s2 then cfg.s2 = cfg.secondary_side end
    return cfg
end

local function promptNumber(label)
    io.write(label)
    local n = tonumber(io.read())
    return n
end

local function showMainMenu()
    term.clear()
    print("=== PRECISION RELAY v17 ===")
    print("[1] Основная -> вторичная")
    print("[2] Вторичная -> основная")
    print("[3] Конфигуратор")
    print("[4] Выход")
    io.write("Выбор: ")
    return tonumber(io.read())
end

local function collectSideItems(tp, side)
    local size = tp.getInventorySize(side) or 0
    local map = {}
    local list = {}

    for slot = 1, size do
        local st = tp.getStackInSlot(side, slot)
        if st and st.name then
            local key = (st.name or "") .. "|" .. tostring(st.damage or 0) .. "|" .. tostring(st.nbt_hash or "")
            if not map[key] then
                local entry = {
                    name = st.name,
                    label = st.label or st.name,
                    damage = st.damage,
                    nbt_hash = st.nbt_hash,
                    size = st.size or 0
                }
                map[key] = entry
                table.insert(list, entry)
            else
                map[key].size = (map[key].size or 0) + (st.size or 0)
            end
        end
    end

    table.sort(list, function(a, b) return (a.label or "") < (b.label or "") end)
    return list
end

-- =========================================================
-- РАБОТА С БАЗОЙ
-- =========================================================

local function sameItem(a, b)
    return a and b
       and a.name == b.name
       and (a.damage or 0) == (b.damage or 0)
       and (a.nbt_hash or "") == (b.nbt_hash or "")
end

local function syncDatabase(me, db, filter)
    print("\nСинхронизация базы...")

    for attempt = 1, 6 do
        print("Попытка " .. attempt)

        db.clear(1)  -- 💥 ВОТ ГЛАВНЫЙ ФИКС
        os.sleep(0.2)

        me.store(filter, db.address, 1)
        os.sleep(0.5)

        local info = db.get(1)
        if sameItem(info, filter) then
            print("✔ База настроена")
            return true
        end

        print("База ещё не совпадает...")
        os.sleep(0.7)
    end

    print("❌ Не удалось синхронизировать базу")
    return false
end

-- =========================================================
-- ОСНОВНОЙ ЦИКЛ
-- =========================================================

local cfg = normalizeConfig(loadConfig()) or setupWizard()
if not cfg then return end

local me = component.proxy(cfg.me)
local db = component.proxy(cfg.db)
local tp = component.proxy(cfg.tp)

local function transferForward()
    io.write("\nПоиск (back): ")
    local search = io.read()
    if search == "back" then return end

    local items = me.getItemsInNetwork()
    if type(items) ~= "table" then
        print("Ошибка сети МЭ")
        os.sleep(2)
        return
    end

    local matches = {}
    for _, it in ipairs(items) do
        if it.label and it.label:lower():find(search:lower()) then
            table.insert(matches, it)
        end
    end

    if #matches == 0 then
        print("Не найдено")
        os.sleep(1.5)
        return
    end

    for i, it in ipairs(matches) do
        print(string.format("[%d] %s (%d)", i, it.label, it.size))
    end

    io.write("Выбор: ")
    local sel = tonumber(io.read())
    if not sel or not matches[sel] then return end

    local c = matches[sel]
    local filter = {name=c.name, damage=c.damage, nbt_hash=c.nbt_hash}

    io.write("Количество: ")
    local total = tonumber(io.read()) or 0
    if total <= 0 then return end

    if not syncDatabase(me, db, filter) then
        print("Ошибка базы. Enter.")
        io.read()
        return
    end

    print("Открываю интерфейс...")
    me.setInterfaceConfiguration(1, db.address, 1, 64)

    local moved = 0
    while moved < total do
        local res = tp.transferItem(cfg.s1, cfg.s2, math.min(64, total - moved), 1)
        if res and res > 0 then
            moved = moved + res
            print("Прогресс: "..moved.."/"..total)
        else
            os.sleep(0.3)
        end
    end
end

local function transferBackward()
    local list = collectSideItems(tp, cfg.s2)
    if #list == 0 then
        print("Во вторичной сети пусто")
        os.sleep(1.5)
        return
    end

    print("\nДоступные предметы во вторичной сети:")
    for i, it in ipairs(list) do
        print(string.format("[%d] %s (%d)", i, it.label, it.size))
    end

    io.write("Выбор (back): ")
    local sel = io.read()
    if sel == "back" then return end
    sel = tonumber(sel)
    if not sel or not list[sel] then return end

    io.write("Количество: ")
    local total = tonumber(io.read()) or 0
    if total <= 0 then return end

    local moved = 0
    while moved < total do
        local res = tp.transferItem(cfg.s2, cfg.s1, math.min(64, total - moved))
        if res and res > 0 then
            moved = moved + res
            print("Прогресс: "..moved.."/"..total)
        else
            os.sleep(0.3)
        end
    end
end

while true do
    local action = showMainMenu()
    if action == 4 then break end

    if action == 3 then
        cfg = setupWizard()
        if not cfg then
            cfg = normalizeConfig(loadConfig())
        end
        if cfg then
            me = component.proxy(cfg.me)
            db = component.proxy(cfg.db)
            tp = component.proxy(cfg.tp)
        end
    elseif action == 2 then
        transferBackward()
    elseif action == 1 then
        transferForward()
    end
end
