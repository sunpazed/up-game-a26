;  Position an object with cycle 74 Hmoves
;  By Omegamatrix
;
;  The top yellow object is position with a cycle 74 hmove (in one scanline).
;  The bottom green object is postioned traditionally for comparision.

      processor 6502

VSYNC   =  $00
VBLANK  =  $01
WSYNC   =  $02
COLUP0  =  $06
COLUP1  =  $07
COLUBK  =  $09
RESP0   =  $10
RESP1   =  $11
GRP0    =  $1B
GRP1    =  $1C
HMP0    =  $20
HMP1    =  $21
HMOVE   =  $2A
SWCHA   =  $0280
INTIM   =  $0284
TIM64T  =  $0296

;73/74 cycle HMxx
LEFT74_15   = $70
LEFT74_14   = $60
LEFT74_13   = $50
LEFT74_12   = $40
LEFT74_11   = $30
LEFT74_10   = $20
LEFT74_9    = $10
LEFT74_8    = $00
LEFT74_7    = $F0
LEFT74_6    = $E0
LEFT74_5    = $D0
LEFT74_4    = $C0
LEFT74_3    = $B0
LEFT74_2    = $A0
LEFT74_1    = $90
NO_MO_74    = $80

;---------------------------------------
;two different approaches here, the fixed
;time routine is useful when kernel time
;is available...

; 0 = fixed time (49 cycles)
; 1 = variable time (96 cycles max)

POSITION_ROUTINE = 0

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;      RIOT RAM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

       SEG.U RIOT_RAM
       ORG $80

objHpos                 ds 1  ;  - actual pixel position 0-159
quickPos                ds 1  ;  - ram used to quickly position GRPx
indirectAddress         ds 2  ;  - address for the indirect jump!
tempOne                 ds 1  ;  - temporary storage



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;      MAIN PROGRAM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

       SEG CODE
       ORG $F000

START:
    cld
    ldx    #0
    txa
.loopClear:
    dex
    txs
    pha
    bne    .loopClear

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; Vsync
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

MainLoop:
    lda    #$0E
.loopVsync:
    sta    WSYNC             ; three lines of Vsync
;---------------------------------------
    sta    VSYNC
    lsr
    bne    .loopVsync
    lda    #46               ; Vblank time
    sta    TIM64T


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; move object with joystick
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
LEFT_EDGE   = 0
RIGHT_EDGE  = 159

    ldx    objHpos
    bit    SWCHA
    bmi    .checkLeft
    inx
.checkLeft:
    bvs    .checkRightWrap
    dex
.checkRightWrap:
    cpx    #RIGHT_EDGE+1     ; have we gone past?
    bne    .checkLeftWrap    ; - no
    ldx    #LEFT_EDGE        ; - yes, so wrap around...
    beq    .storeObjHpos     ; always branch

.checkLeftWrap:
    cpx    #LEFT_EDGE-1      ; have we gone past?
    bne    .storeObjHpos     ; - no
    ldx    #RIGHT_EDGE       ; - yes, reset
.storeObjHpos:
    stx    objHpos
    txa                      ; use the accumulator for subtraction


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; determine a "quick position"
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

  IF POSITION_ROUTINE

;@0 cycles
    ldy    #0
    cmp    #150              ; correct far right positioning (150-159) ?
    bcc    .findPosition     ; - no
    dey                      ; - yes, Y=$FF to get incremented to 0, and we will use the first RESPx
    sbc    #148              ; correction factor
.findPosition:
    sec
.divideBy15:
    sbc    #15
    iny
    bcs    .divideBy15

    sty    quickPos          ; delay count
    eor    #$0F
    adc    #9
    asl
    asl
    asl
    asl                      ; HMPx value
    ora    quickPos          ; HMPx | delay count
;@96 cycles max


  ELSE

;---------------------------------------
; alternative for finding "quickPos"
;---------------------------------------

;fast divide by 15 (that I wrote),
;good for any unsigned number 0-255
    sta    tempOne               ;3  @3
    lsr                          ;2  @5
    adc    #4                    ;2  @7
    lsr                          ;2  @9
    lsr                          ;2  @11
    lsr                          ;2  @13
    adc    tempOne               ;3  @16
    ror                          ;2  @18
    lsr                          ;2  @20
    lsr                          ;2  @22
    lsr                          ;2  @24
;now find quickPos value...
    tay                          ;2  @26
    lda    MultTab,Y             ;4  @30
    sec                          ;2  @32
    sbc    tempOne               ;3  @35
    asl                          ;2  @37
    asl                          ;2  @39
    asl                          ;2  @41
    asl                          ;2  @43
    clc                          ;2  @45
    adc    DelayTab,Y            ;4  @49
