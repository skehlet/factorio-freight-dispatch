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

-- Goods a town needs per new resident; rises with population so big cities take many goods.
-- A powered town grows 25% more per good.
function M.goods_per_resident(site)
  return C.GOODS_PER_RESIDENT * math.max(1, site.pop / 1000) / power_mult(site)
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

local function land_ok(surf, x, y, r)
  local names = get_water_names()
  if #names > 0 and surf.count_tiles_filtered({ area = box(x, y, r), name = names }) > 0 then
    return false
  end
  if surf.count_entities_filtered({ area = box(x, y, r), force = C.FORCE, limit = 1 }) > 0 then
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
          and surf.count_entities_filtered({ area = box(x, y, 2.5), force = "player", limit = 1 }) == 0 then
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
  if site.kind == "town" then return site.name end
  return site.name .. " " .. kind.label
end
M.site_title = site_title

local function cargo_list_str(items)
  local parts = {}
  for _, it in pairs(items) do table.insert(parts, "[item=" .. it .. "]") end
  return table.concat(parts, " ")
end

local function supply_radius(site)
  return C.POWER.radius + C.POWER.radius_per_level * (site.level - 1)
end
M.supply_radius = supply_radius

local function plant_running(site)
  return (site.fuel or 0) > 0
end

local function fuel_minutes(site)
  return (site.fuel or 0) / C.POWER.burn / 60
end

function M.site_status(site)
  local kind = C.KINDS[site.kind]
  local parts = {}
  if site.kind == "town" then
    table.insert(parts, "Pop: " .. fmt(site.pop))
  else
    table.insert(parts, "Level " .. site.level)
  end
  if #kind.produces > 0 then
    local waiting = {}
    for _, it in pairs(kind.produces) do
      -- whole units only: trains load whole units, and a leftover fraction (e.g. 0.6) would
      -- otherwise round up to a phantom "1" while a train is loading
      table.insert(waiting, "[item=" .. it .. "] " .. fmt(math.floor(site.stock[it] or 0)))
    end
    table.insert(parts, "Waiting for pickup: " .. table.concat(waiting, ", "))
  end
  if site.kind == "power-plant" then
    table.insert(parts, plant_running(site) and string.format("Fuel: %d min", math.ceil(fuel_minutes(site)))
      or "[color=#ff9070]Out of fuel[/color]")
  end
  if #kind.accepts > 0 then
    table.insert(parts, "Wants: " .. cargo_list_str(kind.accepts))
  end
  return table.concat(parts, "  |  ")
end

-- What an industry's level means, and how far it is from the next one.
local function level_note(site)
  local kind = C.KINDS[site.kind]
  local need = C.LEVEL_AT[site.level]
  local nxt = need and ("Next level at " .. fmt(need) .. " shipped (" .. fmt(site.shipped) .. " so far).")
    or "Top level."
  if kind.base then
    local item, base = next(kind.base)
    local mult = 1 + C.LEVEL_BONUS * (site.level - 1)
    local service = 0.6 + 0.4 * site.rating
    local s = string.format("Level %d: output x%d. ", site.level, mult)
    service = service * power_mult(site)
    if (site.stock[item] or 0) >= C.STOCK_CAP * site.level - 1 then
      s = s .. "Stockpile full (" .. fmt(C.STOCK_CAP * site.level) .. "): production waits for a pickup"
    else
      s = s .. string.format("Making %.1f [item=%s]/s", base * mult * service, item)
      local svc = 0.6 + 0.4 * site.rating
      if svc < 0.99 then
        s = s .. string.format(" (x%.2f until trains pick up every minute)", svc)
      end
    end
    return s .. ". " .. nxt
  elseif kind.main then
    return string.format("Level %d: processes up to %s [item=%s]/s. ", site.level,
      fmt(C.PROCESS_RATE * site.level * power_mult(site)), kind.main) .. nxt
  end
end

