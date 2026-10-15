# Arisen's Ledger

by [whiteyt223](https://github.com/whiteyt223)

**A quest ledger, tracker and minimap overlay for Dragon's Dogma 2 (PC), built so you never miss a quest or let one time out. Includes Dark Arisen.**

Dragon's Dogma 2 rarely tells you that a quest has a clock on it, that advancing the story will cancel it, or where the person you need actually is. Arisen's Ledger reads that straight from the game and puts it on screen: a quest tracker, a compass, markers on your minimap, live countdowns, and walkthrough notes for every quest, including what each choice leads to.

It is a [REFramework](https://github.com/praydog/REFramework) Lua script. It only **reads** game state and draws over it. It never changes your save or the game.

> **Spoilers:** the walkthrough notes describe quest outcomes, including Dark Arisen's. Quests you haven't unlocked are hidden by default ("Spoiler-safe mode" in Settings), and you can turn the notes off entirely.

---

## Features

### Never miss a quest
- **Every quest in one ledger:** available, in progress, locked, completed, failed and missed, across the base game and Dark Arisen.
- **At Risk page:**
  - quests on a clock;
  - quests that will be cancelled when you finish a particular main-story quest (taken from the game's own end conditions);
  - how soon each one matters.
- **Real timers, read from the game.** Each countdown is labelled by type:
  - a deadline the quest fails on;
  - a step that may run out;
  - a waiting period ("come back in a day");
  - a window before you have even accepted the quest.

  Each shows in-game hours plus roughly how much real play time that is.
- **Notices** when a new quest becomes available, when a clock drops below 24, 6 and 1 hours, and when a person a quest depends on dies.

### Know where to go
- **Tracker card:**
  - the current task and the game's longer description;
  - every person and place for the quest, stacked nearest first with distance and direction;
  - item counts, timers and anything that would cut the quest off.
- **Journal-aware.** It reads the quest journal's open leads, so you see "Radcliff, Jehan, Merchant Quarter" instead of a vague task line. It also adds places the game has already named, such as the cave the wolves dragged someone to.
- **Compass strip** across the top, with markers in the world that fade with distance.
- **Minimap overlay** drawn on the game's own minimap, following its zoom in towns, in the field and while sprinting:
  - your objectives;
  - quest-givers who are ready to talk right now (hollow diamonds);
  - enemies (red dots);
  - unopened chests (orange; larger if they hold gear).
- **Seeker's Tokens:** a 3D direction dial beside the minimap appears when you're within 15 m of one.
- **Missing items:** if a quest wants something you don't have, it checks your pawns and your storage. Then it points you to the nearest inn (storage) or the nearest shop that sells the item.
- **Ibrahim's forgeries:** a live countdown until the copy is ready.
- A 24-hour **clock** under the minimap.

### Know what you're getting into
- **Walkthrough notes for all 120 quests:**
  - steps, written to say exactly how each quest ends;
  - timing (and how to pass time: doze on a bench);
  - choices and their outcomes and rewards, plus the best path;
  - warnings, and where to get each required item.
- Quests with a real decision get a **CHOICE** flag. The best path also shows on the tracker as a single line.

---

## Requirements

- Dragon's Dogma 2 on PC (Steam). Tested on the Dark Arisen update.
- Dark Arisen is **optional**. Without it, the mod should simply ignore the expansion's quests. That case is untested, so please open an issue if expansion quests show up anyway.
- [REFramework](https://github.com/praydog/REFramework-nightly/releases) for DD2: a **nightly build recent enough for the current game patch**. Tested with nightly 1432. Older stable builds may not run on the Dark Arisen patch.

## Install

1. Install REFramework: put `dinput8.dll` from the DD2 build into the game folder (next to `DD2.exe`). Launch the game once and check that the REFramework menu appears (Insert key).
2. Copy the `reframework` folder from this mod into the game folder, merging with the existing one:
   ```
   Dragons Dogma 2/
     reframework/
       autorun/arisens_ledger.lua
       autorun/arisens_ledger/*.lua
       data/arisens_guide.json
       fonts/  (Cinzel, Alegreya Sans + their licences)
   ```
3. Start the game and load your save. The HUD appears once you're in the world.

To update, overwrite the files. To uninstall, delete `autorun/arisens_ledger.lua`, `autorun/arisens_ledger/` and `data/arisens_guide.json` (and `data/arisens_ledger.json` to clear your settings).

## Controls

| Key | Action |
| --- | --- |
| **F8** | Show / hide the ledger window |
| **F6** | Show / hide the whole HUD |
| **F7** | Cycle the stand-alone radar's range (only when the minimap overlay is off) |
| **Insert** | REFramework menu. The ledger needs it open to use the mouse, so by default the ledger only shows while it's open. |

In the ledger, **Navigate here** makes a quest the one the compass and tracker follow. **Pin to HUD** keeps a quest's nearest goal on the compass alongside it.

## Settings

Everything is in the ledger's **Settings** page and saved to `reframework/data/arisens_ledger.json`. You can switch off each HUD element, change HUD scale and opacity, and choose whether to show enemies, chests and tokens. You can also turn the walkthrough notes and tracker hints on or off, hide the HUD in combat, and set spoiler-safe mode.

## How it works

The script reads the game's own data through REFramework:
- the quest manager, quest log and journal entries;
- the time conditions behind quest steps, and the hand-in (delivery) data;
- NPC positions and whether they'll start a quest conversation;
- the item and shop tables, and the minimap's projection.

The walkthrough notes are a static file (`data/arisens_guide.json`), written in our own words from community guides; see [CREDITS.md](CREDITS.md).

It writes nothing but its own settings file.

## Known limitations

- **Screen layout:** built and tested at 16:9. The minimap overlay assumes the game's default HUD layout and scale, so ultrawide screens or a changed HUD scale may put the pips a little off the minimap.
- **Thin Dark Arisen coverage:** guides for the expansion are still sparse. A handful of its notes are marked as best guesses in the ledger, as are some reward tiers whose conditions nobody has documented yet.
- **Notes can be wrong:** the notes come from community walkthroughs and may contain mistakes. Corrections are welcome (see below).
- **Item hints:** these only appear once the game actually asks you for an item.

## Contributing

Corrections and improvements are welcome. The quest notes are a single JSON file, so fixing one needs no coding. See [CONTRIBUTING.md](CONTRIBUTING.md) for the note format and style. You can also open a **Quest note correction** or **Bug report** issue at https://github.com/whiteyt223/arisens-ledger/issues.

## AI disclosure

This mod was built with substantial help from an AI assistant (Anthropic's Claude). That covers the Lua code, and the research and wording of the walkthrough notes, all directed and play-tested by a human. If you post it to a site that asks for this disclosure (for example Nexus Mods' AI tags), tag it accordingly.

## Credits and licence

- Code: MIT licence, see [LICENSE](LICENSE).
- Fonts: [Cinzel](https://github.com/NDISCOVER/Cinzel) and [Alegreya Sans](https://github.com/huertatipografica/Alegreya-Sans), both under the SIL Open Font License 1.1 (licences in `reframework/fonts/`).
- Walkthrough sources and thanks: [CREDITS.md](CREDITS.md).
- Built on [REFramework](https://github.com/praydog/REFramework) by praydog.

Dragon's Dogma is a trademark of Capcom. This is an unofficial fan project, not affiliated with or endorsed by Capcom.
