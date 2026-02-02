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

local function renderSides(tp)
    print("\nСтороны транспозера с инвентарём:")
    for i = 0, 5 do
        if tp.getInventorySize(i) then
            print("  ["..i.."] OK")
        else
            print("  ["..i.."] --")
        end
    end
end

local function configureNetwork(title, current)
    term.clear()
    print("=== НАСТРОЙКА: " .. title .. " ===")

    local cfg = current or {}
    cfg.me = selectComp("ME Interface", "me_interface")
    cfg.db = selectComp("Database", "database")
    cfg.tp = selectComp("Transposer", "transposer")

    if not cfg.me or not cfg.db or not cfg.tp then
        print("Ошибка выбора компонентов")
        return nil
    end

    local tp = component.proxy(cfg.tp)
    renderSides(tp)

    io.write("\nСторона МЭ-интерфейса: ")
    cfg.me_side = tonumber(io.read())

    io.write("Сторона буфера (общий сундук/шина): ")
    cfg.buffer_side = tonumber(io.read())

    return cfg
end

local function printNetworkSummary(title, cfg)
    if not cfg then
        print(title .. ": не настроено")
        return
    end
    print(title .. ":")
    print("  ME: " .. tostring(cfg.me or "-"))
    print("  DB: " .. tostring(cfg.db or "-"))
    print("  TP: " .. tostring(cfg.tp or "-"))
    print("  ME side: " .. tostring(cfg.me_side or "-"))
    print("  Buffer side: " .. tostring(cfg.buffer_side or "-"))
end

local function setupWizard(existing)
    local cfg = existing or {}
    while true do
        term.clear()
        print("=== CONFIG RELAY v17 ===")
        printNetworkSummary("Основная сеть", cfg.main)
        printNetworkSummary("Вторичная сеть", cfg.secondary)

        print("\n[1] Настроить основную сеть")
        print("[2] Настроить вторичную сеть")
        print("[3] Сохранить и выйти")
        print("[4] Выйти без сохранения")
        io.write("Выбор: ")
        local choice = tonumber(io.read())

        if choice == 1 then
            cfg.main = configureNetwork("ОСНОВНАЯ СЕТЬ", cfg.main)
            os.sleep(0.5)
        elseif choice == 2 then
            cfg.secondary = configureNetwork("ВТОРИЧНАЯ СЕТЬ", cfg.secondary)
            os.sleep(0.5)
        elseif choice == 3 then
            if not (cfg.main and cfg.main.me and cfg.main.db and cfg.main.tp and cfg.main.me_side and cfg.main.buffer_side) then
                print("Основная сеть не полностью настроена")
                os.sleep(1.5)
            elseif not (cfg.secondary and cfg.secondary.me and cfg.secondary.db and cfg.secondary.tp and cfg.secondary.me_side and cfg.secondary.buffer_side) then
                print("Вторичная сеть не полностью настроена")
                os.sleep(1.5)
            else
                saveConfig(cfg)
                print("Сохранено.")
                os.sleep(1)
                return cfg
            end
        elseif choice == 4 then
            return nil
        end
    end
end

local function normalizeConfig(cfg)
    if not cfg then return nil end
    if cfg.s1 and cfg.s2 and not cfg.main then
        cfg.main = {
            me = cfg.me,
            db = cfg.db,
            tp = cfg.tp,
            me_side = cfg.s1,
            buffer_side = cfg.s2
        }
    end
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

local cfg = normalizeConfig(loadConfig())
if not (cfg and cfg.main and cfg.secondary) then
    cfg = setupWizard(cfg)
end
if not cfg then return end

local me = component.proxy(cfg.main.me)
local db = component.proxy(cfg.main.db)
local tp = component.proxy(cfg.main.tp)

local function transferForward()
    local main = cfg.main
    local secondary = cfg.secondary
    if not (main and secondary) then return end

    local meMain = component.proxy(main.me)
    local dbMain = component.proxy(main.db)
    local tpMain = component.proxy(main.tp)
    local tpSecondary = component.proxy(secondary.tp)

    io.write("\nПоиск (back): ")
    local search = io.read()
    if search == "back" then return end

    local items = meMain.getItemsInNetwork()
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

    if not syncDatabase(meMain, dbMain, filter) then
        print("Ошибка базы. Enter.")
        io.read()
        return
    end

    print("Открываю интерфейс...")
    meMain.setInterfaceConfiguration(1, dbMain.address, 1, 64)

    local moved = 0
    while moved < total do
        local res = tpMain.transferItem(main.me_side, main.buffer_side, math.min(64, total - moved), 1)
        if res and res > 0 then
            moved = moved + res
            print("Прогресс: "..moved.."/"..total)
        else
            os.sleep(0.3)
        end
    end

    moved = 0
    while moved < total do
        local res = tpSecondary.transferItem(secondary.buffer_side, secondary.me_side, math.min(64, total - moved))
        if res and res > 0 then
            moved = moved + res
            print("Прогресс: "..moved.."/"..total)
        else
            os.sleep(0.3)
        end
    end
end

local function transferBackward()
    local main = cfg.main
    local secondary = cfg.secondary
    if not (main and secondary) then return end

    local meSecondary = component.proxy(secondary.me)
    local dbSecondary = component.proxy(secondary.db)
    local tpSecondary = component.proxy(secondary.tp)
    local tpMain = component.proxy(main.tp)

    io.write("\nПоиск (back): ")
    local search = io.read()
    if search == "back" then return end

    local items = meSecondary.getItemsInNetwork()
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

    if not syncDatabase(meSecondary, dbSecondary, filter) then
        print("Ошибка базы. Enter.")
        io.read()
        return
    end

    print("Открываю интерфейс...")
    meSecondary.setInterfaceConfiguration(1, dbSecondary.address, 1, 64)

    local moved = 0
    while moved < total do
        local res = tpSecondary.transferItem(secondary.me_side, secondary.buffer_side, math.min(64, total - moved), 1)
        if res and res > 0 then
            moved = moved + res
            print("Прогресс: "..moved.."/"..total)
        else
            os.sleep(0.3)
        end
    end

    moved = 0
    while moved < total do
        local res = tpMain.transferItem(main.buffer_side, main.me_side, math.min(64, total - moved))
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
        cfg = setupWizard(cfg)
        if not cfg then
            cfg = normalizeConfig(loadConfig())
        end
        if cfg then
            me = component.proxy(cfg.main.me)
            db = component.proxy(cfg.main.db)
            tp = component.proxy(cfg.main.tp)
        end
    elseif action == 2 then
        transferBackward()
    elseif action == 1 then
        transferForward()
    end
end
