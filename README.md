# UP 1 WAY Atari 2600 Port

This project is a DASM Atari 2600 port of the JavaScript game [UP 1 WAY](https://abagames.github.io/crisp-game-lib-11-games/?up1way) (see `js/main.js`). The target is a complete, playable 4K cart. 

## Authorship

Co-authored with Opus 4.8, it took approximately 1.768M tokens to generate this code. Review `GAME.md` to track the progress of this games development, including the examples and developer steering required to generate a stable graphics kernel and coherant Atari 2600 game.

```
 Total cost:            $206.19
 Total duration (API):  5h 43m 4s
 Total duration (wall): 22h 4m 14s
 Total code changes:    3280 lines added, 1324 lines removed
   Usage by model:
       claude-haiku-4-5:  443 input, 11 output, 0 cache read, 0 cache write ($0.0005)
        claude-opus-4-8:  79.1k input, 1.4m output, 317.3m cache read, 1.8m cache write ($206.19)
```

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
- **M4 — Entities (cones/skulls) + collision**: ✅ done — cone → +score, skull → game over.
- **M5 — HUD**: ✅ done — score (`__nnnn`), GAME OVER text, persistent HI-score.
- **M6 — Spawn spacing + sub-pixel speed-up + spawn-clear-of-gaps**: ✅ done.
- **M7 — Object animations + edge slide**: ✅ player run-cycle (speed-linked), and entities
  slide in/out at both screen edges (pre-shifted sprites + hardware reflect). Cone/skull
  animation frames deferred.
- **M8 — Power-up** (clears skulls): ⬜.
- **M9 — Player vertical glide** (free-Y player kernel): ✅ done on branch `player-glide` — the player
  slides smoothly between floors on jump/fall, drawn at an arbitrary scanline via a page-aligned
  zero-padded sprite + per-band pointer offset (precomputed in VBLANK). Full game re-layered: entity
  redrawn 2x, gap moved to Missile 1 (frees `COLUP0` for the player), run-cycle animation via two
  frame buffers.

### Polish / QoL (post-M6)
- **Sound**: 4 effects on TIA channel 0 — jump (rising), drop (falling), cone (coin), death (noise).
- **Randomisation**: PRNG reseeded from a free-running frame counter at restart; random entity
  types + spawn times; random non-stacking gap layout per game (re-rolled for ≥24px separation
  between adjacent floors). Fair empty start (entities slide in, never parked in the jump path).
- **Performance**: scroll is O(1) (advance by `scrollStep` in one pass), so frame timing stays
  flat at any speed — fixed a high-speed screen roll.

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
