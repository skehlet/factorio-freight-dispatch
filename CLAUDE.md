# Freight Dispatch: handoff notes

A Factorio **2.1** mod (`freight-dispatch/`) that replaces the factory game with a railway tycoon game. It was written from scratch with the user, Steve, over many play-and-fix rounds. Read this before changing anything.

## Goal and the user

- Steve loves **laying track, rail signals and chain signals, and watching trains run**. The mod's purpose is a game loop built around designing a train network instead of a factory. Every feature should push toward "more trains on shared track, so signalling matters".
- It was inspired by the abandoned mod NSkelin/Transportorio (0.17/0.18 era, unusable on 2.x). None of its code is used.
- Steve plays the game and reports what he sees in-game ("mail won't unload", "inventory full of people"). He likes a clear explanation of *why* something happened, then a fix. He is fine with fixes landing as new mod versions.
- **He wants a chill game** (said explicitly at v0.2.0). He hones a few small networks (his "Greenfield loop" with a hub-and-spoke goods system, and the "Fairbridge loop") rather than expanding fast. So: **no** mechanics that push expansion (subsidies for unconnected sites were proposed and put on hold), **no** ongoing costs or upkeep ("Factorio vanilla doesn't have that"), **no** decline of unserved sites. He likes contracts for routes he already runs ("it's a relief"), and he likes progression and seeing multipliers.
- Environment: Windows 11, Steam Factorio **2.1.24, base game only (no Space Age, so no elevated rails, quality or planets)** at `D:\SteamLibrary\steamapps\common\Factorio`. Other enabled mods: `flib`, `EditorExtensions`. Saves are named like `2026-11-07 Freight Dispatch Mod N.zip` in `%APPDATA%\Factorio\saves`.

## Workflow

1. Edit `freight-dispatch/` in this folder (this is the source of truth).
2. Bump `version` in `freight-dispatch/info.json` on every change.
3. Test headlessly: `.\tools\fd.ps1 test` (fresh map plus harness) or `.\tools\fd.ps1 save` (a copy of the user's newest save plus the inspector).
4. Install: `.\tools\fd.ps1 install`, which copies to `%APPDATA%\Factorio\mods\freight-dispatch` as an unzipped folder.
5. Tell the user to **fully restart Factorio**. Mods only load at startup, and loading a save after an update shows a harmless mod-version-changed notice.

Run the script as `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fd.ps1 <mode>`, because the default execution policy blocks unsigned scripts. `save` mode assumes the user's mod set is base + flib + EditorExtensions; update the mod-list line in `fd.ps1` if that changes. On a healthy `test` run, `money` jumps by about $20k or more per trip after the first few minutes and `ghostvalid=false`.

`tools/fd.ps1` runs factorio.exe with its own `--config` and `write-data` folder (`%TEMP%\fd-work`). This is required because the user usually has the game open, and sharing the normal write-data folder fails with **"Couldn't create lock file"**. The full log is `%TEMP%\fd-work\data\factorio-current.log`. `FDDUMP` blocks are multi-line (`serpent.block`), so read that file rather than relying on the script's line filter.

### What headless testing can and cannot verify

- **Can:** prototype loading, `on_init`, map and site generation, train service (loading, unloading, pay), refuel, contracts, ghost revive through the `queue_ghost` remote, and anything in a copy of the user's save (including flipping their train to automatic, or checking their character's inventory through `game.players`).
- **Cannot:** anything needing a connected player or a renderer. That includes all GUI clicks, `cursor_ghost`, remote-view camera moves (`goto_site`), player-placed ghosts (`on_built_entity` with `player_index`), deconstruction and upgrade planner events, and **map charting**: `force.chart()` does nothing in `--benchmark`, so `is_chunk_charted` stays false even at spawn. Be explicit with the user about which of these are untested.
- `runtime-api.json` for the exact installed version is at `D:\SteamLibrary\steamapps\common\Factorio\doc-html\runtime-api.json`. Query it with `ConvertFrom-Json` instead of guessing at 2.1 API changes.

## Files

