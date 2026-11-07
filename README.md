# Lorewalker : QoL

Standalone addon for optional quality-of-life features and compatibility bridges for Lorewalker.

## Structure

- `LorewalkerQoL.lua` creates the shared namespace and initializes registered modules.
- `LorewalkerQoL.xml` loads the module files after the main entry point.
- `Integrations/<Addon>/` contains compatibility modules grouped by addon.
- `Features/<Area>/` contains player-facing features grouped by the part of the UI they affect; quest reward features live in `Features/QuestRewards/`.
- `assets/images/` contains image assets bundled with this addon.

Add new Lua modules to `LorewalkerQoL.xml` and register them through the shared namespace. All runtime code and assets in this addon are independent of the installed DialogueUI files.
