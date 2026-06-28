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

### M5 — HUD: score + GAME OVER + HI score  ✅ DONE
- ✅ Score shown as `__nnnn` (4 digits) via the 48-px glyph kernel.
- ✅ GAME OVER: alternates "GAMEOVER" text and "HInnnn" (high score), 120 frames each.
- ✅ HI-score tracked (max on death), persists across restarts via a soft-reset (NewGame).

### M6 — Spawn spacing + score-based speed-up  ✅ IMPLEMENTED (pending emu check)
- (a) ✅ **Respawn spacing.** Entities now run a per-floor state machine: visible → scroll to the
  left edge → **hide** (`entType=0`) and arm `entDelay[floor] = ENT_DELAY_MIN + (rng & MASK)`
  (32-159 frames) → re-enter from the right with a random type when the delay elapses. The same
  delay is armed when a cone is *collected* (in `CheckCollision`). So entities are spaced out and
  desync (random delays + staggered start). `SetRespawnDelay` arms the timer. RAM: `entDelay[6]`.
- (b) ✅ **Score-based sub-pixel speed-up.** `scrollSpeed` is a **1/32-px fixed-point** speed
  (`SPEED_BASE=32` = 1.0 px/frame). Each frame `total = scrollFrac + scrollSpeed`; the step is
  `total >> 5` whole pixels and the low 5 bits carry as the fraction. `UpdateWorld` runs the
  gap+entity scroll `scrollStep` times (fall-through once/frame). `scrollSpeed` ramps
  `+SPEED_INC (4 = +0.125 px)` per cone up to `SPEED_MAX (128 = 4 px/frame)` — kept ≤ the fall
  window so falls still register, and `SPEED_MAX ≤ 224` so `scrollFrac+scrollSpeed` fits 8 bits.
  No multiply/divide. Reset to base each game. RAM: `scrollSpeed`, `scrollFrac`, `scrollStep`.
  - *Earlier bug:* the first cut used `step = 1 + carry`, which an 8-bit accumulator caps at
    2 px/frame; and a large `SPEED_INC` near a too-high `SPEED_MAX` overflowed `scrollSpeed`
    (`256 → 0`, "slows down again"). The fixed-point `>> n` scheme fixes both. The fraction
    resolution (1/16, 1/32, …) is just a tuning knob — it doesn't change motion smoothness
    (always whole px/frame), only how finely the average speed can ramp.
- (b) **Speed up with score, at sub-pixel resolution.** Scroll speed should increase as the
  score climbs, in **fractional pixels** for smoothness, kept performant with **shifts** (no
  multiply/divide). Plan: a fixed-point scroll accumulator per object (e.g. 8.8 — integer +
  fraction byte); each frame add a `speed` increment; move by the integer carry. Derive `speed`
  from the score via shifts (e.g. base + (score >> n)). Applies to gaps and entities together.
- Verify: entities are spaced out (no instant re-pop); scroll visibly accelerates as score rises,
  still smooth (no judder), no roll.

### M6(c) — Entities must spawn clear of gaps  ✅ IMPLEMENTED (pending emu check)
Implemented as below: in `.entWaiting`, before respawning, `lda gapX,x / cmp #GAP_SPAWN_CLEAR
(145) / bcc .doSpawn`; otherwise re-arm `entDelay = ENT_DEFER (16)` and recheck. No new RAM.
**Symptom:** cones/skulls sometimes appear floating over a hole.
**Cause:** on each floor the gap (`gapX[f]`) and the entity (`entX[f]`) scroll at the **same
speed** (both by `scrollStep`), so their relative x is fixed for a whole pass. If an entity
respawns at the right edge (`entX = ENT_WRAP = 152`) while that floor's gap is also on the right
(~145–159), they overlap and the entity floats over the hole the entire traversal. (The JS avoids
this by only spawning where `nextHoleDist` is large.)
**Fix (to implement):** in `UpdateWorld`'s respawn branch (the `.entWaiting` path, when
`entDelay` hits 0), before spawning, check that floor's gap:
```
	lda gapX,x
	cmp #GAP_SPAWN_CLEAR    ; ~145
	bcs .deferSpawn          ; gap in the spawn zone -> wait, don't spawn over it
	... (existing: Rng / EntTypeRoll / entType=type / entX=ENT_WRAP) ...
	jmp .entNext
.deferSpawn
	lda #16
	sta entDelay,x           ; short re-check delay; gap scrolls clear, then spawn
```
- `x` = floor index in the entity loop; `gapX,x` is that floor's gap. Floor 5 has `gapX=0` (no
  gap) so it always spawns. New const `GAP_SPAWN_CLEAR` (≈145). No new RAM.