-- Second status line: what drives this site (town growth by source, industry boost, level).
local site_detail_core
local function plant_detail(site)
  local r = fmt(supply_radius(site))
  local s
  if plant_running(site) then
    s = string.format("Running: %d min of fuel. Powering %d site%s within %s tiles (+%d%%). ",
      math.ceil(fuel_minutes(site)), site.powering or 0, site.powering == 1 and "" or "s", r, C.POWER.bonus * 100)
  else
    s = "Out of fuel. Deliver [item=fd-coal] Coal or [item=fd-wood] Lumber to power sites within " .. r ..
      " tiles (+" .. (C.POWER.bonus * 100) .. "%). "
  end
  s = s .. "Burns " .. C.POWER.burn .. " [item=fd-coal]/s (lumber counts half), holds " ..
    fmt(C.POWER.cap / C.POWER.burn / 60) .. " min. "
  local need = C.LEVEL_AT[site.level]
  s = s .. "Level " .. site.level .. ": supply radius " .. r .. ". "
  if need then
    s = s .. "Next level at " .. fmt(need) .. " fuel burnt (" .. fmt(site.burnt or 0) .. " so far)."
  else
    s = s .. "Top level."
  end
  return s
end

local function powered_note(site)
  local p = site.powered_by and storage.sites[site.powered_by]
  if not p then return nil end
  return "Powered by " .. site_title(p) .. ": +" .. (C.POWER.bonus * 100) .. "%."
end

function M.site_detail(site)
  if site.kind == "power-plant" then return plant_detail(site) end
  local core = site_detail_core(site)
  local pw = powered_note(site)
  local lvl = site.kind ~= "town" and #C.KINDS[site.kind].produces > 0 and level_note(site) or nil
  local out
  for _, part in pairs({ core, lvl, pw }) do
    if part then
      if out then out = out .. (out:sub(-1) == "." and " " or ". ") .. part else out = part end
    end
  end
  return out
end

site_detail_core = function(site)
  local kind = C.KINDS[site.kind]
  if site.kind == "town" then
    local per = "Each new resident needs " .. fmt(M.goods_per_resident(site)) .. " [item=fd-goods]"
    local gained = site.growth and site.growth["fd-goods"] or 0
    if gained < 0.5 then
      return "Stable. Deliver [item=fd-goods] Goods to grow. " .. per .. "."
    end
    return "Growing +" .. fmt(gained) .. "/min (" .. string.format("%.1f", gained / math.max(1, site.pop) * 100) ..
      "%) from [item=fd-goods] Goods. " .. per .. "."
  elseif kind.main then
    local main_l, boost_l = C.CARGO[kind.main].label, C.CARGO[kind.booster].label
    local main_i, boost_i = "[item=" .. kind.main .. "]", "[item=" .. kind.booster .. "]"
    local top = kind.full_yield / kind.base_yield
    local stock = "Stockpile: " .. main_i .. " " .. fmt(site.input[kind.main] or 0) .. ", " ..
      boost_i .. " " .. fmt(site.input[kind.booster] or 0)
    if site.input_full_tick and game.tick - site.input_full_tick < 180 then
      stock = stock .. " (full: trains wait to unload)"
    end
    if site.output_full then
      local out_i = "[item=" .. kind.produces[1] .. "]"
      return "Paused: output full (" .. out_i .. " " .. fmt(site.stock[kind.produces[1]] or 0) ..
        "). Ship it out to restart. " .. stock
    end
    if not site.made_tick or game.tick - site.made_tick > 120 then
      return "Idle: needs " .. main_i .. " " .. main_l .. " (" .. boost_i .. " " .. boost_l ..
        " only boosts it, up to x" .. top .. "). " .. stock
    end
    local mult = (kind.base_yield + (kind.full_yield - kind.base_yield) * (site.boost or 0)) / kind.base_yield
    local made = string.format("Making %.1f [item=%s]/s. ", site.made or 0, kind.produces[1])
    if (site.boost or 0) >= 0.99 then
      return string.format("Output x%.1f, fully boosted by ", mult) .. boost_i .. " " .. boost_l .. ". " .. made .. stock
    end
    return string.format("Output x%.1f. Deliver ", mult) .. boost_i .. " " .. boost_l ..
      " for up to x" .. top .. ". " .. made .. stock
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

