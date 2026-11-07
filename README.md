# Lorewalker : QoL

Standalone addon for optional quality-of-life features and compatibility bridges for Lorewalker.

## Structure

- `LorewalkerQoL.lua` creates the shared namespace and initializes registered modules.
- `LorewalkerQoL.xml` loads the module files after the main entry point.
- `data/Comp/<Addon>/` contains integrations grouped by addon.
- `data/QoL/` contains player-facing improvements.
- `assets/images/` contains image assets bundled with this addon.

All runtime code and assets in this addon are independent of the installed DialogueUI files.
