# Emulator Test Harness — Stella + Gopher2600

Two complementary Atari 2600 emulators back this project, each verifiable in its own way:

| | **Stella** | **Gopher2600** |
|---|---|---|
| Audience | Humans | Machines / CLI |
| Strength | Visual: sprites, colour, flicker, roll, "does it feel right" | Timing & state: scanline counts, cycles, RAM, input injection |
| Output | **Screenshots** (`build/up.png`) — durable, reviewable artifacts | **Text** (scanline totals, register/RAM values) — assertable in scripts |
| Mode | Interactive GUI + play | Headless, scripted via stdin; deterministic |
| Verified by | a person (or image-capable review) eyeballing the snapshot | `grep`/assert on stdout; CI-friendly |

Use **both**. Stella answers *"does it look and play right?"* — a machine can't judge a
sprite's shape or a colour. Gopher2600 answers *"is the frame exactly 262 scanlines / is
`gameState` 0?"* — a human can't eyeball a cycle count. Neither replaces the other; pair a
visual claim with a numeric one wherever possible (e.g. "no roll" ⇄ `tv frame` `total: 262`).

- **Stella** — <https://stella-emu.github.io> · GUI player + debugger (human / visual)
- **Gopher2600** — <https://github.com/JetSetIlly/Gopher2600> · headless CLI debugger (machine)
- **ROM under test:** `build/up.a26` (produced by `make`)

> Why this harness exists: scanline/cycle timing was repeatedly mis-estimated by hand (a
> frame *measured* 273 vs an *estimated* 262; an overscan margin guessed instead of read).
> Measure — don't count by eye. Visual bugs (a missing sprite row, a comb, a roll) are caught
> in Stella; timing/logic bugs are caught in Gopher2600.

---

## Build artifacts & background (read this first)

`make` runs DASM and produces three files in `build/`. Only the first is loaded by an
emulator; the other two make debugging tractable:

| File | What it is | Used for |
|---|---|---|
| `build/up.a26` | the 4K ROM image (exactly 4096 bytes) | what Stella / Gopher2600 actually run |
| `build/up.sym` | symbol table (label ↔ address), from DASM `-s` | annotating debugger output with names |
| `build/up.lst` | full assembly listing (address, bytes, source line) | mapping an address back to source |

(Produced by `DASM_FLAGS := -f3 -o…a26 -I… -l…lst -s…sym` in the `Makefile`; `make clean`
removes the `.sym`/`.lst`, so rebuild before debugging.)

**Why timing matters (the thing the harness checks).** The 2600 has no frame buffer — the
program "races the beam," emitting TIA register writes in exact sync with the scanline being
drawn. An NTSC frame is **262 scanlines**: VSYNC 3 + VBLANK ~37 + visible 192 + overscan ~30.
Emit the wrong count and the TV can't lock vertical sync — the picture rolls. So the core
machine check is simply *"is every frame 262 scanlines?"* (Gopher2600, numeric). The other
half is *"do the sprites/colours look right, no comb, no flicker?"* (Stella, visual).

### Symbols — the `.sym` file (used by both emulators)

- **Generation:** the `-s build/up.sym` flag in `DASM_FLAGS`. Addresses shift on every
  rebuild, so after `make` the `.sym` is the source of truth for "where is label X now."
- **Format:** one line per symbol — `NAME  hexADDR  (flags)`. Globals are plain
  (`playerFloor 0080`); DASM scope-local labels carry a prefix (`0.bandsDone f22f`).
- **Auto-load:** both emulators pick up `<romname>.sym` sitting beside the `.a26` — no flag
  needed. The payoff is **name-annotated output**, e.g. `0x0080 (playerFloor) (RAM) = 0x05`
  and labelled disassembly. (If labels are missing, the `.sym` isn't next to the ROM —
  rebuild.)
- **Important caveat (Gopher2600):** annotation is *output-only*. You still address targets
  **numerically** in commands — `peek 0x80`, `break pc 0xf2cd`. A symbol *name* as input does
  **not** resolve (`peek playerFloor` → "not found in any symbol table"). Look the address up:
  ```sh
  grep -w playerFloor  build/up.sym     # -> playerFloor  0080
  grep -w WaitOverscan build/up.sym     # -> WaitOverscan f2cd
  ```

---

## Stella — visual / human verification

The human-facing loop: build, load, play, and capture a screenshot anyone (or an
image-capable reviewer) can check against the intended design.

