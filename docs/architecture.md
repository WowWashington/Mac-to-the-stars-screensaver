# Architecture

File structure, architecture and key decisions, configuration, running/deployment.

> Component detail. Start at `STATE.md` in the project root.

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
