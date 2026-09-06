Add a small set of flight preferences so users can select which journeys they want and reproduce a particularly good route. This is a follow-up to the new Saturn expedition, stellar nursery, and inhabited Dyson interiors under local development on 2026-09-05.

Implementation scope:

- Extend the existing Options sheet with scene-family toggles, a gentle/standard travel-speed choice, and an optional replay seed. Keep the default experience an endless varied journey.
- Persist preferences with the existing screensaver defaults domain, validate saved values, and make settings behave across multiple displays.
- Ensure at least one scene remains enabled; handle missing NASA assets and old preferences gracefully. Seed replay must preserve the route without coupling animation speed to frame rate.
- Extend Director temporal-invariant checks to cover restricted scene pools, deterministic replay, image-slot compatibility, transition continuity, and wake-from-sleep recovery.
- Add a developer preview command that accepts scene, seed, normalized time and output directory, so future contributors can reproduce screenshots without editing Harness/main.swift.
- Keep implementation details out of the user-facing UI. Document preferences and the preview command in README.md.

Start by reading STATE.md and AGENTS.md. Preserve the 96-byte uniform ABI; require no third-party runtime dependency. Coordinate with the current expansion before editing Director or the preview harness.
