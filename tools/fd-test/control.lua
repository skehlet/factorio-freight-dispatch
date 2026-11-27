-- Headless test harness for Freight Dispatch. NOT for players.
-- On a fresh map it builds a 440-tile straight line at y=1000 between two big towns,
-- a 4-car train (loco, 2 wagons, reversed loco) shuttling with "Full OR 30 s" at both
-- stops, plus a rail-signal ghost queued for instant build. Every 10 s it logs
-- "FDTEST t=..." lines: money, lifetime earnings, deliveries, train state and cargo.
-- Healthy run: money rises about $20k+ per trip, both directions, and ghostvalid=false.
local Y = 1000

local function L(...) log("FDTEST " .. table.concat({ ... }, " ")) end
local dest_check
local sel_next

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
    L("stranded injected=" .. remote.call("freight_dispatch", "inject_cargo", t.cargo_wagons[2], "fd-mail-1", 30, storage.town_a))
  end
  if tick >= 1200 and tick <= 9000 and tick % 1200 == 0 or tick == 4800 + 600 or tick == 4800 + 1200 then
    L("w1 " .. wagon_summary(t.cargo_wagons[1]))
    L("w2 " .. wagon_summary(t.cargo_wagons[2]))
  end
end

-- 0.9.3 "most riders" dispatch: a second line at Y-200 with towns C (x=0), D (180), E (360).
-- A train at D (drop-off) carries riders for C and E. Both stops at D read train contents
-- and send to train; red -> fd-selector (max) -> fd-arithmetic (each + 1,000,000) -> green.
-- Interrupt "item count [wildcard] > 0 AND circuit [wildcard] > 500,000 -> [wildcard] unload".
-- Phases (one per visit to D): C 50/E 150 -> E;  C 150/E 50 -> C;  then the control, a
-- plain "item count [wildcard] > 0" interrupt with C 50/E 150 -> C (0.9.8: a tenth of the old
-- numbers, as a wagon now holds 200 passengers) (first match by item
-- order: the bias seen on Steve's save). Also tried: circuit [wildcard] alone (never fires).
local Y2 = Y - 200
local P = { type = "virtual", name = "signal-item-parameter" }
local S = { type = "virtual", name = "signal-signal-parameter" }
local PT = "[virtual-signal=signal-item-parameter] unload"
local ST = "[virtual-signal=signal-signal-parameter] unload"
local SEL_PHASES = {
  { name = "item wildcard in circuit", c = 50, e = 150, expect = "E", target = PT,
    conds = { { type = "circuit", condition = { first_signal = P, comparator = ">", constant = 500000 } } } },
  { name = "signal wildcard", c = 50, e = 150, expect = "E", target = ST,
    conds = { { type = "circuit", condition = { first_signal = S, comparator = ">", constant = 500000 } } } },
  { name = "signal wildcard", c = 150, e = 50, expect = "C", target = ST,
    conds = { { type = "circuit", condition = { first_signal = S, comparator = ">", constant = 500000 } } } },
  { name = "signal wildcard + dest not full", c = 50, e = 150, expect = "E", target = ST,
    conds = { { type = "circuit", condition = { first_signal = S, comparator = ">", constant = 500000 } },
              { type = "specific_destination_not_full", station = ST } } },
  { name = "control: item count wildcard", c = 50, e = 150, expect = "C", target = PT,
    conds = { { type = "item_count", condition = { first_signal = P, comparator = ">", constant = 0 } } } },
  -- 0.9.4: a constant combinator on the stop -> selector wire puts -1,000,000 on E's riders
  -- (as for a Spaceport), so the selector picks C although E has more aboard
  { name = "signal wildcard, E excluded", c = 50, e = 150, expect = "C", target = ST, exclude_e = true,
    conds = { { type = "circuit", condition = { first_signal = S, comparator = ">", constant = 500000 } },
              { type = "specific_destination_not_full", station = ST } } },
}

local function sel_inject(c, e)
  local s = storage.sel
  local w = s.train.cargo_wagons[1]
  local inv = w.get_inventory(defines.inventory.cargo_wagon)
  local got = {}
  for _, pass in pairs({ "remove", "add" }) do
    for k, n in pairs({ C = c, E = e }) do
      local item = "fd-passengers-" .. s.no[k]
      local have = inv.get_item_count(item)
      if pass == "add" and n > have then remote.call("freight_dispatch", "inject_cargo", w, item, n - have, s.origin)
      elseif pass == "remove" and n < have then inv.remove({ name = item, count = have - n }) end
      got[k] = inv.get_item_count(item)
    end
  end
  return got
end

-- start the next phase: install its interrupt and set the riders aboard
sel_next = function(tick)
  local s = storage.sel
  s.phase = (s.phase or 0) + 1
  s.left, s.since = false, tick
  local ph = SEL_PHASES[s.phase]
  if not ph then s.phase, s.done = nil, true L("sel done") return end
  local sch = s.train.get_schedule()
  while sch.interrupt_count > 0 do sch.remove_interrupt(1) end
  sch.add_interrupt({ name = ph.name, conditions = ph.conds,
    targets = { { station = ph.target, wait_conditions = { { type = "time", ticks = 120 } } } } })
  if ph.exclude_e and s.const and s.const.valid then
    local sec = s.const.get_control_behavior().get_section(1) or s.const.get_control_behavior().add_section()
    sec.set_slot(1, { value = { type = "item", name = "fd-passengers-" .. s.no.E, quality = "normal" }, min = -1000000 })
  end
  local got = sel_inject(ph.c, ph.e)
  L("sel phase " .. s.phase .. " (" .. ph.name .. ") aboard C=" .. got.C .. " E=" .. got.E .. ", expect " .. ph.expect)
end

local function sel_build()
  local surf = game.surfaces["freight"]
  local tiles = {}
  for x = -80, 440 do
    for y = Y2 - 40, Y2 + 40 do tiles[#tiles + 1] = { name = "grass-1", position = { x, y } } end
  end
  surf.set_tiles(tiles)
  for _, e in pairs(surf.find_entities_filtered({ area = { { -80, Y2 - 40 }, { 440, Y2 + 40 } } })) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  local ids = {}
  for k, x in pairs({ C = 0, D = 180, E = 360 }) do ids[k] = remote.call("freight_dispatch", "create_site", "town", x, Y2, 3000) end
  for x = -40, 400, 2 do surf.create_entity({ name = "straight-rail", position = { x, Y2 }, direction = defines.direction.east, force = "player" }) end
  local function stop_at(x, dir)
    for _, off in pairs({ { 0, 2 }, { 0, -2 }, { 1, 2 }, { 1, -2 }, { -1, 2 }, { -1, -2 } }) do
      local s = surf.create_entity({ name = "train-stop", position = { x + off[1], Y2 + off[2] }, direction = dir, force = "player", raise_built = true })
      if s and s.connected_rail then return s end
      if s then s.destroy() end
    end
  end
  local E_, W_ = defines.direction.east, defines.direction.west
  local stops = { C = stop_at(10, W_), D = stop_at(184, E_), D2 = stop_at(178, W_), E = stop_at(350, E_) }
  if not (stops.C and stops.D and stops.D2 and stops.E) then L("sel stop FAILED") return end
  stops.D2.backer_name = stops.D.backer_name -- one station at D for both directions
  local no = {}
  for k, id in pairs(ids) do no[k] = remote.call("freight_dispatch", "site", id).no end
  L("sel towns C/D/E no=" .. serpent.line(no) .. " stops C=" .. stops.C.backer_name .. " D=" .. stops.D.backer_name .. " E=" .. stops.E.backer_name)
  local W = defines.wire_connector_id
  for _, sd in pairs({ stops.D, stops.D2 }) do
    local cb = sd.get_or_create_control_behavior()
    cb.read_from_train = true
    cb.send_to_train = true
  end
  local ok = {}
  ok[1] = stops.D.get_wire_connector(W.circuit_red, true).connect_to(stops.D2.get_wire_connector(W.circuit_red, true))
  ok[2] = stops.D.get_wire_connector(W.circuit_green, true).connect_to(stops.D2.get_wire_connector(W.circuit_green, true))
  local sp = surf.find_non_colliding_position("fd-selector", { stops.D.position.x - 1, stops.D.position.y + 3 }, 8, 0.5)
  local sel = sp and surf.create_entity({ name = "fd-selector", position = sp, force = "player", raise_built = true })
  local ap = sel and surf.find_non_colliding_position("fd-arithmetic", { stops.D.position.x + 2, stops.D.position.y + 3 }, 8, 0.5)
  local ar = ap and surf.create_entity({ name = "fd-arithmetic", position = ap, force = "player", raise_built = true })
  L("sel placed selector=" .. tostring(sel ~= nil) .. " arithmetic=" .. tostring(ar ~= nil))
  if not (sel and ar) then return end
  ok[3] = stops.D.get_wire_connector(W.circuit_red, true).connect_to(sel.get_wire_connector(W.combinator_input_red, true))
  ok[4] = sel.get_wire_connector(W.combinator_output_green, true).connect_to(ar.get_wire_connector(W.combinator_input_green, true))
  ok[5] = ar.get_wire_connector(W.combinator_output_green, true).connect_to(stops.D.get_wire_connector(W.circuit_green, true))
  -- a vanilla constant combinator (Shop, 0.9.4) on the stop -> selector red wire, empty until phase 6
  local cp = surf.find_non_colliding_position("constant-combinator", { stops.D.position.x - 3, stops.D.position.y + 3 }, 8, 0.5)
  local const = cp and surf.create_entity({ name = "constant-combinator", position = cp, force = "player", raise_built = true })
  ok[6] = const and const.get_wire_connector(W.circuit_red, true).connect_to(stops.D.get_wire_connector(W.circuit_red, true))
  L("sel wires connected=" .. serpent.line(ok) .. " shop constant recipe enabled=" .. tostring(game.forces.player.recipes["constant-combinator"].enabled))
  sel.get_control_behavior().parameters = { operation = "select", select_max = true, index_constant = 0 }
  local each = { type = "virtual", name = "signal-each" }
  ar.get_control_behavior().parameters = { first_signal = each, operation = "+", second_constant = 1000000, output_signal = each }
  -- the train: loco, wagon, reversed loco, west of D's east-facing stop, heading east
  local l1 = surf.create_entity({ name = "locomotive", position = { 160, Y2 }, direction = defines.direction.east, force = "player" })
  surf.create_entity({ name = "cargo-wagon", position = { 153, Y2 }, direction = defines.direction.east, force = "player" })
  surf.create_entity({ name = "locomotive", position = { 146, Y2 }, direction = defines.direction.west, force = "player" })
  local t = l1 and l1.train
  if not t then L("sel no train") return end
  t.get_schedule().add_record({ station = stops.D.backer_name, wait_conditions = { { type = "empty" }, { type = "time", ticks = 120, compare_type = "or" } } })
  t.manual_mode = false
  storage.sel = { train = t, dname = stops.D.backer_name, sel = sel, const = const, no = no, origin = 1, phases = SEL_PHASES,
    dstops = { D = stops.D, D2 = stops.D2 }, stopname = { [stops.C.backer_name] = "C", [stops.E.backer_name] = "E" } }
end

script.on_event(defines.events.on_train_changed_state, function(e)
  local s = storage.sel
  if not (s and s.train.valid and e.train.id == s.train.id) then return end
  local t = s.train
  local at_d = t.station and t.station.backer_name == s.dname
  if s.done then return end
  if t.state == defines.train_state.wait_station and at_d then
    sel_next(e.tick)
  elseif e.old_state == defines.train_state.wait_station and s.phase and not s.left then
    local sch = t.get_schedule()
    local r = sch.get_record({ schedule_index = sch.current })
    if r and r.station ~= s.dname then
      s.left = true
      local ph = s.phases[s.phase]
      local went = s.stopname[r.station] or r.station
      local out = s.sel.get_circuit_network(defines.wire_connector_id.combinator_output_green)
      L("sel phase " .. s.phase .. " (" .. ph.name .. ") -> " .. went .. (went == ph.expect and " OK" or " WRONG, expected " .. ph.expect) ..
        " selector_out=" .. serpent.line(out and out.signals))
    end
  end
end)

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
  if e.tick == 1200 then sel_build() end
  local sl = storage.sel
  if sl and sl.train.valid and e.tick % 1200 == 0 then
    local W = defines.wire_connector_id
    local function sig(ent, id)
      local n = ent.get_circuit_network(id)
      local o = {}
      for _, x in pairs(n and n.signals or {}) do o[#o + 1] = x.signal.name .. "=" .. x.count end
      return table.concat(o, ",")
    end
    L("sel t=" .. e.tick .. " state=" .. sl.train.state .. " at=" .. tostring(sl.train.station and sl.train.station.backer_name) ..
      " sel_in[" .. sig(sl.sel, W.combinator_input_red) .. "] sel_out[" .. sig(sl.sel, W.combinator_output_green) .. "]")
    for k, st in pairs(sl.dstops or {}) do
      local cb = st.get_control_behavior()
      L("sel   stop " .. k .. " @" .. st.position.x .. " train=" .. tostring(st.get_stopped_train() ~= nil) .. " read=" .. tostring(cb and cb.read_from_train) ..
        " send=" .. tostring(cb and cb.send_to_train) .. " red[" .. sig(st, W.circuit_red) .. "] green[" .. sig(st, W.circuit_green) .. "]")
    end
  end
  -- a phase whose train never leaves D: log it and move on to the next phase
  if sl and sl.train.valid and sl.phase and sl.train.station and sl.train.station.backer_name == sl.dname and not sl.left
    and sl.since and e.tick - sl.since >= 900 then
    L("sel phase " .. sl.phase .. " (" .. sl.phases[sl.phase].name .. ") STUCK at D: the interrupt never fired")
    sel_next(e.tick)
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
