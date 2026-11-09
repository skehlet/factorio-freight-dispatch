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
end)

script.on_nth_tick(600, function()
  snap("+" .. math.floor((game.tick - (storage.start or 0)) / 60) .. "s")
end)
