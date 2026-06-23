;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; UP 1 WAY - Atari 2600 port (4K cart)
;
; Milestone 3 (+ edge-to-edge positioning rework):
;   - 6 platform bands (playfield, COLUPF swaps).
;   - Player (GRP0) drawn on its current floor band (jump-up input).
;   - Gaps are Missile 0, repositioned per band, coloured the
;     background so they cut a hole through the platform.
;   - Player falls one tier when a gap scrolls under it.
;
; Horizontal positioning (gaps / enemy) uses the cycle-74 HMOVE
; technique (after examples/hmove74.asm, by Omegamatrix):
;   - In overscan a "quickPos" byte is precomputed per object
;     (= HMOVE fine nibble | jump-table delay count).
;   - In the kernel the object is positioned in ONE scanline: a
;     short delay loop + an indirect jump into a RESxx strobe table
;     that ends with `sta HMOVE` at cycle ~74. The cycle-74 HMOVE
;     positions cleanly edge-to-edge (incl. x=0, strobe in HBLANK)
;     and hides the HMOVE "comb" in the next line's HBLANK.
;   The static player is positioned once at init with the plain
;   divide-by-15 routine (off-screen, timing not critical).
;
; Timing:
;   VSYNC      3   (VERTICAL_SYNC)
;   VBLANK    36   (WSYNC loop)
;   visible  192   (HUD 12 + 6 bands * 30, all WSYNC-exact)
;   overscan ~30   (TIM64T timer; input + world update + precompute)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	processor 6502
	include "vcs.h"
	include "macro.h"

;-------------------------------------------------------------
; Constants
;-------------------------------------------------------------
COL_BG       = $0E      ; light grey background
COL_GREEN    = $C8      ; platform top (green)
COL_GREY     = $06      ; platform underside (dark grey)
COL_PLAYER   = $02      ; player sprite (dark grey)

PLAYER_X     = 10       ; fixed horizontal position of the player
PREST_OFF    = 7        ; player rest top = floor*30 + 7 (band-local sprite top)
PLERP        = 3        ; player vertical glide speed (px/frame toward restY)

HUD_LINES    = 12
NUM_BANDS    = 6
SPRITE_H     = 8        ; sprite data rows. band = setbg 1 + gap pos 2 + entity
                        ;   pos 2 + sprite 14 (6 body rows x2 + 2 blank foot) +
                        ;   green 5 + grey 6 = 30. No dedicated air pad: the
                        ;   positioning lines above already show as background
                        ;   (gap + sprites are off there) and double as the air.
BAND_GREEN   = 5
BAND_GREY    = 6

GAP_WIDTH    = 8        ; missile gap width (NUSIZ0 = $30)
GAP_WRAP     = 159      ; respawn x at the right edge (cycle-74 reaches 0..159).
                        ; Gaps always re-enter here (slide in from the edge); the
                        ; per-game variety comes from the randomised START layout.
GAP_MIN_SEP  = 24       ; min x-distance between adjacent floors' start gaps, so
                        ; holes never stack (= drop the player straight through)
FALL_LO      = 14       ; gap-under-player window [FALL_LO..FALL_HI], centred on
FALL_HI      = 18       ;   ~15 (measured: gap fully under the player at gapX~15)

; entities (GRP1): one per platform, scroll right-to-left
ENT_CONE     = 1        ; gold collectible (+1 score)
ENT_SKULL    = 2        ; red hazard
COL_CONE     = $2C      ; gold / yellow
COL_SKULL    = $46      ; red
ENT_WRAP     = 152      ; respawn x. Kept <=152 so the 8px GRP1 object never
                        ; reaches the wrap zone (153-159): an object there would
                        ; mod-160 wrap part of the sprite to the LEFT edge,
                        ; flashing the freshly-rerolled type at pixel 0.
ENT_DELAY_MIN  = 32     ; off-screen wait before an entity re-enters:
ENT_DELAY_MASK = $7f    ;   ENT_DELAY_MIN + (rng & MASK) = 32..159 frames
GAP_SPAWN_CLEAR = 145   ; don't spawn an entity while this floor's gap is >= here
ENT_DEFER      = 16     ;   (it would overlap the spawn x); recheck after this many frames

; Scroll speed in 1/32-px fixed point. Per-frame step = (scrollFrac + scrollSpeed)
; >> 5 whole pixels; the low 5 bits carry as the fraction. Keep SPEED_MAX <= 224
; so scrollFrac (<=31) + scrollSpeed never overflows 8 bits.
SPEED_BASE   = 32       ; base speed (= 1.0 px/frame)
SPEED_INC    = 2        ; per cone (= +0.125 px/frame; ~24 cones to top speed)
SPEED_MAX    = 96       ; cap (= 4.0 px/frame; <= the fall window so falls hold)

; Player run-cycle animation. The frame swaps every animTimer frames, and the
; interval shortens with scroll speed: interval = ANIM_BASE - (scrollSpeed >> 3).
; (scrollSpeed 32..128 -> interval 18..6 frames; keep ANIM_BASE > SPEED_MAX>>3.)
ANIM_BASE    = 22

COL_GAMEOVER = $42      ; red background tint while game over

; HUD score (48-pixel 6-digit method, after examples/6-digit-score.asm)
THREE_COPIES = %011     ; NUSIZ: 3 close copies (P0 + P1 interleaved = 6 digits)
SCORE_COL    = $00      ; black digits on the grey background
SCORE_SLEEP  = 36       ; positions the score block (RESP0/RESP1 timing)
PLAYER_SLEEP = 23       ; re-strobes the player P0 near PLAYER_X after the HUD

; Sound effects (TIA channel 0). A frame-timed engine plays one SFX at a time:
; sfxId picks the sound, sfxTimer counts its remaining frames (see UpdateSound).
SFX_JUMP     = 1        ; rising tone
SFX_DROP     = 2        ; falling tone
SFX_CONE     = 3        ; two-note coin pickup
SFX_DEATH    = 4        ; two white-noise bursts
JUMP_DUR     = 12
DROP_DUR     = 12
CONE_DUR     = 16
DEATH_DUR    = 20
SFX_TONE     = $04      ; pure-tone waveform (AUDC0)
SFX_NOISE    = $08      ; white-noise waveform (AUDC0)
SFX_VOL      = $0A      ; SFX volume (AUDV0, 0-15)

	MAC TRIGGER_SFX         ; {1} = SFX id, {2} = duration in frames
	lda #{1}
	sta sfxId
	lda #{2}
	sta sfxTimer
	ENDM

;-------------------------------------------------------------
; RAM
;-------------------------------------------------------------
	SEG.U vars
	org $80

playerFloor     ds 1    ; 0 = top tier .. 5 = bottom tier (logical, instant)
playerBandCount ds 1    ; bandCount value at which to draw the player
playerY         ds 1    ; visual top scanline of the player (band-region rel.);
                        ;   lerps toward restY = playerFloor*30+7 (jump/fall glide)
