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
COL_BG       = $0C      ; light grey background
COL_GREEN    = $C8      ; platform top (green)
COL_GREY     = $06      ; platform underside (dark grey)
COL_PLAYER   = $02      ; player sprite (dark grey)

PLAYER_X     = 10       ; fixed horizontal position of the player

HUD_LINES    = 12
NUM_BANDS    = 6
BAND_PAD     = 9        ; air pad rows. band = setbg 1 + missile pos 2 + entity
                        ;   pos 2 + pad 9 + sprite 8 + green 4 + grey 4 = 30
SPRITE_H     = 8
BAND_GREEN   = 4
BAND_GREY    = 4

GAP_WIDTH    = 8        ; missile gap width (NUSIZ0 = $30)
GAP_WRAP     = 159      ; respawn x at the right edge (cycle-74 reaches 0..159)
FALL_LO      = 12       ; gap-under-player window [FALL_LO..FALL_HI]
FALL_HI      = 20

; entities (GRP1): one per platform, scroll right-to-left
ENT_CONE     = 1        ; gold collectible (+1 score)
ENT_SKULL    = 2        ; red hazard
COL_CONE     = $1E      ; gold / yellow
COL_SKULL    = $44      ; red
ENT_WRAP     = 152      ; respawn x. Kept <=152 so the 8px GRP1 object never
                        ; reaches the wrap zone (153-159): an object there would
                        ; mod-160 wrap part of the sprite to the LEFT edge,
                        ; flashing the freshly-rerolled type at pixel 0.

COL_GAMEOVER = $42      ; red background tint while game over

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
entType         ds 6    ; per-floor entity: 0 none, 1 cone, 2 skull
entX            ds 6    ; per-floor entity x position
entQuick        ds 6    ; per-floor precomputed quickPos for the entity (GRP1)
entJmpLo        ds 6    ; per-floor precomputed strobe-table entry (low byte)
entPtr          ds 2    ; pointer to the current band's entity sprite
rng             ds 1    ; PRNG state (LFSR)
gameState       ds 1    ; 0 = playing, 1 = game over
scoreBCD        ds 3    ; 6-digit BCD score (shown by the M5 HUD)

;-------------------------------------------------------------
; ROM
;-------------------------------------------------------------
	SEG code
	org $f000

Reset
	CLEAN_START

	; Solid, full-width playfield (held for the whole program)
	lda #$F0
	sta PF0
	lda #$FF
	sta PF1
	sta PF2
	lda #0
	sta CTRLPF              ; players/missiles draw over the playfield

	lda #COL_BG
	sta COLUBK

	; Missile 0 is GAP_WIDTH wide (player stays normal width)
	lda #$30
	sta NUSIZ0

	; Initial game state: player on the bottom tier
	lda #5
	sta playerFloor
	lda #0
	sta btnPrev

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

	; Entities: staggered positions and initial types (one per platform)
	lda #1
	sta rng                 ; PRNG seed (must be non-zero)
	lda #ENT_CONE
	sta entType+0
	lda #ENT_SKULL
	sta entType+1
	lda #ENT_CONE
	sta entType+2
	lda #ENT_CONE
	sta entType+3
	lda #ENT_SKULL
	sta entType+4
	lda #ENT_CONE
	sta entType+5
	lda #150
	sta entX+0
	lda #95
	sta entX+1
	lda #125
	sta entX+2
	lda #65
	sta entX+3
	lda #35
	sta entX+4
	lda #105
	sta entX+5

	; Clear motion registers, then position the static player once
	; (off-screen, plain divide-by-15). Afterwards default every motion
	; register to $80, the cycle-74 HMOVE "no motion" value: the per-band
	; cycle-74 HMOVEs re-apply ALL HMxx, and $00 there is NOT zero motion
	; (it would walk the object); $80 (NO_MO_74) holds non-targeted
	; objects still. Each positioner sets its own HMxx to the fine value
	; for its HMOVE, then restores $80.
	sta HMCLR
	lda #PLAYER_X
	ldx #0
	jsr PosStd
	lda #$80
	sta HMP0
	sta HMM0
	sta HMP1