| File | Role |
|---|---|
| `freight-dispatch/info.json` | `factorio_version` "2.1" |
| `freight-dispatch/data.lua` | 7 cargo items (`fd-*`, stack size 50, so a wagon holds 2,000) and 7 decorative site buildings: `simple-entity-with-owner` borrowing vanilla animations (lab = house, assembler = shop/factory/sawmill, drill, steel furnace, steam engine), with a fallback picture |
| `freight-dispatch/scripts/config.lua` | **All tuning:** prices, cargo rates and decay, site kinds, weights, level thresholds, starter sites, ranks, sight radii, names |
| `freight-dispatch/control.lua` | All game logic (single module `M`, plus a remote interface `freight_dispatch`) |
| `freight-dispatch/scripts/gui.lua` | Left HUD (cash, income, rank, contracts) and screen windows (Shop, Sites, Help, including the HELP text) |
| `tools/fd-test/` | Headless harness mod: a 440-tile line, two towns, a shuttle train and a ghost test |
| `tools/fd-debug/` | Save inspector mod: calls `debug_dump` and logs train snapshots every 10 s. Edit it for one-off investigations |
| `tools/fd.ps1` | test, save and install helper |

## Game design (as built)

- **World:** `on_init` (new game only) creates surface `freight` from nauvis settings, with resource and enemy autoplace `size = 0`, sparse trees, no cliffs, peaceful mode and always day. Players are teleported there and freeplay's crash site, intro and starting items are disabled. Research is disabled, and all recipes are disabled *except* shop items. Those stay "unlocked" so their ghosts can be placed; they still can't be crafted because no materials exist.
- **Sites:** towns, coal mines, iron mines, lumber camps, steel mills, factories and power plants. Each has a catchment ring (towns start at 22 tiles, others 18; read it through `site_radius(site)`, never `C.KINDS[kind].radius`). Four guaranteed starter sites are placed near spawn, and the rest come from a chunk queue: each new chunk has about a 10% chance of a site, at least 100 tiles from other sites, built entirely inside that one chunk so a later chunk generation can't overwrite it. Sites are charted and chart-tagged.
- **A stop serves a site** if it sits within the ring (`linked_sites`, cached in `storage.stop_links`, and the cache is cleared whenever a site is created). New stops are auto-renamed after their site once, at build time. The user may rename them afterwards, and duplicate names are intended (multi-platform stations).
- **Train service:**
  - **Arrival:** service runs **instantly** in `on_train_changed_state` on arrival (before the engine checks wait conditions), then once per second while the train is waiting.
  - **Unload:** instant, with no rate limit. Every cargo *lot* whose origin is at least `MIN_DIST` (60) tiles from the site and is accepted there comes off and is paid. Lots still near their origin **stay aboard**. Untracked surplus (more items than records) is dumped for free. **Back-pressure (0.3.4, Steve asked for vanilla-like behaviour):** at steel mills and factories, only what fits in the input pile (`INPUT_CAP` 20,000 per item) comes off. The rest stays aboard and unloads on later seconds as the pile shrinks, so an "Empty cargo" train waits like a vanilla train at full chests. A throttled chat message (every 5 min per site and item) names the full pile. Towns and power plants have no pile and take everything, so town passenger and mail handling is unchanged. Before 0.3.4 the overflow was paid and then discarded. Steve's train 93 (Birchmouth coal to Elmbridge, which never gets ore) will park at Elmbridge under the new rule.
  - **Load:** `load_rate()` (the Station crews upgrade: 400/600/900/1,400) per wagon per second, **shared evenly between every produced cargo type waiting there**, so passengers can't starve mail.
  - **Drop-off stops:** if the train's *current schedule record* has an **"Empty cargo"** wait condition, the stop is drop-off only. Nothing loads there, and cargo that originated at this site goes back into its stock.
