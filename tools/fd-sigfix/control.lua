-- One-off: junction exit rail signals whose block is shorter than the longest train become
-- chain signals, so two junctions too close together act as one and trains wait before the
-- first. Same detection as fd-debug's SIGSCAN5. Saves as "fd-sigfixed" (headless server).
local CONNS = { defines.rail_connection_direction.straight, defines.rail_connection_direction.left, defines.rail_connection_direction.right }
local OPPD = { [defines.rail_direction.front] = defines.rail_direction.back, [defines.rail_direction.back] = defines.rail_direction.front }

local function sig_at(surf, loc)
  if not loc then return nil end
  for _, s in pairs(surf.find_entities_filtered({ position = loc.position, radius = 0.3, type = { "rail-signal", "rail-chain-signal" } })) do
    if s.direction == loc.direction then return s end
  end
end
local function in_sig(surf, re)
  return sig_at(surf, re.in_signal_location) or sig_at(surf, re.alternative_in_signal_location)
end

local function scan(surf)
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
    local best = math.huge
    local queue, head, seen = { { rail = rail, tdir = tdir, dist = rail.rail_length } }, 1, {}
    while queue[head] do
      local q = queue[head]; head = head + 1
      local key = q.rail.unit_number .. ":" .. q.tdir
      if not seen[key] and q.dist < best and q.dist < 200 then
        seen[key] = true
        local st = stops[q.rail.unit_number]
        if st and q.dist < (station_len[st.backer_name] or maxlen) then best = math.min(best, q.dist) end
        local any = false
        for _, c in pairs(CONNS) do
          local nr, ndir = q.rail.get_connected_rail({ rail_direction = q.tdir, rail_connection_direction = c })
          if nr then
            any = true
            if nr.is_rail_in_same_rail_block_as(q.rail) then
              table.insert(queue, { rail = nr, tdir = OPPD[ndir], dist = q.dist + nr.rail_length })
            else
              best = math.min(best, q.dist)
            end
          end
        end
        if not any and not st then best = math.min(best, q.dist) end
      end
    end
    return best
  end
  local bad = {}
  for _, s in pairs(surf.find_entities_filtered({ type = "rail-signal" })) do
    for _, r in pairs(s.get_connected_rails()) do
      for _, d in pairs({ defines.rail_direction.front, defines.rail_direction.back }) do
        if in_sig(surf, r.get_rail_end(d)) == s then
          local junction = false
          for _, c in pairs(CONNS) do
            local prev = r.get_connected_rail({ rail_direction = d, rail_connection_direction = c })
            if prev then for _, ib in pairs(prev.get_inbound_signals()) do if ib.type == "rail-chain-signal" then junction = true end end end
          end
          local dist = room(r, OPPD[d])
          if junction and dist < maxlen then table.insert(bad, { s = s, dist = dist }) end
        end
      end
    end
  end
  return bad, maxlen
end

local function wired(s)
  for _, id in pairs({ defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green }) do
    local c = s.get_wire_connector(id, false)
    if c and #c.connections > 0 then return true end
  end
  return false
end

script.on_nth_tick(120, function()
  if storage.done then return end
  storage.done = true
  local surf = game.surfaces["freight"]
  local bad, maxlen = scan(surf)
  log(string.format("FDFIX found %d junction exits shorter than the longest train (%.1f tiles)", #bad, maxlen))
  local fixed = 0
  for _, b in ipairs(bad) do
    local s = b.s
    local pos, dir, force = s.position, s.direction, s.force
    if wired(s) then
      log(string.format("FDFIX skipped (wired) %.1f,%.1f", pos.x, pos.y))
    else
      s.destroy()
      local c = surf.create_entity({ name = "rail-chain-signal", position = pos, direction = dir, force = force })
      if c then
        fixed = fixed + 1
        log(string.format("FDFIX chain %.1f,%.1f dir=%d (block was %.1f tiles)", pos.x, pos.y, dir, b.dist))
      else
        surf.create_entity({ name = "rail-signal", position = pos, direction = dir, force = force })
        log(string.format("FDFIX FAILED, restored rail signal at %.1f,%.1f", pos.x, pos.y))
      end
    end
  end
  local after = scan(surf)
  log(string.format("FDFIX replaced %d; rescan finds %d left", fixed, #after))
  game.server_save("fd-sigfixed")
  log("FDFIX saved")
end)
