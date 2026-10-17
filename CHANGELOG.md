# Changelog

## 1.0.1 (2026-10-17)

- The compass, minimap and tracker now point to the most likely **next** stop when a quest names several people or places, not just the nearest one. Order of preference: items you still need (storage or shop), the game's own objective for the step, open journal leads (newest first) and people with a quest conversation ready, then everyone else involved, then places a later journal entry names.
- The tracker card shows that stop under **NEXT** and lists the rest under **ALSO IN THIS QUEST**, each with the reason it's there ("journal lead", "ready to talk", "involved"...). The ledger's Where list uses the same order.
- Pinned and other in-progress quests on the compass also use the best stop instead of the nearest.

## 1.0.0 (2026-10-15)

First public release.

- Quest ledger (F8): Overview, Quests, At Risk, Timers, Explore and Settings pages, covering the base game and Dark Arisen.
- Tracker card, compass strip, world markers and a minimap overlay that follows the game's minimap zoom.
- Timers read from the game, labelled by kind (deadline, may run out, waiting period, window before accepting), with notices at 24, 6 and 1 hours.
- Cut-off warnings: quests that the main story will cancel, and when.
- Journal-aware leads, deduplicated people and places, quest-givers shown only when they're ready to talk.
- Seeker's Token direction dial, chests and enemies on the minimap, a 24-hour clock, Ibrahim's forgery countdown.
- Missing quest items: checks your pawns and storage, then routes you to the nearest inn or a shop that sells the item.
- Walkthrough notes for all 120 quests: steps, timing, choices and outcomes, best path, warnings and item sources.
