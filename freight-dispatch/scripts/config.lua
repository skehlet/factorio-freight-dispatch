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
-- Site spacing (0.4.0; was 100 for everything, which packed the map at ~115 tiles apart).
-- 0.7.2 (Steve: "increase some more"): everything spread x1.4 (was 180 / 300).
C.SITE_MIN_DIST = 250      -- any two sites
C.TOWN_MIN_DIST = 420      -- any two towns
-- Founding (0.4.0): new sites are no longer rolled per generated chunk. Whenever unserved
-- sites (no train stop in their ring) number fewer than max(SPARE_SITES_MIN, served x
-- SPARE_SITES_RATIO), one new site is founded on purpose: a kind the map is short of,
-- FOUND_MIN..FOUND_MAX tiles from one of your served sites, at most once per FOUND_GAP.
C.SPARE_SITES_MIN = 6
C.SPARE_SITES_RATIO = 0.5
C.FOUND_MIN = 280          -- 0.7.2: was 200
C.FOUND_MAX = 700          -- 0.7.2: was 500
C.FOUND_GAP = 30 * 60
-- Supply-chain order for founding (0.4.6, Steve asked: he had spare iron, steel and factories
-- but no lumber camp to connect). The first tier with a kind that has no unserved site gets
-- that kind next. Tiers marked `basic` are founded even when the spare-site cap is full, so
-- the raw materials are always on offer. Once every tier has a spare, the weighted pick runs.
C.FOUND_TIERS = {
  { kinds = { "coal-mine", "forest" }, basic = true },
  { kinds = { "iron-mine", "power-plant" }, basic = true },
  { kinds = { "town" }, basic = true }, -- 0.4.7: always one town to connect (Steve: towns felt scarce)
  { kinds = { "steel-mill" } },
  { kinds = { "factory" } },
}
C.STUCK_TICKS = 3 * 60 * 60
-- Supply chain window (0.5.0): rates are averages over the last FLOW_MINUTES minutes. A consumer
-- counts as short when it spends more than CHAIN_SHORT of its time short of an input.
C.FLOW_MINUTES = 10
C.CHAIN_SHORT = 0.10
C.TRAIN_SIGHT = 64         -- tiles revealed around each train (refreshed every 2 s)
C.STOP_SIGHT = 48          -- tiles kept live around each train stop (every 10 s)
C.SURVEY_PRICE = 5000      -- Shop "Land survey"
C.SURVEY_RADIUS = 256      -- reveals a 512 x 512 area around your view
C.CONTRACT_TICKS = 30 * 60 * 60
C.CONTRACT_GAP = 4 * 60 * 60
C.CONTRACT_INCOME_MINS = 3 -- 0.7.8: a reward is at least this many minutes of recent income

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
  ["fd-plasma-fuel"] = 6000,     -- 0.8.2
  ["fd-antimatter-fuel"] = 9000, -- 0.8.2
  ["car"] = 4000,
  ["small-lamp"] = 30,
  ["fd-site-signals"] = 2000,
  ["fd-decider"] = 5000,
}

C.SHOP = {
  { item = "rail", ghost = true, note = "Rail planner. Use Place, or lay ghosts in map view (M)." },
  { item = "rail-signal", ghost = true, note = "Splits track into blocks. Only one train per block." },
  { item = "rail-chain-signal", ghost = true, note = "Use at junction entries: shows red unless the exit is clear." },
  { item = "train-stop", ghost = true, note = "Build inside a site's ring to serve it." },
  { item = "locomotive", ghost = true, note = "Refuels itself automatically (you pay for fuel)." },
  { item = "cargo-wagon", ghost = true, note = "Carries cargo. Capacity depends on your wagon upgrade." },
  { item = "landfill", ghost = true, note = "Fill in water to build across lakes." },
  { item = "fd-site-signals", ghost = true, note = "Build in a site's ring: outputs its stockpile as circuit signals. Wire it to a stop or rail signal (see Help)." },
  { item = "fd-decider", ghost = true, note = "Needs no power. Combine conditions with AND/OR, e.g. Steel > 15000 OR Lumber < 1000 (see Help)." },
}

