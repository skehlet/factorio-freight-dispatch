-- Freight Dispatch: GUI
local C = require("scripts.config")
local G = {}
local M

function G.init(m) M = m end

local HELP = [[
[font=default-large-bold]How to play[/font]
You run a railway company. You don't build a factory here. Towns and industries are scattered across the map, each inside a coloured ring. Connect them by rail to earn money.

[font=default-bold]1. Serve a site.[/font] Build a train stop inside a site's ring. The stop is named after the site automatically. A stop can serve more than one site if their rings overlap. Town rings grow as the town grows, and every town keeps a clear street cross through its centre, wide enough for a downtown station. Town buildings never get built right next to your track.

[font=default-bold]2. Run trains.[/font] Give a train a schedule between two stops. When a train arrives, cargo the site accepts is unloaded at once. Then, while it waits, cargo the site produces is loaded. Wagon filters work as normal.
  [color=yellow]Pick-up stop:[/color] wait "Full cargo OR 30 seconds".
  [color=yellow]Drop-off only:[/color] wait "Empty cargo". The train only unloads there and never loads, so it leaves as soon as it's empty. Use this at a steel mill, factory or power plant, or a town you only deliver to.
  Two-way passenger routes: use "Full cargo OR 30 seconds" at both towns.

[font=default-bold]3. Get paid.[/font] Pay = amount x straight-line distance x cargo rate x speed bonus. Slow deliveries pay less, and passengers and mail lose value fastest. Cargo must travel at least 60 tiles.

[font=default-bold]4. Grow.[/font] Industries level up as you ship from them, which raises production. Towns grow when you deliver goods, mail and passengers, and bigger towns make more passengers. Growth slows down once a town passes about 1,000 people, so big cities take a while. More output means more trains, and more trains means you need good signalling. Watch for deadlock and train-wreck alerts. Each site's second status line (on the map and in the Sites list) shows what drives it: a town's growth per minute by source, or an industry's output multiplier and stockpile.

[font=default-bold]5. Upgrade.[/font] The Shop sells upgrades that apply to every train at once: better fuel (faster acceleration and top speed), bigger cargo wagons, and station crews that load faster. Running shoes make you run faster.

New towns and industries stop appearing once you have plenty of unserved ones, and contracts stick to places your network already serves.

[font=default-bold]Supply chains[/font]
[item=fd-coal] Coal Mine -> Power Plant or Steel Mill
[item=fd-iron-ore] Iron Mine -> Steel Mill. Coal is a booster: steel output goes up to x2 with half a coal per ore. Coal alone makes nothing.
[item=fd-steel] Steel Mill -> Factory. [item=fd-wood] Lumber is a booster: goods output goes up to x2 with half a lumber per steel. Lumber alone makes nothing.
[item=fd-goods] Factory -> Towns (towns grow fast)
[item=fd-passengers][item=fd-mail] Town <-> Town

[font=default-bold]Building[/font]
- In the Shop, [color=yellow]Place[/color] puts a ghost in your cursor. Any ghost you place (including blueprints, and from map view with M) is built instantly. Matching items in your inventory are used first, and the rest is paid in cash, so you never need to buy rails ahead of time. Trees in the way are cleared for a small fee. A floating note shows what each build cost.
- Map: your trains reveal the land around them as they run, and your train stops keep a live view of their area. To scout somewhere new, open the map (M), look at the area, and buy a Land survey from the Shop.
- In the Sites list (and on contracts in the left panel), click a name to jump the map view there. Shift+click to travel there in person.
- Rail costs: straight $50, diagonal $100, curve $150. Ghosts you can't afford yet wait and build as soon as the money comes in.
- The deconstruction planner removes your rails and signals instantly and refunds 75% of the price.
- The upgrade planner swaps signals instantly (rail signal <-> chain signal).
- Locomotives refuel themselves with your current fuel upgrade. You pay for the fuel.

[font=default-bold]Signalling refresher[/font]
Rail signal: one train per block. Place it where a train should wait.
Chain signal: looks ahead to the next signal. Put chain signals at junction entries and inside junctions, and a rail signal at each exit, so trains never stop in the middle of a junction.
]]

local function hud(player)
  return player.gui.left.fd_hud
end

