# ForeverLootTracker (WoW Forever)

Session-based **loot and money tracker** for [WoW Forever](https://warcraft.wiki.gg/) (`Interface: 16001`).

Functional recreation of the WildStar addon [FSLootTracker](https://github.com/NexusInstruments/FSLootTracker). A local `_wildstar_ref/` tree may exist for development reference; it is gitignored and never loaded by the client or shipped in releases.

## What it does

- Captures personal and party/raid loot from `CHAT_MSG_LOOT`
- Captures money from `CHAT_MSG_MONEY`
- Tags loot with a likely **source** from encounter events + last readable target/mouseover (Forever blocks addon combat-log access)
- Quality + source filters, ignore / watch lists
- Editable cost + looter per entry
- Money stats: total, per hour, average, largest, junk sell value
- Export: CSV, JSON, BBCode, HTML
- Optional session persistence via `SavedVariables`

## Commands

| Command | Action |
| --- | --- |
| `/flt` `/foreverloot` `/floot` | Toggle tracker window |
| `/flt clear` | Clear current session |
| `/flt export` | Open export window |
| `/flt debug` | Toggle debug chat |

## UI tips

- **Left-click** a row → edit cost / looter (or delete)
- **Right-click** → ignore that item ID (removes matching rows)
- **Shift-right-click** → toggle watch list
- **Shift-click** → insert item link into chat

## WildStar → Forever mapping

| WildStar | Forever |
| --- | --- |
| `ChannelUpdate_Loot` / `LootedItem` | `CHAT_MSG_LOOT` parse via `LOOT_ITEM_*` globals |
| `LootedMoney` | `CHAT_MSG_MONEY` |
| `LootRollWon` / `LootAssigned` | chat patterns for won rolls / given loot |
| `CombatLogDamage` kill source | Forever-safe: `ENCOUNTER_START` + readable `target`/`mouseover` (no CLEU) |
| Apollo list forms + JSON export | `CreateFrame` UI + CSV/JSON/BBCode/HTML builders |
| Objective-tracker watched loot | in-window ★ watch highlight + chat alert |