-- Upgrades (Shop). Tier 1 is what you start with. Each applies to every train at once.
-- 0.8.2 (Steve): two more tiers per line, each with `rockets = 1`: buyable only once the first
-- rocket has launched. Priced as an end game cash sink (about $230M for all eight, against
-- about $3M/min income at that stage).
C.UPGRADES = {
  { id = "fuel", label = "Locomotive fuel", icon = "item/rocket-fuel", tiers = {
    { name = "Solid fuel", item = "solid-fuel", desc = "Acceleration x1.2, top speed x1.05" },
    { name = "Rocket fuel", item = "rocket-fuel", price = 2000000, desc = "Acceleration x1.8, top speed x1.15" },
    { name = "Nuclear fuel", item = "nuclear-fuel", price = 8000000, desc = "Acceleration x2.5, top speed x1.15" },
    { name = "Express fuel", item = "fd-express-fuel", price = 12000000, desc = "Acceleration x3, top speed x1.4" },
    { name = "Plasma fuel", item = "fd-plasma-fuel", price = 30000000, rockets = 1, desc = "Acceleration x3.5, top speed x1.55" },
    { name = "Antimatter fuel", item = "fd-antimatter-fuel", price = 60000000, rockets = 1, desc = "Acceleration x4, top speed x1.7" },
  } },
  { id = "wagons", label = "Cargo wagons", icon = "item/cargo-wagon", tiers = {
    { name = "Standard wagons", slots = 40, desc = "2,000 units per wagon" },
    { name = "Extended wagons", slots = 60, price = 3000000, desc = "3,000 units per wagon" },
    { name = "Double-deck wagons", slots = 80, price = 12000000, desc = "4,000 units per wagon" },
    { name = "Jumbo wagons", slots = 120, price = 15000000, desc = "6,000 units per wagon" },
    { name = "Articulated wagons", slots = 160, price = 25000000, rockets = 1, desc = "8,000 units per wagon" },
    { name = "Superfreighter wagons", slots = 200, price = 50000000, rockets = 1, desc = "10,000 units per wagon" },
  } },
  { id = "loading", label = "Station crews", icon = "item/fd-passengers", tiers = {
    { name = "Small crews", rate = 400, desc = "Loads 400 per wagon per second" },
    { name = "Full crews", rate = 600, price = 1000000, desc = "Loads 600 per wagon per second" },
    { name = "Double shifts", rate = 900, price = 5000000, desc = "Loads 900 per wagon per second" },
    { name = "Automated platforms", rate = 1400, price = 8000000, desc = "Loads 1,400 per wagon per second" },
    { name = "Robotic loaders", rate = 2000, price = 15000000, rockets = 1, desc = "Loads 2,000 per wagon per second" },
    { name = "Gravity chutes", rate = 3000, price = 30000000, rockets = 1, desc = "Loads 3,000 per wagon per second" },
  } },
  { id = "running", label = "Running shoes", icon = "item/exoskeleton-equipment", tiers = {
    { name = "Work boots", speed = 0, desc = "Normal running speed" },
    { name = "Trail runners", speed = 0.5, price = 500000, desc = "Run 50% faster" },
    { name = "Racing spikes", speed = 1, price = 3000000, desc = "Run twice as fast" },
    { name = "Rocket boots", speed = 2, price = 4000000, desc = "Run three times as fast" },
    { name = "Jet boots", speed = 3, price = 8000000, rockets = 1, desc = "Run four times as fast" },
    { name = "Warp boots", speed = 5, price = 16000000, rockets = 1, desc = "Run six times as fast" },
  } },
}