- Because gap+entity then scroll together, clearing them at spawn keeps them apart all pass; the
  gap's mid-pass wrap (0→159) only ever puts it *right* of (behind) the entity, so it never
  catches up. Checking only at spawn is sufficient.

### --- STATE SNAPSHOT (for post-compaction continuity) ---
Done & committed: M1–M5, M6(a) spawn spacing (`f93cea0`), M6(b) speed-up (`33126e1`).
Working tree is clean at `33126e1`. Build: `make` → `build/up.a26` (4096 bytes); verify in Stella.
Key implementation facts not obvious from a quick skim:
- Frame = WSYNC-exact: VSYNC 3 + VBLANK 36 + HUD 12 + 6 bands×30 + overscan(TIM64T) = 262. A
  timer-based HUD/VBLANK *rolled* — keep it WSYNC-exact; `DrawDigits` ends on a `WSYNC`.
- Positioning: gaps=Missile0, entity=GRP1, both via **cycle-74 HMOVE** (`Pos74M0`/`Pos74P1`,
  `PosTblM0`@$f500 / `PosTblP1`@$f600, page-aligned offset 0 so one `JumpTabM0` serves both;
  `CalcQuickPos` precomputes in overscan). Player=GRP0, coarse-strobed in the HUD transition.
- `HMxx` default to `$80` (cycle-74 "no motion"); each positioner sets its own fine then restores
  `$80`. Player held by `HMP0=$80`.
- Collision = hardware `CXPPMM` bit7 (P0-P1); `CXCLR` each VBLANK; `CheckCollision` runs *before*
  input/update so `playerFloor` matches the rendered frame.
- Score: 48-px glyph kernel (`DrawDigits`/`FontTable`@$f700, `GetDigitPtrs`). Playing shows
  `__nnnn`; game over alternates user-supplied `GameOverGlyphs` (reversed to bottom-row-first)
  and `HInnnn` on `goCnt` (0-119 / 120-239). `hiScore` persists via `NewGame` soft-reset
  (vs `Reset` one-time setup). Score `+1` lands on `scoreBCD+0` (least-significant).
- Speed: `scrollSpeed` is 1/32-px fixed point; step = `(scrollFrac+scrollSpeed)>>5`; ramps
  `+SPEED_INC`/cone to `SPEED_MAX` (≤224). User set `SPEED_INC=1` (gentle).
- ROM layout note: code has twice outgrown a table page; tables bumped to $f500/$f600/$f700/$f800.
  If code grows again, bump the `org`s (keep PosTblM0/P1 page-aligned at offset 0).
- Cross-cutting deferred: sprite masking for clean edge slide-in/out (pairs with M7 animations).

### M7 — Object animations  🔶 IN PROGRESS
- **Player run-cycle ✅** — two `GRP0` frames (`PlayerSprite0/1`, same page, selected via
  `PlayerFrameLo[animFrame]`). `AnimatePlayer` (overscan, playing only) swaps frames on a
  countdown whose interval **shortens with scroll speed**: `interval = ANIM_BASE - (scrollSpeed>>3)`
  (~18 frames/swap at base speed → ~6 at top speed). Frozen during game over. RAM: `animFrame`,
  `animTimer`. User redrew both player frames + the cone/skull bitmaps and tweaked the palette
  (`COL_BG=$0E`, `COL_CONE=$2C`, `COL_SKULL=$46`).
- **Edge slide-in/out ✅** — entities now slide smoothly off the left edge and in from the right
  instead of popping (see "sprite masking" below).
- **Entities (anim frames) ⬜ (deferred by user)** — animated cone/skull frames were skipped for
  now in favour of the edge slide.

### M8 — Power-up  ⬜
- The power-up item that clears all skulls on screen (JS: converts skulls → cones). New entity
  type + collision effect.

