-- Freight Dispatch: prototypes

data:extend({
  {
    type = "item-group",
    name = "freight-dispatch",
    order = "z-fd",
    icon = "__base__/graphics/icons/locomotive.png",
    icon_size = 64,
  },
  { type = "item-subgroup", name = "fd-cargo", group = "freight-dispatch", order = "a" },
})

-- Cargo items -----------------------------------------------------------------

local cargo = {
  { name = "fd-passengers", icon = "__core__/graphics/icons/entity/character.png", order = "a" },
  { name = "fd-mail",       icon = "__freight-dispatch__/graphics/mail.png",       order = "b" },
  { name = "fd-coal",       icon = "__base__/graphics/icons/coal.png",             order = "c" },
  { name = "fd-iron-ore",   icon = "__base__/graphics/icons/iron-ore.png",         order = "d" },
  { name = "fd-wood",       icon = "__base__/graphics/icons/wood.png",             order = "e" },
  { name = "fd-steel",      icon = "__base__/graphics/icons/steel-plate.png",      order = "f" },
  { name = "fd-goods",      icon = "__base__/graphics/icons/iron-chest.png",       order = "g" },
}

for _, c in pairs(cargo) do
  data:extend({
    {
      type = "item",
      name = c.name,
      -- small locomotive badge (bottom right) so these never look like the vanilla item with
      -- the same picture (wood, coal, iron ore, steel plate, blueprint, iron chest), which matters
      -- when picking a signal for a circuit condition
      icons = {
        { icon = c.icon, icon_size = 64 },
        { icon = "__base__/graphics/icons/locomotive.png", icon_size = 64, scale = 0.25, shift = { 8, 8 } },
      },
      subgroup = "fd-cargo",
      order = c.order,
      stack_size = 50, -- passengers and mail: set below (0.9.8)
      -- 0.7.3: listed in wagon slot filters (middle click). Filter pickers only show unlocked
      -- items, and these have no recipe, so without this they never appear there.
      flags = { "always-show" },
    },
  })
end

-- 0.9.0: passengers and mail bound for destination N (a town, or after the towns a Spaceport).
-- A coloured disc (graphics/dest/disc.png tinted per destination), the cargo picture and the
-- number. Each kind gets its own row in the item picker.
local C = require("scripts.config")
-- 0.9.8: passengers and mail come in smaller numbers (C.TOWN_SCALE), so a stack holds 5
for b in pairs(C.TOWN_CARGO) do data.raw.item[b].stack_size = 50 / C.TOWN_SCALE end
data:extend({
  { type = "item-subgroup", name = "fd-dest-passengers", group = "freight-dispatch", order = "b" },
  { type = "item-subgroup", name = "fd-dest-mail", group = "freight-dispatch", order = "c" },
})
local dest_pictures = {
  -- 0.10.0: picture up and to the right, number bottom left (the item count is bottom right)
  ["fd-passengers"] = { icon = "__core__/graphics/icons/entity/character.png", scale = 0.34, shift = { 3, -4 } },
  ["fd-mail"] = { icon = "__freight-dispatch__/graphics/mail.png", scale = 0.3, shift = { 3, -5 } },
}
for n = 1, C.DESTS do
  local col = C.DEST_COLORS[n]
  local pad = n > C.DEST_TOWNS
  for _, b in pairs(C.DEST_BASES) do
    local pic = dest_pictures[b]
    local short = b == "fd-passengers" and "passengers" or "mail"
    data:extend({
      {
        type = "item",
        name = C.variant(b, n),
        localised_name = { "item-name.fd-" .. short .. (pad and "-pad" or "-dest"), tostring(pad and (n - C.DEST_TOWNS) or n) },
        localised_description = { "item-description.fd-dest" },
        icons = {
          { icon = "__freight-dispatch__/graphics/dest/disc.png", icon_size = 64, tint = { col[1] / 255, col[2] / 255, col[3] / 255, 1 } },
          { icon = pic.icon, icon_size = 64, scale = pic.scale, shift = pic.shift },
          { icon = "__freight-dispatch__/graphics/dest/num-" .. n .. ".png", icon_size = 64 },
        },
        subgroup = "fd-dest-" .. short,
        order = string.format("%02d", n),
        stack_size = 50 / C.TOWN_SCALE, -- 0.9.8: 5
        flags = { "always-show" },
      },
    })
  end
end

