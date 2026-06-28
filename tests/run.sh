#!/usr/bin/env bash
#
# Headless regression suite for UP 1 WAY, driven by the Gopher2600 emulator.
# Asserts timing/state invariants by piping debugger command scripts to the
# headless emulator and grepping stdout. See ../EMULATOR.md for the harness.
#
#   Usage:  [GOPHER=/path/to/gopher2600] [ROM=build/up.a26] tests/run.sh
#
# Exits 0 if every check passes, non-zero otherwise (CI-friendly). All ROM
# addresses are resolved from the .sym at runtime, so the suite survives the
# address shifts that come with rebuilding.
#
set -u
GOPHER="${GOPHER:-gopher2600}"
ROM="${ROM:-build/up.a26}"
SYM="${ROM%.a26}.sym"

command -v "$GOPHER" >/dev/null 2>&1 || { echo "ERROR: '$GOPHER' not found (set GOPHER=)"; exit 2; }
[ -f "$ROM" ] || { echo "ERROR: ROM '$ROM' not found (run 'make')"; exit 2; }
[ -f "$SYM" ] || { echo "ERROR: symbols '$SYM' not found (run 'make')"; exit 2; }

sym()   { awk -v n="$1" '$1==n{print "0x"$2; exit}'              "$SYM"; }  # label -> 0xADDR
symlo() { awk -v n="$1" '$1==n{print "0x"substr($2,3,2); exit}'  "$SYM"; }  # label -> 0xLO (low byte)
off()   { printf '0x%02x' "$(( $1 + $2 ))"; }                               # 0xADDR + N -> byte-array element

pass=0; fail=0
# check NAME WANT CMDS  -- run CMDS headless, pass if stdout contains WANT (literal)
check() {
  local name="$1" want="$2" cmds="$3" out
  out=$(printf '%b' "$cmds" | "$GOPHER" HEADLESS "$ROM" 2>&1)
  if printf '%s' "$out" | grep -qF -- "$want"; then
    printf 'PASS  %s\n' "$name"; pass=$((pass+1))
  else
    printf 'FAIL  %s  (want: %s)\n' "$name" "$want"
    printf '%s\n' "$out" | tail -3 | sed 's/^/        | /'
    fail=$((fail+1))
  fi
}

# Resolve addresses (RAM state + a couple of code/data labels).
GS=$(sym gameState);  PF=$(sym playerFloor); BP=$(sym btnPrev)
RL=$(sym restartLock); GC=$(sym goCnt);       D0=$(sym Digit0)
WO=$(sym WaitOverscan)
GLYPH_GO=$(symlo GameOverGlyphs)   # leftmost glyph low byte: GAMEOVER phase
GLYPH_HI=$(symlo LetterH)          #                          HI phase
GLYPH_SCORE=$(symlo BlankGlyph)    #                          score phase (blank lead digit)

echo "== UP 1 WAY regression suite (Gopher2600) =="
echo "   ROM=$ROM  gameState=$GS goCnt=$GC Digit0=$D0 WaitOverscan=$WO"
echo

# --- Frame timing: every frame is exactly 262 NTSC scanlines ---
check "frame-262 @60"     "total: 262" "break frame 60\nrun\ntv frame\nquit\n"
check "frame-262 @120"    "total: 262" "break frame 120\nrun\ntv frame\nquit\n"
check "boot-settled @6"   "total: 262" "break frame 6\nrun\ntv frame\nquit\n"

# --- Restart: forces a clean 262 frame AND actually restarts (gameState -> 0) ---
RESTART="break frame 100\nrun\npoke $GS 0x01\npoke $RL 0\npoke $BP 0\nstick left fire\nbreak frame 101\nrun"
check "restart-frame-262" "total: 262"               "$RESTART\ntv frame\nquit\n"
check "restart-fires"     "(gameState) (RAM) = 0x00" "$RESTART\npeek $GS\nquit\n"

# --- Input: fire jumps the player one floor (5 -> 4) when settled ---
check "jump-5to4" "(playerFloor) (RAM) = 0x04" \
  "break frame 60\nrun\nstick left fire\nbreak frame 64\nrun\npeek $PF\nquit\n"

