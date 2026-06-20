
	processor 6502
        include "vcs.h"
        include "macro.h"
        include "xmacro.h"

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;
; This example uses the 48-pixel retriggering method to display
; a six-digit scoreboard.
;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

        seg.u Variables
	org $80


Temp		.byte
LoopCount	.byte ; counts scanline when drawing

; Pointers to bitmap for each digit
Digit0		.word
Digit1		.word
Digit2		.word
Digit3		.word
Digit4		.word
Digit5		.word

BCDScore	hex 000000

; Variables
energy      .byte 0   ; This would hold the external energy value (0-100)
bitCount    .byte 0   ; To store the calculated bit count
filled      .byte 0   ; To help track filled overall

temp1	.byte
temp2	.byte
temp3	.byte
counter .byte

THREE_COPIES    equ %011 ; for NUSIZ registers

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

	seg Code
        org $f000

Start
	CLEAN_START

NextFrame
	VERTICAL_SYNC

	TIMER_SETUP 37
        lda CTRLPF
        ora #%00000001
        sta CTRLPF     ; reflect and mirror with sprite colours
        lda #$0A
        sta COLUP0
        lda #$0A
        sta COLUP1
        lda #%00000100;
        ;lda #THREE_COPIES
        sta NUSIZ0
        sta NUSIZ1
        lda #$1A
        sta COLUPF
; set horizontal position of player objects
        sta WSYNC
        SLEEP 36;26
        sta RESP0
        sta RESP1
        lda #$10
        sta HMP1
        sta WSYNC
        sta HMOVE
        SLEEP 24	; wait 24 cycles between write to HMOVE and HMxxx
        sta HMCLR
        lda #1
        sta VDELP0
        sta VDELP1
        TIMER_WAIT

	TIMER_SETUP 192

	; set sprite colours for playfield
        lda #$1A
        sta COLUP0
        lda #$7A
        sta COLUP1

	lda #$F0
	sta HMM0

        lda #%0
        sta PF0
        sta PF1
        sta PF2

	sta WSYNC

        sleep 22
        sta RESM0
        sleep 21
	sta RESM1

        sta WSYNC
        sta HMOVE

	lda #%10000000
        sta PF0
        lda #%11111111
        sta PF1
        lda #%01111111
	sta PF2


	lda #2
        sta ENAM0
        sta ENAM1        


        ldy #1
fugga:
	sta WSYNC
        dey
        bne fugga

        ldy #2
        sty Temp


fugga2:
	lda temp1
        ldx temp2
        ldy temp3
        sta PF0
	stx PF1
	sty PF2
        lda temp1
        ldx temp2
        ldy temp3
        sleep 18-9
        sta PF0
	stx PF1
	sty PF2
	sleep 18+5
        dec Temp
        bne fugga2

;	lda #$0A
;        sta COLUBK
	sta WSYNC

	lda #%10000000
        sta PF0
        lda #%11111111
        sta PF1
        lda #%01111111
	sta PF2
        
        sta WSYNC

	lda #0
        sta ENAM0
        sta ENAM1

        ; reset playfield
	lda #0
        sta PF0		; store first playfield byte;
        sta PF1		; store 2nd byte;
        sta PF2		; store 3rd byte

        lda #THREE_COPIES
        sta NUSIZ0
        sta NUSIZ1

	; set colours for sprite
        lda #$0A
        sta COLUP0
        lda #$0A
        sta COLUP1

        sta WSYNC
        
	lda #00
        sta COLUBK

	jsr GetDigitPtrs	; get pointers
        jsr DrawDigits		; draw digits

;        lda #158
;        sta energy
        lda energy
        cmp #0
        bne energywithinlimits
        lda #139
        sta energy
        
energywithinlimits:      
	inc counter
        lda counter
        and #%0001111
        bne .skipEngAdd
        dec energy