- **Pay** = amount × cargo rate × distance (straight line, origin site to destination site) / 100 × time factor. The time factor is 1 within a grace period of 20 s + distance/12, then decays linearly over the cargo's `decay` seconds, with a floor of 0.25.
- **Production:**
  - **Primary industries** produce `base × (1 + LEVEL_BONUS·(level−1)) × (0.6 + 0.4·rating)` per second (0.3.0: base coal/ore 12, wood 10, `LEVEL_BONUS` 1.0, `LEVEL_AT` ×2.5; before that 5/5/4 and 0.5, so a level-5 mine made only 15/s and starved the chain), with stock capped at `STOCK_CAP × level`. `rating` rises when anything is picked up each minute. Level-ups happen at shipped totals in `LEVEL_AT`.
  - **Towns** produce passengers at pop/60 and mail at pop/400 per second, and **grow only from goods** (0.3.0, Steve's choice): each new resident costs `M.goods_per_resident` = `GOODS_PER_RESIDENT` (50) × max(1, pop/1000) goods, so pop² rises about 40 per good. Without goods a town is stable (never declines). The design loop: passengers and mail are steady income that funds the factory chain, and goods grow cities. History: up to 0.2.1, passengers, mail and plain service all grew towns, compounding about 1%/min. Steve's save reached 96k-pop towns, $45k/s income and $254M lifetime in 8.3 h, with passengers about 75% of income, mail 25% and freight negligible. 0.2.2 tried a sqrt slowdown (`growth_damp`), and 0.3.0 replaced it. Towns add buildings as they grow (pop/120 + 2, max 64) on an 8×8 slot grid at offsets ±5/9/13/17, which leaves a 7-tile clear "railway street" cross through the centre. Every free slot is retried each minute, and a slot is skipped while any player-force entity is within 2.5 tiles, so buildings never box in track. The ring grows (never shrinks) to the outermost building + 12 tiles (`update_ring`, which also clears `stop_links`). Steve asked for this because the old solid grid filled a fixed 22-tile ring. 0.1.9's `relayout_towns` migration rebuilt old towns (any town without `site.built`).
  - **Secondary industries** (`KINDS[k].main/booster/base_yield/full_yield`) process up to `PROCESS_RATE` (50, was 25) × level of the main input per second. Cargo rates (0.3.0): steel 3.0 (was 2), goods 5.0 (was 3). Yield goes linearly from `base_yield` to `full_yield` as the booster covers ½ unit per main unit. The booster alone makes nothing. The steel mill is ore with a coal booster (0.5 → 1). The factory is steel with a lumber booster (1 → 2); before 0.2.0 lumber alone made goods, but Steve's factories were steel-only, so nothing was nerfed.
  - **Status detail line** (`M.site_detail`, a third render text at y−8, and also shown in the Sites list): towns show last minute's goods growth (`site.growth`, accumulated in `grow_acc`) and the goods cost per resident, and industries show the output multiplier, rate and stockpile, or "Idle: needs X".
- **Economy:** you start with $300k. Contracts (up to 3 at a time, 30 min deadline) give a bonus for delivering X units of item to a site, counting **any** train's *paid* deliveries. They only target **served** sites (a stop in the ring, `served_ids()`), for cargo some served site produces, and pairs already delivered (`site.recv`) are 4× as likely. Freight (anything not in `C.TOWN_CARGO`) is a further 3× as likely, has double the amount, and pays amount × rate × 12 (town cargo: × 6). Only with nothing served can they name any site.
- **Clutter cap:** a chunk only gets a site while unserved sites < max(`SPARE_SITES_MIN` 6, served × `SPARE_SITES_RATIO` 0.5) (`room_for_site`). Skipped chunks never get one later. Steve's save had 188 sites with 34 served, so it's effectively closed.
- **Upgrades** (`C.UPGRADES`, `storage.upgrades[id]` = tier, Shop "Upgrades" section, `M.buy_upgrade`):
  - **Fuel:** solid → rocket → nuclear → custom `fd-express-fuel` (×3 acceleration, ×1.4 top speed). `refuel_trains` swaps other tiers out with a full refund. data.lua raises the cargo-wagon `max_speed` to 2 so Express isn't capped by the wagon's 1.5.
  - **Wagons:** 40/60/80/120 slots, via `set_inventory_size_override`, applied every 5 s to all wagons (never shrinks).
  - **Station crews:** the load rate.
  - **Running shoes:** `force.character_running_speed_modifier` +0.5/+1/+2.
  - Prices total about $135M. Locomotive speed can't be changed at runtime, which is why speed comes from fuel. Ranks are based on lifetime earnings; the last rank ($100M) is a "you win" message.
- **Building:** every ghost (cursor, blueprint, map view) is queued and built instantly by `revive`. **Matching items in the placing player's inventory are used first, then cash.** Unaffordable ghosts wait indefinitely; blocked ones retry for about a minute. Trees and rocks in the way are cleared for $10. A floating note summarises each batch. Rail pieces cost what vanilla `items_to_place_this` says: straight 1 rail, half-diagonal 2, curves 3. The deconstruction planner destroys player entities instantly and refunds 75%. The upgrade planner fast-replaces instantly (e.g. signal to chain signal) and charges or refunds the difference.
- **Locomotives** auto-refuel with the current fuel tier at cost every 5 s. Idle trains burn nothing, so there's no upkeep.
- **Cargo never lives outside wagons:** cargo in a player's inventory or cursor (checked every second), in a hand-mined wagon (taken from `on_player_mined_entity`'s buffer) or in a deconstructed wagon goes back to the nearest site that produces it.
- **Map visibility:** each train charts a 64-tile radius around its front every 2 s, each train stop charts 48 tiles every 10 s, and the Shop sells a $5k "Land survey" (512×512 around `player.position`, which is the camera position in remote view). Charting generates chunks, which spawns new sites.
- **Site signals** (0.3.1, Shop $2k, `fd-site-signals` = a deep-copied constant combinator): the player builds it inside a ring (auto-placing was rejected because wires reach only about 9 tiles and rings reach radius 39). `storage.signal_boxes[unit]`. Every second `update_signal_boxes` rewrites section 1 with the nearest linked site's output stock, secondary inputs, and `signal-P` (town pop) or `signal-L` (level), resetting any GUI edits. `circuit-network` is in `C.TECHS` for the wire shortcuts, and `unlock_techs()` reruns on configuration change and then re-disables every non-Shop recipe, so vanilla combinators stay unplaceable. Constant combinators, stops and rail signals need no power. Purpose (Steve wanted it): gate a mill's ore drop-off stop on Coal > 1000, so every ore unit is fully boosted.
- **Decider combinator (no power)** (0.3.4, Shop $5k, `fd-decider` = a deep-copied decider with `energy_source = void`). The vanilla decider stays locked. Help recipes: put the conditions in the decider, output `signal-red` = 1, and enable the stop while `signal-red` = 0. **Pause when full (0.3.4):** a secondary industry processes only what its output pile can hold (`site.output_full`, and the detail line says "Paused: output full").
- **Alerts:** train wreck (`on_entity_died` filtered to rolling stock), and a train waiting at a red signal for 3 min (possible deadlock).
- **Navigation:** Sites list rows are buttons and HUD contract lines are clickable labels. Click → `set_controller{type=remote, position, surface}`; shift-click → teleport the character.