### M9 — Player vertical glide (free-Y player kernel)  ✅ DONE (branch `player-glide`)
- The player now **slides** vertically between floors (jump/fall) instead of snapping, drawn at
  an arbitrary scanline via a page-aligned zero-padded sprite + per-band pointer offset.
- **Stage 0** (free-Y player, entities/gap off): smooth glide, no notch, no roll, clean score.
- **Stage 1** (full game re-layered): entity (`GRP1`) redrawn 2x in its fixed band rows; **gap
  moved to Missile 1** (`COLUP1`) so its background colour no longer collides with the gliding
  player's `COLUP0`; run-cycle animation restored via two page-aligned frame buffers. Validated
  in Stella. A rare restart-frame over-run was traced, bounded, and confirmed gone in play (see §8).

### Cross-cutting — sprite edge slide  ✅ DONE
- **Problem:** the mod-160 wrap means an 8px object can't slide *off* an edge — entities popped
  in at `x=152` and vanished at `x=0`.
- **Solution (shift, not mask):** masking alone only shrinks a sprite in place; a true slide needs
  the bitmap shifted. So pre-shifted `asl×1..7` tables per entity (`ConeSlide`/`SkullSlide`, page
  `$f5`, generated by macro from the `CONEn`/`SKULLn` row symbols so they track the art).
  - **Left slide-out:** hold `x=0`, step `asl` 1→7, then hide.
  - **Right slide-in:** hold `x=152`, `REFP1=1` (hardware reflect), step `asl` 7→0, then normal
    scroll. The reflect lets the *same* `asl` tables serve the mirror edge — the sprites are
    left/right symmetric so it's invisible. (User's idea — saved the second table set.)
  - Encoding: `entSlide[6]` = `0` normal / `1..7` slide-out / `$80|N` slide-in. Shift = `entSlide&$7F`.
    Per-floor `entDrawLo`/`entRefp` resolved in overscan; the visible kernel just loads them.
    `REFP1` cleared before `DrawDigits` (GRP1 is shared with the score). Both edges advance inside
    the scroll-step loop, so they slide at the current scroll speed.
  - Cost: ~112 B ROM (shift tables), ~18 B RAM (`entSlide`+`entDrawLo`+`entRefp`); base + slide
    sprites colocated in page `$f5` so `entPtr+1` is constant. `ENT_WRAP` stays 152 (slide-in slot).

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

**Tunable / not-yet-polished:** score sits center-ish (`SCORE_SLEEP=36`, the reference value);
player x via `PLAYER_SLEEP`.

### M5 (part 2) — repurposed HUD: 4-digit score, GAME OVER text, HI score

The 6-glyph kernel is reused for three displays (each just a different set of `Digit0..5`
pointers, all into the one page-aligned `FontTable`):
- **Playing:** `__nnnn` — leftmost two glyphs are `BlankGlyph`, the rest are the low 4 BCD score
  digits.
- **Game over:** `GetDigitPtrs` cycles **three** displays via `goCnt` (0-239 in overscan, now
  split 3×80 ≈ 1.3 s each): **0-79 "GAMEOVER"** (6 user-supplied glyphs packing 8 letters into
  48px), **80-159 the last game's score "__nnnn"** (reuses the playing-score path — `scoreBCD`
  survives game over, only `NewGame` clears it), and **160-239 "HI" + 4-digit high score**
  (`LetterH`/`LetterI` + `hiScore`). The score phase was added later so the player sees what they
  just scored, not only the all-time high. The user's GAMEOVER bytes were top-row-first, so each
  glyph's 8 bytes are reversed to the kernel's bottom-row-first order.

