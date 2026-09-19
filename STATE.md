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
│   ├── Renderer.swift       # specialized Metal pipelines, linear HDR crossfades
│   └── SaverView.swift      # @objc(GalacticOdysseyView) ScreenSaverView, CAMetalLayer-backed
│   └── HUD.swift            # starship cockpit overlay (CALayers, edge-only telemetry)
├── Harness/main.swift       # scene PNGs, QHD benchmarks, --verify-renderer
├── Tests/DirectorChecks/    # CPU timeline / image-slot / ABI invariants
├── select_saver.py          # patches wallpaper-store Index.plist for ALL displays/spaces
├── AGENTS.md                # mirror of CLAUDE.md for tools that look for AGENTS.md instead
├── LICENSE                  # MIT (code only; images excluded — see note inside)
├── SeedImages/              # 21 bundled images: NASA archive (PIA*, hubble*) +
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

1. **Fullscreen-triangle Metal rendering**, with scene functions kept in one source string. The renderer prebuilds 28 pipelines specialized by SceneKind / encounter subtype and direct / HDR output. Single scenes render straight to BGRA8; crossfades accumulate two weighted linear renders in a cached RGBA16Float target and tonemap once. No mesh assets or third-party runtime dependencies.
2. **Shader compiled at runtime** from a Swift string — avoids needing the Xcode metal toolchain; CLT-only `swiftc` builds everything.
3. **Saver binary is a dylib** built with `swiftc -emit-library`, used as bundle executable; `NSBundle.load()`/dlopen accepts it (verified). Universal arm64+x86_64 via lipo.
4. **Scene system**: Director emits `Uniforms` each frame. Scene types: 0 cruise, 1 galaxy (far = flat sprite/archive photo growing from a dot; close = VOLUMETRIC 10-step jittered ray-march of a 3D disk density field for true parallax depth, handoff covered by a dust-veil pulse; entry populates the disk with mini solar systems — animated planets orbiting seeded stars — at 3 parallax depths; galaxy-approach photos auto-picked from SeedImages files named *milky*/*galaxy*, scn.y = image index+1, scn.z = aspect), 2 SOLAR SYSTEM transit (38-48s: camera flies through a system of 5 planets + positional sun, 28% binary pair in mutual orbit; planet i=2 is the sunward "hero" close-flyby whose type/rings come from scene params; golden-angle spread avoids clumping; distant planets render as phase-lit dots; AA'd limbs, fractal bump on rocky worlds, sunset terminator band), 3 warp, 4 encounter (subtypes: 0 Dyson sphere — flags=stage: 0 Niven ring band, 1 half-built shell, 2 complete sphere with 52-62s fly-THROUGH journey (exterior → bore entry → inner-surface overflight with oceans/ranges/arcology lights under captive sun → bore exit, spatial radial blends between phases); 1 black hole, 2 comet swarm, 3 Dyson swarm — orbital glint shells + near collector passes), 5 deepfield (NASA archive image with slow pan/zoom + parallax stars; only scheduled when bundled images exist; scn.y carries image index from Director, host swaps it for SCREEN aspect before encode and binds the texture; scn.z = image aspect), 6 HOME SYSTEM (62-74s guided tour of OUR real Solar System, one body at a time: opens on the Sun from deep space, then a fixed itinerary — Sun, Venus/Mercury, EARTH+MOON hero close pass, Mars, Jupiter, Saturn w/ rings — each body a straight-line fly-by that grows from a far dot, lingers at closest approach via an eased pow(|w|,1.7) travel curve, and exits behind; per-kind fixed colors/bands/rings in shader homeSurface(), consistent single sunToward light dir, Earth has clouds+ice caps+night-side city lights; two seed-picked itinerary orderings; Director shows per-leg HUD target names; uncommon-but-not-rare, at most once per region). A "region" = shared color palette + 2-3 scenes, then a warp jump leads to the next region (new palette/seeds). Crossfades render both scenes and mix (transition < 1). The show always OPENS on a Milky Way-style galaxy (blue/silver palette, 34-42s) growing from a dot as we fly into it.
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
- Europa eclipse expedition and flight preferences: GitHub issues #1 and #2. Nebula pillars and inhabited Dyson arcologies are implemented.
- Thumbnail shows in System Settings but could be nicer (currently galaxy frame via sips)

---

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

## Current Status

**Last updated**: 2026-09-05 (nightly checkpoint — pushed the expansion below)
**State**: Expansion installed and selected for both displays. Installed executable matches the verified universal build, all 21 images are bundled, and both Idle entries use NeptuneOneExtension. Source and refreshed demo pushed to origin/main.

**September expansion**:

1. Scene 7 `.rings`: 58–68s continuous Saturn → A-ring / Cassini division skim → Enceladus south-polar plume survey → departure. Oblate globe, mutual ring/planet shadows, band antialiasing, nearby ice fragments, cratered ice and tiger stripes. Analytic Gaussian plume integration avoids noisy ray steps. Enceladus/flight scales are deliberately cinematic.
2. Scene 8 `.nursery`: 38–48s procedural volumetric dust pillars. Tight ellipsoid bounds with six samples per intersected pillar keep close approaches economical; blue ionized crowns and embedded stars. Inspired by observations, not a 3D reconstruction of a specific NASA photo.
3. Black-hole subtype1: 44–52s distant arrival → inclined orbit → photon-ring close pass → outward departure. Sheared disk filaments, flare trail, structured jet. Camera radius stays ≥7.3 horizon radii. Cinematic Schwarzschild-inspired integration; never crosses the horizon and emerges again.
4. Complete Dyson interiors: actual concave habitat sphere, displaced land/oceans, central star, 16 radially anchored original procedural buildings (terraced gardens, needle observatories, glass habitats, twin skybridges). Tight box bounds and analytic intersections for box-based structures; no imported sci-fi assets.
5. Added verified NASA archive images: Cosmic Cliffs `carina_nebula` and Helix Nebula `PIA18164`. Both inspected and credited; 21 JPGs bundled. Code remains MIT; NASA and partner imagery remain separately credited.
6. Director follows its opening galaxy with a randomly selected signature expedition (Saturn, inhabited Dyson, or black hole), then resumes varied regions. New scene weights and phase-specific HUD targets. Opening photo collision fixed; invalid galaxy-image indices filtered.
7. Renderer isolates scene/subtype workloads with function constants. Added HDR crossfade regression checks; Uniforms still exactly 96 bytes. SceneKind is CaseIterable; new encounter subtype ranges must also be registered in Renderer.
8. Trimmed background noise cost and softened single-cell star/comet boundaries. Refreshed README screenshot grid and 41s demo.gif (328 frames, 8 fps, 440×248,~12.2MiB).

**Validation**:

- `./build.sh preview`: universal build passes; relevant new and changed PNGs viewed.
- `./build/preview Preview --bench --verify-renderer`: all 23 sampled QHD benchmarks <12ms, final range 1.31–9.76ms; tested crossfades 5.17/6.11ms. Full timings and caveats in `docs/VALIDATION.md`.
- Renderer: 15 specialized routes pass direct-vs-HDR self-crossfade checks; both endpoints match exactly. Sparse galaxy procedural jitter differences are measured/documented, not suppressed.
- CPU Director checks: 8,192 seeded scenes / 106,560 frames, image/no-image routing, transitions, sleep resync and 96-byte ABI pass.
- No GPU command failures. Full-resolution QHD rendering; no per-scene downsampling was used to meet budget.

**Next contributor work**:

- https://github.com/WowWashington/Mac-to-the-stars-screensaver/issues/1 — Europa ice flight / Jovian eclipse.
- https://github.com/WowWashington/Mac-to-the-stars-screensaver/issues/2 — flight preferences / deterministic preview CLI.
- Issue bodies are also saved as `docs/roadmap-europa.md` and `docs/roadmap-flight-controls.md` for a Claude handoff. No messages were sent to Claude.
- The September expansion is already committed and pushed at `c302ae2`; there is no remaining publish reminder for that expansion.

### September 19 contributor handoff review

Reviewed the existing Claude issue handoff and current GitHub issues #1 and #2.
The latest human request was to check those issues; the subsequent checkpoint
found no new implementation. Both issues remain open and there is no feature PR.
Local main and origin/main both resolve to `c302ae2` with a clean working tree.

Selected next contributor issue: **#2, flight preferences and reproducible scene
previews**. This coach selection uses the delegated checklist review; it is not
a claim that the owner previously selected #2. Reproducible scene/seed/time
previews and Director checks provide a useful verification foundation for the
later Europa work. Issue #1 remains in the existing backlog; no duplicate issue
or additional build is needed for this handoff.

The September validation above remains historical evidence. This documentation
review did not rebuild, install, or re-test the screensaver or implement either
feature. Follow AGENTS.md's render/view/benchmark procedure when implementation
resumes, with installation reviewed separately.