btnPrev         ds 1    ; fire button state last frame (edge detect)
bandCount       ds 1    ; bands remaining in the visible kernel
curFloor        ds 1    ; floor index of the band being drawn
tempOne         ds 1    ; scratch for the fast divide in CalcQuickPos
tempFloor       ds 1    ; scratch floor index across CalcQuickPos
sprPtr          ds 2    ; pointer to current band's sprite data
posJmp          ds 2    ; indirect pointer into the missile strobe table
gapX            ds 6    ; per-floor gap x position (floor 5 unused/no gap)
gapQuick        ds 6    ; per-floor precomputed quickPos (HMM0 fine | delay count)
posJmpLo        ds 6    ; per-floor precomputed strobe-table entry (low byte)
entType         ds 6    ; per-floor entity: 0 none/hidden, 1 cone, 2 skull
entX            ds 6    ; per-floor entity x position
entDelay        ds 6    ; per-floor frames left to wait off-screen before respawn
scrollSpeed     ds 1    ; fractional scroll speed (ramps with score)
scrollFrac      ds 1    ; fixed-point fractional accumulator
scrollStep      ds 1    ; whole pixels to scroll this frame
entQuick        ds 6    ; per-floor precomputed quickPos for the entity (GRP1)
entJmpLo        ds 6    ; per-floor precomputed strobe-table entry (low byte)
entPtr          ds 2    ; pointer to the current band's entity sprite
rng             ds 1    ; PRNG state (LFSR)
frameCnt        ds 1    ; free-running frame counter (never reset; RNG reseed)
sfxId           ds 1    ; sound effect currently playing (0 = none)
sfxTimer        ds 1    ; frames left in the current sound effect
gameState       ds 1    ; 0 = playing, 1 = game over
scoreBCD        ds 3    ; BCD score (low 4 digits shown)
hiScore         ds 2    ; 4-digit BCD high score (persists across games)
goCnt           ds 1    ; game-over text cycle: 0-119 GAMEOVER, 120-239 HInnnn
animFrame       ds 1    ; player run-cycle frame (0 or 1)
animTimer       ds 1    ; frames left until the next player-frame swap
entSlide        ds 6    ; per-floor edge-slide state: 0 = normal; 1..7 = sliding
                        ;   OUT the LEFT edge (asl amount); $80|N = sliding IN
                        ;   the RIGHT edge (asl amount N, reflected via REFP1)
entDrawLo       ds 6    ; per-floor resolved entity sprite low byte (base or shift)
entRefp         ds 6    ; per-floor REFP1 value ($08 while sliding in, else $00)
sprPtrLoTab     ds 6    ; per-band player-sprite pointer low byte (free-Y draw);
                        ;   = <PlayerBuf + offset, precomputed each frame from playerY
Digit0          ds 12   ; 6 font pointers (Digit0..Digit5) for the score kernel
loopCnt         ds 1    ; scanline counter inside DrawDigits

;-------------------------------------------------------------
; ROM
;-------------------------------------------------------------
	SEG code
	org $f000

Reset
	CLEAN_START             ; zeros all RAM (hiScore starts at 0)

	; --- one-time setup (survives a soft restart) ---
	; Solid, full-width playfield (held for the whole program)
	lda #$F0
	sta PF0
	lda #$FF
	sta PF1
	sta PF2
	lda #0
	sta CTRLPF              ; players/missiles draw over the playfield

	; Missile 0 is GAP_WIDTH wide (player stays normal width)
	lda #$30
	sta NUSIZ0

	; Default every motion register to $80, the cycle-74 HMOVE "no motion"
	; value: the per-band cycle-74 HMOVEs re-apply ALL HMxx, and $00 there
	; is NOT zero motion (it would walk the object); $80 (NO_MO_74) holds
	; non-targeted objects still. The player P0 is (re)placed each frame in
	; the HUD transition; gaps/entities are placed per band.
	sta HMCLR
	lda #$80
	sta HMP0
	sta HMM0
	sta HMP1

	lda #1
	sta rng                 ; PRNG seed (set once; advances across games)

	lda #0
	sta AUDV0               ; silence both audio channels at boot
	sta AUDV1

;-------------------------------------------------------------
; NewGame - (re)start a round. Reached from Reset and from a game-over
; restart. Resets all gameplay state but NOT hiScore (or rng).
;-------------------------------------------------------------
NewGame
	lda #COL_BG
	sta COLUBK              ; clear any game-over red tint

	lda #5
	sta playerFloor         ; player starts on the bottom tier
	lda #5*30+PREST_OFF     ; visual Y settled on floor 5 (157)
	sta playerY
	lda #0
	sta btnPrev
	sta gameState
	sta goCnt
	sta sfxTimer            ; stop any leftover sound (e.g. the death sting)
	sta scoreBCD+0
	sta scoreBCD+1
	sta scoreBCD+2
	sta scrollFrac
	sta animFrame           ; start on run-cycle frame 0
	lda #ANIM_BASE
	sta animTimer
	lda #SPEED_BASE
	sta scrollSpeed         ; start each game at base speed (1 px/frame)

	; (gap layout is randomised below, after the PRNG is reseeded)

	; Reseed the PRNG from the free-running frame counter (mixed with whatever
	; state carried over), so each restart differs -- the human-variable delay
	; before pressing fire makes frameCnt effectively random. Keep it non-zero
	; (an all-zero LFSR is a dead state).
	lda rng
	eor frameCnt
	bne .seedOk
	lda #1
.seedOk
	sta rng

	; Randomise the gap (slot) layout per game. Each floor gets a fully random x;
	; re-roll any that lands within GAP_MIN_SEP of the floor below so holes never
	; stack (which would drop the player straight through) -- but the result is
	; non-monotonic (no rigid diagonal). Candidates stay in 16..143 (away from the
	; 0/159 wrap zone, so the same separation holds as they scroll). Floor 5: none.
	ldx #4
.ngGapFloor
	ldy #8                  ; re-roll attempt cap (collisions are rare)
.ngGapRoll
	jsr Rng                 ; (Rng preserves X and Y)
	and #$7F
	clc
	adc #16                 ; candidate 16..143
	sta tempOne
	cpx #4
	beq .ngGapOk            ; first floor placed: nothing below to clash with
	sec
	sbc gapX+1,x            ; A = candidate - gap on the floor below
	bcs .ngGapAbs
	eor #$FF
	clc
	adc #1                  ; A = |difference|
.ngGapAbs
	cmp #GAP_MIN_SEP
	bcs .ngGapOk            ; far enough from the floor below -> accept
	dey
	bne .ngGapRoll          ; too close -> re-roll (capped)
.ngGapOk
	lda tempOne
	sta gapX,x
	dex
	bpl .ngGapFloor
	lda #0
	sta gapX+5

	; Start with EMPTY platforms: every entity begins hidden and slides in from
	; the right edge (via the normal respawn path, which rolls a random type and
	; clears gaps). Each gets a RANDOM first-spawn delay so they don't all enter
	; evenly spaced (which read as a rigid diagonal). entX is set on spawn.
	ldx #5
.ngEnt
	lda #0
	sta entType,x           ; hidden -> .entWaiting spawns it (slide-in)
	sta entSlide,x
	sta entRefp,x
	lda #<ZeroSprite
	sta entDrawLo,x
	jsr Rng                 ; random first-spawn delay (Rng preserves X)
	and #$3F
	clc
	adc #8                  ; 8..71 frames -> entities enter at varied times
	sta entDelay,x
	dex
	bpl .ngEnt

	jsr GetDigitPtrs        ; seed digit pointers for the first HUD

