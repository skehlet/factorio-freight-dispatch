-- Freight Dispatch: tuning values. Tweak freely.
local C = {}

C.SURFACE = "freight"
C.FORCE = "player"

C.START_MONEY = 300000
C.REFUND = 0.75            -- fraction refunded on deconstruction
C.CLEAR_FEE = 10           -- per tree/rock cleared
C.WAGON_RATE = 400         -- units loaded/unloaded per wagon per second
C.MIN_DIST = 60            -- cargo must travel at least this far to be paid
C.STOCK_CAP = 4000         -- per level, for industries
C.INPUT_CAP = 20000
C.SITE_CHANCE = 0.10       -- chance a newly generated chunk gets a site
C.SITE_MIN_DIST = 100
-- Clutter cap: new sites only appear while unserved sites (no train stop in their ring)
-- number fewer than max(SPARE_SITES_MIN, served sites x SPARE_SITES_RATIO).
C.SPARE_SITES_MIN = 6
C.SPARE_SITES_RATIO = 0.5
C.STUCK_TICKS = 3 * 60 * 60
C.TRAIN_SIGHT = 64         -- tiles revealed around each train (refreshed every 2 s)
C.STOP_SIGHT = 48          -- tiles kept live around each train stop (every 10 s)
C.SURVEY_PRICE = 5000      -- Shop "Land survey"
C.SURVEY_RADIUS = 256      -- reveals a 512 x 512 area around your view
C.CONTRACT_TICKS = 30 * 60 * 60
C.CONTRACT_GAP = 4 * 60 * 60

-- Shop prices (per item)
C.PRICES = {
  ["rail"] = 50,
  ["rail-signal"] = 150,
  ["rail-chain-signal"] = 200,
  ["train-stop"] = 1200,
  ["locomotive"] = 25000,
  ["cargo-wagon"] = 6000,
  ["landfill"] = 250,
  ["solid-fuel"] = 40,
  ["rocket-fuel"] = 300,
  ["nuclear-fuel"] = 2500,
  ["fd-express-fuel"] = 4000,
  ["car"] = 4000,
  ["small-lamp"] = 30,
}

C.SHOP = {
  { item = "rail", ghost = true, note = "Rail planner. Use Place, or lay ghosts in map view (M)." },
  { item = "rail-signal", ghost = true, note = "Splits track into blocks. Only one train per block." },
  { item = "rail-chain-signal", ghost = true, note = "Use at junction entries: shows red unless the exit is clear." },
  { item = "train-stop", ghost = true, note = "Build inside a site's ring to serve it." },
  { item = "locomotive", ghost = true, note = "Refuels itself automatically (you pay for fuel)." },
  { item = "cargo-wagon", ghost = true, note = "Carries cargo. Capacity depends on your wagon upgrade." },
  { item = "landfill", ghost = true, note = "Fill in water to build across lakes." },
}

-- Upgrades (Shop). Tier 1 is what you start with. Each applies to every train at once.
C.UPGRADES = {
  { id = "fuel", label = "Locomotive fuel", icon = "item/rocket-fuel", tiers = {
    { name = "Solid fuel", item = "solid-fuel", desc = "Acceleration x1.2, top speed x1.05" },
    { name = "Rocket fuel", item = "rocket-fuel", price = 2000000, desc = "Acceleration x1.8, top speed x1.15" },
    { name = "Nuclear fuel", item = "nuclear-fuel", price = 8000000, desc = "Acceleration x2.5, top speed x1.15" },
    { name = "Express fuel", item = "fd-express-fuel", price = 30000000, desc = "Acceleration x3, top speed x1.4" },
  } },
  { id = "wagons", label = "Cargo wagons", icon = "item/cargo-wagon", tiers = {
    { name = "Standard wagons", slots = 40, desc = "2,000 units per wagon" },
    { name = "Extended wagons", slots = 60, price = 3000000, desc = "3,000 units per wagon" },
    { name = "Double-deck wagons", slots = 80, price = 12000000, desc = "4,000 units per wagon" },
    { name = "Jumbo wagons", slots = 120, price = 40000000, desc = "6,000 units per wagon" },
  } },
  { id = "loading", label = "Station crews", icon = "item/fd-passengers", tiers = {
    { name = "Small crews", rate = 400, desc = "Loads 400 per wagon per second" },
    { name = "Full crews", rate = 600, price = 1000000, desc = "Loads 600 per wagon per second" },
    { name = "Double shifts", rate = 900, price = 5000000, desc = "Loads 900 per wagon per second" },
    { name = "Automated platforms", rate = 1400, price = 20000000, desc = "Loads 1,400 per wagon per second" },
  } },
  { id = "running", label = "Running shoes", icon = "item/exoskeleton-equipment", tiers = {
    { name = "Work boots", speed = 0, desc = "Normal running speed" },
    { name = "Trail runners", speed = 0.5, price = 500000, desc = "Run 50% faster" },
    { name = "Racing spikes", speed = 1, price = 3000000, desc = "Run twice as fast" },
    { name = "Rocket boots", speed = 2, price = 10000000, desc = "Run three times as fast" },
  } },
}

