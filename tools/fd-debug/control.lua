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

-- town layout check, 1 s after load (on_init runs BEFORE the main mod's on_configuration_changed)
script.on_nth_tick(60, function()
  if storage.towns_logged then return end
  storage.towns_logged = true
  local n = 0
  for _ in pairs(remote.call("freight_dispatch", "sites")) do n = n + 1 end
  log("FDSNAP sites=" .. n .. " " .. serpent.line(remote.call("freight_dispatch", "served")))
  local surf = game.surfaces["freight"]
  for _, s in pairs(remote.call("freight_dispatch", "sites")) do
    if s.delivered > 0 or s.shipped > 0 then
      log("FDSNAP served-ish " .. s.kind .. " " .. s.name .. " detail=" .. tostring(remote.call("freight_dispatch", "site_detail", s.id)))
    end
    if s.kind == "town" and s.delivered > 0 then
      local n = surf.count_entities_filtered({ area = { { s.x - 30, s.y - 30 }, { s.x + 30, s.y + 30 } }, name = { "fd-house", "fd-shop" } })
      log("FDSNAP town " .. s.name .. " pop=" .. math.floor(s.pop) .. " buildings=" .. s.building_count ..
        " entities=" .. n .. " radius=" .. tostring(s.radius))
    end
  end
end)

script.on_nth_tick(600, function()
  snap("+" .. math.floor((game.tick - (storage.start or 0)) / 60) .. "s")
end)