## Storage (all on the single force "player")

`sites[id]` = {kind, name, x, y, level, shipped, delivered, picked_min, rating, stock, input, pop, building_count, built (set of TOWN_SLOTS indices), radius (towns, grown ring), render, tagged} · `stop_links[stop_unit] = {site ids}` · `wagons[wagon_unit][item] = { {amount, ox, oy, tick, site}, ... }` (the lot list; `get_lots()` migrates the old 0.1.0 single-record format) · `waiting[train_id] = LuaTrain` · `stuck` · `ghost_queue` · `chunk_queue` · `contracts` · `money`, `lifetime`, `income_hist`, `rank` · `seed` (own deterministic LCG; never `math.random` after init) · `disabled` (dormant flag) · `throttle` (message rate limiting).

Wagon records are cleaned up through `script.register_on_object_destroyed` → `on_object_destroyed.useful_id`.

## Key decisions and why

- **Dormant in existing saves.** Factorio enables new mods globally. If `on_init` sees `game.tick > 0` (mod added to an old factory save), it sets `storage.disabled`, unregisters every handler (also in `on_load`) and prints a notice. Without this, loading any old save would teleport the player and wipe its research and recipes.
- **Per-origin cargo lots, not one averaged origin.** The 0.1.0 averaged origin drifted when mixed loads accumulated, until cargo "came from" its own destination and jammed the train forever.
- **"Empty cargo" = drop-off.** Steve's schedules naturally use "Empty" at destinations. Loading there meant the train could never empty and would sit forever filling with locals. A more general rule ("cargo back home gets off free") was tried and caused load-then-unload churn every second at towns, which both produce and accept passengers. Don't reintroduce it.
- **Instant unload on arrival.** Otherwise "Full cargo" is already true when a full train arrives, and it leaves without unloading.
- **Fair-share loading.** First-come loading let ~3,700 waiting passengers take all capacity, so mail contracts were impossible.
- **Ghosts over items.** Steve called instant ghost building, charged in cash, a "huge QOL" win. Keep inventory-first, then cash.
- **No power and no radars** in this game, so visibility comes from trains, stops and paid surveys.

## Pitfalls already hit (2.1 API and engine)

