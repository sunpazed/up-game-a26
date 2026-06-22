# UP 1 WAY - Implementation Plan

> Aligned to the updated `INSTRUCTIONS.md` (per-platform repeated kernel approach).

## 0. Source-of-Truth Notes
- `INSTRUCTIONS.md` is the authoritative spec. The current target architecture is the
  **per-platform repeated kernel** described there, not the old "all-5-TIA-objects debug
  baseline" modeled on `examples/example.asm`.
- `src/up.asm` has been removed from the tree — this is effectively a fresh implementation
  built on the kernel architecture below. The old `build/up.png` reflects the retired debug
  baseline and is no longer the reference for correctness.
- Reference screenshots: `screens/demo-01..03.png` (gameplay + GAME OVER) and
  `screens/screenshot.gif`.

## 1. Game Analysis (from `js/main.js`)

### Layout
- **6 floors**, `floorIndexToY(i) = 16 + i*15` → JS y = 16, 31, 46, 61, 76, 91 in a 100px view.
  Floor 0 = top, floor 5 = bottom.
- Player is **fixed horizontally** at `x = 20` (left side); the world scrolls right-to-left.
- Player starts on **floor 5** (bottom).
- Platform strip = 2px green top + 3px dark-grey underside; sprites sit at `y - 5` (just above).
- A `light_blue` baseline is drawn near the bottom of the view.

### Player movement
- **Jump up**: `input.isJustPressed && floorIndex > 0` → `targetFi = floorIndex - 1`.
- **Fall down**: `checkHole(floorIndex, x)` true (player standing over a gap) → `targetFi = floorIndex + 1`.
- Movement interpolates `pos.y` toward the target floor's y; no manual descent otherwise.
- `checkHole`: a hole at `hx` opens a gap for x in `(hx+3, hx+6)`.

### World objects (all scroll right-to-left by `scr = difficulty`, spawn at x≈209/200)
- **Holes** (`holeXs`): gaps in a floor. **Floor 5 never has holes** (always solid/safe).
  Other floors periodically spawn holes (`nextHoleDist`), holes are 9px wide.
- **Yellow cones** (`bambooXs`, char `c`): collectible, **+1 score** on contact.
- **Pink/red ovals** (`skullXs`, animated char `d`): hazard. **Contact → `end()` (GAME OVER)**.
  Falling past the bottom is also fatal in spirit (bottom floor is the safety net here).
- **Power-up** (`powXs`, char `h`): on contact, converts every skull on screen into bamboo
  (clears hazards). Spawns rarely.

### Scoring / HUD
- Score shown top-left (integer); high score shown top-right as `HI n`.
- `addScore(1, ...)` on cone pickup.

## 2. Atari 2600 Kernel Architecture (per `INSTRUCTIONS.md`)

### Whole-frame structure (262 NTSC lines)
```
VSYNC      3 lines
VBLANK     37 lines     ; input + all world/state updates here
visible    192 lines    ; HUD region (6-digit score) + 6 platform kernels
overscan   30 lines     ; batched repositioning / spillover updates
```
- Reserve a fixed HUD region at the top of the visible frame (~16 lines) for the 6-digit score,
  then divide the remaining ~176 lines across the **6 platform bands (~29 lines each)**.
- Keep each band's cycle budget identical so timing is deterministic and the picture does not roll.
  (Exact HUD/band line counts are tuned in M1/M5 to keep the total at 192.)

