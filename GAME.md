# UP 1 WAY - Implementation Plan

## 1. Game Analysis (JS Version)
The JavaScript version of "Up 1 Way" defines the following core mechanics:
- **Player**: A bipedal grey sprite.
- **Movement**: 
  - Automatic horizontal movement (the screen scrolls right-to-left).
  - **Jump Up**: On button press, the player moves to the tier above.
  - **Fall Down**: If the player walks over a gap in the current tier, they fall to the tier below.
- **Tiers/Platforms**:
  - A vertical stack of platforms.
  - Each tier has "holes" (gaps) that move right-to-left.
- **Entities**:
  - **Yellow Cones (Triangles)**: Collectibles that increase score.
  - **Pink/Red Ovals**: Hazards that cause Game Over.
  - **Power-up**: A power-up that clears all hazards (skulls) from the screen.
- **Scoring**: Displayed in the top-left. High score in the top-right.

## 2. Atari 2600 Technical Strategy
To implement this on the Atari 2600 (6502 assembly), I will use:
- **Graphics**:
  - **Player 0**: The player sprite.
  - **Player 1**: Used for items (cones/ovals) or as a secondary sprite if needed.
  - **Missiles/Ball**: Used for small objects or additional entities.
  - **Playfield**: Used to draw the platforms and holes. Since the playfield is limited, I might use a combination of the playfield and sprites/missiles to represent the platforms and their gaps.
  - **Background**: Minimalist colors as specified.
- **Logic**:
  - **Kernel**: The main loop that draws the screen line-by-line (scanline-based rendering).
  - **Vertical Sync & VBlank**: Standard timing for frame updates.
  - **Input**: Reading the joystick/button state.
  - **Memory Management**: Using RAM to track player position, scores, entity positions, and platform/gap locations.
- **Complexity Management**:
  - The 2600 has very limited RAM (128 bytes). I must be extremely efficient with how I store platform and entity data.
  - I will likely use a simplified representation of the tiers/gaps.

## 3. Milestones (Verifiable Deliverables)

### Milestone 1: Basic Kernel & Player Rendering
- [ ] Set up the project structure and build process (`make`).
- [ ] Implement a basic kernel that clears the screen and renders a single player sprite at a fixed position.
- [ ] **Verification**: Successful compilation with `make` and a stable, non-crashing loop.

### Milestone 2: Movement & Input
- [ ] Implement input reading (button press).
- [ ] Implement vertical movement (changing Y position of Player 0).
- [ ] **Verification**: Successful compilation and code logic for Y-position changes in response to input.

### Milestone 3: Scrolling Platforms & Gaps
- [ ] Implement a method to render "platforms" and "gaps".
- [ ] Implement the horizontal scrolling mechanic (moving platform/gap data right-to-left).
- [ ] **Verification**: Successful compilation and correct rendering of moving platform/gap patterns.

### Milestone 4: Entities & Collision
- [ ] Implement entity spawning (Yellow Cones, Pink/Red Ovals).
- [ ] Implement collision detection between the player and entities.
- [ ] **Verification**: Successful compilation and logic for collision detection.

### Milestone 5: Scoring, HUD & Game Loop
- [ ] Implement the scoring system and HUD (Score and High Score).
- [ ] Implement the Game Over state.
- [ ] Implement the power-up mechanic.
- [ ] **Verification**: Full game loop functionality.

## 4. Resource Mapping
- **Player Sprite**: `player.asm` style or custom bit patterns.
- **Items**: Small sprites or missiles.
- **Platforms**: Playfield segments or customized scanline drawing.
- **HUD**: Small sprites or playfield-based digits.

## 5. Example References and Integration Notes

This section maps useful implementation patterns from `examples/` into the current milestone plan.

### Milestone 1 (Kernel + player rendering)
- Reuse coarse/fine positioning structure from `examples/example.asm` (`SetHorizPos`) and `examples/punchout.asm` (`DoPositionMac`).
- Keep HMOVE sequence disciplined (`WSYNC`/`HMCLR`/divide loop/`RESPx`+`HMPx`/`WSYNC`/`HMOVE`) to avoid horizontal jitter.

### Milestone 2 (Input + movement)
- Keep player lane/tier movement logic in VBLANK and keep scanline kernel simple.
- Use positional routines from `examples/example.asm` as a stable horizontal anchor while vertical tier logic changes per frame.

### Milestone 3 (Scrolling platforms + gaps)
- Use playfield-first approach and table-driven masks inspired by PF table use in `examples/energy-bar.asm` and `examples/punchout.asm`.
- Prefer compact table/state representations for gaps and scrolling offsets to fit 128-byte RAM constraints.

### Milestone 4 (Entities + collision)
- Use missile/player positioning and enable patterns from `examples/example.asm` (`ENAMx`, `RESMx`) as references for lightweight entities.
- Keep collision checks/state transitions in VBLANK/overscan, not in the visible kernel.

### Milestone 5 (Scoring + HUD + loop completion)
- 6-digit score reference path:
  - `examples/6-digit-score.asm` (`BCDScore`, `AddScore`, `GetDigitPtrs`, `DrawDigits`)
  - `examples/punchout.asm` (`GetDigitPtrs`, `ScoreDrawDigits`)
- Energy bar reference path:
  - `examples/energy-bar.asm` (`DoEnergy`, `PF0Table/PF1Table/PF2Table`)
  - `examples/punchout.asm` (`DrawEnergy`, `DoEnergy`)

### ROM-size contingency
- If the game no longer fits 4K, use `examples/punchout.asm` bank-switch macros as a migration template.
- Until then, keep `up.asm` single-bank to reduce complexity and risk.

## 6. Immediate Build Checklist (`src/up.asm`)

### Phase A: Stabilize frame and core state
- [x] Replace ad-hoc frame logic with explicit VSYNC/VBLANK/Kernel/Overscan sections.
- [x] Ensure one clean horizontal positioning routine is used correctly (object index explicitly set).
- [x] Normalize RAM map for player, tier/gap scroll, entity placeholders, score, and game state.

### Phase B: Gameplay scaffolding
- [x] Add tier/lane index model and jump-up / fall-down lane transitions.
- [x] Add table-driven gap progression (scroll offset + per-tier gap position).
- [x] Add placeholder cone/hazard lane objects and collision hooks.

### Phase C: HUD and progression hooks
- [x] Add score/high-score variables and update hooks.
- [x] Add HUD placeholder pass (simple PF/sprite markers first).
- [x] Add game-over flag/state and reset path.

### Planned subroutine names (ordered)
- [x] `InitGame`
- [x] `ReadInput`
- [x] `UpdateWorld`
- [x] `UpdatePlayerLane`
- [x] `UpdateGaps`
- [x] `UpdateEntities`
- [x] `CheckCollisions`
- [x] `DrawKernel`
- [x] `DrawHUD` (placeholder initially)
- [x] `SetHorizPos`

## 7. Verification Gates (Stop-and-Check Workflow)

Use this sequence to avoid large unverified jumps:

### Gate 1: Baseline stability (ready now)
- Build passes with `make`.
- Emulator check: stable frame, visible tiers, player sprite visible, no crash/reset loop.

### Gate 2: Movement and lane logic
- Emulator check: button press moves player up one lane only.
- Emulator check: standing over a lane gap causes fall-down by one lane.

### Gate 3: Entity interaction
- Emulator check: cone contact increments score values.
- Emulator check: skull contact transitions to game-over state.

### Gate 4: HUD and polish pass
- Replace placeholder HUD with explicit score/high-score presentation.
- Add game-over text style closer to source screenshots.