-- Cargo: rate = $ per unit per 100 tiles; decay = seconds after the grace period until pay is at its minimum
C.CARGO = {
  ["fd-passengers"] = { rate = 3.0, decay = 150, label = "Passengers" },
  ["fd-mail"]       = { rate = 3.5, decay = 200, label = "Mail" },
  ["fd-coal"]       = { rate = 1.0, decay = 1500, label = "Coal" },
  ["fd-iron-ore"]   = { rate = 1.0, decay = 1500, label = "Iron ore" },
  ["fd-wood"]       = { rate = 1.2, decay = 1000, label = "Lumber" },
  ["fd-steel"]      = { rate = 3.0, decay = 700, label = "Steel" },
  ["fd-goods"]      = { rate = 3.5, decay = 400, label = "Goods" },
}

-- Towns grow ONLY from goods (0.3.0). Passengers and mail are steady income, not growth.
-- 0.6.0 rebalance (Steve, after a 10.9 h game where goods made 56% of income and towns hit
-- 5,500 pop with 60-90k passengers waiting): goods 5.0 -> 3.5, passengers 1.5 -> 3.0 but made
-- at pop/120 (was pop/60), mail 2.5 -> 3.5, growth cost GOODS_PER_RESIDENT 50 -> 100 with
-- exponent GROWTH_EXP 1.5 (was linear), starter towns 700/550 -> 1000/800, and the top upgrade
-- tiers cheaper (Express 30M -> 12M, Jumbo 40M -> 15M, Automated 20M -> 8M, Rocket boots 10M -> 4M).
-- Goods per new resident = GOODS_PER_RESIDENT x max(1, pop / 1000) ^ GROWTH_EXP: 100 at
-- 1,000 pop, 283 at 2,000, 1,118 at 5,000. A town needs ~216k goods to reach 2,000, ~613k
-- for 3,000 and ~2.2M for 5,000 (before 0.6.0: 90k, 215k, 615k).
-- (0.3.0 to 0.5.x used 50 x max(1, pop / 1000), linear. Before 0.3.0 passengers, mail and plain service all compounded growth, and a playtest
-- reached 96k-pop towns.)
C.GOODS_PER_RESIDENT = 100
C.GROWTH_EXP = 1.5
C.PAX_PER_POP = 120          -- a town makes pop / PAX_PER_POP passengers per second (was 60)
C.INCOME_LOG_TICKS = 10 * 60 * 60 -- earnings by cargo are snapshotted this often (storage.income_log)
-- town cargo (everything else counts as freight, e.g. for contract weighting and size)
C.TOWN_CARGO = { ["fd-passengers"] = true, ["fd-mail"] = true }

-- Primary industries: output = base x (1 + LEVEL_BONUS x (level - 1)) x service.
-- Secondary industries process up to PROCESS_RATE x level of their main input per second.
C.LEVEL_BONUS = 1.0
C.PROCESS_RATE = 50

C.KINDS = {
  ["town"] = {
    label = "Town", icon = "fd-passengers", radius = 22, color = { 1, 0.85, 0.35 },
    produces = { "fd-passengers", "fd-mail" }, accepts = { "fd-passengers", "fd-mail", "fd-goods" },
  },
  ["coal-mine"] = {
    label = "Coal Mine", icon = "fd-coal", radius = 18, color = { 0.75, 0.75, 0.8 },
    produces = { "fd-coal" }, accepts = {}, base = { ["fd-coal"] = 12 },
  },
  ["iron-mine"] = {
    label = "Iron Mine", icon = "fd-iron-ore", radius = 18, color = { 0.55, 0.75, 1 },
    produces = { "fd-iron-ore" }, accepts = {}, base = { ["fd-iron-ore"] = 12 },
  },
  ["forest"] = {
    label = "Lumber Camp", icon = "fd-wood", radius = 18, color = { 0.5, 0.9, 0.4 },
    produces = { "fd-wood" }, accepts = {}, base = { ["fd-wood"] = 10 },
  },
  ["steel-mill"] = {
    label = "Steel Mill", icon = "fd-steel", radius = 18, color = { 1, 0.55, 0.4 },
    produces = { "fd-steel" }, accepts = { "fd-iron-ore", "fd-coal" }, secondary = true,
    -- processes up to PROCESS_RATE x level of `main` per second; output per unit goes from base_yield
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
    produces = {}, accepts = { "fd-coal", "fd-wood" },
  },
  -- 0.7.0 end game: founded once at Railway Tycoon (C.PAD_RANK). Not in KIND_ORDER, KIND_WEIGHTS or
  -- FOUND_TIERS, so normal founding never picks it.
  ["spaceport"] = {
    label = "Spaceport", icon = "rocket-silo", radius = 22, color = { 0.6, 0.9, 1 },
    produces = {}, accepts = { "fd-passengers", "fd-mail", "fd-goods" },
  },
}

