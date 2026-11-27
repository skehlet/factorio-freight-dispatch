-- Freight Dispatch: GUI
local C = require("scripts.config")
local G = {}
local M

function G.init(m) M = m end

local HELP = [[
[font=default-large-bold]How to play[/font]
You run a railway. Towns and industries sit inside coloured rings across the map. Link them by rail and get paid for what you carry.

[font=default-bold]1. Serve a site.[/font] Build a train stop inside its ring (it's named after the site; in a town, after its number, see below). Overlapping rings share a stop. Towns keep a clear street cross through the centre for a downtown station, and never build next to your track.
[font=default-bold]2. Run trains.[/font] On arrival, cargo the site accepts unloads at once. While waiting, cargo it produces loads.
  [color=yellow]Pick-up:[/color] "Full cargo OR 30 seconds".  [color=yellow]Drop-off only:[/color] "Empty cargo" (never loads there).
  Two-way passenger lines and loops: "Full cargo OR 30 seconds" at every town.
[font=default-bold]3. Get paid.[/font] Amount x straight-line distance x cargo rate. Cargo must travel 60+ tiles, and slow trips pay less (passengers and mail lose value fastest).
[font=default-bold]4. Grow.[/font] Industries level up as you ship from them. Towns grow only from goods. More output means more trains, so signalling matters.
[font=default-bold]Destinations.[/font] Every town has a number and colour, shown after its name (e.g. Brookmoor [item=fd-passengers-3]), and so does each Spaceport. Passengers and mail pick where they're going as they board: one of the towns and Spaceports this train goes to (its schedule and interrupt targets, if it can reach them by rail), bigger towns more often. So a loop just runs, and everyone gets off at the right town. They ride as [item=fd-passengers-3] passengers to 3 and [item=fd-mail-3] mail to 3. If a train stops going where some riders are bound (you changed its schedule), they get off at the next town and wait there again.
  A town's first stop is named [item=fd-passengers-3] unload and its second [item=fd-mail-3] unload, so one interrupt can dispatch any train: condition "Item count [virtual-signal=signal-item-parameter] > 0" (the item wildcard), target "[virtual-signal=signal-item-parameter] unload" with "Item count [virtual-signal=signal-item-parameter] = 0". Rename stops freely; delivery goes by the town's ring, not the name.
[font=default-bold]Wagon filters.[/font] Middle-click wagon slots to filter them. A slot filtered to [item=fd-passengers] Passengers takes passengers to any destination, and [item=fd-mail] Mail any mail. If every slot of a wagon is filtered to one cargo, a wagon upgrade gives the new slots the same filter; otherwise they come unfiltered.
[font=default-bold]5. Upgrade.[/font] The Shop sells fuel, bigger wagons, faster station crews and running shoes. Each applies to every train. Fuel, station crews and running shoes each have two more tiers that unlock after your first rocket launch.

Whenever fewer than 6 sites are unserved, a new one is founded 280-700 tiles from your network and announced in chat. New sites fill the supply chain from the bottom up: first a coal mine and lumber camp you haven't connected yet, then an iron mine and power plant, then a town, then a steel mill, then a factory. A missing coal mine, lumber camp, iron mine, power plant or town is founded even when 6 sites are already waiting. Contracts only name places you already serve.

[font=default-bold]Supply chain window[/font] (HUD button) shows, for each cargo, what your served sites made, delivered and could use per second over the last 10 minutes, and whether anything runs short. [color=#ff6060]SHORT[/color] says why: not enough made, held back by an earlier cargo, a producer at full speed, or pickups that can't keep up (a full pile, or a site not visited every minute). [color=yellow]BACKED UP[/color] means a pile keeps filling up. "Next step" names the one fix that helps most, often a spare site to connect.

[font=default-bold]Spaceport (end game)[/font] Reaching Railway Tycoon founds a Spaceport. From there, ranks come from rockets launched (all Spaceports together): 1, 5, 10, 20, 35 and 50, the last one wins the game. Each rocket needs colonists ([item=fd-passengers] passengers), [item=fd-mail] mail and [item=fd-goods] goods brought by train (normal fares), and cash. Assembly is paid as the cargo arrives (half the cargo aboard, half the rocket built), and a fully loaded rocket takes at least 3 minutes, so the faster your trains fill it, the more rockets you launch. Assembly waits whenever paying would take your cash below the reserve you set in the Spaceport window. Every launch adds a satellite: +1% town passengers and mail and +1% power plant supply radius, up to +50%. After your first (free) Spaceport you can buy more in the Spaceport window; each is founded at least 700 tiles from the others and builds its own rockets. The pad levels up after launches 3, 8, 15 and 25: bigger rockets, more cargo, higher cost. Site signals there output [virtual-signal=signal-P] colonists, [virtual-signal=signal-M] mail and [virtual-signal=signal-G] goods still needed, [virtual-signal=signal-T] minutes of assembly left once loaded and [virtual-signal=signal-C] your cash in $1,000s. Tip: filter some wagons to [item=fd-passengers] and some to [item=fd-mail], so a Spaceport train always brings both.

[font=default-bold]Sites[/font]
[item=fd-passengers] [font=default-bold]Town[/font]
  Helped by: [item=fd-goods] goods (the only way to grow), power
  Makes: [item=fd-passengers] passengers and [item=fd-mail] mail bound for other towns, more as it grows
[item=fd-coal] [font=default-bold]Coal Mine[/font]
  Helped by: regular pickups, levels, power
  Makes: [item=fd-coal] coal for steel mills and power plants
[item=fd-iron-ore] [font=default-bold]Iron Mine[/font]
  Helped by: regular pickups, levels, power
  Makes: [item=fd-iron-ore] iron ore for steel mills
[item=fd-wood] [font=default-bold]Lumber Camp[/font]
  Helped by: regular pickups, levels, power
  Makes: [item=fd-wood] lumber for factories and power plants
[item=fd-steel] [font=default-bold]Steel Mill[/font]
  Needs: [item=fd-iron-ore] iron ore
  Helped by: [item=fd-coal] coal (up to x2 with half a coal per ore), levels, power
  Makes: [item=fd-steel] steel for factories
[item=fd-goods] [font=default-bold]Factory[/font]
  Needs: [item=fd-steel] steel
  Helped by: [item=fd-wood] lumber (up to x2 with half a lumber per steel), levels, power
  Makes: [item=fd-goods] goods for towns
[item=fd-coal] [font=default-bold]Power Plant[/font]
  Needs: [item=fd-coal] coal or [item=fd-wood] lumber (worth half). Burns 15 a second, holds 20 minutes
  Makes: power, +25% for every site in its circle (350 tiles, wider each level). One plant per site, so spread them out
Each level adds the base output again (mines) or 50 more processed per second (mills, factories). Mines make less ("service") until trains pick up regularly. Input piles hold 20,000: when full, trains keep the rest aboard, and a full output pile pauses the site. Nothing is wasted.

[font=default-bold]Building[/font]
- Shop [color=yellow]Place[/color] puts a ghost in your cursor. Every ghost (blueprints and map view too) builds instantly, from your inventory first, then cash. Unaffordable ghosts wait for the money. Trees in the way cost a small fee.
- Rails: straight $50, diagonal $100, curve $150. Deconstruction refunds 75%. The upgrade planner swaps rail and chain signals.
- Locomotives refuel themselves at your expense. Idle trains cost nothing.
- Trains and stops reveal the map around them. A Land survey (Shop) reveals the area you're looking at.
- Click a site in the Supply chain window or a contract to view it. Shift+click to travel there.

[font=default-bold]Signals[/font]
Rail signal: one train per block, place it where trains should wait. Chain signal: at junction entries and inside junctions, with a rail signal at each exit, so trains never stop inside a junction.

[font=default-bold]Circuits (optional)[/font]
[item=fd-site-signals] Site signals (Shop), built inside a ring, outputs that site's piles every second, plus [virtual-signal=signal-P] population, [virtual-signal=signal-L] level or [virtual-signal=signal-F] fuel. Wire it with the red or green wire button (shortcut bar), then tick the stop's or signal's circuit option. Pick the freight item (with the small locomotive badge), not the vanilla one.
- Full boost: enable a mill's ore stop while [item=fd-coal] Coal > 1000 (factory steel stop: [item=fd-wood] Lumber > 1000).
- A disabled stop is skipped. To hold a train instead, close a rail signal before the stop.
- Full loads only: enable a town's stop while [item=fd-passengers] Passengers > 4000.
[item=fd-decider] Decider combinator (Shop, no power) combines conditions: box -> decider input, decider output -> stop. Output [virtual-signal=signal-red] = 1 when it should stop, and enable the stop while [virtual-signal=signal-red] = 0. For example, steel mill ore stop: [item=fd-iron-ore] Iron ore > 15000 OR [item=fd-coal] Coal < 1000.
[item=fd-arithmetic] Arithmetic combinator (Shop, no power) does maths on signals. Stop priority only goes from 0 to 255 (higher wins, then the nearest), so to send trains to the busiest town, output [item=fd-passengers] Passengers / 20 as [virtual-signal=signal-W], wire it to every same-named stop and tick "Set priority" with [virtual-signal=signal-W].
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
  f.add({ type = "label", name = "rockets" })
  f.add({ type = "line" })
  f.add({ type = "label", caption = "[font=default-bold]Contracts[/font]" })
  f.add({ type = "flow", name = "contracts", direction = "vertical" })
  f.add({ type = "line" })
  local b = f.add({ type = "flow", name = "buttons", direction = "horizontal" })
  b.add({ type = "button", caption = "Shop", tags = { fd = "shop" } })
  b.add({ type = "button", caption = "Supply chain", tags = { fd = "sites" } })
  b.add({ type = "button", name = "pad", caption = "Spaceport", tags = { fd = "pad" } })
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
    if nxt.rockets then
      -- 0.7.9 space ranks: progress in rockets launched
      local have, from = storage.rockets or 0, rk.rockets or 0
      f.rank.caption = "Rank: [color=yellow]" .. rk.title .. "[/color]  (next: " .. nxt.title .. " at " .. nxt.rockets .. " rockets)"
      f.rank_bar.value = math.max(0, math.min(1, (have - from) / math.max(1, nxt.rockets - from)))
    else
      f.rank.caption = "Rank: [color=yellow]" .. rk.title .. "[/color]  (next: " .. nxt.title .. " at " .. M.money_str(nxt.at) .. " earned)"
      f.rank_bar.value = math.min(1, (storage.lifetime - rk.at) / (nxt.at - rk.at))
    end
  else
    f.rank.caption = "Rank: [color=yellow]" .. rk.title .. "[/color]  - you won!"
    f.rank_bar.value = 1
  end
  local pad = M.spaceport()
  if f.rockets then
    f.rockets.visible = pad ~= nil
    if pad then
      f.rockets.caption = "[item=rocket-silo] Rockets launched: " .. (storage.rockets or 0) ..
        string.format("  (satellites x%.2f)", M.sat_mult())
    end
  end
  if f.buttons and f.buttons.pad then f.buttons.pad.visible = pad ~= nil end
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
  for _, n in pairs({ "fd_shop", "fd_sites", "fd_help", "fd_pad" }) do
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
    -- 0.8.2: the top two tiers wait for the first rocket launch
    local locked = nxt and nxt.rockets and (storage.rockets or 0) < nxt.rockets
    local b = ut.add({ type = "button", caption = locked and "After 1st rocket" or (nxt and M.money_str(nxt.price) or "Max"),
      tags = { fd = "upgrade", id = u.id },
      tooltip = nxt and (locked and (nxt.name .. " (" .. M.money_str(nxt.price) .. ") unlocks after your first rocket launch.") or ("Buy " .. nxt.name)) or nil })
    b.enabled = nxt ~= nil and not locked and storage.money >= nxt.price
  end
  -- 0.7.8: more Spaceports, once the free first one exists
  if M.spaceport() then
    inner.add({ type = "line" })
    local pf = inner.add({ type = "flow", direction = "horizontal" })
    pf.style.vertical_align = "center"
    pf.add({ type = "sprite", sprite = "item/rocket-silo" })
    local pl = pf.add({ type = "label", caption = "Spaceport: [color=yellow]" .. #M.spaceports() .. " built[/color]" })
    pl.style.minimal_width = 230
    local pending = (storage.pads_pending or 0) > 0
    local price = M.pad_price()
    local pb = pf.add({ type = "button", caption = pending and "Choosing a site..." or ("Buy another (" .. M.money_str(price) .. ")"),
      tags = { fd = "buy_pad" },
      tooltip = "Founded somewhere on the map, at least " .. M.fmt(C.SPACEPORT.pad_min_dist) .. " tiles from your other Spaceports. It builds its own rockets; satellites are shared." })
    pb.enabled = not pending and storage.money >= price
  end
  inner.add({ type = "line" })
  inner.add({ type = "button", caption = "Sell back shop items in my inventory (75%)", tags = { fd = "sell" } })
  inner.add({
    type = "button", caption = "[item=train-stop] Land survey here (" .. M.money_str(C.SURVEY_PRICE) .. ")", tags = { fd = "survey" },
    tooltip = "Reveals a " .. (C.SURVEY_RADIUS * 2) .. " x " .. (C.SURVEY_RADIUS * 2) ..
      " tile area around where you're looking (works from the map view too). Handy for planning a route.",
  })
end

-- Supply chain window (0.5.0, replaces the old Sites list, which Steve found too noisy).
-- Every site name is a button: click to view it, shift+click to travel there.
-- Column widths, shared by every block so the columns line up down the whole window.
local COL_ROLE, COL_SITE, COL_RATE = 50, 250, 80
local HEAD = { 150, 120, 150, 140 } -- cargo name, made, delivered, wanted (0.5.2: was 300 wide, too far right)

local function site_button(parent, s, width)
  local tip = M.site_status(s)
  local detail = M.site_detail(s)
  if detail then tip = tip .. "\n" .. detail end
  local b = parent.add({
    type = "button", caption = M.site_title(s), tags = { fd = "goto", site = s.id },
    tooltip = tip .. "\n[color=gray]Click: view on map.  Shift+click: travel there.[/color]",
  })
  b.style.height = 26
  b.style.left_padding = 6
  b.style.right_padding = 6
  b.style.font = "default"
  if width then
    b.style.width = width
    b.style.horizontal_align = "left"
  end
  return b
end

local function cell(parent, caption, width, right)
  local l = parent.add({ type = "label", caption = caption })
  if width then l.style.width = width end
  if right then l.style.horizontal_align = "right" end
  return l
end

-- a 4-column table: role | site button | rate | note
local function site_table(parent)
  local t = parent.add({ type = "table", column_count = 4 })
  t.style.horizontal_spacing = 10
  t.style.vertical_spacing = 2
  t.style.left_margin = 8
  return t
end

local function site_row(t, role, s, rate_text, note)
  cell(t, role, COL_ROLE)
  site_button(t, s, COL_SITE)
  cell(t, rate_text, COL_RATE, true)
  cell(t, note or "")
end

local function rate(n)
  if n > 0 and n < 10 then return string.format("%.1f", n) end
  return M.fmt(n)
end

local function cause_text(r)
  if r.status == "measuring" then return "[color=gray]measuring...[/color]" end
  if r.status == "ok" then return "[color=green]OK[/color]" end
  if r.status == "unused" then return "[color=gray]nothing connected uses it[/color]" end
  if r.status == "backed" then return "[color=yellow]BACKED UP[/color]: a pile keeps filling, needs more pickups" end
  if r.status ~= "short" then return "" end
  local why = ({
    none = "nothing connected makes it",
    production = "not enough made",
    capacity = "producer at full speed",
    pickup = r.why == "service" and "irregular pickups" or r.why == "full" and "not picked up fast enough" or "trains don't carry enough",
    upstream = r.cause_item and ("held back by [item=" .. r.cause_item .. "]") or "held back",
  })[r.cause] or ""
  return "[color=#ff6060]SHORT[/color]: " .. why
end

local function pct(f) return math.floor(f * 100 + 0.5) .. "%" end

local function build_chain(player)
  local f = open_window(player, "fd_sites", "Supply chain")
  if not f then return end
  local ch = M.supply_chain()
  local sp = f.add({ type = "scroll-pane", direction = "vertical" })
  sp.style.maximal_height = 680
  sp.style.minimal_width = 720

  -- next step
  local nf = sp.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  nf.style.horizontally_stretchable = true
  local nl = nf.add({ type = "label", caption = "[font=default-bold]Next step:[/font] " .. ch.next.text })
  nl.style.single_line = false
  nl.style.maximal_width = 680
  if #ch.next.sites > 0 then
    local fl = nf.add({ type = "flow", direction = "horizontal" })
    for _, id in ipairs(ch.next.sites) do
      if storage.sites[id] then site_button(fl, storage.sites[id]) end
    end
  end

  local measuring = ch.window < 120

  -- block header: cargo name, made, delivered, wanted, status (fixed widths so they line up)
  local function header(caption, made, got, wanted, status)
    local head = sp.add({ type = "flow", direction = "horizontal" })
    head.style.horizontal_spacing = 0
    cell(head, caption, HEAD[1])
    cell(head, made, HEAD[2])
    cell(head, got, HEAD[3])
    cell(head, wanted or "", HEAD[4])
    cell(head, status or "")
  end

  -- one block per freight cargo
  for _, it in ipairs(M.CHAIN_ITEMS) do
    local r = ch.rows[it]
    if #r.producers > 0 or #r.consumers > 0 then
      sp.add({ type = "line" })
      header("[item=" .. it .. "] [font=default-bold]" .. C.CARGO[it].label .. "[/font]",
        "made " .. rate(r.made) .. "/s", "delivered " .. rate(r.got) .. "/s",
        r.wanted > 0 and ("wanted " .. rate(r.wanted) .. "/s") or nil, cause_text(r))
      local t = site_table(sp)
      for i, p in ipairs(r.producers) do
        local notes = {}
        if p.busy then table.insert(notes, "busy " .. pct(p.busy)) end
        if not measuring and p.full > 0.15 then table.insert(notes, "[color=yellow]pile full " .. pct(p.full) .. "[/color]") end
        if p.service and p.service < 0.85 then table.insert(notes, string.format("[color=yellow]service x%.2f[/color]", p.service)) end
        site_row(t, i == 1 and "From" or "", p.site, rate(p.rate) .. "/s", table.concat(notes, ", "))
      end
      if it == "fd-goods" then
        local n = #ch.towns.growing
        local first = true
        for _, c in ipairs(r.consumers) do
          local grows = false
          for _, s in ipairs(ch.towns.growing) do if s == c.site then grows = true end end
          site_row(t, first and "To" or "", c.site, rate(c.got) .. "/s", grows and "[color=green]growing[/color]" or "[color=gray]stable[/color]")
          first = false
        end
      else
        for i, c in ipairs(r.consumers) do
          local notes = {}
          if c.role == "booster" then table.insert(notes, "boost") end
          if c.role == "fuel" then table.insert(notes, "fuel") end
          if c.role == "pad" then table.insert(notes, "rocket") end
          if not measuring and c.short > C.CHAIN_SHORT then
            table.insert(notes, "[color=#ff6060]" .. (c.role == "fuel" and "dry " or "short ") .. pct(c.short) .. " of the time[/color]")
          end
          site_row(t, i == 1 and "To" or "", c.site, rate(c.got) .. "/s", table.concat(notes, ", "))
        end
      end
    end
  end

  -- towns: passengers and mail summary
  local tw = ch.towns
  if tw.n > 0 then
    sp.add({ type = "line" })
    header("[item=fd-passengers] [font=default-bold]Passengers[/font]", "made " .. rate(tw.pax.made) .. "/s",
      "delivered " .. rate(tw.pax.got) .. "/s", "carried " .. rate(tw.pax.carried) .. "/s")
    header("[item=fd-mail] [font=default-bold]Mail[/font]", "made " .. rate(tw.mail.made) .. "/s",
      "delivered " .. rate(tw.mail.got) .. "/s", "carried " .. rate(tw.mail.carried) .. "/s")
    local pads = M.spaceports()
    if #pads > 0 then
      local t = site_table(sp)
      for i, pad in ipairs(pads) do
        local need, st = M.pad_need(pad), M.pad_state(pad)
        site_row(t, i == 1 and "Pad" or "", pad, "", "rocket: [item=fd-passengers] " .. M.fmt(st.colonists) .. " / " ..
          M.fmt(need.colonists) .. ", [item=fd-mail] " .. M.fmt(st.mail) .. " / " .. M.fmt(need.mail) ..
          ", [item=fd-goods] " .. M.fmt(st.goods) .. " / " .. M.fmt(need.goods))
      end
    end
    if #tw.full > 0 and not measuring then
      local t = site_table(sp)
      for i, s in ipairs(tw.full) do
        site_row(t, i == 1 and "Full" or "", s, "", "[color=yellow]passengers piling up: more trains[/color]")
      end
    end
  end

  -- footer
  sp.add({ type = "line" })
  local parts = {}
  for _, k in ipairs(C.KIND_ORDER) do
    local n = ch.spare[k] or 0
    if n > 0 then table.insert(parts, n .. " [item=" .. C.KINDS[k].icon .. "] " .. C.KINDS[k].label:lower()) end
  end
  local mins = math.max(1, math.floor(ch.window / 60 + 0.5))
  local foot = sp.add({ type = "label", caption = "[color=gray]Averages over the last " .. mins .. " min. Hover a site for its details." ..
    (#parts > 0 and ("\nSpare (unserved) sites: " .. table.concat(parts, ", ")) or "") .. "[/color]" })
  foot.style.single_line = false
  foot.style.maximal_width = 680
end

-- Spaceport window (0.7.0): progress of the rocket being built at each pad (0.7.8: all of
-- them), cash reserve, pause, and buying another pad.
local function build_pad(player)
  local pads = M.spaceports()
  if #pads == 0 then return end
  local f = open_window(player, "fd_pad", "Spaceport" .. (#pads > 1 and "s" or ""))
  if not f then return end
  local outer = f.add({ type = "scroll-pane", direction = "vertical" })
  outer.style.maximal_height = 760
  local inner = outer.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  inner.style.minimal_width = 560
  for i, s in ipairs(pads) do
    if i > 1 then inner.add({ type = "line" }) end
    site_button(inner, s)
    local need, st = M.pad_need(s), M.pad_state(s)
    inner.add({ type = "label", caption = "[font=default-bold]Level " .. s.level .. "[/font]  (" .. (s.launches or 0) .. " launched here)" })
    local function bar(caption, have, want)
      local fl = inner.add({ type = "flow", direction = "horizontal" })
      fl.style.vertical_align = "center"
      local l = fl.add({ type = "label", caption = caption })
      l.style.width = 220
      local pb = fl.add({ type = "progressbar", value = math.min(1, have / math.max(1, want)) })
      pb.style.width = 300
    end
    bar("[item=fd-passengers] Colonists " .. M.fmt(st.colonists) .. " / " .. M.fmt(need.colonists), st.colonists, need.colonists)
    bar("[item=fd-mail] Mail " .. M.fmt(st.mail) .. " / " .. M.fmt(need.mail), st.mail, need.mail)
    bar("[item=fd-goods] Goods " .. M.fmt(st.goods) .. " / " .. M.fmt(need.goods), st.goods, need.goods)
    bar("Assembly " .. M.money_short(st.paid) .. " / " .. M.money_short(need.cost), st.paid, need.cost)
    local d = inner.add({ type = "label", caption = "[color=#d8d8b0]" .. (M.site_detail(s) or "") .. "[/color]" })
    d.style.single_line = false
    d.style.maximal_width = 540
  end
  inner.add({ type = "line" })
  local run = inner.add({ type = "checkbox", caption = "Assemble rockets", state = not storage.pad_paused,
    tags = { fd = "pad_run" }, tooltip = "Untick to pause every Spaceport. Nothing is lost while paused." })
  local fl = inner.add({ type = "flow", direction = "horizontal" })
  fl.style.vertical_align = "center"
  fl.add({ type = "label", caption = "Keep at least" })
  local items = {}
  for _, v in ipairs(C.SPACEPORT.reserves) do table.insert(items, M.money_str(v)) end
  fl.add({ type = "drop-down", items = items, selected_index = storage.pad_reserve or C.SPACEPORT.default_reserve,
    tags = { fd = "pad_reserve" } })
  fl.add({ type = "label", caption = "in cash: assembly waits whenever paying would go below it." })
  local n = storage.rockets or 0
  local pct = math.floor((M.sat_mult() - 1) * 100 + 0.5)
  local info = inner.add({ type = "label", caption = "[color=gray]Assembly is paid as the cargo arrives and takes at least " .. math.floor(C.SPACEPORT.build_secs / 60) ..
    " min. A rocket launches as soon as it's built and its colonists, mail and goods are aboard. " ..
    "Deliveries pay their normal fare on arrival; trains keep anything the rocket doesn't need yet.\n" ..
    "Satellites: " .. n .. " launched, +" .. pct .. "% town passengers and mail, and +" .. pct .. "% power plant reach (" ..
    math.floor(C.SPACEPORT.satellite * 100 + 0.5) .. "% per launch, up to +" .. math.floor(C.SPACEPORT.satellite_cap * 100) .. "%).[/color]" })
  info.style.single_line = false
  info.style.maximal_width = 540
  inner.add({ type = "line" })
  local pending = (storage.pads_pending or 0) > 0
  local price = M.pad_price()
  local bb = inner.add({ type = "button", caption = pending and "New Spaceport: choosing a site..." or ("Buy another Spaceport (" .. M.money_str(price) .. ")"),
    tags = { fd = "buy_pad" },
    tooltip = "Founded somewhere on the map, at least " .. M.fmt(C.SPACEPORT.pad_min_dist) .. " tiles from your other Spaceports. It builds its own rockets; satellites are shared." })
  bb.enabled = not pending and storage.money >= price
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
  elseif a == "sites" then build_chain(player)
  elseif a == "help" then build_help(player)
  elseif a == "pad" then build_pad(player)
  elseif a == "buy_pad" then
    M.buy_pad(player)
    local scr = player.gui.screen
    if scr.fd_pad then scr.fd_pad.destroy(); build_pad(player)
    elseif scr.fd_shop then scr.fd_shop.destroy(); build_shop(player) end
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

-- Every rail entity type the game has (straight, half-diagonal, curved a/b, legacy, ramps...).
-- The character doesn't collide with rails, so find_non_colliding_position happily picks a track.
local rail_types
local function get_rail_types()
  if rail_types then return rail_types end
  local set = {}
  for _, p in pairs(prototypes.entity) do
    local t = p.type
    if t:find("rail", 1, true) and not t:find("signal", 1, true) and t ~= "rail-remnants" then
      set[t] = true
    end
  end
  rail_types = {}
  for t in pairs(set) do rail_types[#rail_types + 1] = t end
  return rail_types
end

local RAIL_CLEARANCE = 3.5 -- tiles from any rail piece (a train is about 2 tiles wide)

-- Nearest spot to `target` where a character fits and no rail is within RAIL_CLEARANCE.
-- Searches outward in rings of 2 tiles up to `max_r`.
function G.safe_spot(surf, target, max_r)
  local types = get_rail_types()
  local tx, ty = target[1] or target.x, target[2] or target.y
  local function clear(pos)
    local c = RAIL_CLEARANCE
    return surf.count_entities_filtered({
      area = { { pos.x - c, pos.y - c }, { pos.x + c, pos.y + c } }, type = types, limit = 1,
    }) == 0
  end
  for r = 0, max_r or 60, 2 do
    local n = r == 0 and 1 or math.ceil(2 * math.pi * r / 2)
    for i = 0, n - 1 do
      local a = 2 * math.pi * i / n
      local cand = { tx + r * math.cos(a), ty + r * math.sin(a) }
      local pos = surf.find_non_colliding_position("character", cand, 1.5, 0.5)
      if pos and clear(pos) then return pos end
    end
  end
  return nil
end

-- Click: jump the camera there in remote view. Shift+click: teleport the character there,
-- to the nearest spot that is clear of track.
function G.goto_site(player, site_id, travel)
  local s = storage.sites[site_id]
  if not s then return end
  local surf = game.surfaces[C.SURFACE]
  local target = { s.x, s.y + C.KINDS[s.kind].radius * 0.6 }
  for _, n in pairs({ "fd_shop", "fd_sites", "fd_help", "fd_pad" }) do
    if player.gui.screen[n] then player.gui.screen[n].destroy() end
  end
  if travel and player.character then
    local pos = G.safe_spot(surf, target, 60)
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

script.on_event(defines.events.on_gui_checked_state_changed, function(e)
  local el = e.element
  if el and el.valid and el.tags and el.tags.fd == "pad_run" then
    storage.pad_paused = not el.state
  end
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(e)
  local el = e.element
  if el and el.valid and el.tags and el.tags.fd == "pad_reserve" then
    storage.pad_reserve = el.selected_index
  end
end)

script.on_event(defines.events.on_gui_closed, function(e)
  local el = e.element
  if el and el.valid and (el.name == "fd_shop" or el.name == "fd_sites" or el.name == "fd_help" or el.name == "fd_pad") then
    el.destroy()
  end
end)

return G