-- Cargo: rate = $ per unit per 100 tiles; decay = seconds after the grace period until pay is at its minimum
C.CARGO = {
  ["fd-passengers"] = { rate = 1.5, decay = 150, label = "Passengers" },
  ["fd-mail"]       = { rate = 2.5, decay = 200, label = "Mail" },
  ["fd-coal"]       = { rate = 1.0, decay = 1500, label = "Coal" },
  ["fd-iron-ore"]   = { rate = 1.0, decay = 1500, label = "Iron ore" },
  ["fd-wood"]       = { rate = 1.2, decay = 1000, label = "Lumber" },
  ["fd-steel"]      = { rate = 2.0, decay = 700, label = "Steel" },
  ["fd-goods"]      = { rate = 3.0, decay = 400, label = "Goods" },
}

-- population gained per unit delivered to a town
C.TOWN_GROWTH = {
  ["fd-passengers"] = 0.004,
  ["fd-mail"] = 0.01,
  ["fd-goods"] = 0.08,
}
-- Big-town slowdown: above this population, every source of town growth is scaled by
-- sqrt(GROWTH_REF / pop), so towns keep growing steadily instead of compounding without
-- limit (pop 4,000: x0.5, pop 16,000: x0.25). Before 0.2.2 a served town doubled about
-- every 70 minutes.
C.GROWTH_REF = 1000

C.KINDS = {
  ["town"] = {
    label = "Town", icon = "fd-passengers", radius = 22, color = { 1, 0.85, 0.35 },
    produces = { "fd-passengers", "fd-mail" }, accepts = { "fd-passengers", "fd-mail", "fd-goods" },
  },
  ["coal-mine"] = {
    label = "Coal Mine", icon = "fd-coal", radius = 18, color = { 0.75, 0.75, 0.8 },
    produces = { "fd-coal" }, accepts = {}, base = { ["fd-coal"] = 5 },
  },
  ["iron-mine"] = {
    label = "Iron Mine", icon = "fd-iron-ore", radius = 18, color = { 0.55, 0.75, 1 },
    produces = { "fd-iron-ore" }, accepts = {}, base = { ["fd-iron-ore"] = 5 },
  },
  ["forest"] = {
    label = "Lumber Camp", icon = "fd-wood", radius = 18, color = { 0.5, 0.9, 0.4 },
    produces = { "fd-wood" }, accepts = {}, base = { ["fd-wood"] = 4 },
  },
  ["steel-mill"] = {
    label = "Steel Mill", icon = "fd-steel", radius = 18, color = { 1, 0.55, 0.4 },
    produces = { "fd-steel" }, accepts = { "fd-iron-ore", "fd-coal" }, secondary = true,
    -- processes up to 25 x level of `main` per second; output per unit goes from base_yield
    -- to full_yield as `booster` is supplied (0.5 booster per main unit = full boost)
    main = "fd-iron-ore", booster = "fd-coal", base_yield = 0.5, full_yield = 1,
  },
  ["factory"] = {
    label = "Factory", icon = "fd-goods", radius = 18, color = { 0.5, 0.7, 1 },
    produces = { "fd-goods" }, accepts = { "fd-steel", "fd-wood" }, secondary = true,
    main = "fd-steel", booster = "fd-wood", base_yield = 1, full_yield = 2,
  },
  ["power-plant"] = {
    label = "Power Plant", icon = "fd-coal", radius = 18, color = { 1, 0.6, 1 },
    produces = {}, accepts = { "fd-coal" },
  },
}

C.KIND_ORDER = { "town", "coal-mine", "iron-mine", "forest", "steel-mill", "factory", "power-plant" }
C.KIND_WEIGHTS = {
  ["town"] = 32, ["coal-mine"] = 14, ["iron-mine"] = 14, ["forest"] = 11,
  ["steel-mill"] = 10, ["factory"] = 10, ["power-plant"] = 9,
}

-- shipped units needed to reach the next industry level
C.LEVEL_AT = { 8000, 24000, 60000, 140000 }

C.STARTERS = {
  { kind = "town", x = 40, y = -30, pop = 700 },
  { kind = "town", x = -230, y = 70, pop = 550 },
  { kind = "coal-mine", x = 190, y = 170 },
  { kind = "power-plant", x = -110, y = -210 },
}

C.TECHS = { "railway", "automated-rail-transportation", "rail-signals", "landfill", "automobilism", "lamp" }

C.RANKS = {
  { at = 0, title = "Track Layer" },
  { at = 250000, title = "Signal Apprentice" },
  { at = 1000000, title = "Dispatcher" },
  { at = 5000000, title = "Line Manager" },
  { at = 20000000, title = "Rail Baron" },
  { at = 100000000, title = "Railway Tycoon" },
}

C.NAME_PREFIX = {
  "Ash", "Brook", "Cedar", "Dun", "Elm", "Fair", "Glen", "Hart", "Iron", "Kings", "Lake", "Mill",
  "North", "Oak", "Pine", "Red", "Stone", "Thorn", "West", "Wood", "Black", "Silver", "Green",
  "High", "Cold", "Marsh", "Hollow", "Copper", "Wolf", "Raven", "East", "South", "Maple", "Birch",
}
C.NAME_SUFFIX = {
  "ford", "ton", "field", "bury", "wood", "dale", "ville", "port", "bridge", "haven", "stead",
  "wick", "moor", "ham", "creek", "gate", "hill", "mouth", "by", "worth",
}

return C
