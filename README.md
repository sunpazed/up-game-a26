# UP 1 WAY Atari 2600 Port

This project is a DASM Atari 2600 port of the JavaScript game `UP 1 WAY`
(`js/main.js`). Target: a complete, playable 4K cart.

## Current Status

- The ROM builds with `make` → `build/up.a26` (exactly 4096 bytes).
- Screenshot reference: `build/up.png` (saved from Stella).
- `src/up.asm` now implements the **real game kernel** (per-platform repeated kernel),
  not the old debug baseline. Progress is tracked by milestone in `GAME.md`.

### Milestone progress
- **M1 — Frame + 6 static platform bands**: ✅ done, verified in Stella (stable, no roll).
- **M2 — Player sprite + jump-up lane movement**: ✅ done, verified in Stella.
- **M3 — Scrolling gaps (Missile 0) + fall-through**: ✅ done, verified in Stella
  (edge-to-edge cycle-74 positioning, no comb, stable player).
- **M4 — Entities (cones/skulls) + collision**: ✅ implemented — cone → +score, skull → game over.
- **M5 — HUD**: 🟡 score (`__nnnn`) + GAME OVER text + HI-score done; power-up pending.

## Kernel Architecture

Per-platform repeated kernel (see `INSTRUCTIONS.md` and `GAME.md` for detail):

```
VSYNC      3 lines
VBLANK    36 lines     ; input + state updates
visible  192 lines     ; HUD region (12) + 6 platform bands (30 each)
overscan  30 lines
                       ; total = 262 NTSC scanlines
```

- Platforms are the **playfield** held solid full-width; band appearance is driven by
  `COLUPF` swaps during HBLANK (background = invisible / green top / grey underside).
- The **player** is `GRP0`, drawn only in the band matching its current floor by selecting a
  sprite pointer per band (no per-scanline branching).
- Gaps (M3) will use `ENAM0/ENAM1`; entities (M4) will use `GRP1` with per-floor type/color.
- HUD (M5) is a dedicated 12-line top region rendering a 6-digit BCD score.

## Design Rules

- Keep frame timing at exactly 262 NTSC scanlines; every band has an identical cycle budget.
- All gameplay state updates happen in VBLANK/overscan, never free-running between `WSYNC`s.
- Prefer table-/pointer-selected register values over compare ladders inside scanlines.
- Each milestone ends in a clean `make` and a Stella visual check before the next begins.

## Build

```sh
make
```

Then load `build/up.a26` in Stella to verify and save a snapshot to `build/up.png`.