;-------------------------------------------------------------
; Main frame loop
;-------------------------------------------------------------
NextFrame
	lda #2
	sta VBLANK
	VERTICAL_SYNC           ; 3 vsync lines (leaves A=0)
	sta CXCLR               ; clear collision latches for this frame

	; --- position the score sprites (P0+P1, 3 copies each = 6 digits) ---
	; (uses 2 of the 36 VBLANK scanlines; the rest are the WSYNC loop below)
	lda #THREE_COPIES
	sta NUSIZ0
	sta NUSIZ1
	lda #SCORE_COL
	sta COLUP0
	sta COLUP1
	sta WSYNC               ; vblank line 1
	SLEEP SCORE_SLEEP
	sta RESP0               ; coarse-position P0 and P1 together
	sta RESP1
	sta HMCLR               ; clear stray motion (player left HMP0=$80)
	lda #$10
	sta HMP1                ; nudge P1 so its copies interleave with P0's
	sta WSYNC               ; vblank line 2
	sta HMOVE
	SLEEP 24                ; settle time after HMOVE before HMCLR
	sta HMCLR
	lda #1
	sta VDELP0              ; vertical delay: enables the 6-digit retrigger
	sta VDELP1

	; --- per-band player-sprite pointer, computed in VBLANK's idle cycles ---
	; playerY was finalised by the previous frame's overscan, and the value feeds
	; THIS frame's band kernel (right after VBLANK), so the ordering is correct.
	; Doing it here keeps overscan under its TIM64T budget on glide/fall frames.
	; offset = (band+1)*30 - playerY; 0..41 -> body lands in band, else 0 (blank).
	ldx #33                 ; remaining VBLANK lines (2 + 33 = 35; one line was
	                        ; moved to the kernel's closing WSYNC so the bottom
	                        ; band line renders fully before overscan blanks it)
	ldy #5                  ; band index 5..0 (first 6 loop lines do the precompute)
VBlankLoop
	sta WSYNC
	cpy #6
	bcs .vbSkipPsp          ; Y wrapped past 0 -> precompute done
	lda BandStartTab+1,y    ; (band+1)*30 = next band's start scanline
	sec
	sbc playerY             ; offset
	bcc .vbPspZero          ; negative -> blank
	cmp #42
	bcc .vbPspStore         ; 0..41 (0 = base/zeros, fine)
.vbPspZero
	lda #0
.vbPspStore
	sta sprPtrLoTab,y
	dey
.vbSkipPsp
	dex
	bne VBlankLoop

	lda #0
	sta VBLANK              ; display on

;-------------------------------------------------------------
; Visible kernel (192 lines = HUD 12 + 6 bands * 30)
;-------------------------------------------------------------
	; --- HUD region: 6-digit score (12 WSYNC-exact lines) ---
	lda #COL_BG
	sta COLUPF              ; HUD line 0: playfield invisible behind the score (set
	                        ; first, before the latch flush, so the bg is solid)
	lda #0
	sta REFP1               ; clear any slide-in reflect so score digits (GRP1) aren't mirrored
	; Flush both VDELP old/new latches (VDELP0/1 are still 1 here). The score is
	; double-buffered, so its first displayed row uses the OLD latch - which still
	; holds the previous frame's last band GRP0 write. Without this, a mid-glide
	; player body row bleeds into the score's leading blank digits.
	sta GRP0
	sta GRP1
	sta GRP0
	sta GRP1
	jsr DrawDigits          ; HUD lines 1-9 (DrawDigits ends on a WSYNC)
	; HUD line 10: restore game sprite state
	lda #0
	sta VDELP0
	sta VDELP1
	lda #$30
	sta NUSIZ1              ; entity single copy + gap missile M1 8px wide
	sta NUSIZ0              ; player single copy + M0 8px (M0 unused)
	sta WSYNC
	; HUD line 11: re-place the player P0 near PLAYER_X
	SLEEP PLAYER_SLEEP
	sta RESP0
	lda #$80
	sta HMP0                ; cycle-74 no-motion so band HMOVEs hold it
	sta WSYNC

	; Six platform bands
	lda #NUM_BANDS
	sta bandCount
	lda animFrame           ; run-cycle frame 0/1 selects the player buffer page
	clc
	adc #>PlayerBuf0        ; PlayerBuf0/1 are one page apart, same low-byte layout
	sta sprPtr+1            ; constant for the whole frame (animFrame is fixed here)
	lda #>ZeroSprite        ; entity ptr hi byte is constant (all art in page f5)
	sta entPtr+1
	lda #COL_PLAYER
	sta COLUP0              ; player colour is constant across bands (hoisted out)
	lda #0
	sta curFloor            ; floor index counts up 0..5 (top band first)
