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

## File Structure

```
Mac-StarsScreenSaver/
├── Sources/
│   ├── ShaderSource.swift   # entire Metal shader as a Swift string (the visuals)
│   ├── Uniforms.swift       # 96-byte uniform struct, must match Metal layout exactly
│   ├── Director.swift       # scene scheduler: regions, palettes, seeds, crossfades
│   ├── Renderer.swift       # Metal device/pipeline, renders to texture or CAMetalLayer
│   └── SaverView.swift      # @objc(GalacticOdysseyView) ScreenSaverView, CAMetalLayer-backed
│   └── HUD.swift            # starship cockpit overlay (CALayers, edge-only telemetry)
├── Harness/main.swift       # offscreen renderer -> Preview/*.png for visual QA
├── select_saver.py          # patches wallpaper-store Index.plist for ALL displays/spaces
├── LICENSE                  # MIT (code only; images excluded — see note inside)
├── SeedImages/              # 14 bundled images: NASA archive (PIA*, hubble*) +
│   │                        #   publicdomainpictures.net CC0 set (provenance in CREDITS.md);
│   │                        #   *milky*/*galaxy* filenames feed the galaxy-approach photo pool
│   └── unverified/          # excluded: composite art + saved webpage w/ NASA logos
├── Preview/                 # rendered QA frames (gitignore-able)
├── Info.plist               # NSPrincipalClass = GalacticOdysseyView
├── build.sh                 # build | preview | install
└── build/                   # artifacts incl. GalacticOdyssey.saver
```

---

## Architecture & Key Decisions

