-- Headless test harness for Freight Dispatch. NOT for players.
-- On a fresh map it builds a 440-tile straight line at y=1000 between two big towns,
-- a 4-car train (loco, 2 wagons, reversed loco) shuttling with "Full OR 30 s" at both
-- stops, plus a rail-signal ghost queued for instant build. Every 10 s it logs
-- "FDTEST t=..." lines: money, lifetime earnings, deliveries, train state and cargo.
-- Healthy run: money rises about $20k+ per trip, both directions, and ghostvalid=false.
local Y = 1000

local function L(...) log("FDTEST " .. table.concat({ ... }, " ")) end
local dest_check

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
  storage.town_a = a
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

  -- Site signals: a box beside stop A (town a), wired red to the stop and to a rail signal
  if sa then
    local bp = surf.find_non_colliding_position("fd-site-signals", { sa.position.x + 3, sa.position.y + 3 }, 6, 0.5)
    local box = bp and surf.create_entity({ name = "fd-site-signals", position = bp, force = "player", raise_built = true })
    local sig
    for _, yy in pairs({ Y + 2.5, Y - 0.5, Y + 3.5, Y - 1.5 }) do
      for _, d in pairs({ defines.direction.east, defines.direction.west }) do
        if not sig and surf.can_place_entity({ name = "rail-signal", position = { sa.position.x + 6.5, yy }, direction = d, force = "player" }) then
          sig = surf.create_entity({ name = "rail-signal", position = { sa.position.x + 6.5, yy }, direction = d, force = "player" })
        end
      end
    end
    L("box", tostring(box and box.position.x), tostring(box and box.position.y), "sig", tostring(sig ~= nil))
    if box then
      local red = box.get_wire_connector(defines.wire_connector_id.circuit_red, true)
      L("wire stop", tostring(red.connect_to(sa.get_wire_connector(defines.wire_connector_id.circuit_red, true))))
      local cb = sa.get_or_create_control_behavior()
      cb.circuit_enable_disable = true
      cb.circuit_condition = { first_signal = { type = "item", name = "fd-passengers" }, comparator = ">", constant = 1 }
      if sig then
        L("wire sig", tostring(red.connect_to(sig.get_wire_connector(defines.wire_connector_id.circuit_red, true))))
        local scb = sig.get_or_create_control_behavior()
        scb.close_signal = true
        scb.circuit_condition = { first_signal = { type = "item", name = "fd-passengers" }, comparator = ">", constant = 1000000000 }
      end
      storage.box, storage.sa, storage.sig = box, sa, sig
    end
  end
end