BandLoop
	; --- setbg line: air bg + this band's player pointer + line-0 row ---
	; curFloor is a running counter (no subtract), so the player pointer loads
	; early enough to write GRP0 for band-local line 0 before the player's x
	; (pixel 10 ~ cycle 26). This removes the 1-line air-gap notch.
	sta WSYNC
	lda #COL_BG
	sta COLUPF              ; air bg, set first (well inside HBLANK)
	ldx curFloor
	lda sprPtrLoTab,x       ; offset into the player buffer (or 0 = blank band)
	sta sprPtr              ; (sprPtr+1 already = the frame's buffer page)
	ldy #0
	lda (sprPtr),y          ; player band-local line 0 ...
	sta GRP0                ; ... GRP0 written ~cycle 25, before pixel 10
	lda #0
	sta ENAM1               ; gap missile off until the platform rows below
	sta GRP1

	; position the gap missile M1 (cycle-74; the pad also draws the player on
	; band-local line 1 via a preloaded byte, keeping HMOVE exactly on cycle 74).
	ldy curFloor
	jsr Pos74M0
	lda #$80
	sta HMM1                ; restore no-motion so Pos74P1's HMOVE won't move M1
	; player on band-local line 2 (HBLANK, before the player's x)
	ldy #2
	lda (sprPtr),y
	sta GRP0
	; position the entity sprite P1 (cycle-74; its pad draws the player on line 3)
	ldy curFloor
	jsr Pos74P1
	lda #$80
	sta HMP1
	; player on band-local line 4 (all 5 positioning lines now draw the player, so
	; the glide has no stale-row gap at a band top)
	ldy #4
	lda (sprPtr),y
	sta GRP0
	; --- entity select for this floor (line 4 has the spare cycles) ---
	; colour by type; pointer = base or pre-shifted slide frame (entDrawLo);
	; REFP1 reflects the bitmap while sliding in (entRefp, else 0).
	ldy curFloor
	ldx entType,y
	lda EntColorTable,x
	sta COLUP1
	lda entDrawLo,y
	sta entPtr              ; entPtr+1 already = >ZeroSprite (set before the loop)
	lda entRefp,y
	sta REFP1

	; --- content region (band-local 5..29) ---
	; STAGE 1a: player free-Y on every line; entity (GRP1) drawn 2x in its fixed
	; band rows (7..18); gap missile still OFF. Air 5..18, green 19..23, grey 24..29.

	; air rows 5..6 (player only; COLUPF still COL_BG from setbg)
	ldy #5
	sta WSYNC
	lda (sprPtr),y
	sta GRP0
	iny
	sta WSYNC
	lda (sprPtr),y
	sta GRP0
	iny                     ; y = 7

	; entity region 7..18: entity rows 7..2 each on TWO lines (2x tall, no vertical
	; stretch on the 2600), player free-Y drawn on every line. Both reads are
	; (zp),Y, so the entity row tracks in X and the player line in tempOne; the
	; entity is loaded first since it may sit at x=0 (sliding out the left edge).
	lda #7
	sta tempOne             ; player band-local line (7..18)
	ldx #7                  ; entity row 7..2
.entRegion
	sta WSYNC               ; 1st line of the pair
	txa
	tay
	lda (entPtr),y          ; entity row (Y = entity row)
	sta GRP1
	ldy tempOne
	lda (sprPtr),y          ; player row (free-Y)
	sta GRP0
	inc tempOne
	sta WSYNC               ; 2nd line of the pair (GRP1 holds -> 2x tall)
	ldy tempOne
	lda (sprPtr),y          ; player row (free-Y)
	sta GRP0
	inc tempOne
	dex
	cpx #1
	bne .entRegion          ; rows 7..2 -> band-local lines 7..18

	; preload the gap-enable byte while still on line 18 (the entity's last line),
	; so line 19's HBLANK can enable + colour the gap missile BEFORE pixel 0.
	; (Doing it late clipped the top row of a left-edge gap.)
	ldx curFloor
	lda GapOnTable,x
	tax                     ; X = ENAM1 enable byte for this floor

	; platform line 19 (green): entity off, gap enabled+coloured, green, player.
	ldy #19
	sta WSYNC
	lda #0
	sta GRP1                ; entity off (cycle 5)
	stx ENAM1               ; enable gap missile (cycle 8, before pixel 0)
	lda #COL_BG
	sta COLUP1              ; gap colour = background (cycle 13, before pixel 0)
	lda #COL_GREEN
	sta COLUPF              ; green platform (cycle 18, before pixel 0)
	lda (sprPtr),y
	sta GRP0                ; player free-Y (cycle ~26; rarely on a platform line)
	iny                     ; y = 20

	; platform rows 20..29: player free-Y + green(20..23)/grey(24..29) colour
.platform
	sta WSYNC
	cpy #24
	bcc .pfGrn
	lda #COL_GREY
	bne .pfSet              ; COL_GREY != 0 -> always taken
.pfGrn
	lda #COL_GREEN
.pfSet
	sta COLUPF
	lda (sprPtr),y
	sta GRP0
	iny
	cpy #30
	bne .platform

	inc curFloor            ; advance to the next band's floor index
	dec bandCount
	beq .bandsDone
	jmp BandLoop            ; (band body > 128 bytes, so jmp not bne)
.bandsDone
	sta WSYNC               ; complete the last band's final visible line before
	                        ; overscan blanks it (compensated by one fewer VBLANK line)

	; turn the gap missile off before leaving the visible area
	lda #0
	sta ENAM1

;-------------------------------------------------------------
; Overscan (~30 lines via timer) - game logic + positioning precompute
;-------------------------------------------------------------
	lda #2
	sta VBLANK
	lda #35
	sta TIM64T

	inc frameCnt            ; free-running frame timer (all states) for RNG reseed

	lda gameState
	bne .gsFrozen
	; CheckCollision must run BEFORE input/update: CXPPMM reflects the
	; frame just rendered, where playerFloor still matches.
	jsr CheckCollision
	lda gameState
	bne .gsAfter            ; just died this frame -> skip further updates
	jsr ReadInput
	jsr UpdateWorld
	jsr AnimatePlayer       ; advance the run cycle (frozen while game over)
	jsr UpdatePlayerY       ; glide the player's visual Y toward its floor
	jmp .gsAfter
.gsFrozen
	jsr CheckRestart        ; world frozen; fresh fire press restarts
.gsAfter
	jsr UpdateSound         ; advance SFX every frame (incl. the game-over freeze)
	; game-over text cycle: 240-frame period (120 GAMEOVER + 120 HInnnn)
	inc goCnt
	lda goCnt
	cmp #240
	bcc .goCntOk
	lda #0
	sta goCnt
.goCntOk

	; Precompute each gap's quickPos + strobe-table entry (in overscan),
	; so the visible kernel positions in one fixed-time scanline.
	ldx #5
.precomp
	; gap (missile 0)
	lda gapX,x
	stx tempFloor
	jsr CalcQuickPos        ; A = quickPos (clobbers Y, tempOne)
	ldx tempFloor
	sta gapQuick,x
	and #$0F                ; low nibble = delay count = jump-table index
	tay
	lda JumpTabM0,y
	sta posJmpLo,x
	; entity (GRP1) - PosTblP1 mirrors PosTblM0, so JumpTabM0 low bytes apply
	lda entX,x
	stx tempFloor
	jsr CalcQuickPos
	ldx tempFloor
	sta entQuick,x
	and #$0F
	tay
	lda JumpTabM0,y
	sta entJmpLo,x
	; resolve this floor's entity sprite low byte + REFP1. entSlide 0 = base
	; sprite, no reflect. Otherwise shift N = entSlide & $7F selects the slide
	; frame (SlideBaseLo[type] + (N-1)*8); the $80 flag (slide-in) sets REFP1.
	lda entSlide,x
	beq .pcBase
	and #$7F                ; N = shift amount (strip the slide-in flag)
	sec
	sbc #1                  ; N-1 (0..6)
	asl
	asl
	asl                     ; * 8 (rows per shift frame)
	ldy entType,x
	clc
	adc SlideBaseLo,y
	sta entDrawLo,x
	lda entSlide,x
	and #$80                ; slide-in flag -> REFP1 bit3 ($80 >> 4 = $08)
	lsr
	lsr
	lsr
	lsr
	sta entRefp,x
	jmp .pcSprDone
.pcBase
	ldy entType,x
	lda EntSprLo,y
	sta entDrawLo,x
	lda #0
	sta entRefp,x
.pcSprDone
	dex
	bpl .precomp

	; playerBandCount = NUM_BANDS - playerFloor (for next frame's kernel)
	lda #NUM_BANDS
	sec
	sbc playerFloor
	sta playerBandCount

	; (the per-band player-sprite pointer is now computed in VBLANK's idle cycles,
	; keeping overscan under its TIM64T budget on glide/fall frames.)

	; build the score's digit pointers for next frame's HUD
	jsr GetDigitPtrs

WaitOverscan
	lda INTIM
	bne WaitOverscan
	sta WSYNC

	jmp NextFrame

;-------------------------------------------------------------
; Pos74M0 - position the gap Missile 1 at gap[curFloor] in one scanline.
;   IN: Y = curFloor. Uses precomputed gapQuick / posJmpLo. (The gap moved from
;   M0 to M1 so its background colour COLUP1 no longer collides with the gliding
;   player's COLUP0; PosTblM0 strobes RESM1.)
;   Cycle-74 HMOVE: clean edge-to-edge positioning, no comb.
;-------------------------------------------------------------
Pos74M0
	lda gapQuick,y
	sta HMM1                ; high nibble = fine motion (low nibble ignored)
	and #$0F
	tax                     ; X = delay count
	lda posJmpLo,y
	sta posJmp
	lda #>PosTblM0
	sta posJmp+1
	ldy #1                  ; band-local line 1
	lda (sprPtr),y          ; preload the player row (A survives the WSYNC strobe)
	sta WSYNC
	; 9 cycles of dead time (HMOVE stays @ cycle 74); the first store draws the
	; player on this cycle-74 line so the glide has no stale-row gap at line 1.
	sta GRP0                ; 3  player row (A = preloaded byte)
	nop                     ; 2
	nop                     ; 2
	nop                     ; 2
.wait74
	dex
	bpl .wait74
	jmp (posJmp)            ; into PosTblM0; strobes RESM1, HMOVE @ ~74, rts

;-------------------------------------------------------------
; Pos74P1 - position the entity sprite (GRP1) at ent[curFloor].
;   IN: Y = curFloor. Uses entQuick / entJmpLo. Same technique as
;   Pos74M0, but strobes RESP1 (PosTblP1) and uses HMP1.
;-------------------------------------------------------------
Pos74P1
	lda entQuick,y
	sta HMP1
	and #$0F
	tax
	lda entJmpLo,y
	sta posJmp
	lda #>PosTblP1
	sta posJmp+1
	ldy #3                  ; band-local line 3
	lda (sprPtr),y          ; preload the player row (A survives the WSYNC strobe)
	sta WSYNC
	; 9 cycles of dead time (HMOVE stays @ cycle 74); draw the player on line 3
	sta GRP0                ; 3  player row (A = preloaded byte)
	nop
	nop
	nop
.wait74p
	dex
	bpl .wait74p
	jmp (posJmp)            ; into PosTblP1; strobes RESP1, HMOVE @ ~74, rts

;-------------------------------------------------------------
; Rng - 8-bit LFSR. Advances and returns the new value in A.
;-------------------------------------------------------------
Rng
	lda rng
	lsr
	bcc .rngNoFb
	eor #$B4
.rngNoFb
	sta rng
	rts

;-------------------------------------------------------------
; ReadInput - one-button jump-up (rising edge of fire button)
;-------------------------------------------------------------
ReadInput
	ldx #0                  ; assume not pressed
	lda INPT4
	bmi .store              ; bit7 set => not pressed
	ldx #1                  ; pressed
	lda btnPrev
	bne .store              ; held => no new press
	lda playerFloor
	beq .store              ; already at top tier
	; only jump when the player is settled (visual Y == rest), not mid-glide
	ldy playerFloor
	lda BandStartTab,y
	clc
	adc #PREST_OFF
	cmp playerY
	bne .store              ; mid-glide -> ignore the press
	dec playerFloor         ; jump up one tier (logical, instant; Y glides)
	TRIGGER_SFX SFX_JUMP, JUMP_DUR
.store
	stx btnPrev
	rts

;-------------------------------------------------------------
; UpdatePlayerY - glide the visual player Y toward its floor's rest Y by PLERP
;   px/frame (snapping when within PLERP). Drives the jump/fall animation.
;-------------------------------------------------------------
UpdatePlayerY
	ldx playerFloor
	lda BandStartTab,x
	clc
	adc #PREST_OFF          ; A = restY
	sta tempOne
	sec
	sbc playerY             ; restY - playerY
	beq .pyDone             ; settled
	bcc .pyUp               ; restY < playerY -> move up (decrease playerY)
	; restY > playerY: move down. A = diff (positive)
	cmp #PLERP
	bcc .pySnap             ; within one step -> snap
	lda playerY
	clc
	adc #PLERP
	sta playerY
	rts
.pyUp
	eor #$FF
	clc
	adc #1                  ; A = playerY - restY (abs)
	cmp #PLERP
	bcc .pySnap
	lda playerY
	sec
	sbc #PLERP
	sta playerY
	rts
.pySnap
	lda tempOne             ; restY
	sta playerY
.pyDone
	rts

;-------------------------------------------------------------
; AnimatePlayer - tick the run-cycle frame. Swaps frame every animTimer
;   frames; the interval shortens with scroll speed so the player's legs
;   move faster as the world speeds up.
;   interval = ANIM_BASE - (scrollSpeed >> 3)
;-------------------------------------------------------------
AnimatePlayer
	dec animTimer
	bne .apDone
	lda animFrame
	eor #1
	sta animFrame           ; toggle 0 <-> 1
	lda scrollSpeed
	lsr
	lsr
	lsr                     ; scrollSpeed >> 3
	sta animTimer           ; (temp)
	lda #ANIM_BASE
	sec
	sbc animTimer
	sta animTimer           ; reload shortened interval
.apDone
	rts

;-------------------------------------------------------------
; UpdateWorld - scroll gaps left, wrap, and fall-through check
;-------------------------------------------------------------
UpdateWorld
	; advance the PRNG once per frame so respawns stay varied
	jsr Rng

	; Sub-pixel speed: accumulate the fractional speed; the carry is an
	; extra whole pixel this frame, so the scroll step is 1 or 2 px.
	; (scrollSpeed ramps with the score; see CheckCollision.)
	lda scrollFrac
	clc
	adc scrollSpeed         ; accumulate 1/32-px units
	tax                     ; X = total (whole.frac)
	and #$1F
	sta scrollFrac          ; carry the fraction (low 5 bits) to next frame
	txa
	lsr
	lsr
	lsr
	lsr
	lsr                     ; whole pixels this frame = total >> 5
	sta scrollStep

	; Everything below advances by scrollStep in ONE pass (O(1)) rather than a
	; per-pixel loop, so the overscan cost stays flat as the speed ramps -- the
	; per-pixel loop was up to 4x work at top speed and overran the overscan
	; timer (causing the screen to roll, worst on the heavier cone-pickup frame).

	; --- scroll gaps (floors 0..4): gapX -= step, wrap <=0 back to GAP_WRAP ---
	ldx #4
.gapLoop
	lda gapX,x
	sec
	sbc scrollStep
	bcc .gapWrap            ; underflowed past 0 -> wrap in from the right edge
	bne .gapStore           ; still > 0
.gapWrap                    ; A is 0 or the negative remainder; +GAP_WRAP re-enters
	clc
	adc #GAP_WRAP
.gapStore
	sta gapX,x
	dex
	bpl .gapLoop

	; --- entities: advance position / slide / respawn wait, each by scrollStep ---
	ldx #5
.entLoop
	lda entType,x
	beq .entWaiting         ; hidden -> count down the respawn delay
	lda entSlide,x
	beq .entScroll          ; 0 -> normal scroll
	bmi .entSlideIn         ; $80|N -> sliding IN from the right edge
	; 1..7 -> sliding OUT the left edge: grow the shift, hide once fully off
	clc
	adc scrollStep
	cmp #8
	bcc .entSlideStore      ; 1..7 still partly on-screen
	lda #0
	sta entType,x           ; fully off the left edge -> hide + arm respawn
	sta entSlide,x
	jsr SetRespawnDelay
	jmp .entNext
.entSlideIn
	sec
	sbc scrollStep          ; $80|N -> shrink N toward $80 (grow in from the right)
	cmp #$81
	bcs .entSlideStore      ; still >= $81 -> entering
	lda #0
	sta entSlide,x          ; reached $80 (or past) -> fully in, normal scroll
	jmp .entNext
.entSlideStore
	sta entSlide,x
	jmp .entNext
.entScroll
	lda entX,x
	sec
	sbc scrollStep
	bcc .entEdge            ; passed the left edge
	beq .entEdge            ; reached x = 0
	sta entX,x
	jmp .entNext
.entEdge
	lda #0
	sta entX,x              ; clamp at the left edge
	lda #1
	sta entSlide,x          ; begin slide-out (kernel draws asl x1 at x=0)
	jmp .entNext
.entWaiting
	lda entDelay,x
	sec
	sbc scrollStep          ; advance the wait by this frame's step (speed-linked)
	bcc .entSpawn
	beq .entSpawn
	sta entDelay,x
	jmp .entNext
.entSpawn
	; delay elapsed -> respawn, but not over this floor's gap. If the gap is in
	; the spawn zone, wait a little and recheck (same speed keeps them apart).
	lda gapX,x
	cmp #GAP_SPAWN_CLEAR
	bcc .doSpawn
	lda #ENT_DEFER
	sta entDelay,x
	jmp .entNext
.doSpawn
	jsr Rng
	and #3
	tay
	lda EntTypeRoll,y
	sta entType,x
	lda #ENT_WRAP
	sta entX,x
	lda #$80|7              ; begin sliding IN from the right edge (reflected)
	sta entSlide,x
.entNext
	dex
	bpl .entLoop

	; --- fall-through (once per frame): gap under the player? ---
	lda playerFloor
	cmp #5
	bcs .noFall             ; bottom tier is solid/safe
	tax
	; only start a fall when the player is settled (not mid-glide)
	lda BandStartTab,x
	clc
	adc #PREST_OFF
	cmp playerY
	bne .noFall
	lda gapX,x
	cmp #FALL_HI+1
	bcs .noFall             ; gap is right of the player
	cmp #FALL_LO
	bcc .noFall             ; gap is left of the player
	inc playerFloor         ; fall down one tier (logical, instant; Y glides)
	TRIGGER_SFX SFX_DROP, DROP_DUR
.noFall
	rts

;-------------------------------------------------------------
; SetRespawnDelay - arm entDelay[X] with a randomised off-screen wait.
;-------------------------------------------------------------
SetRespawnDelay
	jsr Rng
	and #ENT_DELAY_MASK
	clc
	adc #ENT_DELAY_MIN
	sta entDelay,x
	rts

;-------------------------------------------------------------
; CheckCollision - player vs the entity on the player's floor.
;   cone  -> +1 to the BCD score, entity consumed.
;   skull -> game over (freeze + red background).
;-------------------------------------------------------------
CheckCollision
	lda CXPPMM
	bpl .ccDone             ; bit7 (P0-P1) clear -> player didn't touch an entity
	; player's GRP0 only draws on its own floor, so a P0-P1 hit is the
	; entity on playerFloor. Act on its type.
	ldx playerFloor
	lda entType,x
	beq .ccDone             ; guard: no entity here
	cmp #ENT_SKULL
	beq .ccSkull
	TRIGGER_SFX SFX_CONE, CONE_DUR
	; cone collected: +1 (BCD). GetDigitPtrs shows scoreBCD+2 as the
	; leftmost (most-significant) digits, so the +1 must land on the
	; least-significant byte scoreBCD+0 and carry up toward +2.
	sed
	lda scoreBCD+0
	clc
	adc #1
	sta scoreBCD+0
	lda scoreBCD+1
	adc #0
	sta scoreBCD+1
	lda scoreBCD+2
	adc #0
	sta scoreBCD+2
	cld
	lda #0
	sta entType,x           ; cone consumed
	jsr SetRespawnDelay     ; wait before a new entity enters this floor
	; ramp the scroll speed (sub-pixel speed-up with score)
	lda scrollSpeed
	cmp #SPEED_MAX
	bcs .ccDone             ; already at max
	clc
	adc #SPEED_INC
	sta scrollSpeed
	rts
.ccSkull
	lda #1
	sta gameState
	TRIGGER_SFX SFX_DEATH, DEATH_DUR
	lda #COL_GAMEOVER
	sta COLUBK              ; red tint; NewGame restores COL_BG on restart
	; high score = max(hiScore, score) over the low 4 digits
	lda scoreBCD+1
	cmp hiScore+1
	bcc .ccDone             ; score's high pair < hiScore's
	bne .ccNewHi            ; score's high pair > hiScore's
	lda scoreBCD+0
	cmp hiScore+0
	bcc .ccDone             ; equal high pair, low pair lower
.ccNewHi
	lda scoreBCD+0
	sta hiScore+0
	lda scoreBCD+1
	sta hiScore+1
.ccDone
	rts

;-------------------------------------------------------------
; CheckRestart - during game over, a fresh fire press restarts.
;-------------------------------------------------------------
CheckRestart
	ldx #0
	lda INPT4
	bmi .crStore            ; not pressed
	ldx #1
	lda btnPrev
	bne .crStore            ; held since last frame -> no edge
	jmp NewGame             ; fresh press -> restart (keeps hiScore)
.crStore
	stx btnPrev
	rts

;-------------------------------------------------------------
; CalcQuickPos - A = x (0..159) -> A = quickPos
;   quickPos = (HMOVE fine nibble << 4) | delay count (low nibble).
;   Fast divide-by-15 + tables, from examples/hmove74.asm. Uses Y, tempOne.
;-------------------------------------------------------------
CalcQuickPos
	sta tempOne
	lsr
	adc #4
	lsr
	lsr
	lsr
	adc tempOne
	ror
	lsr
	lsr
	lsr
	tay                     ; Y = x / 15
	lda MultTab,y
	sec
	sbc tempOne
	asl
	asl
	asl
	asl
	clc
	adc DelayTab,y
	rts

;-------------------------------------------------------------
; Tables
;-------------------------------------------------------------
; (GapOnTable / MultTab / DelayTab / player run-cycle frames moved to the gap
;  after PosTblP1 -- the $f000-$f500 code region had no room left.)

; Entity sprite rows (bottom row first), defined as symbols so the base sprites
; AND the left/right slide shift tables (all in page f5, below) generate from the
; SAME source and never drift. Edit these rows to change the cone / skull art.
CONE0 = %00000000
CONE1 = %00000000
CONE2 = %11111111         ; wide base
CONE3 = %01000010
CONE4 = %01111110
CONE5 = %00100100
CONE6 = %00011000
CONE7 = %00011000         ; point (top)
SKULL0 = %00000000
SKULL1 = %00000000
SKULL2 = %00111100
SKULL3 = %01111110
SKULL4 = %11100111         ; eyes
SKULL5 = %10111101
SKULL6 = %01111110
SKULL7 = %00111100         ; top

	MAC CONE_ROWS            ; {1} = left-shift amount (asl); 0 = base art
	.byte (CONE0<<{1})&$FF,(CONE1<<{1})&$FF,(CONE2<<{1})&$FF,(CONE3<<{1})&$FF
	.byte (CONE4<<{1})&$FF,(CONE5<<{1})&$FF,(CONE6<<{1})&$FF,(CONE7<<{1})&$FF
	ENDM
	MAC SKULL_ROWS
	.byte (SKULL0<<{1})&$FF,(SKULL1<<{1})&$FF,(SKULL2<<{1})&$FF,(SKULL3<<{1})&$FF
	.byte (SKULL4<<{1})&$FF,(SKULL5<<{1})&$FF,(SKULL6<<{1})&$FF,(SKULL7<<{1})&$FF
	ENDM
	; (ZeroSprite / ConeSprite / SkullSprite base art + the slide tables all live
	;  together in page f5 -- see the block after JumpTabM0.)

; (Entity lookup tables moved to the gap after PosTblP1 -- the $f000-$f500 code
;  region is full.)

;-------------------------------------------------------------
; Missile-0 cycle-74 strobe table (must stay within one page).
;   Each entry strobes RESM0; the $1C (NOP abs) swallows the next
;   entry's `sta RESM0`, so only the jumped-to strobe executes, then
;   execution falls through to `sta HMOVE` at cycle ~74.
;-------------------------------------------------------------
	org $f500
PosTblM0
pM0_3
	sta RESM1
	.byte $1C
pM0_15
	sta RESM1
	.byte $1C
pM0_30
	sta RESM1
	.byte $1C
pM0_45
	sta RESM1
	.byte $1C
pM0_60
	sta RESM1
	.byte $1C
pM0_75
	sta RESM1
	.byte $1C
pM0_90
	sta RESM1
	.byte $1C
pM0_105
	sta RESM1
	.byte $1C
pM0_120
	sta RESM1
	.byte $1C
pM0_135
	sta RESM1
	.byte $1C
pM0_150
	sta RESM1
	sta HMOVE
	sta WSYNC               ; re-align: the positioning line ends here so the
	rts                     ; band keeps an exact, identical scanline budget

JumpTabM0
	.byte <pM0_3, <pM0_15, <pM0_30, <pM0_45, <pM0_60, <pM0_75
	.byte <pM0_90, <pM0_105, <pM0_120, <pM0_135, <pM0_150

;-------------------------------------------------------------
; ---- Entity sprites + edge-slide shift tables (all page f5) ----
; Base art (shift 0) and the asl 1..7 slide frames live together so a single
; high byte (>ZeroSprite) covers every entity draw. Generated from the CONEn/
; SKULLn row symbols so the slide frames track the art.
ZeroSprite
	.byte 0,0,0,0,0,0,0,0
ConeSprite
	CONE_ROWS 0
SkullSprite
	SKULL_ROWS 0
; Slide frames: each entity's bitmap pre-shifted left (asl) 1..7; the frame for
; shift N lives at <table> + (N-1)*8. Used for BOTH edges: left slide-out draws
; them directly; right slide-in draws them with REFP1=1 (the sprites are
; left/right symmetric, so the reflect is invisible).
ConeSlide
	CONE_ROWS 1
	CONE_ROWS 2
	CONE_ROWS 3
	CONE_ROWS 4
	CONE_ROWS 5
	CONE_ROWS 6
	CONE_ROWS 7
SkullSlide
	SKULL_ROWS 1
	SKULL_ROWS 2
	SKULL_ROWS 3
	SKULL_ROWS 4
	SKULL_ROWS 5
	SKULL_ROWS 6
	SKULL_ROWS 7

;-------------------------------------------------------------
; Player-1 (GRP1) cycle-74 strobe table. Placed at $f600 so its
; entries share the SAME low bytes as PosTblM0 ($f500) -> JumpTabM0
; works for both; Pos74P1 just uses the $f6 high byte.
;-------------------------------------------------------------
	org $f600
PosTblP1
pP1_3
	sta RESP1
	.byte $1C
pP1_15
	sta RESP1
	.byte $1C
pP1_30
	sta RESP1
	.byte $1C
pP1_45
	sta RESP1
	.byte $1C
pP1_60
	sta RESP1
	.byte $1C
pP1_75
	sta RESP1
	.byte $1C
pP1_90
	sta RESP1
	.byte $1C
pP1_105
	sta RESP1
	.byte $1C
pP1_120
	sta RESP1
	.byte $1C
pP1_135
	sta RESP1
	.byte $1C
pP1_150
	sta RESP1
	sta HMOVE
	sta WSYNC
	rts

;-------------------------------------------------------------
; Tables relocated here (the $f000-$f500 code region is full).
;-------------------------------------------------------------
; Entity lookups indexed by entType (0 none, 1 cone, 2 skull)
EntColorTable
	.byte $00, COL_CONE, COL_SKULL
EntSprLo
	.byte <ZeroSprite, <ConeSprite, <SkullSprite
; base low byte of each type's slide-shift table (indexed by entType); the
; sliding sprite = SlideBaseLo[type] + (entSlide-1)*8. Type 0 never slides.
SlideBaseLo
	.byte $00, <ConeSlide, <SkullSlide
; Respawn type roll, indexed by (rng & 3): 50/50 cone / skull
EntTypeRoll
	.byte ENT_CONE, ENT_CONE, ENT_SKULL, ENT_SKULL

; ENAM1 enable byte per floor (bit1 = enable). Floor 5 = no gap.
GapOnTable
	.byte 2,2,2,2,2,0

; quickPos divide tables (from examples/hmove74.asm)
MultTab
	.byte -25,-10,5,20,35,50,65,80,95,110,-21
DelayTab
	.byte 1,2,3,4,5,6,7,8,9,10,0

; (The run-cycle frames now live in the page-aligned PlayerBuf0/PlayerBuf1
;  free-Y buffers near the end of ROM; see PLAYER_FRAME.)

;-------------------------------------------------------------
; FontTable - 8x8 bitmaps for digits 0-9 (page-aligned so each
; digit's 8 bytes never cross a page). From examples/6-digit-score.asm.
;-------------------------------------------------------------
	align $100
FontTable
	.byte $00,$1c,$32,$63,$63,$63,$26,$1c
	.byte $00,$3f,$0c,$0c,$0c,$0c,$1c,$0c
	.byte $00,$7f,$70,$3c,$1e,$07,$63,$3e
	.byte $00,$3e,$63,$03,$1e,$0c,$06,$3f
	.byte $00,$06,$06,$7f,$66,$36,$1e,$0e
	.byte $00,$3e,$63,$03,$03,$7e,$60,$7e
	.byte $00,$3e,$63,$63,$7e,$60,$30,$1e
	.byte $00,$18,$18,$18,$0c,$06,$63,$7f
	.byte $00,$3e,$43,$4f,$3c,$72,$62,$3c
	.byte $00,$3c,$06,$03,$3f,$63,$63,$3e
BlankGlyph
	.byte $00,$00,$00,$00,$00,$00,$00,$00

; "GAMEOVER" packed across 6 glyph slots (8 letters in 48px). User-supplied,
; with each glyph's 8 bytes reversed to the kernel's bottom-row-first order.
GameOverGlyphs
	.byte $00,$79,$cd,$cd,$dd,$c1,$c1,$78
	.byte $00,$b6,$b6,$f6,$b7,$b7,$b6,$e4
	.byte $00,$37,$36,$b6,$f7,$76,$36,$17
	.byte $00,$9c,$36,$36,$b6,$36,$36,$9c
	.byte $00,$23,$73,$db,$db,$db,$db,$db
	.byte $00,$db,$1b,$1e,$db,$1b,$1b,$de

; "H" and "I" for the HInnnn high-score frame (digit-font orientation:
; byte order is bottom row first, top row last; 7px wide).
LetterH
	.byte $00,$63,$63,$63,$7f,$63,$63,$63
LetterI
	.byte $00,$3c,$18,$18,$18,$18,$18,$3c

;-------------------------------------------------------------
; DrawDigits - render the 48x8 score from Digit0..Digit5 pointers.
; Page-aligned so BigLoop's branch stays in-page (exact 76-cycle rows).
; After examples/6-digit-score.asm (Temp -> tempOne, LoopCount -> loopCnt).
;-------------------------------------------------------------
	align $100
DrawDigits
	lda #7
	sta loopCnt
	sta WSYNC
	SLEEP 60
.bigLoop
	ldy loopCnt             ; counts 7..0
	lda (Digit0),y
	sta GRP0
	lda (Digit0+2),y
	sta GRP1
	cmp $00
	cmp $00
	lda (Digit0+4),y
	sta GRP0
	lda (Digit0+10),y
	sta tempOne
	lda (Digit0+8),y
	tax
	lda (Digit0+6),y
	ldy tempOne
	sta GRP1
	stx GRP0
	sty GRP1
	sta GRP0
	dec loopCnt
	bpl .bigLoop
	lda #0
	sta GRP0
	sta GRP1
	sta GRP0
	sta GRP1
	sta WSYNC               ; align: DrawDigits is exactly 9 scanlines
	rts

;-------------------------------------------------------------
; GetDigitPtrs - build the 6 font pointers (Digit0..Digit5) from the
;   3-byte BCD score. Each nibble * 8 = offset into FontTable.
;   (After examples/6-digit-score.asm.) Lives here in the trailing gap to
;   keep the cramped $f000-$f500 code region under the PosTblM0 org.
;-------------------------------------------------------------
GetDigitPtrs
	lda gameState
	bne .goText
	; --- playing: score "__nnnn" (blank leftmost two, low 4 BCD digits) ---
	lda #<BlankGlyph
	sta Digit0+0
	sta Digit0+2
	ldx #4
	ldy #1
.gdpLoop
	lda scoreBCD,y
	and #$f0                ; high nibble * 16
	lsr                     ; -> * 8
	sta Digit0,x
	inx
	inx
	lda scoreBCD,y
	and #$0f                ; low nibble
	asl
	asl
	asl                     ; * 8
	sta Digit0,x
	inx
	inx
	dey
	bpl .gdpLoop
	jmp .setHi
.goText
	; --- game over: alternate "GAMEOVER" and "HInnnn" every 120 frames ---
	lda goCnt
	cmp #120
	bcs .goHi               ; goCnt 120-239 -> HInnnn
	; "GAMEOVER" packed across the 6 glyph slots
	lda #<GameOverGlyphs
	sta Digit0+0
	clc
	adc #8
	sta Digit0+2
	adc #8
	sta Digit0+4
	adc #8
	sta Digit0+6
	adc #8
	sta Digit0+8
	adc #8
	sta Digit0+10
	jmp .setHi
.goHi
	; "HI" + the 4-digit high score
	lda #<LetterH
	sta Digit0+0
	lda #<LetterI
	sta Digit0+2
	ldx #4
	ldy #1
.goHiLoop
	lda hiScore,y
	and #$f0
	lsr
	sta Digit0,x
	inx
	inx
	lda hiScore,y
	and #$0f
	asl
	asl
	asl
	sta Digit0,x
	inx
	inx
	dey
	bpl .goHiLoop
.setHi
	; every glyph lives in the FontTable page, so all hi bytes are the same
	lda #>FontTable
	sta Digit0+1
	sta Digit0+3
	sta Digit0+5
	sta Digit0+7
	sta Digit0+9
	sta Digit0+11
	rts

;-------------------------------------------------------------
; UpdateSound - advance the one-shot SFX on channel 0 (called every frame in
;   all game states, so the death sound keeps playing through the freeze).
;   sfxTimer counts down; AUDC0/AUDF0/AUDV0 are derived from the id + timer.
;-------------------------------------------------------------
UpdateSound
	lda sfxTimer
	bne .usPlay
	rts                     ; idle (already silent)
.usPlay
	dec sfxTimer
	beq .usSilence          ; last frame elapsed -> turn the channel off
	lda sfxId
	cmp #SFX_JUMP
	beq .usJump
	cmp #SFX_DROP
	beq .usDrop
	cmp #SFX_CONE
	beq .usCone
	jmp .usDeath
.usSilence
	lda #0
	sta AUDV0
	rts

.usJump                     ; pure tone, pitch RISES (AUDF falls as timer falls)
	lda #SFX_TONE
	sta AUDC0
	lda sfxTimer
	clc
	adc #3
	sta AUDF0
	lda #SFX_VOL
	sta AUDV0
	rts

.usDrop                     ; pure tone, pitch FALLS (AUDF rises as timer falls)
	lda #SFX_TONE
	sta AUDC0
	lda #DROP_DUR
	sec
	sbc sfxTimer
	sta AUDF0
	lda #SFX_VOL
	sta AUDV0
	rts

.usCone                     ; two-note coin: low note then a higher one
	lda #SFX_TONE
	sta AUDC0
	lda #SFX_VOL
	sta AUDV0
	lda sfxTimer
	cmp #CONE_DUR/2
	bcs .usConeLo           ; first half -> low note
	lda #7                  ; second half -> higher note (lower AUDF)
	sta AUDF0
	rts
.usConeLo
	lda #13
	sta AUDF0
	rts

.usDeath                    ; white noise: "tah" burst, gap, "tish" burst
	lda #SFX_NOISE
	sta AUDC0
	lda sfxTimer
	cmp #13
	bcs .usDeathTah         ; 13.. -> first (lower) burst
	cmp #10
	bcc .usDeathTish        ; ..9  -> second (sharper) burst
	lda #0                  ; 10..12 -> short gap
	sta AUDV0
	rts
.usDeathTah
	lda #15
	sta AUDF0
	lda #SFX_VOL
	sta AUDV0
	rts
.usDeathTish
	lda #4
	sta AUDF0
	lda #SFX_VOL
	sta AUDV0
	rts

;-------------------------------------------------------------
; Player vertical-glide data
;-------------------------------------------------------------
; Band start scanline per floor (floor*30). 7 entries so [curFloor+1] is valid.
BandStartTab
	.byte 0, 30, 60, 90, 120, 150, 180

; Zero-padded player sprites for the pointer-offset free-Y draw. The kernel sets
; sprPtr = PlayerBufN + offset: offset 0 -> the 30 leading zeros (player not in
; this band, all blank); offset 1..41 slides the 12-byte body to the band-local
; line where the player sits. The kernel indexes (sprPtr),Y with Y = band-local
; line 1..29, so a 30-byte lead + body + 29-byte tail covers every Y at any
; offset. Page-aligned so (sprPtr),Y never crosses a page boundary (constant 5c).
;
; Two frames for the run cycle: AnimatePlayer toggles animFrame (0/1), and the
; kernel picks the buffer page = >PlayerBuf0 + animFrame (the two buffers are one
; page apart). Both share the same layout, so the per-band offset (sprPtrLoTab)
; is frame-independent. Edit the 6 body rows (top->bottom); the macro doubles
; each to 2 scanlines (the 2600 has no vertical stretch).
	MAC PLAYER_FRAME        ; {1}..{6} = body rows top->bottom (each drawn x2)
	ds 30, 0                ; leading zeros (offset 0 = blank band; covers L 0..29)
	.byte {1},{1},{2},{2},{3},{3},{4},{4},{5},{5},{6},{6}
	ds 29, 0                ; trailing zeros (covers up to L=29 at max offset 41)
	ENDM

	align $100
PlayerBuf0
	PLAYER_FRAME $00,$FC,$D4,$D4,$FC,$CC   ; frame 0: head-up, legs apart
	align $100
PlayerBuf1
	PLAYER_FRAME $FC,$D4,$D4,$FC,$48,$48   ; frame 1: run pose, legs mid-stride

;-------------------------------------------------------------
; Vectors
;-------------------------------------------------------------
	org $fffc
	.word Reset
	.word Reset
