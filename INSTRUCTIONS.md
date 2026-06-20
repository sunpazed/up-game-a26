
## About

Your task is to build an Atari 2600 game based on a javascript game. The 2600 game should be complete and playable as a 4k cart. 

---

### The Game Instructions

This document defines the comprehensive rules, mechanics, and visual elements of the retro arcade mini-game "Up 1 Way" to enable automated recreation or simulation.

#### 1. Visual & UI Architecture
- Art Style: Minimalist, high-contrast, low-resolution 8-bit pixel art.
- Color Palette: Light grey background (#F0F0F0 equivalent), green-topped platforms with dark grey undersides, yellow items, a grey player sprite, and a distinct pink/red oval item.
- Heads-Up Display (HUD):
  - Top-Left Corner: Displays the current score as an integer (e.g., 3).
  - Top-Right Corner: Displays the session's highest score preceded by "HI" (e.g., HI 3).

#### 2. Core Game Logic & Mechanics

##### A. Player Properties and Movement
- The Character: A small, bipedal grey pixel sprite.
- Default Movement: The player automatically runs horizontally along a platform lane (well, it stays in the same place and the screen scrolls right-to-left, giving the appearance of running) 
- The "Up 1 Way" Control: The game uses a strict one-button control scheme. Pressing the action button (or screen tap) causes the player to immediately jump vertically upward to the platform tier directly above.
- Downward Movement: The player cannot manually descend. However, if the player walks over an open gap/pit in their current platform, they will fall through to the platform tier directly below.

##### B. Game Loop and Obstacles
- Horitonzal Scrolling: The stage naturally moves or scrolls right-to-left. In reality, the player is stationary, and the "gaps", "enemies", and "cones" are moving right-to-left towards the player.
- Items and Scoring:
  - Yellow Cones (Triangles): These are collectibles that award points. The player aims to traverse lanes to gather them.
  - Pink/Red Oval: This is a hazard/enemy item that must be avoided. Contact with this object or falling past the bottom screen boundary results in an immediate Game Over.

#### 3. Step-by-Step Level Design Rules for Replication

- Tier Generation: Create a vertical stack of parallel horizontal platforms separated by uniform gaps that accommodate the player's height.
- Gap Placement: Systematically cut small holes into the platforms at staggered positions to allow the player to fall down a level when needed.
- Entity Spawning: Populate the tiers randomly but fairly with a mixture of point-yielding yellow cones and dangerous pink/red ovals, forcing the player to choose whether to jump up or drop down a tier to survive.

---

## Assets

- `js/main.js` This is the main game asset coded in javascript that you need to port into DASM 2600 assembly (4k cart). Read this source code and use it as the approach for the game you are coding for the 2600.
- `src/up.asm` This is the game asset you need to generate and test
- `src/example.asm` This is an example file showcasing how the 2600 works. It's only an example if you need help.
- `src/*.h` Resources used by the `.asm` files
- `build/*` Where the game is built
- `make` Generates the game
- `GAME.md` Use this .md file as your planning document — add your approach, tasks, features, planning into this file
- `INSTRUCTIONS.md` is this file

---

## Example Reference Patterns (`examples/`)

Use these files as implementation references while building `src/up.asm`.

### 1) Fine movement and horizontal positioning (coarse + fine)
- Generic object-indexed positioning routine: `examples/example.asm` (`SetHorizPos`).
- Pair/object-specific routines: `examples/punchout.asm` (`DoPosition`, `DoPositionMac`, `ScoreDoPosition`).
- Expected sequence for stable placement:
  1. `WSYNC`
  2. `HMCLR`
  3. divide loop (`SBC #15` until carry clear)
  4. fine offset prep (`EOR #7`, shift left x4)
  5. write `RESPx` and `HMPx`
  6. `WSYNC`
  7. `HMOVE`

### 2) 6-digit score rendering (BCD + 48-pixel retrigger)
- Full reference flow: `examples/6-digit-score.asm`.
  - Score storage in BCD bytes (`BCDScore`).
  - Decimal-mode add routine (`SED`/`CLD`) for incremental scoring.
  - `GetDigitPtrs` maps nibbles to digit bitmap pointers.
  - `DrawDigits` performs the 48-pixel retrigger draw path.
- Alternative production-style integration: `examples/punchout.asm` (`GetDigitPtrs`, `ScoreDrawDigits`).

### 3) Energy bars using playfield + missiles
- Core conversion routine: `DoEnergy` in `examples/energy-bar.asm` and `examples/punchout.asm`.
- Fill lookup tables: `PF0Table`, `PF1Table`, `PF2Table`.
- Typical draw composition:
  - bar frame in PF,
  - end caps using missiles (`RESM0`/`RESM1`, `ENAM0`/`ENAM1`),
  - optional mid-line PF swap for left/right bars.

### 4) Bank switching pattern (only if ROM grows beyond 4K)
- Reference macro set: `examples/punchout.asm` (`BANK_SWITCH_TRAMPOLINE`, `BANK_SWITCH`, `BANK_PROLOGUE`, `BANK_VECTORS`).
- Includes F6 hotspot reference (`$1FF6`) and note for 32K (`$1FF4`).
- Current target is a 4K cart, so bank switching is optional and should only be introduced if size forces it.

### 5) Immediate implementation order for `src/up.asm`
- Keep this project in a single 4K bank while core gameplay is being built.
- Implement in this order:
  1. Stable frame timing skeleton (VSYNC, VBLANK update block, 192-line kernel, overscan).
  2. Safe horizontal positioning routine reuse (`SetHorizPos`/`DoPosition` style).
  3. Tier model + scrolling gaps (playfield tables/masks).
  4. Player lane movement (`up` jump, gap fall-down).
  5. Entity lanes (cone/hazard placeholders), collision flags, score increment hooks.
  6. HUD hooks (score + high-score placeholders first, full 6-digit path after core loop is stable).
  7. Game over/reset loop and polish.

### 6) Kernel safety constraints
- Keep gameplay state updates in VBLANK/overscan as much as possible.
- Keep visible kernel deterministic and short-cycle; avoid branching explosions inside scanline loop.
- Prefer table-driven playfield and lane logic over many repeated CMP/branch blocks.

### 7) Milestone gate workflow
- Work in small milestones that always end in a successful `make` build.
- After each milestone, run in emulator and verify expected behavior before starting the next milestone.
- Keep a short verification checklist in `GAME.md` and mark gates as they pass.
