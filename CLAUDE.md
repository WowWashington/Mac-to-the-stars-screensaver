# Mac-StarsScreenSaver (Galactic Odyssey)

Read STATE.md first for full context. This file is the working recipe.

## Verify-as-you-go loop (ALWAYS use it)

```
./build.sh preview         # builds everything + renders Preview/*.png — LOOK at them
./build/preview Preview --bench   # GPU ms/frame at QHD; keep every scene < 12ms
./build.sh install         # installs + re-selects for all displays + restarts agents
```
Never ship a visual change without rendering and viewing the relevant Preview PNG.
Add a harness case in Harness/main.swift for anything new you build.

## How to add a new scene type

1. Write `float3 myScene(float2 uv, float t, float4 scn, float4 pal, float gt)` in
   Sources/ShaderSource.swift (it's one big Metal string; plain MSL, helpers at top).
2. Add a dispatch line in `renderScene()` with the next free type number.
3. In Sources/Director.swift: add the case to `SceneKind`, duration in `makeScene`,
   weight in `makeRegionTail`, target name in `makeTargetName`, speed in `hudInfo`.
4. Add the HUD label case in Sources/HUD.swift (`kindLabel` switch).
5. Harness case → `./build.sh preview` → look → tune → bench → install.

New encounter subtype is even easier: extend `encounterScene()` dispatch (scn.y =
subtype, scn.z = free per-subtype param) and the subtype ranges in Director.

## Hard-won rules (violating these caused real bugs)

- **Uniforms layout**: Sources/Uniforms.swift and the Metal `Uniforms` struct must
  match BYTE FOR BYTE (96 bytes, SIMD4s first). Change both together or nothing.
- **Motion direction**: depth-layer patterns are `q = uv * depth * K` with depth
  SHRINKING over time → stars stream outward (toward viewer). Warp streak phase
  uses `+t`. Getting a sign wrong makes travel look reversed — it LOOKS plausible
  in stills, so reason it through: a star at grid point g appears at g/(depth·K).
- **Nothing pops in**: every body starts as a distant dot (planets z≥17, structures
  z≥19) and grows. Crossfades are 4.5s; warp is the only "cut".
- **Scenes must average < ~12ms** at QHD (bench it) so two-scene crossfades hold 60fps.
  `starLayer` (3x3 neighbor scan) costs ~1.5ms per call — for stacked fly-through
  layers use the single-cell `starLayerFast`/`systemLayer` (~9x cheaper). Bench
  numbers are inflated when the user is actively using the GPU — compare against
  an untouched scene from the same run before reacting.
- **Screensaver selection** (macOS 14+): all Idle entries in the wallpaper store
  must use provider `com.apple.NeptuneOneExtension`. System Settings sometimes
  rewrites them → `python3 select_saver.py && killall WallpaperAgent`
  (build.sh install already does this).
- Manual run: `open -a ScreenSaverEngine` — dismisses on ANY input; screenshots of
  it need Screen Recording permission (`screencapture -x /tmp/x.png`).

## NASA seed images (deepfield scenes)

- Only files verifiably from https://images.nasa.gov go in SeedImages/ — record
  NASA ID + credit in SeedImages/CREDITS.md. Unknown provenance → SeedImages/unverified/
  (gitignored, never bundled, never distributed). NO NASA logos anywhere.
- Fetch workflow: `curl https://images-api.nasa.gov/search?q=...&media_type=image`
  → take nasa_id → `https://images-assets.nasa.gov/image/<ID>/<ID>~large.jpg` (use -L).
- Drop the .jpg in SeedImages/, add the credit row, `./build.sh install`. Auto-joins
  the rotation (Director only schedules deepfield when images exist).

## Licensing

MIT covers CODE only (LICENSE). Images stay "Courtesy NASA", can't be sublicensed.
Keep that split intact in any docs or release notes.

## Style

- Everything procedural unless it's a NASA deepfield image. No other binary assets.
- Scene aesthetics: dark space, restrained nebula, HDR highlights through the
  ACES tonemap. When a scene looks washed out, cut background fill before
  boosting subject brightness.
- Commit style: short, imperative, lowercase ("add pulsar encounter").
