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
  local f = game.forces.player
  log("FDBAL circuit tech=" .. tostring(f.technologies["circuit-network"].researched) .. " decider recipe=" .. tostring(f.recipes["decider-combinator"].enabled) .. " box recipe=" .. tostring(f.recipes["fd-site-signals"].enabled) .. " rail recipe=" .. tostring(f.recipes["rail"].enabled))
end)

script.on_nth_tick(600, function()
  snap("+" .. math.floor((game.tick - (storage.start or 0)) / 60) .. "s")
end)
