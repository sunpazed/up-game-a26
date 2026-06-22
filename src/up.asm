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
GAP_WRAP     = 159      ; respawn x at the right edge (cycle-74 reaches 0..159)
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
SPEED_INC    = 1        ; per cone (= +0.125 px/frame; ~24 cones to top speed)
SPEED_MAX    = 128      ; cap (= 4.0 px/frame; <= the fall window so falls hold)

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

;-------------------------------------------------------------
; RAM
;-------------------------------------------------------------
	SEG.U vars
	org $80

playerFloor     ds 1    ; 0 = top tier .. 5 = bottom tier
playerBandCount ds 1    ; bandCount value at which to draw the player
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

;-------------------------------------------------------------
; NewGame - (re)start a round. Reached from Reset and from a game-over
; restart. Resets all gameplay state but NOT hiScore (or rng).
;-------------------------------------------------------------
NewGame
	lda #COL_BG
	sta COLUBK              ; clear any game-over red tint

	lda #5
	sta playerFloor         ; player starts on the bottom tier
	lda #0
	sta btnPrev
	sta gameState
	sta goCnt
	sta scoreBCD+0
	sta scoreBCD+1
	sta scoreBCD+2
	sta scrollFrac
	sta animFrame           ; start on run-cycle frame 0
	lda #ANIM_BASE
	sta animTimer
	lda #SPEED_BASE
	sta scrollSpeed         ; start each game at base speed (1 px/frame)

	; Staggered initial gap positions (floor 5 has no gap)
	lda #140
	sta gapX+0
	lda #110
	sta gapX+1
	lda #80
	sta gapX+2
	lda #50
	sta gapX+3
	lda #130
	sta gapX+4
	lda #0
	sta gapX+5

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

	; Start with EMPTY platforms: every entity begins hidden and slides in from
	; the right edge on a staggered delay (via the normal respawn path, which
	; rolls a random type and clears gaps). This guarantees reaction time on any
	; floor the player jumps to -- nothing is ever sitting in the jump path at
	; the fixed player x. entX is set when each one spawns; entDrawLo = blank.
	ldx #5
.ngEnt
	lda #0
	sta entType,x           ; hidden -> .entWaiting spawns it (slide-in)
	sta entSlide,x
	sta entRefp,x
	lda #<ZeroSprite
	sta entDrawLo,x
	lda InitDelayTab,x      ; staggered first-spawn delay per floor
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

	ldx #34                 ; remaining VBLANK lines (2 + 34 = 36)
VBlankLoop
	sta WSYNC
	dex
	bne VBlankLoop

	lda #0
	sta VBLANK              ; display on