- `LuaEntity.active` write was **removed in 2.1**. Use `disabled_by_script`. Check the 2.1 changelog (`data/changelog.txt`, the top ~1,300 lines) for other removals: recipe `category` became `categories`, crafting inventory defines were renamed, and `fluidbox` was removed.
- Map-gen autoplace `frequency = 0` → **NaN noise-expression crash** in `create_surface`. Set `size = 0` only.
- `ghost.revive()` at a position where the real entity can't exist (e.g. a signal overlapping the rail) **returns quietly and leaves the ghost**. In tests, use `can_place_entity` first.
- Straight rails are 2×2. Script-created ones at even x snap to odd centres. Train stops sit ±2 tiles beside the rail; find the offset by checking `stop.connected_rail`.
- Schedules: use `train.get_schedule()` (LuaSchedule: `current`, `get_record{schedule_index=}`, `add_record`). `train.schedule =` may also still work.
- `game.train_manager.get_trains{surface=}` is the 2.x way to list trains.
- **GPS rich text `[gps=x,y,surface]` is only clickable in chat**, not in mod GUI labels, which is why navigation uses real buttons.
- Lua can't define GUI styles at runtime. Stick to known vanilla style names (`frame_title`, `draggable_space_header`, `frame_action_button`, `inside_shallow_frame_with_padding`). `mini_button_aligned_to_text_vertically` was removed for being uncertain.
- The simulation clamps stock with `min(cap, stock + x)`, so stock returned above the cap is trimmed on the next tick. That's acceptable.
- Cargo icons reuse vanilla pictures (wood, coal, iron ore, steel plate, blueprint for mail, iron chest for goods). In 0.3.1 Steve set a stop condition on vanilla **Wood** instead of `fd-wood`, so it never fired. Since 0.3.2 every `fd-*` cargo icon has a small locomotive badge, and since 0.3.3 mail uses its own envelope picture (`graphics/mail.png`, drawn with System.Drawing) (bottom right), and the Help says to pick the freight version. Earlier he also read a mail contract as "deliver 1500 blueprint", which is why contract text includes the cargo name.
- `train_state` numbers seen in logs: 0 = on_the_path, 5 = arrive_station, 6 = wait_station, 8 = manual_control (a train in manual mode is never serviced).
- Rail signal `close_signal` + condition: the signal is **closed while the condition is true** (`signal_state` 3 = reserved_by_circuit_network). A train stop with `circuit_enable_disable` is enabled while its condition is true. Both verified headlessly in fd-test. `is_shortcut_available` errors for vanilla shortcuts.
- A combinator output connector has no circuit network until something is wired to it, so `get_circuit_network(combinator_output_*)` returns nil. The 2.1 decider supports `else_outputs`.

## Gameplay tips the user has been given (keep the Help text consistent)

- Pick-up stops: "Full cargo OR 30 seconds". Drop-off-only stops: "Empty cargo". Two-way passenger lines and loops: "Full cargo OR 30 s" (or "Inactivity 5 s OR 30 s") at every town.
- Loops (A → B → C → A) work for passengers and mail because they're accepted by any town at least 60 tiles from their origin. Freight is directional.
- Don't tear down idle trains (no upkeep). Train groups, multiple platforms sharing a stop name, and 2.0 wildcard interrupts are all usable.

## Not yet verified in-game (built since the user last confirmed)

Inventory-first ghost building, click-to-navigate, map reveal by trains, stops and survey, returning cargo from inventory (verified on a save copy but not live), and Site signals wiring by hand (scripted wiring was verified). Ask the user how these went before building on them.

## Backlog (the user hasn't chosen yet; don't build unasked)

Done in 0.2.0: factory lumber booster, and upgrades (fuel, wagons, loading). **Rejected by Steve:** per-train upkeep or any ongoing cost, and decline of unserved sites. (He first rejected "towns grow mainly from goods", then chose goods-only growth in 0.3.0 once he saw the runaway populations.) **On hold:** anything incentivising expansion (subsidies for unconnected sites, connect-a-site bonuses).

1. **Passengers with destinations** (cargodist-like). Rewards meshed networks and transfers; the biggest gameplay upgrade.
2. More upgrade lines, e.g. industry production or town growth multipliers (keep them chill: one-off purchases, no running costs).
3. Congestion and punctuality scoring that rewards good signalling.
4. Contract rewards scaled to income (flat bonuses are tiny at $60M; Steve didn't ask for this).
5. Challenge maps or scenarios.
6. Smaller ideas: a live list of stuck trains in the HUD, and showing each stop's linked site and pending cargo in the stop's tooltip or GUI.

`debug_dump`, `queue_ghost`, `buy_upgrade`, `site_detail`, `set_input` and `served` remotes in `control.lua` are intentional dev hooks; keep them. Note: a new mod's `on_init` (e.g. fd-debug) runs *before* existing mods' `on_configuration_changed`, so inspect migrations a tick later.
