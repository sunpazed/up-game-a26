	processor 6502
	include "vcs.h"
	include "macro.h"
	include "xmacro.h"

; -----------------------------------------------------------------------------
; UP 1 WAY (Atari 2600, 4K)
;
; This file is intentionally documented and organized in readable sections.
; The code currently implements:
; - stable frame structure (VSYNC / VBLANK / kernel / overscan)
; - lane-based player movement (jump up, fall on gap)
; - scrolling gap model
; - placeholder cone/skull entities with collision hooks
; - HUD placeholder strip at top of screen
;
; The goal is a clean, extensible baseline that we can iterate on.
; -----------------------------------------------------------------------------

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------
GAME_STATE_PLAY     equ $00
GAME_STATE_OVER     equ $01

LANE_COUNT          equ 6
LANE_LAST           equ 5

PLAYER_X_RESET      equ 40
PLAYER_START_LANE   equ 5
PLAYER_GAP_MIN      equ 36
PLAYER_GAP_MAX      equ 44

GAP_X_MIN           equ 8
GAP_X_MAX           equ 152

CONE_RESPAWN_X      equ 176
SKULL_RESPAWN_X     equ 200

; -----------------------------------------------------------------------------
; RAM map
; -----------------------------------------------------------------------------
	seg.u Variables
	org $80

FrameCounter        ds 1
GameState           ds 1
Random              ds 1

JoyPrev             ds 1
JoyNow              ds 1
JumpPressed         ds 1

PlayerX             ds 1
PlayerY             ds 1
PlayerLane          ds 1

Scroll              ds 1

TierGap0            ds 1
TierGap1            ds 1
TierGap2            ds 1
TierGap3            ds 1
TierGap4            ds 1
TierGap5            ds 1

TierDir0            ds 1
TierDir1            ds 1
TierDir2            ds 1
TierDir3            ds 1
TierDir4            ds 1
TierDir5            ds 1

ConeX               ds 1
ConeY               ds 1
ConeLane            ds 1

SkullX              ds 1
SkullY              ds 1
SkullLane           ds 1

ActiveEntityType    ds 1 ; 0=cone, 1=skull (rendered on P1)

ScoreLo             ds 1
ScoreHi             ds 1
HiScoreLo           ds 1
HiScoreHi           ds 1

KernelScanline      ds 1
KernelPhase         ds 1
PlayerGfx           ds 1
Temp                ds 1

; -----------------------------------------------------------------------------
; ROM code
; -----------------------------------------------------------------------------
	seg
	org $f000

Start
	CLEAN_START
	jsr InitGame

; Main frame loop.
; The high-level flow is kept explicit and easy to audit.
NextFrame
	VERTICAL_SYNC

	lda #2
	sta VBLANK

	; 36 scanlines of VBLANK. The VERTICAL_SYNC macro consumes 4 WSYNCs
	; total (3 VSYNC-on lines plus the line that turns VSYNC off), so this
	; keeps the full frame at 262 NTSC scanlines: 4 + 36 + 192 + 30.
	SKIP_SCANLINES 36

	lda #0
	sta VBLANK

	; 192 visible scanlines.
	jsr DrawKernel

	; Overscan with timed housekeeping.
	lda #2
	sta VBLANK
	; Debug baseline: keep overscan purely scanline-budgeted. Gameplay update
	; routines run for variable CPU time, so leave them disabled until the kernel
	; is stable and then reintroduce them inside a timer-budgeted block.
	; PositionObjects calls SetHorizPos five times. SetHorizPos burns two WSYNCs
	; per object, so this consumes 10 overscan scanlines.
	jsr PositionObjects
	; Complete the 30-line overscan budget: 10 positioning + 20 idle.
	SKIP_SCANLINES 20

	jmp NextFrame

; -----------------------------------------------------------------------------
; Initialization
; -----------------------------------------------------------------------------

; InitGame: full boot init (includes high score reset).
InitGame
	lda #0
	sta HiScoreLo
	sta HiScoreHi
	jsr InitRound
	rts