-- Top fuel upgrade tier (Shop > Upgrades). Never craftable: there is no recipe.
data:extend({
  {
    type = "item",
    name = "fd-express-fuel",
    icons = { { icon = "__base__/graphics/icons/nuclear-fuel.png", icon_size = 64, tint = { 0.55, 0.85, 1, 1 } } },
    subgroup = "fd-cargo",
    order = "z",
    fuel_categories = { "chemical" },
    fuel_value = "2GJ",
    fuel_acceleration_multiplier = 3,
    fuel_top_speed_multiplier = 1.4,
    stack_size = 10,
  },
  -- 0.8.2: two more fuel tiers, unlocked after the first rocket
  {
    type = "item",
    name = "fd-plasma-fuel",
    icons = { { icon = "__base__/graphics/icons/nuclear-fuel.png", icon_size = 64, tint = { 1, 0.55, 1, 1 } } },
    subgroup = "fd-cargo",
    order = "z2",
    fuel_categories = { "chemical" },
    fuel_value = "3GJ",
    fuel_acceleration_multiplier = 3.5,
    fuel_top_speed_multiplier = 1.55,
    stack_size = 10,
  },
  {
    type = "item",
    name = "fd-antimatter-fuel",
    icons = { { icon = "__base__/graphics/icons/nuclear-fuel.png", icon_size = 64, tint = { 1, 0.85, 0.35, 1 } } },
    subgroup = "fd-cargo",
    order = "z3",
    fuel_categories = { "chemical" },
    fuel_value = "5GJ",
    fuel_acceleration_multiplier = 4,
    fuel_top_speed_multiplier = 1.7,
    stack_size = 10,
  },
})
-- A train's speed is capped by its slowest carriage. Vanilla wagons (1.5) would cap
-- Express fuel (locomotive 1.2 x 1.4 = 1.68), and since 0.8.2 Antimatter fuel reaches
-- 1.2 x 1.7 = 2.04. Vanilla trains never exceed 1.38, so raising the wagon limit changes
-- nothing in normal games.
for _, w in pairs(data.raw["cargo-wagon"] or {}) do
  if w.max_speed and w.max_speed < 2.1 then w.max_speed = 2.1 end
end

-- Site buildings (decorative, indestructible) ---------------------------------

local function as_animation(t)
  if type(t) ~= "table" then return nil end
  if t.layers or t.filename or t.filenames or t.stripes then return table.deepcopy(t) end
  if t.north then return as_animation(t.north) end
  return nil
end

local function get(path_fn)
  local ok, result = pcall(path_fn)
  if ok then return as_animation(result) end
  return nil
end

local fallback_picture = {
  layers = {
    {
      filename = "__base__/graphics/entity/iron-chest/iron-chest.png",
      width = 66, height = 76, scale = 1.25,
      shift = util.by_pixel(-0.5, -0.5),
    },
  },
}

local buildings = {
  { name = "fd-house",    size = 3, color = { 0.95, 0.8, 0.3 },
    anim = get(function() return data.raw["lab"]["lab"].on_animation end) },
  { name = "fd-shop",     size = 3, color = { 0.95, 0.8, 0.3 },
    anim = get(function() return data.raw["assembling-machine"]["assembling-machine-1"].graphics_set.animation end) },
  { name = "fd-drill",    size = 3, color = { 0.55, 0.55, 0.6 },
    anim = get(function() return data.raw["mining-drill"]["electric-mining-drill"].graphics_set.animation end) },
  { name = "fd-furnace",  size = 2, color = { 0.8, 0.4, 0.3 },
    anim = get(function() return data.raw["furnace"]["steel-furnace"].graphics_set.animation end) },
  { name = "fd-factory",  size = 3, color = { 0.4, 0.6, 0.95 },
    anim = get(function() return data.raw["assembling-machine"]["assembling-machine-2"].graphics_set.animation end) },
  { name = "fd-sawmill",  size = 3, color = { 0.45, 0.75, 0.35 },
    anim = get(function() return data.raw["assembling-machine"]["assembling-machine-1"].graphics_set.animation end) },
  { name = "fd-generator", w = 3, h = 5, color = { 0.9, 0.5, 0.9 },
    anim = get(function() return data.raw["generator"]["steam-engine"].vertical_animation end) },
}

for _, b in pairs(buildings) do
  local w = (b.w or b.size) / 2 - 0.1
  local h = (b.h or b.size) / 2 - 0.1
  local proto = {
    type = "simple-entity-with-owner",
    name = b.name,
    icon = "__base__/graphics/icons/market.png",
    icon_size = 64,
    flags = { "placeable-neutral", "not-blueprintable", "not-deconstructable", "not-upgradable", "not-flammable" },
    hidden = true,
    max_health = 1000,
    render_layer = "object",
    collision_box = { { -w, -h }, { w, h } },
    selection_box = { { -w - 0.1, -h - 0.1 }, { w + 0.1, h + 0.1 } },
    map_color = b.color,
  }
  if b.anim then
    proto.animations = b.anim
  else
    proto.picture = fallback_picture
  end
  data:extend({ proto })
