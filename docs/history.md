# Mac-StarsScreenSaver — History

Original overview/intent, completed list, git log, moved verbatim from STATE.md.

> Component detail. Start at `STATE.md` in the project root.

# Mac-StarsScreenSaver - Project State

> Resume instruction: "Read STATE.md to understand where we are in the project and what needs to happen next. Do not review the previous chat history."

## Project Overview

**Mac-StarsScreenSaver ("Galactic Odyssey")** — a fully procedural macOS screensaver that flies through space: starfield cruises, spiral-galaxy approaches/entries, planet flybys (terran / gas giant / lava / ice, optional rings), connected by Star Wars/Stargate-style warp jumps. Every scene is randomly seeded so no two runs look alike.

- **Language/Stack**: Swift 5 mode (Swift 6.3 toolchain), Metal fragment shader (compiled at runtime via `makeLibrary(source:)` — no Xcode project needed)
- **Dependencies**: none (system frameworks only: ScreenSaver, Metal, QuartzCore, AppKit)
- **Repo**: https://github.com/WowWashington/Mac-to-the-stars-screensaver (public, MIT)
- **Local path**: `/Users/automator/Projects/Mac-StarsScreenSaver/`

---

## Intent & Use

Personal screensaver for Peter's Mac mini. Runs automatically when the machine idles 5 minutes. Goal: always-changing, cinematic space flythrough (SGU/Star Wars/Trek vibes), procedurally generated so it never repeats.

---

## What's Complete

- All five scene types (incl. rare encounters: Dyson sphere, black hole, comet swarm) + crossfade transitions, rendered and visually QA'd via harness PNGs
- Director timeline (regions, palettes, warp-between-regions, sleep-resync guard)
- Saver bundle builds, loads, instantiates, renders (verified via Bundle.load() test)
- Installed to `~/Library/Screen Savers/GalacticOdyssey.saver`
- Selected as system screensaver via Index.plist patch (survived WallpaperAgent restart); idleTime 300s

## Git History (recent)

```
55b1a79 add agents.md mirror of claude.md for cross-tool compat
fddaed1 update state: publish notes, remote already configured
a9d3498 close out 8-run improvement loop in state
f57b0dd final polish: pulsar pulse concentrated, filamentary shells, denser galaxy march
1c083be refresh readme with demo gif and new scenes; add gif renderer tool
24f0655 polish pass from full-frame visual audit
```

Remote: `origin` → https://github.com/WowWashington/Mac-to-the-stars-screensaver.git.

---