function G.build_hud(player)
  local left = player.gui.left
  if left.fd_hud then left.fd_hud.destroy() end
  local f = left.add({ type = "frame", name = "fd_hud", direction = "vertical", caption = "[item=locomotive] Freight Dispatch" })
  f.style.minimal_width = 280
  local money = f.add({ type = "label", name = "money" })
  money.style.font = "default-large-bold"
  f.add({ type = "label", name = "income" })
  f.add({ type = "label", name = "rank" })
  local bar = f.add({ type = "progressbar", name = "rank_bar" })
  bar.style.horizontally_stretchable = true
  f.add({ type = "line" })
  f.add({ type = "label", caption = "[font=default-bold]Contracts[/font]" })
  f.add({ type = "flow", name = "contracts", direction = "vertical" })
  f.add({ type = "line" })
  local b = f.add({ type = "flow", name = "buttons", direction = "horizontal" })
  b.add({ type = "button", caption = "Shop", tags = { fd = "shop" } })
  b.add({ type = "button", caption = "Sites", tags = { fd = "sites" } })
  b.add({ type = "button", caption = "Help", tags = { fd = "help" } })
  G.update(player)
end

function G.update(player)
  local f = hud(player)
  if not (f and f.valid) then return end
  f.money.caption = "Cash: " .. M.money_str(storage.money)
  f.income.caption = "Income: " .. M.money_str(M.income_per_min()) .. " / min"
  local r = M.rank()
  local rk = C.RANKS[r]
  local nxt = C.RANKS[r + 1]
  if nxt then
    f.rank.caption = "Rank: [color=yellow]" .. rk.title .. "[/color]  (next: " .. nxt.title .. " at " .. M.money_str(nxt.at) .. " earned)"
    f.rank_bar.value = math.min(1, (storage.lifetime - rk.at) / (nxt.at - rk.at))
  else
    f.rank.caption = "Rank: [color=yellow]" .. rk.title .. "[/color]  - you won!"
    f.rank_bar.value = 1
  end
  local cf = f.contracts
  cf.clear()
  if #storage.contracts == 0 then
    cf.add({ type = "label", caption = "[color=gray]None right now. New ones appear every few minutes.[/color]" })
  end
  for _, ct in pairs(storage.contracts) do
    local s = storage.sites[ct.site_id]
    if s then
      local mins = math.max(0, math.ceil((ct.deadline - game.tick) / 3600))
      cf.add({
        type = "label",
        caption = "[item=" .. ct.item .. "] " .. C.CARGO[ct.item].label .. " " .. M.fmt(ct.delivered) .. "/" .. M.fmt(ct.amount) ..
          " to [color=yellow]" .. M.site_title(s) .. "[/color]  [color=green]" ..
          M.money_str(ct.reward) .. "[/color]  " .. mins .. "m",
        tags = { fd = "goto", site = s.id },
        tooltip = "Click: view on map.  Shift+click: travel there.",
      })
    end
  end
end

local function titlebar(frame, title, close_tag)
  local tb = frame.add({ type = "flow", direction = "horizontal" })
  tb.drag_target = frame
  tb.add({ type = "label", caption = title, style = "frame_title", ignored_by_interaction = true })
  local filler = tb.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  filler.style.height = 24
  filler.style.horizontally_stretchable = true
  tb.add({ type = "sprite-button", sprite = "utility/close", style = "frame_action_button", tags = { fd = "close", win = close_tag } })
end

local function open_window(player, name, title)
  local screen = player.gui.screen
  if screen[name] then
    screen[name].destroy()
    return nil
  end
  for _, n in pairs({ "fd_shop", "fd_sites", "fd_help" }) do
    if screen[n] then screen[n].destroy() end
  end
  local f = screen.add({ type = "frame", name = name, direction = "vertical" })
  titlebar(f, title, name)
  f.auto_center = true
  player.opened = f
  return f
end

