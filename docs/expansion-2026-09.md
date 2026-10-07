# September 2026 Expansion & Handoff

Rings, nursery, black hole, Dyson interiors; validation; contributor handoff review.

> Component detail. Start at `STATE.md` in the project root.

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