**High score + soft reset.** `hiScore[2]` (4-digit BCD) is updated to `max(hiScore, score)` on
death (in `CheckCollision`'s skull path). To keep it across deaths, init was split: **`Reset`**
does the one-time TIA setup + `hiScore=0` (via `CLEAN_START`) + the PRNG seed; **`NewGame`**
resets only the per-round state (player, entities, gaps, score, `gameState`, `COLUBK`) and is
where the game-over restart jumps — so `hiScore` and `rng` persist.

**RAM added:** `hiScore[2]`, `frameCnt`, `BlankGlyph`/`GameOverGlyphs`/`LetterH`/`LetterI` (ROM).

### Steering: user-supplied GAMEOVER glyphs

The user supplied the 6-glyph "GAMEOVER" bitmap (48×8, 8 letters packed across the 6 slots) and
confirmed soft-reset for HI persistence — the elegant fix for fitting an 8-letter word in a
6-glyph region.

### M7 — player run-cycle + edge slide
- **Player animation:** two `GRP0` frames (`PlayerSprite0/1`, same page, `PlayerFrameLo[animFrame]`).
  `AnimatePlayer` (overscan) swaps frames on a countdown that shortens with speed
  (`ANIM_BASE − scrollSpeed>>3`). Frozen on game over.
- **Edge slide (sprite masking):** masking alone only shrinks a sprite in place, so a true slide
  needs the bitmap *shifted*. Pre-shifted `asl×1..7` tables (`ConeSlide`/`SkullSlide`, page `$f5`,
  macro-generated from the `CONEn`/`SKULLn` row symbols). Left slide-out: hold `x=0`, step `asl`
  up. Right slide-in: hold `x=152`, `REFP1=1` (hardware reflect — the *same* tables serve the
  mirror edge since the sprites are symmetric), step `asl` down. State in `entSlide[6]`
  (`0` normal / `1..7` out / `$80|N` in); per-floor `entDrawLo`/`entRefp` resolved in the precompute,
  the kernel just loads them; `REFP1` cleared before `DrawDigits` (GRP1 is shared with the score).

### M9 — Player vertical glide (free-Y player kernel)  [branch `player-glide`]
The logical floor (`playerFloor`) still snaps instantly on a jump/fall, but a new **visual** Y
(`playerY`, band-region-relative scanline) *lerps* toward the floor's rest line (`playerFloor*30 +
PREST_OFF`, by `PLERP` px/frame in `UpdatePlayerY`, overscan). The kernel had to become able to
draw the player at an **arbitrary** scanline, not just inside one band's content rows.

- **Free-Y draw via pointer offset.** A zero-padded sprite buffer `PlayerBuf` = 30 leading zeros +
  12 body rows + 29 trailing zeros, **page-aligned** so `(sprPtr),Y` never crosses a page (constant
  5 cycles). Per band, `sprPtr = PlayerBuf + offset` where `offset = (band+1)*30 − playerY`; the
  kernel then reads `(sprPtr),Y` with `Y` = band-local line. When the body lands in this band the
  player appears at the right rows; when it doesn't, `offset` clamps to a zeros region and every
  read is `0` (blank). `offset` is computed once per band per frame (clamped to 0..41).
- **Where the offset is computed — and why VBLANK, not overscan.** First put the 6-band
  `sprPtrLoTab[]` precompute in overscan; on glide/fall frames the extra `UpdateWorld`+
  `UpdatePlayerY` work pushed overscan past its `TIM64T` budget → **occasional roll when moving**.
  Moved the precompute into VBLANK's otherwise-idle `WSYNC` loop (one band per line, ~31 cyc of a
  76-cyc line, no change to the line count). `playerY` is final from the previous overscan and feeds
  this frame's kernel, so the ordering is correct — and overscan returns under budget. (Bonus: the
  first frame after `NewGame` now has valid pointers; previously the old-overscan order left the
  very first kernel reading uninitialised pointers.)
- **Drawing on all 30 band lines (no notch).** The band has 5 "positioning" lines at its top
  (`setbg` + the two cycle-74 `Pos74M0`/`Pos74P1` strobe lines + their two trailing lines) where the
  content loop can't run. The player is drawn on each: **line 0** (`setbg`) by making `curFloor` a
  running counter (no per-band subtract) so `sprPtr` loads early enough to write `GRP0` at ~cycle 25,
  just before the player's x (pixel 10); **lines 2 & 4** inline after each `WSYNC`; and **lines 1 & 3**
  inside the cycle-74 pads. The pads must keep `HMOVE` on cycle 74 (an 8-cyc `lda (sprPtr),y / sta
  GRP0` shifted it to 73 and made the entity/gap positioning erratic). The fix: **preload** the player
  byte into A *before* the pad's `sta WSYNC` (a WSYNC strobe doesn't disturb A), then `sta GRP0` + 3
  `nop`s = the exact 9-cycle dead-time. The content loop covers band-local 5..29 — player solid across
  the whole band.
- **Three rendering fixes found in Stella:**
  1. *Score bleed* — the score is `VDELP`-double-buffered, so its first displayed `GRP0` row uses the
     *old* latch, which still held the previous frame's last band `GRP0` write; a mid-glide player
     body row leaked into the leading blank digits. Fixed by flushing both `GRP0/GRP1` old+new latches
     at HUD entry (4 writes), **after** `COLUPF` is set.
  2. *Top-left background* — that latch flush, placed before `COLUPF`, pushed the background colour
     past HBLANK on the first visible line. Reordered: `COLUPF` first.
  3. *Bottom line cut to black* — the content loop had no closing `WSYNC`, so overscan's `VBLANK`
     blanked the last band line ~⅓ of the way across. Added a closing `WSYNC` (last line renders
     fully) and removed one VBLANK line to keep the frame at exactly 262.
**Stage 1 — full game re-layered onto the glide kernel:**
- **Entity (`GRP1`)** redrawn 2x in its fixed band rows (7..18) while the player draws free-Y on every
  line. Both reads are `(zp),Y`, so the entity row tracks in X and the player line in a scratch byte;
  the entity is loaded first (it may sit at x=0 sliding out left). Selected per floor on line 4's spare
  cycles (`COLUP1` / `entPtr` / `REFP1`).
- **Gap → Missile 1.** M0's colour is `COLUP0` (shared with the player), but the gliding player crosses
  platform rows where the gap needs `COLUP0 = COL_BG` — a conflict. Since M0 was now free, its
  positioning machinery (`PosTblM0`, `gapQuick`) was repurposed to strobe **RESM1**, so the gap is M1
  (colour `COLUP1`, `NUSIZ1 = $30` for 8px). `COLUP1` is time-multiplexed: entity colour in the body
  rows, `COL_BG` on the platform rows (different scanlines). The enable byte is **preloaded on line 18**
  so the gap turns on before pixel 0 of line 19 (else a left-edge gap clipped its top row).
- **Run-cycle animation restored.** Two page-aligned buffers `PlayerBuf0/1` one page apart; the kernel
  picks the page = `>PlayerBuf0 + animFrame`. The per-band offset (`sprPtrLoTab`) is frame-independent,
  so only the high byte changes. `PLAYER_FRAME` macro doubles 6 editable body rows per frame.
- **ROM:** the bigger kernel overflowed `$f000-$f500`; relocated `GapOnTable`/`MultTab`/`DelayTab`, the
  entity lookup tables, and the old 8-byte player frames into the gap after `PosTblP1`.
- **RAM:** `playerY`, `sprPtrLoTab[6]`; constants `PREST_OFF`, `PLERP`.

**Scanline audit → 262 NTSC.** A Stella-debugger check showed the frame at **273** scanlines, not
262. Root cause: each band is **32** scanlines, not the assumed 30 — every cycle-74 positioning
routine (`Pos74M0` gap, `Pos74P1` entity) costs **2** lines, the strobe line plus a line the
post-HMOVE `sta WSYNC` halts through (which also hides the HMOVE comb). Two positionings/band = +2
lines × 6 bands = +12, i.e. visible 204 not 192. Pre-existing since M3. Fix: trim 2 grey underside
rows per band (`platform` loop `cpy #30`→`#28`) → 30-line bands → visible 192; +1 VBLANK line →
exactly 262. The player free-Y model is untouched (offset uses the logical 30-pitch; the body sits
at band-local y7..18, above the trimmed rows) — and the trim *aligns* rendering with the model
(rendering was 32/band while the model assumed 30; now they match).

Final layout (user-chosen): the trim was rebalanced to **1 air row + 1 grey row** rather than 2 grey
(sprite shifted up one via `PREST_OFF` 7→6, air 2→1, platform thresholds shifted) — a thicker grey
underside / tighter air gap that reads better. Still 30-line bands / 262.

**Known accepted limitation — eaten-line glide distortion.** During a jump/fall the player body
slides up through a band's top (the cycle-74 positioning region), where the 2 "eaten" lines (the
`sta WSYNC` halt after each HMOVE) hold the previous `GRP0` and so duplicate two sprite rows. The
duplicated rows shift frame-to-frame as the body moves, so the sprite briefly distorts mid-transition
(clean at rest / on platforms). It can't be removed cleanly: dropping the realign `WSYNC` to draw on
those lines desyncs the variable-timing positioning and makes the whole screen jerky (tried, reverted).
The eaten line is the unavoidable cost of comb-free cycle-74 positioning (×2 objects/band). Accepted.

