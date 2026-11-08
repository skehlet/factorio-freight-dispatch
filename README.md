# Freight Dispatch

A Factorio **2.1** mod that replaces the factory game with a railway tycoon game. Towns and industries are scattered across a fresh map. Buy track, signals and trains with money, then earn by hauling passengers, mail and freight between sites. Pay depends on distance and delivery speed. Industries and towns grow when served well, so busy shared lines need good signalling.

Base game only (no Space Age needed). Enable it for **new games only**: added to an existing save, it stays dormant.

## Features

- Procedurally placed towns, mines, lumber camps, steel mills, factories and power plants, each with a catchment ring for your stations
- Passengers and mail between towns, plus freight supply chains (ore + coal → steel, steel + lumber → goods)
- Ghosts build instantly and are paid in cash. The deconstruction and upgrade planners also act instantly.
- Contracts for routes you already run
- Progression upgrades: faster fuel, bigger wagons, quicker station crews and running shoes
- Ranks based on lifetime earnings

## Install

Copy the `freight-dispatch/` folder into `%APPDATA%\Factorio\mods\`, then restart Factorio and start a new game.

## Development

`tools/fd.ps1` runs headless tests and installs the mod:

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\fd.ps1 test|save|install
```

`tools/fd-test` is a test-harness mod and `tools/fd-debug` is a save inspector. See `CLAUDE.md` for design notes.

## License

MIT. See `LICENSE`.