-- flip the circuit conditions and log what the stop and signal do
local function circuit_check(tick)
  local box, sa, sig = storage.box, storage.sa, storage.sig
  if not (box and box.valid) then return end
  local cb = box.get_control_behavior()
  local sec = cb and cb.get_section(1)
  L("box signals=" .. serpent.line(sec and sec.filters))
  local scb = sa.get_control_behavior()
  local sigstate = sig and sig.valid and sig.signal_state
  L("stop cond=" .. scb.circuit_condition.constant .. " disabled=" .. tostring(scb.disabled) ..
    " | sig close_cond=" .. (sig and sig.get_control_behavior().circuit_condition.constant or -1) ..
    " state=" .. tostring(sigstate) .. " (open=" .. defines.signal_state.open .. " closed=" .. defines.signal_state.closed .. ")")
  -- powerless decider: box -> decider input (red); read the decider's green output
  if tick == 1200 then
    local surf = box.surface
    local dp = surf.find_non_colliding_position("fd-decider", { box.position.x + 2, box.position.y + 2 }, 6, 0.5)
    local d = dp and surf.create_entity({ name = "fd-decider", position = dp, force = "player", raise_built = true })
    if d then
      box.get_wire_connector(defines.wire_connector_id.circuit_red, true).connect_to(
        d.get_wire_connector(defines.wire_connector_id.combinator_input_red, true))
      -- an output only has a network once something is wired to it: wire it to stop A (green)
      d.get_wire_connector(defines.wire_connector_id.combinator_output_green, true).connect_to(
        sa.get_wire_connector(defines.wire_connector_id.circuit_green, true))
      local p = { type = "item", name = "fd-passengers" }
      d.get_control_behavior().parameters = {
        conditions = {
          { first_signal = p, comparator = ">", constant = 1000000000 },
          { first_signal = { type = "item", name = "fd-mail" }, comparator = ">", constant = 1, compare_type = "or" },
        },
        outputs = { { signal = { type = "virtual", name = "signal-red" }, constant = 1, copy_count_from_input = false } },
        else_outputs = { { signal = { type = "virtual", name = "signal-green" }, constant = 1, copy_count_from_input = false } },
      }
      storage.decider = d
    end
    L("decider placed", tostring(d ~= nil))
  end
  -- powerless arithmetic (0.8.3): box -> input (red), Passengers / 20 -> W on its green output,
  -- wired to stop A, which takes its priority from W. At 1800 switch to Passengers * 1 to see
  -- whether priority is capped at 255.
  if tick == 1200 then
    local surf = box.surface
    local ap = surf.find_non_colliding_position("fd-arithmetic", { box.position.x - 3, box.position.y + 2 }, 8, 0.5)
    local a = ap and surf.create_entity({ name = "fd-arithmetic", position = ap, force = "player", raise_built = true })
    if a then
      box.get_wire_connector(defines.wire_connector_id.circuit_red, true).connect_to(
        a.get_wire_connector(defines.wire_connector_id.combinator_input_red, true))
      a.get_wire_connector(defines.wire_connector_id.combinator_output_green, true).connect_to(
        sa.get_wire_connector(defines.wire_connector_id.circuit_green, true))
      a.get_control_behavior().parameters = { first_signal = { type = "item", name = "fd-passengers" },
        operation = "/", second_constant = 20, output_signal = { type = "virtual", name = "signal-W" } }
      scb.set_priority = true
      scb.priority_signal = { type = "virtual", name = "signal-W" }
      storage.arith = a
    end
    L("arithmetic placed", tostring(a ~= nil))
  end
  local ar = storage.arith
  if ar and ar.valid then
    local net = ar.get_circuit_network(defines.wire_connector_id.combinator_output_green)
    local w = 0
    for _, sg in pairs(net and net.signals or {}) do if sg.signal.name == "signal-W" then w = sg.count end end
    L("arith W=" .. w .. " op=" .. ar.get_control_behavior().parameters.operation .. " stop priority=" .. sa.train_stop_priority)
    if tick == 1800 then
      local pr = ar.get_control_behavior().parameters
      pr.operation = "*"; pr.second_constant = 1
      ar.get_control_behavior().parameters = pr
    end
  end
  local d = storage.decider
  if d and d.valid then
    local net = d.get_circuit_network(defines.wire_connector_id.combinator_output_green)
    local rnet = d.get_circuit_network(defines.wire_connector_id.combinator_output_red)
    L("decider out green=" .. serpent.line(net and net.signals) .. " red=" .. serpent.line(rnet and rnet.signals) ..
      " (pax>1e9 OR mail>1 -> signal-red, else signal-green)")
    if tick == 1800 then
      -- now make it false: pax > 1e9 AND mail > 1
      local pr = d.get_control_behavior().parameters
      pr.conditions[2].compare_type = "and"
      d.get_control_behavior().parameters = pr
    end
  end
  if tick == 1800 then
    scb.circuit_condition = { first_signal = { type = "item", name = "fd-passengers" }, comparator = ">", constant = 1000000000 }
    if sig then sig.get_control_behavior().circuit_condition = { first_signal = { type = "item", name = "fd-passengers" }, comparator = ">", constant = 1 } end
  elseif tick == 2400 then
    scb.circuit_condition = { first_signal = { type = "item", name = "fd-passengers" }, comparator = ">", constant = 1 }
    if sig then sig.get_control_behavior().circuit_condition = { first_signal = { type = "item", name = "fd-passengers" }, comparator = ">", constant = 1000000000 } end
  end
end

