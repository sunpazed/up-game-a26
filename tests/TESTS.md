# Test suite — UP 1 WAY

A headless regression suite (`tests/run.sh`) that asserts the game's timing and
state invariants against the [Gopher2600](https://github.com/JetSetIlly/Gopher2600)
emulator. It is the machine-checkable companion to the human/visual Stella checks;
see [`../EMULATOR.md`](../EMULATOR.md) for the underlying harness and command
reference.

The suite exists so the brittle invariants of a cycle-exact 2600 kernel — a 262
scanline frame, the restart path, collision outcomes — can be re-verified in
seconds after any change, instead of being eyeballed in an emulator.

## Running

```sh
make                                            # build/up.a26 + build/up.sym
tests/run.sh                                    # uses `gopher2600` on PATH
GOPHER=/path/to/gopher2600 tests/run.sh         # explicit binary
ROM=releases/up-1-way.a26 tests/run.sh          # test a different ROM
```

Prints one `PASS`/`FAIL` line per check and a total; **exits 0 only if every
check passes** (CI-friendly). A failing check also dumps the last few lines of
the emulator output, prefixed `|`, so you can see what it got instead.

## How it works

Each check pipes a short debugger script to `gopher2600 HEADLESS` over stdin and
greps stdout for an expected literal string:

```sh
check NAME WANT "break frame 60\nrun\n…\npeek <addr>\nquit\n"
```

- **`break frame N` / `run`** advances to a deterministic point. The emulator's
  PRNG is frame-counter seeded, so a given frame is reproducible run-to-run.
- **`poke <addr> <val>`** forces a RAM state (e.g. set up a game-over screen, or
  place an entity) without having to play into it. **`peek <addr>`** reads state
  back; its output line (`(label) (RAM) = 0xNN`) is what `WANT` matches against.
- **`stick left fire`** injects controller input (LEFT = player 0 = the joystick).
- **`tv frame`** reports the scanline total of the frame just completed.

**Addresses are resolved from `build/up.sym` at runtime** (`sym`/`symlo`/`off`
helpers), never hard-coded — so the suite survives the address shifts that come
with every rebuild. `off <addr> N` indexes into a byte array (e.g. `entType+5`
is the floor-5 entity slot).

## What each check asserts

### Frame timing — every frame is exactly 262 NTSC scanlines
| Check | Setup | Asserts |
|---|---|---|
| `frame-262 @60`  | run to frame 60  | `total: 262` (mid-gameplay) |
| `frame-262 @120` | run to frame 120 | `total: 262` (still holds later) |
| `boot-settled @6`| run to frame 6   | `total: 262` (power-on transient is over) |

Catches a rolling / non-compliant frame — the bug class that produced 273 lines
(over-tall bands) and a 246-line restart frame earlier in development.

### Restart
| Check | Setup | Asserts |
|---|---|---|
| `restart-frame-262` | game-over, lockout cleared, fire | the restart frame is `total: 262` (the `NewGame → WaitOverscan` fix; was 246) |
| `restart-fires`     | same | `gameState = 0x00` — the restart actually ran |

### Input / movement
| Check | Setup | Asserts |
|---|---|---|
| `jump-5to4`   | settled on floor 5, fire | `playerFloor = 0x04` — fire jumps up one floor |
| `gap fall 4->5` | floor 4 (settled), gap on floor 4 in the fall window | `playerFloor = 0x05` — a gap underfoot drops the player one floor |

### Collision (real `CXPPMM` hardware collision)
Places an entity on the player's floor (5) at the player's x (10) so the GRP0
(player) and GRP1 (entity) sprites genuinely overlap when rendered — the
collision latch fires and `CheckCollision` acts on it.
| Check | Setup | Asserts |
|---|---|---|
| `cone -> +1 score`   | cone on the player | `scoreBCD = 0x01` — collecting a cone scores |
| `skull -> game over` | skull on the player | `gameState = 0x01` — a skull kills |
| `hi-score on death`  | run score `0x34` > stored hi `0x00`, then a fatal skull | `hiScore = 0x34` — the high score is updated on death |

### Restart lockout
| Check | Setup | Asserts |
|---|---|---|
| `lockout-blocks`   | game-over, `restartLock = 0x78`, hold fire | `gameState = 0x01` 30 frames later — fire can't restart during the window |
| `lockout-expires`  | game-over, short lock, fire after it elapses | `gameState = 0x00` — a fresh press restarts once the window clears |

### Overscan budget
| Check | Setup | Asserts |
|---|---|---|
| `overscan-margin` | break at `WaitOverscan` on a gameplay frame | `INTIM = 0x04` — ~256 cycles of idle headroom under `TIM64T`; per-frame work isn't overrunning |

### Game-over text cycle
Pokes `goCnt` into each 80-frame phase, lets overscan rebuild the digit pointers,
then reads the leftmost glyph (`Digit0+0`, low byte):
| Check | Phase (`goCnt`) | Asserts leftmost glyph = |
|---|---|---|
| `go-cycle GAMEOVER @40` | 0–79    | `GameOverGlyphs` |
| `go-cycle SCORE @100`   | 80–159  | `BlankGlyph` (the `__nnnn` last-score layout) |
| `go-cycle HI @180`      | 160–239 | `LetterH` (the HI screen) |

## Are the tests any good? (mutation testing)

Passing only proves the tests pass. To confirm they actually *discriminate* —
fail when behaviour breaks — break an invariant on purpose and watch the right
checks (and only those) fail:

```sh
# e.g. mistune the VBLANK line count in src/up.asm (ldx #34 -> #40), then:
make && tests/run.sh
#   => frame-262 ×3 and restart-frame-262 FAIL; every behaviour check stays green
git checkout src/up.asm && make           # revert, back to all-green
```

This was run for the timing group (4 fail, behaviour unaffected — proving both
discrimination *and* independence) and the score-cycle check (it flipped
fail→pass the moment that feature landed). Each new behaviour check above was
likewise verified to read the post-condition it claims (e.g. the cone check sees
`scoreBCD` step 0→1, not a coincidental match).

## Coverage boundaries (what this suite does *not* cover)

The suite asserts **machine state and timing**, not pixels. It confirms *which*
display phase / floor / score is selected, but the actual rendered appearance —
sprite shapes, colours, the smoothness of the vertical glide, HUD digit layout —
is still a **Stella** visual check (`build/up.png`). Also not yet covered:
sound (`AUDxx`), the no-stacking random gap layout, entity edge-slide animation,
and the power-up (M8, unimplemented). Add new cases the same way: pick a
deterministic frame, `poke` the scenario, `peek` the post-condition, and assert
a labelled value.