# --- Restart lockout: fire during the window must NOT restart ... ---
check "lockout-blocks" "(gameState) (RAM) = 0x01" \
  "break frame 60\nrun\npoke $GS 0x01\npoke $RL 0x78\nstick left fire\nbreak frame 90\nrun\npeek $GS\nquit\n"
# --- ... but a fresh press after it expires DOES restart ---
check "lockout-expires" "(gameState) (RAM) = 0x00" \
  "break frame 60\nrun\npoke $GS 0x01\npoke $RL 5\nbreak frame 70\nrun\nstick left fire\nbreak frame 73\nrun\npeek $GS\nquit\n"

# --- Overscan margin: per-frame work stays under TIM64T (INTIM > 0 at WaitOverscan) ---
check "overscan-margin" "(INTIM) (RIOT) = 0x04" \
  "break frame 60\nrun\nbreak $WO\nrun\npeek 0x284\nquit\n"

# --- Game-over text cycle.  Digit0+0 low byte = leftmost glyph for the phase.
#     3 phases of 80 frames: GAMEOVER (0-79), last-score "__nnnn" (80-159), HI (160-239).
#     (poke goCnt to a phase; overscan increments it then rebuilds the pointers.) ---
GOCYC="break frame 60\nrun\npoke $GS 0x01"
check "go-cycle GAMEOVER @40" "(Digit0) (RAM) = $GLYPH_GO" \
  "$GOCYC\npoke $GC 40\nbreak frame 61\nrun\npeek $D0\nquit\n"
check "go-cycle SCORE @100" "(Digit0) (RAM) = $GLYPH_SCORE" \
  "$GOCYC\npoke $GC 100\nbreak frame 61\nrun\npeek $D0\nquit\n"
check "go-cycle HI @180" "(Digit0) (RAM) = $GLYPH_HI" \
  "$GOCYC\npoke $GC 180\nbreak frame 61\nrun\npeek $D0\nquit\n"

# --- Collision (CXPPMM): drop an entity onto the player's floor (5) at the
#     player's x (10) so the GRP0/GRP1 sprites overlap, then read the outcome a
#     few frames later (the entity renders the frame after the poke; collision
#     latches that frame, CheckCollision acts on it in the same overscan). ---
ET5=$(off "$(sym entType)" 5); EX5=$(off "$(sym entX)" 5); ES5=$(off "$(sym entSlide)" 5)
SC=$(sym scoreBCD)
check "cone -> +1 score" "(scoreBCD) (RAM) = 0x01" \
  "break frame 60\nrun\npoke $ET5 1\npoke $EX5 10\npoke $ES5 0\nbreak frame 63\nrun\npeek $SC\nquit\n"
check "skull -> game over" "(gameState) (RAM) = 0x01" \
  "break frame 60\nrun\npoke $ET5 2\npoke $EX5 10\npoke $ES5 0\nbreak frame 63\nrun\npeek $GS\nquit\n"
# --- High score: a fatal hit while the run (0x34) beats the stored hi (0x00)
#     copies the score into hiScore on death ---
check "hi-score on death" "(hiScore) (RAM) = 0x34" \
  "break frame 60\nrun\npoke $SC 0x34\npoke $ET5 2\npoke $EX5 10\npoke $ES5 0\nbreak frame 63\nrun\npeek $(sym hiScore)\nquit\n"

# --- Fall-through: a gap in the fall window under a settled player drops them
#     one floor.  Force the player onto floor 4 (settled: playerY = 4*30+6 = 126)
#     and put a gap on floor 4 inside [FALL_LO..FALL_HI]; expect floor 5. ---
GX4=$(off "$(sym gapX)" 4); PY=$(sym playerY)
check "gap fall 4->5" "(playerFloor) (RAM) = 0x05" \
  "break frame 60\nrun\npoke $PF 4\npoke $PY 126\npoke $GX4 17\nbreak frame 62\nrun\npeek $PF\nquit\n"

echo
echo "------------------------------------"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
