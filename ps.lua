-- ant colony AI v2 | OpenRouter | not run in-game
-- v2: exact upgrade costs (no more "not enough wood" spam), monsters (hunt/capture/tame), allies (answer/request/lend)
-- start a SOLO match yourself; bot plays once MatchState == playing.
-- the LLM can only emit whitelisted actions; everything is validated here.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer

local env = (getgenv and getgenv()) or _G
if env.__ANT_STOP then pcall(env.__ANT_STOP) end

local cfg = {
    Key = env.OPENROUTER_KEY or "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", -- FILL: sk-or-...  (don't share the script with the key inside)
    Model = "google/gemini-2.5-flash",
    Interval = 6,
    MaxTokens = 800,
    Temperature = 0.4,
    UseAI = true,
    AutoDefend = true,
    Monsters = true,   -- hunt / capture / tame
    Allies = true,     -- answer + request alliances, lend soldiers
    Run = true,
}
local httpReq = (syn and syn.request) or (http and http.request) or http_request or request

-- game handles -----------------------------------------------------------------
local AG = RS:WaitForChild("AntGame", 15)
local World = AG:WaitForChild("World")
local Colonies = World:WaitForChild("Colonies")
local Remotes = AG:WaitForChild("Remotes")
local Action = Remotes:WaitForChild("Action")
local okC, Config = pcall(require, AG:WaitForChild("Config"))
if not okC or type(Config) ~= "table" then Config = {} end
local SUPER_FOOD = (Config.SUPER and Config.SUPER.cost and Config.SUPER.cost.food) or 75
local MAX_FEEDERS = Config.MAX_FEEDERS or 3
local ALLY_MAX = (Config.ALLY and Config.ALLY.max) or 3
local PRISON_LEVEL = Config.PRISON_LEVEL or 2

-- log ---------------------------------------------------------------------------
local logs = {}
local logLabel
local function log(s)
    s = os.date("%M:%S") .. " " .. tostring(s)
    table.insert(logs, s)
    while #logs > 10 do table.remove(logs, 1) end
    print("[ANT] " .. s)
    if logLabel then pcall(function() logLabel.Text = table.concat(logs, "\n") end) end
end

-- helpers ---------------------------------------------------------------------------
local function myFolder()
    for _, f in ipairs(Colonies:GetChildren()) do
        if f:GetAttribute("OwnerId") == lp.UserId then return f end
    end
end

local function colonyByIndex(idx)
    for _, c in ipairs(Colonies:GetChildren()) do
        if c:GetAttribute("Index") == idx then return c end
    end
end

local function parseOrders(s)
    local t = {}
    for k, v in string.gmatch(s or "", "([^:,]+):(%d+)") do t[k] = tonumber(v) end
    return t
end

local function sumOrders(t)
    local n = 0
    for _, v in pairs(t) do n = n + v end
    return n
end

local function int(v, d) v = tonumber(v); if not v then return d end return math.floor(v) end

local function freeSoldiers(f)
    local soldiers = f:GetAttribute("Soldiers") or 0
    return math.max(0, soldiers - sumOrders(parseOrders(f:GetAttribute("NestOrders"))) - sumOrders(parseOrders(f:GetAttribute("AntOrders"))))
end

local function allySet(f)
    local s = {}
    for n in string.gmatch(f:GetAttribute("Allies") or "", "%d+") do s[tonumber(n)] = true end
    return s
end

local function dist(f, c)
    local dx = (c:GetAttribute("NestX") or 0) - (f:GetAttribute("NestX") or 0)
    local dy = (c:GetAttribute("NestY") or 0) - (f:GetAttribute("NestY") or 0)
    return math.floor(math.sqrt(dx * dx + dy * dy))
end

-- upgrade costs straight from Config (same data the game UI uses) -------------------------------
local UPG = { nest = "Nest", soldier = "Soldier", worker = "Worker", nursery = "Nursery" }
local UPG_ATTR = { Nest = "NestLevel", Soldier = "SoldierLv", Worker = "WorkerLv", Nursery = "NurseryCap" }

-- returns table {food,wood,need_ants}, "max", or nil (unknown)
local function upgradeCost(key, f)
    local ok, res = pcall(function()
        if key == "Nest" then
            local lvl = f:GetAttribute("NestLevel") or 1
            local nx = Config.NEST_LEVELS and Config.NEST_LEVELS[lvl + 1]
            if not nx then return "max" end
            return { food = nx.food or 0, wood = nx.wood or 0, need_ants = nx.ants }
        elseif key == "Nursery" then
            local cap = f:GetAttribute("NurseryCap") or Config.NURSERY_START or 3
            if Config.NURSERY_MAX and cap >= Config.NURSERY_MAX then return "max" end
            local c = Config.nurseryCost(cap)
            return { food = c.food or 0, wood = c.wood or 0 }
        else
            local lv = f:GetAttribute(UPG_ATTR[key]) or 1
            if Config.MAX_LEVEL and lv >= Config.MAX_LEVEL then return "max" end
            local c = Config.UPGRADE_COST[key][lv]
            if not c then return "max" end
            return { food = c.food or 0, wood = c.wood or 0 }
        end
    end)
    if ok then return res end
end

local function affordable(c, f)
    if type(c) ~= "table" then return false end
    if (f:GetAttribute("Food") or 0) < c.food or (f:GetAttribute("Wood") or 0) < c.wood then return false end
    if c.need_ants and (f:GetAttribute("Total") or 0) < c.need_ants then return false end
    return true
end

-- monsters: parse the game's own Snap buffer (same layout the client reads) ----------------------------
-- NOTE: server only streams what is inside the camera view, so only monsters near your camera are visible.
local MONSTER_KINDS = { "Spider", "Scorpion", "Termite", "TermiteSoldier", "TermiteMound" }
local monsters = {}
local function parseSnap(p)
    local n = buffer.readu16(p, 0)
    local off = 2 + n * 11
    local len = buffer.len(p)
    local out = {}
    if len > off then
        local cnt = buffer.readu8(p, off)
        off = off + 1
        for _ = 1, cnt do
            if off + 13 > len then break end
            local id = buffer.readu16(p, off)
            out[id] = {
                id = id,
                x = buffer.readu16(p, off + 2) / 8,
                y = buffer.readu16(p, off + 4) / 8,
                kind = MONSTER_KINDS[buffer.readu8(p, off + 6)] or "Spider",
                state = buffer.readu8(p, off + 7),
                hp = buffer.readu8(p, off + 8) / 255,
                owner = buffer.readu8(p, off + 10),
                seen = os.clock(),
            }
            off = off + 13
        end
    end
    return out
end

local conns = {}
local function track(c) conns[#conns + 1] = c return c end

track(Remotes:WaitForChild("Snap").OnClientEvent:Connect(function(p)
    if typeof(p) ~= "buffer" then return end
    local ok, res = pcall(parseSnap, p)
    if ok then monsters = res end
end))

-- allies: incoming requests from the game's own event ---------------------------------------------------
local pendingAsks = {}  -- [from.."|"..kind] = {...}
local urgent = false
track(Remotes:WaitForChild("Event").OnClientEvent:Connect(function(kind, ...)
    if kind == "AllyAsk" then
        local k, from, life, n, by = ...
        if type(k) == "string" and type(from) == "number" then
            pendingAsks[from .. "|" .. k] = { kind = k, from = from, n = n, by = by, deadline = os.clock() + (tonumber(life) or 15) - 1 }
            urgent = true
        end
    end
end))

-- snapshot ---------------------------------------------------------------------------------------------
local function snapshot()
    local f = myFolder()
    if not f then return end
    local now = workspace:GetServerTimeNow()
    local a = function(n, d) local v = f:GetAttribute(n); if v == nil then return d end return v end
    local eggsStr = a("Eggs", "")
    local growing = select(2, string.gsub(eggsStr, "[^,]+", ""))
    local soldiers = a("Soldiers", 0)
    local incoming = parseOrders(a("Incoming", ""))
    local allies = allySet(f)
    local nestMax = math.max(1, a("NestMaxHP", 1))
    local nestLv = a("NestLevel", 1)

    local enemies = {}
    local allyList = {}
    local lend = {}
    for idx, exp in string.gmatch(a("LendCd", ""), "(%d+):(%d+)") do lend[tonumber(idx)] = tonumber(exp) end
    for _, c in ipairs(Colonies:GetChildren()) do
        local idx = c:GetAttribute("Index")
        if c ~= f and idx and (c:GetAttribute("NestHP") or 0) > 0 then
            local info = {
                index = idx,
                name = tostring(c:GetAttribute("Name") or "?"),
                power = math.floor(c:GetAttribute("Power") or 0),
                ants = c:GetAttribute("Total") or 0,
                nest_level = c:GetAttribute("NestLevel") or 1,
                nest_hp_pct = math.floor(100 * (c:GetAttribute("NestHP") or 0) / math.max(1, c:GetAttribute("NestMaxHP") or 1)),
                dist = dist(f, c),
                ai = c:GetAttribute("IsAI") == true,
            }
            if allies[idx] then
                info.lend_ready = (lend[idx] or 0) <= now
                table.insert(allyList, info)
            else
                table.insert(enemies, info)
            end
        end
    end
    table.sort(enemies, function(x, y) return x.dist < y.dist end)
    while #enemies > 8 do table.remove(enemies) end

    -- ally requests still alive
    local asks = {}
    local t = os.clock()
    for key, p in pairs(pendingAsks) do
        if p.deadline <= t or not colonyByIndex(p.from) then
            pendingAsks[key] = nil
        else
            local c = colonyByIndex(p.from)
            table.insert(asks, {
                kind = p.kind, from = p.from, from_name = tostring(c:GetAttribute("Name") or "?"),
                from_power = math.floor(c:GetAttribute("Power") or 0), from_dist = dist(f, c),
                soldiers_requested = p.n, seconds_left = math.floor(p.deadline - t),
                already_ally = allies[p.from] == true,
            })
        end
    end
    local outReq = {}
    for n in string.gmatch(a("AllyOut", ""), "%d+") do outReq[#outReq + 1] = tonumber(n) end

    -- prisoners "Type:fed:need,..."  (cell = order)
    local prisoners = {}
    local cell = 0
    for ty, fed, need in string.gmatch(a("Prisoners", ""), "(%a+):(%d+):(%d+)") do
        cell = cell + 1
        prisoners[#prisoners + 1] = { cell = cell, kind = ty, fed = tonumber(fed), need = tonumber(need) }
    end

    -- monsters
    local mons = {}
    if cfg.Monsters then
        local nx, ny = a("NestX", 0), a("NestY", 0)
        for _, m in pairs(monsters) do
            if m.owner == 0 and os.clock() - m.seen < 3 then
                local mc = Config.MONSTERS and Config.MONSTERS[m.kind] or {}
                local dx, dy = m.x - nx, m.y - ny
                table.insert(mons, {
                    id = m.id, kind = m.kind, down = m.state == 4,
                    hp_pct = math.floor(m.hp * 100), hp_max = mc.hp,
                    bite_dmg = mc.bite and mc.bite.dmg, speed = mc.speed,
                    capture_wood = mc.capture, tame_food = mc.tame,
                    pack = mc.pack, mound = mc.mound, wood_reward = mc.wood,
                    dist = math.floor(math.sqrt(dx * dx + dy * dy)),
                })
            end
        end
        table.sort(mons, function(x, y) return x.dist < y.dist end)
        while #mons > 6 do table.remove(mons) end
    end

    local upgrades = {}
    for lower, key in pairs(UPG) do
        local c = upgradeCost(key, f)
        if c == "max" then upgrades[lower] = "max"
        elseif type(c) == "table" then
            upgrades[lower] = { food = c.food, wood = c.wood, need_total_ants = c.need_ants, affordable = affordable(c, f) }
        else upgrades[lower] = "unknown" end
    end

    local start = World:GetAttribute("MatchStart")
    local sStats
    pcall(function() sStats = Config.antStats("Soldier", a("SoldierLv", 1)) end)
    return {
        t = start and math.floor(now - start) or 0,
        peace_left = math.max(0, math.floor((World:GetAttribute("PeaceUntil") or 0) - now)),
        playing = World:GetAttribute("MatchState") == "playing",
        me = {
            food = a("Food", 0), wood = a("Wood", 0),
            eggs_ready = a("Available", 0), eggs_growing = growing, nursery_cap = a("NurseryCap", 3),
            workers = a("Workers", 0), soldiers = soldiers, supers = a("Supers", 0), pets = a("Pets", 0),
            total_ants = a("Total", 0),
            free_soldiers = freeSoldiers(f),
            soldier_lv = a("SoldierLv", 1), worker_lv = a("WorkerLv", 1), nest_lv = nestLv,
            soldier_stats = sStats,
            nest_hp_pct = math.floor(100 * a("NestHP", 0) / nestMax),
            power = math.floor(a("Power", 0)),
            want_wood = a("WantWood", 0), want_feeders = a("WantFeeders", 0), on_food = a("JobFood", 0),
            under_raid = next(incoming) ~= nil,
            prison_open = nestLv >= PRISON_LEVEL, prisoners = prisoners,
        },
        upgrades = upgrades,
        enemies = enemies,
        allies = allyList, ally_max = ALLY_MAX, my_pending_ally_requests = outReq,
        ally_requests_to_me = asks,
        wild_monsters_in_view = mons,
        super_food_cost = SUPER_FOOD, max_feeders = MAX_FEEDERS,
    }, f
end

-- action executor (all validation lives here). returns msg, quiet ---------------------------------
local lastUp = {}
local lastAtk, lastDef, lastHunt, lastAllyReq = 0, 0, 0, 0

local function setJob(f, kind, attr, target)
    local workers = f:GetAttribute("Workers") or 0
    local cap = kind == "Feeder" and math.min(MAX_FEEDERS, workers) or workers
    target = math.clamp(target, 0, cap)
    local d = target - (f:GetAttribute(attr) or 0)
    local step = d > 0 and 1 or -1
    for _ = 1, math.min(math.abs(d), 10) do
        Action:FireServer("Job", kind, step)
        task.wait(0.08)
    end
    return d
end

local function exec(a, f)
    local k = tostring(a.type or a.action or ""):lower()

    if k == "hatch" then
        local role = ({ worker = "Worker", soldier = "Soldier", super = "Super" })[tostring(a.role or ""):lower()]
        if not role then return "hatch: bad role" end
        local n = math.clamp(int(a.n, 1), 1, 10)
        local ready = f:GetAttribute("Available") or 0
        local food = f:GetAttribute("Food") or 0
        local sent = 0
        for _ = 1, n do
            if ready <= 0 then break end
            if role == "Super" then
                if food < SUPER_FOOD then break end
                food = food - SUPER_FOOD
            end
            Action:FireServer("Role", role, 1)
            ready = ready - 1
            sent = sent + 1
            task.wait(0.15)
        end
        if sent == 0 then return "hatch " .. role .. ": nothing (no egg/food)", true end
        return string.format("hatch %s x%d", role, sent)

    elseif k == "upgrade" then
        local key = UPG[tostring(a.what or ""):lower()]
        if not key then return "upgrade: bad target" end
        local c = upgradeCost(key, f)
        if c == "max" then return "upgrade " .. key .. ": already max", true end
        if type(c) == "table" then
            if not affordable(c, f) then
                return string.format("upgrade %s: skipped, needs %df/%dw%s", key, c.food, c.wood, c.need_ants and (" & " .. c.need_ants .. " ants") or ""), true
            end
        else
            -- costs unknown (Config layout differs): blind try, long backoff so the game's error toast isn't spammed
            if os.clock() - (lastUp[key] or -99) < 30 then return "upgrade " .. key .. ": backoff", true end
        end
        if os.clock() - (lastUp[key] or -99) < 3 then return "upgrade " .. key .. ": cooldown", true end
        lastUp[key] = os.clock()
        local before = f:GetAttribute(UPG_ATTR[key])
        Action:FireServer("Upgrade", key)
        task.wait(0.7)
        local after = f:GetAttribute(UPG_ATTR[key])
        return "upgrade " .. key .. (after ~= before and ": OK" or ": failed")

    elseif k == "job" then
        local out = {}
        if a.wood ~= nil then out[#out + 1] = "wood " .. setJob(f, "Wood", "WantWood", int(a.wood, 0)) end
        if a.feeders ~= nil then out[#out + 1] = "feeders " .. setJob(f, "Feeder", "WantFeeders", int(a.feeders, 0)) end
        return "job " .. table.concat(out, ", ")

    elseif k == "attack" then
        if workspace:GetServerTimeNow() < (World:GetAttribute("PeaceUntil") or 0) then return "attack: peace not over", true end
        if os.clock() - lastAtk < 8 then return "attack: cooldown", true end
        local idx = int(a.target, nil)
        local c = idx and colonyByIndex(idx)
        if not c or c == f then return "attack: target gone" end
        if allySet(f)[idx] then return "attack: target is my ally" end
        local free = freeSoldiers(f)
        local n = (a.soldiers == "all" or a.soldiers == nil) and free or math.min(int(a.soldiers, free), free)
        if n < 1 then return "attack: no free soldiers", true end
        local pets = (a.pets == "all") and (f:GetAttribute("Pets") or 0) or math.min(int(a.pets, 0), f:GetAttribute("Pets") or 0)
        lastAtk = os.clock()
        Action:FireServer("AttackNest", idx, n, pets)
        task.wait(0.7)
        local ok = parseOrders(f:GetAttribute("NestOrders"))[tostring(idx)] ~= nil
        return string.format("attack #%d with %d+%dpets: %s", idx, n, pets, ok and "sent" or "no order registered")

    elseif k == "defend" then
        if os.clock() - lastDef < 5 then return "defend: cooldown", true end
        lastDef = os.clock()
        Action:FireServer("Defend")
        return "defend"

    elseif k == "hunt" then
        if not cfg.Monsters then return "hunt: disabled", true end
        if os.clock() - lastHunt < 6 then return "hunt: cooldown", true end
        local id = int(a.target, nil)
        local m = id and monsters[id]
        if not m or m.owner ~= 0 then return "hunt: monster not in view" end
        if m.state == 4 then return "hunt: already knocked out (use capture)", true end
        local free = freeSoldiers(f)
        local n = (a.soldiers == "all" or a.soldiers == nil) and free or math.min(int(a.soldiers, free), free)
        if n < 1 then return "hunt: no free soldiers", true end
        local pets = (a.pets == "all") and (f:GetAttribute("Pets") or 0) or math.min(int(a.pets, 0), f:GetAttribute("Pets") or 0)
        lastHunt = os.clock()
        Action:FireServer("Hunt", id, n, pets)
        return string.format("hunt %s #%d with %d+%dpets", m.kind, id, n, pets)

    elseif k == "capture" then
        if not cfg.Monsters then return "capture: disabled", true end
        local id = int(a.target, nil)
        local m = id and monsters[id]
        if not m or m.owner ~= 0 or m.state ~= 4 then return "capture: monster not knocked out/in view", true end
        local need = Config.MONSTERS and Config.MONSTERS[m.kind] and Config.MONSTERS[m.kind].capture or 0
        if (f:GetAttribute("Wood") or 0) < need then return string.format("capture: needs %d wood", need), true end
        if (f:GetAttribute("NestLevel") or 1) < PRISON_LEVEL then return "capture: prison locked", true end
        Action:FireServer("Capture", id)
        return "capture " .. m.kind .. " #" .. id

    elseif k == "tame" then
        if not cfg.Monsters then return "tame: disabled", true end
        local cell = int(a.cell, nil)
        local target
        local cn = 0
        for ty, fed, need in string.gmatch(f:GetAttribute("Prisoners") or "", "(%a+):(%d+):(%d+)") do
            cn = cn + 1
            if cn == cell then target = { ty = ty, fed = tonumber(fed), need = tonumber(need) } end
        end
        if not target then return "tame: no prisoner in that cell", true end
        local presses = math.ceil(math.max(0, target.need - target.fed) / 10)
        local food = f:GetAttribute("Food") or 0
        presses = math.min(presses, math.floor(food / 10), int(a.max_presses, 20), 30)
        if presses < 1 then return "tame: no food", true end
        for _ = 1, presses do
            Action:FireServer("Tame", cell)
            task.wait(0.1)
        end
        return string.format("tame %s cell %d x%d (+%d food)", target.ty, cell, presses, presses * 10)

    elseif k == "ally_answer" then
        if not cfg.Allies then return "ally_answer: disabled", true end
        local from = int(a.from, nil)
        local found
        for key, p in pairs(pendingAsks) do
            if p.from == from then found = p; pendingAsks[key] = nil end
        end
        if not found then return "ally_answer: request expired", true end
        local accept = a.accept == true
        if accept and found.kind == "ally" and sumOrders({}) == 0 then
            local cnt = 0
            for _ in pairs(allySet(f)) do cnt = cnt + 1 end
            if cnt >= ALLY_MAX then accept = false end
        end
        Action:FireServer("AllyAnswer", from, accept)
        return string.format("ally %s from #%d: %s", found.kind, from, accept and "ACCEPT" or "decline")

    elseif k == "ally_request" then
        if not cfg.Allies then return "ally_request: disabled", true end
        if os.clock() - lastAllyReq < 20 then return "ally_request: cooldown", true end
        local idx = int(a.target, nil)
        if not idx or not colonyByIndex(idx) or allySet(f)[idx] then return "ally_request: bad target", true end
        local cnt = 0
        for _ in pairs(allySet(f)) do cnt = cnt + 1 end
        if cnt >= ALLY_MAX then return "ally_request: max allies", true end
        lastAllyReq = os.clock()
        Action:FireServer("AllyRequest", idx)
        return "ally_request -> #" .. idx

    elseif k == "ally_soldiers" then
        if not cfg.Allies then return "ally_soldiers: disabled", true end
        local idx = int(a.target, nil)
        if not idx or not allySet(f)[idx] then return "ally_soldiers: not an ally", true end
        for i, exp in string.gmatch(f:GetAttribute("LendCd") or "", "(%d+):(%d+)") do
            if tonumber(i) == idx and tonumber(exp) > workspace:GetServerTimeNow() then return "ally_soldiers: on cooldown", true end
        end
        Action:FireServer("AllySoldiers", idx)
        return "ally_soldiers <- #" .. idx

    elseif k == "wait" then
        return "wait", true
    end
    return "unknown action: " .. k
end

-- heuristic fallback (same schema as the LLM output) ---------------------------------------------------
local function heuristic(S)
    local me, acts = S.me, {}

    -- allies first (requests expire in ~15s)
    if cfg.Allies then
        local cnt = #S.allies
        for _, r in ipairs(S.ally_requests_to_me) do
            local accept = false
            if r.kind == "ally" then accept = (cnt < S.ally_max) and not r.already_ally
            elseif r.kind == "soldiers" then accept = me.free_soldiers >= (r.soldiers_requested or 3) + 10 and not me.under_raid
            elseif r.kind == "help" then accept = me.free_soldiers >= (r.soldiers_requested or 3) + 12 and not me.under_raid end
            if accept and r.kind == "ally" then cnt = cnt + 1 end
            acts[#acts + 1] = { type = "ally_answer", from = r.from, accept = accept }
        end
        if cnt < S.ally_max and #S.my_pending_ally_requests == 0 and #S.enemies > 0 and S.t > 30 then
            acts[#acts + 1] = { type = "ally_request", target = S.enemies[1].index }
        end
        for _, al in ipairs(S.allies) do
            if al.lend_ready and (me.under_raid or me.free_soldiers < 10) then
                acts[#acts + 1] = { type = "ally_soldiers", target = al.index }
            end
        end
    end

    local w, s = me.workers, me.soldiers + me.supers
    if me.eggs_ready > 0 then
        local nw, ns = 0, 0
        for _ = 1, me.eggs_ready do
            local wk, sd = w + nw, s + ns
            if wk < 6 or (wk < 14 and sd >= wk * 0.8) then nw = nw + 1 else ns = ns + 1 end
        end
        if nw > 0 then acts[#acts + 1] = { type = "hatch", role = "worker", n = nw } end
        if ns > 0 then
            if me.food >= SUPER_FOOD * 1.5 and s >= 6 then
                acts[#acts + 1] = { type = "hatch", role = "super", n = 1 }
                ns = ns - 1
            end
            if ns > 0 then acts[#acts + 1] = { type = "hatch", role = "soldier", n = ns } end
        end
    end
    local feeders = w >= 3 and math.clamp(math.floor(w * 0.3) + 1, 1, MAX_FEEDERS) or 0
    local wood = (me.wood < 40 and w >= 4) and math.floor(w * 0.25) or 0
    acts[#acts + 1] = { type = "job", feeders = feeders, wood = wood }

    local order = { "nursery", me.worker_lv <= me.soldier_lv and "worker" or "soldier", "nest" }
    for _, k in ipairs(order) do
        local u = S.upgrades[k]
        if type(u) == "table" and u.affordable then acts[#acts + 1] = { type = "upgrade", what = k } end
    end

    if cfg.Monsters then
        for _, p in ipairs(me.prisoners) do
            if me.food >= (p.need - p.fed) + 60 then acts[#acts + 1] = { type = "tame", cell = p.cell } end
        end
        for _, m in ipairs(S.wild_monsters_in_view) do
            if m.down and m.capture_wood and me.wood >= m.capture_wood and me.prison_open then
                acts[#acts + 1] = { type = "capture", target = m.id }
            elseif not m.down and not m.pack and not m.mound and m.dist < 900 then
                local need = (m.kind == "Scorpion") and 20 or 12
                if me.free_soldiers >= need and S.peace_left <= 0 then
                    acts[#acts + 1] = { type = "hunt", target = m.id, soldiers = need, pets = "all" }
                    break
                end
            end
        end
    end

    if S.peace_left <= 0 and me.free_soldiers >= 6 then
        local best
        for _, e in ipairs(S.enemies) do
            if e.power <= me.power * 0.8 and (not best or e.power < best.power) then best = e end
        end
        if best then acts[#acts + 1] = { type = "attack", target = best.index, soldiers = "all", pets = "all" } end
    end
    return { thought = "heuristic", actions = acts }
end

-- LLM ---------------------------------------------------------------------------------------------------
local SYS = [[
You control one ant colony in a real-time ant-war game against AI colonies (medium difficulty). GOAL: win = destroy every enemy colony's nest while keeping yours alive.
Mechanics:
- Workers gather food automatically. Workers assigned to "wood" bring wood; workers assigned to "feeders" (max max_feeders) feed the queen, which lays eggs into the nursery (cap = nursery_cap). Unassigned workers gather food.
- Ready eggs (eggs_ready) are hatched into worker, soldier or super (super costs super_food_cost food, strongest). Hatched ants cannot be changed. Never leave eggs_ready unused.
- Upgrades: state.upgrades gives the EXACT cost and whether it is affordable. Only request upgrades with affordable=true (others are silently skipped). nest upgrades also need total ants >= need_total_ants.
- Raids are impossible while peace_left > 0. Afterwards AI colonies raid you (under_raid=true): use "defend" to call soldiers home.
- "attack" sends free soldiers (and pets) to an enemy nest. Attack only when enemy power < ~0.8 * my power, or its nest is damaged. One target at a time; nearer is better; keep some soldiers home if raids are frequent.
MONSTERS (wild_monsters_in_view; only those near the camera are visible):
- Scorpion and spider kill ants fast: a scorpion one-shots a worker, kills a soldier in 2 bites, a super in 3-4 bites. A spider needs about 3 bites on a super. Scorpion is stronger than spider. Workers near monsters die, so a monster close to the nest or food is a threat.
- hunt {target:monster id, soldiers:n, pets} sends soldiers to fight it; send a big enough army (soldiers die to bites; compare soldier count/level with hp_max and bite_dmg). When hp reaches 0 it becomes "down" (knocked out).
- capture {target:id} cages a DOWN monster; costs capture_wood wood; requires prison_open (nest level). Then it sits in a prison cell (me.prisoners) and "tame" {cell} feeds it 10 food per press until fed==need. A tamed monster becomes a PET that fights for you in attacks/hunts (pets param). Worth it when the economy is healthy (food well above the remaining need) and your army is too small or you want a strong pet; skip when food is tight or you're being raided.
- termite packs/mounds (pack/mound flags) give wood when killed; low priority.
ALLIES:
- ally_requests_to_me are live requests from other colonies and expire within ~15 seconds, answer them NOW. kind "ally": they want an alliance (allies can't hurt each other, can lend soldiers). Accept if it covers an exposed side, the requester is strong/near, or it removes a dangerous neighbour from the enemy list; decline if you already have ally_max or the requester is weak/far and useless. kind "soldiers": they ask me to lend n soldiers (accept only if free_soldiers is comfortably above n and I'm not raided). kind "help": an ally is being raided and asks for n soldiers (same rule). Max ally_max allies. Allies show in state.allies and are NOT valid attack targets. Betrayal exists, don't rely on one ally alone.
- ally_request {target:index} asks a colony to ally (cooldown 20s). ally_soldiers {target:ally index} asks an ally to lend 3 soldiers (only if lend_ready; long cooldown, so use it before a big attack or when raided).
Typical plan: first ~10 workers, 1-2 feeders (more while nursery isn't full), 1-3 wood workers; nursery+worker upgrades early, then soldiers/supers, then hunt monsters/attack the weakest nearby colony repeatedly.
You receive a JSON state each turn plus last_results and your previous notes. Reply with ONLY one JSON object, no markdown:
{"thought":"<=30 words plan","actions":[ ... max 10 ... ]}
Allowed actions:
{"type":"hatch","role":"worker|soldier|super","n":1-10}
{"type":"upgrade","what":"nursery|worker|soldier|nest"}
{"type":"job","wood":<target wood workers>,"feeders":<target feeders>}   (either key optional)
{"type":"attack","target":<enemy colony index>,"soldiers":"all" or number,"pets":"all" or number}
{"type":"hunt","target":<monster id>,"soldiers":number,"pets":"all" or number}
{"type":"capture","target":<monster id>}
{"type":"tame","cell":<prisoner cell>}
{"type":"ally_answer","from":<colony index>,"accept":true|false}
{"type":"ally_request","target":<colony index>}
{"type":"ally_soldiers","target":<ally colony index>}
{"type":"defend"}
{"type":"wait"}
]]

local function extractJson(s)
    s = tostring(s or "")
    local a, b = s:find("{"), nil
    for i = #s, 1, -1 do if s:sub(i, i) == "}" then b = i break end end
    if not a or not b then return nil end
    local ok, t = pcall(HttpService.JSONDecode, HttpService, s:sub(a, b))
    if ok and type(t) == "table" then return t end
end

local function askAI(S, results, notes)
    if not httpReq then return nil, "executor has no request()" end
    if cfg.Key == "" or cfg.Key:find("PUT_") then return nil, "no API key" end
    S.last_results = results
    S.my_previous_notes = notes
    local body = HttpService:JSONEncode({
        model = cfg.Model,
        temperature = cfg.Temperature,
        max_tokens = cfg.MaxTokens,
        messages = {
            { role = "system", content = SYS },
            { role = "user", content = HttpService:JSONEncode(S) },
        },
    })
    local ok, res = pcall(httpReq, {
        Url = "https://openrouter.ai/api/v1/chat/completions",
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. cfg.Key,
            ["X-Title"] = "AntBot",
        },
        Body = body,
    })
    if not ok then return nil, "http error: " .. tostring(res) end
    if res.StatusCode ~= 200 then return nil, "HTTP " .. tostring(res.StatusCode) .. " " .. tostring(res.Body):sub(1, 120) end
    local okJ, j = pcall(HttpService.JSONDecode, HttpService, res.Body)
    local content = okJ and j.choices and j.choices[1] and j.choices[1].message and j.choices[1].message.content
    local plan = extractJson(content)
    if not plan or type(plan.actions) ~= "table" then return nil, "bad reply: " .. tostring(content):sub(1, 100) end
    return plan
end

-- main loop ------------------------------------------------------------------------------------------
local alive = true
local fails, heurUntil = 0, 0
local lastDecide = -99
local results, notes = {}, ""
local statusLabel

local function decide()
    local S, f = snapshot()
    if not S then return "no colony" end
    if not S.playing then return "waiting for match" end
    local plan, err
    if cfg.UseAI and os.clock() > heurUntil then
        plan, err = askAI(S, results, notes)
        if plan then fails = 0 else
            fails = fails + 1
            log("AI fail (" .. fails .. "): " .. tostring(err))
            if fails >= 3 then heurUntil = os.clock() + 60; fails = 0; log("AI down 60s -> heuristic") end
        end
    end
    local usedAI = plan ~= nil
    plan = plan or heuristic(S)
    notes = tostring(plan.thought or ""):sub(1, 200)
    log((usedAI and "AI: " or "H: ") .. notes)
    results = {}
    for i, a in ipairs(plan.actions) do
        if i > 10 then break end
        if type(a) == "table" then
            local ok, r, quiet = pcall(exec, a, f)
            if not ok then r = "err " .. tostring(r) end
            results[#results + 1] = r
            if not quiet then log(" > " .. tostring(r)) end
            task.wait(0.1)
        end
    end
    return "ok"
end

task.spawn(function()
    while alive do
        task.wait(0.5)
        if cfg.Run then
            pcall(function()
                local f = myFolder()
                if f and cfg.AutoDefend and next(parseOrders(f:GetAttribute("Incoming"))) and os.clock() - lastDef > 6 then
                    lastDef = os.clock()
                    Action:FireServer("Defend")
                    log("reflex: defend")
                end
            end)
            if urgent or os.clock() - lastDecide >= cfg.Interval then
                urgent = false
                lastDecide = os.clock()
                local ok, r = pcall(decide)
                if not ok then log("decide err: " .. tostring(r)) end
                if statusLabel then pcall(function() statusLabel.Text = ok and tostring(r) or "error" end) end
            end
        end
    end
end)

-- UI -----------------------------------------------------------------------------------------------------
local saved = env.__ANT_POS or {}

local gui = Instance.new("ScreenGui")
gui.Name = "AntAI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 1000
local pg = lp:FindFirstChildOfClass("PlayerGui") or lp:WaitForChild("PlayerGui", 10)
gui.Parent = pg

local frame, mini
local function savePos()
    pcall(function()
        env.__ANT_POS = {
            frame = { frame.Position.X.Offset, frame.Position.Y.Offset },
            mini = { mini.Position.X.Offset, mini.Position.Y.Offset },
        }
    end)
end

local function draggable(handle, target, onTap)
    local dragging, moved, start, startPos
    track(handle.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging, moved, start, startPos = true, false, i.Position, target.Position
            local c
            c = i.Changed:Connect(function()
                if i.UserInputState == Enum.UserInputState.End then
                    dragging = false
                    c:Disconnect()
                    if moved then savePos() elseif onTap then pcall(onTap) end
                end
            end)
        end
    end))
    track(UIS.InputChanged:Connect(function(i)
        if not dragging then return end
        if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
            local d = i.Position - start
            if d.Magnitude > 6 then moved = true end
            if moved then
                pcall(function() target.Position = UDim2.fromOffset(startPos.X.Offset + d.X, startPos.Y.Offset + d.Y) end)
            end
        end
    end))
end

local fp = saved.frame or { 12, 120 }
frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(310, 0)
frame.AutomaticSize = Enum.AutomaticSize.Y
frame.Position = UDim2.fromOffset(fp[1], fp[2])
frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
frame.BorderSizePixel = 0
frame.Parent = gui
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 2)
layout.Parent = frame

local bar = Instance.new("Frame")
bar.Size = UDim2.new(1, 0, 0, 30)
bar.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
bar.BorderSizePixel = 0
bar.LayoutOrder = 0
bar.Parent = frame
local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -30, 1, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.Code
title.TextSize = 14
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = "ANT AI v2 (drag)"
title.Parent = bar
local close = Instance.new("TextButton")
close.Size = UDim2.fromOffset(30, 30)
close.Position = UDim2.new(1, -30, 0, 0)
close.BackgroundColor3 = Color3.fromRGB(150, 40, 40)
close.BorderSizePixel = 0
close.Font = Enum.Font.Code
close.TextSize = 15
close.TextColor3 = Color3.new(1, 1, 1)
close.Text = "X"
close.Parent = bar
track(close.Activated:Connect(function() frame.Visible = false end))
draggable(title, frame)

local order = 0
local function toggle(text, key)
    order = order + 1
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 28)
    b.BorderSizePixel = 0
    b.Font = Enum.Font.Code
    b.TextSize = 14
    b.TextColor3 = Color3.new(1, 1, 1)
    b.LayoutOrder = order
    local function refresh()
        b.Text = text .. ": " .. (cfg[key] and "ON" or "OFF")
        b.BackgroundColor3 = cfg[key] and Color3.fromRGB(40, 120, 70) or Color3.fromRGB(40, 40, 48)
    end
    track(b.Activated:Connect(function() cfg[key] = not cfg[key]; refresh() end))
    refresh()
    b.Parent = frame
end
toggle("Bot running", "Run")
toggle("AI (OpenRouter)", "UseAI")
toggle("Auto defend", "AutoDefend")
toggle("Monsters (hunt/tame)", "Monsters")
toggle("Allies", "Allies")

order = order + 1
statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, 0, 0, 22)
statusLabel.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
statusLabel.BorderSizePixel = 0
statusLabel.Font = Enum.Font.Code
statusLabel.TextSize = 13
statusLabel.TextColor3 = Color3.fromRGB(180, 255, 180)
statusLabel.Text = "starting"
statusLabel.LayoutOrder = order
statusLabel.Parent = frame

order = order + 1
logLabel = Instance.new("TextLabel")
logLabel.Size = UDim2.new(1, 0, 0, 0)
logLabel.AutomaticSize = Enum.AutomaticSize.Y
logLabel.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
logLabel.BorderSizePixel = 0
logLabel.Font = Enum.Font.Code
logLabel.TextSize = 12
logLabel.TextColor3 = Color3.new(1, 1, 1)
logLabel.TextXAlignment = Enum.TextXAlignment.Left
logLabel.TextWrapped = true
logLabel.Text = "-"
logLabel.LayoutOrder = order
logLabel.Parent = frame

local mp = saved.mini or { 12, 70 }
mini = Instance.new("TextButton")
mini.Size = UDim2.fromOffset(44, 44)
mini.Position = UDim2.fromOffset(mp[1], mp[2])
mini.BackgroundColor3 = Color3.fromRGB(30, 30, 38)
mini.BorderSizePixel = 0
mini.Font = Enum.Font.Code
mini.TextSize = 15
mini.TextColor3 = Color3.new(1, 1, 1)
mini.Text = "AI"
mini.Parent = gui
draggable(mini, mini, function() frame.Visible = not frame.Visible end)

env.__ANT_STOP = function()
    alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
end

log("loaded v2. model=" .. cfg.Model .. (httpReq and "" or " | NO request()!"))
