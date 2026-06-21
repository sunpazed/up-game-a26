# UP 1 WAY Atari 2600 Port

This project is a DASM Atari 2600 port of the JavaScript game `UP 1 WAY`.

## Current Status

- The ROM builds with `make`.
- Current output: `build/up.a26`.
- Current screenshot reference: `build/up.png`.
- The current `src/up.asm` is a verified stable debug baseline, not gameplay-complete.

## Verified Baseline

The visible kernel currently follows the stable pattern from `examples/example.asm`:

- renders Player 0 every scanline,
- renders Player 1 every scanline,
- renders Missile 0 every scanline,
- renders Missile 1 every scanline,
- renders the Ball every scanline.

This was verified in Stella as stable: no rolling and stable color.

The current debug objects also move right-to-left in a constant-cycle update slot. Player 0 remains fixed while Player 1, Missile 0, Missile 1, and the Ball wrap back to the right side after reaching the left edge.

## Temporarily Disabled

- Platforms
- Full gameplay updates
- HUD/score rendering
- Entities and collisions
- Game-over display

These were disabled to re-establish a reliable 262-scanline frame baseline.

## Next Step

Reintroduce exactly six static platform bands on top of the stable debug kernel.

Rules for the next step:

- Preserve fixed register writes in the visible kernel.
- Avoid variable compare ladders inside scanlines.
- Keep frame timing at 262 NTSC scanlines.
- Verify with `make` and `build/up.png` before adding movement or gameplay.

## Build

```sh
make
```