; InitRound: per-round reset (preserves high score).
InitRound
	lda #GAME_STATE_PLAY
	sta GameState

	lda #$A5
	sta Random

	lda #0
	sta FrameCounter
	sta JoyPrev
	sta JoyNow
	sta JumpPressed
	sta Scroll
	sta ScoreLo
	sta ScoreHi

	lda #PLAYER_X_RESET
	sta PlayerX
	lda #PLAYER_START_LANE
	sta PlayerLane
	jsr SyncPlayerY

	; Initial gap offsets per lane. These are intentionally staggered.
	lda #4
	sta TierGap0
	lda #7
	sta TierGap1
	lda #10
	sta TierGap2
	lda #13
	sta TierGap3
	lda #16
	sta TierGap4
	lda #19
	sta TierGap5

	; Direction per lane: 0=left, 1=right.
	lda #1
	sta TierDir0
	lda #0
	sta TierDir1
	lda #1
	sta TierDir2
	lda #0
	sta TierDir3
	lda #1
	sta TierDir4
	lda #0
	sta TierDir5

	; Initial entities and their lanes.
	lda #0
	sta ActiveEntityType
	jsr RespawnCone
	jsr RespawnSkull
	rts

; -----------------------------------------------------------------------------
; Input and world updates
; -----------------------------------------------------------------------------

; ReadInput: edge-detect trigger button into JumpPressed.
; INPT4 bit7: 0=pressed, 1=released.
ReadInput
	lda INPT4
	and #$80
	sta JoyNow

	lda #0
	sta JumpPressed

	lda JoyPrev
	beq ReadInput_PrevWasPressed
	lda JoyNow
	bne ReadInput_StoreCurrent
	lda #1
	sta JumpPressed

ReadInput_PrevWasPressed
ReadInput_StoreCurrent
	lda JoyNow
	sta JoyPrev
	rts

; UpdateWorld: top-level gameplay update dispatch.
UpdateWorld
	inc FrameCounter

	lda GameState
	beq UpdateWorld_Playing

	; Game-over state: restart on next button press.
	lda JumpPressed
	beq UpdateWorld_Done
	jsr InitRound
	jmp UpdateWorld_Done

UpdateWorld_Playing
	jsr UpdateGaps
	jsr UpdatePlayerLane
	; Milestone focus: missile-driven gap scrolling.
	; Entity updates/collisions will be re-enabled in the next gate.

UpdateWorld_Done
	rts

; UpdateGaps: moves one shared missile gap left/right.
UpdateGaps
	lda FrameCounter
	and #$01
	bne UpdateGaps_Done

	lda TierDir0
	beq UpdateGaps_MoveLeft

UpdateGaps_MoveRight
	inc TierGap0
	lda TierGap0
	cmp #GAP_X_MAX
	bcc UpdateGaps_Done
	lda #0
	sta TierDir0
	jmp UpdateGaps_Done

UpdateGaps_MoveLeft
	dec TierGap0
	lda TierGap0
	cmp #GAP_X_MIN
	bcs UpdateGaps_Done
	lda #1
	sta TierDir0

UpdateGaps_Done
	rts

; UpdatePlayerLane: applies jump-up and automatic fall-down behavior.
UpdatePlayerLane
	lda JumpPressed
	beq UpdatePlayerLane_CheckFall

	lda PlayerLane
	beq UpdatePlayerLane_CheckFall
	dec PlayerLane
	jsr SyncPlayerY
	rts

UpdatePlayerLane_CheckFall
	ldx PlayerLane
	jsr CheckHoleForLane
	beq UpdatePlayerLane_Done

	cpx #LANE_LAST
	beq UpdatePlayerLane_FallOffBottom

	inc PlayerLane
	jsr SyncPlayerY
	rts

UpdatePlayerLane_FallOffBottom
	; Bottom lane is safe for now. If the gap marker reaches the player on
	; the lowest lane, keep the player there instead of ending the round.
	; Game-over will be restored later via explicit hazard collision.

UpdatePlayerLane_Done
	rts

; CheckHoleForLane
; IN:  X = lane index
; OUT: A = 1 if player aligns with shared moving missile-gap marker, else 0
CheckHoleForLane
	lda TierGap0
	cmp #PLAYER_GAP_MIN
	bcc CheckHoleForLane_NoHole
	cmp #PLAYER_GAP_MAX
	bcs CheckHoleForLane_NoHole
	lda #1
	rts

CheckHoleForLane_NoHole
	lda #0
	rts

; UpdateEntities: moves placeholders and respawns when off-screen.
UpdateEntities
	lda FrameCounter
	and #$01
	bne UpdateEntities_Done

	dec ConeX
	dec SkullX

	lda ConeX
	cmp #2
	bcs UpdateEntities_CheckSkull
	jsr RespawnCone

UpdateEntities_CheckSkull
	lda SkullX
	cmp #2
	bcs UpdateEntities_Done
	jsr RespawnSkull

UpdateEntities_Done
	rts