;-------------------------------------------------------------
; Visible kernel (192 lines = HUD 12 + 6 bands * 30)
;-------------------------------------------------------------
	; --- HUD region: 6-digit score (12 WSYNC-exact lines) ---
	lda #0
	sta REFP1               ; clear any slide-in reflect so score digits (GRP1) aren't mirrored
	lda #COL_BG
	sta COLUPF              ; HUD line 0: playfield invisible behind the score
	jsr DrawDigits          ; HUD lines 1-9 (DrawDigits ends on a WSYNC)
	; HUD line 10: restore game sprite state
	lda #0
	sta VDELP0
	sta VDELP1
	sta NUSIZ1              ; entity = single copy
	lda #$30
	sta NUSIZ0              ; missile 8px wide, player single copy
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
BandLoop
	; --- setbg line: background colour, player colour, missile off ---
	sta WSYNC
	lda #COL_BG
	sta COLUPF
	lda #COL_PLAYER
	sta COLUP0
	lda #0
	sta ENAM0

	; floor index = NUM_BANDS - bandCount, then position the gap missile
	; (Pos74M0 consumes exactly one scanline, HMOVE at cycle ~74)
	lda #NUM_BANDS
	sec
	sbc bandCount
	sta curFloor
	tay
	jsr Pos74M0             ; position the gap missile (cycle-74)
	lda #$80
	sta HMM0                ; restore no-motion so the next HMOVE won't move it
	ldy curFloor
	jsr Pos74P1             ; position the entity sprite GRP1 (cycle-74)
	lda #$80
	sta HMP1                ; restore no-motion

	; pick player sprite (blank unless this is the player's band); on the player
	; band, select the current run-cycle frame (both frames share a page).
	lda bandCount
	cmp playerBandCount
	bne .blankSpr
	ldx animFrame
	lda PlayerFrameLo,x
	sta sprPtr
	lda #>PlayerSprite0
	sta sprPtr+1
	jmp .selEnt
.blankSpr
	SET_POINTER sprPtr, ZeroSprite
.selEnt
	; entity sprite + colour for this floor's type. The low byte is precomputed
	; (base or pre-shifted slide frame); the page is the base page normally, or
	; the slide-table page while sliding (entSlide != 0).
	ldy curFloor
	ldx entType,y
	lda EntColorTable,x
	sta COLUP1
	lda entDrawLo,y
	sta entPtr
	lda #>ZeroSprite        ; base + slide frames all share this page
	sta entPtr+1
	lda entRefp,y           ; reflect GRP1 while sliding in (else 0)
	sta REFP1

	; 2-line top air pad: drops the sprite within the band so its feet land on
	; the platform below. (GRP0/GRP1 are 0 here from the previous band's clear.)
	sta WSYNC
	sta WSYNC

	; sprite window: each body row (7..2) is drawn on TWO scanlines so the
	; player / entity / cone render at 2x height from the same 8-byte data
	; (the 2600 has no vertical stretch -- you just hold GRPx for 2 lines).
	; No pad loop: the positioning lines above already render as background.
	ldy #SPRITE_H-1         ; 7
.sprLoop
	sta WSYNC               ; row y, 1st scanline
	lda (sprPtr),y
	sta GRP0
	lda (entPtr),y
	sta GRP1
	sta WSYNC               ; row y, 2nd scanline (GRP0/GRP1 hold => 2x tall)
	dey
	cpy #1
	bne .sprLoop            ; rows 7..2 (the body), each twice = 12 lines

	; Still on the last body line (row 2 = feet). After the beam has drawn the
	; player (~pixel 22), recolour the missile to background and enable the gap:
	; it stays invisible on this background line, but is then ready CLIP-FREE for
	; the first green line below -- so the gap shows full-height and the feet sit
	; directly on the platform (no blank foot row, no float).
	SLEEP 24                ; wait past the player sprite before recolouring P0
	lda #COL_BG
	sta COLUP0
	ldy curFloor
	lda GapOnTable,y
	sta ENAM0

	; green top rows. In green line 1's HBLANK (before pixel 0) clear GRP0/GRP1
	; AND both VDEL "old" latches (double sta-pair: a GRP1 write refreshes GRP0's
	; old latch and vice-versa) so the feet don't bleed onto the platform and no
	; stale entity row reaches the score next frame (where VDELP1=1 displays it).
	sta WSYNC
	lda #0
	sta GRP0
	sta GRP1
	sta GRP0
	sta GRP1
	lda #COL_GREEN
	sta COLUPF
	ldx #BAND_GREEN-1
.grnLoop
	sta WSYNC
	dex
	bne .grnLoop

	; grey underside rows
	sta WSYNC
	lda #COL_GREY
	sta COLUPF
	ldx #BAND_GREY-1
.gryLoop
	sta WSYNC
	dex
	bne .gryLoop

	dec bandCount
	beq .bandsDone
	jmp BandLoop            ; (band body > 128 bytes, so jmp not bne)
.bandsDone

	; turn the missile off before leaving the visible area
	lda #0
	sta ENAM0

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
	jmp .gsAfter
.gsFrozen
	jsr CheckRestart        ; world frozen; fresh fire press restarts
.gsAfter
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

	; build the score's digit pointers for next frame's HUD
	jsr GetDigitPtrs

WaitOverscan
	lda INTIM
	bne WaitOverscan
	sta WSYNC

	jmp NextFrame

;-------------------------------------------------------------
; Pos74M0 - position Missile 0 at gap[curFloor] in one scanline.
;   IN: Y = curFloor. Uses precomputed gapQuick / posJmpLo.
;   Cycle-74 HMOVE: clean edge-to-edge positioning, no comb.
;-------------------------------------------------------------
Pos74M0
	lda gapQuick,y
	sta HMM0                ; high nibble = fine motion (low nibble ignored)
	and #$0F
	tax                     ; X = delay count
	lda posJmpLo,y
	sta posJmp
	lda #>PosTblM0
	sta posJmp+1
	sta WSYNC
	; 9 cycles of dead time (matches hmove74 calibration)
	nop                     ; 2
	nop                     ; 2
	nop                     ; 2
	.byte $04,$EA           ; NOP zp (3 cycles)
.wait74
	dex
	bpl .wait74
	jmp (posJmp)            ; into PosTblM0; strobes RESM0, HMOVE @ ~74, rts

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
	sta WSYNC
	nop
	nop
	nop
	.byte $04,$EA
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
	dec playerFloor         ; jump up one tier
.store
	stx btnPrev
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

.scrollStep
	; --- scroll gaps (floors 0..4 ; floor 5 has none) ---
	ldx #4
.gapLoop
	dec gapX,x
	bne .gapNext            ; reached 0 => wrap to the right
	lda #GAP_WRAP
	sta gapX,x
.gapNext
	dex
	bpl .gapLoop

	; --- entities: scroll, hide for a random delay, re-enter ---
	ldx #5
.entLoop
	lda entType,x
	beq .entWaiting         ; type 0 = hidden, waiting to respawn
	lda entSlide,x
	beq .entScroll          ; 0 -> normal scroll
	bmi .entSlideIn         ; $80|N -> sliding IN from the right edge
	; 1..7 -> sliding OUT the left edge (shift grows, then hide)
	inc entSlide,x          ; advance the shift (per scroll step => speed-linked)
	lda entSlide,x
	cmp #8
	bcc .entNext            ; 1..7 still partly on-screen
	lda #0
	sta entType,x           ; fully off the left edge -> hide + arm respawn
	sta entSlide,x
	jsr SetRespawnDelay
	jmp .entNext
.entSlideIn
	dec entSlide,x          ; $80|N -> $80|(N-1): grow in from the right edge
	lda entSlide,x
	cmp #$80
	bne .entNext            ; still entering ($80|7 .. $80|1)
	lda #0
	sta entSlide,x          ; N=0 -> fully in; normal scroll begins next step
	jmp .entNext
.entScroll
	; normal scroll until the entity reaches the left edge (entX = 0)
	lda entX,x
	beq .entStartSlide
	dec entX,x
	jmp .entNext
.entStartSlide
	inc entSlide,x          ; 0 -> 1: hold at x=0, kernel now draws asl x1
	jmp .entNext
.entWaiting
	dec entDelay,x
	bne .entNext
	; delay elapsed -> respawn, but not over this floor's gap. If the gap
	; is in the spawn zone, wait a little and recheck (they scroll at the
	; same speed, so clearing them at spawn keeps them apart all pass).
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

	dec scrollStep
	bne .scrollStep         ; run the scroll 1 or 2 times this frame

	; --- fall-through (once per frame): gap under the player? ---
	lda playerFloor
	cmp #5
	bcs .noFall             ; bottom tier is solid/safe
	tax
	lda gapX,x
	cmp #FALL_HI+1
	bcs .noFall             ; gap is right of the player
	cmp #FALL_LO
	bcc .noFall             ; gap is left of the player
	inc playerFloor         ; fall down one tier
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
; GetDigitPtrs - build the 6 font pointers (Digit0..Digit5) from the
;   3-byte BCD score. Each nibble * 8 = offset into FontTable.
;   (After examples/6-digit-score.asm.)
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
; Tables
;-------------------------------------------------------------
; ENAM0 enable byte per floor (bit1 = enable). Floor 5 = no gap.
GapOnTable
	.byte 2,2,2,2,2,0

; quickPos divide tables (from examples/hmove74.asm)
MultTab
	.byte -25,-10,5,20,35,50,65,80,95,110,-21
DelayTab
	.byte 1,2,3,4,5,6,7,8,9,10,0

; Player run-cycle frames (bottom row first; index 7 = top row). Both frames
; live in the same page so the kernel selects one by low byte via PlayerFrameLo.
; PlayerSprite1 starts as a copy of frame 0 -- edit it to make the second pose.
PlayerSprite0
	.byte %00000000         ; offset 0 (bottom)
	.byte %00000000         ;  
	.byte %11001100         ; ll  ll
	.byte %11111100         ; llllll
	.byte %11010100         ; ll l l
	.byte %11010100         ; ll l l
	.byte %11111100         ; llllll  
	.byte %00000000			; (offset 7, top)
PlayerSprite1
	.byte %00000000         ; offset 0 (bottom)
	.byte %00000000
	.byte %01001000         ;  l  l
	.byte %01001000         ;  l  l
	.byte %11111100         ; llllll
	.byte %11010100         ; ll l l
	.byte %11010100         ; ll l l
	.byte %11111100         ; llllll  (offset 7, top)
; low-byte lookup for the two frames (indexed by animFrame)
PlayerFrameLo
	.byte <PlayerSprite0, <PlayerSprite1

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
; Staggered first-spawn delay per floor (frames) so the empty start fills in
; gradually from the right rather than all at once.
InitDelayTab
	.byte 16, 28, 40, 52, 64, 76

;-------------------------------------------------------------
; Missile-0 cycle-74 strobe table (must stay within one page).
;   Each entry strobes RESM0; the $1C (NOP abs) swallows the next
;   entry's `sta RESM0`, so only the jumped-to strobe executes, then
;   execution falls through to `sta HMOVE` at cycle ~74.
;-------------------------------------------------------------
	org $f500
PosTblM0
pM0_3
	sta RESM0
	.byte $1C
pM0_15
	sta RESM0
	.byte $1C
pM0_30
	sta RESM0
	.byte $1C
pM0_45
	sta RESM0
	.byte $1C
pM0_60
	sta RESM0
	.byte $1C
pM0_75
	sta RESM0
	.byte $1C
pM0_90
	sta RESM0
	.byte $1C
pM0_105
	sta RESM0
	.byte $1C
pM0_120
	sta RESM0
	.byte $1C
pM0_135
	sta RESM0
	.byte $1C
pM0_150
	sta RESM0
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
; Vectors
;-------------------------------------------------------------
	org $fffc
	.word Reset
	.word Reset