;@49 cycles all the time

  ENDIF

    sta    quickPos
    and    #$0F
    tay


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; set up indirect jump
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;    tya                      ; alternative code to get the low pointer,
;    sta    indirectAddress   ; using this would save six bytes as the
;    asl                      ; jump table could be eliminated...
;    adc    indirectAddress
;    adc    #<postion_3
;    sta    indirectAddress


    lda    JumpTab,Y         ; low pointer
    sta    indirectAddress
    lda    #>postion_3       ; high pointer
    sta    indirectAddress+1

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; finish Vblank, draw top of screen
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

.loopVblank
    lda    INTIM
    bne    .loopVblank
    sta    WSYNC
    sta    WSYNC
;---------------------------------------
    sta    VBLANK
    lda    #$A0
    sta    COLUBK
    lda    #$1A              ; top object
    sta    COLUP0
    lda    #$C8              ; bottom object
    sta    COLUP1

    ldy    #91
.loopTop:
    sta    WSYNC
;---------------------------------------
    dey
    bne   .loopTop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; prep to position top object
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    lda    quickPos          ; 10 cycles of stuff
    sta    HMP0
    and    #$0F
    tax                      ; delay count

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; position top object in 1 scanline
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    sta    WSYNC
;---------------------------------------
    nop                               ;2  @2  nine cycles of free time
    nop                               ;2  @4
    nop                               ;2  @6
    nop    $EA                        ;3  @9
.waitPos:
    dex                               ;2  @11
    bpl    .waitPos                   ;2³ @13/14
    jmp.ind (indirectAddress)         ;5  @18    jump into table below


postion_3:
    sta   RESP0
    .byte $1C         ; nop  $1085,X (rom space),  X is bounded 0-10
postion_15:
    sta   RESP0
    .byte $1C         ; could also use opcode $9D for "sta  $1085,X", or $DD for "cmp  $1085,X", etc...
postion_30:
    sta   RESP0
    .byte $1C
postion_45:
    sta   RESP0
    .byte $1C
postion_60:
    sta   RESP0
    .byte $1C
postion_75:
    sta   RESP0
    .byte $1C
postion_90:
    sta   RESP0
    .byte $1C
postion_105:
    sta   RESP0
    .byte $1C
postion_120:
    sta   RESP0
    .byte $1C
postion_135:
    sta   RESP0
    .byte $1C
postion_150:
    sta   RESP0
    sta   HMOVE       ;3  @74
    nop               ;2  @76   free time
;---------------------------------------

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; draw top object
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    ldy    #8
    lda    #$FF
    sta    GRP0

.loopDrawTopObj
    sta    WSYNC
;---------------------------------------
    dey
    bne    .loopDrawTopObj
    sty    GRP0           ; clear

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; prep for bottom object
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    lda    objHpos
    sta    WSYNC
;---------------------------------------
    sec
.loopPos2
    sbc    #15
    bcs    .loopPos2
    eor    #$07
    asl
    asl
    asl
    asl
    sta.w  HMP1
    sta    RESP1
    sta    WSYNC
;---------------------------------------
    sta    HMOVE
    sta    WSYNC

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; draw bottom object
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    ldy    #8
    lda    #$FF
    sta    GRP1

.loopDrawBotObj
    sta    WSYNC
;---------------------------------------
    dey
    bne    .loopDrawBotObj
    sty    GRP1           ; clear

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; finish bottom of screen
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

    ldy    #81
.loopBottom:
    sta    WSYNC
;---------------------------------------
    dey
    bne    .loopBottom
    lda    #2
    sta    VBLANK
    lda    #31
    sta    TIM64T

.loopOverscan:
    lda    INTIM
    bne    .loopOverscan
    jmp    MainLoop

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
; tables
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

       ORG $F100

JumpTab:
    .byte <postion_3    ; X=0   this table can be eliminated!
    .byte <postion_15   ; 1
    .byte <postion_30   ; 2
    .byte <postion_45   ; 3
    .byte <postion_60   ; 4
    .byte <postion_75   ; 5
    .byte <postion_90   ; 6
    .byte <postion_105  ; 7
    .byte <postion_120  ; 8
    .byte <postion_135  ; 9
    .byte <postion_150  ; 10


MultTab:
    .byte -25    ; Y=0
    .byte -10    ; 1
    .byte 5      ; 2
    .byte 20     ; 3
    .byte 35     ; 4
    .byte 50     ; 5
    .byte 65     ; 6
    .byte 80     ; 7
    .byte 95     ; 8
    .byte 110    ; 9
    .byte -21    ; 10

DelayTab:
    .byte 1      ; Y=0
    .byte 2      ; 1
    .byte 3      ; 2
    .byte 4      ; 3
    .byte 5      ; 4
    .byte 6      ; 5
    .byte 7      ; 6
    .byte 8      ; 7
    .byte 9      ; 8
    .byte 10     ; 9
    .byte 0      ; 10


       ORG $FFFC

    .word START
    .word START