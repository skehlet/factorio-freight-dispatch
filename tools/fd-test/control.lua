-- Headless test harness for Freight Dispatch. NOT for players.
-- On a fresh map it builds a 440-tile straight line at y=1000 between two big towns,
-- a 4-car train (loco, 2 wagons, reversed loco) shuttling with "Full OR 30 s" at both
-- stops, plus a rail-signal ghost queued for instant build. Every 10 s it logs
-- "FDTEST t=..." lines: money, lifetime earnings, deliveries, train state and cargo.
-- Healthy run: money rises about $20k+ per trip, both directions, and ghostvalid=false.
local Y = 1000

local function L(...) log("FDTEST " .. table.concat({ ... }, " ")) end

local function build()
  local surf = game.surfaces["freight"]
  surf.request_to_generate_chunks({ 180, Y }, 8)
  surf.force_generate_chunk_requests()
  local tiles = {}
  for x = -80, 440 do
    for y = Y - 40, Y + 40 do
      table.insert(tiles, { name = "grass-1", position = { x, y } })
    end
  end
  surf.set_tiles(tiles)
  for _, e in pairs(surf.find_entities_filtered({ area = { { -80, Y - 40 }, { 440, Y + 40 } } })) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  -- towns centred ON the line: the track runs down each town's street corridor
  local a = remote.call("freight_dispatch", "create_site", "town", 0, Y, 3000)
  local b = remote.call("freight_dispatch", "create_site", "town", 360, Y, 3000)
  L("sites", a, b)
  for _, id in pairs({ a, b }) do
    local s = remote.call("freight_dispatch", "site", id)
    if s then L("town", id, "buildings=" .. tostring(s.building_count), "radius=" .. tostring(s.radius)) end
  end

  -- 2.x straight rails: 2x2, created at even x snap to odd centres (first one lands at -39,1001)
  local count = 0
  for x = -40, 400, 2 do
    if surf.create_entity({ name = "straight-rail", position = { x, Y }, direction = defines.direction.east, force = "player" }) then
      count = count + 1
    end
  end
  L("rails", count)

  -- try offsets until the stop actually connects to the rail
  local function try_stop(cx, cy, dir, label)
    for _, off in pairs({ { 0, 2 }, { 0, -2 }, { 1, 2 }, { 1, -2 }, { -1, 2 }, { -1, -2 } }) do
      local s = surf.create_entity({ name = "train-stop", position = { cx + off[1], cy + off[2] }, direction = dir, force = "player", raise_built = true })
      if s then
        if s.connected_rail then
          L("stop", label, s.backer_name, s.position.x, s.position.y)
          return s
        end
        s.destroy()
      end
    end
    L("stop FAILED", label)
  end
  local sb = try_stop(350, Y, defines.direction.east, "B")
  local sa = try_stop(10, Y, defines.direction.west, "A")

  local l1 = surf.create_entity({ name = "locomotive", position = { 300, Y }, direction = defines.direction.east, force = "player" })
  surf.create_entity({ name = "cargo-wagon", position = { 293, Y }, direction = defines.direction.east, force = "player" })
  surf.create_entity({ name = "cargo-wagon", position = { 286, Y }, direction = defines.direction.east, force = "player" })
  surf.create_entity({ name = "locomotive", position = { 279, Y }, direction = defines.direction.west, force = "player" })
  local train = l1 and l1.train
  if not train then L("no train"); return end
  L("train carriages", #train.carriages)
  local recs = {}
  for _, s in pairs({ sb, sa }) do
    if s then
      table.insert(recs, { station = s.backer_name, wait_conditions = {
        { type = "full", compare_type = "or" }, { type = "time", compare_type = "or", ticks = 1800 } } })
    end
  end
  local ok = pcall(function() train.schedule = { current = 1, records = recs } end)
  if not ok then
    local sch = train.get_schedule()
    for _, r in pairs(recs) do sch.add_record(r) end
  end
  train.manual_mode = false
  storage.train = train

  -- ghost test: ghosts must be at a VALID position or revive() silently fails
  local g
  for _, yy in pairs({ Y + 2.5, Y - 0.5, Y + 3.5, Y - 1.5 }) do
    for _, d in pairs({ defines.direction.east, defines.direction.west }) do
      if not g and surf.can_place_entity({ name = "rail-signal", position = { 150.5, yy }, direction = d, force = "player" }) then
        g = surf.create_entity({ name = "entity-ghost", inner_name = "rail-signal", position = { 150.5, yy }, direction = d, force = "player" })
      end
    end
  end
  L("ghost", tostring(g ~= nil))
  if g then remote.call("freight_dispatch", "queue_ghost", g); storage.ghost = g end
end

-- top speed tracking (tiles/tick), to verify the fuel upgrade
script.on_event(defines.events.on_tick, function()
  local t = storage.train
  if t and t.valid then storage.vmax = math.max(storage.vmax or 0, math.abs(t.speed)) end
end)

local function upgrade_test()
  remote.call("freight_dispatch", "add_money", 200000000)
  for _, id in pairs({ "fuel", "wagons", "loading", "running" }) do
    for _ = 1, 3 do remote.call("freight_dispatch", "buy_upgrade", id) end
  end
  L("upgrades bought, vmax before=" .. string.format("%.3f", storage.vmax or 0) ..
    " running_mod=" .. game.forces.player.character_running_speed_modifier)
  storage.vmax = 0
  -- industries: steel mill with ore + quarter coal (x1.5), factory with steel only (x1), then full lumber
  local surf = game.surfaces["freight"]
  local m = remote.call("freight_dispatch", "create_site", "steel-mill", 200, Y + 300)
  local f = remote.call("freight_dispatch", "create_site", "factory", 400, Y + 300)
  remote.call("freight_dispatch", "set_input", m, "fd-iron-ore", 5000)
  remote.call("freight_dispatch", "set_input", m, "fd-coal", 1250)
  remote.call("freight_dispatch", "set_input", f, "fd-steel", 5000)
  storage.mill, storage.factory = m, f
end

script.on_nth_tick(600, function(e)
  if not storage.built then
    storage.built = true
    build()
    return
  end
  if e.tick == 6000 then upgrade_test() end
  if storage.mill and e.tick >= 6600 then
    if e.tick == 7200 then remote.call("freight_dispatch", "set_input", storage.factory, "fd-wood", 5000) end
    L("mill: " .. tostring(remote.call("freight_dispatch", "site_detail", storage.mill)))
    L("factory: " .. tostring(remote.call("freight_dispatch", "site_detail", storage.factory)))
    L("town: " .. tostring(remote.call("freight_dispatch", "site_detail", 5)))
    local t = storage.train
    if t and t.valid then
      local w = t.cargo_wagons[1]
      local fuel = t.locomotives.front_movers[1].get_fuel_inventory().get_contents()
      L("wagon slots=" .. #w.get_inventory(defines.inventory.cargo_wagon) .. " fuel=" .. serpent.line(fuel) ..
        " vmax=" .. string.format("%.3f", storage.vmax or 0))
    end
    L("served=" .. serpent.line(remote.call("freight_dispatch", "served")))
  end
  local st = remote.call("freight_dispatch", "stats")
  local t = storage.train
  local tinfo = "invalid"
  if t and t.valid then
    local fuel = t.locomotives.front_movers[1] and t.locomotives.front_movers[1].get_fuel_inventory().get_item_count("solid-fuel")
    tinfo = "state=" .. t.state .. " x=" .. math.floor(t.front_stock.position.x) .. " fuel=" .. tostring(fuel) ..
      " cargo=" .. serpent.line(t.get_contents())
  end
  L("t=" .. e.tick, "money=" .. math.floor(st.money), "life=" .. math.floor(st.lifetime), "sites=" .. st.sites,
    "contracts=" .. st.contracts, "deliv=" .. st.deliveries, "fuel$=" .. st.fuel_spent, tinfo,
    "ghostvalid=" .. tostring(storage.ghost and storage.ghost.valid))
end)