1. **Install** (macOS): `brew install --cask stella`, or download from the site above.
2. **Load the ROM:**
   ```sh
   open -a Stella build/up.a26      # macOS
   # or:  stella build/up.a26
   ```
3. **Play:** the joystick maps to the arrow keys and fire to the joystick button (see
   Stella's input config). This game uses only fire (jump / restart).
4. **Capture a screenshot — the verifiable artifact.** Save a PNG snapshot from Stella
   (snapshot key / menu). The project convention is **`build/up.png`** (git-ignored); point
   Stella's snapshot directory at `build/` so the path is predictable. The developer or
   reviewer then inspects that image. Frame-by-frame captures (`build/up_dbg_*.png`) are used
   to study motion — e.g. the player glide across a platform.
5. **Stella debugger** (press `` ` ``): the origin of the command set Gopher2600 borrowed
   (`break`, `peek`, `poke`, `trap`, `run`, `step`, `frame`, `scanline`, `ram`, …). Stella
   also auto-loads `build/up.sym`, so its debugger shows your label names. Its TIA /
   frame-stats overlay shows the live **scanline count** (should read 262). Good for quick
   interactive pokes; use Gopher2600 for repeatable/automated runs.

**When to use Stella:** sprite shapes & art, colours/palette, flicker, screen roll, "is the
glide smooth", HUD legibility, edge-slide look — anything a person must judge. The saved
snapshot *is* the verifiable record: a reviewer confirms the visual against the design
("player whole at rest", "no comb on the left edge", "score reads 0000"), and pairs it with
a Gopher2600 numeric check where one exists.

---

## Gopher2600 — machine / CLI verification

The rest of this document details the headless, scriptable harness for timing, state, and
logic. It assumes the `gopher2600` binary is on your `PATH`.

## 1. Setup

1. **Build the emulator** from source (Go toolchain required):
   ```sh
   git clone https://github.com/JetSetIlly/Gopher2600
   cd Gopher2600 && make            # or: go build
   ```
   Put the resulting `gopher2600` binary on your `PATH` (or invoke it by path).

2. **Build the ROM** (`make`) so `build/up.a26` and `build/up.sym` both exist. Gopher2600
   auto-loads the `.sym` for name-annotated output — see *Build artifacts & background* above,
   including the numeric-address caveat (you query by `0x80`, not `playerFloor`).

3. **Smoke test:**
   ```sh
   printf "break frame 30\nrun\ntv frame\nquit\n" | gopher2600 HEADLESS build/up.a26
   # -> break on Frame->30
   #    top: 29, bottom: 242, total: 262
   ```

---

## 2. Two modes of operation

### Autonomous (recommended for testing / CI)
Pipe a newline-separated command script to the headless debugger via stdin and parse stdout:

```sh
printf "break frame 60\nrun\npeek 0x80\nquit\n" | gopher2600 HEADLESS build/up.a26
```

**Anatomy of the invocation:**
- `gopher2600 HEADLESS build/up.a26` — launch the debugger in headless mode on the ROM. It
  reads debugger commands from **stdin, one per line**, and writes results to **stdout**.
- `printf "…\n…\n"` feeds those lines; **always finish with `quit`** or the process waits for
  more input.
- `run` advances emulation **until the next halt condition** (a `break`/`trap`/`watch` you
  set earlier). With **no valid halt pending, `run` never returns** — the process hangs.
  Guard against this: only `run` after a breakpoint you know resolves, and use numeric
  addresses (a mistyped/unknown break target silently fails to halt).
- Capture results by piping stdout through `grep`/`nl`/`sed` (see recipes below).
- **Deterministic:** with no injected input the run is reproducible (the game's PRNG is
  seeded from a free-running frame counter, so a fixed input sequence yields a fixed
  playthrough). This is what makes scripted assertions stable.

If a script hangs, kill it and fix the offending break target:
```sh
pkill -f gopher2600
```

### Interactive
Run the debugger with a terminal for live stepping/inspection (see the `-term`/GUI options
in the Gopher2600 wiki). The same commands apply; the autonomous recipes are just those
commands fed over stdin instead of typed.

---

## 3. Core workflow recipes (validated on this ROM)

**Verify NTSC frame size (must be 262):**
```sh
printf "break frame 30\nrun\ntv frame\nquit\n" | gopher2600 HEADLESS build/up.a26
```
`tv frame` reports `top`, `bottom`, and `total` (scanlines/frame) of the **just-completed**
frame. `total: 262` = NTSC-compliant.

**Read the overscan timer margin** (how close the per-frame work is to overrunning `TIM64T`):
```sh
# WaitOverscan is the INTIM spin-loop; INTIM is the RIOT timer at $0284
printf "break frame 60\nrun\nbreak pc 0xf2cd\nrun\npeek 0x284\nquit\n" \
  | gopher2600 HEADLESS build/up.a26
# -> 0x0284 (INTIM) (RIOT) = 0x04   (4 timer ticks ~= 256 CPU cycles of idle margin)
```

**Find the exact beam position of a write** (e.g. verify a cycle-74 `sta HMOVE`):
```sh
printf "break pc 0xf520\nrun\ntv\ncpu\nquit\n" | gopher2600 HEADLESS build/up.a26
# -> FR=0001 SL=049 CL=145   (CL is the VISIBLE pixel 0..159; HBLANK is negative.
#     CL=145 => colour-clock 68+145=213 => CPU cycle ~71-74)
```

**Inject controller input and check game state** (does fire jump the player?):
```sh
printf "break frame 60\nrun\npeek 0x80\nstick left fire\nbreak frame 64\nrun\npeek 0x80\nquit\n" \
  | gopher2600 HEADLESS build/up.a26
# playerFloor 0x05 -> 0x04 : fire triggered a jump
```

**Force a state and test a feature** (e.g. game-over restart lockout):
```sh
printf "break frame 60\nrun\npoke 0xc5 0x01\npoke 0xf3 0x78\nstick left fire\nbreak frame 100\nrun\npeek 0xc5\npeek 0xf3\nquit\n" \
  | gopher2600 HEADLESS build/up.a26
# gameState stays 0x01 (no restart) while restartLock counts down 0x78 -> 0x50
```

**Sweep many conditions from the shell** (e.g. restart-frame size across RNG seeds):
```sh
for F in 50 90 150 200 280; do
  printf "break frame %d\nrun\npoke 0xc5 1\npoke 0xf3 0\npoke 0x83 0\nstick left fire\nbreak frame %d\nrun\ntv frame\nquit\n" "$F" "$((F+1))" \
    | gopher2600 HEADLESS build/up.a26 | grep total: | sed "s/^/restart@$F -> /"
done
```

---

## 4. Command reference

The full debugger keyword set (from `HELP`):

```
AUDIO  BALL  BREAK  BUS  CARTRIDGE  CLEAR  COMPARISON  COPROC  CPU  DISASM  DROP
DWARF  GOTO  GREP  HALT  HELP  INSERT  KEYPAD  LAST  LIST  LOG  MEMMAP  MEMUSAGE
MISSILE  ONHALT  ONSTEP  ONTRACE  PANEL  PATCH  PEEK  PERIPHERAL  PLAYER  PLAYFIELD
PLUSROM  POKE  QUANTUM  QUIT  RAM  RESET  REWIND  RIOT  RUN  SCRIPT  STEP  STICK
SWAP  SYMBOL  TIA  TRACE  TRAP  TV  WATCH
```
`HELP <keyword>` prints usage for any of them. The most useful for game testing:

### Execution control
| Command | Purpose |
|---|---|
| `RUN` | run until the next halt condition (breakpoint/trap/watch) |
| `STEP` | step one instruction; `STEP SCANLINE` / `STEP FRAME` step larger units |
| `QUANTUM <cpu\|video>` | set step granularity (instruction vs video cycle) |
| `HALT` | halt immediately |
| `GOTO` | run to a specific coordinate |
| `QUIT` | exit |

### Halt conditions
| Command | Example | Notes |
|---|---|---|
| `BREAK` | `break frame 60`, `break pc 0xf520`, `break sl 100` | halt when a target hits a value. Targets incl. `FRAME`, `SL` (scanline), `PC`, `CL` (clock). **`PC` must be named** (`break pc <addr>`). |
| `TRAP` | `trap sl` | halt when a target *changes* |
| `WATCH` | `watch write GRP0`, `watch read INPT4` | halt on memory access; great for catching a stray write (e.g. score VDEL bleed) |
| `LIST` / `DROP` / `CLEAR` | `list`, `drop 0`, `clear` | review / delete halt conditions |

### Memory & state
| Command | Example | Notes |
|---|---|---|
| `PEEK` | `peek 0x80`, `peek 0x284` | read memory; output is symbol-annotated |
| `POKE` | `poke 0xc5 0x01` | write memory (force a state for testing) |
| `RAM` | `ram` | dump zero-page RAM |
| `CPU` | `cpu` | registers (`PC A X Y SP SR`) |
| `TIA` / `RIOT` | `tia`, `riot` | chip state |
| `TV` | `tv`, `tv frame` | beam position (`FR/SL/CL`) and frame geometry (`top/bottom/total`) |
| `DISASM` | `disasm` | disassembly (labelled with symbols) |
| `SYMBOL` | `symbol` | symbol-table info — note DASM source labels do **not** resolve as command input (query by address; see the Symbols caveat) |
| `MEMMAP` / `MEMUSAGE` | `memmap` | address map / RAM-usage stats |

### Input (controllers & console)
| Command | Example | Notes |
|---|---|---|
| `STICK <port> <action>` | `stick left fire`, `stick left nofire`, `stick left up` | **port is `LEFT`/`RIGHT`** (left = player 0). Actions: `FIRE NOFIRE UP DOWN LEFT RIGHT NOUP… SECOND NOSECOND`. Input persists until changed. |
| `PANEL` | console switches (reset/select/difficulty/colour) |
| `KEYPAD` | keypad controller input |
| `PERIPHERAL` | show/set the controller type per port |

### Scripting / automation
| Command | Purpose |
|---|---|
| `SCRIPT RECORD <file>` / `SCRIPT <file>` | record a command session and replay it |
| `ONHALT <cmds>` | run commands automatically on every halt (e.g. `onhalt tv frame` to log each break) |
| `ONSTEP` / `ONTRACE` | run commands on every step / trace event |
| `TRACE` | trace execution |

### Other
`REWIND` (step back in time), `RESET`, `CARTRIDGE`/`INSERT`/`SWAP` (cart management),
`PLAYER`/`MISSILE`/`BALL`/`PLAYFIELD`/`AUDIO` (per-object TIA inspection), `LOG`, `GREP`,
`LAST`, `PATCH`, `COMPARISON`, `DWARF`/`COPROC` (for ARM/coprocessor carts).

---

## 5. Gotchas (learned the hard way)

- **A breakpoint that doesn't resolve makes `run` hang forever** in headless mode (no halt
  ever fires). If a script hangs, the break target was wrong — kill it (`pkill -f gopher2600`)
  and fix the address/syntax. Prefer numeric addresses from `build/up.sym`.
- **`STICK` needs the port word:** `stick left fire` works; `stick fire` and `stick 0 fire`
  are rejected ("unrecognised argument").
- **`BREAK PC` needs the `pc` keyword:** `break pc 0xf520`, not `break 0xf520`.
- **`CL` (clock) is the visible pixel 0..159**, with HBLANK as *negative* clocks. Convert to
  CPU cycle via `cycle ≈ (68 + CL) / 3`.
- **`tv frame` reports the frame that just completed**, so to read frame *N* break at frame
  *N+1*.
- **macOS has no `timeout`** — rely on the shell/tool timeout, and keep break targets valid.

---

## 6. Project RAM map (handy `PEEK`/`POKE` targets)

Symbols auto-load, so addresses appear labelled. Common ones:

| Addr | Symbol | Meaning |
|---|---|---|
| `0x80` | `playerFloor` | 0=top … 5=bottom |
| `0x82` | `playerY` | visual glide scanline (`floor*30 + PREST_OFF`) |
| `0x83` | `btnPrev` | fire edge-detect latch |
| `0xc5` | `gameState` | 0=playing, 1=game over |
| `0xc6` | `scoreBCD` | BCD score (3 bytes) |
| `0xf3` | `restartLock` | frames left before restart allowed |
| `0x0284` | `INTIM` | RIOT overscan timer (read at `WaitOverscan` for the margin) |

Key code addresses (from `build/up.sym`, will shift as code changes — re-check with
`grep <label> build/up.sym`): `WaitOverscan 0xf2cd`, `Pos74M0 0xf2d7`, `BandLoop 0xf17b`,
gap `sta HMOVE 0xf520` (`pM0_150 + 2`; stable since it's after `org $f500`).

---

## 7. Suggested autonomous checks (future `make verify`)

A small script can assert invariants and fail CI on regression:
- **Frame size:** `tv frame` → `total` must equal **262** at several frames (start,
  mid-gameplay, game-over, the restart frame).
- **Overscan margin:** `INTIM` at `WaitOverscan` must be `> 0` (work stays under the timer).
- **Restart:** force game-over + injected fire after the lockout → `gameState` returns to 0
  and the restart frame is 262.
- **Lockout:** fire during the lockout window must not restart.

Pattern: run each scenario headless, `grep` the expected line, and exit non-zero if the
value is wrong. Because the harness is headless and deterministic, these run unattended.
