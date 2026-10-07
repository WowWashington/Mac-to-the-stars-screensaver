# Mac-StarsScreenSaver — STATE

**State**: Stable — September expansion installed on both displays and pushed (`c302ae2`); next contributor issue is #2
**Updated**: 2026-10-06 · **Path**: `~/Projects/Mac-StarsScreenSaver/` · **Repo**: github.com/WowWashington/Mac-to-the-stars-screensaver (public, MIT, main)
**Stack**: Swift 5 mode + runtime-compiled Metal shader, ScreenSaver/QuartzCore/AppKit, no dependencies

> Load this file first; open a `docs/` file only when the task needs it. Keep this file ~4 KB:
> add detail and dated notes to the matching component doc, not here.

## What it is
"Galactic Odyssey" is a procedural space-flythrough screensaver: starfields, galaxies, planets, Saturn rings, nurseries,
black holes and Dyson interiors, plus bundled NASA images. It's the framework source for the screensaver family.

## Components
| Component | Doc |
|---|---|
| **Working recipe + hard-won framework lessons** (all agents) | `CLAUDE.md` |
| Files, architecture, key decisions, config, run | `docs/architecture.md` |
| September expansion + validation + handoff | `docs/expansion-2026-09.md`, `docs/VALIDATION.md` |
| Roadmap issues #1 Europa, #2 flight controls | `docs/roadmap-europa.md`, `docs/roadmap-flight-controls.md` |
| Backlog · history | `docs/backlog.md`, `docs/history.md` |

## Run
`./build.sh preview` (LOOK at PNGs) → `./build/preview Preview --bench --verify-renderer` (< 12 ms at QHD) → `./build.sh install`

## Hard rules
`Uniforms` stay exactly 96 bytes in Swift and Metal. Register new encounter subtypes in Renderer. Review installs separately.

## Now / next
1. Issue #2: flight preferences and reproducible scene/seed/time previews (selected 2026-09-19).
2. Then issue #1: Europa ice flight / Jovian eclipse.

## Related
Framework for #28 Infinity-Hallway → #45 MemoryLane / #46 Elemental, and #31 Amway Showcase.