**Rare frame over-run — analysis + fix.** A very rare (≈once in dozens of games) one-frame roll was
reported. Ruled out the visible kernel: every band loop is `WSYNC`-exact, the free-running lines 2/4
start at a fixed cycle (the cycle-74 `PosTbl` always ends `sta HMOVE` @74 + `sta WSYNC`), the wait
loop is bounded (delay nibble ≤ 10), and `CalcQuickPos` is branchless. That leaves the unblanked/timed
work: the prime suspect is **`NewGame` on restart** — `CheckRestart` does `jmp NewGame` from overscan,
and `NewGame` runs to `NextFrame`'s `VSYNC` **without** passing `WaitOverscan`, so its length isn't
clamped by `TIM64T`. Its one variable-length path is the gap re-roll loop, so its per-floor cap was
tightened 8 → 4 to bound the tail (stacking stays rare). **Confirmed gone** across extended play after
the cap change. (Secondary suspect, not needed in the end: a heavy gameplay frame — cone collision +
several simultaneous entity transitions, each `jsr Rng`/`SetRespawnDelay` — tipping overscan past
`TIM64T`; if it ever recurs, the fix is to shift idle VBLANK lines into the timer budget.)

**Restart-frame length — measured + fixed (Gopher2600 harness).** With a headless emulator
(see `EMULATOR.md`) the restart was measured directly: the restart frame was a consistent
**246 scanlines (16 *short*, not over)** across many RNG seeds — `NewGame`, reached mid-overscan
via `CheckRestart`, fell straight into `NextFrame`'s VSYNC, skipping the `WaitOverscan` timer pad,
so the frame ended early (a one-frame roll). Fix: `NewGame` now ends `jmp WaitOverscan` (the
overscan `TIM64T` is already running when `CheckRestart` jumps in, so it pads to a full 262); the
boot path arms `TIM64T`/`VBLANK` in the one-time setup so its `NewGame → WaitOverscan` is bounded.
Emulator-validated: restart frame 246 → **262**, gameplay and post-restart frames 262, boot a
single power-on frame then 262. Also measured the overscan idle margin (`INTIM` at `WaitOverscan`)
= **4 ticks (~256 cyc)**, and confirmed bands are 30 scanlines and the gap `sta HMOVE` lands at
~cycle 74 — all numbers I had previously only estimated. These invariants are now locked by a
runnable regression suite — `tests/run.sh` (16 headless checks), documented in `tests/TESTS.md`
— so a future change that re-breaks frame timing, restart, collision, or the game-over cycle
fails the suite instead of needing a manual re-measure.