.skipEngAdd:
	sta WSYNC
	jsr DoEnergy

        TIMER_WAIT

	TIMER_SETUP 29
        lda #$01
        ldx #$00
        ldy #$00
        jsr AddScore
        TIMER_WAIT
        jmp NextFrame

; Adds value to 6-BCD-digit score.
; A = 1st BCD digit
; X = 2nd BCD digit
; Y = 3rd BCD digit
AddScore subroutine
        sed	; enter BCD mode
        clc	; clear carry
        sta Temp
        lda BCDScore
        adc Temp
        sta BCDScore
        stx Temp
        lda BCDScore+1
        adc Temp
        sta BCDScore+1
        sty Temp
        lda BCDScore+2
        adc Temp
        sta BCDScore+2
        cld	; exit BCD mode
        rts

GetDigitPtrs subroutine
	ldx #0	; leftmost bitmap
        ldy #2	; start from most-sigificant BCD value
.Loop
        lda BCDScore,y	; get BCD value
        and #$f0	; isolate high nibble (* 16)
        lsr		; shift right 1 bit (* 8)
        sta Digit0,x	; store pointer lo byte
        lda #>FontTable
        sta Digit0+1,x	; store pointer hi byte
        inx
        inx		; next bitmap pointer
        lda BCDScore,y	; get BCD value (again)
        and #$f		; isolate low nibble
        asl
        asl
        asl		; * 8
        sta Digit0,x	; store pointer lo byte
        lda #>FontTable
        sta Digit0+1,x	; store pointer hi byte
        inx
        inx		; next bitmap pointer
        dey		; next BCD value
        bpl .Loop	; repeat until < 0
	rts

; Display the resulting 48x8 bitmap
; using the Digit0-5 pointers.
	align $100
DrawDigits subroutine
	;SLEEP 40	; start near end of scanline
        lda #7
        sta LoopCount
	sta WSYNC
	sleep 60
BigLoop
	ldy LoopCount	; counts backwards
        lda (Digit0),y	; load B0 (1st sprite byte)
        sta GRP0	; B0 -> [GRP0]
        lda (Digit1),y	; load B1 -> A
        sta GRP1	; B1 -> [GRP1], B0 -> GRP0
;        sta WSYNC	; sync to next scanline
;	nop
;	lda #%11111
;        sta PF1		; store 3rd byte
	cmp $00
        cmp $00
        
        lda (Digit2),y	; load B2 -> A
        sta GRP0	; B2 -> [GRP0], B1 -> GRP1
        lda (Digit5),y	; load B5 -> A
        sta Temp	; B5 -> temp
        lda (Digit4),y	; load B4
        tax		; -> X
        lda (Digit3),y	; load B3 -> A
        ldy Temp	; load B5 -> Y
        sta GRP1	; B3 -> [GRP1]; B2 -> GRP0
        stx GRP0	; B4 -> [GRP0]; B3 -> GRP1
        sty GRP1	; B5 -> [GRP1]; B4 -> GRP0
        sta GRP0	; ?? -> [GRP0]; B5 -> GRP1
	dec LoopCount	; go to next line
	bpl BigLoop	; repeat until < 0


        lda #0		; clear the sprite registers
        sta GRP0
        sta GRP1
        sta GRP0
        sta GRP1
        
        rts


    ; Main program
DoEnergy:
    ; we divide the energy by 8 to find 
    ; the number of playfield pixels to draw.
    ; 160 / 8 = upto 20 pixels.
    lda energy	; fetch energy
    lsr 	; divide by 8
    lsr
    lsr 
    adc #2 ; add to offset 0 energy position
    tay    
    ;tay		
    cmp #13	; >= 13 
    bcs .energy13to20  
    cmp #5	; >=5 
    bcs .energy5to12  
    ; energy is 0-4 
    lda PF0Table,y    
    sta temp1
    lda #%00000000
    sta temp2
    sta temp3
    rts