end

-- Spaceport (0.7.0): the vanilla rocket silo's picture with its doors shut, and the rocket
-- itself as a sprite for the launch animation. Decorative like the other site buildings.
do
  local silo = data.raw["rocket-silo"] and data.raw["rocket-silo"]["rocket-silo"]
  local layers = {}
  if silo then
    for _, key in pairs({ "hole_sprite", "door_back_sprite", "door_front_sprite", "base_day_sprite" }) do
      local sp = silo[key]
      if type(sp) == "table" and (sp.filename or sp.layers) then
        if sp.layers then
          for _, l in pairs(sp.layers) do table.insert(layers, table.deepcopy(l)) end
        else
          table.insert(layers, table.deepcopy(sp))
        end
      end
    end
  end
  -- 0.7.4: a real rocket silo (no power needed, nothing to craft) so the engine plays its own
  -- sequence: lights, doors opening, the rocket rising out of the hole, launch, doors closing.
  -- The script sets rocket_parts from the assembly progress and calls launch_rocket().
  if silo then
    local rs = table.deepcopy(silo)
    rs.name = "fd-spaceport-silo"
    rs.flags = { "placeable-neutral", "not-blueprintable", "not-deconstructable", "not-upgradable", "not-flammable" }
    rs.hidden = true
    rs.minable = nil
    rs.fast_replaceable_group = nil
    rs.next_upgrade = nil
    rs.energy_source = { type = "void" }
    rs.module_slots = 0
    rs.allowed_effects = {}
    rs.icons_positioning = nil
    rs.placeable_by = nil
    rs.map_color = { 0.6, 0.9, 1 }
    rs.corpse = nil
    rs.dying_explosion = nil
    data:extend({ rs })
  end
  data:extend({
    {
      type = "simple-entity-with-owner",
      name = "fd-silo",
      icon = "__base__/graphics/icons/rocket-silo.png",
      icon_size = 64,
      flags = { "placeable-neutral", "not-blueprintable", "not-deconstructable", "not-upgradable", "not-flammable" },
      hidden = true,
      max_health = 1000,
      render_layer = "object",
      collision_box = { { -4.4, -4.4 }, { 4.4, 4.4 } },
      selection_box = { { -4.5, -4.5 }, { 4.5, 4.5 } },
      map_color = { 0.6, 0.9, 1 },
      picture = #layers > 0 and { layers = layers } or fallback_picture,
    },
  })
  local rocket = data.raw["rocket-silo-rocket"] and data.raw["rocket-silo-rocket"]["rocket-silo-rocket"]
  if rocket and rocket.rocket_sprite then
    local sp = table.deepcopy(rocket.rocket_sprite)
    sp.type = "sprite"
    sp.name = "fd-rocket"
    data:extend({ sp })
  end
end

-- Site signals (Shop): a constant combinator the mod fills every second with the stockpile
-- of the site whose ring it stands in. Wire it to train stops or rail signals.
-- Constant combinators, train stops and rail signals need no power, which suits this world.
do
  local cc = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
  local icons = { { icon = "__base__/graphics/icons/constant-combinator.png", icon_size = 64, tint = { 1, 0.85, 0.45, 1 } } }
  cc.name = "fd-site-signals"
  cc.icon = nil
  cc.icons = icons
  cc.minable = { mining_time = 0.1, result = "fd-site-signals" }
  cc.fast_replaceable_group = nil
  cc.next_upgrade = nil
  data:extend({
    cc,
    {
      type = "item",
      name = "fd-site-signals",
      icons = icons,
      subgroup = "fd-cargo",
      order = "y",
      place_result = "fd-site-signals",
      stack_size = 50,
    },
    -- the recipe only exists so the Shop's ghosts can be placed; nobody has the ingredients
    {
      type = "recipe",
      name = "fd-site-signals",
      enabled = false,
      ingredients = { { type = "item", name = "electronic-circuit", amount = 5 } },
      results = { { type = "item", name = "fd-site-signals", amount = 1 } },
    },
  })
end

