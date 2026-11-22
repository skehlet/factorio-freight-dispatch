-- 0.7.5: no achievements while this mod is installed. The Spaceport's real silo launches
-- count as vanilla rocket launches, which awarded "Lazy bastard" and "Smoke me a kipper"
-- for a game that never crafted or built a factory. Steve asked for them all to be off.
-- Runs last so achievements added by other mods go too. (Factorio 2.0.43+ no longer touches
-- Steam achievements when a modded game deletes its achievement prototypes.)
for type_name, list in pairs(data.raw) do
  if type_name == "achievement" or type_name:find("%-achievement$") then
    for name in pairs(list) do list[name] = nil end
  end
end
