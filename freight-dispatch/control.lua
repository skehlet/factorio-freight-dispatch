-- Freight Dispatch: a railway tycoon game mode for Factorio 2.1
local C = require("scripts.config")
local gui -- set below (needs functions from here)

local M = {}

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

local function rand()
  -- deterministic LCG stored in storage so saves/MP stay in sync
  storage.seed = (storage.seed * 1103515245 + 12345) % 2147483648
  return storage.seed / 2147483648
end

local function rand_int(a, b)
  return a + math.floor(rand() * (b - a + 1))
end

local function pick(list)
  return list[rand_int(1, #list)]
end

local function dist(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx * dx + dy * dy)
end

function M.fmt(n)
  n = math.floor(n + 0.5)
  local neg = n < 0
  local s = tostring(math.abs(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  return (neg and "-" or "") .. out
end
local fmt = M.fmt

function M.money_str(n)
  return "$" .. fmt(n)
end

local function surface()
  return game.surfaces[C.SURFACE]
end

local function force()
  return game.forces[C.FORCE]
end

local function throttle(key, ticks)
  storage.throttle = storage.throttle or {}
  local last = storage.throttle[key]
  if last and game.tick - last < ticks then return false end
  storage.throttle[key] = game.tick
  return true
end

local function flying_text(position, text, color, player)
  local players = player and { player } or force().connected_players
  for _, p in pairs(players) do
    if p.valid and p.surface.name == C.SURFACE then
      p.create_local_flying_text({ text = text, position = position, color = color })
    end
  end
end

-- Power (0.4.1): x1.25 for a site inside a running power plant's supply radius, else 1
local function power_mult(site)
  return site.powered_by and (1 + C.POWER.bonus) or 1
end
M.power_mult = power_mult

-- Spaceport (0.7.0) ----------------------------------------------------------
-- Satellite network: every launch adds C.SPACEPORT.satellite, up to the cap. Since 0.7.8 it
-- multiplies town passengers and mail and every power plant's supply radius (it was a fare
-- multiplier before, which only grew a cash pile nothing needed).
local function sat_mult()
  return 1 + math.min(C.SPACEPORT.satellite_cap, (storage.rockets or 0) * C.SPACEPORT.satellite)
end
M.sat_mult = sat_mult

-- 0.7.8: more than one Spaceport. M.spaceport() is the first (the free one), M.spaceports() all
-- of them in id order.
function M.spaceports()
  local list = {}
  for _, s in pairs(storage.sites) do
    if s.kind == "spaceport" then table.insert(list, s) end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

function M.spaceport()
  local s = storage.spaceport_id and storage.sites[storage.spaceport_id]
  return s or M.spaceports()[1]
end

-- price of the next Spaceport bought in the Shop (the first one is free at Railway Tycoon)
function M.pad_price()
  local n = (storage.pads_bought or 0) + 1
  local p = C.SPACEPORT.buy_prices
  return p[math.min(n, #p)] * 2 ^ math.max(0, n - #p)
end

local function pad_need(site)
  return C.SPACEPORT.levels[math.min(site.level, #C.SPACEPORT.levels)]
end
M.pad_need = pad_need

local function pad_state(site)
  site.pad = site.pad or { colonists = 0, mail = 0, goods = 0, paid = 0 }
  site.pad.goods = site.pad.goods or 0 -- 0.7.0 saves
  return site.pad
end
M.pad_state = pad_state

-- what the pad still takes of this cargo for the rocket being built
local function pad_room(site, item)
  local need, st = pad_need(site), pad_state(site)
  if item == "fd-passengers" then return math.max(0, need.colonists - st.colonists) end
  if item == "fd-mail" then return math.max(0, need.mail - st.mail) end
  if item == "fd-goods" then return math.max(0, need.goods - st.goods) end
  return 0
end

local function pad_reserve()
  return C.SPACEPORT.reserves[storage.pad_reserve or C.SPACEPORT.default_reserve] or 0
end
M.pad_reserve = pad_reserve

local function pad_rate(site)
  return pad_need(site).cost / C.SPACEPORT.build_secs
end

-- 0.7.7: share of the rocket's cargo aboard (average of colonists, mail and goods, each capped at
-- 1). Assembly is paid only up to this share of the cost, so it follows the deliveries.
local function pad_cargo_frac(site)
  local need, st = pad_need(site), pad_state(site)
  local function f(have, want) return math.min(1, have / math.max(1, want)) end
  return (f(st.colonists, need.colonists) + f(st.mail, need.mail) + f(st.goods, need.goods)) / 3
end
M.pad_cargo_frac = pad_cargo_frac

-- minutes of assembly left once all the cargo is aboard
local function pad_minutes_left(site)
  local st = pad_state(site)
  return math.max(0, (pad_need(site).cost - st.paid) / pad_rate(site) / 60)
end
M.pad_minutes_left = pad_minutes_left

-- Flow meters (0.5.0, for the Supply chain window): each site adds up what happens to it this
-- minute in site.fl_cur, and simulate_minute pushes that onto site.fl_hist (newest first, at
-- most C.FLOW_MINUTES). Keys: "mk:<item>" made, "rx:<item>" delivered by train, "tx:<item>"
-- picked up, "busy"/"starve"/"block" (fractions of a second at full speed, short of the main
-- input, paused by a full output pile), "full" (seconds with a full stockpile), "bdef"/"proc"
-- (booster shortfall weighted by processed main input), "secs" (seconds counted).
local function fl_add(site, key, v)
  local c = site.fl_cur
  if not c then c = {}; site.fl_cur = c end
  c[key] = (c[key] or 0) + v
end

local function fl_sum(site, key)
  local t = (site.fl_cur and site.fl_cur[key]) or 0
  for _, h in pairs(site.fl_hist or {}) do t = t + (h[key] or 0) end
  return t
end

-- per-second average over the window (0 until the site has been measured)
local function fl_rate(site, key)
  local secs = fl_sum(site, "secs")
  return secs > 0 and fl_sum(site, key) / secs or 0
end
M.fl_rate = fl_rate

-- Goods a town needs per new resident; rises with population so big cities take many goods.
-- A powered town grows 25% more per good.
function M.goods_per_resident(site)
  return C.GOODS_PER_RESIDENT * math.max(1, site.pop / 1000) ^ C.GROWTH_EXP / power_mult(site)
end

-- Train liveries (0.3.5): the mod paints each carriage once and remembers it in
-- storage.painted[unit_number]. (Comparing colours doesn't work: new locomotives come out
-- pure red rather than their prototype colour, and wagons copy the locomotive's colour.)
-- A train takes the current colour of its first painted carriage, so a colour the player
-- set by hand is kept and spreads to new carriages coupled on, or else a random
-- C.TRAIN_COLORS entry. Carriages painted before are never repainted.
local function paint_train(train)
  if not (train and train.valid) then return end
  storage.painted = storage.painted or {}
  local target
  for _, c in pairs(train.carriages) do
    if storage.painted[c.unit_number] and c.color then target = c.color; break end
  end
  target = target or C.TRAIN_COLORS[rand_int(1, #C.TRAIN_COLORS)]
  for _, c in pairs(train.carriages) do
    if not storage.painted[c.unit_number] then
      pcall(function()
        c.color = target
        -- otherwise the locomotive takes each (default red) stop's colour on arrival
        if c.type == "locomotive" then c.copy_color_from_train_stop = false end
      end)
      storage.painted[c.unit_number] = true
      script.register_on_object_destroyed(c)
    end
  end
end
M.paint_train = paint_train

local function earn(amount)
  storage.money = storage.money + amount
  if amount > 0 then
    storage.earned_sec = storage.earned_sec + amount
    storage.lifetime = storage.lifetime + amount
  end
end

local function spend(amount)
  if storage.money < amount then return false end
  storage.money = storage.money - amount
  storage.spent_total = (storage.spent_total or 0) + amount
  return true
end
M.spend = spend
M.earn = earn

-- Upgrades ----------------------------------------------------------------

local function upgrade_def(id)
  for _, u in pairs(C.UPGRADES) do
    if u.id == id then return u end
  end
end

-- current tier table of an upgrade ("fuel", "wagons", "loading")
local function upgrade_tier(id)
  local u = upgrade_def(id)
  local level = (storage.upgrades and storage.upgrades[id]) or 1
  return u.tiers[math.min(level, #u.tiers)], level
end
M.upgrade_tier = upgrade_tier

local function load_rate()
  return upgrade_tier("loading").rate
end

-- 0.9.7: the Industry upgrade (mines, camps, mills and factories)
local function industry_mult()
  return upgrade_tier("industry").mult or 1
end
M.industry_mult = industry_mult

local function industry_part(m)
  if industry_mult() > 1 then table.insert(m, string.format("industry x%g", industry_mult())) end
end

-- price of a whole entity/tile prototype (sum of items needed to place it)
local function prototype_cost(proto)
  if not proto then return nil end
  local items = proto.items_to_place_this
  if not items or not items[1] then return nil end
  local it = items[1]
  local name = type(it) == "string" and it or it.name
  if type(name) ~= "string" then name = name.name end
  local count = (type(it) == "table" and it.count) or 1
  local price = C.PRICES[name]
  if not price then return nil end
  return price * count, name
end

local function ghost_cost(ghost)
  return prototype_cost(ghost.ghost_prototype)
end

local function entity_cost(entity)
  return prototype_cost(entity.prototype)
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

local function new_place_name()
  storage.used_names = storage.used_names or {}
  for _ = 1, 50 do
    local n = pick(C.NAME_PREFIX) .. pick(C.NAME_SUFFIX)
    if not storage.used_names[n] then
      storage.used_names[n] = true
      return n
    end
  end
  local n = pick(C.NAME_PREFIX) .. pick(C.NAME_SUFFIX) .. " " .. rand_int(2, 99)
  storage.used_names[n] = true
  return n
end

---------------------------------------------------------------------------
-- Terrain helpers
---------------------------------------------------------------------------

local water_names
local function get_water_names()
  if water_names then return water_names end
  water_names = {}
  for _, n in pairs({ "water", "deepwater", "water-green", "deepwater-green", "water-shallow", "water-mud", "water-wube" }) do
    if prototypes.tile[n] then table.insert(water_names, n) end
  end
  return water_names
end

local function box(x, y, r)
  return { { x - r, y - r }, { x + r, y + r } }
end

-- Is any of the player's own stuff in the area? (Ignores the invisible map-memory radars.)
local function player_stuff(surf, area)
  local n = surf.count_entities_filtered({ area = area, force = C.FORCE })
  if n == 0 then return false end
  return n > surf.count_entities_filtered({ area = area, force = C.FORCE, name = "fd-eye" })
end

local function land_ok(surf, x, y, r)
  local names = get_water_names()
  if #names > 0 and surf.count_tiles_filtered({ area = box(x, y, r), name = names }) > 0 then
    return false
  end
  if player_stuff(surf, box(x, y, r)) then
    return false
  end
  return true
end

local function clear_area(surf, area)
  for _, e in pairs(surf.find_entities_filtered({ area = area, type = { "tree", "simple-entity", "cliff", "fish" } })) do
    if e.valid then e.destroy() end
  end
  surf.destroy_decoratives({ area = area })
end

---------------------------------------------------------------------------
-- Sites
---------------------------------------------------------------------------

local function place_building(surf, name, x, y)
  local e = surf.create_entity({ name = name, position = { x, y }, force = "neutral", create_build_effect_smoke = false })
  if e then
    e.destructible = false
    e.minable_flag = false
    e.operable = false
  end
  return e
end

-- Town layout: four blocks of 3x3 buildings around a clear "railway street" cross.
-- Slot offsets are never 0, so buildings (centred at offset + 0.5, covering
-- offset-1 .. offset+2) leave a 7-tile corridor through the centre on both axes.
local TOWN_OFFSETS = { -17, -13, -9, -5, 5, 9, 13, 17 }
local TOWN_MARGIN = 12 -- free band between the outermost building and the ring

local function town_slots()
  local slots = {}
  for _, dx in pairs(TOWN_OFFSETS) do
    for _, dy in pairs(TOWN_OFFSETS) do
      table.insert(slots, { dx, dy })
    end
  end
  table.sort(slots, function(a, b)
    local da, db = a[1] * a[1] + a[2] * a[2], b[1] * b[1] + b[2] * b[2]
    if da ~= db then return da < db end
    if a[1] ~= b[1] then return a[1] < b[1] end
    return a[2] < b[2]
  end)
  return slots
end
local TOWN_SLOTS = town_slots()

-- Catchment radius of a site. Towns' rings grow (never shrink) as they add buildings.
local function site_radius(site)
  return math.max(site.radius or 0, C.KINDS[site.kind].radius)
end
M.site_radius = site_radius

local function town_target_buildings(pop)
  return math.min(#TOWN_SLOTS, math.max(3, math.floor(pop / 120) + 2))
end

local function update_ring(site)
  local r = C.KINDS[site.kind].radius
  for i in pairs(site.built or {}) do
    local s = TOWN_SLOTS[i]
    local d = math.sqrt((s[1] + 0.5) ^ 2 + (s[2] + 0.5) ^ 2) + 2.2 + TOWN_MARGIN
    if d > r then r = d end
  end
  r = math.ceil(r)
  if r > site_radius(site) then
    site.radius = r
    storage.stop_links = {} -- stops may now fall inside the bigger ring
    if site.render and site.render.ring and site.render.ring.valid then
      site.render.ring.radius = r
    end
  end
end

local function grow_town_buildings(site)
  local surf = surface()
  local target = town_target_buildings(site.pop)
  site.built = site.built or {}
  local i = 0
  -- Retry every free slot each time: a slot blocked by your track (or an ungenerated
  -- chunk) may open up later. Buildings keep a 1-tile gap from anything you built.
  while site.building_count < target and i < #TOWN_SLOTS do
    i = i + 1
    if not site.built[i] then
      local s = TOWN_SLOTS[i]
      local x, y = site.x + s[1] + 0.5, site.y + s[2] + 0.5
      local name = (i % 4 == 0) and "fd-shop" or "fd-house"
      if surf.is_chunk_generated({ math.floor(x / 32), math.floor(y / 32) })
          and not player_stuff(surf, box(x, y, 2.5)) then
        clear_area(surf, box(x, y, 1.6))
        if surf.can_place_entity({ name = name, position = { x, y }, force = "neutral" }) then
          place_building(surf, name, x, y)
          site.built[i] = true
          site.building_count = site.building_count + 1
        end
      end
    end
  end
  update_ring(site)
end

-- 0.1.9 migration: re-lay out towns built with the old solid grid (no street, fixed ring).
local function relayout_towns()
  local surf = surface()
  for _, site in pairs(storage.sites) do
    if site.kind == "town" and not site.built then
      for _, e in pairs(surf.find_entities_filtered({ area = box(site.x, site.y, 16), name = { "fd-house", "fd-shop" } })) do
        e.destroy()
      end
      site.building_count = 0
      site.slot = nil
      site.built = {}
      grow_town_buildings(site)
    end
  end
end

local function build_site_structures(surf, site)
  local k = site.kind
  local x, y = site.x, site.y
  if k == "town" then
    site.building_count = 0
    grow_town_buildings(site)
  elseif k == "coal-mine" or k == "iron-mine" then
    local ore = (k == "coal-mine") and "coal" or "iron-ore"
    if prototypes.entity[ore] then
      for _ = 1, 70 do
        local ox, oy = x + rand_int(-8, 8), y + rand_int(-8, 8)
        if dist(ox, oy, x, y) <= 8.5 then
          surf.create_entity({ name = ore, position = { ox + 0.5, oy + 0.5 }, amount = 5000 })
        end
      end
    end
    for _, o in pairs({ { -2, -2 }, { 2, -2 }, { -2, 2 }, { 2, 2 } }) do
      place_building(surf, "fd-drill", x + o[1] + 0.5, y + o[2] + 0.5)
    end
  elseif k == "forest" then
    place_building(surf, "fd-sawmill", x - 2 + 0.5, y + 0.5)
    place_building(surf, "fd-sawmill", x + 2 + 0.5, y + 0.5)
    local tree = prototypes.entity["tree-01"] and "tree-01" or nil
    if not tree then
      for name, _ in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "tree" } })) do
        tree = name
        break
      end
    end
    if tree then
      for _ = 1, 45 do
        local a = rand() * 2 * math.pi
        local r = 6 + rand() * 5
        surf.create_entity({ name = tree, position = { x + math.cos(a) * r, y + math.sin(a) * r } })
      end
    end
  elseif k == "steel-mill" then
    for _, dx in pairs({ -3, 0, 3 }) do
      for _, dy in pairs({ -2, 1 }) do
        place_building(surf, "fd-furnace", x + dx, y + dy)
      end
    end
  elseif k == "factory" then
    for _, o in pairs({ { -2, -2 }, { 2, -2 }, { -2, 2 }, { 2, 2 } }) do
      place_building(surf, "fd-factory", x + o[1] + 0.5, y + o[2] + 0.5)
    end
  elseif k == "spaceport" then
    place_building(surf, prototypes.entity["fd-spaceport-silo"] and "fd-spaceport-silo" or "fd-silo", x + 0.5, y + 0.5)
  elseif k == "power-plant" then
    for _, dx in pairs({ -4, 0, 4 }) do
      place_building(surf, "fd-generator", x + dx + 0.5, y + 0.5)
    end
  end
end

local function site_icon(site)
  return C.KINDS[site.kind].icon
end

local function site_title(site)
  local kind = C.KINDS[site.kind]
  local t = site.kind == "town" and site.name or (site.name .. " " .. kind.label)
  if site.no then t = t .. " [item=" .. C.variant("fd-passengers", site.no) .. "]" end
  return t
end
M.site_title = site_title

local function cargo_list_str(items)
  local parts = {}
  for _, it in pairs(items) do table.insert(parts, "[item=" .. it .. "]") end
  return table.concat(parts, " ")
end

local function supply_radius(site)
  return math.floor((C.POWER.radius + C.POWER.radius_per_level * (site.level - 1)) * sat_mult())
end
M.supply_radius = supply_radius

local function plant_running(site)
  return (site.fuel or 0) > 0
end

local function fuel_minutes(site)
  return (site.fuel or 0) / C.POWER.burn / 60
end

-- Site text (0.4.3): every site uses the same two lines.
--   status: inventory only. Level or population, then In (piles with limits), Out, Accepts.
--   detail: what it's doing. One state, its rate, the multipliers in the same "x" format and
--           order (level, boost, power, service), then progress to the next level.
-- Teaching sentences (what a booster is, lumber counts half...) live in the Help, not here.
local SEP = "  ·  "

local function icon(item)
  return "[item=" .. item .. "]"
end

local function pile(n, cap)
  n = math.floor(n or 0)
  local s = fmt(n) .. " / " .. fmt(cap)
  if n >= cap - 1 then s = s .. " (full)" end
  return s
end

local function next_level(site, done)
  local need = C.LEVEL_AT[site.level]
  if not need then return "Top level" end
  return "Next level " .. math.min(99, math.floor((done or 0) / need * 100)) .. "%"
end

local function mults(list)
  if #list == 0 then return "" end
  return "  (" .. table.concat(list, ", ") .. ")"
end

local function power_part(site, list)
  if site.powered_by then table.insert(list, string.format("power x%.2f", 1 + C.POWER.bonus)) end
end

local function money_short(n)
  if n >= 1000000 then return string.format("$%.1fM", n / 1000000) end
  return M.money_str(n)
end
M.money_short = money_short

function M.site_status(site)
  local kind = C.KINDS[site.kind]
  local parts = {}
  if site.kind == "spaceport" then
    local need, st = pad_need(site), pad_state(site)
    return table.concat({
      "Level " .. site.level,
      "Rocket " .. ((site.launches or 0) + 1) .. ": " .. icon("fd-passengers") .. " " .. fmt(st.colonists) .. " / " .. fmt(need.colonists) ..
        ", " .. icon("fd-mail") .. " " .. fmt(st.mail) .. " / " .. fmt(need.mail) ..
        ", " .. icon("fd-goods") .. " " .. fmt(st.goods) .. " / " .. fmt(need.goods) ..
        ", " .. money_short(st.paid) .. " / " .. money_short(need.cost),
    }, SEP)
  end
  if site.kind == "town" then
    table.insert(parts, "Pop " .. fmt(site.pop))
  else
    table.insert(parts, "Level " .. site.level)
  end
  if kind.secondary then
    local ins = {}
    for _, it in pairs(kind.accepts) do table.insert(ins, icon(it) .. " " .. pile(site.input[it], C.INPUT_CAP)) end
    table.insert(parts, "In: " .. table.concat(ins, ", "))
  elseif site.kind == "power-plant" then
    local f = math.floor(site.fuel or 0)
    local note = f >= C.POWER.cap - 1 and "full, " or ""
    table.insert(parts, "Fuel: " .. fmt(f) .. " / " .. fmt(C.POWER.cap) ..
      (f > 0 and string.format(" (%s%d min)", note, math.ceil(fuel_minutes(site))) or ""))
  end
  if #kind.produces > 0 then
    local outs = {}
    for _, it in pairs(kind.produces) do
      -- whole units only: trains load whole units, and a leftover fraction (e.g. 0.6) would
      -- otherwise round up to a phantom "1" while a train is loading
      if site.kind == "town" then
        table.insert(outs, icon(it) .. " " .. fmt(math.floor(site.stock[it] or 0)))
      else
        table.insert(outs, icon(it) .. " " .. pile(site.stock[it], C.STOCK_CAP * site.level))
      end
    end
    table.insert(parts, "Out: " .. table.concat(outs, ", "))
  end
  if not kind.secondary and #kind.accepts > 0 then
    table.insert(parts, "Accepts " .. cargo_list_str(kind.accepts))
  end
  return table.concat(parts, SEP)
end

function M.site_detail(site)
  local kind = C.KINDS[site.kind]
  local m = {}
  if site.kind == "spaceport" then
    local need, st = pad_need(site), pad_state(site)
    local s
    local miss = {}
    if st.colonists < need.colonists then table.insert(miss, fmt(need.colonists - st.colonists) .. " " .. icon("fd-passengers")) end
    if st.mail < need.mail then table.insert(miss, fmt(need.mail - st.mail) .. " " .. icon("fd-mail")) end
    if st.goods < need.goods then table.insert(miss, fmt(need.goods - st.goods) .. " " .. icon("fd-goods")) end
    local pct = math.floor(100 * st.paid / math.max(1, need.cost))
    if storage.pad_paused then
      s = "Paused (Spaceport window)"
    elseif st.waiting_cash then
      s = "Waiting for cash above your " .. money_short(pad_reserve()) .. " reserve"
    elseif #miss > 0 then
      -- 0.7.7: assembly follows the cargo
      s = "Assembled " .. pct .. "%: waiting for " .. table.concat(miss, ", ")
    elseif st.paid < need.cost - 0.5 then
      local secs = math.ceil(pad_minutes_left(site) * 60)
      s = "Loaded, assembling: " .. (secs >= 90 and (math.ceil(secs / 60) .. " min") or (secs .. " s")) .. " left"
    else
      s = "Rocket rolling out: launching soon"
    end
    local at = C.SPACEPORT.level_at[site.level]
    local nl = at and ("Next level after launch " .. at) or "Top level"
    return s .. mults(m) .. SEP .. nl
  end
  if site.kind == "town" then
    local per = fmt(M.goods_per_resident(site)) .. " " .. icon("fd-goods") .. " per resident"
    local gained = site.growth and site.growth["fd-goods"] or 0
    local s
    if gained < 0.5 then
      s = "Stable: deliver " .. icon("fd-goods") .. " to grow, " .. per
    else
      s = "Growing +" .. fmt(gained) .. "/min (" .. string.format("%.1f", gained / math.max(1, site.pop) * 100) ..
        "%), " .. per
    end
    power_part(site, m)
    if sat_mult() > 1 then table.insert(m, string.format("satellites x%.2f", sat_mult())) end
    return s .. mults(m)
  elseif site.kind == "power-plant" then
    local r = fmt(supply_radius(site))
    local s
    if plant_running(site) then
      local n = site.powering or 0
      local pm = { string.format("power x%.2f", 1 + C.POWER.bonus) }
      if sat_mult() > 1 then table.insert(pm, string.format("satellites reach x%.2f", sat_mult())) end
      s = "Running: powering " .. n .. " site" .. (n == 1 and "" or "s") .. " within " .. r .. " tiles" .. mults(pm)
    else
      s = "Out of fuel: needs " .. icon("fd-coal") .. " or " .. icon("fd-wood") .. " to power sites within " .. r .. " tiles"
    end
    return s .. SEP .. next_level(site, site.burnt)
  elseif kind.base then
    local item, base = next(kind.base)
    local lvl = 1 + C.LEVEL_BONUS * (site.level - 1)
    local svc = 0.6 + 0.4 * site.rating
    local s
    if (site.stock[item] or 0) >= C.STOCK_CAP * site.level - 1 then
      s = "Stockpile full: waiting for pickup"
    else
      if lvl > 1 then table.insert(m, string.format("level x%g", lvl)) end
      power_part(site, m)
      industry_part(m)
      if svc < 0.95 then table.insert(m, string.format("service x%.2f", svc)) end
      s = string.format("Producing %.1f %s/s", base * lvl * svc * power_mult(site) * industry_mult(), icon(item)) .. mults(m)
    end
    return s .. SEP .. next_level(site, site.shipped)
  elseif kind.main then
    local s
    if site.output_full then
      s = "Paused: output full"
    elseif not site.made_tick or game.tick - site.made_tick > 120 then
      s = "Idle: needs " .. icon(kind.main)
    else
      local boost = (kind.base_yield + (kind.full_yield - kind.base_yield) * (site.boost or 0)) / kind.base_yield
      if (site.boost or 0) >= 0.99 then
        table.insert(m, string.format("boost x%.1f max", boost))
      elseif (site.boost or 0) > 0.01 then
        table.insert(m, string.format("boost x%.1f", boost))
      else
        table.insert(m, "boost x1.0, no " .. icon(kind.booster))
      end
      power_part(site, m)
      industry_part(m)
      s = string.format("Making %.1f %s/s from %.1f %s/s", site.made or 0, icon(kind.produces[1]),
        site.used or 0, icon(kind.main)) .. mults(m)
    end
    return s .. SEP .. next_level(site, site.shipped)
  end
  return nil
end

local function draw_detail(site)
  local text = M.site_detail(site)
  if not text then return end
  site.render.detail = rendering.draw_text({
    text = text, surface = surface(), target = { site.x, site.y - 8 }, color = { 0.85, 0.85, 0.7 },
    scale = 1.1, alignment = "center", use_rich_text = true,
  })
end

local function draw_site(site)
  local surf = surface()
  local kind = C.KINDS[site.kind]
  local col = kind.color
  site.render = site.render or {}
  site.render.ring = rendering.draw_circle({
    color = { col[1] * 0.35, col[2] * 0.35, col[3] * 0.35, 0.35 },
    radius = site_radius(site), width = 3, filled = false,
    target = { site.x, site.y }, surface = surf, draw_on_ground = true,
  })
  site.render.title = rendering.draw_text({
    text = "[item=" .. site_icon(site) .. "] " .. site_title(site),
    surface = surf, target = { site.x, site.y - 11 }, color = col,
    scale = 2.2, alignment = "center", use_rich_text = true, scale_with_zoom = false,
  })
  site.render.status = rendering.draw_text({
    text = M.site_status(site),
    surface = surf, target = { site.x, site.y - 9.3 }, color = { 1, 1, 1 },
    scale = 1.3, alignment = "center", use_rich_text = true,
  })
  draw_detail(site)
end

-- Power plant supply area: a circle on the ground and on the map, dimmed when dry
local function update_supply_circle(site)
  if site.kind ~= "power-plant" or not site.render then return end
  local on = plant_running(site)
  -- 0.8.1 (Steve: more noticeable still): opaque, more saturated purple, widths 12 / 6.
  -- 0.5.3: 0.75 / 0.2 and widths 6 / 3; before that 0.45 / 0.12 and 4 / 2.
  -- 0.9.7 (Steve: still hard to see zoomed out on the map): line widths don't grow as the map
  -- zooms out, so the map also gets a light filled disc (it scales with the map), and its
  -- outline goes from 6 to 10.
  local a = on and 1 or 0.35
  local col = { 1 * a, 0.3 * a, 1 * a, a }
  -- 0.10.0 (Steve: too opaque where many plants overlap): 0.16 / 0.05 -> 0.06 / 0.02, so
  -- five overlapping discs are about 27% instead of 58%
  local fa = on and 0.06 or 0.02
  local fill = { fa, 0.3 * fa, fa, fa } -- premultiplied
  local looks = {
    supply = { col = col, width = 12, filled = false, mode = "game" },
    supply_map = { col = col, width = 10, filled = false, mode = "chart" },
    supply_fill = { col = fill, width = 1, filled = true, mode = "chart" },
  }
  for key, l in pairs(looks) do
    local o = site.render[key]
    if not (o and o.valid) then
      o = rendering.draw_circle({
        color = l.col, radius = supply_radius(site), width = l.width, filled = l.filled,
        target = { site.x, site.y }, surface = surface(), draw_on_ground = true, render_mode = l.mode,
      })
      site.render[key] = o
    end
    o.radius = supply_radius(site)
    o.color = l.col
    o.width = l.width
  end
end

local function update_site_render(site)
  update_supply_circle(site)
  if site.render and site.render.status and site.render.status.valid then
    site.render.status.text = M.site_status(site)
    local d = site.render.detail
    if d and d.valid then
      d.text = M.site_detail(site) or ""
    else
      draw_detail(site) -- sites from before 0.2.0
    end
  end
end

local function tag_site(site)
  if site.tagged then return end
  local surf = surface()
  local f = force()
  local chunk = { math.floor(site.x / 32), math.floor(site.y / 32) }
  if not f.is_chunk_charted(surf, chunk) then return end
  local ok, tag = pcall(f.add_chart_tag, surf, {
    position = { site.x, site.y },
    text = site_title(site),
    icon = { type = "item", name = site_icon(site) },
  })
  if ok and tag then site.tagged = true end
end

-- 0.9.0: the first free destination number for a town (1..DEST_TOWNS) or Spaceport (after them)
function M.free_dest_no(kind)
  storage.dest_sites = storage.dest_sites or {}
  local a, b = 1, C.DEST_TOWNS
  if kind == "spaceport" then a, b = C.DEST_TOWNS + 1, C.DESTS end
  for n = a, b do
    if not storage.dest_sites[n] then return n end
  end
  return nil
end

local function create_site(kind, x, y, opts)
  opts = opts or {}
  local surf = surface()
  x, y = math.floor(x), math.floor(y)
  clear_area(surf, box(x, y, 12))
  local id = storage.next_site_id
  storage.next_site_id = id + 1
  local site = {
    id = id, kind = kind, x = x, y = y,
    name = opts.name or new_place_name(),
    level = 1, shipped = 0, delivered = 0, picked_min = 0, rating = 0.5,
    stock = {}, input = {},
    pop = 0, building_count = 0,
    created = game.tick,
  }
  if kind == "town" then
    local d = dist(x, y, 0, 0)
    site.pop = opts.pop or math.floor(250 + rand() * 350 + d * 0.4)
  end
  if kind == "town" or kind == "spaceport" then
    -- 0.9.0: destination number (passengers and mail bound here are fd-passengers-N, fd-mail-N)
    local n = M.free_dest_no(kind)
    if n then
      site.no = n
      storage.dest_sites[n] = id
    end
  end
  storage.sites[id] = site
  storage.stop_links = {}
  build_site_structures(surf, site)
  draw_site(site)
  update_supply_circle(site)
  force().chart(surf, box(x, y, 24))
  tag_site(site)
  return site
end
M.create_site = create_site

-- Spacing rules: SITE_MIN_DIST from any site, TOWN_MIN_DIST between towns.
local function spot_ok(kind, x, y, min_d)
  min_d = min_d or C.SITE_MIN_DIST
  for _, s in pairs(storage.sites) do
    local d = dist(x, y, s.x, s.y)
    if d < min_d then return false end
    if kind == "town" and s.kind == "town" and d < C.TOWN_MIN_DIST then return false end
    if kind == "spaceport" and s.kind == "spaceport" and d < C.SPACEPORT.pad_min_dist then return false end
  end
  return true
end

-- the site's whole footprint (3x3 chunks around it) must exist before we build there, so a
-- later chunk generation can never overwrite it
local function area_generated(surf, x, y)
  local cx, cy = math.floor(x / 32), math.floor(y / 32)
  for dx = -1, 1 do
    for dy = -1, 1 do
      if not surf.is_chunk_generated({ cx + dx, cy + dy }) then return false end
    end
  end
  return true
end

local function find_land_near(kind, tx, ty, max_r, min_d)
  local surf = surface()
  for r = 0, max_r, 8 do
    local steps = math.max(1, math.floor(r / 4))
    for i = 0, steps - 1 do
      local a = (i / steps) * 2 * math.pi
      local x, y = math.floor(tx + math.cos(a) * r), math.floor(ty + math.sin(a) * r)
      if area_generated(surf, x, y) and land_ok(surf, x, y, 13) and spot_ok(kind, x, y, min_d) then
        return x, y
      end
    end
  end
  return nil
end

local function place_starters()
  -- rotate the whole layout by a random angle, so every map starts differently
  local a = rand() * 2 * math.pi
  local ca, sa = math.cos(a), math.sin(a)
  for _, st in pairs(C.STARTERS) do
    local tx, ty = st.x * ca - st.y * sa, st.x * sa + st.y * ca
    local x, y = find_land_near(st.kind, tx, ty, 160)
    if not x then x, y = find_land_near(st.kind, tx, ty, 160, 100) end -- lots of water: relax
    if x then
      create_site(st.kind, x, y, { pop = st.pop })
    end
  end
end

local served_ids -- defined after linked_sites

-- Clutter cap: only add sites while unserved ones are few compared with served ones.
local function room_for_site()
  local served = served_ids()
  local ns, nu = 0, 0
  for id in pairs(storage.sites) do
    if served[id] then ns = ns + 1 else nu = nu + 1 end
  end
  return nu < math.max(C.SPARE_SITES_MIN, ns * C.SPARE_SITES_RATIO)
end
M.room_for_site = room_for_site

-- 0.10.5 founding streams (see C.CHAIN_NEED in config). Each returns the kind it wants founded
-- now, or nil. A stream never founds a kind that already has an unserved site waiting.
local CHAIN_RAW = { "iron-mine", "coal-mine", "forest" }

local function site_counts(served)
  local all, spare = {}, {}
  for id, s in pairs(storage.sites) do
    all[s.kind] = (all[s.kind] or 0) + 1
    if not served[id] then spare[s.kind] = true end
  end
  return all, spare
end

-- chain: the raw input furthest below what the existing consumers need; when all are met, a
-- steel mill (while mills <= factories) or else a factory
local function chain_kind(served)
  local all, spare = site_counts(served)
  local best, best_short, any_short = {}, 0, false
  for _, kind in ipairs(CHAIN_RAW) do
    local need = 0
    for consumer, per in pairs(C.CHAIN_NEED[kind]) do need = need + per * (all[consumer] or 0) end
    local have = all[kind] or 0
    if need > 0 and have < need then
      any_short = true
      -- a kind with a spare waiting is skipped: connect that one first
      if not spare[kind] then
        local short = (need - have) / need
        if short > best_short + 1e-9 then best, best_short = { kind }, short
        elseif short > best_short - 1e-9 then table.insert(best, kind) end
      end
    end
  end
  if #best > 0 then return pick(best) end
  if any_short then return nil end -- inputs come first: don't grow mills or factories yet
  local kind = (all["steel-mill"] or 0) <= (all["factory"] or 0) and "steel-mill" or "factory"
  if spare[kind] then return nil end
  return kind
end
M.chain_kind = function() return chain_kind(served_ids()) end

local function plant_covers(s, plants)
  for _, p in pairs(plants) do
    if dist(s.x, s.y, p.x, p.y) <= supply_radius(p) then return true end
  end
  return false
end

local function power_plants()
  local plants = {}
  for _, s in pairs(storage.sites) do
    if s.kind == "power-plant" then table.insert(plants, s) end
  end
  return plants
end

-- served sites (not plants or Spaceports) that no plant reaches
local function uncovered_served(served)
  local plants, n = power_plants(), 0
  for id in pairs(served) do
    local s = storage.sites[id]
    if s and s.kind ~= "power-plant" and s.kind ~= "spaceport" and not plant_covers(s, plants) then n = n + 1 end
  end
  return n
end

local function power_kind(served)
  local _, spare = site_counts(served)
  if spare["power-plant"] then return nil end
  if uncovered_served(served) < C.POWER_UNCOVERED then return nil end
  local plants, others = 0, 0
  for id in pairs(served) do
    local s = storage.sites[id]
    if s and s.kind == "power-plant" then plants = plants + 1 elseif s and s.kind ~= "spaceport" then others = others + 1 end
  end
  if plants >= math.ceil(others / C.POWER_SITES_PER_PLANT) then return nil end
  return "power-plant"
end

local function town_gap()
  return C.TOWN_GAP_MIN + math.floor(rand() * (C.TOWN_GAP_MAX - C.TOWN_GAP_MIN))
end

local function town_kind(served)
  local _, spare = site_counts(served)
  if spare["town"] or not M.free_dest_no("town") then return nil end
  if not storage.next_town_tick then
    -- old save: count from its newest town
    local last = 0
    for _, s in pairs(storage.sites) do
      if s.kind == "town" then last = math.max(last, s.created or 0) end
    end
    storage.next_town_tick = last + town_gap()
  end
  if game.tick < storage.next_town_tick then return nil end
  return "town"
end

local STREAMS = { { name = "chain", want = chain_kind }, { name = "power", want = power_kind },
  { name = "town", want = town_kind, no_delay = true } } -- towns: the random gap is the whole wait

-- Found one new site on purpose: FOUND_MIN..FOUND_MAX tiles from a random served site (or
-- spawn), on generated dry land that keeps the spacing rules. Land that isn't generated yet
-- is requested and tried again on a later call.
local function found_site(kind)
  local surf = surface()
  local served = served_ids()
  local anchors = {}
  for id in pairs(served) do
    local s = storage.sites[id]
    if s then table.insert(anchors, s) end
  end
  table.sort(anchors, function(p, q) return p.id < q.id end) -- pairs order isn't stable
  if #anchors == 0 then anchors = { { x = 0, y = 0 } } end
  -- a power plant goes where it would cover the most sites no plant covers yet (fuelled or
  -- not; your served ones count double), and only where it reaches C.POWER_MIN_REACH served
  -- sites no plant covers yet (0.10.5). Anything else takes the first good spot.
  local plants = power_plants()
  local function score(x, y)
    local n, ns = 0, 0
    for id, s in pairs(storage.sites) do
      if s.kind ~= "power-plant" and dist(x, y, s.x, s.y) <= C.POWER.radius and not plant_covers(s, plants) then
        n = n + (served[id] and 2 or 1)
        if served[id] then ns = ns + 1 end
      end
    end
    return n, ns
  end
  local bx, by, bs
  for _ = 1, 40 do
    local an = pick(anchors)
    local a = rand() * 2 * math.pi
    local d = C.FOUND_MIN + rand() * (C.FOUND_MAX - C.FOUND_MIN)
    local x, y = math.floor(an.x + math.cos(a) * d), math.floor(an.y + math.sin(a) * d)
    if spot_ok(kind, x, y) then
      if not area_generated(surf, x, y) then
        surf.request_to_generate_chunks({ x, y }, 1)
      elseif land_ok(surf, x, y, 13) then
        local sc, ns = 0, C.POWER_MIN_REACH
        if kind == "power-plant" then sc, ns = score(x, y) end
        if ns >= C.POWER_MIN_REACH and (not bs or sc > bs) then bx, by, bs = x, y, sc end
        if kind ~= "power-plant" then break end
      end
    end
  end
  if not bx then return nil end
  local x, y = bx, by
  local site = create_site(kind, x, y)
  if kind == "spaceport" and not (storage.spaceport_id and storage.sites[storage.spaceport_id]) then storage.spaceport_id = site.id end
  local near, nd = nil, nil
  for id in pairs(served) do
    local s = storage.sites[id]
    if s then
      local dd = dist(x, y, s.x, s.y)
      if not nd or dd < nd then near, nd = s, dd end
    end
  end
  game.print("[color=cyan]A new " .. C.KINDS[kind].label:lower() .. " has been founded:[/color] " ..
    "[item=" .. site_icon(site) .. "] " .. site_title(site) ..
    (near and (", " .. M.fmt(nd) .. " tiles from " .. site_title(near)) or "") ..
    " [gps=" .. x .. "," .. y .. "," .. C.SURFACE .. "]")
  return site
end
M.found_site = found_site

local function maybe_found_site()
  -- end game (0.7.0): Railway Tycoon founds the first Spaceport, outside the usual pacing and cap
  if storage.pad_wanted and not M.spaceport() then
    if found_site("spaceport") then
      storage.pad_wanted = nil
      game.print("[color=cyan]Serve it with a stop and bring colonists ([item=fd-passengers] passengers), [item=fd-mail] mail and [item=fd-goods] goods: " ..
        "a rocket launches as soon as it's loaded and paid. Every launch adds a satellite: +" ..
        math.floor(C.SPACEPORT.satellite * 100 + 0.5) .. "% town passengers and mail, and power plant reach. Open the Spaceport window from your HUD.[/color]")
    end
    return
  end
  -- 0.7.8: a Spaceport bought in the Shop
  if (storage.pads_pending or 0) > 0 then
    if found_site("spaceport") then
      storage.pads_pending = storage.pads_pending - 1
      game.print("[color=cyan]Your new Spaceport is ready for trains. Each Spaceport builds its own rockets.[/color]")
    end
    return
  end
  -- 0.10.5: each stream keeps its own random delay once it wants a site
  if type(storage.found_due) ~= "table" then storage.found_due = {} end
  storage.found_kind = nil -- pre-0.10.5 leftover
  local served = served_ids()
  local ready = {}
  for _, st in ipairs(STREAMS) do
    local kind = st.want(served)
    if not kind then
      storage.found_due[st.name] = nil
    elseif not storage.found_due[st.name] then
      storage.found_due[st.name] = st.no_delay and game.tick or
        (game.tick + C.FOUND_DELAY_MIN + math.floor(rand() * (C.FOUND_DELAY_MAX - C.FOUND_DELAY_MIN)))
    elseif game.tick >= storage.found_due[st.name] then
      table.insert(ready, { name = st.name, kind = kind })
    end
  end
  if game.tick < (storage.next_found_tick or 0) or #ready == 0 then return end
  for _, r in ipairs(ready) do -- one per call; a stream that can't place yet doesn't block the others
    if found_site(r.kind) then
      storage.found_due[r.name] = nil
      storage.next_found_tick = game.tick + C.FOUND_GAP
      if r.kind == "town" then storage.next_town_tick = game.tick + town_gap() end
      return
    end
  end
end

---------------------------------------------------------------------------
-- Stops <-> sites
---------------------------------------------------------------------------

local function linked_sites(stop)
  local key = stop.unit_number
  local ids = storage.stop_links[key]
  if not ids then
    ids = {}
    local p = stop.position
    for id, s in pairs(storage.sites) do
      if dist(p.x, p.y, s.x, s.y) <= site_radius(s) + 1 then
        table.insert(ids, id)
      end
    end
    storage.stop_links[key] = ids
  end
  local result = {}
  for _, id in pairs(ids) do
    local s = storage.sites[id]
    if s then table.insert(result, s) end
  end
  return result
end
M.linked_sites = linked_sites

-- set of site ids that have at least one train stop in their ring (cached for a minute;
-- storage.served = nil forces a refresh, e.g. after a stop is built)
served_ids = function()
  if storage.served and game.tick - (storage.served_tick or 0) < 3600 then return storage.served end
  local set = {}
  for _, stop in pairs(surface().find_entities_filtered({ type = "train-stop", force = C.FORCE })) do
    for _, s in pairs(linked_sites(stop)) do set[s.id] = true end
  end
  storage.served = set
  storage.served_tick = game.tick
  return set
end

-- Site signals boxes (constant combinators): each one reports the nearest site whose ring
-- it stands in. Rewritten every second; anything a player edits in its GUI is reset.
local function signals_site(box)
  local best, bd
  for _, s in pairs(linked_sites(box)) do
    local d = dist(box.position.x, box.position.y, s.x, s.y)
    if not bd or d < bd then best, bd = s, d end
  end
  return best
end
M.signals_site = signals_site

local function site_signals(s)
  local list = {}
  local function add(type, name, v)
    v = math.floor(v or 0)
    if v > 0 then
      table.insert(list, { value = { type = type, name = name, quality = "normal" }, min = math.min(v, 2000000000) })
    end
  end
  local kind = C.KINDS[s.kind]
  for _, it in pairs(kind.produces) do add("item", it, s.stock[it]) end
  if kind.secondary then
    for _, it in pairs(kind.accepts) do add("item", it, s.input[it]) end
  end
  if s.kind == "town" then add("virtual", "signal-P", s.pop) else add("virtual", "signal-L", s.level) end
  if s.kind == "power-plant" then add("virtual", "signal-F", s.fuel) end
  if s.kind == "spaceport" then
    -- P / M / G: colonists, mail and goods still needed, T: minutes of assembly left once loaded, C: cash in $1,000s
    add("virtual", "signal-P", pad_room(s, "fd-passengers"))
    add("virtual", "signal-M", pad_room(s, "fd-mail"))
    add("virtual", "signal-G", pad_room(s, "fd-goods"))
    add("virtual", "signal-T", math.ceil(pad_minutes_left(s)))
    add("virtual", "signal-C", storage.money / 1000)
  end
  return list
end
M.site_signals = site_signals

local function update_signal_box(box)
  local s = signals_site(box)
  local cb = box.get_or_create_control_behavior()
  if not cb then return end
  cb.enabled = true
  while cb.sections_count > 1 do cb.remove_section(cb.sections_count) end
  local sec = cb.get_section(1) or cb.add_section()
  if sec then sec.filters = s and site_signals(s) or {} end
end

local function update_signal_boxes()
  for unit, box in pairs(storage.signal_boxes) do
    if box.valid then update_signal_box(box) else storage.signal_boxes[unit] = nil end
  end
end

local function on_signals_built(box, player)
  if not (box and box.valid) or box.surface.name ~= C.SURFACE then return end
  storage.signal_boxes[box.unit_number] = box
  storage.stop_links[box.unit_number] = nil
  local s = signals_site(box)
  if s then
    flying_text(box.position, "Site signals: " .. site_title(s), { 0.6, 1, 0.6 }, player)
  else
    flying_text(box.position, "Not inside any site's ring: it will stay blank", { 1, 0.6, 0.2 }, player)
  end
  update_signal_box(box)
end

local function on_stop_built(stop, player)
  if not (stop and stop.valid) or stop.surface.name ~= C.SURFACE then return end
  storage.stop_links[stop.unit_number] = nil
  storage.served = nil
  local sites = linked_sites(stop)
  if #sites == 0 then
    flying_text(stop.position, "This stop is not near any town or industry", { 1, 0.6, 0.2 }, player)
    return
  end
  local names = {}
  local dest
  for i, s in pairs(sites) do
    if i <= 2 then table.insert(names, site_title(s)) end
    if s.no and not dest then dest = s end
  end
  if dest then
    -- 0.9.0 (Steve): a town's or Spaceport's stop is named after its destination items, so one
    -- wildcard interrupt ("[item wildcard] unload") can send any train where its cargo is bound.
    -- Once it has a passenger stop, the next one is named for mail (if it has none), the rest
    -- for passengers again.
    local function has(b)
      for _, st in pairs(game.train_manager.get_train_stops({ station_name = "[item=" .. C.variant(b, dest.no) .. "] unload", surface = C.SURFACE })) do
        if st ~= stop then
          for _, s in pairs(linked_sites(st)) do
            if s.id == dest.id then return true end
          end
        end
      end
      return false
    end
    local b = (has("fd-passengers") and not has("fd-mail")) and "fd-mail" or "fd-passengers"
    stop.backer_name = "[item=" .. C.variant(b, dest.no) .. "] unload"
  else
    stop.backer_name = table.concat(names, " & ")
  end
  flying_text(stop.position, "Serves: " .. table.concat(names, ", "), { 0.5, 1, 0.5 }, player)
end

---------------------------------------------------------------------------
-- Cargo tracking and train service
---------------------------------------------------------------------------

local function wagon_record(wagon)
  local key = wagon.unit_number
  local rec = storage.wagons[key]
  if not rec then
    rec = {}
    storage.wagons[key] = rec
    script.register_on_object_destroyed(wagon)
  end
  return rec
end

-- Each wagon keeps a list of "lots" per item: {amount, ox, oy, tick, site}, one per origin.
local function get_lots(rec, item)
  local v = rec[item]
  if not v then return nil end
  if v.amount ~= nil then
    -- migrate 0.1.0 single averaged record
    v = { v }
    rec[item] = v
  end
  return v
end

local function add_loaded(wagon, item, amount, site)
  local rec = wagon_record(wagon)
  local lots = get_lots(rec, item)
  if not lots then
    lots = {}
    rec[item] = lots
  end
  local last = lots[#lots]
  if last and last.site == site.id then
    local total = last.amount + amount
    last.tick = (last.tick * last.amount + game.tick * amount) / total
    last.amount = total
  else
    table.insert(lots, { amount = amount, ox = site.x, oy = site.y, tick = game.tick, site = site.id })
  end
end

local function on_delivered(site, item, amount)
  site.delivered = site.delivered + amount
  fl_add(site, "rx:" .. item, amount)
  local kind = C.KINDS[site.kind]
  if kind.secondary then
    site.input[item] = math.min(C.INPUT_CAP, (site.input[item] or 0) + amount)
  elseif site.kind == "power-plant" then
    site.fuel = math.min(C.POWER.cap, (site.fuel or 0) + amount * (C.POWER.fuel[item] or 0))
  elseif site.kind == "spaceport" then
    local st = pad_state(site)
    if item == "fd-passengers" then st.colonists = st.colonists + amount end
    if item == "fd-mail" then st.mail = st.mail + amount end
    if item == "fd-goods" then st.goods = st.goods + amount end
  end
  site.recv = site.recv or {}
  site.recv[item] = (site.recv[item] or 0) + amount
  if site.kind == "town" and item == "fd-goods" then
    local gain = amount / M.goods_per_resident(site)
    site.pop = site.pop + gain
    site.grow_acc = site.grow_acc or {}
    site.grow_acc[item] = (site.grow_acc[item] or 0) + gain
  end
  -- contracts: each unit counts once, oldest matching contract first, and only what it still
  -- needs (before 0.4.2 the full amount counted towards every matching contract)
  local left = amount
  for _, ct in ipairs(storage.contracts) do
    if left > 0 and ct.site_id == site.id and ct.item == item and not ct.done then
      local take = math.min(left, ct.amount - ct.delivered)
      ct.delivered = ct.delivered + take
      left = left - take
      if ct.delivered >= ct.amount then
        ct.done = true
        earn(ct.reward)
        game.print("[color=green]Contract complete![/color] [item=" .. item .. "] to " ..
          site_title(site) .. " - bonus " .. M.money_str(ct.reward))
      end
    end
  end
end

local function payment(rec, site, item, amount)
  local cargo = C.CARGO[item]
  local d = dist(rec.ox, rec.oy, site.x, site.y)
  local transit = (game.tick - rec.tick) / 60
  local grace = 20 + d / 12
  local tf = 1
  if transit > grace then
    tf = math.max(0.25, 1 - (transit - grace) / cargo.decay)
  end
  return amount * cargo.rate * d / 100 * tf, d, tf
end

-- A stop whose current wait condition includes "Empty cargo" is a drop-off stop:
-- the train only unloads there, never loads (otherwise it could never become empty).
local function is_dropoff(train)
  local result = false
  pcall(function()
    local sch = train.get_schedule()
    local rec = sch.get_record({ schedule_index = sch.current })
    for _, wc in pairs(rec and rec.wait_conditions or {}) do
      if wc.type == "empty" then result = true end
    end
  end)
  return result
end

---------------------------------------------------------------------------
-- Destinations (0.9.0) and wagon filters
---------------------------------------------------------------------------

local function filter_name(f)
  if type(f) == "table" then return f.name end
  return f
end

-- Insert into a cargo wagon. A slot filtered to passengers (or mail) takes passengers for any
-- destination: an empty slot filtered to one destination is switched to the one loading now.
local function wagon_insert(inv, item, n)
  if n <= 0 then return 0 end
  local got = inv.insert({ name = item, count = n })
  local b = C.BASE[item]
  if got >= n or not b or not inv.is_filtered() then return got end
  local need = math.ceil((n - got) / prototypes.item[item].stack_size)
  for i = 1, #inv do
    if need <= 0 then break end
    local f = filter_name(inv.get_filter(i))
    if f and f ~= item and C.base(f) == b and not inv[i].valid_for_read then
      if inv.set_filter(i, item) then need = need - 1 end
    end
  end
  return got + inv.insert({ name = item, count = n - got })
end

-- 0.9.1 (Steve): when a wagon upgrade adds slots (`old` = the size before), the new slots get
-- the wagon's filter, but only if every old slot was filtered to one cargo. Slots switched to
-- different destinations of one cargo by `wagon_insert` count as that cargo; the new slots then
-- get the plain cargo (any destination), or the exact filter if all old slots share it.
-- Filters are never changed otherwise.
local function extend_wagon_filters(inv, old)
  if old < 1 or #inv <= old or not inv.is_filtered() then return end
  local names, nnames, base = {}, 0, nil
  for i = 1, old do
    local f = filter_name(inv.get_filter(i))
    if not f then return end
    if not names[f] then names[f] = true nnames = nnames + 1 end
    local b = C.base(f)
    if base and b ~= base then return end
    base = b
  end
  local fill = nnames == 1 and next(names) or base
  for i = old + 1, #inv do
    if not inv.get_filter(i) then inv.set_filter(i, fill) end
  end
end
M.extend_wagon_filters = extend_wagon_filters

-- Stop-name wildcards: the item wildcard (bound by "item count" conditions) and, since 0.9.3,
-- the signal wildcard (bound by circuit conditions, e.g. the "most riders" selector dispatch).
-- Both turn into "[item=fd-passengers-N]" etc. when the destination is an item.
local PARAMS = { "[virtual-signal=signal-item-parameter]", "[virtual-signal=signal-signal-parameter]" }
local function find_param(station)
  for _, p in pairs(PARAMS) do
    local i, j = station:find(p, 1, true)
    if i then return i, j end
  end
end

local function stops_named(name)
  return game.train_manager.get_train_stops({ station_name = name, surface = C.SURFACE })
end

local function links_site(stop, site)
  for _, s in pairs(linked_sites(stop)) do
    if s.id == site.id then return true end
  end
  return false
end

-- Where this train can take passengers and mail: dests[base][site id] = site, for numbered
-- sites (towns, Spaceports) with a stop on its schedule or among its interrupt targets, and,
-- for a wildcard target like "[item wildcard] unload" (or the signal wildcard), every site whose cargo would name a stop
-- there. Only stops the train can reach by rail count. Cached for 10 s.
local function train_dests(train)
  storage.dest_cache = storage.dest_cache or {}
  local c = storage.dest_cache[train.id]
  if c and game.tick - c.tick < 600 then return c.dests end
  local names, patterns = {}, {}
  local function add(station)
    if not station or station == "" then return end
    if find_param(station) then patterns[station] = true else names[station] = true end
  end
  pcall(function()
    local sch = train.get_schedule()
    for i = 1, sch.get_record_count() or 0 do
      local r = sch.get_record({ schedule_index = i })
      if r then add(r.station) end
    end
    for _, it in pairs(sch.get_interrupts() or {}) do
      for _, r in pairs(it.targets or {}) do add(r.station) end
    end
  end)
  local goals = {} -- { stop, site, base (nil = both) }
  local seen = {}
  local function goal(stop, site, b)
    local key = stop.unit_number .. ":" .. site.id .. ":" .. (b or "")
    if seen[key] or not stop.connected_rail then return end
    seen[key] = true
    table.insert(goals, { stop = stop, site = site, base = b })
  end
  for name in pairs(names) do
    for _, st in pairs(stops_named(name)) do
      for _, s in pairs(linked_sites(st)) do
        if s.no then goal(st, s, nil) end
      end
    end
  end
  for pat in pairs(patterns) do
    local i, j = find_param(pat)
    for n, sid in pairs(storage.dest_sites or {}) do
      local s = storage.sites[sid]
      if s then
        for _, b in pairs(C.DEST_BASES) do
          for _, st in pairs(stops_named(pat:sub(1, i - 1) .. "[item=" .. C.variant(b, n) .. "]" .. pat:sub(j + 1))) do
            if links_site(st, s) then goal(st, s, b) end
          end
        end
      end
    end
  end
  local res
  if #goals > 0 then
    local list = {}
    for k, g in ipairs(goals) do list[k] = { train_stop = g.stop } end
    pcall(function()
      res = game.train_manager.request_train_path({ train = train, goals = list, type = "all-goals-accessible" })
    end)
  end
  local dests = {}
  for _, b in pairs(C.DEST_BASES) do dests[b] = {} end
  for k, g in ipairs(goals) do
    if not (res and res.accessible) or res.accessible[k] then
      for _, b in pairs(C.DEST_BASES) do
        if not g.base or g.base == b then dests[b][g.site.id] = g.site end
      end
    end
  end
  storage.dest_cache[train.id] = { tick = game.tick, dests = dests }
  return dests
end
M.train_dests = train_dests

-- Destinations for cargo `b` boarding at `here`, with weights: towns by population, a
-- Spaceport strongly while its rocket still needs this cargo. Nothing within MIN_DIST.
local function boarding_dests(dests, b, here)
  local list, towns, tw = {}, 0, 0
  for _, s in pairs(dests[b] or {}) do
    if s.id ~= here.id and s.kind == "town" and dist(s.x, s.y, here.x, here.y) >= C.MIN_DIST then
      local w = math.max(100, s.pop or 0)
      table.insert(list, { site = s, w = w })
      towns, tw = towns + 1, tw + w
    end
  end
  for _, s in pairs(dests[b] or {}) do
    if s.id ~= here.id and s.kind == "spaceport" and pad_room(s, b) > 0 and dist(s.x, s.y, here.x, here.y) >= C.MIN_DIST then
      table.insert(list, { site = s, w = towns > 0 and 2 * tw / towns or 1000 })
    end
  end
  table.sort(list, function(p, q) return p.site.id < q.site.id end) -- pairs order isn't stable
  return list
end

-- Split `n` units between weighted destinations (whole units; the remainder goes to one
-- destination picked at random by weight).
local function split_by_weight(n, list)
  local total = 0
  for _, d in ipairs(list) do total = total + d.w end
  local out, given = {}, 0
  for k, d in ipairs(list) do
    out[k] = math.floor(n * d.w / total)
    given = given + out[k]
  end
  local left = n - given
  if left > 0 then
    local r = rand() * total
    for k, d in ipairs(list) do
      r = r - d.w
      if r <= 0 or k == #list then out[k] = out[k] + left break end
    end
  end
  return out
end

local function service_train(train)
  local stop = train.station
  if not (stop and stop.valid) then return end
  local sites = linked_sites(stop)
  if #sites == 0 then return end
  local dropoff = is_dropoff(train)
  local dests
  for _, site in pairs(sites) do
    if site.kind == "town" or site.kind == "spaceport" then dests = train_dests(train) end
  end
  local paid = 0
  local loaded = 0
  local stranded = 0
  for _, wagon in pairs(train.cargo_wagons) do
    local inv = wagon.get_inventory(defines.inventory.cargo_wagon)
    if inv then
      local budget = load_rate()
      local rec = storage.wagons[wagon.unit_number] or {}
      -- unload (instant, no rate limit): every lot that has travelled far enough comes off
      -- and is paid, as far as the site has room (mills and factories: input pile). Lots still
      -- near their origin stay aboard. Untracked cargo (more in the wagon than we have records
      -- for) gets off for free. 0.9.0: passengers and mail get off only at their destination.
      for _, site in pairs(sites) do
        for _, base in pairs(C.KINDS[site.kind].accepts) do
          local item = base
          if C.TOWN_CARGO[base] then item = site.no and C.variant(base, site.no) or nil end
          local have = item and inv.get_item_count(item) or 0
          if have > 0 then
            local lots = get_lots(rec, item) or {}
            local tracked = 0
            for _, lot in pairs(lots) do tracked = tracked + lot.amount end
            local untracked = math.max(0, math.floor(have - tracked + 0.001))
            local keep = {}
            local deliver = 0
            local avail = have - untracked
            -- back-pressure (0.3.4): steel mills and factories only take what fits in their
            -- input pile; the rest stays aboard and comes off on later seconds as room opens.
            -- Power plants (0.4.1) take what fits in their fuel pile. Towns take everything.
            local room = math.huge
            if C.KINDS[site.kind].secondary then
              room = math.max(0, math.floor(C.INPUT_CAP - (site.input[base] or 0)))
            elseif site.kind == "power-plant" then
              room = math.max(0, math.floor((C.POWER.cap - (site.fuel or 0)) / C.POWER.fuel[base] + 0.001))
            elseif site.kind == "spaceport" then
              room = pad_room(site, base) -- only what the rocket being built still needs
            end
            for _, lot in ipairs(lots) do
              if dist(lot.ox, lot.oy, site.x, site.y) >= C.MIN_DIST and avail > 0 and room > 0 then
                local take = math.min(math.floor(lot.amount + 0.001), avail, room)
                room = room - take
                if take > 0 then
                  local pay = payment(lot, site, base, take)
                  paid = paid + pay
                  -- lifetime earnings per cargo (balance checks; `stats` remote)
                  storage.earned_item = storage.earned_item or {}
                  storage.earned_item[base] = (storage.earned_item[base] or 0) + pay
                  deliver = deliver + take
                  avail = avail - take
                  lot.amount = lot.amount - take
                end
              end
              if lot.amount > 0.001 then table.insert(keep, lot) end
            end
            if room <= 0 and #keep > 0 then site.input_full_tick = game.tick end
            local n = deliver + untracked
            if n > 0 then
              inv.remove({ name = item, count = n })
              if deliver > 0 then on_delivered(site, base, deliver) end
            end
            if inv.get_item_count(item) == 0 then
              rec[item] = nil
            else
              rec[item] = keep
            end
          end
        end
      end
      -- 0.9.0: passengers and mail whose destination this train no longer goes to (its
      -- schedule changed, or the rail there is gone) get off at a town and wait there again
      for _, site in pairs(sites) do
        if site.kind == "town" and dests then
          for item, _ in pairs(rec) do
            local b, n = C.BASE[item], C.DEST_NO[item]
            local sid = n and storage.dest_sites[n]
            if b and sid ~= site.id and not dests[b][sid] then
              local have = inv.get_item_count(item)
              if have > 0 then
                local back = inv.remove({ name = item, count = have })
                site.stock[b] = (site.stock[b] or 0) + back
                stranded = stranded + back
              end
              rec[item] = nil
            end
          end
        end
      end
      -- drop-off stop: cargo that never left home goes back to its site, and nothing loads
      if dropoff then
        for _, site in pairs(sites) do
          for _, base in pairs(C.KINDS[site.kind].produces) do
            for item, _ in pairs(rec) do
              if C.base(item) == base then
                local lots = get_lots(rec, item)
                local have = inv.get_item_count(item)
                if lots and have > 0 then
                  local keep, back = {}, 0
                  for _, lot in ipairs(lots) do
                    if have - back > 0 and dist(lot.ox, lot.oy, site.x, site.y) < C.MIN_DIST then
                      local take = math.min(math.floor(lot.amount + 0.001), have - back)
                      back = back + take
                      lot.amount = lot.amount - take
                    end
                    if lot.amount > 0.001 then table.insert(keep, lot) end
                  end
                  if back > 0 then
                    inv.remove({ name = item, count = back })
                    site.stock[base] = (site.stock[base] or 0) + back
                  end
                  if inv.get_item_count(item) == 0 then rec[item] = nil else rec[item] = keep end
                end
              end
            end
          end
        end
      end
      -- load: share this second's capacity evenly between every cargo type waiting here
      -- (so plentiful passengers can't crowd out mail); leftover share goes to the others.
      -- 0.9.0: passengers and mail pick a destination among the places this train goes.
      local offers = {}
      for _, site in pairs(dropoff and {} or sites) do
        for _, item in pairs(C.KINDS[site.kind].produces) do
          local s = math.floor(site.stock[item] or 0)
          local to
          if C.TOWN_CARGO[item] then
            to = dests and boarding_dests(dests, item, site) or {}
            if #to == 0 then s = 0 end
          end
          if s > 0 then table.insert(offers, { site = site, item = item, avail = s, to = to }) end
        end
      end
      for _ = 1, 4 do
        if budget <= 0 or #offers == 0 then break end
        local share = math.max(1, math.floor(budget / #offers))
        local still = {}
        for _, o in ipairs(offers) do
          -- 0.9.8: a passenger or letter takes C.TOWN_SCALE units of loading capacity, so
          -- wagons fill at the same pace as before the rescale
          local k = C.TOWN_CARGO[o.item] and C.TOWN_SCALE or 1
          local want = math.min(o.avail, math.floor(share / k), math.floor(budget / k))
          local site = o.site
          local ins = 0
          if want > 0 then
            if o.to then
              local parts = split_by_weight(want, o.to)
              -- 0.9.5: start at a random destination. In id order, a nearly full wagon always
              -- ran out of room before the high-numbered towns, so fewer riders boarded for
              -- them (on Steve's save: 37k delivered to town 1 against 7k to town 10 in 10 min).
              local nto = #o.to
              local first = math.floor(rand() * nto)
              for step = 0, nto - 1 do
                local k = (first + step) % nto + 1
                local d = o.to[k]
                local v = C.variant(o.item, d.site.no)
                local got = wagon_insert(inv, v, parts[k])
                if got > 0 then
                  add_loaded(wagon, v, got, site)
                  ins = ins + got
                end
              end
            else
              ins = wagon_insert(inv, o.item, want)
              if ins > 0 then add_loaded(wagon, o.item, ins, site) end
            end
          end
          if ins > 0 then
            site.stock[o.item] = site.stock[o.item] - ins
            site.shipped = site.shipped + ins
            site.picked_min = site.picked_min + ins
            fl_add(site, "tx:" .. o.item, ins)
            budget = budget - ins * k
            loaded = loaded + ins
            o.avail = o.avail - ins
          end
          -- keep offering only if it took everything we asked for and more is waiting
          if ins == want and o.avail > 0 then table.insert(still, o) end
        end
        offers = still
      end
    end
  end
  if stranded > 0 then
    flying_text(stop.position, fmt(stranded) .. " passengers and mail got off: this train no longer goes where they are bound", { 1, 0.7, 0.3 })
  end
  if paid > 0 then
    earn(paid)
    storage.deliveries = (storage.deliveries or 0) + 1
    local p = stop.position
    rendering.draw_text({
      text = "+" .. M.money_str(paid), surface = stop.surface, target = { p.x, p.y - 2 },
      color = { 0.4, 1, 0.4 }, scale = 1.6, time_to_live = 120, alignment = "center",
    })
  end
end

---------------------------------------------------------------------------
-- Economy simulation (once per second)
---------------------------------------------------------------------------

local function level_up_check(site)
  if site.kind == "town" or site.kind == "spaceport" then return end
  local plant = site.kind == "power-plant"
  local need = C.LEVEL_AT[site.level]
  if need and (plant and (site.burnt or 0) or site.shipped) >= need then
    site.level = site.level + 1
    game.print("[color=yellow]" .. site_title(site) .. " expanded to level " .. site.level ..
      "![/color] " .. (plant and ("Supply radius now " .. fmt(supply_radius(site)) .. " tiles.") or "Production up.") ..
      " [gps=" .. site.x .. "," .. site.y .. "," .. C.SURFACE .. "]")
    if plant then update_supply_circle(site) end
  end
end

-- Burn fuel, then give every other site the nearest running plant whose radius reaches it
-- (one plant at most: overlapping plants don't stack).
local function update_power()
  local running = {}
  for _, site in pairs(storage.sites) do
    if site.kind == "power-plant" then
      local was = plant_running(site)
      local b = math.min(site.fuel or 0, C.POWER.burn)
      fl_add(site, "starve", 1 - b / C.POWER.burn)
      site.fuel = (site.fuel or 0) - b
      if site.fuel < 0.001 then site.fuel = 0 end
      site.burnt = (site.burnt or 0) + b
      site.powering = 0
      if plant_running(site) then table.insert(running, site) end
      if was ~= plant_running(site) then update_supply_circle(site) end
    end
  end
  for _, site in pairs(storage.sites) do
    if site.kind ~= "power-plant" then
      local best, bd
      for _, p in ipairs(running) do
        local d = dist(site.x, site.y, p.x, p.y)
        if d <= supply_radius(p) and (not bd or d < bd) then best, bd = p, d end
      end
      site.powered_by = best and best.id or nil
      if best then best.powering = best.powering + 1 end
    end
  end
end

-- The Spaceport's real rocket silo (0.7.4), placed at the site centre. Nil if missing (then the
-- old sprite launch is used).
local function pad_silo(site)
  local surf = surface()
  return surf and surf.find_entity("fd-spaceport-silo", { site.x + 0.5, site.y + 0.5 }) or nil
end

-- Put the real silo on a Spaceport (new site, or a save from before 0.7.4 with the picture).
local function ensure_pad_silo(site)
  if pad_silo(site) or not prototypes.entity["fd-spaceport-silo"] then return end
  local surf = surface()
  for _, e in pairs(surf.find_entities_filtered({ name = "fd-silo", position = { site.x + 0.5, site.y + 0.5 }, radius = 2 })) do
    e.destroy()
  end
  local e = surf.create_entity({ name = "fd-spaceport-silo", position = { site.x + 0.5, site.y + 0.5 }, force = "neutral",
    create_build_effect_smoke = false })
  if e then
    e.destructible = false
    e.minable_flag = false
    e.operable = false
  end
end

-- No "you won" screen: the vanilla silo script would end the game on the first launch.
local function no_silo_victory()
  if remote.interfaces["silo_script"] and remote.interfaces["silo_script"]["set_no_victory"] then
    remote.call("silo_script", "set_no_victory", true)
  end
end

-- Launch: the silo launches its rocket (or, without a silo, a rocket sprite rises for 10 s,
-- moved by on_nth_tick 2)
local function launch_rocket(site, silo)
  local need = pad_need(site)
  storage.rockets = (storage.rockets or 0) + 1
  site.launches = (site.launches or 0) + 1
  site.pad = { colonists = 0, mail = 0, goods = 0, paid = 0 }
  local n = storage.rockets
  game.print("[color=cyan][font=default-large-bold]Rocket " .. n .. " launched from " .. site_title(site) .. "![/font][/color] " ..
    fmt(need.colonists) .. " [item=fd-passengers] colonists, " .. fmt(need.mail) .. " [item=fd-mail] mail and " ..
    fmt(need.goods) .. " [item=fd-goods] goods are on their way. " ..
    string.format("Satellite network: town passengers and mail, and power plant reach, +%d%%.", math.floor((sat_mult() - 1) * 100 + 0.5)) ..
    " [gps=" .. site.x .. "," .. site.y .. "," .. C.SURFACE .. "]")
  local at = C.SPACEPORT.level_at[site.level]
  if at and site.launches >= at then
    site.level = site.level + 1
    local nx = pad_need(site)
    game.print("[color=yellow]" .. site_title(site) .. " expanded to level " .. site.level .. "![/color] Rockets now carry " ..
      fmt(nx.colonists) .. " colonists, " .. fmt(nx.mail) .. " mail and " .. fmt(nx.goods) .. " goods, and cost " .. M.money_str(nx.cost) .. ".")
  end
  if silo then return end -- the silo plays its own launch
  local sprite = helpers.is_valid_sprite_path("fd-rocket") and "fd-rocket" or "item/rocket-silo"
  local ok, obj = pcall(rendering.draw_sprite, {
    sprite = sprite, surface = surface(), target = { site.x + 0.5, site.y - 1 },
    render_layer = "air-object", x_scale = 1, y_scale = 1,
  })
  if ok and obj then
    storage.launch_anims = storage.launch_anims or {}
    table.insert(storage.launch_anims, { obj = obj, x = site.x + 0.5, y = site.y - 1, start = game.tick })
  end
end
M.launch_rocket = launch_rocket

local function animate_launches()
  local list = storage.launch_anims
  if not list or #list == 0 then return end
  local keep = {}
  for _, a in ipairs(list) do
    local t = (game.tick - a.start) / 60
    if a.obj.valid and t < 10 then
      a.obj.target = { a.x, a.y - 1.5 * t * t } -- accelerating: 150 tiles up after 10 s
      table.insert(keep, a)
    elseif a.obj.valid then
      a.obj.destroy()
    end
  end
  storage.launch_anims = keep
end

-- Assembly: pay the build cost a little each second (never below the reserve, and since 0.7.7
-- only up to the share of cargo aboard), then launch once the cost is paid and the colonists,
-- mail and goods are aboard. Fully loaded, a rocket takes build_secs.
local function update_spaceport(site)
  local st = pad_state(site)
  local need = pad_need(site)
  st.waiting_cash = false
  if st.paid > need.cost then
    -- 0.7.7 lowered the costs: refund what an older save already paid above the new cost
    storage.money = storage.money + (st.paid - need.cost)
    st.paid = need.cost
  end
  local target = need.cost * pad_cargo_frac(site)
  if not storage.pad_paused and st.paid < target then
    local want = math.min(pad_rate(site), target - st.paid)
    local pay = math.max(0, math.min(want, storage.money - pad_reserve()))
    if pay > 0 then
      storage.money = storage.money - pay
      storage.spent_total = (storage.spent_total or 0) + pay
      st.paid = st.paid + pay
    end
    if pay < want - 0.001 then st.waiting_cash = true end
  end
  local silo = pad_silo(site)
  local built = st.paid >= need.cost - 0.5
  if silo then
    -- the silo's rocket parts follow the assembly; at 100% the engine rolls the rocket out
    local status = silo.rocket_silo_status
    if status == defines.rocket_silo_status.building_rocket then
      local req = silo.prototype.rocket_parts_required or 100
      local parts = built and req or math.min(req - 1, math.floor(req * st.paid / math.max(1, need.cost)))
      if silo.rocket_parts ~= parts then silo.rocket_parts = parts end
    end
    if built and st.colonists >= need.colonists and st.mail >= need.mail and st.goods >= need.goods
      and status == defines.rocket_silo_status.rocket_ready then
      no_silo_victory()
      -- 0.9.7: send the cargo pod to orbit. With no destination, 2.x sends the pod back down
      -- to the surface (to 0,0 without a landing pad): Steve saw a "rocket descending into the
      -- earth" and its shadow flying across the map.
      if silo.launch_rocket({ type = defines.cargo_destination.orbit }) then launch_rocket(site, silo) end
    end
  elseif built and st.colonists >= need.colonists and st.mail >= need.mail and st.goods >= need.goods then
    launch_rocket(site)
  end
end

local function simulate_second()
  update_power()
  for _, site in pairs(storage.sites) do
    local kind = C.KINDS[site.kind]
    local service = (0.6 + 0.4 * site.rating) * power_mult(site)
    local cap = C.STOCK_CAP * site.level
    fl_add(site, "secs", 1)
    if site.kind == "town" then
      -- 0.9.8: in units of C.TOWN_SCALE (a town of 4,000 makes about 3 passengers a second)
      local pax = site.pop / C.PAX_PER_POP * service * sat_mult() / C.TOWN_SCALE
      local mail = site.pop / 400 * service * sat_mult() / C.TOWN_SCALE
      cap = (C.STOCK_CAP + site.pop * 4) / C.TOWN_SCALE
      local p0, m0 = site.stock["fd-passengers"] or 0, site.stock["fd-mail"] or 0
      site.stock["fd-passengers"] = math.min(cap, p0 + pax)
      site.stock["fd-mail"] = math.min(cap / 4, m0 + mail)
      fl_add(site, "mk:fd-passengers", math.max(0, site.stock["fd-passengers"] - p0))
      fl_add(site, "mk:fd-mail", math.max(0, site.stock["fd-mail"] - m0))
      if site.stock["fd-passengers"] >= cap - 1 then fl_add(site, "full", 1) end
    elseif kind.base then
      local mult = (1 + C.LEVEL_BONUS * (site.level - 1)) * service * industry_mult()
      for item, rate in pairs(kind.base) do
        local s0 = site.stock[item] or 0
        site.stock[item] = math.min(cap, s0 + rate * mult)
        fl_add(site, "mk:" .. item, math.max(0, site.stock[item] - s0))
        if site.stock[item] >= cap - 1 then fl_add(site, "full", 1) end
      end
    elseif site.kind == "spaceport" then
      update_spaceport(site)
    elseif kind.main then
      -- steel mill (ore, boosted by coal) and factory (steel, boosted by lumber):
      -- the booster alone makes nothing; it raises the yield of the main input.
      local main = site.input[kind.main] or 0
      local full_rate = C.PROCESS_RATE * site.level * power_mult(site) * industry_mult()
      local p = math.min(main, full_rate)
      local item = kind.produces[1]
      local room = cap - (site.stock[item] or 0)
      site.output_full = p > 0 and room < 1
      if room < 1 then
        fl_add(site, "full", 1)
        if p > 0 then fl_add(site, "block", 1) end
      end
      if p <= 0 then fl_add(site, "starve", 1) end
      if p > 0 and room >= 1 then
        local b = math.min(site.input[kind.booster] or 0, p * 0.5)
        local frac = b / (p * 0.5)
        local out = p * (kind.base_yield + (kind.full_yield - kind.base_yield) * frac)
        -- pause instead of wasting: only process what the output pile can hold (0.3.4)
        if out > room then
          local f = room / out
          p, b, out = p * f, b * f, room
        end
        site.input[kind.main] = main - p
        site.input[kind.booster] = (site.input[kind.booster] or 0) - b
        site.stock[item] = math.min(cap, (site.stock[item] or 0) + out)
        site.boost = frac
        site.made = out
        site.used = p
        site.made_tick = game.tick
        fl_add(site, "mk:" .. item, out)
        fl_add(site, "busy", p / full_rate)
        -- short of ore this second: whatever part of full speed it couldn't run (unless the
        -- output pile was what held it back)
        if out < room then fl_add(site, "starve", 1 - p / full_rate) else fl_add(site, "block", 1 - p / full_rate) end
        fl_add(site, "proc", p)
        fl_add(site, "bdef", p * (1 - frac))
      end
    end
  end
end

local function simulate_minute()
  for _, site in pairs(storage.sites) do
    local served = site.picked_min > 0 and 1 or 0
    site.rating = site.rating * 0.75 + 0.25 * served
    site.picked_min = 0
    site.fl_hist = site.fl_hist or {}
    table.insert(site.fl_hist, 1, site.fl_cur or {})
    while #site.fl_hist > C.FLOW_MINUTES do table.remove(site.fl_hist) end
    site.fl_cur = {}
    level_up_check(site)
    if site.kind == "town" then
      -- last minute's growth, by source, for the status line
      local g = site.grow_acc or {}
      site.growth = g
      site.grow_acc = {}
      grow_town_buildings(site)
    end
  end
end

---------------------------------------------------------------------------
-- Trains: refuel, stuck detection
---------------------------------------------------------------------------

local function all_trains()
  local ok, trains = pcall(function()
    return game.train_manager.get_trains({ surface = surface() })
  end)
  if ok and trains then return trains end
  return {}
end

-- Fuel of the current upgrade tier, topped up every 5 s at cost. Fuel of any other tier
-- in the tank is taken out and refunded at full price, so an upgrade applies at once
-- (the item already burning finishes first).
local function refuel_trains()
  local fuel = upgrade_tier("fuel").item
  local price = C.PRICES[fuel]
  for _, train in pairs(all_trains()) do
    if train.valid then
      for _, group in pairs({ train.locomotives.front_movers, train.locomotives.back_movers }) do
        for _, loco in pairs(group) do
          local inv = loco.get_fuel_inventory()
          if inv then
            for _, t in pairs(upgrade_def("fuel").tiers) do
              if t.item ~= fuel then
                local c = inv.get_item_count(t.item)
                if c > 0 then
                  local removed = inv.remove({ name = t.item, count = c })
                  storage.money = storage.money + removed * C.PRICES[t.item]
                end
              end
            end
            -- 0.8.2: a fuel upgrade takes effect at once. The engine keeps the speed multipliers
            -- of the item being burnt, and an old Express item lasts a long time, so the
            -- burning item is swapped too (charged as one new fuel item).
            local burner = loco.burner
            local cb = burner and burner.currently_burning
            local cname = cb and (cb.name.name or cb.name)
            if cname and cname ~= fuel and storage.money >= price then
              burner.currently_burning = { name = fuel, quality = "normal" }
              burner.remaining_burning_fuel = prototypes.item[fuel].fuel_value
              storage.money = storage.money - price
              storage.fuel_spent = (storage.fuel_spent or 0) + price
            end
            if inv.get_item_count(fuel) < 2 then
              if storage.money >= price * 3 then
                local ins = inv.insert({ name = fuel, count = 3 })
                if ins > 0 then
                  storage.money = storage.money - price * ins
                  storage.fuel_spent = (storage.fuel_spent or 0) + price * ins
                end
              elseif throttle("nofuel", 3600) then
                game.print("[color=red]Not enough money to refuel locomotives![/color]")
              end
            end
          end
        end
      end
    end
  end
end

-- Running shoes upgrade: a force-wide modifier, so it covers every character, now and later.
local function apply_running_speed()
  force().character_running_speed_modifier = upgrade_tier("running").speed
end

-- Wagon capacity upgrade: every cargo wagon's inventory is resized to the current tier. Since
-- 0.8.5 (two tiers removed) a bigger wagon also shrinks back, but only once its cargo fits in the
-- smaller size, so nothing is ever deleted; until then it is retried every 5 s.
local function apply_wagon_capacity()
  local slots = upgrade_tier("wagons").slots
  for _, train in pairs(all_trains()) do
    if train.valid then
      for _, w in pairs(train.cargo_wagons) do
        local inv = w.get_inventory(defines.inventory.cargo_wagon)
        local cur = w.get_inventory_size_override(defines.inventory.cargo_wagon)
        if (cur or 0) < slots and #inv < slots then
          local old = #inv
          w.set_inventory_size_override(defines.inventory.cargo_wagon, slots)
          extend_wagon_filters(w.get_inventory(defines.inventory.cargo_wagon), old)
        elseif #inv > slots and #inv - inv.count_empty_stacks() <= slots then
          inv.sort_and_merge() -- filled stacks first, so the slots that go are empty
          local tail_empty = true
          for i = slots + 1, #inv do
            if inv[i].valid_for_read then tail_empty = false break end
          end
          if tail_empty then w.set_inventory_size_override(defines.inventory.cargo_wagon, slots) end
        end
      end
    end
  end
end

-- 0.8.5: a save above the last tier of a line (the removed wagon tiers) drops to the top tier
-- and gets the removed tiers' prices back.
local function clamp_upgrades()
  storage.upgrades = storage.upgrades or {}
  for _, u in pairs(C.UPGRADES) do
    local lv = storage.upgrades[u.id]
    if lv and lv > #u.tiers then
      local refund = 0
      if u.id == "wagons" then refund = ({ 0, 0, 0, 0, 25000000, 75000000 })[math.min(lv, 6)] end
      storage.upgrades[u.id] = #u.tiers
      storage.money = storage.money + refund
      game.print(string.format("Freight Dispatch: the bigger wagon upgrades were removed. Wagons go back to %s (%d slots) as they empty, and you got $%s back.",
        u.tiers[#u.tiers].name, u.tiers[#u.tiers].slots, M.fmt(refund)))
    end
  end
end

function M.buy_upgrade(player, id)
  local u = upgrade_def(id)
  if not u then return end
  local _, level = upgrade_tier(id)
  local nxt = u.tiers[level + 1]
  if not nxt then return end
  if nxt.rockets and (storage.rockets or 0) < nxt.rockets then
    (player or game).print("[color=red]" .. nxt.name .. " unlocks after your first rocket launch.[/color]")
    return
  end
  if not spend(nxt.price) then
    (player or game).print("[color=red]Not enough money for " .. nxt.name .. " (" .. M.money_str(nxt.price) .. ").[/color]")
    return
  end
  storage.upgrades[id] = level + 1
  refuel_trains()
  apply_wagon_capacity()
  apply_running_speed()
  game.print("[color=green][font=default-bold]Upgrade bought:[/font][/color] " .. u.label .. " -> [color=yellow]" ..
    nxt.name .. "[/color]. " .. nxt.desc .. ((id == "running" or id == "industry") and "." or ", for every train."))
end

-- Cargo outside a wagon (in a player's inventory, or in a removed wagon) goes back to the
-- nearest site that produces it, so it rejoins that site's waiting stock.
local function return_cargo(item, count, x, y)
  local best, bd = nil, math.huge
  item = C.base(item) -- 0.9.0: passengers and mail lose their destination
  for _, s in pairs(storage.sites) do
    for _, it in pairs(C.KINDS[s.kind].produces) do
      if it == item then
        local d = dist(x, y, s.x, s.y)
        if d < bd then best, bd = s, d end
      end
    end
  end
  if best then best.stock[item] = (best.stock[item] or 0) + count end
  return best
end

local function return_inventory_cargo(inv, x, y)
  local moved = {}
  if not inv then return moved end
  for item, _ in pairs(C.CARGO) do
    local c = inv.get_item_count(item)
    if c > 0 then
      local removed = inv.remove({ name = item, count = c })
      if removed > 0 then
        local site = return_cargo(item, removed, x, y)
        table.insert(moved, { item = item, count = removed, site = site })
      end
    end
  end
  return moved
end

local function clear_player_cargo()
  for _, p in pairs(game.players) do
    local pos = p.position
    local moved = {}
    for _, m in pairs(return_inventory_cargo(p.get_main_inventory(), pos.x, pos.y)) do table.insert(moved, m) end
    local cs = p.cursor_stack
    if cs and cs.valid_for_read and C.CARGO[cs.name] then
      local item, count = cs.name, cs.count
      cs.clear()
      table.insert(moved, { item = item, count = count, site = return_cargo(item, count, pos.x, pos.y) })
    end
    for _, m in pairs(moved) do
      p.print(fmt(m.count) .. " [item=" .. m.item .. "] " .. C.CARGO[m.item].label ..
        " left your inventory and went back to " .. (m.site and site_title(m.site) or "nowhere") .. ".")
    end
  end
end

-- Map visibility: locomotives act as moving radars and train stops as fixed ones.
local function reveal_trains()
  local surf, f = surface(), force()
  local r = C.TRAIN_SIGHT
  for _, train in pairs(all_trains()) do
    if train.valid then
      local p = train.front_stock and train.front_stock.position
      if p then f.chart(surf, box(p.x, p.y, r)) end
    end
  end
end

local function reveal_stops()
  local surf, f = surface(), force()
  for _, stop in pairs(surf.find_entities_filtered({ type = "train-stop", force = C.FORCE })) do
    local p = stop.position
    f.chart(surf, box(p.x, p.y, C.STOP_SIGHT))
  end
end

-- Map memory (0.7.6, Steve asked: once seen, no fog of war). Each block of EYE_BLOCK x EYE_BLOCK
-- chunks that has anything charted gets one invisible radar (fd-eye) in its middle chunk, whose
-- nearby scan (radius 2 chunks) keeps exactly that block live. Trains, stops, the survey and the
-- character still do the exploring; the radars only remember.
local EYE_BLOCK = 5
local function place_eye(surf, cx, cy)
  if not prototypes.entity["fd-eye"] then return end
  storage.eyes = storage.eyes or {}
  local bx, by = math.floor(cx / EYE_BLOCK), math.floor(cy / EYE_BLOCK)
  local key = bx .. "," .. by
  local e = storage.eyes[key]
  if e and e.valid then return end
  local half = math.floor(EYE_BLOCK / 2)
  e = surf.create_entity({ name = "fd-eye", force = C.FORCE, create_build_effect_smoke = false,
    position = { (bx * EYE_BLOCK + half) * 32 + 16, (by * EYE_BLOCK + half) * 32 + 16 } })
  if e then
    e.destructible = false
    e.minable_flag = false
    storage.eyes[key] = e
  end
end

-- every charted chunk gets its block's radar (old saves, on configuration change)
local function place_all_eyes()
  local surf, f = surface(), force()
  if not surf then return 0 end
  for c in surf.get_chunks() do
    if f.is_chunk_charted(surf, c) then place_eye(surf, c.x, c.y) end
  end
  return table_size(storage.eyes or {})
end
M.place_all_eyes = place_all_eyes

-- 0.7.8: buy another Spaceport (Shop, after the free first one). It's founded like any site,
-- at least C.SPACEPORT.pad_min_dist tiles from the others, within a few seconds.
function M.buy_pad(player)
  local out = player or game
  if not M.spaceport() then
    out.print("[color=red]Your first Spaceport comes free with the rank of " .. C.RANKS[C.PAD_RANK].title .. ".[/color]")
    return false
  end
  if (storage.pads_pending or 0) > 0 then
    out.print("[color=yellow]A Spaceport is already being founded.[/color]")
    return false
  end
  local price = M.pad_price()
  if not spend(price) then
    out.print("[color=red]A new Spaceport costs " .. M.money_str(price) .. ". Not enough money.[/color]")
    return false
  end
  storage.pads_bought = (storage.pads_bought or 0) + 1
  storage.pads_pending = (storage.pads_pending or 0) + 1
  game.print("[color=green][font=default-bold]Spaceport bought[/font][/color] for " .. M.money_str(price) .. ". Surveyors are choosing a site...")
  return true
end

function M.survey(player)
  local cost = C.SURVEY_PRICE
  if not spend(cost) then
    player.print("[color=red]A land survey costs " .. M.money_str(cost) .. ". Not enough money.[/color]")
    return
  end
  local p = player.position
  force().chart(surface(), box(p.x, p.y, C.SURVEY_RADIUS))
  player.print("Surveyors are mapping " .. (C.SURVEY_RADIUS * 2) .. " x " .. (C.SURVEY_RADIUS * 2) ..
    " tiles around [gps=" .. math.floor(p.x) .. "," .. math.floor(p.y) .. "," .. C.SURFACE .. "] for " .. M.money_str(cost) ..
    ". New towns and industries out there will appear as the map fills in.")
end

local function check_stuck()
  for id, s in pairs(storage.stuck) do
    if not s.train.valid or s.train.state ~= defines.train_state.wait_signal then
      storage.stuck[id] = nil
    elseif not s.reported and game.tick - s.tick > C.STUCK_TICKS then
      s.reported = true
      local front = s.train.front_stock
      if front and front.valid then
        local p = front.position
        game.print("[color=orange]A train has been waiting at a red signal for 3 minutes - possible deadlock.[/color] [gps=" ..
          math.floor(p.x) .. "," .. math.floor(p.y) .. "," .. C.SURFACE .. "]")
      end
    end
  end
end

---------------------------------------------------------------------------
-- Instant construction (ghosts are built and charged)
---------------------------------------------------------------------------

-- Ghosts are built instantly. Matching items in the placing player's inventory are used
-- first; otherwise the piece is paid for in cash. A summary of each batch floats up.
local function process_ghosts()
  local q = storage.ghost_queue
  if #q == 0 then return end
  local surf = surface()
  local keep = {}
  local processed = 0
  local batches = {} -- per player: {cash, items, pieces, pos}
  for i = 1, #q do
    local g = q[i]
    if processed >= 200 then
      table.insert(keep, g)
    elseif g.ghost.valid then
      processed = processed + 1
      local ghost = g.ghost
      local cost, item = ghost_cost(ghost)
      local player = g.player_index and game.get_player(g.player_index)
      local inv = player and player.valid and player.get_main_inventory()
      local need = 0
      if item then
        local proto = ghost.ghost_prototype
        local it = proto.items_to_place_this[1]
        need = (type(it) == "table" and it.count) or 1
      end
      local use_items = inv and item and inv.get_item_count(item) >= need
      if not cost then
        if throttle("noprice" .. ghost.ghost_name, 600) then
          game.print("[color=orange]" .. ghost.ghost_name .. " can't be bought in Freight Dispatch, so the ghost was left in place.[/color]")
        end
      elseif not use_items and storage.money < cost then
        -- can't afford it yet: keep waiting (it builds once money comes in)
        if throttle("broke", 600) then
          game.print("[color=red]Not enough money to build that! Need " .. M.money_str(cost) ..
            ". The ghosts will build as soon as you can afford them.[/color]")
        end
        table.insert(keep, g)
      else
        local b = batches[g.player_index or 0]
        if not b then
          b = { cash = 0, items = 0, pieces = 0 }
          batches[g.player_index or 0] = b
        end
        -- clear trees and rocks in the way
        local obstacles = surf.find_entities_filtered({ area = ghost.bounding_box, type = { "tree", "simple-entity" } })
        for _, o in pairs(obstacles) do
          if o.valid and spend(C.CLEAR_FEE) then
            o.destroy()
            b.cash = b.cash + C.CLEAR_FEE
          end
        end
        local pos = ghost.position
        local ok, err = pcall(function() ghost.revive({ raise_revive = true }) end)
        if ok and not ghost.valid then
          if use_items then
            inv.remove({ name = item, count = need })
            b.items = b.items + need
          else
            spend(cost)
            b.cash = b.cash + cost
          end
          b.pieces = b.pieces + 1
          b.pos = pos
        else
          -- blocked (e.g. a train or a player in the way): retry for about a minute
          if g.tries == 0 then log("FD ghost revive failed: " .. tostring(ok) .. " " .. tostring(err) .. " " .. ghost.ghost_name) end
          g.tries = g.tries + 1
          if g.tries < 360 then table.insert(keep, g) end
        end
      end
    end
  end
  storage.ghost_queue = keep
  for _, b in pairs(batches) do
    if b.pos and (b.cash > 0 or b.items > 0) then
      local parts = {}
      if b.cash > 0 then table.insert(parts, "-" .. M.money_str(b.cash)) end
      if b.items > 0 then table.insert(parts, b.items .. " from inventory") end
      rendering.draw_text({
        text = "Built " .. b.pieces .. ": " .. table.concat(parts, ", "),
        surface = surf, target = { b.pos.x, b.pos.y - 1 }, color = { 1, 0.75, 0.4 },
        scale = 1.4, time_to_live = 150, alignment = "center",
      })
    end
  end
end

---------------------------------------------------------------------------
-- Contracts
---------------------------------------------------------------------------

local function producers_exist(item)
  for _, s in pairs(storage.sites) do
    for _, it in pairs(C.KINDS[s.kind].produces) do
      if it == item then return true end
    end
  end
  return false
end

-- Contracts stick to your network: a served site, for cargo a served site produces.
-- Deliveries you already make there are 4x as likely. Only before you serve anything
-- (a new game) can a contract name any site.
local function new_contract()
  local served = served_ids()
  local makes = {}
  for id in pairs(served) do
    local s = storage.sites[id]
    if s then
      for _, it in pairs(C.KINDS[s.kind].produces) do makes[it] = true end
    end
  end
  -- never two contracts for the same cargo to the same site
  local active = {}
  for _, ct in pairs(storage.contracts) do
    if not ct.done then active[ct.site_id .. "/" .. ct.item] = true end
  end
  local candidates = {}
  for id in pairs(served) do
    local s = storage.sites[id]
    if s and s.kind ~= "spaceport" then -- it only takes what the next rocket needs
      for _, item in pairs(C.KINDS[s.kind].accepts) do
        if makes[item] and not active[id .. "/" .. item] then
          local w = (s.recv and (s.recv[item] or 0) > 0) and 4 or 1
          if not C.TOWN_CARGO[item] then w = w * 3 end -- freight contracts are more common
          table.insert(candidates, { site = s, item = item, w = w })
        end
      end
    end
  end
  if #candidates == 0 then
    for _, s in pairs(storage.sites) do
      for _, item in pairs(s.kind == "spaceport" and {} or C.KINDS[s.kind].accepts) do
        if producers_exist(item) and not active[s.id .. "/" .. item] then
          table.insert(candidates, { site = s, item = item, w = 1 })
        end
      end
    end
  end
  if #candidates == 0 then return end
  -- deterministic order
  table.sort(candidates, function(a, b)
    if a.site.id ~= b.site.id then return a.site.id < b.site.id end
    return a.item < b.item
  end)
  local total = 0
  for _, cand in ipairs(candidates) do total = total + cand.w end
  local r = rand() * total
  local c = candidates[#candidates]
  for _, cand in ipairs(candidates) do
    r = r - cand.w
    if r <= 0 then c = cand; break end
  end
  local scale = 1 + math.min(4, storage.lifetime / 2000000)
  local freight = not C.TOWN_CARGO[c.item]
  local amount = math.floor((rand_int(3, 8) * 500 * scale * (freight and 2 or 1)) / 100) * 100
  if not freight then amount = math.floor(amount / C.TOWN_SCALE / 10) * 10 end -- 0.9.8
  -- bonus = what the cargo would earn over 1,200 tiles (freight) or 600 tiles (town cargo),
  -- rounded to $100. Freight: double the amount and double the rate (0.3.0).
  local reward = math.floor(amount * C.CARGO[c.item].rate * (freight and 12 or 6) / 100) * 100
  -- 0.7.8: at least C.CONTRACT_INCOME_MINS minutes of recent income, so they still matter late
  local floor = math.floor(M.recent_income_per_min() * C.CONTRACT_INCOME_MINS / 10000) * 10000
  reward = math.max(reward, floor)
  table.insert(storage.contracts, {
    site_id = c.site.id, item = c.item, amount = amount, delivered = 0,
    deadline = game.tick + C.CONTRACT_TICKS, reward = reward,
  })
  game.print("[color=cyan]New contract:[/color] deliver " .. fmt(amount) .. " [item=" .. c.item .. "] " .. C.CARGO[c.item].label .. " to " ..
    site_title(c.site) .. " within 30 min for a " .. M.money_str(reward) .. " bonus. [gps=" ..
    c.site.x .. "," .. c.site.y .. "," .. C.SURFACE .. "]")
end

local function update_contracts()
  local keep = {}
  for _, ct in pairs(storage.contracts) do
    if ct.done then
      -- drop
    elseif game.tick > ct.deadline then
      local s = storage.sites[ct.site_id]
      game.print("[color=gray]Contract expired: [item=" .. ct.item .. "] to " .. (s and site_title(s) or "?") .. "[/color]")
    else
      table.insert(keep, ct)
    end
  end
  storage.contracts = keep
  if #storage.contracts < 3 and game.tick >= storage.next_contract_tick then
    new_contract()
    storage.next_contract_tick = game.tick + C.CONTRACT_GAP
  end
end

---------------------------------------------------------------------------
-- Ranks
---------------------------------------------------------------------------

-- ranks are reached in order: lifetime earnings, and (0.7.9 space ranks) rockets launched
function M.rank()
  local idx = 1
  for i, r in ipairs(C.RANKS) do
    if storage.lifetime >= r.at and (storage.rockets or 0) >= (r.rockets or 0) then idx = i else break end
  end
  return idx
end

local function check_rank()
  local r = M.rank()
  if r > (storage.rank or 1) then
    storage.rank = r
    local rk = C.RANKS[r]
    game.print("[color=yellow][font=default-large-bold]Promotion! You are now: " .. rk.title .. "[/font][/color]")
    if r >= C.PAD_RANK and not M.spaceport() then storage.pad_wanted = true end
    if r == #C.RANKS then
      game.print("[color=green][font=default-large-bold]Your railway reaches the stars. You win! (Keep playing if you like.)[/font][/color]")
    end
  end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local function make_surface()
  local surf = game.surfaces[C.SURFACE]
  if surf then return surf end
  local mgs = game.surfaces["nauvis"].map_gen_settings
  mgs.seed = math.random(1, 4000000000)
  local controls = mgs.autoplace_controls or {}
  for name, ctl in pairs(controls) do
    local proto = prototypes.autoplace_control[name]
    if proto and (proto.category == "resource" or proto.category == "enemy") then
      ctl.size = 0
    elseif name == "trees" then
      ctl.size = 0.35
      ctl.frequency = 0.5
    elseif name == "water" then
      ctl.size = 0.8
    end
  end
  mgs.autoplace_controls = controls
  if mgs.cliff_settings then mgs.cliff_settings.richness = 0 end
  mgs.starting_area = 1
  mgs.peaceful_mode = true
  surf = game.create_surface(C.SURFACE, mgs)
  surf.always_day = true
  return surf
end

-- Research C.TECHS (e.g. circuit-network unlocks the red/green wire shortcuts), then disable
-- every recipe except the Shop items. Also run on configuration change for older saves.
local function unlock_techs()
  local f = force()
  for _, t in pairs(C.TECHS) do
    if f.technologies[t] then f.technologies[t].researched = true end
  end
  for _, r in pairs(f.recipes) do r.enabled = false end
  -- keep shop items "unlocked" so their ghosts can be placed (they still can't be crafted: no materials exist)
  for item, _ in pairs(C.PRICES) do
    if f.recipes[item] then f.recipes[item].enabled = true end
  end
end

local function setup_force()
  local f = force()
  unlock_techs()
  pcall(function() f.disable_research() end)
  f.character_running_speed_modifier = 1.0
  f.manual_mining_speed_modifier = 4
  f.character_build_distance_bonus = 20
  f.character_reach_distance_bonus = 20
  f.set_spawn_position({ 0, 0 }, surface())
  f.chart(surface(), box(0, 0, 160))
end

local function setup_player(player)
  local surf = surface()
  if player.character or player.controller_type == defines.controllers.character then
    if player.surface.name ~= C.SURFACE then
      local pos = surf.find_non_colliding_position("character", { 0, 0 }, 64, 1) or { 0, 0 }
      player.teleport(pos, surf)
    end
  end
  gui.build_hud(player)
  if not storage.welcomed[player.index] then
    storage.welcomed[player.index] = true
    player.print("[font=default-large-bold]Welcome to Freight Dispatch![/font] Open [color=yellow]Help[/color] on the left panel for how to play. Tip: press M for the map, where you can lay rails (ghosts are built instantly and charged to your account).")
  end
end

local function init_storage()
  storage.sites = storage.sites or {}
  storage.next_site_id = storage.next_site_id or 1
  storage.dest_sites = storage.dest_sites or {}
  storage.stop_links = storage.stop_links or {}
  storage.wagons = storage.wagons or {}
  storage.waiting = storage.waiting or {}
  storage.stuck = storage.stuck or {}
  storage.ghost_queue = storage.ghost_queue or {}
  storage.chunk_queue = nil -- before 0.4.0, sites were rolled per generated chunk
  storage.contracts = storage.contracts or {}
  storage.next_contract_tick = storage.next_contract_tick or (C.CONTRACT_GAP / 2)
  storage.money = storage.money or C.START_MONEY
  storage.lifetime = storage.lifetime or 0
  storage.signal_boxes = storage.signal_boxes or {}
  storage.earned_sec = storage.earned_sec or 0
  storage.income_hist = storage.income_hist or {}
  storage.welcomed = storage.welcomed or {}
  storage.rank = storage.rank or 1
  storage.seed = storage.seed or 12345
  storage.upgrades = storage.upgrades or {}
end

local function unregister_all()
  for _, id in pairs(defines.events) do script.on_event(id, nil) end
  script.on_nth_tick(nil)
end

script.on_load(function()
  if storage.disabled then unregister_all() end
end)

script.on_init(function()
  if game.tick > 0 then
    -- Added to an existing save: stay dormant so we never wreck a normal factory game.
    storage.disabled = true
    unregister_all()
    game.print("[color=orange]Freight Dispatch only works on a NEW map. It is inactive in this save. Disable the mod to play normal Factorio.[/color]")
    return
  end
  init_storage()
  storage.town_scale = C.TOWN_SCALE -- 0.9.8: new maps start at the new scale
  if remote.interfaces["freeplay"] then
    local fp = remote.interfaces["freeplay"]
    if fp["set_disable_crashsite"] then remote.call("freeplay", "set_disable_crashsite", true) end
    if fp["set_skip_intro"] then remote.call("freeplay", "set_skip_intro", true) end
    if fp["set_created_items"] then remote.call("freeplay", "set_created_items", {}) end
    if fp["set_respawn_items"] then remote.call("freeplay", "set_respawn_items", {}) end
  end
  local surf = make_surface()
  storage.seed = (surf.map_gen_settings.seed % 2147483647) + 1
  surf.request_to_generate_chunks({ 0, 0 }, 24) -- starters reach about 560 tiles out, plus 160 of search
  surf.force_generate_chunk_requests()
  place_starters()
  pcall(function() game.map_settings.pollution.enabled = false end)
  pcall(function() game.map_settings.enemy_expansion.enabled = false end)
  setup_force()
  no_silo_victory()
  for _, p in pairs(game.players) do setup_player(p) end
end)

-- 0.9.8: one-time migration of a save from before the passenger and mail rescale. Everything
-- counted in passengers or letters shrinks by C.TOWN_SCALE: towns' waiting stock, every wagon
-- stack (Factorio keeps the old 50-stacks as they are when the stack size drops to 5) and its
-- origin records, the Spaceports' colonists and mail aboard, contracts and the flow meters.
local function rescale_town_cargo()
  local from = storage.town_scale or 1
  if from >= C.TOWN_SCALE then return end
  local f = from / C.TOWN_SCALE
  local function town_key(key) return key:find("fd-passengers", 1, true) or key:find("fd-mail", 1, true) end
  local function scale_flows(t)
    for key, v in pairs(t or {}) do
      if town_key(key) then t[key] = v * f end
    end
  end
  for _, s in pairs(storage.sites) do
    for b in pairs(C.TOWN_CARGO) do
      if s.stock[b] then s.stock[b] = s.stock[b] * f end
    end
    if s.pad then
      s.pad.colonists = math.floor((s.pad.colonists or 0) * f)
      s.pad.mail = math.floor((s.pad.mail or 0) * f)
    end
    scale_flows(s.fl_cur)
    for _, h in pairs(s.fl_hist or {}) do scale_flows(h) end
  end
  local before_total, after_total = 0, 0
  for _, w in pairs(surface().find_entities_filtered({ type = "cargo-wagon" })) do
    local inv = w.get_inventory(defines.inventory.cargo_wagon)
    local before, after = {}, {}
    for i = 1, #inv do
      local st = inv[i]
      if st.valid_for_read and C.TOWN_CARGO[C.base(st.name)] then
        local name, n = st.name, math.floor(st.count * f)
        before[name] = (before[name] or 0) + st.count
        after[name] = (after[name] or 0) + n
        before_total, after_total = before_total + st.count, after_total + n
        if n > 0 then st.count = n else st.clear() end
      end
    end
    local rec = storage.wagons[w.unit_number]
    if rec then
      for item, old in pairs(before) do
        local lots = get_lots(rec, item)
        if lots then
          local r = after[item] / old
          local keep = {}
          for _, lot in ipairs(lots) do
            lot.amount = lot.amount * r
            if lot.amount > 0.001 then table.insert(keep, lot) end
          end
          rec[item] = #keep > 0 and keep or nil
        end
      end
    end
  end
  for _, ct in pairs(storage.contracts or {}) do
    if C.TOWN_CARGO[ct.item] then
      ct.amount = math.max(10, math.floor(ct.amount * f / 10) * 10)
      ct.delivered = math.floor((ct.delivered or 0) * f)
    end
  end
  storage.town_scale = C.TOWN_SCALE
  log("freight-dispatch: passengers and mail rescaled by " .. f .. " (wagons " .. before_total .. " -> " .. after_total .. ")")
  game.print("[color=cyan]Passengers and mail now come in believable numbers: a tenth as many, each paying ten times the fare. " ..
    "Waiting riders, wagons, rockets and contracts were converted. If an interrupt or circuit compares passenger or mail counts, divide its number by " ..
    C.TOWN_SCALE .. ".[/color]")
end

script.on_configuration_changed(function()
  if storage.disabled then return end
  init_storage()
  unlock_techs()
  clamp_upgrades()
  if game.surfaces[C.SURFACE] then
    rescale_town_cargo()
    relayout_towns()
    -- paint any train still in default red (all trains in saves from before 0.3.5)
    for _, t in pairs(game.train_manager.get_trains({ surface = game.surfaces[C.SURFACE] })) do paint_train(t) end
    -- 0.7.0: a save already at Railway Tycoon gets its Spaceport
    if M.rank() >= C.PAD_RANK and not M.spaceport() then storage.pad_wanted = true end
    -- 0.7.4: the Spaceport's picture becomes a real silo (doors and rocket animate)
    for _, pad in pairs(M.spaceports()) do ensure_pad_silo(pad) end
    -- 0.7.6: no fog of war over anything already charted
    place_all_eyes()
    no_silo_victory()
  end
  for _, p in pairs(game.players) do gui.build_hud(p) end
end)

-- A train forms or changes whenever a carriage is built, coupled or uncoupled. Each new
-- carriage briefly forms a train of its own before coupling, so painting waits for the
-- next second (when the train has settled; see on_nth_tick 60).
script.on_event(defines.events.on_train_created, function(e)
  if e.train.valid and e.train.carriages[1].surface.name == C.SURFACE then
    storage.paint_queue = storage.paint_queue or {}
    table.insert(storage.paint_queue, e.train)
  end
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

script.on_event(defines.events.on_player_created, function(e)
  setup_player(game.get_player(e.player_index))
end)

script.on_event(defines.events.on_player_respawned, function(e)
  local p = game.get_player(e.player_index)
  if p and p.surface.name ~= C.SURFACE then setup_player(p) end
end)

script.on_event(defines.events.on_chunk_charted, function(e)
  if e.surface_index ~= (surface() and surface().index) then return end
  local cx, cy = e.position.x, e.position.y
  place_eye(surface(), cx, cy)
  for _, s in pairs(storage.sites) do
    if not s.tagged and math.floor(s.x / 32) == cx and math.floor(s.y / 32) == cy then
      tag_site(s)
    end
  end
end)

script.on_event(defines.events.on_built_entity, function(e)
  local ent = e.entity
  if not (ent and ent.valid) or ent.surface.name ~= C.SURFACE then return end
  if ent.name == "entity-ghost" or ent.name == "tile-ghost" then
    table.insert(storage.ghost_queue, { ghost = ent, player_index = e.player_index, tries = 0 })
  elseif ent.type == "train-stop" then
    on_stop_built(ent, game.get_player(e.player_index))
  elseif ent.name == "fd-site-signals" then
    on_signals_built(ent, game.get_player(e.player_index))
  end
end)

local function on_script_built(e)
  local ent = e.entity
  if not (ent and ent.valid) then return end
  if ent.type == "train-stop" then on_stop_built(ent)
  elseif ent.name == "fd-site-signals" then on_signals_built(ent) end
end
script.on_event(defines.events.script_raised_revive, on_script_built)
script.on_event(defines.events.script_raised_built, on_script_built)
script.on_event(defines.events.on_robot_built_entity, on_script_built)

script.on_event(defines.events.on_marked_for_deconstruction, function(e)
  local ent = e.entity
  if not e.player_index or not (ent and ent.valid) or ent.surface.name ~= C.SURFACE then return end
  if ent.type == "tree" or ent.type == "simple-entity" then
    if spend(C.CLEAR_FEE) then ent.destroy() end
    return
  end
  if ent.force.name == C.FORCE and ent.name ~= "entity-ghost" then
    local cost = entity_cost(ent)
    if cost then
      local refund = math.floor(cost * C.REFUND)
      local p = ent.position
      local surf = ent.surface
      if ent.type == "cargo-wagon" then
        return_inventory_cargo(ent.get_inventory(defines.inventory.cargo_wagon), p.x, p.y)
      end
      if ent.destroy({ raise_destroy = true }) then
        storage.money = storage.money + refund
        rendering.draw_text({ text = "+" .. M.money_str(refund) .. " refund", surface = surf, target = p,
          color = { 0.8, 0.8, 0.4 }, scale = 1, time_to_live = 90, alignment = "center" })
      end
    end
  end
end)

-- Mining a cargo wagon by hand: its cargo goes home instead of into your inventory.
script.on_event(defines.events.on_player_mined_entity, function(e)
  local ent = e.entity
  if not (ent and ent.valid) or ent.surface.name ~= C.SURFACE or not e.buffer then return end
  local p = ent.position
  local moved = return_inventory_cargo(e.buffer, p.x, p.y)
  local player = game.get_player(e.player_index)
  if player then
    for _, m in pairs(moved) do
      player.print(fmt(m.count) .. " [item=" .. m.item .. "] " .. C.CARGO[m.item].label ..
        " got off and went back to " .. (m.site and site_title(m.site) or "nowhere") .. ".")
    end
  end
end, { { filter = "type", type = "cargo-wagon" } })

script.on_event(defines.events.on_marked_for_upgrade, function(e)
  local ent = e.entity
  if not e.player_index or not (ent and ent.valid) or ent.surface.name ~= C.SURFACE then return end
  if ent.force.name ~= C.FORCE then return end
  local target = e.target
  if not target then return end
  local old_cost = entity_cost(ent)
  local new_cost = prototype_cost(target)
  if not (old_cost and new_cost) then return end
  local diff = new_cost - old_cost
  if diff > 0 and storage.money < diff then
    game.get_player(e.player_index).print("[color=red]Not enough money for that upgrade.[/color]")
    return
  end
  local surf, pos, dir, f = ent.surface, ent.position, ent.direction, ent.force
  local new = surf.create_entity({
    name = target.name, position = pos, direction = dir, force = f,
    fast_replace = true, spill = false, raise_built = true, create_build_effect_smoke = false,
  })
  if new then
    if diff > 0 then spend(diff) else storage.money = storage.money - math.floor(diff * C.REFUND) end
  elseif ent.valid then
    ent.cancel_upgrade(f)
  end
end)

script.on_event(defines.events.on_train_changed_state, function(e)
  local train = e.train
  if not train.valid then return end
  if train.state == defines.train_state.wait_station then
    storage.waiting[train.id] = train
    service_train(train) -- unload immediately on arrival
  else
    storage.waiting[train.id] = nil
  end
  if train.state == defines.train_state.wait_signal then
    storage.stuck[train.id] = { train = train, tick = game.tick }
  else
    storage.stuck[train.id] = nil
  end
end)

script.on_event(defines.events.on_object_destroyed, function(e)
  if e.useful_id then
    storage.wagons[e.useful_id] = nil
    if storage.painted then storage.painted[e.useful_id] = nil end
  end
end)

script.on_event(defines.events.on_entity_died, function(e)
  local ent = e.entity
  if ent and ent.valid and ent.surface.name == C.SURFACE and throttle("wreck", 120) then
    local p = ent.position
    game.print("[color=red][font=default-bold]Train wreck![/font][/color] Rolling stock was destroyed. Check your signals! [gps=" ..
      math.floor(p.x) .. "," .. math.floor(p.y) .. "," .. C.SURFACE .. "]")
  end
end, { { filter = "type", type = "locomotive" }, { filter = "type", type = "cargo-wagon" } })

-- Main loops ---------------------------------------------------------------

script.on_nth_tick(10, function()
  process_ghosts()
end)

script.on_nth_tick(2, function()
  animate_launches()
end)

script.on_nth_tick(120, function()
  maybe_found_site()
end)

script.on_nth_tick(60, function(e)
  simulate_second()
  update_signal_boxes()
  if storage.paint_queue and #storage.paint_queue > 0 then
    for _, t in pairs(storage.paint_queue) do paint_train(t) end -- skips trains merged since
    storage.paint_queue = {}
  end
  for id, train in pairs(storage.waiting) do
    if train.valid and train.state == defines.train_state.wait_station then
      service_train(train)
    else
      storage.waiting[id] = nil
    end
  end
  table.insert(storage.income_hist, storage.earned_sec)
  storage.earned_sec = 0
  if #storage.income_hist > 60 then table.remove(storage.income_hist, 1) end
  clear_player_cargo()
  if e.tick % 120 == 0 then reveal_trains() end
  if e.tick % 600 == 300 then reveal_stops() end
  if e.tick % 300 == 0 then
    refuel_trains()
    apply_wagon_capacity()
    for id, c in pairs(storage.dest_cache or {}) do
      if e.tick - c.tick > 3600 then storage.dest_cache[id] = nil end
    end
    for _, s in pairs(storage.sites) do update_site_render(s) end
  end
  if e.tick % C.INCOME_LOG_TICKS == 0 then
    -- balance history (0.6.0): earnings by cargo and total town population, every 10 minutes
    local pop = 0
    for _, s in pairs(storage.sites) do if s.kind == "town" then pop = pop + s.pop end end
    local earned = {}
    for k, v in pairs(storage.earned_item or {}) do earned[k] = math.floor(v) end
    storage.income_log = storage.income_log or {}
    table.insert(storage.income_log, { tick = e.tick, lifetime = math.floor(storage.lifetime), pop = math.floor(pop), earned = earned })
  end
  if e.tick % 600 == 0 then
    check_stuck()
    update_contracts()
    check_rank()
  end
  if e.tick % 3600 == 0 then simulate_minute() end
  for _, p in pairs(game.connected_players) do gui.update(p) end
end)

-- average income over the last 10-minute income_log interval (steadier than the HUD's last
-- minute); the HUD figure until two log entries exist
function M.recent_income_per_min()
  local log = storage.income_log or {}
  local a, b = log[#log - 1], log[#log]
  if a and b and b.tick > a.tick then
    return math.max(0, (b.lifetime - a.lifetime) / ((b.tick - a.tick) / 3600))
  end
  return M.income_per_min()
end

function M.income_per_min()
  local t = 0
  for _, v in pairs(storage.income_hist) do t = t + v end
  return t * 60 / math.max(1, #storage.income_hist)
end

---------------------------------------------------------------------------
-- Supply chain analysis (0.5.0, Steve asked for an in-game way to see shortages and what to
-- work on next). Served sites only, averaged over the flow meters' window (C.FLOW_MINUTES).
--   row per freight cargo: made / delivered / wanted per second, producers, consumers, status
--     short  = a consumer spent > CHAIN_SHORT of its time without it (booster: boost below full,
--              power plant: dry), with a cause:
--              none (nothing connected makes it), pickup (producer piles full, irregular pickups,
--              or enough is made but trains don't carry it), upstream (the producing mill or
--              factory is itself short of `cause_item`), capacity (producer at full speed),
--              production (producers just don't make enough)
--     backed = nobody short, but a producer's pile keeps filling up (needs more pickups)
--   next   = one suggestion: the root cause with the biggest effect, plus sites to click.
--            Expansion over levelling (Steve's choice): it names a spare site to connect.
---------------------------------------------------------------------------
local CHAIN_ITEMS = { "fd-iron-ore", "fd-coal", "fd-steel", "fd-wood", "fd-goods" }
M.CHAIN_ITEMS = CHAIN_ITEMS
local ROLE_WEIGHT = { main = 1, booster = 0.5, fuel = 0.3 }
local FULL_SHARE = 0.15 -- a pile full this much of the time means pickups can't keep up

local function producer_kind(item)
  for _, k in ipairs(C.KIND_ORDER) do
    for _, it in pairs(C.KINDS[k].produces) do
      if it == item then return k end
    end
  end
end

local function nearest_spare(kind, to, served)
  local best, bd
  for id, s in pairs(storage.sites) do
    if s.kind == kind and not served[id] then
      local d = dist(s.x, s.y, to.x, to.y)
      if not bd or d < bd then best, bd = s, d end
    end
  end
  return best, bd
end

local function kind_label(kind) return C.KINDS[kind].label:lower() end
local function item_label(item) return icon(item) .. " " .. C.CARGO[item].label:lower() end
local function pct(f) return math.floor(f * 100 + 0.5) .. "%" end

function M.supply_chain()
  local served = served_ids()
  local rows = {}
  for _, it in ipairs(CHAIN_ITEMS) do
    rows[it] = { item = it, made = 0, got = 0, wanted = 0, producers = {}, consumers = {} }
  end
  local towns = { n = 0, growing = {}, full = {},
    pax = { made = 0, carried = 0, got = 0 }, mail = { made = 0, carried = 0, got = 0 } }
  local window = 0
  local spare = {}
  for id, s in pairs(storage.sites) do
    if not served[id] then spare[s.kind] = (spare[s.kind] or 0) + 1 end
  end
  local ids = {}
  for id in pairs(served) do if storage.sites[id] then table.insert(ids, id) end end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local s = storage.sites[id]
    local kind = C.KINDS[s.kind]
    window = math.max(window, fl_sum(s, "secs"))
    if s.kind == "town" then
      towns.n = towns.n + 1
      if (s.growth and s.growth["fd-goods"] or 0) >= 0.5 then table.insert(towns.growing, s) end
      if fl_rate(s, "full") > FULL_SHARE then table.insert(towns.full, s) end
      for key, it in pairs({ pax = "fd-passengers", mail = "fd-mail" }) do
        local t = towns[key]
        t.made = t.made + fl_rate(s, "mk:" .. it)
        t.carried = t.carried + fl_rate(s, "tx:" .. it)
        t.got = t.got + fl_rate(s, "rx:" .. it)
      end
      table.insert(rows["fd-goods"].consumers, { site = s, role = "town", wanted = 0, got = fl_rate(s, "rx:fd-goods"), short = 0 })
    elseif s.kind == "spaceport" then
      table.insert(rows["fd-goods"].consumers, { site = s, role = "pad", wanted = 0, got = fl_rate(s, "rx:fd-goods"), short = 0 })
    elseif kind.base then
      local item = next(kind.base)
      table.insert(rows[item].producers, { site = s, rate = fl_rate(s, "mk:" .. item), full = fl_rate(s, "full"),
        service = 0.6 + 0.4 * s.rating })
    elseif kind.main then
      local item = kind.produces[1]
      local full_rate = C.PROCESS_RATE * s.level * power_mult(s) * industry_mult()
      local proc = fl_sum(s, "proc")
      local p = { site = s, rate = fl_rate(s, "mk:" .. item), full = fl_rate(s, "full"), busy = fl_rate(s, "busy"),
        starve = fl_rate(s, "starve"), block = fl_rate(s, "block"), bshort = proc > 0 and fl_sum(s, "bdef") / proc or 0,
        main = kind.main, booster = kind.booster }
      table.insert(rows[item].producers, p)
      table.insert(rows[kind.main].consumers, { site = s, role = "main", wanted = full_rate,
        got = fl_rate(s, "rx:" .. kind.main), short = p.starve, busy = p.busy })
      table.insert(rows[kind.booster].consumers, { site = s, role = "booster", wanted = full_rate * 0.5,
        got = fl_rate(s, "rx:" .. kind.booster), short = p.bshort })
    elseif s.kind == "power-plant" then
      local fc = fl_sum(s, "rx:fd-coal") * C.POWER.fuel["fd-coal"]
      local fw = fl_sum(s, "rx:fd-wood") * C.POWER.fuel["fd-wood"]
      local share = (fc + fw) > 0 and fc / (fc + fw) or 1 -- coal's part of its fuel
      local dry = fl_rate(s, "starve")
      if share > 0 then
        table.insert(rows["fd-coal"].consumers, { site = s, role = "fuel", wanted = C.POWER.burn * share / C.POWER.fuel["fd-coal"],
          got = fl_rate(s, "rx:fd-coal"), short = share >= 0.5 and dry or 0 })
      end
      if share < 1 then
        table.insert(rows["fd-wood"].consumers, { site = s, role = "fuel", wanted = C.POWER.burn * (1 - share) / C.POWER.fuel["fd-wood"],
          got = fl_rate(s, "rx:fd-wood"), short = share < 0.5 and dry or 0 })
      end
    end
  end

  -- status and cause per row
  for _, it in ipairs(CHAIN_ITEMS) do
    local r = rows[it]
    for _, p in ipairs(r.producers) do r.made = r.made + p.rate end
    local worst, wsev = nil, 0
    for _, c in ipairs(r.consumers) do
      r.wanted = r.wanted + c.wanted
      r.got = r.got + c.got
      local sev = c.short * (ROLE_WEIGHT[c.role] or 0)
      if c.short > C.CHAIN_SHORT and sev > wsev then worst, wsev = c, sev end
    end
    r.who = worst and worst.site
    r.sev = wsev
    local fullest
    for _, p in ipairs(r.producers) do
      if p.full > FULL_SHARE and (not fullest or p.full > fullest.full) then fullest = p end
    end
    if worst then
      r.status = "short"
      local primary = r.producers[1] and C.KINDS[r.producers[1].site.kind].base
      -- irregular pickups only count as the cause if full service would cover the demand;
      -- otherwise more producers are the real fix (a newly connected mine starts at x0.60)
      local lowsvc
      if primary then
        local potential = 0
        for _, p in ipairs(r.producers) do potential = potential + p.rate / math.max(0.6, p.service) end
        if potential >= 0.95 * r.wanted then
          for _, p in ipairs(r.producers) do
            if p.service < 0.85 and (not lowsvc or p.service < lowsvc.service) then lowsvc = p end
          end
        end
      end
      local starved, bshort, busiest
      for _, p in ipairs(r.producers) do
        if p.starve and (not starved or p.starve > starved.starve) then starved = p end
        if p.bshort and (not bshort or p.bshort > bshort.bshort) then bshort = p end
        if p.busy and (not busiest or p.busy > busiest.busy) then busiest = p end
      end
      if #r.producers == 0 then
        r.cause = "none"
      elseif fullest then
        r.cause, r.from, r.why = "pickup", fullest.site, "full"
        r.from_full = fullest.full
      elseif lowsvc then
        r.cause, r.from, r.why = "pickup", lowsvc.site, "service"
        r.from_service = lowsvc.service
      elseif not primary and starved and starved.starve > C.CHAIN_SHORT then
        r.cause, r.from, r.cause_item = "upstream", starved.site, starved.main
      elseif not primary and bshort and bshort.bshort > C.CHAIN_SHORT then
        r.cause, r.from, r.cause_item = "upstream", bshort.site, bshort.booster
      elseif not primary and busiest and busiest.busy >= 0.85 then
        r.cause, r.from = "capacity", busiest.site
        r.from_busy = busiest.busy
      elseif r.made >= 0.95 * r.wanted then
        r.cause, r.why = "pickup", "carry"
      else
        r.cause = "production"
      end
    elseif fullest then
      r.status, r.from, r.from_full = "backed", fullest.site, fullest.full
      r.sev = fullest.full * 0.3
    elseif #r.consumers == 0 then
      r.status = #r.producers > 0 and "unused" or nil
    else
      r.status = #r.producers > 0 and "ok" or nil
    end
  end

  -- a few seconds of data say nothing yet (a single delivery reads as thousands per second)
  if window < 120 then
    for _, it in ipairs(CHAIN_ITEMS) do
      local r = rows[it]
      if r.status then r.status, r.cause, r.sev = "measuring", nil, 0 end
    end
  end

  -- next step: follow "held back by" to the root, then the root with the biggest effect
  local roots = {}
  for _, it in ipairs(CHAIN_ITEMS) do
    local r = rows[it]
    if r.status == "short" or r.status == "backed" then
      local cur, depth = r, 0
      while cur.cause == "upstream" and depth < 5 and rows[cur.cause_item] and rows[cur.cause_item].status == "short" do
        cur, depth = rows[cur.cause_item], depth + 1
      end
      roots[cur.item] = (roots[cur.item] or 0) + r.sev
    end
  end
  local best, bs
  for _, it in ipairs(CHAIN_ITEMS) do
    if roots[it] and (not bs or roots[it] > bs) then best, bs = it, roots[it] end
  end

  local nxt = { sites = {} }
  local function add_site(s) if s then table.insert(nxt.sites, s.id) end end
  if window < 120 then
    nxt.text = "Measuring: the supply chain needs a couple of minutes of play to average over."
  elseif not best then
    nxt.text = "Nothing is short right now: every mill, factory and power plant gets what it needs."
  else
    local r = rows[best]
    local L = item_label(best)
    if r.status == "backed" or (r.cause == "pickup" and r.why == "full") then
      nxt.text = site_title(r.from) .. "'s " .. L .. " pile keeps filling up (full " .. pct(r.from_full) ..
        " of the time): run more or bigger trains from it."
      add_site(r.from)
      if r.who then add_site(r.who) end
    elseif r.cause == "pickup" and r.why == "service" then
      nxt.text = site_title(r.from) .. " is picked up irregularly (" .. string.format("service x%.2f", r.from_service) ..
        "), so it makes less: a train should call there at least once a minute. " .. site_title(r.who) .. " is short of " .. L .. "."
      add_site(r.from); add_site(r.who)
    elseif r.cause == "pickup" then
      nxt.text = "Enough " .. L .. " is made (" .. fmt(r.made) .. "/s for " .. fmt(r.wanted) .. "/s), but " .. site_title(r.who) ..
        " still runs short: trains aren't carrying enough. Add trains or wagons on that route."
      add_site(r.who)
    else
      local pk = r.cause == "capacity" and r.from.kind or producer_kind(best)
      local sp, d = nearest_spare(pk, r.who, served)
      local head
      if r.cause == "capacity" then
        head = site_title(r.from) .. " runs flat out (busy " .. pct(r.from_busy) .. ") and " .. site_title(r.who) ..
          " still wants more " .. L .. ": connect another " .. kind_label(pk) .. "."
        add_site(r.from)
      elseif r.cause == "none" then
        head = site_title(r.who) .. " needs " .. L .. ", and no " .. kind_label(pk) .. " is connected."
      else
        head = site_title(r.who) .. " needs more " .. L .. ": your " .. kind_label(pk) .. "s make " .. fmt(r.made) ..
          "/s, and it could use " .. fmt(r.wanted) .. "/s."
      end
      add_site(r.who)
      if sp then
        nxt.text = head .. " Connect " .. site_title(sp) .. " (" .. fmt(d) .. " tiles from " .. r.who.name .. ")."
        add_site(sp)
      elseif chain_kind(served) == pk then
        nxt.text = head .. " No spare " .. kind_label(pk) .. " yet: a new one will be founded near your network soon."
      else
        nxt.text = head .. " No spare " .. kind_label(pk) .. " yet: one may be founded later."
      end
    end
  end

  return { rows = rows, towns = towns, next = nxt, window = window, spare = spare }
end

gui = require("scripts.gui")
gui.init(M)

-- remote interface for testing / other mods
remote.add_interface("freight_dispatch", {
  money = function() return storage.money end,
  add_money = function(n) storage.money = storage.money + n end,
  create_site = function(kind, x, y, pop) local s = create_site(kind, x, y, { pop = pop }); return s.id end,
  site = function(id) return storage.sites[id] end,
  sites = function() return storage.sites end,
  queue_ghost = function(g) table.insert(storage.ghost_queue, { ghost = g, tries = 0 }) end,
  buy_upgrade = function(id) M.buy_upgrade(nil, id); return storage.upgrades[id] end,
  site_detail = function(id) return storage.sites[id] and M.site_detail(storage.sites[id]) end,
  -- where shift+click in the GUI would teleport the character for this site
  safe_spot = function(id)
    local s = storage.sites[id]
    if not s then return nil end
    return gui.safe_spot(surface(), { s.x, s.y + C.KINDS[s.kind].radius * 0.6 }, 60)
  end,
  site_status = function(id) return storage.sites[id] and M.site_status(storage.sites[id]) end,
  set_input = function(id, item, amount) storage.sites[id].input[item] = amount end,
  get_input = function(id, item) return storage.sites[id].input[item] end,
  set_fuel = function(id, amount) storage.sites[id].fuel = amount end,
  -- test hook: every train's carriage colours, as "r,g,b" strings
  train_colors = function()
    local out = {}
    for _, t in pairs(game.train_manager.get_trains({ surface = game.surfaces[C.SURFACE] })) do
      local cs = {}
      for _, c in pairs(t.carriages) do
        local col = c.color
        table.insert(cs, c.type .. "=" .. (col and string.format("%.2f,%.2f,%.2f", col.r, col.g, col.b) or "nil"))
      end
      out[t.id] = table.concat(cs, " ")
    end
    return out
  end,
  set_stock = function(id, item, amount) storage.sites[id].stock[item] = amount end,
  -- test hook: put cargo in a wagon as if it had been loaded at site `origin_id`
  -- 0.9.0 test hooks: where a train can take passengers and mail, and the destination numbers
  train_dests = function(train)
    storage.dest_cache = storage.dest_cache or {}
    storage.dest_cache[train.id] = nil
    local out = {}
    for b, set in pairs(train_dests(train)) do
      local ids = {}
      for id in pairs(set) do table.insert(ids, id) end
      table.sort(ids)
      out[b] = ids
    end
    return out
  end,
  dest_sites = function() return storage.dest_sites end,
  inject_cargo = function(wagon, item, amount, origin_id)
    local n = wagon_insert(wagon.get_inventory(defines.inventory.cargo_wagon), item, amount)
    if n > 0 then add_loaded(wagon, item, n, storage.sites[origin_id]) end
    return n
  end,
  served = function()
    local n = 0
    for _ in pairs(served_ids()) do n = n + 1 end
    local kinds = {}
    for id, s in pairs(storage.sites) do
      local k = kinds[s.kind] or { served = 0, spare = 0 }
      if served_ids()[id] then k.served = k.served + 1 else k.spare = k.spare + 1 end
      kinds[s.kind] = k
    end
    local sv = served_ids()
    return { served = n, room = room_for_site(), kinds = kinds, chain = chain_kind(sv), power = power_kind(sv),
      town = town_kind(sv), uncovered = uncovered_served(sv), found_due = storage.found_due, next_town_tick = storage.next_town_tick }
  end,
  debug_dump = function()
    local out = {}
    for _, train in pairs(all_trains()) do
      local t = { id = train.id, state = train.state, wagons = {} }
      local st = train.station
      if st and st.valid then
        t.station = st.backer_name
        t.stop_pos = st.position
        t.links = {}
        for _, s in pairs(linked_sites(st)) do
          table.insert(t.links, { id = s.id, kind = s.kind, name = s.name, x = s.x, y = s.y })
        end
      end
      for _, w in pairs(train.cargo_wagons) do
        table.insert(t.wagons, { unit = w.unit_number, contents = w.get_inventory(defines.inventory.cargo_wagon).get_contents(),
          rec = storage.wagons[w.unit_number] })
      end
      table.insert(out, t)
    end
    local sites = {}
    for id, s in pairs(storage.sites) do
      if s.kind == "town" then table.insert(sites, { id = id, name = s.name, x = s.x, y = s.y, stock = s.stock }) end
    end
    for _, train in pairs(all_trains()) do
      local recs = {}
      local ok = pcall(function()
        local sch = train.get_schedule()
        for i = 1, sch.get_record_count() do
          local r = sch.get_record({ schedule_index = i })
          table.insert(recs, { station = r.station, temporary = r.temporary, wait = r.wait_conditions })
        end
      end)
      log("FDDUMP schedule train " .. train.id .. " ok=" .. tostring(ok) .. " " .. serpent.line(recs))
    end
    for _, stop in pairs(surface().find_entities_filtered({ type = "train-stop" })) do
      local links = {}
      for _, s in pairs(linked_sites(stop)) do table.insert(links, s.name .. "(" .. s.kind .. ")") end
      local nearest, nd = nil, 1e9
      for _, s in pairs(storage.sites) do
        local d = dist(stop.position.x, stop.position.y, s.x, s.y)
        if d < nd then nearest, nd = s, d end
      end
      log("FDDUMP stop '" .. stop.backer_name .. "' at " .. stop.position.x .. "," .. stop.position.y ..
        " links=" .. serpent.line(links) .. " nearest=" .. (nearest and (nearest.name .. " d=" .. math.floor(nd) .. " r=" .. site_radius(nearest)) or "none") ..
        " cache=" .. serpent.line(storage.stop_links[stop.unit_number]))
    end
    log("FDDUMP trains " .. serpent.block(out))
    log("FDDUMP towns " .. serpent.line(sites))
    log("FDDUMP contracts " .. serpent.line(storage.contracts))
    log("FDDUMP wagons-table-size " .. table_size(storage.wagons))
  end,
  contracts = function() return storage.contracts end,
  income_log = function() return storage.income_log or {} end,
  -- Spaceport (0.7.0) dev hooks
  spaceport = function()
    local s = M.spaceport()
    return { id = s and s.id, name = s and s.name, x = s and s.x, y = s and s.y, level = s and s.level, launches = s and s.launches,
      pad = s and s.pad, need = s and pad_need(s), rockets = storage.rockets or 0, sat = sat_mult(), wanted = storage.pad_wanted,
      reserve = pad_reserve(), paused = storage.pad_paused, money = storage.money,
      status = s and M.site_status(s), detail = s and M.site_detail(s), signals = s and M.site_signals(s) }
  end,
  set_pad = function(t, id) local s = id and storage.sites[id] or M.spaceport(); for k, v in pairs(t) do pad_state(s)[k] = v end end,
  spaceports = function()
    local out = {}
    for _, s in pairs(M.spaceports()) do
      table.insert(out, { id = s.id, name = s.name, x = s.x, y = s.y, level = s.level, launches = s.launches, status = M.site_status(s), detail = M.site_detail(s) })
    end
    return { pads = out, bought = storage.pads_bought or 0, pending = storage.pads_pending or 0, price = M.pad_price(), rockets = storage.rockets or 0, sat = sat_mult() }
  end,
  buy_pad = function() return M.buy_pad(nil) end,
  set_pad_reserve = function(i) storage.pad_reserve = i end,
  eyes = function() return M.place_all_eyes() end,
  -- Supply chain analysis as plain data (dev hook)
  chain = function()
    local ch = M.supply_chain()
    local rows = {}
    local function nm(s) return s and s.name or nil end
    for it, r in pairs(ch.rows) do
      local prods, cons = {}, {}
      for _, p in ipairs(r.producers) do
        table.insert(prods, string.format("%s %.1f/s busy=%s starve=%s full=%.2f svc=%s", p.site.name, p.rate,
          tostring(p.busy and string.format("%.2f", p.busy)), tostring(p.starve and string.format("%.2f", p.starve)),
          p.full, tostring(p.service and string.format("%.2f", p.service))))
      end
      for _, c in ipairs(r.consumers) do
        table.insert(cons, string.format("%s %s want=%.1f got=%.1f short=%.2f", c.site.name, c.role, c.wanted, c.got, c.short))
      end
      rows[it] = { status = r.status, cause = r.cause, why = r.why, cause_item = r.cause_item, made = r.made, got = r.got,
        wanted = r.wanted, who = nm(r.who), from = nm(r.from), sev = r.sev, producers = prods, consumers = cons }
    end
    return { next = ch.next.text, rows = rows, window = ch.window, towns = { n = ch.towns.n, growing = #ch.towns.growing,
      full = #ch.towns.full, pax = ch.towns.pax, mail = ch.towns.mail } }
  end,
  stats = function()
    return { money = storage.money, lifetime = storage.lifetime, sites = table_size(storage.sites),
      contracts = #storage.contracts, deliveries = storage.deliveries or 0, fuel_spent = storage.fuel_spent or 0,
      earned_item = storage.earned_item or {}, upgrades = storage.upgrades,
      rank = M.rank(), rank_title = C.RANKS[M.rank()].title, rockets = storage.rockets or 0 }
  end,
})
