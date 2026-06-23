# UP 1 WAY Atari 2600 Port

This project is a DASM Atari 2600 port of the JavaScript game [UP 1 WAY](https://abagames.github.io/crisp-game-lib-11-games/?up1way) (see `js/main.js`). The target is a complete, playable 4K cart. 

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
VBLANK    35 lines     ; input edge + per-band player-pointer precompute (idle cycles)
visible  192 lines     ; HUD region (12) + 6 platform bands (30 each)
overscan  32 lines     ; TIM64T timer; world update + positioning precompute
                       ; total = 262 NTSC scanlines
```

- Platforms are the **playfield** held solid full-width; band appearance is driven by
  `COLUPF` swaps during HBLANK (background = invisible / green top / grey underside).
- The **player** is `GRP0`, drawn at an **arbitrary scanline** (M9 vertical glide) via a
  page-aligned zero-padded sprite + a per-band pointer offset, so it slides smoothly between
  floors. Two frame buffers (selected by `animFrame`) give the run-cycle animation.
- Gaps are **Missile 1** (`COLUP1`, background-coloured to cut the hole — moved off Missile 0 so
  its colour doesn't clash with the gliding player's `COLUP0`); entities are `GRP1`, drawn 2x in
  their fixed band rows with per-floor type/colour and edge-slide.
- HUD is a dedicated 12-line top region rendering a 6-digit BCD score.

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

## Authorship

Co-authored with Opus 4.8, it took approximately 1.9M tokens to generate this code. Review `GAME.md` to track the progress of this games development, including the examples and developer steering required to generate a stable graphics kernel and coherant Atari 2600 game.

```
 Total cost:            $266.13
 Total duration (API):  7h 36m 33s
 Total duration (wall): 1d 4h 15m
 Total code changes:    3884 lines added, 1682 lines removed
 Usage by model:
     claude-haiku-4-5:  443 input, 11 output, 0 cache read, 0 cache write ($0.0005)
      claude-opus-4-8:  123.6k input, 1.9m output, 392.5m cache read, 3.4m cache write ($266.13)    
```
