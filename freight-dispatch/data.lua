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
      stack_size = 50,
    },
  })
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
})
-- A train's speed is capped by its slowest carriage. Vanilla wagons (1.5) would cap
-- Express fuel (locomotive 1.2 x 1.4 = 1.68). Vanilla trains never exceed 1.38, so
-- raising the wagon limit changes nothing in normal games.
for _, w in pairs(data.raw["cargo-wagon"] or {}) do
  if w.max_speed and w.max_speed < 2 then w.max_speed = 2 end
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