; CheckCollisions: lane + X-distance checks for cone/skull.
CheckCollisions
	; Cone pickup
	lda ConeLane
	cmp PlayerLane
	bne CheckCollisions_CheckSkull
	lda ConeX
	jsr IsNearPlayerX
	beq CheckCollisions_CheckSkull
	jsr AddScorePoint
	jsr RespawnCone

CheckCollisions_CheckSkull
	; Skull hazard
	lda SkullLane
	cmp PlayerLane
	bne CheckCollisions_Done
	lda SkullX
	jsr IsNearPlayerX
	beq CheckCollisions_Done
	lda #GAME_STATE_OVER
	sta GameState
	jsr UpdateHighScore

CheckCollisions_Done
	rts

; IsNearPlayerX
; IN:  A = entity X
; OUT: A = 1 if |entityX - playerX| < 4, else 0
IsNearPlayerX
	sta Temp
	lda Temp
	cmp PlayerX
	bcs IsNearPlayerX_EntityRight

	; Entity is left of player
	lda PlayerX
	sec
	sbc Temp
	cmp #4
	bcc IsNearPlayerX_Near
	bcs IsNearPlayerX_Far

IsNearPlayerX_EntityRight
	lda Temp
	sec
	sbc PlayerX
	cmp #4
	bcc IsNearPlayerX_Near

IsNearPlayerX_Far
	lda #0
	rts

IsNearPlayerX_Near
	lda #1
	rts

; -----------------------------------------------------------------------------
; Scoring helpers
; -----------------------------------------------------------------------------

; AddScorePoint: 16-bit binary score increment.
AddScorePoint
	inc ScoreLo
	bne AddScorePoint_Done
	inc ScoreHi

AddScorePoint_Done
	rts

; UpdateHighScore: keeps HiScore >= current score.
UpdateHighScore
	lda ScoreHi
	cmp HiScoreHi
	bcc UpdateHighScore_Done
	bne UpdateHighScore_Store

	lda ScoreLo
	cmp HiScoreLo
	bcc UpdateHighScore_Done

UpdateHighScore_Store
	lda ScoreLo
	sta HiScoreLo
	lda ScoreHi
	sta HiScoreHi

UpdateHighScore_Done
	rts

; -----------------------------------------------------------------------------
; Entity and lane sync helpers
; -----------------------------------------------------------------------------

; RespawnCone: chooses new lane and places cone at right side.
RespawnCone
	lda #CONE_RESPAWN_X
	sta ConeX
	jsr NextRandom
	and #$07
	cmp #LANE_COUNT
	bcc RespawnCone_StoreLane
	sec
	sbc #LANE_COUNT

RespawnCone_StoreLane
	sta ConeLane
	jsr SyncConeY
	rts

; RespawnSkull: chooses new lane and places skull at right side.
RespawnSkull
	lda #SKULL_RESPAWN_X
	sta SkullX
	jsr NextRandom
	and #$03
	clc
	adc #2
	sta SkullLane
	jsr SyncSkullY
	rts

SyncPlayerY
	ldx PlayerLane
	lda LaneYTable,x
	sta PlayerY
	rts

SyncConeY
	ldx ConeLane
	lda LaneYTable,x
	sta ConeY
	rts

SyncSkullY
	ldx SkullLane
	lda LaneYTable,x
	sta SkullY
	rts

; -----------------------------------------------------------------------------
; Positioning and kernel
; -----------------------------------------------------------------------------

; PositionObjects: coarse/fine horizontal setup done in overscan.
; Debug milestone: position all five TIA objects like examples/example.asm.
; X index mapping for SetHorizPos: 0=P0, 1=P1, 2=M0, 3=M1, 4=Ball.
PositionObjects
	ldx #0
	lda PlayerX
	jsr SetHorizPos

	ldx #1
	lda #64
	jsr SetHorizPos

	ldx #2
	lda #88
	jsr SetHorizPos

	ldx #3
	lda #112
	jsr SetHorizPos

	ldx #4
	lda #136
	jsr SetHorizPos
	rts

; DrawKernel: 192 visible scanlines.
; Debug kernel based on examples/example.asm.
; It writes both players, both missiles, and the ball on every scanline.
; Platforms are intentionally disabled until this baseline is stable.
DrawKernel
	lda #$0e
	sta COLUBK
	lda #$08
	sta COLUP0
	lda #$56
	sta COLUP1
	lda #$3a
	sta COLUPF
	lda #$30
	sta CTRLPF
	lda #$10
	sta NUSIZ0
	sta NUSIZ1

	lda #0
	sta KernelScanline
	sta KernelPhase
	sta PF0
	sta PF1
	sta PF2
	sta GRP0
	sta GRP1
	ldx #192
	ldy #0