1. **Single fullscreen-triangle Metal fragment shader** does all rendering (Shadertoy-style). No geometry, no assets.
2. **Shader compiled at runtime** from a Swift string — avoids needing the Xcode metal toolchain; CLT-only `swiftc` builds everything.
3. **Saver binary is a dylib** built with `swiftc -emit-library`, used as bundle executable; `NSBundle.load()`/dlopen accepts it (verified). Universal arm64+x86_64 via lipo.
4. **Scene system**: Director emits `Uniforms` each frame. Scene types: 0 cruise, 1 galaxy (far = flat sprite/archive photo growing from a dot; close = VOLUMETRIC 10-step jittered ray-march of a 3D disk density field for true parallax depth, handoff covered by a dust-veil pulse; entry populates the disk with mini solar systems — animated planets orbiting seeded stars — at 3 parallax depths; galaxy-approach photos auto-picked from SeedImages files named *milky*/*galaxy*, scn.y = image index+1, scn.z = aspect), 2 SOLAR SYSTEM transit (38-48s: camera flies through a system of 5 planets + positional sun, 28% binary pair in mutual orbit; planet i=2 is the sunward "hero" close-flyby whose type/rings come from scene params; golden-angle spread avoids clumping; distant planets render as phase-lit dots; AA'd limbs, fractal bump on rocky worlds, sunset terminator band), 3 warp, 4 encounter (subtypes: 0 Dyson sphere — flags=stage: 0 Niven ring band, 1 half-built shell, 2 complete sphere with 52-62s fly-THROUGH journey (exterior → bore entry → inner-surface overflight with oceans/ranges/arcology lights under captive sun → bore exit, spatial radial blends between phases); 1 black hole, 2 comet swarm, 3 Dyson swarm — orbital glint shells + near collector passes), 5 deepfield (NASA archive image with slow pan/zoom + parallax stars; only scheduled when bundled images exist; scn.y carries image index from Director, host swaps it for SCREEN aspect before encode and binds the texture; scn.z = image aspect). A "region" = shared color palette + 2-3 scenes, then a warp jump leads to the next region (new palette/seeds). Crossfades render both scenes and mix (transition < 1). The show always OPENS on a Milky Way-style galaxy (blue/silver palette, 34-42s) growing from a dot as we fly into it.
9. **HUD**: optional cockpit overlay (default ON, full-size screens only). Toggle via the Options… sheet in System Settings → Screen Saver (configureSheet in SaverView.swift), or `defaults -currentHost write com.petersheppard.GalacticOdyssey ShowHUD -bool NO`. CALayer-based so text stays crisp regardless of the 3D render cap. Director supplies telemetry (`hudInfo(at:)` — call after `uniforms(at:)`): sector/target names per region/scene, speed model per scene type, warp shows blinking amber "WARP ACTIVE" + DEST sector.
10. **Multi-display gotcha**: System Settings sometimes rewrites Idle entries with provider `com.apple.wallpaper.choice.screen-saver`, which CANNOT host legacy .saver bundles → that display falls back to a built-in saver. Fix: `python3 select_saver.py && killall WallpaperAgent` (now run automatically by `./build.sh install`). All Idle entries must use `com.apple.NeptuneOneExtension`.
11. **Motion convention**: depth-layer patterns use `q = uv * depth * K` with depth shrinking over time, so stars/comets stream OUTWARD (toward the viewer); warp streak phase uses `+t` so heads race outward. Getting either sign wrong makes travel look reversed — this was a real bug, fixed 2026-06-10. All approaching bodies grow from a dot (planet z from 17, dyson z from 22, black hole scale from 0.05, galaxy zoom from 0.10).
5. **Per-scene uniqueness**: each scene gets a random seed driving galaxy arm count/winding, planet type/rings/tilt/sun angle, palette hues, etc.
6. **Perf**: render resolution capped ~3.7 Mpx in SaverView (QHD-ish upscale on 4K+), 60 fps target. Measured 2026-06-10 via `./build/preview Preview --bench` (QHD, this Mac mini): warp 2.0ms, dyson interior 4.1, black hole 5.8, galaxy 7.9, system 8.0, comets 8.8, cruise 11.9, worst transition ~9ms — all under the 16.7ms/60fps budget with ~2-8x headroom.
7. **Principal class** is `@objc(GalacticOdysseyView)` so NSPrincipalClass lookup needs no Swift module prefix.
8. **Uniforms layout**: SIMD4 fields first, then SIMD2, floats, Int32s — identical 96-byte layout in Swift and MSL; edit both together or rendering breaks silently.

---

## Configuration & Secrets

No secrets. Install-time configuration (already applied):
- `defaults -currentHost write com.apple.screensaver idleTime -int 300` (5-min idle trigger)
- `defaults -currentHost write com.apple.screensaver moduleDict ...` (legacy selection path)
- macOS 26 wallpaper store: all `Idle` choices in `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` patched to `Provider=com.apple.NeptuneOneExtension`, `Configuration={module:{relative:file:///...GalacticOdyssey.saver}}` (script pattern preserved at /tmp/set_saver.py during the session; backup of original at /tmp/Index.backup.plist that session only). `killall WallpaperAgent` to reload.

---

## Running / Deployment

```
./build.sh            # build harness + saver bundle
./build.sh preview    # + render QA frames to Preview/
./build.sh install    # + copy to ~/Library/Screen Savers/
open -a ScreenSaverEngine   # manual run (note: modern macOS may route via WallpaperAgent instead)
```
Ad-hoc codesigned; locally built so no quarantine/Gatekeeper issues.

---

## What's Complete

- All five scene types (incl. rare encounters: Dyson sphere, black hole, comet swarm) + crossfade transitions, rendered and visually QA'd via harness PNGs
- Director timeline (regions, palettes, warp-between-regions, sleep-resync guard)
- Saver bundle builds, loads, instantiates, renders (verified via Bundle.load() test)
- Installed to `~/Library/Screen Savers/GalacticOdyssey.saver`
- Selected as system screensaver via Index.plist patch (survived WallpaperAgent restart); idleTime 300s

## What's In Progress

- Nothing. Verified 2026-06-10 two ways: (1) system `legacyScreenSaver.appex` host loaded the bundle (lsof), and (2) after screen-recording was granted, `screencapture` during a live ScreenSaverEngine run showed the saver actually rendering on the display.

## What's NOT Implemented (Future Work)

- Configure sheet (speed/scene-mix options)
- More encounter subtypes: binary stars, asteroid belts w/ rocky silhouettes, nebula pillars, ringworld arcs, pulsars
- Thumbnail shows in System Settings but could be nicer (currently galaxy frame via sips)
- Git repo / versioning

---

## Git History (recent)

```
f93ca1a restore publicdomainpictures.net images with documented provenance
0d8a28d document volumetric patterns in claude.md
bb45aec volumetric raymarched galaxy for true 3d depth
31de5a5 open on real nasa milky way image; continuous growth for mini systems
f0f3e77 note starlayer cost and bench contention caveat in claude.md
634ee45 populate galaxy entry with resolved mini solar systems
7c7baa5 add project claude.md: scene recipe, perf budget, image and licensing rules
1949804 add dyson swarm and staged dyson spheres with interior fly-through
d89afac add options sheet with HUD toggle in system settings
3b0ebe7 initial release: procedural space screensaver with NASA deep-field scenes
```
Local repo only (main branch) — no GitHub remote yet; push deliberately when ready to publish (`gh repo create Mac-StarsScreenSaver --public --source . --push`). .gitignore excludes build/, Preview/, SeedImages/unverified/. Consider a README + screen-recording GIF before publishing.

---

## Current Status

**Last updated**: 2026-06-10 (end of initial build marathon, Fable 5 session)
**State**: Active — installed, selected for all displays, verified live on-screen earlier in session
**Recent changes**: Volumetric ray-marched galaxy (true 3D depth, dust-veil handoff); galaxy entry populated with animated mini solar systems; opening uses real archive Milky Way photos (3-image pool); publicdomainpictures.net CC0 images restored with documented provenance (14 images bundled); Dyson stages + swarm; solar-system transits; starship HUD with Options sheet; MIT LICENSE + CREDITS for GitHub sharing.
**Next steps**: Owner plans to continue with a cheaper model — CLAUDE.md holds the scene recipe, perf budget, and gotchas; ALWAYS use the `./build.sh preview` + `--bench` loop and view the PNGs before installing. Candidate features: pulsar/asteroid-belt/nebula-pillar encounters; README + demo GIF before GitHub publish (`gh repo create Mac-StarsScreenSaver --public --source . --push`).