-- Power plant supply area: a faint circle on the ground and on the map, dimmed when dry
local function update_supply_circle(site)
  if site.kind ~= "power-plant" or not site.render then return end
  local on = plant_running(site)
  local a = on and 0.45 or 0.12
  local col = { 0.9 * a, 0.5 * a, 0.9 * a, a }
  for _, key in pairs({ "supply", "supply_map" }) do
    local o = site.render[key]
    if not (o and o.valid) then
      o = rendering.draw_circle({
        color = col, radius = supply_radius(site), width = key == "supply" and 4 or 2, filled = false,
        target = { site.x, site.y }, surface = surface(), draw_on_ground = true,
        render_mode = key == "supply" and "game" or "chart",
      })
      site.render[key] = o
    end
    o.radius = supply_radius(site)
    o.color = col
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

-- What to found next: a kind missing from the whole map if there is one, otherwise a weighted
-- pick that avoids kinds already waiting unserved (so the spare sites stay varied).
local function pick_found_kind(served)
  local all, spare = {}, {}
  for id, s in pairs(storage.sites) do
    all[s.kind] = (all[s.kind] or 0) + 1
    if not served[id] then spare[s.kind] = (spare[s.kind] or 0) + 1 end
  end
  local weights, total = {}, 0
  local missing = false
  for _, kind in pairs(C.KIND_ORDER) do
    if not all[kind] then missing = true end
  end
  for _, kind in pairs(C.KIND_ORDER) do
    local w
    if missing then
      w = all[kind] and 0 or C.KIND_WEIGHTS[kind]
    else
      local n = spare[kind] or 0
      w = C.KIND_WEIGHTS[kind] / ((1 + n) * (1 + n))
    end
    weights[kind] = w
    total = total + w
  end
  local r = rand() * total
  for _, kind in pairs(C.KIND_ORDER) do
    r = r - weights[kind]
    if r <= 0 and weights[kind] > 0 then return kind end
  end
  return "town"
end

-- Found one new site on purpose: FOUND_MIN..FOUND_MAX tiles from a random served site (or
-- spawn), on generated dry land that keeps the spacing rules. Land that isn't generated yet
-- is requested and tried again on a later call.
local function found_site()
  local surf = surface()
  local served = served_ids()
  local anchors = {}
  for id in pairs(served) do
    local s = storage.sites[id]
    if s then table.insert(anchors, s) end
  end
  table.sort(anchors, function(p, q) return p.id < q.id end) -- pairs order isn't stable
  if #anchors == 0 then anchors = { { x = 0, y = 0 } } end
  local kind = storage.found_kind or pick_found_kind(served)
  storage.found_kind = kind
  -- a power plant goes where it would cover the most sites no plant covers yet (fuelled or
  -- not; your served ones count double), so there's usually a good one to connect. Anything
  -- else takes the first good spot.
  local plants = {}
  for _, s in pairs(storage.sites) do
    if s.kind == "power-plant" then table.insert(plants, s) end
  end
  local function covered(s)
    for _, p in pairs(plants) do
      if dist(s.x, s.y, p.x, p.y) <= supply_radius(p) then return true end
    end
    return false
  end
  local function score(x, y)
    local n = 0
    for id, s in pairs(storage.sites) do
      if s.kind ~= "power-plant" and dist(x, y, s.x, s.y) <= C.POWER.radius and not covered(s) then
        n = n + (served[id] and 2 or 1)
      end
    end
    return n
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
        local sc = kind == "power-plant" and score(x, y) or 0
        if not bs or sc > bs then bx, by, bs = x, y, sc end
        if kind ~= "power-plant" then break end
      end
    end
  end
  if not bx then return nil end
  local x, y = bx, by
  storage.found_kind = nil
  local site = create_site(kind, x, y)
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
  if game.tick < (storage.next_found_tick or 0) then return end
  if not room_for_site() then return end
  if found_site() then storage.next_found_tick = game.tick + C.FOUND_GAP end
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
      table.insert(list, { value = { type = type, name = name, quality = type == "item" and "normal" or nil }, min = math.min(v, 2000000000) })
    end
  end
  local kind = C.KINDS[s.kind]
  for _, it in pairs(kind.produces) do add("item", it, s.stock[it]) end
  if kind.secondary then
    for _, it in pairs(kind.accepts) do add("item", it, s.input[it]) end
  end
  if s.kind == "town" then add("virtual", "signal-P", s.pop) else add("virtual", "signal-L", s.level) end
  if s.kind == "power-plant" then add("virtual", "signal-F", s.fuel) end
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
  for i, s in pairs(sites) do
    if i <= 2 then table.insert(names, site_title(s)) end
  end
  stop.backer_name = table.concat(names, " & ")
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
  local kind = C.KINDS[site.kind]
  if kind.secondary then
    site.input[item] = math.min(C.INPUT_CAP, (site.input[item] or 0) + amount)
  elseif site.kind == "power-plant" then
    site.fuel = math.min(C.POWER.cap, (site.fuel or 0) + amount * (C.POWER.fuel[item] or 0))
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

