# Contributing to Arisen's Ledger

Thanks for helping! There are two kinds of contribution, and the first needs no coding at all.

## 1. Fix or improve a quest note (no coding)

All walkthrough notes live in one file: [`reframework/data/arisens_guide.json`](reframework/data/arisens_guide.json). There is one entry per quest, sorted by quest id.

**Easiest:** open a [Quest note correction](../../issues/new?template=quest-note.yml) issue and describe what actually happened in your game. That's genuinely useful on its own.

**To edit it yourself:**
1. Open the file on GitHub and click the pencil icon. GitHub makes a fork for you.
2. Find the quest (Ctrl+F its name) and edit the text.
3. Click **Propose changes**, then **Create pull request**.

### What a good note looks like

```json
{
  "id": 20130,
  "name": "Saint of the Slums",
  "how": "Steps in order, ending with exactly how the quest finishes ...",
  "decision": true,
  "choices": [ { "option": "short label", "outcome": "what happens", "rewards": "what you get" } ],
  "best": "The single most useful sentence. Shown on the tracker as 'Choice ahead:'.",
  "rewards": "Rewards when there's no choice, else empty",
  "warnings": ["The most important thing first. Shown on the tracker as 'Heads up:'."],
  "follow_ups": "Quests this unlocks or affects",
  "confidence": "high | medium | low",
  "sources": ["https://..."],
  "item_hints": { "Exact In-Game Item Name": "where to get it: shop + town, drop, or quest step" }
}
```

Style that players asked for:
- **Say how each step and the quest ends** in game terms. For example: "grab her in the basement at night; that grab is the arrest, there's no one to report her to".
- **Include timing.** If something only happens at night or after a day, say so, along with how to pass time ("sit on a bench, choose Doze Off").
- **Only mark `decision: true` for real choices** where outcomes or rewards differ. Handing in one of several acceptable items is a turn-in, not a choice. Don't invent bad endings.
- **Make item hints specific.** Say what the item is and where it comes from, including whether it's bought, looted, or given during the quest.
- **Keep it short.** It shows in a small overlay: "how" around 70 words, warnings under 30 words each, at most 4 or 5.
- **Write it in your own words.** Don't paste from guides; add the guide's URL to `sources` instead.
- **ASCII only.** Use straight quotes `'` and `"` and plain hyphens; the in-game font has no curly punctuation.

Before submitting, run `python tools/check_guide.py` (Python 3, no packages needed). CI runs the same check on every pull request.

## 2. Change the code

The mod is a [REFramework](https://github.com/praydog/REFramework) Lua script for Dragon's Dogma 2 on PC.

```
reframework/autorun/arisens_ledger.lua        loader: loads core, catches errors
reframework/autorun/arisens_ledger/core.lua   settings, keys, frame loop
  game.lua    per-frame player/camera/clock state, the game's minimap projection
  model.lua   quests: catalog, status, timers, cut-offs, journal leads, items, shops
  tokens.lua  Seeker's Tokens, chests, enemies
  hud.lua     tracker card, compass, minimap overlay, markers, notices, clock
  ui.lua      the ledger window (F8)
  fonts.lua / util.lua
```

Ground rules:
- **Read-only.** The mod must never change the game state or the save. The only file it writes is its settings (`reframework/data/arisens_ledger.json`).
- **Wrap every game call in `try(...)` / `pcall`**, because game types can change between patches. A failed read should hide one feature, not crash the overlay.
- **Keep per-frame work light.** Heavy scans are spread out (quests are scanned a few per frame; chests every 1.5 s).
- **Test in game** with REFramework open (Insert) and check `re2_framework_log.txt` for errors. Say in the pull request what you tested.

CI checks that every Lua file compiles (`luac -p`), but it can't run the game, so in-game testing is on you.

## Releasing (maintainer)

Bump `VERSION` in `core.lua` and add a `## x.y.z` section at the top of `CHANGELOG.md`, then push to `main`. The Release workflow notices the new version, builds the zip and publishes release `vx.y.z` with that changelog section as its notes.

## Reporting bugs

Use the [Bug report](../../issues/new?template=bug-report.yml) template. Include your resolution, HUD scale and REFramework build. A screenshot plus any "Arisen's Ledger" lines from the REFramework log help enormously.

## Licence

By contributing you agree that your contribution is released under the project's [MIT licence](LICENSE).