-- Decider combinator that needs no power (Shop). This world has no electricity, so the
-- vanilla one stays locked. Same GUI and behaviour: several conditions with AND/OR.
do
  local dc = table.deepcopy(data.raw["decider-combinator"]["decider-combinator"])
  local icons = { { icon = "__base__/graphics/icons/decider-combinator.png", icon_size = 64, tint = { 1, 0.85, 0.45, 1 } } }
  dc.name = "fd-decider"
  dc.icon = nil
  dc.icons = icons
  dc.minable = { mining_time = 0.1, result = "fd-decider" }
  dc.energy_source = { type = "void" }
  dc.fast_replaceable_group = nil
  dc.next_upgrade = nil
  data:extend({
    dc,
    { type = "item", name = "fd-decider", icons = icons, subgroup = "fd-cargo", order = "y2", place_result = "fd-decider", stack_size = 50 },
    { type = "recipe", name = "fd-decider", enabled = false,
      ingredients = { { type = "item", name = "electronic-circuit", amount = 5 } },
      results = { { type = "item", name = "fd-decider", amount = 1 } } },
  })
end

-- Arithmetic combinator that needs no power (Shop, 0.8.3). Steve wanted stop priority to follow
-- waiting passengers, but priority only goes to 255, so the count has to be divided down first.
do
  local ac = table.deepcopy(data.raw["arithmetic-combinator"]["arithmetic-combinator"])
  local icons = { { icon = "__base__/graphics/icons/arithmetic-combinator.png", icon_size = 64, tint = { 1, 0.85, 0.45, 1 } } }
  ac.name = "fd-arithmetic"
  ac.icon = nil
  ac.icons = icons
  ac.minable = { mining_time = 0.1, result = "fd-arithmetic" }
  ac.energy_source = { type = "void" }
  ac.fast_replaceable_group = nil
  ac.next_upgrade = nil
  data:extend({
    ac,
    { type = "item", name = "fd-arithmetic", icons = icons, subgroup = "fd-cargo", order = "y3", place_result = "fd-arithmetic", stack_size = 50 },
    { type = "recipe", name = "fd-arithmetic", enabled = false,
      ingredients = { { type = "item", name = "electronic-circuit", amount = 5 } },
      results = { { type = "item", name = "fd-arithmetic", amount = 1 } } },
  })
end

-- Selector combinator that needs no power (Shop, 0.9.3). Steve's wildcard interrupts pick the
-- FIRST destination item over a threshold (lowest town number), not the biggest, so far towns
-- starved. Stop reads train contents -> selector "max" -> arithmetic "+1,000,000" -> stop with
-- "Send to train" -> interrupt "circuit [item wildcard] > 500,000" sends it where most riders go.
do
  local sc = table.deepcopy(data.raw["selector-combinator"]["selector-combinator"])
  local icons = { { icon = "__base__/graphics/icons/selector-combinator.png", icon_size = 64, tint = { 1, 0.85, 0.45, 1 } } }
  sc.name = "fd-selector"
  sc.icon = nil
  sc.icons = icons
  sc.minable = { mining_time = 0.1, result = "fd-selector" }
  sc.energy_source = { type = "void" }
  sc.fast_replaceable_group = nil
  sc.next_upgrade = nil
  data:extend({
    sc,
    { type = "item", name = "fd-selector", icons = icons, subgroup = "fd-cargo", order = "y4", place_result = "fd-selector", stack_size = 50 },
    { type = "recipe", name = "fd-selector", enabled = false,
      ingredients = { { type = "item", name = "electronic-circuit", amount = 5 } },
      results = { { type = "item", name = "fd-selector", amount = 1 } } },
  })
end

-- Map memory (0.7.6): an invisible radar that needs no power and keeps the chunks around it
-- live on the map (no fog of war). The script places one per block of charted land, so
-- anything you've seen once stays visible. It scans nothing farther out, so it never
-- explores or generates new land by itself.
do
  local empty = { filename = "__core__/graphics/empty.png", width = 1, height = 1, direction_count = 1 }
  data:extend({
    {
      type = "radar",
      name = "fd-eye",
      icon = "__base__/graphics/icons/radar.png",
      flags = { "placeable-off-grid", "not-on-map", "not-blueprintable", "not-deconstructable", "not-upgradable",
        "not-flammable", "not-repairable", "not-in-kill-statistics", "no-automated-item-removal", "no-automated-item-insertion" },
      hidden = true,
      selectable_in_game = false,
      max_health = 1000,
      collision_box = { { -0.1, -0.1 }, { 0.1, 0.1 } },
      collision_mask = { layers = {} },
      energy_source = { type = "void" },
      energy_usage = "1kW",
      energy_per_sector = "1MJ",
      max_distance_of_sector_revealed = 0,
      max_distance_of_nearby_sector_revealed = 2,
      energy_per_nearby_scan = "1J",
      connects_to_other_radars = false,
      is_military_target = false,
      pictures = empty,
    },
  })
end