.energy5to12:
    ; energy is 5-12 
    lda PF0Table,y
    sta temp2
    lda #%10000000
    sta temp1
    lda #%00000000
    sta temp3
    rts    
.energy13to20:
    ; energy is 13-20 
    lda PF0Table,y
    sta temp3
    lda #%10000000
    sta temp1
    lda #%11111111
    sta temp2
    rts
    
; Font table for digits 0-9 (8x8 pixels)
        align $100 ; make sure data doesn't cross page boundary
FontTable:
    .byte $00,$1c,$32,$63,$63,$63,$26,$1c,$00,$3f,$0c,$0c,$0c,$0c,$1c,$0c,$00,$7f,$70,$3c,$1e,$07,$63,$3e,$00,$3e,$63,$03,$1e,$0c,$06,$3f,$00,$06,$06,$7f,$66,$36,$1e,$0e,$00,$3e,$63,$03,$03,$7e,$60,$7e,$00,$3e,$63,$63,$7e,$60,$30,$1e,$00,$18,$18,$18,$0c,$06,$63,$7f,$00,$3e,$43,$4f,$3c,$72,$62,$3c,$00,$3c,$06,$03,$3f,$63,$63,$3e

FontTableOrigBinary:
    .byte %00000000
    .byte %00111100
    .byte %01100110
    .byte %01100110
    .byte %01110110
    .byte %01101110
    .byte %01100110
    .byte %00111100
    .byte %00000000
    .byte %01111110
    .byte %00011000
    .byte %00011000
    .byte %00011000
    .byte %00111000
    .byte %00011000
    .byte %00011000
    .byte %00000000
    .byte %01111110
    .byte %01100000
    .byte %00110000
    .byte %00001100
    .byte %00000110
    .byte %01100110
    .byte %00111100
    .byte %00000000
    .byte %00111100
    .byte %01100110
    .byte %00000110
    .byte %00011100
    .byte %00000110
    .byte %01100110
    .byte %00111100
    .byte %00000000
    .byte %00000110
    .byte %00000110
    .byte %01111111
    .byte %01100110
    .byte %00011110
    .byte %00001110
    .byte %00000110
    .byte %00000000
    .byte %00111100
    .byte %01100110
    .byte %00000110
    .byte %00000110
    .byte %01111100
    .byte %01100000
    .byte %01111110
    .byte %00000000
    .byte %00111100
    .byte %01100110
    .byte %01100110
    .byte %01111100
    .byte %01100000
    .byte %01100110
    .byte %00111100
    .byte %00000000
    .byte %00011000
    .byte %00011000
    .byte %00011000
    .byte %00011000
    .byte %00001100
    .byte %01100110
    .byte %01111110
    .byte %00000000
    .byte %00111100
    .byte %01100110
    .byte %01100110
    .byte %00111100
    .byte %01100110
    .byte %01100110
    .byte %00111100
    .byte %00000000
    .byte %00111100
    .byte %01100110
    .byte %00000110
    .byte %00111110
    .byte %01100110
    .byte %01100110
    .byte %00111100

FontTable2
;;{w:8,h:8,count:10,brev:1,flip:1};;
	hex 003c6666766e663c007e181818381818
        hex 007e60300c06663c003c66061c06663c
        hex 0006067f661e0e06003c6606067c607e
        hex 003c66667c60663c00181818180c667e
        hex 003c66663c66663c003c66063e66663c

	align $100
PF0Table: 
    .byte 0,0,%00000000,%00000000,%10000000
    ;     .byte %00000000,%00010000,%00110000,%01110000,%11110000

PF1Table: 
    .byte %10000000
    .byte %11000000
    .byte %11100000
    .byte %11110000   
    .byte %11111000
    .byte %11111100
    .byte %11111110
    .byte %11111111
PF2Table: 
    .byte %00000001,%00000011,%00000111,%00001111    
    .byte %00011111,%00111111,%01111111,%11111111


;;
; Epilogue
	org $fffc
        .word Start
        .word Start
