# Lorewalker : QoL

Standalone addon with optional quality-of-life features and compatibility bridges for Lorewalker.

## Layout and loading

- `LorewalkerQoL.toc` declares addon metadata and optional dependencies.
- `LorewalkerQoL.lua` creates the shared namespace and initializes registered modules.
- `LorewalkerQoL.xml` loads module files after the core entry point; its order is the Lua load order.
- `Integrations/<Addon>/` groups compatibility code by the external addon it connects to.
- `Features/<Area>/` groups player-facing features by the Lorewalker UI they affect.
- `assets/images/` contains image assets bundled with LorewalkerQoL.

| Module | Purpose | Dependencies |
| --- | --- | --- |
| `Integrations/PrettyTooltip/PrettyTooltip.lua` | Moves PrettyTooltip's panel host with Lorewalker's tooltip during HideUI. | Lorewalker, PrettyTooltip |
| `Integrations/Spoken/SpokenImmersivePagination.lua` | Syncs immersive paragraph changes and playback pace with Spoken captions. | Lorewalker, Spoken |
| `Integrations/Spoken/SpokenQuestControls.lua` | Adds pause and skip controls for Spoken quest clips. | Lorewalker, Spoken |
| `Features/QuestRewards/PawnUpgradeArrow.lua` | Marks fixed and choice item rewards Pawn identifies as upgrades. | Lorewalker, Pawn |
| `Features/QuestRewards/HighestSellPrice.lua` | Marks the choice option with the highest total vendor value (unit price × count). | Lorewalker |

## Module lifecycle contract

1. Add the Lua file to `LorewalkerQoL.xml` in the intended load order. Declare optional addon dependencies in the TOC when needed.
2. Capture the shared namespace with `local _, addon = ...`, define an idempotent `Initialize()` function, then register it once with `addon.RegisterModule(name, Initialize)`.
3. Check required globals and APIs before installing hooks or creating listeners. Return `false` when a prerequisite is not ready; the core will try again on a later supported `ADDON_LOADED` event or at `PLAYER_LOGIN`.
4. Return `true` (or anything except `false`) after successful initialization. The core then marks the module initialized and will not initialize it again.
5. Guard hooks and other per-object setup so retries cannot install duplicates. If an initializer throws, the core reports the error through WoW's error handler and leaves the module eligible for a later retry.

LorewalkerQoL owns its runtime code and bundled assets; it does not require files from an installed DialogueUI addon.