### Polish / QoL (post-M6)
- **Sound:** frame-timed engine on TIA channel 0 (`UpdateSound`, `sfxId`/`sfxTimer`) — jump (rising
  tone), drop (falling), cone (two-note coin), death (two white-noise bursts). Triggered at the
  event sites; silenced at boot and on restart. `UpdateSound`+`GetDigitPtrs` live in the trailing
  ROM gap after `DrawDigits` to keep the `$f000-$f500` code region under the `PosTblM0` org.
- **Randomisation:** free-running `frameCnt`; `NewGame` reseeds `rng = rng ⊕ frameCnt` (human-variable
  restart delay = good entropy). Random entity types + random first-spawn delays. Gap layout
  randomised per floor and **re-rolled to keep ≥`GAP_MIN_SEP`(24)px from the floor below**, so holes
  never stack and the pattern isn't a diagonal. Gaps still re-enter at the right edge on wrap (clean
  slide-in); the variety is in the start layout.
- **Fair start:** platforms begin empty; entities slide in from the right, so nothing is parked in
  the player's jump path at game start.
- **Timing:** the scroll is **O(1)** — gaps/entities/slide/respawn counters all advance by
  `scrollStep` in a single pass instead of a per-pixel loop. This keeps the overscan cost flat at
  any speed and fixed a high-speed screen roll (the old loop did up to 4× work and overran the
  overscan timer, worst on the heavier cone-pickup frame).

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
- **Re-flagged the player-vs-gap fall position.** Drove a measurement-first fix: a diagnostic
  build pinned every gap at a known x so the gap-vs-player offset could be read straight off a
  Stella snapshot, confirming the two coordinate systems align to ~1px. The fall trigger was a
  window-tuning issue (firing while the hole was still arriving), not a coordinate mismatch.
  User then hand-tuned the final window (`FALL_LO=14, FALL_HI=18`).