DrawKernel_Loop
	sta WSYNC
	lda DebugSprite,y
	sta GRP0
	eor #$ff
	sta GRP1
	tya
	and #$02
	sta ENAM0
	sta ENAM1
	sta ENABL
	iny
	cpy #8
	bne DrawKernel_NoWrap
	ldy #0

DrawKernel_NoWrap
	dex
	beq DrawKernel_Done
	jmp DrawKernel_Loop

DrawKernel_Done
	lda #0
	sta GRP0
	sta GRP1
	sta ENAM0
	sta ENAM1
	sta ENABL
	rts

; DrawHUD: placeholder hook for future dedicated score kernel.
DrawHUD
	rts

; SetHorizPos
; IN:  A = X position, X = object index (0=P0,1=P1,2=M0,3=M1,4=BL)
; OUT: Coarse/fine horizontal position applied with HMOVE.
SetHorizPos
	sta WSYNC
	sta HMCLR
	sec

SetHorizPos_DivideLoop
	sbc #15
	bcs SetHorizPos_DivideLoop
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

; NextRandom: tiny LFSR-ish generator used for lane selection.
NextRandom
	lda Random
	beq NextRandom_DoEor
	lsr
	bcc NextRandom_NoEor

NextRandom_DoEor
	eor #$B4

NextRandom_NoEor
	sta Random
	rts

; -----------------------------------------------------------------------------
; Data tables
; -----------------------------------------------------------------------------

; Lane top-Y values for 8-pixel sprites.
LaneYTable
	.byte 11,29,47,65,83,101

; Gap animation patterns (coarse playfield masks).
PlatformPF0Table
	.byte $f0,$e0,$c0,$80,$00,$10,$30,$70
PlatformPF1Table
	.byte $ff,$ff,$7f,$3f,$1f,$0f,$87,$c3
PlatformPF2Table
	.byte $ff,$fe,$fc,$f8,$f0,$e0,$c0,$80

; Platform register values indexed by PlatformMask (0=off, 1=platform).
; The kernel writes all of these every scanline so platform rows and gaps take
; the same timing path whether visible or hidden.
PlatformPF0Value
	.byte $00,$f0
PlatformPF1Value
	.byte $00,$ff
PlatformPF2Value
	.byte $00,$ff
PlatformP1Value
	.byte $00,%00011000
PlatformEnableValue
	.byte $00,$02

; 16-step fill table for top HUD placeholder.
HudPF1Table
	.byte $00,$80,$c0,$e0,$f0,$f8,$fc,$fe
	.byte $ff,$7f,$3f,$1f,$0f,$07,$03,$01

; 8-line debug sprite used by the reference-style stable kernel.
DebugSprite
	.byte %10000001
	.byte %01000010
	.byte %00100100
	.byte %00011000
	.byte %00011000
	.byte %00100100
	.byte %01000010
	.byte %10000001

; 7-line player sprite.
PlayerSprite
	.byte %00111100
	.byte %01111110
	.byte %01111110
	.byte %01111110
	.byte %01111110
	.byte %01111110
	.byte %00111100

; 192-line platform mask: exactly six 6-scanline platform bands.
; Bands begin at scanlines 18, 36, 54, 72, 90, and 108.
PlatformMask
	REPEAT 18
	.byte 0
	REPEND
	REPEAT 6
	.byte 1
	REPEND
	REPEAT 12
	.byte 0
	REPEND
	REPEAT 6
	.byte 1
	REPEND
	REPEAT 12
	.byte 0
	REPEND
	REPEAT 6
	.byte 1
	REPEND
	REPEAT 12
	.byte 0
	REPEND
	REPEAT 6
	.byte 1
	REPEND
	REPEAT 12
	.byte 0
	REPEND
	REPEAT 6
	.byte 1
	REPEND
	REPEAT 12
	.byte 0
	REPEND
	REPEAT 6
	.byte 1
	REPEND
	REPEAT 78
	.byte 0
	REPEND

; 8-line cone sprite.
ConeSprite
	.byte %00011000
	.byte %00011000
	.byte %00111100
	.byte %00111100
	.byte %01111110
	.byte %01111110
	.byte %11111111
	.byte %00011000

; 8-line skull-ish placeholder sprite.
SkullSprite
	.byte %00111100
	.byte %01111110
	.byte %01011010
	.byte %01111110
	.byte %00111100
	.byte %00100100
	.byte %01011010
	.byte %10000001

; -----------------------------------------------------------------------------
; Vectors
; -----------------------------------------------------------------------------
	org $fffc
	.word Start
	.word Start