-- Spaceport (0.7.0, Steve's end game): a rocket needs colonists (passengers), mail and (0.7.1)
-- goods as cargo delivered
-- by train (normal fares) and cash, paid as the cargo arrives (0.7.7; at most cost / build_secs
-- per second) and paused while cash is at or below the reserve the player sets. It launches when all three are done; the next one
-- starts at once. The pad levels up from launches (level N from launch level_at[N-1] + 1), and
-- each launch adds `satellite` to every fare, up to `satellite_cap`.
C.SPACEPORT = {
  -- 0.7.7 (Steve, at 11 launches: the pad was full with 5 min still on the clock, so trains
  -- made no difference): assembly follows the cargo. Cash is paid only up to the share of cargo
  -- aboard, and at most cost / build_secs per second, so a rocket launches as soon as it's loaded
  -- and paid, but never in under 3 min. Cargo is 2x to 2.5x the 0.7.1 amounts (L5 goods are about
  -- 85% of a level-5 factory's output at the 3 min pace) and cost is lower, since launches can
  -- now come every 3 to 5 min instead of 10 (his end game income was about $2.5M/min).
  -- 0.7.1: build_secs 10 min (was 15); mail half the colonists; goods added.
  build_secs = 3 * 60,
  levels = {
    { colonists = 4000, mail = 2000, goods = 24000, cost = 4000000 },
    { colonists = 6000, mail = 3000, goods = 36000, cost = 5000000 },
    { colonists = 8000, mail = 4000, goods = 48000, cost = 6000000 },
    { colonists = 10000, mail = 5000, goods = 60000, cost = 7000000 },
    { colonists = 12000, mail = 6000, goods = 72000, cost = 8000000 },
  },
  level_at = { 3, 8, 15, 25 }, -- launches done to reach level 2, 3, 4, 5
  -- 0.7.8 (Steve): satellites multiply town passengers and mail and power plant supply radius
  -- instead of fares. 1% per launch (was 2%) because rockets now come about twice as often.
  satellite = 0.01,
  satellite_cap = 0.5,         -- reached at 50 launches
  -- 0.7.8: more Spaceports from the Shop after the free first one; doubling after the list
  buy_prices = { 25000000, 50000000, 100000000 },
  pad_min_dist = 700,          -- tiles between Spaceports
  reserves = { 0, 1000000, 2000000, 5000000, 10000000, 25000000, 50000000 },
  default_reserve = 3,         -- index into reserves ($2M)
}

C.KIND_ORDER = { "town", "coal-mine", "iron-mine", "forest", "steel-mill", "factory", "power-plant" }
C.KIND_WEIGHTS = {
  ["town"] = 18, ["coal-mine"] = 14, ["iron-mine"] = 14, ["forest"] = 11,
  ["steel-mill"] = 10, ["factory"] = 10, ["power-plant"] = 9,
}

-- Power plants (0.4.1): burn delivered fuel and power every other site within their supply
-- radius while the fuel pile isn't empty. A site takes the bonus from one plant at most.
C.POWER = {
  fuel = { ["fd-coal"] = 1, ["fd-wood"] = 0.5 }, -- fuel value per unit (lumber counts half)
  burn = 15,             -- fuel burnt per second while running
  cap = 18000,           -- fuel pile: 20 minutes of running
  radius = 350,          -- supply radius at level 1 (0.7.2: was 250, scaled with site spacing)
  radius_per_level = 35, -- level 5: 490 tiles (was 25 / 350). Plants level up from fuel burnt (LEVEL_AT).
  bonus = 0.25,          -- powered towns: +25% passengers and mail, and 25% more growth per good;
                         -- primary industries +25% output; mills and factories +25% processing
}

-- shipped units needed to reach the next industry level
C.LEVEL_AT = { 20000, 60000, 150000, 350000 }

-- Starting sites: a full goods chain around spawn. The whole layout is rotated by a random
-- angle per map, and each site moves to the nearest dry spot that keeps the spacing rules.
-- 0.7.2: the 0.4.0 layout scaled x1.4 (reaches about 560 tiles from spawn).
C.STARTERS = {
  { kind = "town", x = 56, y = -42, pop = 1000 },
  { kind = "town", x = -406, y = 126, pop = 800 },
  { kind = "coal-mine", x = 266, y = 238 },
  { kind = "power-plant", x = -154, y = -294 },
  { kind = "iron-mine", x = 378, y = -224 },
  { kind = "steel-mill", x = 546, y = 84 },
  { kind = "forest", x = -476, y = -238 },
  { kind = "factory", x = -84, y = 406 },
}

C.TECHS = { "railway", "automated-rail-transportation", "rail-signals", "landfill", "automobilism", "lamp", "circuit-network" }

-- Livery palette: each new train gets one of these on every carriage (only carriages still in
-- the default colour; a colour you set yourself is kept and spreads to carriages coupled on).
-- Alpha 0.5 matches how vanilla tints rolling stock.
C.TRAIN_COLORS = {
  { r = 0.85, g = 0.15, b = 0.10, a = 0.5 }, -- signal red
  { r = 0.95, g = 0.55, b = 0.10, a = 0.5 }, -- orange
  { r = 0.95, g = 0.82, b = 0.15, a = 0.5 }, -- yellow
  { r = 0.30, g = 0.70, b = 0.20, a = 0.5 }, -- green
  { r = 0.05, g = 0.40, b = 0.20, a = 0.5 }, -- forest green
  { r = 0.15, g = 0.75, b = 0.75, a = 0.5 }, -- teal
  { r = 0.20, g = 0.45, b = 0.90, a = 0.5 }, -- blue
  { r = 0.10, g = 0.15, b = 0.45, a = 0.5 }, -- navy
  { r = 0.55, g = 0.25, b = 0.80, a = 0.5 }, -- purple
  { r = 0.90, g = 0.40, b = 0.65, a = 0.5 }, -- pink
  { r = 0.50, g = 0.10, b = 0.15, a = 0.5 }, -- maroon
  { r = 0.55, g = 0.35, b = 0.18, a = 0.5 }, -- brown
  { r = 0.85, g = 0.85, b = 0.85, a = 0.5 }, -- silver
  { r = 0.18, g = 0.18, b = 0.20, a = 0.5 }, -- black
}

C.RANKS = {
  { at = 0, title = "Track Layer" },
  { at = 250000, title = "Signal Apprentice" },
  { at = 1000000, title = "Dispatcher" },
  { at = 5000000, title = "Line Manager" },
  { at = 20000000, title = "Rail Baron" },
  { at = 100000000, title = "Railway Tycoon" },
  -- 0.7.9 (Steve): space ranks by rockets launched (all Spaceports together). Railway Tycoon
  -- founds the first Spaceport; "you win" waits for the last rank, where the satellite bonus
  -- tops out (+50% at 50 launches).
  { at = 100000000, rockets = 1, title = "Launch Dispatcher" },
  { at = 100000000, rockets = 5, title = "Orbital Line Manager" },
  { at = 100000000, rockets = 10, title = "Space Freight Baron" },
  { at = 100000000, rockets = 20, title = "Starport Tycoon" },
  { at = 100000000, rockets = 35, title = "Orbital Railway Magnate" },
  { at = 100000000, rockets = 50, title = "Interplanetary Rail Legend" },
}
C.PAD_RANK = 6 -- Railway Tycoon: reaching it founds the first Spaceport

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
