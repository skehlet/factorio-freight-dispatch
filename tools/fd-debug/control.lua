-- Save inspector for Freight Dispatch. NOT for players.
-- Added to a COPY of the user's save. on_init runs when it is "added" to the save:
--   1. calls the mod's debug_dump remote (FDDUMP lines: every train's schedule, wagons,
--      per-lot cargo records, stops and their linked sites, towns' stock, contracts)
--   2. logs a snapshot of all trains every 10 s (FDSNAP lines) so you can watch behaviour
-- Edit freely for one-off investigations (e.g. flip a train to automatic, inspect a
-- wagon's inventory bar/filters, count player inventory items).
local states = {}
for k, v in pairs(defines.train_state) do states[v] = k end

local function snap(label)
  local st = remote.call("freight_dispatch", "stats")
  log("FDSNAP " .. label .. " money=" .. math.floor(st.money) .. " deliveries=" .. st.deliveries)
  for _, t in pairs(game.train_manager.get_trains({ surface = game.surfaces["freight"] })) do
    log("FDSNAP   train " .. t.id .. " state=" .. tostring(states[t.state]) .. " at=" ..
      tostring(t.station and t.station.backer_name) .. " cargo=" .. serpent.line(t.get_contents()))
  end
end

script.on_init(function()
  remote.call("freight_dispatch", "debug_dump")
  storage.start = game.tick
  snap("load")
end)

-- circuit inspector: every Site signals box, what it outputs, and every stop/signal wired to it
script.on_nth_tick(120, function()
  if storage.circ_logged then return end
  storage.circ_logged = true
  local surf = game.surfaces["freight"]
  for _, e in pairs(surf.find_entities_filtered({ type = { "constant-combinator", "decider-combinator", "arithmetic-combinator" } })) do
    log("FDCIRC combinator " .. e.name .. " at " .. e.position.x .. "," .. e.position.y)
  end
  for _, st in pairs(surf.find_entities_filtered({ type = "train-stop" })) do
    local cb = st.get_control_behavior()
    if cb and (cb.circuit_enable_disable or st.get_circuit_network(defines.wire_connector_id.circuit_red) or st.get_circuit_network(defines.wire_connector_id.circuit_green)) then
      local rn = st.get_circuit_network(defines.wire_connector_id.circuit_red)
      local gn = st.get_circuit_network(defines.wire_connector_id.circuit_green)
      log("FDCIRC stop " .. st.backer_name .. " at " .. st.position.x .. "," .. st.position.y .. " enable_disable=" .. tostring(cb.circuit_enable_disable) ..
        " disabled=" .. tostring(cb.disabled) .. " cond=" .. serpent.line(cb.circuit_condition) ..
        " red=" .. serpent.line(rn and rn.signals) .. " green=" .. serpent.line(gn and gn.signals))
    end
  end
  for _, box in pairs(surf.find_entities_filtered({ name = "fd-site-signals" })) do
    local cb0 = box.get_control_behavior()
    local sec = cb0 and cb0.get_section(1)
    log("FDCIRC box at " .. box.position.x .. "," .. box.position.y .. " signals=" .. serpent.line(sec and sec.filters))
    for _, wid in pairs({ defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }) do
      local c = box.get_wire_connector(wid, false)
      for _, conn in pairs(c and c.connections or {}) do
        local o = conn.target.owner
        local line = "FDCIRC   wire " .. wid .. " -> " .. o.name .. " " .. (o.backer_name or "") .. " at " .. o.position.x .. "," .. o.position.y
        local cb = o.get_control_behavior()
        if cb and o.type == "train-stop" then
          line = line .. " enable_disable=" .. tostring(cb.circuit_enable_disable) .. " disabled=" .. tostring(cb.disabled) ..
            " cond=" .. serpent.line(cb.circuit_condition)
          local net = o.get_circuit_network(conn.target.wire_connector_id)
          line = line .. " net_signals=" .. serpent.line(net and net.signals)
        elseif cb and o.type == "rail-signal" then
          line = line .. " close=" .. tostring(cb.close_signal) .. " cond=" .. serpent.line(cb.circuit_condition) .. " state=" .. tostring(o.signal_state)
        end
        log(line)
      end
    end
  end
end)

-- balance report, about 1 min after load (also, on_init runs BEFORE the main mod's on_configuration_changed)
script.on_nth_tick(60, function()
  if game.tick - (storage.start or 0) < 3660 then return end
  if storage.towns_logged then return end
  storage.towns_logged = true
  local n = 0
  for _ in pairs(remote.call("freight_dispatch", "sites")) do n = n + 1 end
  log("FDSNAP sites=" .. n .. " " .. serpent.line(remote.call("freight_dispatch", "served")))
  local st = remote.call("freight_dispatch", "stats")
  log("FDBAL playtime_h=" .. string.format("%.2f", game.tick / 216000) .. " money=" .. math.floor(st.money) ..
    " lifetime=" .. math.floor(st.lifetime) .. " " .. serpent.line(st))
  local towns, inds = {}, {}
  for _, s in pairs(remote.call("freight_dispatch", "sites")) do
    if s.delivered > 0 or s.shipped > 0 then
      table.insert(s.kind == "town" and towns or inds, s)
    end
  end
  table.sort(towns, function(a, b) return a.pop > b.pop end)
  local total = 0
  for _, s in pairs(towns) do
    total = total + s.pop
    log("FDBAL town " .. s.name .. " pop=" .. math.floor(s.pop) .. " rating=" .. string.format("%.2f", s.rating) ..
      " shipped=" .. math.floor(s.shipped) .. " delivered=" .. math.floor(s.delivered) ..
      " recv=" .. serpent.line(s.recv) .. " growth=" .. serpent.line(s.growth))
  end
  log("FDBAL towns=" .. #towns .. " total_pop=" .. math.floor(total))
  for _, s in pairs(inds) do
    log("FDBAL ind " .. s.kind .. " " .. s.name .. " lvl=" .. s.level .. " shipped=" .. math.floor(s.shipped) ..
      " detail=" .. tostring(remote.call("freight_dispatch", "site_detail", s.id)))
  end
  local n = 0
  for _ in pairs(game.train_manager.get_trains({ surface = game.surfaces["freight"] })) do n = n + 1 end
  log("FDBAL trains=" .. n)
  local cols = remote.call("freight_dispatch", "train_colors")
  local k = 0
  for id, s in pairs(cols) do k = k + 1; if k <= 6 then log("FDBAL color train " .. id .. ": " .. s) end end
  local f = game.forces.player
  log("FDBAL circuit tech=" .. tostring(f.technologies["circuit-network"].researched) .. " decider recipe=" .. tostring(f.recipes["decider-combinator"].enabled) .. " box recipe=" .. tostring(f.recipes["fd-site-signals"].enabled) .. " rail recipe=" .. tostring(f.recipes["rail"].enabled) .. " fd-decider recipe=" .. tostring(f.recipes["fd-decider"].enabled))
end)


-- supply chain report at 3 min and 11 min after load
-- (own tick interval: a second on_nth_tick(60) would replace the balance report above)
script.on_nth_tick(1800, function()
  local t = game.tick - (storage.start or 0)
  for _, at in pairs({ 3 * 3600, 11 * 3600 }) do
    if t >= at and t - 1800 < at then
      log("FDCHAIN at +" .. math.floor(t / 60) .. "s\n" .. serpent.block(remote.call("freight_dispatch", "chain")))
    end
  end
end)


-- income by cargo: logged every 2 min (needs freight-dispatch 0.5.4+ for earned_item)
script.on_nth_tick(7200, function()
  local st = remote.call("freight_dispatch", "stats")
  local waiting = 0
  for _, s in pairs(remote.call("freight_dispatch", "sites")) do
    if s.kind == "town" then waiting = waiting + (s.stock["fd-passengers"] or 0) end
  end
  log("FDINCOME +" .. math.floor((game.tick - (storage.start or 0)) / 60) .. "s money=" .. math.floor(st.money) ..
    " lifetime=" .. math.floor(st.lifetime) .. " pax_waiting=" .. math.floor(waiting) .. " " .. serpent.line(st.earned_item) ..
    " upgrades=" .. serpent.line(st.upgrades))
end)


-- Spaceport check: passive log of the pad (set storage.pad_test = true in on_init for the scripted test)
script.on_nth_tick(300, function()
  local t = game.tick - (storage.start or 0)
  if t > 6000 and t % 3600 > 300 then return end
  local fd = "freight_dispatch"
  local sp = remote.call(fd, "spaceport")
  log("FDPAD +" .. math.floor(t / 60) .. "s " .. serpent.line(sp))
  if not storage.pad_test then return end
  if sp.id and not storage.pad_step then
    storage.pad_step = 1
    local set = { colonists = sp.need.colonists, mail = sp.need.mail, paid = sp.need.cost - 50000 }
    if sp.need.goods then set.goods = sp.need.goods - 10 end
    remote.call(fd, "set_pad", set)
    log("FDPAD set nearly complete, goods 10 short")
  elseif storage.pad_step == 1 then
    storage.pad_step = 2
    if sp.need.goods then remote.call(fd, "set_pad", { goods = sp.need.goods }) end
    log("FDPAD goods complete")
  end
end)

script.on_nth_tick(600, function()
  snap("+" .. math.floor((game.tick - (storage.start or 0)) / 60) .. "s")
end)

-- Signal scanner (one-off): for each rail signal, measure the block a train enters after
-- passing it (to the next signal facing the same way). Short blocks mean a train stopped at
-- the next signal sticks out back past this one.
local function sig_at(surf, loc)
  if not loc then return nil end
  for _, s in pairs(surf.find_entities_filtered({ position = loc.position, radius = 0.3, type = { "rail-signal", "rail-chain-signal" } })) do
    if s.direction == loc.direction then return s end
  end
end

-- Convention (checked on Steve's save): a signal sits at a rail end's in_signal_location and
-- guards trains entering that rail through that end.
local function in_sig(surf, re)
  return sig_at(surf, re.in_signal_location) or sig_at(surf, re.alternative_in_signal_location)
end

local CONN = { defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right }

-- re: end of the first rail past the signal, pointing in the direction of travel
local function walk(surf, re0)
  local re = re0.make_copy()
  local len, branch, stop = re.rail.rail_length, false, nil
  for _ = 1, 400 do
    local n = 0
    for _, c in pairs(CONN) do
      if re.rail.get_connected_rail({ rail_direction = re.direction, rail_connection_direction = c }) then n = n + 1 end
    end
    if n == 0 then return len, "dead end", branch, stop end
    if n > 1 then branch = true end
    local st = re.rail.get_rail_segment_stop(re.direction)
    if st and not stop then stop = st.backer_name end
    if not re.move_natural() then return len, "dead end", branch, stop end
    local near = re.make_copy()
    near.flip_direction()
    local s = in_sig(surf, near)
    if s then return len, s, branch, stop end
    len = len + re.rail.rail_length
    if len > 400 then return len, "far", branch, stop end
  end
  return len, "far", branch, stop
end
SIG_WALK = walk
SIG_IN = in_sig

function SIGSCAN()
  local surf = game.surfaces["freight"]
  local maxcars = 0
  for _, t in pairs(game.train_manager.get_trains({ surface = surf })) do maxcars = math.max(maxcars, #t.carriages) end
  local sigs = surf.find_entities_filtered({ type = "rail-signal" })
  local nfound, nshort = 0, 0
  log("FDSIG scanning " .. #sigs .. " rail signals, " .. #surf.find_entities_filtered({ type = "rail-chain-signal" }) .. " chain signals, longest train " .. maxcars .. " carriages")
  for _, s in pairs(sigs) do
    local found
    for _, r in pairs(s.get_connected_rails()) do
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        local re = r.get_rail_end(d)
        if not found and in_sig(surf, re) == s then
          found = r.get_rail_end(d == defines.rail_direction.front and defines.rail_direction.back or defines.rail_direction.front)
        end
      end
    end
    if found then
      nfound = nfound + 1
      local len, nxt, branch, stop = walk(surf, found)
      if len < 45 then
        nshort = nshort + 1
        log(string.format("FDSIG short %.1f tiles: signal at %.1f,%.1f dir=%d -> %s%s%s", len, s.position.x, s.position.y, s.direction,
          type(nxt) == "string" and nxt or (nxt.type .. " at " .. nxt.position.x .. "," .. nxt.position.y),
          branch and " (branch in block)" or "", stop and (" stop=" .. stop) or ""))
      end
    else
      log("FDSIG no rail end for signal at " .. s.position.x .. "," .. s.position.y)
    end
  end
  log("FDSIG done: matched " .. nfound .. ", short " .. nshort)
end

script.on_nth_tick(301, function()
  if storage.sig_scanned then return end
  storage.sig_scanned = true
  SIGSCAN()
end)

script.on_nth_tick(307, function()
  if storage.sig_dbg then return end
  storage.sig_dbg = true
  local surf = game.surfaces["freight"]
  local s = surf.find_entities_filtered({ position = { -900.5, 77.5 }, radius = 0.5, type = "rail-signal" })[1]
  log("FDSIGDBG signal pos=" .. serpent.line(s.position) .. " dir=" .. s.direction .. " layer=" .. tostring(s.rail_layer))
  for _, r in pairs(s.get_connected_rails()) do
    for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
      local re = r.get_rail_end(d)
      log("FDSIGDBG rail " .. r.name .. " " .. serpent.line(r.position) .. " end " .. d .. " in=" .. serpent.line(re.in_signal_location) ..
        " out=" .. serpent.line(re.out_signal_location) .. " altin=" .. serpent.line(re.alternative_in_signal_location) .. " altout=" .. serpent.line(re.alternative_out_signal_location))
    end
  end
end)

-- refined scan: junction exits only, compared with real train lengths
function SIGSCAN2()
  local surf = game.surfaces["freight"]
  -- train length in tiles: distance between the outer ends of the front and back carriages
  local function tlen(t)
    local f, b = t.front_stock, t.back_stock
    local dx, dy = f.position.x - b.position.x, f.position.y - b.position.y
    local along = 0
    for i = 2, #t.carriages do
      local a, c = t.carriages[i - 1].position, t.carriages[i].position
      along = along + math.sqrt((a.x - c.x) ^ 2 + (a.y - c.y) ^ 2)
    end
    return along + 6 -- plus half a carriage at each end (about 3 tiles each)
  end
  local maxlen, maxcars = 0, 0
  local station_len = {}
  for _, t in pairs(game.train_manager.get_trains({ surface = surf })) do
    local L = tlen(t)
    if L > maxlen then maxlen, maxcars = L, #t.carriages end
    local ok, sch = pcall(function() return t.get_schedule() end)
    if ok and sch then
      for i = 1, sch.get_record_count() do
        local r = sch.get_record({ schedule_index = i })
        if r and r.station then station_len[r.station] = math.max(station_len[r.station] or 0, L) end
      end
    end
  end
  log(string.format("FDSIG2 longest train %d carriages = %.1f tiles", maxcars, maxlen))
  local flagged = 0
  local list = {}
  for _, s in pairs(surf.find_entities_filtered({ type = "rail-signal" })) do
    for _, r in pairs(s.get_connected_rails()) do
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        local E = r.get_rail_end(d)
        if SIG_IN(surf, E) == s then
          local after = r.get_rail_end(d == defines.rail_direction.front and defines.rail_direction.back or defines.rail_direction.front)
          local len, nxt, branch, stop = SIG_WALK(surf, after)
          -- the block behind: a rail connected at E
          local junction = false
          for _, c in pairs({ defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right }) do
            local prev = r.get_connected_rail({ rail_direction = d, rail_connection_direction = c })
            if prev then
              for _, ib in pairs(prev.get_inbound_signals()) do
                if ib.type == "rail-chain-signal" then junction = true end
              end
            end
          end
          local need = maxlen
          if stop and nxt == "dead end" then need = station_len[stop] or maxlen end
          local entry = string.format("%.1f tiles after, needs %.1f: signal at %.1f,%.1f -> %s%s%s%s", len, need, s.position.x, s.position.y,
            type(nxt) == "string" and nxt or (nxt.type .. " at " .. nxt.position.x .. "," .. nxt.position.y),
            branch and " (branch)" or "", stop and (" stop=" .. stop) or "", junction and " JUNCTION-EXIT" or "")
          if len < need then
            if junction then flagged = flagged + 1; log("FDSIG2 BAD " .. entry) else log("FDSIG2 short-but-not-exit " .. entry) end
          end
        end
      end
    end
  end
  log("FDSIG2 done: flagged " .. flagged)
end

script.on_nth_tick(313, function()
  if storage.sig_scanned2 then return end
  storage.sig_scanned2 = true
  SIGSCAN2()
end)

script.on_nth_tick(317, function()
  if storage.sig_dump then return end
  storage.sig_dump = true
  local surf = game.surfaces["freight"]
  for i, p in pairs({ { -73.5, -260.5 }, { 215.5, 88.5 }, { 624.5, 333.5 }, { 449.5, 534.5 }, { 73.5, -17.5 }, { 226.5, 53.5 } }) do
    local out = {}
    for _, e in pairs(surf.find_entities_filtered({ position = p, radius = 70, type = { "straight-rail", "curved-rail-a", "curved-rail-b", "half-diagonal-rail", "rail-signal", "rail-chain-signal", "train-stop" } })) do
      table.insert(out, string.format("%s,%.1f,%.1f,%d", e.type, e.position.x, e.position.y, e.direction))
    end
    log("FDDUMPAREA " .. i .. " " .. p[1] .. " " .. p[2] .. " " .. table.concat(out, ";"))
  end
end)

-- scan 3: rail segment API (exact). For each rail signal: the segment starting just past it,
-- its length, and what ends it in the direction of travel.
function SIGSCAN3(fix)
  local surf = game.surfaces["freight"]
  local OPP = { [defines.rail_direction.front] = defines.rail_direction.back, [defines.rail_direction.back] = defines.rail_direction.front }
  local res = {}
  for _, s in pairs(surf.find_entities_filtered({ type = "rail-signal" })) do
    for _, r in pairs(s.get_connected_rails()) do
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        if SIG_IN(surf, r.get_rail_end(d)) == s then
          local t = OPP[d]
          local L = r.get_rail_segment_length()
          local endrail, enddir = r.get_rail_segment_end(t)
          local nsig = r.get_rail_segment_signal(t, true)
          local stop = r.get_rail_segment_stop(t)
          local nbranch = 0
          for _, c in pairs({ defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right }) do
            if endrail.get_connected_rail({ rail_direction = enddir, rail_connection_direction = c }) then nbranch = nbranch + 1 end
          end
          -- what is behind the signal: is that block a junction (entered through a chain signal)?
          local junction = false
          for _, c in pairs({ defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right }) do
            local prev = r.get_connected_rail({ rail_direction = d, rail_connection_direction = c })
            if prev then for _, ib in pairs(prev.get_inbound_signals()) do if ib.type == "rail-chain-signal" then junction = true end end end
          end
          table.insert(res, { s = s, L = L, nsig = nsig, stop = stop, nbranch = nbranch, junction = junction })
        end
      end
    end
  end
  local short = 0
  for _, x in ipairs(res) do
    local endtxt = x.nsig and (x.nsig.type .. " at " .. x.nsig.position.x .. "," .. x.nsig.position.y) or (x.nbranch == 0 and "dead end" or (x.nbranch > 1 and "fork" or "merge/other"))
    local line = string.format("%.1f  sig %.1f,%.1f -> %s%s%s", x.L, x.s.position.x, x.s.position.y, endtxt,
      x.stop and (" stop=" .. x.stop.backer_name) or "", x.junction and " EXIT" or "")
    if x.L < 42 then short = short + 1; log("FDSIG3 short " .. line) end
  end
  log("FDSIG3 done: " .. #res .. " signals, " .. short .. " with a segment under 42")
end

script.on_nth_tick(331, function()
  if storage.sig_scanned3 then return end
  storage.sig_scanned3 = true
  SIGSCAN3()
end)

-- scan 4: breadth-first over rail connections, every branch. For each rail signal, the nearest
-- place a train may have to stop after passing it (a same-direction signal or a station).
local CONNS = { defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right }
local OPPD = { [defines.rail_direction.front] = defines.rail_direction.back, [defines.rail_direction.back] = defines.rail_direction.front }

function SIGSCAN4(fix)
  local surf = game.surfaces["freight"]
  -- train lengths, longest overall and per station
  local maxlen, station_len = 0, {}
  for _, t in pairs(game.train_manager.get_trains({ surface = surf })) do
    local along = 0
    for i = 2, #t.carriages do
      local a, c = t.carriages[i - 1].position, t.carriages[i].position
      along = along + math.sqrt((a.x - c.x) ^ 2 + (a.y - c.y) ^ 2)
    end
    local L = along + 6
    maxlen = math.max(maxlen, L)
    local ok, sch = pcall(function() return t.get_schedule() end)
    if ok and sch then
      for i = 1, sch.get_record_count() do
        local r = sch.get_record({ schedule_index = i })
        if r and r.station then station_len[r.station] = math.max(station_len[r.station] or 0, L) end
      end
    end
  end
  -- stops by the rail they sit on and the direction trains travel to reach them
  local stops = {}
  for _, st in pairs(surf.find_entities_filtered({ type = "train-stop" })) do
    local cr = st.connected_rail
    if cr then stops[cr.unit_number .. ":" .. st.connected_rail_direction] = st end
  end
  -- nearest stopping point after entering `rail`, travelling towards its end `tdir`
  local function nearest(rail, tdir, limit)
    local best, bestwhat = math.huge, nil
    local queue = { { rail = rail, tdir = tdir, dist = rail.rail_length } }
    local seen = {}
    local head = 1
    while queue[head] do
      local q = queue[head]; head = head + 1
      local key = q.rail.unit_number .. ":" .. q.tdir
      if not seen[key] and q.dist < best and q.dist < limit then
        seen[key] = true
        local st = stops[q.rail.unit_number .. ":" .. q.tdir] or stops[q.rail.unit_number .. ":" .. OPPD[q.tdir]]
        if st then
          local need = station_len[st.backer_name] or maxlen
          -- a station is only a problem if its trains don't fit
          if q.dist < need then best, bestwhat = q.dist, st end
        end
        local any = false
        for _, c in pairs(CONNS) do
          local nr, ndir = q.rail.get_connected_rail({ rail_direction = q.tdir, rail_connection_direction = c })
          if nr then
            any = true
            local sig = SIG_IN(surf, nr.get_rail_end(ndir))
            if sig then
              if q.dist < best then best, bestwhat = q.dist, sig end
            else
              table.insert(queue, { rail = nr, tdir = OPPD[ndir], dist = q.dist + nr.rail_length })
            end
          end
        end
      end
    end
    return best, bestwhat
  end
  local bad = {}
  local nsig = 0
  for _, s in pairs(surf.find_entities_filtered({ type = "rail-signal" })) do
    for _, r in pairs(s.get_connected_rails()) do
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        if SIG_IN(surf, r.get_rail_end(d)) == s then
          nsig = nsig + 1
          local junction = false
          for _, c in pairs(CONNS) do
            local prev = r.get_connected_rail({ rail_direction = d, rail_connection_direction = c })
            if prev then for _, ib in pairs(prev.get_inbound_signals()) do if ib.type == "rail-chain-signal" then junction = true end end end
          end
          local dist, what = nearest(r, OPPD[d], maxlen)
          if junction and dist < maxlen then
            table.insert(bad, { s = s, dist = dist, what = what })
          end
        end
      end
    end
  end
  log(string.format("FDSIG4 %d rail signals, longest train %.1f tiles, %d junction exits too short", nsig, maxlen, #bad))
  for _, b in ipairs(bad) do
    local w = b.what
    local wired = #(b.s.get_wire_connector(defines.wire_connector_id.circuit_red, false) or { connections = {} }).connections +
      #(b.s.get_wire_connector(defines.wire_connector_id.circuit_green, false) or { connections = {} }).connections
    log(string.format("FDSIG4 BAD %.1f tiles: signal at %.1f,%.1f dir=%d -> %s at %.1f,%.1f%s", b.dist, b.s.position.x, b.s.position.y,
      b.s.direction, w.type == "train-stop" and ("stop " .. w.backer_name) or w.type, w.position.x, w.position.y, wired > 0 and " WIRED" or ""))
  end
  return bad
end

script.on_nth_tick(337, function()
  if storage.sig_scanned4 then return end
  storage.sig_scanned4 = true
  SIGSCAN4()
end)

-- scan 5: block-based. Shortest forward path from the signal to the edge of its block (any
-- branch), or to a station in it whose trains don't fit.
function SIGSCAN5(fix)
  local surf = game.surfaces["freight"]
  local maxlen, station_len = 0, {}
  for _, t in pairs(game.train_manager.get_trains({ surface = surf })) do
    local along = 0
    for i = 2, #t.carriages do
      local a, c = t.carriages[i - 1].position, t.carriages[i].position
      along = along + math.sqrt((a.x - c.x) ^ 2 + (a.y - c.y) ^ 2)
    end
    local L = along + 6
    maxlen = math.max(maxlen, L)
    local ok, sch = pcall(function() return t.get_schedule() end)
    if ok and sch then
      for i = 1, sch.get_record_count() do
        local r = sch.get_record({ schedule_index = i })
        if r and r.station then station_len[r.station] = math.max(station_len[r.station] or 0, L) end
      end
    end
  end
  local stops = {}
  for _, st in pairs(surf.find_entities_filtered({ type = "train-stop" })) do
    if st.connected_rail then stops[st.connected_rail.unit_number] = st end
  end
  local function room(rail, tdir)
    local best, what = math.huge, nil
    local queue, head, seen = { { rail = rail, tdir = tdir, dist = rail.rail_length } }, 1, {}
    while queue[head] do
      local q = queue[head]; head = head + 1
      local key = q.rail.unit_number .. ":" .. q.tdir
      if not seen[key] and q.dist < best and q.dist < 200 then
        seen[key] = true
        local st = stops[q.rail.unit_number]
        if st and q.dist < (station_len[st.backer_name] or maxlen) and q.dist < best then best, what = q.dist, st end
        local any = false
        for _, c in pairs(CONNS) do
          local nr, ndir = q.rail.get_connected_rail({ rail_direction = q.tdir, rail_connection_direction = c })
          if nr then
            any = true
            if nr.is_rail_in_same_rail_block_as(q.rail) then
              table.insert(queue, { rail = nr, tdir = OPPD[ndir], dist = q.dist + nr.rail_length })
            elseif q.dist < best then
              best, what = q.dist, nr
            end
          end
        end
        if not any and not st and q.dist < best then best, what = q.dist, "dead end" end
      end
    end
    return best, what
  end
  local bad, nsig = {}, 0
  for _, s in pairs(surf.find_entities_filtered({ type = "rail-signal" })) do
    for _, r in pairs(s.get_connected_rails()) do
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        if SIG_IN(surf, r.get_rail_end(d)) == s then
          nsig = nsig + 1
          local junction = false
          for _, c in pairs(CONNS) do
            local prev = r.get_connected_rail({ rail_direction = d, rail_connection_direction = c })
            if prev then for _, ib in pairs(prev.get_inbound_signals()) do if ib.type == "rail-chain-signal" then junction = true end end end
          end
          local dist, what = room(r, OPPD[d])
          if dist < maxlen then
            table.insert(bad, { s = s, dist = dist, what = what, junction = junction })
          end
        end
      end
    end
  end
  local nbad = 0
  for _, b in ipairs(bad) do
    local w = b.what
    local wt = type(w) == "string" and w or (w.type == "train-stop" and ("stop " .. w.backer_name) or ("block edge at " .. w.position.x .. "," .. w.position.y))
    if b.junction then nbad = nbad + 1 end
    log(string.format("FDSIG5 %s %.1f tiles: signal at %.1f,%.1f -> %s", b.junction and "BAD" or "short-not-exit", b.dist, b.s.position.x, b.s.position.y, wt))
  end
  log(string.format("FDSIG5 %d rail signals, longest train %.1f tiles, %d junction exits too short", nsig, maxlen, nbad))
  return bad
end

script.on_nth_tick(353, function()
  if storage.sig_scanned5 then return end
  storage.sig_scanned5 = true
  SIGSCAN5()
end)