### TIA object assignment (per platform band)
- `COLUBK` — background (light grey).
- `PF0/PF1/PF2` — the solid platform graphic (green top region drawn via COLUPF / band color).
- `ENAM0` / `ENAM1` — the **gaps** in the platform (painted background-colored to "cut holes").
- `GRP0` — the player (only rendered in the band matching the player's current floor).
- `GRP1` — the enemy / item for that band (cone or skull). The **bitmap and `COLUP1`
  are selected from `entType[floor]`** so the same object renders as a yellow cone or a
  pink/red skull depending on the per-band RAM variable.

### HUD region (dedicated, not a 7th band)
- A **dedicated top region** above the 6 platform bands renders a **6-digit BCD score**.
- Use the 48-pixel retrigger digit path (`examples/6-digit-score.asm` / `examples/punchout.asm`).
- This region sits in its own scanline budget at the top of the visible frame; the 6 platform
  bands then divide the remaining visible lines evenly.

### Per-band scanline approach (from INSTRUCTIONS §"Kernel for each platform")
1. Position the missiles for this platform `n+0` (gaps; they scroll right-to-left).
2. Draw the player (fixed x) — only on the player's floor band.
3. Draw the enemy/item for `n+0` (scrolls right-to-left).
4. Repeat 2–3 across the band's sprite rows until player + enemy are drawn.
5. Turn on the platform (PF) to render the strip under the sprites.
6. Turn on the missiles so the gaps appear in the platform.
7. Position the enemy/item for the next platform `n+1`.
8. Wait out the remaining band cycles, then switch off PF and missiles.
9. Repeat for the next band.

### Safety constraints (carried from INSTRUCTIONS)
- All gameplay state updates happen in VBLANK/overscan, never as free-running code between WSYNCs.
- Visible kernel stays deterministic and short-cycle — **table-driven** register values, no
  variable per-scanline CMP/branch ladders.
- Hold frame at exactly 262 lines; keep each band's budget fixed.

## 3. RAM Model (128 bytes — keep tight)
Proposed layout (refine during implementation):
- `playerFloor` (0–5), `playerY` / `playerTargetFloor`, jump-in-progress flag.
- Per-floor scroll/gap state: gap x-position (one active gap per floor to start), gap-present flag.
- **Per-platform entity arrays, indexed by floor (0–5):**
  - `entType[6]` — entity kind for that band: none / cone / skull (drives GRP1 bitmap + COLUP1).
  - `entX[6]` — x-position of that band's entity (scrolls right-to-left).
  - This is how cone-vs-skull is distinguished: the **graphic and color are selected per band
    from `entType[floor]`** during the kernel; the kernel reads the table, no per-scanline branching.
- `scoreBCD[3]` — 6-digit BCD score for the HUD; `hiScoreBCD[3]` if a high score is kept.
- `gameState` (playing / game-over), `frameCounter` / RNG seed for spawns.

> Simplification vs JS: JS keeps arrays of many holes/cones/skulls per floor. On the 2600 we
> start with **one gap and one entity per floor band** (matching GRP1/ENAMx being single
> objects per band) and expand only if cycle/RAM budget allows.

## 4. Milestones (each ends in a clean `make` + emulator check)

### M1 — Frame skeleton + 6 static platform bands  ✅ DONE (G1 verified)
- VSYNC/VBLANK/visible/overscan at 262 lines.
- Render 6 green/grey platform bands via PF, 30 lines each, fixed register writes.
- Verify: `make` passes; `build/up.png` shows 6 stable horizontal platforms, no roll, stable color.

### M2 — Player sprite + lane (floor) movement  ✅ DONE (G2 verified)
- Draw GRP0 at fixed x on the player's current floor band.
- Read button (INPT4 / fire); jump up one floor on press (snap, no interpolation yet).
- Verify: button moves player up exactly one floor; can't go above floor 0.

### M3 — Scrolling gaps + fall-through  ✅ DONE (verified in Stella)
- ENAM0 gap (Missile 0) per floor, scrolling right-to-left edge-to-edge; floor 5 stays solid.
- Player falls one floor when a gap scrolls under it.
- Gaps positioned with the cycle-74 HMOVE technique (clean 0..159, no comb).
- Verified: gaps scroll smoothly edge-to-edge, no glitch/comb, player stable, fall works.
- `PLAYER_X = 10` (final). Fall window `[FALL_LO=12 .. FALL_HI=20]` — see note below if the
  drop timing wants centring on the new player x.

### M4 — Entities (cones + skulls) + collision  ✅ IMPLEMENTED (pending emu check)
- ✅ GRP1 per band as cone (gold) or skull (red), one per platform, randomly placed,
  scrolling right-to-left and respawning with a random type. (Verified clean in Stella.)
- ✅ Collision (player vs entity on the player's floor): cone → +1 BCD score + consumed;
  skull → game over (freeze + red tint + restart on fire).
- Score HUD display is M5; for now the cone's effect is it disappearing, the skull's is game over.

### M5 — HUD, power-up, game-over/reset  🟡 HUD score IMPLEMENTED (pending emu check)
- ✅ **6-digit BCD score** in the dedicated top HUD region, 48-px digit path.
- ⬜ Power-up that clears skulls.
- ⬜ GAME OVER text (currently a red-screen freeze placeholder).
- ⬜ HI-score (top-right).

## 5. Example References
- Horizontal positioning: `examples/example.asm` (`SetHorizPos`), `examples/punchout.asm`
  (`DoPosition`/`DoPositionMac`). Sequence: WSYNC / HMCLR / divide loop / RESPx+HMPx / WSYNC / HMOVE.
- Score digits: `examples/6-digit-score.asm` (`BCDScore`, `AddScore`, `GetDigitPtrs`, `DrawDigits`).
- PF/missile bar techniques: `examples/energy-bar.asm` (`DoEnergy`, `PF0/1/2Table`).
- Bank switching (only if ROM exceeds 4K): `examples/punchout.asm` macros — stay single-bank otherwise.

## 6. Verification Gates
- **G1**: `make` passes; 6 stable platforms render, no rolling, correct colors (matches demo palette).
- **G2**: jump-up moves one floor only; fall-through on gaps; floor 5 safe.
- **G3**: cone → score; skull → game over.
- **G4**: HUD score/HI correct; power-up clears skulls; game over + reset works.

## 7. Decisions (resolved) & Open Questions

### Resolved
- **HUD**: a **dedicated top region** rendering a **6-digit score** (not a 7th platform band).
- **Cone vs skull**: distinguished by **graphics + color**, tracked per platform index in RAM
  (`entType[6]`); the kernel selects the GRP1 bitmap and `COLUP1` from that table.
- **Entities**: start with **one entity per floor band** (GRP1 is a single object per band).

### Still open
- The `light_blue` baseline — own TIA object vs folded into the bottom band.
- Smooth jump animation (JS interpolates y between tiers; M2 currently snaps).

### Decided during implementation
- HUD = **12 lines**, each band = **30 lines** → 12 + 6×30 = 192 visible. Locked.
- `VERTICAL_SYNC` macro emits **4 WSYNCs** (3 vsync lines + the transition WSYNC), so VBLANK
  uses **36** lines (not 37) to total exactly 262 — matching `examples/example.asm`.

## 8. Implementation Log (detailed, per milestone)

> Updated between milestones. Describes *how* each milestone is implemented in `src/up.asm`.

### M1 — Frame skeleton + 6 static platform bands

**Frame structure.** `NextFrame` runs: set `VBLANK=2` (blank), `VERTICAL_SYNC` (3 vsync
lines), a 36-iteration `VBlankLoop` of `WSYNC`, then `VBLANK=0` to enable the display. The
visible kernel draws 12 HUD lines + 6 bands × 30 lines. Overscan is `VBLANK=2` + a 30-iteration
`WSYNC` loop. `jmp NextFrame` closes the loop. Total scanlines = 4 (macro WSYNCs) + 36 + 12 +
180 + 30 = **262**.

**Platforms via playfield + COLUPF swaps.** The playfield is set **solid and full-width once**
at `Reset` (`PF0=$F0`, `PF1=$FF`, `PF2=$FF`, `CTRLPF=0`) and never touched again. A platform is
made visible or invisible purely by changing `COLUPF`:
- air rows: `COLUPF = COL_BG` (same as `COLUBK`) → the solid playfield is invisible;
- green top rows: `COLUPF = COL_GREEN`;
- grey underside rows: `COLUPF = COL_GREY`.

This avoids touching PF registers mid-screen and keeps every band's cycle budget identical.

**HBLANK-safe color changes.** Every `COLUPF` change is the *first* write after a `WSYNC`, so
it lands during HBLANK before the beam reaches the visible area. The structure for each colored
run is: `sta WSYNC` → set color → loop the remaining `WSYNC`s of that run.

**Band layout (30 lines).** 22 air + 4 green + 4 grey. Bands are counted down with the
`bandCount` RAM byte (6→1); the loop ends on `dec bandCount / bne`.

**Colors.** `COL_BG=$0C` (light grey), `COL_GREEN=$C8`, `COL_GREY=$06`. Verified against the
demo palette in `build/up.png`.

### M2 — Player sprite + jump-up lane movement

**Player as GRP0, one band only.** The player is an 8-line GRP0 sprite drawn only in the band
matching `playerFloor`. Bands draw top tier (floor 0) first, so the player's band is reached
when `bandCount == playerBandCount`, where `playerBandCount = NUM_BANDS - playerFloor`
(computed once per frame in VBLANK).

**Constant-time band selection (no per-scanline branching).** The air region is restructured to
`1 (setbg) + BAND_PAD (13) + SPRITE_H (8) = 22` lines. On each band's first air line, after
setting `COLUPF=COL_BG`, the code compares `bandCount` to `playerBandCount` and points the
zero-page `sprPtr` at either `PlayerSprite` or `ZeroSprite`. This branch happens once per band
(between scanlines), not inside the scanline loop, so the visible kernel stays deterministic.

**Sprite window.** The 8 sprite lines run `sta WSYNC / lda (sprPtr),y / sta GRP0 / dey / bpl`,
with `y` counting 7→0. Data is stored bottom-row-first so index 7 is the top row. The indexed
load + store complete ~8 cycles into HBLANK — well before the beam reaches `PLAYER_X=20`
(~29 CPU cycles in). Both sprite tables sit within a single ROM page (`$f0ed`, `$f0f5`) so the
`lda (zp),y` is constant-cycle. `PlayerSprite` offsets 0–1 are blank, so `GRP0` is already 0
when the kernel reaches the green/grey rows — no extra clear needed.

**Horizontal positioning.** `SetHorizPos` (coarse `RESP0` + fine `HMP0` via the classic
`SBC #15` divide loop) is called once at `Reset` with `A=PLAYER_X, X=0`, followed by
`WSYNC`/`HMOVE`. The player never moves horizontally, so it is never repositioned again and
overscan needs no `HMOVE`.

**Input / jump (`ReadInput`, in VBLANK).** Reads `INPT4` (fire, active-low on bit 7). Rising-edge
detection uses `btnPrev`: on a fresh press, if `playerFloor > 0` it does `dec playerFloor`
(move up one tier), clamped at the top. Movement currently **snaps** between tiers; smooth
interpolation (as in the JS source) is deferred to polish.

**RAM used so far:** `playerFloor`, `playerBandCount`, `btnPrev`, `bandCount`, `sprPtr` (2).

### M3 — Scrolling gaps + fall-through

**Gaps are Missile 0.** Each floor (except floor 5) has one gap whose x lives in `gapX[6]`. A gap
is rendered by enabling `ENAM0` over the platform rows with the missile **colored the
background color**, so it punches a hole through the green top and grey underside. Default TIA
priority draws missiles over the playfield (`CTRLPF=0`), which is what makes the hole appear.
`NUSIZ0=$30` sets the missile to 8 px wide (`GAP_WIDTH`).

**COLUP0 is time-shared.** GRP0 (player) and M0 (gap) share `COLUP0`, but they live on different
scanlines within a band, so the kernel swaps it: `COL_PLAYER` for the air/sprite rows,
`COL_BG` for the platform rows. The swap to background happens in the tail of the last sprite
line (a background missile over background air is invisible, so enabling it early is harmless),
keeping the platform-row HBLANK budget free for the `COLUPF` write.

**Per-band missile positioning (`PosObject`).** On each band, after computing
`curFloor = NUM_BANDS - bandCount`, the kernel loads `gapX[curFloor]` and calls `PosObject`
with `X=2` (object index → `RESM0`/`HMM0`). `PosObject` is a **self-contained 2-scanline**
routine: `WSYNC / HMCLR / SBC #15 divide loop / EOR #7 / ASL×4 / strobe RESP0,x / set HMP0,x /
WSYNC / HMOVE`. The trailing `HMOVE` applies the fine offset so gaps scroll at 1-px resolution.
`HMCLR` zeroes every HMxx each call, so the once-positioned player never drifts on these
HMOVEs (its position is latched by its own `RESP0`). The same routine positions the player at
`Reset` (`X=0`), so player and gaps share one calibration and stay aligned for fall detection.
The per-band `HMOVE` leaves a small black "comb" on the left 8 px of one air line per band —
a cosmetic artifact to clean up later.

**Band layout (still 30 lines):** `1 (setbg) + 2 (PosObject) + 11 (pad) + 8 (sprite) +
4 (green) + 4 (grey)`.

**Game logic moved to overscan under a timer.** `ReadInput` + `UpdateWorld` now run in overscan,
which is bounded by `TIM64T` (`lda #35`) and a `WaitOverscan` poll on `INTIM` + final `WSYNC`.
This makes overscan a **fixed line count regardless of how long the logic branches take**, so
variable update work can never change the frame's scanline total (the roll trap that bit the
earlier baseline). The visible kernel stays exact-192 via WSYNC; VBLANK stays the verified
36-line loop. `playerBandCount` is recomputed at the end of overscan so the next frame's kernel
sees the latest floor.

**`UpdateWorld`.** Scrolls floors 0–4 (`dec gapX,x`), wrapping a gap back to `GAP_WRAP` (154)
when it reaches 0. Fall-through: if `playerFloor < 5` and `gapX[playerFloor]` is within
`[FALL_LO=12 .. FALL_HI=20]` (gap overlapping the player's fixed x≈20), it does
`inc playerFloor`. Floor 5 is always safe.

**Known simplifications (M3):** all floors 0–4 carry a perpetual scrolling gap (no spawn RNG
yet); jump and fall can both fire in one frame (no mid-jump lockout like the JS `targetFi`
state); movement still snaps between tiers.

**RAM added:** `curFloor`, `gapX[6]`.

#### M3 fixes (post-emu feedback)

- **Gap didn't scroll fully to the left edge.** The old wrap fired at `gapX < 8`. **Fix:**
  wrap exactly when `dec gapX` reaches 0, so the gap travels to the left edge before recycling.

- **Band dropped a pixel when a gap was at the far right; gaps had to "appear" mid-screen.**
  The old `PosObject` body between its two `WSYNC`s was 77 cycles at 11 `SBC #15` iterations
  (`x≥150`), overrunning the 76-cycle line so the trailing `WSYNC` stole a scanline that frame.
  Capping `GAP_WRAP` low avoided the glitch but kept gaps from entering at the right edge.
  **Fix (precompute fine — per the suggested approach):**
  - A new `CalcFine` does the `÷15 / EOR #7 / ASL×4` fine math; in **overscan** the frame
    precomputes `gapFine[6]` for every floor.
  - The kernel loads `gapFine[floor]` into `HMM0` in the band's first air line (before
    positioning), so the positioner no longer computes or stores the fine.
  - `PosObject` → **`PosCoarse`**: drops the trailing `sta HMP0,x` (fine is pre-set) **and**
    the per-band `HMCLR` (done once at init, so the pre-set fine isn't wiped). Body is now
    **≤70 cycles even at x=159** (11 iterations) — fits the scanline with margin.
  - `HMCLR` runs once at `Reset` after positioning the player (player fine via `HMP0`), so
    per-band missile `HMOVE`s never disturb the static player; `PosCoarse` uses the same
    calibration for both, keeping player and gaps aligned for fall detection.
  - **Result:** gaps scroll in from the right edge, no pixel drop. Removing the per-band
    `HMCLR` shifts all objects ~9px left uniformly (a constant offset; fall alignment is
    unchanged because player and gaps share it). `GAP_WRAP=164` (user-verified).

- **Gap couldn't scroll edge-to-edge; the leftmost block (`gapX < $10`) wrapped to the right.**
  The plain divide-by-15 positioner can't represent the leftmost ~block: for small `gapX` the
  `RESM0` strobe lands in HBLANK (pinned far-left) and the fine offset can push the position
  **negative**, which wraps mod-160 to the right edge. An interim attempt that *hid* the gap
  below a threshold was rejected (the gap must scroll off, not disappear).

#### Edge-to-edge positioning rework (cycle-74 HMOVE) — IMPLEMENTED

Replaced the positioner with the **cycle-74 HMOVE** technique (after `examples/hmove74.asm`,
by Omegamatrix), which positions any object 0..159 cleanly in one scanline — including the far
left (strobe during HBLANK) — and hides the HMOVE comb in the next line's HBLANK.

- **Precompute (`CalcQuickPos`, overscan):** a fast divide-by-15 + `MultTab`/`DelayTab` produces
  a `quickPos` byte per gap = `(HMOVE fine nibble << 4) | delay-count`. Stored in `gapQuick[6]`;
  the strobe-table entry (`JumpTabM0[delay]`) is precomputed into `posJmpLo[6]`.
- **Kernel (`Pos74M0`, one scanline):** load `quickPos` → `HMM0` (fine), mask the delay count,
  `WSYNC`, 9-cycle pad, a `dex/bpl` delay loop, then `jmp (posJmp)` into `PosTblM0` — a page-aligned
  table of `sta RESM0 / .byte $1C` entries (the `$1C` NOP-abs swallows the next entry's strobe, so
  only the jumped-to strobe runs) that falls through to `sta HMOVE` at cycle ~74. A `sta WSYNC`
  follows the HMOVE so every band's positioning line is an identical, exact length (the HMOVE is
  always at cycle ~74 regardless of gap x), keeping the scanline budget deterministic.
- The static player keeps the plain divide-by-15 routine (`PosStd`) at init (off-screen).
  **Gotcha 1:** the per-band cycle-74 HMOVE re-applies *every* object's HMxx, and at cycle 74
  `HM=$00` is NOT zero motion — it walks the object. The player is strobed only once, so its
  `HMP0` must be set to `$80` (`NO_MO_74`) after positioning to stay put; clearing it to `$00`
  made the player jump to random x each frame. (The missile is immune — it's re-strobed and
  given a fresh calibrated `HMM0` every band.)
  **Gotcha 2:** `PosStd` must include the leading `sta HMOVE / sta HMCLR` of the canonical
  positioning routine. Without them the `RESP0` strobe fires ~6 cycles (~18px) early, pinning
  the player at the far left — so it visually fell through gaps ~18px before they reached it
  (the gaps position accurately via cycle-74, the player did not). With the leading pair, both
  render logical-x at pixel-x and the fall window lines up.
- `GAP_WRAP=159` (true right edge); the gap now scrolls 159→0 and wraps. `GapOnTable` retained
  only to keep floor 5 gap-free.
- **Band layout (still 30):** `setbg 1 + pos 2 (strobe + realign) + pad 11 + sprite 8 +
  green 4 + grey 4`.

**RAM:** `gapQuick[6]`, `posJmpLo[6]`, `posJmp[2]`, `tempOne`, `tempFloor` (replaced the interim
`gapFine`/`gapEnable`). **Tables added:** `MultTab`, `DelayTab`, `JumpTabM0`, `PosTblM0`
(page-aligned at `$f200`).

**Verification caveat:** this is a timing-critical port done without local emulator access; the
exact cycle-74 calibration (9-cycle pad, strobe table) follows the reference and may need a
1–2 cycle tuning pass confirmed in Stella.

### M4 — Entities: cones + skulls (rendering / placement)

**Per-platform entity in GRP1.** Each floor has one entity: `entType[6]` (0 none / 1 cone /
2 skull) and `entX[6]` (x, scrolls right-to-left). The kernel draws GRP1 in the same 8-line
sprite window as the player (`lda (entPtr),y / sta GRP1` after the GRP0 write — GRP1 lands in
HBLANK so even x≈0 is fine). Per band the kernel selects the sprite and colour from `entType`:
`entPtr` ← `EntSprLo[type]` (Cone/Skull/Zero, all in one page), `COLUP1` ← `EntColorTable[type]`
(`COL_CONE=$1E` gold, `COL_SKULL=$44` red).

**Second cycle-74 positioner (`Pos74P1`, RESP1).** The entity is positioned exactly like the gap
but strobing `RESP1`/`HMP1` via `PosTblP1`. `PosTblP1` is page-aligned at `$f400` with the same
internal layout as `PosTblM0` at `$f300`, so the single `JumpTabM0` low-byte table serves both
(only the high byte differs). `entQuick[6]`/`entJmpLo[6]` are precomputed in overscan alongside
the gap values.

**HMxx no-motion discipline.** The band now does *two* cycle-74 HMOVEs (gap, then entity), and
each HMOVE re-applies every object's HMxx. So all motion registers default to `$80` (NO_MO_74),
and each positioner sets only its own HMxx to the fine value before its HMOVE, then **restores
`$80`** after. This keeps the player, the gap, and the entity from disturbing one another.

**Random placement.** An 8-bit LFSR (`Rng`, advanced once per frame) drives respawns; initial
types/positions are staggered. Entities scroll exactly like the gaps: `dec entX` to the left
edge, then wrap to `ENT_WRAP=159` with a fresh type from `EntTypeRoll[rng & 3]` =
{cone, cone, skull, skull}.

**Type-change flicker — root cause and fix.** GRP1 is an **8px-wide** object and the TIA position
counter is **mod-160**. An object positioned at `entX=153..159` draws pixels that exceed 159 and
**wrap to the left edge (pixels 0-6)** — so the freshly-rerolled type appeared as a ghost at the
left. (The gaps wrap identically, but a *background-coloured* missile wrapping to the left is
invisible — which is the whole reason the gaps looked clean and the coloured entities didn't.)
**Fix:** cap `ENT_WRAP=152` so the full 8px object always stays on-screen (152-159) and never
wraps. The entity now appears at the right edge and scrolls cleanly to the left — no wrapped
ghost, no type flash. Trade-off: it *appears* at the right edge rather than sliding in column by
column (a gradual slide-in past pixel 159 would require per-column sprite masking). Earlier
attempts (defer the re-roll a frame; off-screen hide/delay state machine; blank bit 7) were
reverted — they didn't address the mod-160 wrap, which was the actual cause.

**Band layout (still 30):** `setbg 1 + missile pos 2 + entity pos 2 + pad 9 + sprite 8 +
green 4 + grey 4`. The end-of-band loop uses `jmp BandLoop` (the body now exceeds a branch's
±128-byte range).

**RAM added:** `entType[6]`, `entX[6]`, `entQuick[6]`, `entJmpLo[6]`, `entPtr[2]`, `rng`.

**Collision + scoring (`CheckCollision`, overscan) — hardware collision.** The player is GRP0
and entities are GRP1, so the TIA's `CXPPMM` bit 7 (P0–P1) flags a real pixel overlap. This is
calibration-independent — important because the player (`PosStd`) and entities (cycle-74) use
different positioners, so a position-compare window was unreliable (an early version missed
overlaps the eye could clearly see). `CXCLR` is strobed each frame in VBLANK; `CheckCollision`
reads `CXPPMM` in overscan. Because GRP0 is only drawn on the player's own floor, a P0–P1 hit can
only be the entity on `playerFloor`, so the type is read from `entType[playerFloor]` —
**cone**: `+1` to the 3-byte BCD `scoreBCD` (decimal-mode add with carry) and consumed
(`entType=0`); **skull**: `gameState=1` and `COLUBK` → `COL_GAMEOVER` (red).
`CheckCollision` runs *before* `ReadInput`/`UpdateWorld` so `playerFloor` still matches the frame
that was just rendered (and latched the collision).

**Game-over loop.** While `gameState!=0` the overscan skips `ReadInput`/`UpdateWorld` (world
frozen, but the precompute + kernel still run so the picture is stable) and calls `CheckRestart`,
which restarts the game (`jmp Reset`) on a fresh fire press. `Reset` restores `COL_BG`, zeroes
RAM (so score/state reset), and re-inits. The score isn't visible yet (HUD is M5) — for now the
cone's visible effect is disappearing on pickup, the skull's is the red freeze.

**RAM added:** `gameState`, `scoreBCD[3]`.

### M5 (part 1) — HUD: 6-digit score

**48-pixel score kernel** (after `examples/6-digit-score.asm`). P0 and P1 each draw 3 close copies
(`NUSIZ=THREE_COPIES`) and are interleaved (`HMP1` nudge + `VDELP0/VDELP1`) into 6 digits across
48px. `GetDigitPtrs` (run in overscan off the just-updated `scoreBCD`, and once in init to seed
frame 1) turns the 3 BCD bytes into 6 `FontTable` pointers (`Digit0..Digit5`). `DrawDigits`
(page-aligned; each `bigLoop` row is exactly 76 cycles) renders the 8 rows.

**Frame layout (all WSYNC-exact — a timer-based attempt rolled).** The whole frame stays
WSYNC-counted: VSYNC 3 + VBLANK 36 + HUD 12 + bands 180 + overscan(TIM64T ~30) = 262.
- VBLANK uses 2 of its 36 lines to position the score sprites (NUSIZ/VDELP/colors + RESP0/RESP1
  + HMP1), then a 34-line WSYNC loop.
- HUD = exactly 12 lines: COLUPF line + `DrawDigits` (9 lines — it ends on a `WSYNC` so the
  count is exact) + 2 transition lines that **restore game sprite state** (NUSIZ0=$30, NUSIZ1=0,
  VDELP=0) and **re-strobe the player P0** near `PLAYER_X` (coarse strobe — exact x is cosmetic
  now that collision is hardware). The player is no longer positioned at init; `PosStd` removed.
- *Pitfall recorded:* `TIMER_SETUP`/`TIMER_WAIT` for the HUD rolled the screen — the score
  kernel's free-running 8 rows overran the 12-line timer, so `TIMER_WAIT` couldn't pad and the
  visible region exceeded 192. WSYNC-exact (with `DrawDigits` ending on a `WSYNC`) is reliable.

**RAM added:** `Digit0[12]`, `loopCnt`.

**Tunable / not-yet-polished:** score sits center-ish (`SCORE_SLEEP=36`, the reference value) —
top-left placement + a "HI" score are follow-ups; player x via `PLAYER_SLEEP`.

## 9. Steering Log (user-directed decisions)

This project is being built collaboratively; the user (an experienced 2600/asm developer) has
materially steered the implementation. Recording the key interventions:

- **Updated `INSTRUCTIONS.md` to the per-platform repeated-kernel architecture.** Reframed the
  whole approach away from the old debug baseline toward PF-platforms + ENAMx-gaps + GRP0/GRP1.
- **HUD = dedicated top region rendering a 6-digit score** (not a 7th band). Directed the HUD
  design in §2.
- **Cone vs skull tracked per platform index in RAM** (`entType[]`), with graphic + colour
  selected from the table — drove the M4 entity model and `entType[6]`/`entX[6]` design.
- **Diagnosed the M3 far-right pixel-drop** as the `÷15` fine-positioning loop overrunning a
  raster line (>76 cycles) — a precise root-cause call that pointed straight at the fix.
- **Directed `GAP_WRAP` higher (≈154)** so gaps enter from the true right edge rather than
  "appearing" mid-screen, and asked for a timing workaround to keep within the 2600's limits.
- **Proposed precomputing the fine positions in overscan and reading them from a RAM table**
  (for gaps and the upcoming enemy). This is exactly what unblocked far-right positioning:
  precompute `gapFine[]` in overscan → kernel skips the fine math/store → `PosCoarse` fits 11
  `SBC` iterations in one scanline. See the "M3 fixes" entry above.
- **Tested `GAP_WRAP=164`** as safe on hardware/emulator and directed the bump.
- **Reported the `gapX < $10` left-edge bug** and asked whether it was fine-positioning or
  something else — which pinpointed the leftmost-block / HBLANK-strobe wrap limitation.
- **Rejected hiding the gap and directed a generic edge-to-edge positioning method** ("position
  at 0 during horizontal blanking… cycle efficient… missile(s) and enemy sprite"). This drove
  the cycle-74 HMOVE rework (`Pos74M0` + `CalcQuickPos`), the proper full-range solution.
- **Diagnosed the player-vs-gap pixel mismatch** (player dropping through holes before reaching
  them) as a fine-position alignment issue → fixed `PosStd`'s calibration. Set `PLAYER_X = 10`
  as the final player position.
- **Diagnosed the entity "type flash" as the mod-160 sprite wrap** — spotted that an 8px GRP1
  object near the right edge wraps part of itself to the left edge, and that the gaps avoid it
  only by being background-coloured. This pinned down the real cause after several near-misses,
  leading to the `ENT_WRAP=152` fix. Proposed sprite-masking as the alternative (kept in reserve
  for gradual slide-in).
- **Process: keep the `.md` docs updated between milestones**, with detailed implementation
  writeups — and maintain this steering log.