local function service_train(train)
  local stop = train.station
  if not (stop and stop.valid) then return end
  local sites = linked_sites(stop)
  if #sites == 0 then return end
  local dropoff = is_dropoff(train)
  local paid = 0
  local loaded = 0
  for _, wagon in pairs(train.cargo_wagons) do
    local inv = wagon.get_inventory(defines.inventory.cargo_wagon)
    if inv then
      local budget = load_rate()
      local rec = storage.wagons[wagon.unit_number] or {}
      -- unload (instant, no rate limit): every lot that has travelled far enough comes off
      -- and is paid, as far as the site has room (mills and factories: input pile). Lots still
      -- near their origin stay aboard. Untracked cargo (more in the wagon than we have records
      -- for) gets off for free.
      for _, site in pairs(sites) do
        for _, item in pairs(C.KINDS[site.kind].accepts) do
          local have = inv.get_item_count(item)
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
              room = math.max(0, math.floor(C.INPUT_CAP - (site.input[item] or 0)))
            elseif site.kind == "power-plant" then
              room = math.max(0, math.floor((C.POWER.cap - (site.fuel or 0)) / C.POWER.fuel[item] + 0.001))
            end
            for _, lot in ipairs(lots) do
              if dist(lot.ox, lot.oy, site.x, site.y) >= C.MIN_DIST and avail > 0 and room > 0 then
                local take = math.min(math.floor(lot.amount + 0.001), avail, room)
                room = room - take
                if take > 0 then
                  paid = paid + payment(lot, site, item, take)
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
              if deliver > 0 then on_delivered(site, item, deliver) end
            end
            if inv.get_item_count(item) == 0 then
              rec[item] = nil
            else
              rec[item] = keep
            end
          end
        end
      end
      -- drop-off stop: cargo that never left home goes back to its site, and nothing loads
      if dropoff then
        for _, site in pairs(sites) do
          for _, item in pairs(C.KINDS[site.kind].produces) do
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
                site.stock[item] = (site.stock[item] or 0) + back
              end
              if inv.get_item_count(item) == 0 then rec[item] = nil else rec[item] = keep end
            end
          end
        end
      end
      -- load: share this second's capacity evenly between every cargo type waiting here
      -- (so plentiful passengers can't crowd out mail); leftover share goes to the others
      local offers = {}
      for _, site in pairs(dropoff and {} or sites) do
        for _, item in pairs(C.KINDS[site.kind].produces) do
          local s = math.floor(site.stock[item] or 0)
          if s > 0 then table.insert(offers, { site = site, item = item, avail = s }) end
        end
      end
      for _ = 1, 4 do
        if budget <= 0 or #offers == 0 then break end
        local share = math.max(1, math.floor(budget / #offers))
        local still = {}
        for _, o in ipairs(offers) do
          local want = math.min(o.avail, share, budget)
          local ins = want > 0 and inv.insert({ name = o.item, count = want }) or 0
          if ins > 0 then
            local site = o.site
            site.stock[o.item] = site.stock[o.item] - ins
            site.shipped = site.shipped + ins
            site.picked_min = site.picked_min + ins
            budget = budget - ins
            loaded = loaded + ins
            o.avail = o.avail - ins
            add_loaded(wagon, o.item, ins, site)
          end
          -- keep offering only if it took everything we asked for and more is waiting
          if ins == want and o.avail > 0 then table.insert(still, o) end
        end
        offers = still
      end
    end
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
  if site.kind == "town" then return end
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

local function simulate_second()
  update_power()
  for _, site in pairs(storage.sites) do
    local kind = C.KINDS[site.kind]
    local service = (0.6 + 0.4 * site.rating) * power_mult(site)
    local cap = C.STOCK_CAP * site.level
    if site.kind == "town" then
      local pax = site.pop / 60 * service
      local mail = site.pop / 400 * service
      cap = C.STOCK_CAP + site.pop * 4
      site.stock["fd-passengers"] = math.min(cap, (site.stock["fd-passengers"] or 0) + pax)
      site.stock["fd-mail"] = math.min(cap / 4, (site.stock["fd-mail"] or 0) + mail)
    elseif kind.base then
      local mult = (1 + C.LEVEL_BONUS * (site.level - 1)) * service
      for item, rate in pairs(kind.base) do
        site.stock[item] = math.min(cap, (site.stock[item] or 0) + rate * mult)
      end
    elseif kind.main then
      -- steel mill (ore, boosted by coal) and factory (steel, boosted by lumber):
      -- the booster alone makes nothing; it raises the yield of the main input.
      local main = site.input[kind.main] or 0
      local p = math.min(main, C.PROCESS_RATE * site.level * power_mult(site))
      local item = kind.produces[1]
      local room = cap - (site.stock[item] or 0)
      site.output_full = p > 0 and room < 1
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
        site.made_tick = game.tick
      end
    end
  end
end

local function simulate_minute()
  for _, site in pairs(storage.sites) do
    local served = site.picked_min > 0 and 1 or 0
    site.rating = site.rating * 0.75 + 0.25 * served
    site.picked_min = 0
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

-- Wagon capacity upgrade: every cargo wagon's inventory is resized (never shrunk).
local function apply_wagon_capacity()
  local slots = upgrade_tier("wagons").slots
  for _, train in pairs(all_trains()) do
    if train.valid then
      for _, w in pairs(train.cargo_wagons) do
        local cur = w.get_inventory_size_override(defines.inventory.cargo_wagon)
        if (cur or 0) < slots and #w.get_inventory(defines.inventory.cargo_wagon) < slots then
          w.set_inventory_size_override(defines.inventory.cargo_wagon, slots)
        end
      end
    end
  end
end

function M.buy_upgrade(player, id)
  local u = upgrade_def(id)
  if not u then return end
  local _, level = upgrade_tier(id)
  local nxt = u.tiers[level + 1]
  if not nxt then return end
  if not spend(nxt.price) then
    (player or game).print("[color=red]Not enough money for " .. nxt.name .. " (" .. M.money_str(nxt.price) .. ").[/color]")
    return
  end
  storage.upgrades[id] = level + 1
  refuel_trains()
  apply_wagon_capacity()
  apply_running_speed()
  game.print("[color=green][font=default-bold]Upgrade bought:[/font][/color] " .. u.label .. " -> [color=yellow]" ..
    nxt.name .. "[/color]. " .. nxt.desc .. (id == "running" and "." or ", for every train."))
end

-- Cargo outside a wagon (in a player's inventory, or in a removed wagon) goes back to the
-- nearest site that produces it, so it rejoins that site's waiting stock.
local function return_cargo(item, count, x, y)
  local best, bd = nil, math.huge
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
    if s then
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
      for _, item in pairs(C.KINDS[s.kind].accepts) do
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
  -- bonus = what the cargo would earn over 1,200 tiles (freight) or 600 tiles (town cargo),
  -- rounded to $100. Freight: double the amount and double the rate (0.3.0).
  local reward = math.floor(amount * C.CARGO[c.item].rate * (freight and 12 or 6) / 100) * 100
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

function M.rank()
  local idx = 1
  for i, r in ipairs(C.RANKS) do
    if storage.lifetime >= r.at then idx = i end
  end
  return idx
end

local function check_rank()
  local r = M.rank()
  if r > (storage.rank or 1) then
    storage.rank = r
    local rk = C.RANKS[r]
    game.print("[color=yellow][font=default-large-bold]Promotion! You are now: " .. rk.title .. "[/font][/color]")
    if r == #C.RANKS then
      game.print("[color=green][font=default-large-bold]You built a railway empire. You win! (Keep playing if you like.)[/font][/color]")
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
  if remote.interfaces["freeplay"] then
    local fp = remote.interfaces["freeplay"]
    if fp["set_disable_crashsite"] then remote.call("freeplay", "set_disable_crashsite", true) end
    if fp["set_skip_intro"] then remote.call("freeplay", "set_skip_intro", true) end
    if fp["set_created_items"] then remote.call("freeplay", "set_created_items", {}) end
    if fp["set_respawn_items"] then remote.call("freeplay", "set_respawn_items", {}) end
  end
  local surf = make_surface()
  storage.seed = (surf.map_gen_settings.seed % 2147483647) + 1
  surf.request_to_generate_chunks({ 0, 0 }, 18) -- starters reach about 400 tiles out
  surf.force_generate_chunk_requests()
  place_starters()
  pcall(function() game.map_settings.pollution.enabled = false end)
  pcall(function() game.map_settings.enemy_expansion.enabled = false end)
  setup_force()
  for _, p in pairs(game.players) do setup_player(p) end
end)

script.on_configuration_changed(function()
  if storage.disabled then return end
  init_storage()
  unlock_techs()
  if game.surfaces[C.SURFACE] then
    relayout_towns()
    -- paint any train still in default red (all trains in saves from before 0.3.5)
    for _, t in pairs(game.train_manager.get_trains({ surface = game.surfaces[C.SURFACE] })) do paint_train(t) end
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
    for _, s in pairs(storage.sites) do update_site_render(s) end
  end
  if e.tick % 600 == 0 then
    check_stuck()
    update_contracts()
    check_rank()
  end
  if e.tick % 3600 == 0 then simulate_minute() end
  for _, p in pairs(game.connected_players) do gui.update(p) end
end)

function M.income_per_min()
  local t = 0
  for _, v in pairs(storage.income_hist) do t = t + v end
  return t * 60 / math.max(1, #storage.income_hist)
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
  inject_cargo = function(wagon, item, amount, origin_id)
    local n = wagon.get_inventory(defines.inventory.cargo_wagon).insert({ name = item, count = amount })
    if n > 0 then add_loaded(wagon, item, n, storage.sites[origin_id]) end
    return n
  end,
  served = function()
    local n = 0
    for _ in pairs(served_ids()) do n = n + 1 end
    return { served = n, room = room_for_site() }
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
  stats = function()
    return { money = storage.money, lifetime = storage.lifetime, sites = table_size(storage.sites),
      contracts = #storage.contracts, deliveries = storage.deliveries or 0, fuel_spent = storage.fuel_spent or 0 }
  end,
})