local function build_shop(player)
  local f = open_window(player, "fd_shop", "Shop")
  if not f then return end
  local inner = f.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  inner.add({ type = "label", name = "cash", caption = "Cash: " .. M.money_str(storage.money) })
  local t = inner.add({ type = "table", column_count = 6 })
  t.style.horizontal_spacing = 12
  t.style.vertical_spacing = 6
  for _, row in pairs(C.SHOP) do
    local proto = prototypes.item[row.item]
    if proto then
      local note = row.note
      if row.item == "cargo-wagon" then
        note = "Holds " .. M.fmt(M.upgrade_tier("wagons").slots * 50) .. " units of cargo (wagon upgrade: " ..
          M.upgrade_tier("wagons").name .. ")."
      end
      t.add({ type = "sprite", sprite = "item/" .. row.item, tooltip = note })
      local l = t.add({ type = "label", caption = proto.localised_name, tooltip = note })
      l.style.minimal_width = 140
      t.add({ type = "label", caption = M.money_str(C.PRICES[row.item]) })
      t.add({ type = "button", caption = "Buy 1", tags = { fd = "buy", item = row.item, n = 1 } })
      t.add({ type = "button", caption = "Buy 10", tags = { fd = "buy", item = row.item, n = 10 } })
      if row.ghost then
        t.add({ type = "button", caption = "Place", tags = { fd = "ghost", item = row.item },
          tooltip = "Puts a ghost in your cursor. Ghosts are built instantly and charged." })
      else
        t.add({ type = "empty-widget" })
      end
    end
  end
  inner.add({ type = "line" })
  inner.add({ type = "label", caption = "[font=default-bold]Upgrades[/font]  [color=gray](apply to every train at once)[/color]" })
  local ut = inner.add({ type = "table", column_count = 4 })
  ut.style.horizontal_spacing = 12
  ut.style.vertical_spacing = 6
  for _, u in pairs(C.UPGRADES) do
    local cur, level = M.upgrade_tier(u.id)
    local nxt = u.tiers[level + 1]
    ut.add({ type = "sprite", sprite = u.icon })
    local l = ut.add({ type = "label", caption = u.label .. ": [color=yellow]" .. cur.name .. "[/color]", tooltip = cur.desc })
    l.style.minimal_width = 230
    local n = ut.add({ type = "label", caption = nxt and ("Next: " .. nxt.name .. " (" .. nxt.desc .. ")") or "[color=green]Fully upgraded[/color]" })
    n.style.minimal_width = 330
    local b = ut.add({ type = "button", caption = nxt and M.money_str(nxt.price) or "Max", tags = { fd = "upgrade", id = u.id },
      tooltip = nxt and ("Buy " .. nxt.name) or nil })
    b.enabled = nxt ~= nil and storage.money >= nxt.price
  end
  inner.add({ type = "line" })
  inner.add({ type = "button", caption = "Sell back shop items in my inventory (75%)", tags = { fd = "sell" } })
  inner.add({
    type = "button", caption = "[item=train-stop] Land survey here (" .. M.money_str(C.SURVEY_PRICE) .. ")", tags = { fd = "survey" },
    tooltip = "Reveals a " .. (C.SURVEY_RADIUS * 2) .. " x " .. (C.SURVEY_RADIUS * 2) ..
      " tile area around where you're looking (works from the map view too). Unexplored land fills with new towns and industries.",
  })
end

local function build_sites(player)
  local f = open_window(player, "fd_sites", "Towns and industries")
  if not f then return end
  local sp = f.add({ type = "scroll-pane", direction = "vertical" })
  sp.style.maximal_height = 600
  sp.style.minimal_width = 640
  local t = sp.add({ type = "table", column_count = 3 })
  t.style.horizontal_spacing = 16
  t.add({ type = "label", caption = "[font=default-bold]Site (click to view on map)[/font]" })
  t.add({ type = "label", caption = "[font=default-bold]Status[/font]" })
  t.add({ type = "label", caption = "[font=default-bold]Distance[/font]" })
  local pos = player.position
  local list = {}
  for _, s in pairs(storage.sites) do
    local dx, dy = s.x - pos.x, s.y - pos.y
    table.insert(list, { s = s, d = math.sqrt(dx * dx + dy * dy) })
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  for i, e in ipairs(list) do
    if i > 100 then break end
    local s = e.s
    local btn = t.add({
      type = "button", caption = "[item=" .. C.KINDS[s.kind].icon .. "] " .. M.site_title(s),
      tags = { fd = "goto", site = s.id }, tooltip = "Click: view on map.  Shift+click: travel there.",
    })
    btn.style.horizontal_align = "left"
    btn.style.minimal_width = 230
    local detail = M.site_detail(s)
    local st = t.add({ type = "label", caption = M.site_status(s) .. (detail and ("\n[color=#d8d8b0]" .. detail .. "[/color]") or "") })
    st.style.single_line = false
    t.add({ type = "label", caption = M.fmt(e.d) .. " tiles" })
  end
  f.add({ type = "label", caption = "[color=gray]Explore (or view the map) to discover more sites. New land generates new towns and industries.[/color]" })