-- 0.9.0 destinations: numbers, stop names, where the shuttle can take passengers, a wildcard
-- interrupt (added and removed in the same tick), an unreachable wildcard-only train, wagon
-- filters (one slot of wagon 2 filtered to mail), and stranded riders.
local function wagon_summary(w)
  local inv = w.get_inventory(defines.inventory.cargo_wagon)
  local nf = 0
  for i = 1, #inv do if inv.get_filter(i) then nf = nf + 1 end end
  local c = {}
  for _, it in pairs(inv.get_contents()) do c[#c + 1] = it.name .. "=" .. it.count end
  table.sort(c)
  return "slots=" .. #inv .. " filtered=" .. nf .. " " .. table.concat(c, ",")
end

dest_check = function(tick)
  local t = storage.train
  if not (t and t.valid) then return end
  if tick == 1200 then
    L("dest_sites=" .. serpent.line(remote.call("freight_dispatch", "dest_sites")))
    L("stops=" .. serpent.line((function()
      local n = {}
      for _, s in pairs(game.surfaces["freight"].find_entities_filtered({ type = "train-stop" })) do n[#n + 1] = s.backer_name end
      return n
    end)()))
    L("shuttle dests=" .. serpent.line(remote.call("freight_dispatch", "train_dests", t)))
    -- wildcard interrupt on the shuttle, read back, dests, then removed again
    local sch = t.get_schedule()
    local ok, err = pcall(function()
      sch.add_interrupt({ name = "fd-test dispatch",
        conditions = { { type = "item_count", condition = { first_signal = { type = "virtual", name = "signal-item-parameter" }, comparator = ">", constant = 0 } } },
        targets = { { station = "[virtual-signal=signal-item-parameter] unload", wait_conditions = { { type = "time", ticks = 60 } } } } })
    end)
    L("interrupt add ok=" .. tostring(ok) .. " " .. tostring(err))
    L("interrupts=" .. serpent.line(sch.get_interrupts()))
    L("shuttle+wildcard dests=" .. serpent.line(remote.call("freight_dispatch", "train_dests", t)))
    pcall(function() sch.remove_interrupt(sch.interrupt_count) end)
    L("interrupt count after remove=" .. tostring(sch.interrupt_count))
    -- a lone locomotive on its own short track, wildcard interrupt only: nothing reachable
    local surf = game.surfaces["freight"]
    for x = 100, 140, 2 do surf.create_entity({ name = "straight-rail", position = { x, Y + 30 }, direction = defines.direction.east, force = "player" }) end
    local lone = surf.create_entity({ name = "locomotive", position = { 120, Y + 30 }, direction = defines.direction.east, force = "player" })
    if lone then
      local ls = lone.train.get_schedule()
      pcall(function()
        ls.add_interrupt({ name = "fd-test lone",
          conditions = { { type = "item_count", condition = { first_signal = { type = "virtual", name = "signal-item-parameter" }, comparator = ">", constant = 0 } } },
          targets = { { station = "[virtual-signal=signal-item-parameter] unload", wait_conditions = { { type = "time", ticks = 60 } } } } })
      end)
      L("lone wildcard dests=" .. serpent.line(remote.call("freight_dispatch", "train_dests", lone.train)))
    end
    -- wagon 2: every slot filtered to mail (0.9.1: the mod only extends filters on a wagon
    -- upgrade, and only when all slots share one cargo; the upgrade at tick 6000 should give 120)
    local inv2 = t.cargo_wagons[2].get_inventory(defines.inventory.cargo_wagon)
    local nset = 0
    for i = 1, #inv2 do
      if not inv2[i].valid_for_read and inv2.set_filter(i, "fd-mail") then nset = nset + 1 end
    end
    L("filter set on " .. nset .. " slots")
  end
  if tick == 4800 then
    -- mail for starter town 1, which the shuttle never visits, into the mail-filtered wagon 2: it
    -- should get off at the next town (town A or B stock) with a flying text
    L("stranded injected=" .. remote.call("freight_dispatch", "inject_cargo", t.cargo_wagons[2], "fd-mail-1", 300, storage.town_a))
  end
  if tick >= 1200 and tick <= 9000 and tick % 1200 == 0 or tick == 4800 + 600 or tick == 4800 + 1200 then
    L("w1 " .. wagon_summary(t.cargo_wagons[1]))
    L("w2 " .. wagon_summary(t.cargo_wagons[2]))
  end
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
  if not storage.spacing_logged then
    -- starter layout: each site's distance from spawn and from its nearest neighbour
    storage.spacing_logged = true
    local ss = {}
    for i = 1, 8 do ss[i] = remote.call("freight_dispatch", "site", i) end
    for i, a in ipairs(ss) do
      local nd
      for j, b in ipairs(ss) do
        if i ~= j then
          local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
          if not nd or d < nd then nd = d end
        end
      end
      L(string.format("starter %d %s at %d,%d spawn=%d nearest=%d", i, a.kind, a.x, a.y, math.sqrt(a.x ^ 2 + a.y ^ 2), nd))
    end
  end
  if not storage.built then
    storage.built = true
    build()
    return
  end
  if e.tick >= 1200 and e.tick <= 3000 then circuit_check(e.tick) end
  dest_check(e.tick)
  -- power plant (0.4.1): a plant overlapping stop B with a nearly full fuel pile; coal and
  -- lumber in the train. Only what fits comes off; the rest follows as the plant burns.
  if e.tick == 3600 then
    local pp = remote.call("freight_dispatch", "create_site", "power-plant", 352, Y - 12)
    remote.call("freight_dispatch", "set_fuel", pp, 17990)
    storage.pp = pp
    local w = storage.train.cargo_wagons[1]
    L("power: injected coal=" .. remote.call("freight_dispatch", "inject_cargo", w, "fd-coal", 1500, storage.town_a) ..
      " wood=" .. remote.call("freight_dispatch", "inject_cargo", w, "fd-wood", 1000, storage.town_a))
  end
  if storage.pp and e.tick > 3600 and e.tick <= 6000 then
    local pp = remote.call("freight_dispatch", "site", storage.pp)
    local tb = remote.call("freight_dispatch", "site", 2 + 8) -- second harness town (after 8 starters)
    local t = storage.train
    L("power: fuel=" .. math.floor(pp.fuel or 0) .. " burnt=" .. math.floor(pp.burnt or 0) ..
      " train coal=" .. t.get_item_count("fd-coal") .. " wood=" .. t.get_item_count("fd-wood") ..
      " at=" .. tostring(t.station and t.station.backer_name) .. " townB powered_by=" .. tostring(tb and tb.powered_by) ..
      " | " .. tostring(remote.call("freight_dispatch", "site_detail", storage.pp)))
  end
  if e.tick == 6000 then upgrade_test() end
  -- back-pressure: a factory overlapping stop B with a nearly full steel pile; 3,000 steel in the train
  if e.tick == 6000 then
    local f2 = remote.call("freight_dispatch", "create_site", "factory", 352, Y + 12)
    remote.call("freight_dispatch", "set_input", f2, "fd-steel", 19000)
    storage.f2 = f2
    local t = storage.train
    L("colors: " .. serpent.line(remote.call("freight_dispatch", "train_colors")))
    L("injected steel=" .. remote.call("freight_dispatch", "inject_cargo", t.cargo_wagons[1], "fd-steel", 3000, storage.town_a))
  end
  if storage.f2 and e.tick > 6000 then
    local t = storage.train
    L("backpressure: f2 steel pile=" .. math.floor(remote.call("freight_dispatch", "get_input", storage.f2, "fd-steel") or 0) ..
      " train steel=" .. t.get_item_count("fd-steel") .. " at=" .. tostring(t.station and t.station.backer_name) ..
      " | " .. tostring(remote.call("freight_dispatch", "site_detail", storage.f2)))
  end
  -- pause when output full: fill the test mill's steel output to its cap
  if e.tick == 8400 then remote.call("freight_dispatch", "set_stock", storage.mill, "fd-steel", 4000) end
  if e.tick == 9000 or e.tick == 9600 then
    L("mill after fill: " .. tostring(remote.call("freight_dispatch", "site_detail", storage.mill)) ..
      " ore pile=" .. math.floor(remote.call("freight_dispatch", "get_input", storage.mill, "fd-iron-ore") or 0))
  end
  if storage.mill and e.tick >= 6600 then
    if e.tick == 7200 then remote.call("freight_dispatch", "set_input", storage.factory, "fd-wood", 5000) end
    L("mill: " .. tostring(remote.call("freight_dispatch", "site_detail", storage.mill)))
    L("factory: " .. tostring(remote.call("freight_dispatch", "site_detail", storage.factory)))
    L("town: " .. tostring(remote.call("freight_dispatch", "site_detail", 5)))
    local t = storage.train
    if t and t.valid then
      local w = t.cargo_wagons[1]
      local fuel = t.locomotives.front_movers[1].get_fuel_inventory().get_contents()
      L("achievements=" .. #prototypes.achievement)
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