- **Directed thicker platforms** (+1px green, +2px grey), with the air pad shrunk to keep each
  band at exactly 30 lines.
- **Asked for 2× sprite height "without increasing pixel data — hardware stretching?", then
  proposed "write the sprite every second line".** Correct: the 2600 has no vertical stretch, so
  you hold `GRPx` for 2 scanlines. Also asked **"can the positioning occur within the platform
  lines to save white space?"** — which led to the key realization that the cycle-74 positioning
  lines *already render as background* (gap off, sprites blank) and thus double as the air pad.
  Removing the dedicated pad freed exactly the lines to double the 6 body rows (→12 lines), with
  no change to positioning or platforms.
- **Hypothesised the score artifact was a `$100` page-cross breaking the cycle-perfect DrawDigits
  timing.** The page-cross itself was disproven (bigLoop `$f824–$f84b`, in-page; font reads stay
  in `$f7xx`), but the question sent me back to find the real cause: the doubled sprite loop's
  short blank-foot left the entity's last body row in `GRP1`'s VDEL *old* latch, which the score
  displayed on its top row next frame (`VDELP1=1`). Fixed with the reference's full double-pair
  `GRP0/GRP1` clear in the foot rows.
- **Asked for the sprites to touch the platforms** instead of floating. Moved the two blank rows
  from below the sprite (the float) to a top air pad, dropped the feet onto the green, and kept
  the band at 30 lines. The gap is now prepped on the last body line (after the player draws) so
  it stays clip-free, and the sprite + VDEL-latch clear happens in the green's HBLANK before
  pixel 0 — no foot row needed.
- **Directed M7 to start with the player run cycle**: duplicate the player sprite for manual
  editing, swap between frames, and **shorten the swap interval as scroll speed increases**. Then
  hand-edited both player frames + the cone/skull graphics and adjusted the palette.
- **Directed the edge-slide and suggested the hardware reflect** to avoid a second shift-table set
  ("Perhaps we can use the hardware flip to save ram?"). It worked: `REFP1` lets one `asl` table
  serve both edges (sprites are symmetric). Also chose to **defer the cone/skull animation frames**
  in favour of the slide, and to **land the left edge first, then the right**.
- **QoL: better RNG + fair start.** Flagged that restarts felt identical and **suggested seeding
  the PRNG from a global frame timer**. Added a free-running `frameCnt` and reseed `rng ⊕ frameCnt`
  on each `NewGame`. Then diagnosed the real start-death cause: the player begins on the bottom
  floor and the first button press jumps them *into* the fixed object on the floor above. Fix:
  start with **empty platforms** — every entity begins hidden and slides in from the right, so
  nothing is ever parked in the jump path.
- **Asked for 4 sound effects** (jump rising / drop falling / cone coin / death noise). Added a
  small frame-timed SFX engine on TIA channel 0 (`UpdateSound`, `sfxId`/`sfxTimer`), triggered at
  the jump/fall/cone/death sites. (Relocating `UpdateSound`+`GetDigitPtrs` to the trailing ROM gap
  after `DrawDigits` kept the cramped `$f000-$f500` code region under the `PosTblM0` org.)
- **Noticed the screen rolling on cone pickup and correctly suspected the scroll/timing.** Root
  cause: the per-pixel `.scrollStep` loop did up to 4x work at top speed and overran the overscan
  timer (worst on the heavier cone-pickup frame). Fix: rewrote the scroll as **O(1)** (subtract
  `scrollStep` once for gaps/entities/slide/respawn counters) so overscan cost is flat regardless
  of speed. User then tuned `SPEED_INC=2`, `SPEED_MAX=96`.