end

local function build_help(player)
  local f = open_window(player, "fd_help", "Freight Dispatch - Help")
  if not f then return end
  local sp = f.add({ type = "scroll-pane", direction = "vertical" })
  sp.style.maximal_height = 650
  local l = sp.add({ type = "label", caption = HELP })
  l.style.single_line = false
  l.style.maximal_width = 620
end

local function buy(player, item, n)
  local price = C.PRICES[item]
  if not price then return end
  n = math.min(n, math.floor(storage.money / price))
  if n <= 0 then
    player.print("[color=red]Not enough money.[/color]")
    return
  end
  local inserted = player.insert({ name = item, count = n })
  if inserted == 0 then
    player.print("[color=red]No room in your inventory.[/color]")
    return
  end
  M.spend(price * inserted)
end

local function sell(player)
  local inv = player.get_main_inventory()
  if not inv then return end
  local total = 0
  for item, price in pairs(C.PRICES) do
    local c = inv.get_item_count(item)
    if c > 0 then
      local removed = inv.remove({ name = item, count = c })
      total = total + removed * price * C.REFUND
    end
  end
  storage.money = storage.money + math.floor(total)
  player.print("Sold items for " .. M.money_str(total))
end

local function set_ghost(player, item)
  player.clear_cursor()
  local ok = pcall(function() player.cursor_ghost = item end)
  if not ok then
    pcall(function() player.cursor_ghost = { name = item, quality = "normal" } end)
  end
  if player.gui.screen.fd_shop then player.gui.screen.fd_shop.destroy() end
end

script.on_event(defines.events.on_gui_click, function(e)
  local el = e.element
  if not (el and el.valid) then return end
  local tags = el.tags
  if not tags or not tags.fd then return end
  local player = game.get_player(e.player_index)
  local a = tags.fd
  if a == "shop" then build_shop(player)
  elseif a == "sites" then build_sites(player)
  elseif a == "help" then build_help(player)
  elseif a == "close" then
    local w = player.gui.screen[tags.win]
    if w then w.destroy() end
  elseif a == "buy" then
    buy(player, tags.item, e.shift and tags.n * 5 or tags.n)
    local w = player.gui.screen.fd_shop
    if w then
      local inner = w.children[2]
      if inner and inner.cash then inner.cash.caption = "Cash: " .. M.money_str(storage.money) end
    end
  elseif a == "upgrade" then
    M.buy_upgrade(player, tags.id)
    local w = player.gui.screen.fd_shop
    if w then w.destroy() end
    build_shop(player)
  elseif a == "ghost" then set_ghost(player, tags.item)
  elseif a == "sell" then sell(player)
  elseif a == "goto" then G.goto_site(player, tags.site, e.shift)
  elseif a == "survey" then
    M.survey(player)
    local w = player.gui.screen.fd_shop
    if w then w.destroy() end
  end
end)

-- Click: jump the camera there in remote view. Shift+click: teleport the character there.
function G.goto_site(player, site_id, travel)
  local s = storage.sites[site_id]
  if not s then return end
  local surf = game.surfaces[C.SURFACE]
  local target = { s.x, s.y + C.KINDS[s.kind].radius * 0.6 }
  for _, n in pairs({ "fd_shop", "fd_sites", "fd_help" }) do
    if player.gui.screen[n] then player.gui.screen[n].destroy() end
  end
  if travel and player.character then
    local pos = surf.find_non_colliding_position("character", target, 40, 0.5)
    if pos then
      if player.controller_type == defines.controllers.remote then
        pcall(function() player.set_controller({ type = defines.controllers.character, character = player.character }) end)
      end
      player.teleport(pos, surf)
      return
    end
  end
  local ok = pcall(function()
    player.set_controller({ type = defines.controllers.remote, position = { s.x, s.y }, surface = surf })
    player.zoom = 0.6
  end)
  if not ok then
    player.print("[gps=" .. s.x .. "," .. s.y .. "," .. C.SURFACE .. "] " .. M.site_title(s))
  end
end

script.on_event(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and (el.name == "fd_shop" or el.name == "fd_sites" or el.name == "fd_help") then
    el.destroy()
  end
end)

return G