;-------------------------------------------------------------
; Main frame loop
;-------------------------------------------------------------
NextFrame
	lda #2
	sta VBLANK
	VERTICAL_SYNC           ; 3 vsync lines (leaves A=0)
	sta CXCLR               ; clear collision latches for this frame

	; 36 lines of VBLANK
	ldx #36
VBlankLoop
	sta WSYNC
	dex
	bne VBlankLoop

	lda #0
	sta VBLANK              ; display on

;-------------------------------------------------------------
; Visible kernel (192 lines)
;-------------------------------------------------------------
	; HUD region (playfield invisible)
	lda #COL_BG
	sta COLUPF
	ldx #HUD_LINES
HudLoop
	sta WSYNC
	dex
	bne HudLoop

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

	; pick player sprite (blank unless this is the player's band)
	lda bandCount
	cmp playerBandCount
	bne .blankSpr
	SET_POINTER sprPtr, PlayerSprite
	jmp .selEnt
.blankSpr
	SET_POINTER sprPtr, ZeroSprite
.selEnt
	; entity sprite + colour for this floor's type
	ldy curFloor
	ldx entType,y
	lda EntColorTable,x
	sta COLUP1
	lda EntSprLo,x
	sta entPtr
	lda #>ZeroSprite
	sta entPtr+1

	ldx #BAND_PAD
.padLoop
	sta WSYNC
	dex
	bne .padLoop

	; sprite window (8 lines): player (GRP0) + entity (GRP1), top row first
	ldy #SPRITE_H-1
.sprLoop
	sta WSYNC
	lda (sprPtr),y
	sta GRP0
	lda (entPtr),y
	sta GRP1
	dey
	bpl .sprLoop
	; GRP0/GRP1 are now 0 (sprite offsets 0-1 are blank)

	; prepare platform rows: missile = background (so it shows as a gap),
	; enable the gap if this floor has one (floor 5 has none).
	lda #COL_BG
	sta COLUP0
	ldy curFloor
	lda GapOnTable,y
	sta ENAM0

	; green top rows
	sta WSYNC
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

	lda gameState
	bne .gsFrozen
	; CheckCollision must run BEFORE input/update: CXPPMM reflects the
	; frame just rendered, where playerFloor still matches.
	jsr CheckCollision
	lda gameState
	bne .gsAfter            ; just died this frame -> skip further updates
	jsr ReadInput
	jsr UpdateWorld
	jmp .gsAfter
.gsFrozen
	jsr CheckRestart        ; world frozen; fresh fire press restarts
.gsAfter

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
	dex
	bpl .precomp

	; playerBandCount = NUM_BANDS - playerFloor (for next frame's kernel)
	lda #NUM_BANDS
	sec
	sbc playerFloor
	sta playerBandCount

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
; UpdateWorld - scroll gaps left, wrap, and fall-through check
;-------------------------------------------------------------
UpdateWorld
	; scroll gaps for floors 0..4 (floor 5 has no gap)
	ldx #4
.scroll
	dec gapX,x
	bne .next               ; reached 0 => fully off the left, wrap to right
	lda #GAP_WRAP
	sta gapX,x
.next
	dex
	bpl .scroll

	; fall-through: if player floor < 5 and a gap is under the player
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
	; advance the PRNG once per frame so respawn types stay varied
	jsr Rng
	; scroll entities exactly like the gaps: dec to the left edge, then
	; wrap to the right with a fresh random type. The sprites have a blank
	; leftmost column (bit 7 = 0), so at entX=ENT_WRAP (the wrap target)
	; nothing is drawn at pixel 159 -- the new type stays invisible until
	; the entity scrolls in from the right, so the type change isn't seen.
	ldx #5
.entScroll
	dec entX,x
	bne .entNext
	jsr Rng
	and #3
	tay
	lda EntTypeRoll,y
	sta entType,x
	lda #ENT_WRAP
	sta entX,x
.entNext
	dex
	bpl .entScroll
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
	; cone collected: +1 (BCD), then consume it
	sed
	lda scoreBCD+2
	clc
	adc #1
	sta scoreBCD+2
	lda scoreBCD+1
	adc #0
	sta scoreBCD+1
	lda scoreBCD+0
	adc #0
	sta scoreBCD+0
	cld
	lda #0
	sta entType,x           ; cone consumed (respawns on its next wrap)
	rts
.ccSkull
	lda #1
	sta gameState
	lda #COL_GAMEOVER
	sta COLUBK              ; red tint; Reset restores COL_BG on restart
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
	jmp Reset               ; fresh press -> restart the game
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
; PosStd - plain divide-by-15 positioning (object X at pixel A).
;   Used once at init for the static player (off-screen). 2 scanlines.
;-------------------------------------------------------------
PosStd
	sta WSYNC
	sta HMOVE               ; leading HMOVE/HMCLR set the standard strobe timing
	sta HMCLR               ; (without these the strobe fires ~18px too far left)
	sec
.psd
	sbc #15
	bcs .psd
	eor #7
	asl
	asl
	asl
	asl
	sta RESP0,x
	sta HMP0,x
	sta WSYNC
	sta HMOVE
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

; Player sprite (stored bottom row first; index 7 = top row)
PlayerSprite
	.byte %00000000         ; offset 0 (bottom)
	.byte %00000000
	.byte %01001000         ;  l  l
	.byte %01001000         ;  l  l
	.byte %11111100         ; llllll
	.byte %11010100         ; ll l l
	.byte %11010100         ; ll l l
	.byte %11111100         ; llllll  (offset 7, top)

ZeroSprite
	.byte 0,0,0,0,0,0,0,0

; Cone (gold) - narrow top widening to a base. Bottom row first.
; Bit 7 (leftmost column) is always blank so the entity is invisible at
; the wrap position (entX=159), hiding the respawn type change.
ConeSprite
	.byte %00000000
	.byte %00000000
	.byte %01111110         ; wide base
	.byte %01111110
	.byte %00111100
	.byte %00111100
	.byte %00011000
	.byte %00011000         ; point (top)

; Skull (red) - rounded blob with an eye gap. Bottom row first.
SkullSprite
	.byte %00000000
	.byte %00000000
	.byte %00011000
	.byte %00111100
	.byte %00100100         ; eyes
	.byte %00111100
	.byte %00111100
	.byte %00011000         ; top

; Entity lookups indexed by entType (0 none, 1 cone, 2 skull)
EntColorTable
	.byte $00, COL_CONE, COL_SKULL
EntSprLo
	.byte <ZeroSprite, <ConeSprite, <SkullSprite
; Respawn type roll, indexed by (rng & 3): 50/50 cone / skull
EntTypeRoll
	.byte ENT_CONE, ENT_CONE, ENT_SKULL, ENT_SKULL

;-------------------------------------------------------------
; Missile-0 cycle-74 strobe table (must stay within one page).
;   Each entry strobes RESM0; the $1C (NOP abs) swallows the next
;   entry's `sta RESM0`, so only the jumped-to strobe executes, then
;   execution falls through to `sta HMOVE` at cycle ~74.
;-------------------------------------------------------------
	org $f300
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
; Player-1 (GRP1) cycle-74 strobe table. Placed at $f400 so its
; entries share the SAME low bytes as PosTblM0 ($f300) -> JumpTabM0
; works for both; Pos74P1 just uses the $f4 high byte.
;-------------------------------------------------------------
	org $f400
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
; Vectors
;-------------------------------------------------------------
	org $fffc
	.word Reset
	.word Reset