- **Asked to randomise the gap (slot) layout, which never changed run-to-run** — and iteratively
  steered it to the right solution:
  1. First attempt also randomised the wrap re-entry x; user: *"the gaps randomly pop up on the
     screen"* → reverted to always re-entering at the right edge (`GAP_WRAP`), randomising only
     the **start** layout.
  2. With independent random gaps, *"the holes sometimes are directly over one another"* (chained
     falls). Added a 32px staircase + jitter — but user spotted it *"still looks deterministic"*
     (the staircase was monotonic = a diagonal).
  3. Final: each floor's start gap is fully random and **re-rolled if within `GAP_MIN_SEP`=24 of
     the floor below** — non-monotonic (no diagonal) yet never stacking. Candidates kept in 16..143
     so the separation holds as they scroll past the wrap zone.
  Also noticed the **entities entered in a rigid diagonal** (uniform spawn stagger) → replaced with
  random first-spawn delays so they arrive at varied times.
- **Directed the player vertical glide (M9) and framed the kernel constraint precisely.** Asked for
  the player to *slide* toward the platform on jump/fall, noting it "requires the player sprite to be
  generated (potentially drawn) on every single scanline" and "the state of the player managed
  frame-by-frame". Then sharpened it: *"The horizontal positioning never changes… the vertical
  positioning is based on triggering writes to `GRP0`. The kernel just needs to know when to write to
  `GRP0` and when to stop."* — which is exactly the free-Y pointer-offset draw. Chose to **branch and
  attempt it** with the option to discard, and validated **stage 0** in Stella.
- **Drove the glide bug-hunt from emulator observation:**
  - *"the boundary blanking in the air section"* → identified the 5 cycle-74 positioning lines as the
    notch; chose to fix it on the simple stage-0 kernel first.
  - *"`pcLoop` often eats up all the scanlines… occasionally, when moving up/down"* → the right
    symptom for an **overscan timer overrun** on movement frames (the new precompute tipped it over);
    fixed by moving the precompute into idle VBLANK cycles.
  - Spotted the **player graphics bleeding into the big score digits** ("notice the gap in the
    player") → the `VDELP` old-latch score bleed.
  - Caught the **top-left background not solid** ("changing background too late?") and the **bottom
    raster line transitioning to black too early (overscan)** — both precisely diagnosed and both
    correct: a late `COLUPF` and a missing closing `WSYNC`.
- **Drove the stage-1 re-layering and caught each regression by eye:** spotted the **erratic entity
  slide** (the 1-cycle cycle-74 pad shift — led to the preload fix that draws lines 1/3 *and* keeps
  `HMOVE` on cycle 74); the **green line across left-edge gaps** (gap missile enabled too late on
  line 19 — fixed by preloading the enable byte on line 18); the **3-line stale-row distortion below
  platforms** (player not drawn on the cycle-74 lines); and that the **player stopped animating**
  (single glide buffer — restored with two frame buffers). Each was a precise visual catch.
- **Reported a very rare one-frame over-run and asked for candidate analysis** rather than a blind
  fix. This drove the systematic elimination (visible kernel ruled out as fixed-time; the untimed
  `NewGame` restart path and the overscan `TIM64T` budget identified as the real candidates), and the
  user chose to "start with re-roll" — bounding `NewGame`'s gap re-roll cap as the cheap first step.
- **Scanline-count check + band proportions.** Verified the frame in the Stella debugger (it read
  **273**, not 262), correctly intuiting the bands were 32 lines, not 30. Drove the trim to a
  compliant 262, chose the **1-air / thicker-grey** proportion split, and — after seeing the
  eaten-line glide distortion — vetoed the risky `WSYNC`-removal fix ("it just missed 2 lines"),
  choosing to live with it. A precise debugger-driven correction of my wrong scanline estimate.
- **Game-over restart lockout.** Flagged that pressing fire as the game ends immediately restarts,
  and asked for a ~frame delay done memory/ROM-efficiently. Implemented as a 1-byte `restartLock`
  counter (set to `RESTART_LOCK` on death, counted down in `CheckRestart`); tuned 240 → **120** (~2s).
- **Process: keep the `.md` docs updated between milestones**, with detailed implementation
  writeups — and maintain this steering log.
