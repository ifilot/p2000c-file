; P2FILE.ASM - two-panel CP/M file manager for the Philips P2000C
;
; Assemble on the P2000C with Digital Research's tools:
;     ASM P2FILE
;     LOAD P2FILE
;     P2FILE
;
; Keys: TAB panel, W/S move, SPACE mark, C copy, D delete, R rename,
;       V choose drive, H help, Q quit.
;
; Intel 8080 source.  The program uses only documented CP/M 2.2 BDOS calls
; and documented P2000C terminal escape sequences.

BDOS    EQU     0005H
CONOUT  EQU     02H
DIRIO   EQU     06H
OPENF   EQU     0FH
CLOSEF  EQU     10H
SFIRST  EQU     11H
SNEXT   EQU     12H
DELETE  EQU     13H
SELDSK  EQU     0EH
READSEQ EQU     14H
WRITSEQ EQU     15H
MAKEF   EQU     16H
RENAME  EQU     17H
CURDSK  EQU     19H
SETDMA  EQU     1AH
USERNO  EQU     20H

MAXFILE EQU     128
ROWS    EQU     21
FIRST   EQU     1
ENTSIZ  EQU     15
CENTSIZ EQU     14
CACHEBY EQU     MAXFILE*CENTSIZ
NORMATT EQU     40H
INVATT  EQU     50H
CPBUFR  EQU     32

        ORG     0100H

START:  LXI     SP,STACK
        CALL    CURSOFF
        CALL    INITCACHE
        LDA     LDRIVE
        CALL    SHOWSTART
        CALL    LOADL
        CALL    DRAWSHELL
        LDA     RDRIVE
        CALL    SHOWREAD
        CALL    LOADR
        CALL    DRAWR
        CALL    DRAWFOOT
        JMP     KEYLOOP

MAIN:   CALL    DRAW
KEYLOOP:CALL    GETKEY
        STA     KEYTMP
        LDA     MODAL
        ORA     A
        JZ      KEYFOOT
        XRA     A
        STA     MODAL
        CALL    DRAW
        JMP     KEYLOAD
KEYFOOT:
        LDA     FOOTMSG
        ORA     A
        JZ      KEYLOAD
        CALL    DRAWFOOT
KEYLOAD:LDA     KEYTMP
        CPI     'a'
        JC      KEYUP
        CPI     'z'+1
        JNC     KEYUP
        SUI     20H
KEYUP:  CPI     09H
        JZ      KTAB
        CPI     05H
        JZ      KUP
        CPI     18H
        JZ      KDOWN
        CPI     'W'
        JZ      KUP
        CPI     'S'
        JZ      KDOWN
        CPI     ' '
        JZ      KMARK
        CPI     'C'
        JZ      KCOPY
        CPI     'D'
        JZ      KDEL
        CPI     'R'
        JZ      KREN
        CPI     'V'
        JZ      KDRIVE
        CPI     'H'
        JZ      KHELP
        CPI     'Q'
        JZ      KQUIT
        JMP     KEYLOOP

KTAB:   LDA     ACTIVE
        XRI     1
        STA     ACTIVE
        CALL    SETL
        CALL    DRAWHDR
        CALL    DRAWCUR
        CALL    SETR
        CALL    DRAWHDR
        CALL    DRAWCUR
        JMP     KEYLOOP

KUP:    CALL    SAVENAV
        CALL    MOVEUP
        CALL    NAVDRAW
        JMP     KEYLOOP

KDOWN:  CALL    SAVENAV
        CALL    MOVEDOWN
        CALL    NAVDRAW
        JMP     KEYLOOP

KMARK:  CALL    MARKFILE
        CALL    REDRAWC
        JMP     KEYLOOP

KCOPY:  CALL    COPYFILES
        JMP     KEYLOOP

KDEL:
        CALL    DELFILES
        JMP     KEYLOOP

KREN:
        CALL    RENFILE
        JMP     KEYLOOP

KDRIVE:CALL    PICKDRIVE
        JMP     MAIN

KHELP: CALL    SHOWHELP
        CALL    GETKEY
        JMP     MAIN

KQUIT:  CALL    CURSON
        MVI     A,0CH
        CALL    PUTC
        LXI     H,BYEMSG
        CALL    PRINTZ
        JMP     0000H

; ---------------------------------------------------------------------------
; Directory loading

LOADL:  LDA     LDRIVE
        CALL    ENSUREDR
        LXI     H,LFILES
        SHLD    STOREPTR
        LXI     H,LCOUNT
        SHLD    CNTPTR
        CALL    COPYPANEL
        CALL    NORML
        RET

LOADR:  LDA     RDRIVE
        CALL    ENSUREDR
        LXI     H,RFILES
        SHLD    STOREPTR
        LXI     H,RCOUNT
        SHLD    CNTPTR
        CALL    COPYPANEL
        CALL    NORMR
        RET

; Each drive owns one compact filename/size catalog. Panels copy that catalog
; into their working arrays so marks remain independent when both panels show
; the same drive. A catalog is populated by one raw directory scan and reused
; until P2FILE changes the drive or removable media is explicitly selected.
INITCACHE:
        LXI     H,DVALID
        MVI     B,12
        XRA     A
ICZERO: MOV     M,A
        INX     H
        DCR     B
        JNZ     ICZERO
        RET

; A is the CP/M drive number, 1 through 6. Return with CACHEPTR and CACHECOUNT
; selecting its compact catalog, loading it from disk only when invalid.
ENSUREDR:
        STA     CACHEDRV
        DCR     A
        STA     CACHEIDX
        LXI     H,DCACHES
        ORA     A
        JZ      EDCBASE
        MOV     B,A
        LXI     D,CACHEBY
EDCADV: DAD     D
        DCR     B
        JNZ     EDCADV
EDCBASE:SHLD    CACHEPTR
        LDA     CACHEIDX
        MOV     E,A
        MVI     D,0
        LXI     H,DVALID
        DAD     D
        MOV     A,M
        ORA     A
        CZ      SCANDIR
        LDA     CACHEIDX
        MOV     E,A
        MVI     D,0
        LXI     H,DCOUNTS
        DAD     D
        MOV     A,M
        STA     CACHECOUNT
        RET

; Invalidate the compact catalog for drive A (1 through 6).
INVALIDATE:
        DCR     A
        MOV     E,A
        MVI     D,0
        LXI     H,DVALID
        DAD     D
        MVI     M,0
        RET

; Scan every raw directory entry exactly once. Drive '?' asks documented CP/M
; Search First/Next to return allocated, free, and all-user entries from the
; already selected default drive. Only the current user's allocated entries
; are aggregated. HASHBUF maps filenames to compact catalog indices.
SCANDIR:
        XRA     A
        STA     CACHECOUNT
        LXI     H,HASHBUF
        MVI     B,0
SDHASH: MOV     M,A
        INX     H
        DCR     B
        JNZ     SDHASH
        MVI     E,0FFH
        MVI     C,USERNO
        CALL    BDOS
        STA     CURUSER
        MVI     C,CURDSK
        CALL    BDOS
        STA     OLDDISK
        LDA     CACHEDRV
        DCR     A
        MOV     E,A
        MVI     C,SELDSK
        CALL    BDOS
        LXI     D,DIRBUF
        MVI     C,SETDMA
        CALL    BDOS
        LXI     H,SRCHFCB
        CALL    CLEAR36
        MVI     A,'?'
        STA     SRCHFCB
        LXI     D,SRCHFCB
        MVI     C,SFIRST
        CALL    BDOS
SDLOOP: CPI     0FFH
        JZ      SDDONE
        ANI     03H
        RLC
        RLC
        RLC
        RLC
        RLC
        MOV     E,A
        MVI     D,0
        LXI     H,DIRBUF
        DAD     D
        SHLD    RAWPTR
        MOV     A,M
        MOV     B,A
        LDA     CURUSER
        CMP     B
        JNZ     SDNEXT
        CALL    CACHEENT
SDNEXT:
        LXI     D,SRCHFCB
        MVI     C,SNEXT
        CALL    BDOS
        JMP     SDLOOP
SDDONE:LDA     OLDDISK
        MOV     E,A
        MVI     C,SELDSK
        CALL    BDOS
        LDA     CACHEIDX
        MOV     E,A
        MVI     D,0
        LXI     H,DCOUNTS
        DAD     D
        LDA     CACHECOUNT
        MOV     M,A
        LDA     CACHEIDX
        MOV     E,A
        MVI     D,0
        LXI     H,DVALID
        DAD     D
        MVI     M,1
        RET

; Hash and aggregate the raw directory entry at RAWPTR.
CACHEENT:
        LHLD    RAWPTR
        INX     H
        MVI     B,11
        MVI     C,0
CEHASH: MOV     A,M
        ANI     7FH
        ADD     C
        MOV     C,A
        INX     H
        DCR     B
        JNZ     CEHASH
        MOV     A,C
        STA     HASHIDX
CEPROBE:
        LDA     HASHIDX
        MOV     E,A
        MVI     D,0
        LXI     H,HASHBUF
        DAD     D
        MOV     A,M
        ORA     A
        JZ      CENEW
        DCR     A
        CALL    CENTRY
        SHLD    MATCHPTR
        XCHG
        LHLD    RAWPTR
        INX     H
        MVI     B,11
CECMP:  MOV     A,M
        ANI     7FH
        MOV     C,A
        LDAX    D
        CMP     C
        JNZ     CECOLL
        INX     H
        INX     D
        DCR     B
        JNZ     CECMP
        LHLD    MATCHPTR
        LXI     D,11
        DAD     D
        JMP     CEUPD
CECOLL: LDA     HASHIDX
        INR     A
        STA     HASHIDX
        JMP     CEPROBE
CENEW: LDA     CACHECOUNT
        CPI     MAXFILE
        RZ
        MOV     B,A
        CALL    CENTRY
        XCHG
        LHLD    RAWPTR
        INX     H
        MVI     C,11
CECOPY: MOV     A,M
        ANI     7FH
        STAX    D
        INX     H
        INX     D
        DCR     C
        JNZ     CECOPY
        XRA     A
        STAX    D
        INX     D
        STAX    D
        INX     D
        STAX    D
        MOV     H,D
        MOV     L,E
        DCX     H
        DCX     H
        LDA     CACHECOUNT
        INR     A
        STA     CACHECOUNT
        MOV     C,A
        LDA     HASHIDX
        MOV     E,A
        MVI     D,0
        PUSH    H
        LXI     H,HASHBUF
        DAD     D
        MOV     M,C
        POP     H
CEUPD:  SHLD    MATCHPTR
        CALL    CALCSIZE
        LHLD    MATCHPTR
        INX     H
        INX     H
        LDA     CANDHI
        CMP     M
        JC      CENKEEP
        JNZ     CESTORE2
        DCX     H
        LDA     CANDMID
        CMP     M
        JC      CENKEEP
        JNZ     CESTORE1
        DCX     H
        LDA     CANDLOW
        CMP     M
        JC      CENKEEP
        JMP     CESTORE0
CESTORE2:
        DCX     H
CESTORE1:
        DCX     H
CESTORE0:
        LDA     CANDLOW
        MOV     M,A
        INX     H
        LDA     CANDMID
        MOV     M,A
        INX     H
        LDA     CANDHI
        MOV     M,A
CENKEEP:RET

; Convert EX/S2/RC in RAWPTR to the three-byte virtual ending record.
CALCSIZE:
        LHLD    RAWPTR
        LXI     D,15
        DAD     D
        MOV     C,M
        LHLD    RAWPTR
        LXI     D,12
        DAD     D
        MOV     A,M
        STA     EXTEMP
        RRC
        ANI     80H
        ADD     C
        MOV     C,A
        MVI     B,0
        MVI     A,0
        ADC     B
        MOV     B,A
        LDA     EXTEMP
        RRC
        ANI     0FH
        ADD     B
        MOV     B,A
        LHLD    RAWPTR
        LXI     D,14
        DAD     D
        MOV     A,M
        ANI     0FH
        RLC
        RLC
        RLC
        RLC
        ADD     B
        MOV     B,A
        MVI     A,0
        ACI     0
        STA     CANDHI
        MOV     A,B
        STA     CANDMID
        MOV     A,C
        STA     CANDLOW
        RET

; A is a compact-catalog index. Return CACHEPTR + A*CENTSIZ in HL.
CENTRY: LHLD    CACHEPTR
        ORA     A
        RZ
        MOV     B,A
        LXI     D,CENTSIZ
CEADV:  DAD     D
        DCR     B
        JNZ     CEADV
        RET

; Copy the selected compact catalog to a panel working array, clearing marks.
COPYPANEL:
        LHLD    CNTPTR
        LDA     CACHECOUNT
        MOV     M,A
        STA     COPYLEFT
        LHLD    CACHEPTR
        SHLD    COPYSRCP
CPNLOOP:LDA     COPYLEFT
        ORA     A
        RZ
        LHLD    COPYSRCP
        XCHG
        LHLD    STOREPTR
        MVI     B,11
CPNNAME:LDAX    D
        MOV     M,A
        INX     D
        INX     H
        DCR     B
        JNZ     CPNNAME
        MVI     M,0
        INX     H
        MVI     B,3
CPNSIZE:LDAX    D
        MOV     M,A
        INX     D
        INX     H
        DCR     B
        JNZ     CPNSIZE
        SHLD    STOREPTR
        XCHG
        SHLD    COPYSRCP
        LDA     COPYLEFT
        DCR     A
        STA     COPYLEFT
        JMP     CPNLOOP

NORML:  LDA     LCOUNT
        MOV     B,A
        LDA     LCUR
        CALL    NORM
        STA     LCUR
        CPI     ROWS
        JC      NORMZL
        SUI     ROWS-1
        JMP     NORMSL
NORMZL: XRA     A
NORMSL:
        STA     LTOP
        RET

NORMR:  LDA     RCOUNT
        MOV     B,A
        LDA     RCUR
        CALL    NORM
        STA     RCUR
        CPI     ROWS
        JC      NORMZR
        SUI     ROWS-1
        JMP     NORMSR
NORMZR: XRA     A
NORMSR:
        STA     RTOP
        RET

NORM:   MOV     C,A
        MOV     A,B
        ORA     A
        JZ      NORMZERO
        MOV     A,C
        CMP     B
        RC
        MOV     A,B
        DCR     A
        RET
NORMZERO:
        XRA     A
        RET

; ---------------------------------------------------------------------------
; Screen drawing

DRAW:   CALL    DRAWSHELL
        RET

DRAWSHELL:
        MVI     A,NORMATT
        CALL    SETATTR
        MVI     A,0CH
        CALL    PUTC
        CALL    DRAWL
        CALL    DRAWR
        CALL    DRAWFOOT
        RET

DRAWFOOT:
        MVI     B,22
        MVI     C,0
        CALL    POS
        MVI     A,INVATT
        CALL    SETATTR
        CALL    CLEAR79
        MVI     B,22
        MVI     C,1
        CALL    POS
        LXI     H,MENU1
        CALL    PRINTZ
        MVI     B,23
        MVI     C,0
        CALL    POS
        CALL    CLEAR79
        MVI     B,23
        MVI     C,1
        CALL    POS
        LXI     H,MENU2
        CALL    PRINTZ
        MVI     B,23
        MVI     C,65
        CALL    POS
        LXI     H,APPNAME
        CALL    PRINTZ
        MVI     A,NORMATT
        CALL    SETATTR
        XRA     A
        STA     FOOTMSG
        RET

CLEAR79:
        MVI     D,79
CFLOOP: MVI     A,' '
        CALL    PUTC
        DCR     D
        JNZ     CFLOOP
        RET

SHOWHELP:
        MVI     A,NORMATT
        CALL    SETATTR
        MVI     A,0CH
        CALL    PUTC
        MVI     B,0
        MVI     C,0
        CALL    POS
        MVI     A,INVATT
        CALL    SETATTR
        CALL    CLEAR79
        MVI     B,0
        MVI     C,2
        CALL    POS
        LXI     H,HELPHEAD
        CALL    PRINTZ
        MVI     B,0
        MVI     C,73
        CALL    POS
        LXI     H,SHORTVER
        CALL    PRINTZ
        MVI     A,NORMATT
        CALL    SETATTR
        MVI     B,2
        MVI     C,4
        CALL    POS
        LXI     H,HELPDESC
        CALL    PRINTZ
        MVI     B,4
        MVI     C,4
        CALL    POS
        LXI     H,HELPKEYS
        CALL    PRINTZ
        MVI     B,5
        MVI     C,6
        CALL    POS
        LXI     H,HELPK1
        CALL    PRINTZ
        MVI     B,6
        MVI     C,6
        CALL    POS
        LXI     H,HELPK2
        CALL    PRINTZ
        MVI     B,7
        MVI     C,6
        CALL    POS
        LXI     H,HELPK3
        CALL    PRINTZ
        MVI     B,8
        MVI     C,6
        CALL    POS
        LXI     H,HELPK4
        CALL    PRINTZ
        MVI     B,10
        MVI     C,4
        CALL    POS
        LXI     H,REPOHEAD
        CALL    PRINTZ
        MVI     B,11
        MVI     C,6
        CALL    POS
        LXI     H,REPOURL
        CALL    PRINTZ
        MVI     B,13
        MVI     C,4
        CALL    POS
        LXI     H,LICHEAD
        CALL    PRINTZ
        MVI     B,14
        MVI     C,6
        CALL    POS
        LXI     H,LICTEXT
        CALL    PRINTZ
        MVI     B,15
        MVI     C,6
        CALL    POS
        LXI     H,LICFILE
        CALL    PRINTZ
        MVI     B,22
        MVI     C,0
        CALL    POS
        MVI     A,INVATT
        CALL    SETATTR
        CALL    CLEAR79
        MVI     B,22
        MVI     C,24
        CALL    POS
        LXI     H,HELPBACK
        CALL    PRINTZ
        MVI     B,23
        MVI     C,0
        CALL    POS
        CALL    CLEAR79
        MVI     B,23
        MVI     C,65
        CALL    POS
        LXI     H,APPNAME
        CALL    PRINTZ
        MVI     A,NORMATT
        CALL    SETATTR
        RET

DRAWL:  CALL    SETL
        CALL    DRAWP
        RET

SETL:   XRA     A
        STA     PCOL
        LDA     LDRIVE
        STA     PDRIVE
        LDA     LCOUNT
        STA     PCOUNT
        LDA     LCUR
        STA     PCUR
        LDA     LTOP
        STA     PTOP
        LXI     H,LFILES
        SHLD    PLIST
        LDA     ACTIVE
        XRI     1
        STA     PACTIVE
        RET

DRAWR:  CALL    SETR
        CALL    DRAWP
        RET

SETR:   MVI     A,41
        STA     PCOL
        LDA     RDRIVE
        STA     PDRIVE
        LDA     RCOUNT
        STA     PCOUNT
        LDA     RCUR
        STA     PCUR
        LDA     RTOP
        STA     PTOP
        LXI     H,RFILES
        SHLD    PLIST
        LDA     ACTIVE
        STA     PACTIVE
        RET

DRAWP:  CALL    DRAWHDR
        CALL    DRAWROWS
        RET

DRAWHDR:
        MVI     A,INVATT
        STA     LINEATT
        MVI     B,0
        LDA     PCOL
        MOV     C,A
        CALL    POS
        LDA     LINEATT
        CALL    SETATTR
        MVI     B,39
DPHCLR: MVI     A,' '
        CALL    PUTC
        DCR     B
        JNZ     DPHCLR
        MVI     B,0
        LDA     PCOL
        MOV     C,A
        CALL    POS
        LDA     PACTIVE
        ORA     A
        MVI     A,' '
        JZ      DPHMARK
        MVI     A,'*'
DPHMARK:CALL    PUTC
        LXI     H,DRIVEMSG
        CALL    PRINTZ
        LDA     PDRIVE
        ADI     'A'-1
        CALL    PUTC
        MVI     A,':'
        CALL    PUTC
        MVI     A,' '
        CALL    PUTC
        MVI     A,' '
        CALL    PUTC
        LDA     PCOUNT
        CALL    PRINT3
        LXI     H,FILEMSG
        CALL    PRINTZ
        LDA     PCOUNT
        ORA     A
        JZ      DPHPOS
        LDA     PCUR
        INR     A
DPHPOS: CALL    PRINT3
        MVI     A,'/'
        CALL    PUTC
        LDA     PCOUNT
        CALL    PRINT3
        MVI     A,' '
        CALL    PUTC
        LDA     PTOP
        ORA     A
        MVI     A,' '
        JZ      DPHUP
        MVI     A,'^'
DPHUP:  CALL    PUTC
        LDA     PTOP
        ADI     ROWS
        MOV     B,A
        LDA     PCOUNT
        CMP     B
        MVI     A,' '
        JC      DPHDOWN
        JZ      DPHDOWN
        MVI     A,'v'
DPHDOWN:CALL    PUTC
        LDA     PCOL
        ORA     A
        JZ      DPHNOVER
        MVI     B,0
        MVI     C,74
        CALL    POS
        LXI     H,TOPVER
        CALL    PRINTZ
DPHNOVER:
        MVI     A,NORMATT
        CALL    SETATTR
        RET

DRAWROWS:
        LDA     PTOP
        STA     DRAWIDX
        MVI     A,FIRST
        STA     DRAWROW
        MVI     A,ROWS
        STA     DRAWLEFT
DPLOOP: LDA     DRAWROW
        CALL    DRAWLINE
        LDA     DRAWIDX
        INR     A
        STA     DRAWIDX
        LDA     DRAWROW
        INR     A
        STA     DRAWROW
        LDA     DRAWLEFT
        DCR     A
        STA     DRAWLEFT
        JNZ     DPLOOP
        RET

DRAWLINE:
        LDA     DRAWIDX
        STA     LINEIDX
        MOV     D,A
        LDA     PCOUNT
        CMP     D
        MVI     A,0
        JC      DLVALID
        JZ      DLVALID
        MVI     A,1
DLVALID:STA     LINEOK
        MVI     A,NORMATT
        STA     LINEATT
        LDA     LINEOK
        ORA     A
        JZ      DLATTR
        LDA     PACTIVE
        ORA     A
        JZ      DLATTR
        LDA     PCUR
        MOV     D,A
        LDA     LINEIDX
        CMP     D
        JNZ     DLATTR
        MVI     A,INVATT
        STA     LINEATT
DLATTR: LDA     DRAWROW
        MOV     B,A
        LDA     PCOL
        MOV     C,A
        CALL    POS
        LDA     LINEATT
        CALL    SETATTR
        MVI     B,39
DLBLANK:MVI     A,' '
        CALL    PUTC
        DCR     B
        JNZ     DLBLANK
        LDA     LINEOK
        ORA     A
        JZ      DLNORM
        LDA     DRAWROW
        MOV     B,A
        LDA     PCOL
        MOV     C,A
        CALL    POS
        LDA     LINEIDX
        MOV     D,A
        LDA     PACTIVE
        ORA     A
        JZ      DLNOCUR
        LDA     PCUR
        CMP     D
        MVI     A,' '
        JNZ     DLCURS
        MVI     A,'>'
        JMP     DLCURS
DLNOCUR:MVI     A,' '
DLCURS: CALL    PUTC
        LDA     LINEIDX
        CALL    PENTRY
        PUSH    H
        LXI     D,11
        DAD     D
        MOV     A,M
        ORA     A
        MVI     A,' '
        JZ      DLSEL
        MVI     A,'*'
DLSEL:  CALL    PUTC
        MVI     A,' '
        CALL    PUTC
        POP     H
        PUSH    H
        CALL    PRINTNAME
        POP     H
        MVI     A,' '
        CALL    PUTC
        PUSH    H
        LXI     D,14
        DAD     D
        MOV     A,M
        CPI     0FFH
        JZ      DLUNKSZ
        DCX     H
        DCX     H
        MOV     E,M
        INX     H
        MOV     D,M
        XCHG
        LXI     D,7
        DAD     D
        CALL    HALF
        CALL    HALF
        CALL    HALF
        CALL    PRINT5
        JMP     DLSIZED
DLUNKSZ:
        LXI     H,UNKSIZE
        CALL    PRINTZ
DLSIZED:
        MVI     A,'K'
        CALL    PUTC
        POP     H
DLNORM: MVI     A,NORMATT
        CALL    SETATTR
        RET

PENTRY: LHLD    PLIST
ENTRYA: ORA     A
        RZ
        LXI     D,ENTSIZ
ENTLOOP:DAD     D
        DCR     A
        JNZ     ENTLOOP
        RET

PRINTNAME:
        MVI     B,8
PNBASE: MOV     A,M
        CALL    PUTC
        INX     H
        DCR     B
        JNZ     PNBASE
        MVI     A,'.'
        CALL    PUTC
        MVI     B,3
PNEXT:  MOV     A,M
        CALL    PUTC
        INX     H
        DCR     B
        JNZ     PNEXT
        RET

PRINT3: MOV     L,A
        MVI     H,0
        XRA     A
        STA     LEAD
        LXI     D,100
        CALL    PDIV
        LXI     D,10
        CALL    PDIV
        MOV     A,L
        ADI     '0'
        CALL    PUTC
        RET

PRINT5: XRA     A
        STA     LEAD
        LXI     D,10000
        CALL    PDIV
        LXI     D,1000
        CALL    PDIV
        LXI     D,100
        CALL    PDIV
        LXI     D,10
        CALL    PDIV
        MOV     A,L
        ADI     '0'
        CALL    PUTC
        RET

PDIV:   MVI     B,0
PDLOOP: MOV     A,H
        CMP     D
        JC      PDDONE
        JNZ     PDSUB
        MOV     A,L
        CMP     E
        JC      PDDONE
PDSUB:  MOV     A,L
        SUB     E
        MOV     L,A
        MOV     A,H
        SBB     D
        MOV     H,A
        INR     B
        JMP     PDLOOP
PDDONE: MOV     A,B
        ORA     A
        JNZ     PDNUM
        LDA     LEAD
        ORA     A
        MVI     A,' '
        JZ      PDOUT
        MVI     A,'0'
        JMP     PDOUT
PDNUM:  MVI     A,1
        STA     LEAD
        MOV     A,B
        ADI     '0'
PDOUT:  CALL    PUTC
        RET

HALF:   ORA     A
        MOV     A,H
        RAR
        MOV     H,A
        MOV     A,L
        RAR
        MOV     L,A
        RET

SETATTR:MOV     B,A
        MVI     A,1BH
        CALL    PUTC
        MVI     A,'0'
        CALL    PUTC
        MOV     A,B
        CALL    PUTC
        RET

POS:    PUSH    B
        MVI     A,1BH
        CALL    PUTC
        MVI     A,'Y'
        CALL    PUTC
        POP     B
        MOV     A,B
        ADI     20H
        CALL    PUTC
        MOV     A,C
        ADI     20H
        CALL    PUTC
        RET

STATUS: PUSH    H
        MVI     B,23
        MVI     C,0
        CALL    POS
        MVI     A,INVATT
        CALL    SETATTR
        MVI     D,64
STCLEAR:MVI     A,' '
        CALL    PUTC
        DCR     D
        JNZ     STCLEAR
        MVI     B,23
        MVI     C,1
        CALL    POS
        POP     H
        CALL    PRINTZ
        MVI     A,NORMATT
        CALL    SETATTR
        MVI     A,1
        STA     FOOTMSG
        RET

; ---------------------------------------------------------------------------
; Navigation and marking

SAVENAV:LDA     ACTIVE
        ORA     A
        JNZ     SAVER
        LDA     LCUR
        STA     OLDCUR
        LDA     LTOP
        STA     OLDTOP
        RET
SAVER:  LDA     RCUR
        STA     OLDCUR
        LDA     RTOP
        STA     OLDTOP
        RET

NAVDRAW:LDA     ACTIVE
        ORA     A
        JNZ     NAVR
        CALL    SETL
        JMP     NAVSET
NAVR:   CALL    SETR
NAVSET: LDA     PCUR
        MOV     B,A
        LDA     OLDCUR
        CMP     B
        JNZ     NAVCHG
        LDA     PTOP
        MOV     B,A
        LDA     OLDTOP
        CMP     B
        RZ
NAVCHG:CALL    DRAWHDR
        LDA     PTOP
        MOV     B,A
        LDA     OLDTOP
        CMP     B
        JZ      NAVROWS
        CALL    DRAWROWS
        RET
NAVROWS:
        LDA     OLDCUR
        STA     DRAWIDX
        MOV     B,A
        LDA     PTOP
        MOV     C,A
        MOV     A,B
        SUB     C
        ADI     FIRST
        STA     DRAWROW
        CALL    DRAWLINE
        LDA     PCUR
        MOV     B,A
        LDA     OLDCUR
        CMP     B
        RZ
        MOV     A,B
        STA     DRAWIDX
        MOV     B,A
        LDA     PTOP
        MOV     C,A
        MOV     A,B
        SUB     C
        ADI     FIRST
        STA     DRAWROW
        CALL    DRAWLINE
        RET

REDRAWC:LDA     ACTIVE
        ORA     A
        JNZ     REDRAWR
        CALL    SETL
        JMP     REDSET
REDRAWR:CALL    SETR
REDSET: CALL    DRAWCUR
        RET

DRAWCUR:LDA     PCOUNT
        ORA     A
        RZ
        LDA     PCUR
        STA     DRAWIDX
        MOV     B,A
        LDA     PTOP
        MOV     C,A
        MOV     A,B
        SUB     C
        ADI     FIRST
        STA     DRAWROW
        CALL    DRAWLINE
        RET

MOVEUP: LDA     ACTIVE
        ORA     A
        JNZ     RUP
        LDA     LCUR
        ORA     A
        RZ
        DCR     A
        STA     LCUR
        MOV     B,A
        LDA     LTOP
        MOV     C,A
        MOV     A,B
        CMP     C
        RNC
        STA     LTOP
        RET
RUP:    LDA     RCUR
        ORA     A
        RZ
        DCR     A
        STA     RCUR
        MOV     B,A
        LDA     RTOP
        MOV     C,A
        MOV     A,B
        CMP     C
        RNC
        STA     RTOP
        RET

MOVEDOWN:
        LDA     ACTIVE
        ORA     A
        JNZ     RDOWN
        LDA     LCOUNT
        MOV     B,A
        LDA     LCUR
        INR     A
        CMP     B
        RNC
        STA     LCUR
        MOV     B,A
        LDA     LTOP
        ADI     ROWS
        CMP     B
        JC      LDSCROLL
        JZ      LDSCROLL
        RET
LDSCROLL:
        LDA     LTOP
        INR     A
        STA     LTOP
        RET
RDOWN:  LDA     RCOUNT
        MOV     B,A
        LDA     RCUR
        INR     A
        CMP     B
        RNC
        STA     RCUR
        MOV     B,A
        LDA     RTOP
        ADI     ROWS
        CMP     B
        JC      RDSCROLL
        JZ      RDSCROLL
        RET
RDSCROLL:
        LDA     RTOP
        INR     A
        STA     RTOP
        RET

MARKFILE:
        LDA     ACTIVE
        ORA     A
        JNZ     RMARK
        LDA     LCOUNT
        ORA     A
        RZ
        LDA     LCUR
        LXI     H,LFILES
        JMP     DOMARK
RMARK:  LDA     RCOUNT
        ORA     A
        RZ
        LDA     RCUR
        LXI     H,RFILES
DOMARK: SHLD    WORKLIST
        CALL    WENTRY
        LXI     D,11
        DAD     D
        MOV     A,M
        XRI     1
        MOV     M,A
        RET

WENTRY: LHLD    WORKLIST
        JMP     ENTRYA

PICKDRIVE:
        CALL    SHOWDRIVES
PDKEY:  CALL    GETKEY
        CPI     1BH
        RZ
        CPI     'a'
        JC      PDUP
        CPI     'z'+1
        JNC     PDUP
        SUI     20H
PDUP:   CPI     'A'
        JC      PDKEY
        CPI     'G'
        JNC     PDKEY
        SUI     'A'-1
        MOV     B,A
        PUSH    B
        CALL    SHOWREAD
        POP     B
        MOV     A,B
        CPI     3
        JNC     PDCACHED
        PUSH    B
        CALL    INVALIDATE
        POP     B
PDCACHED:
        LDA     ACTIVE
        ORA     A
        JNZ     PDRIGHT
        MOV     A,B
        STA     LDRIVE
        CALL    LOADL
        RET
PDRIGHT:MOV     A,B
        STA     RDRIVE
        CALL    LOADR
        RET

SHOWDRIVES:
        CALL    MODBOX
        MVI     B,9
        MVI     C,34
        CALL    POS
        LXI     H,DRVHEAD
        CALL    PRINTZ
        MVI     B,10
        MVI     C,29
        CALL    POS
        LXI     H,DRVOPTS
        CALL    PRINTZ
        MVI     B,11
        MVI     C,27
        CALL    POS
        LXI     H,DRVPROMPT
        CALL    PRINTZ
        MVI     B,12
        MVI     C,26
        CALL    POS
        LXI     H,DRVREADY
        CALL    PRINTZ
        MVI     A,NORMATT
        CALL    SETATTR
        RET

; ---------------------------------------------------------------------------
; Copy

COPYFILES:
        CALL    SETSOURCE
        LDA     SRCDRIVE
        MOV     B,A
        LDA     DSTDRIVE
        CMP     B
        JNZ     CPDIFF
        LXI     H,SAMEDRV
        CALL    STATUS
        RET
CPDIFF:
        LDA     SCOUNT
        ORA     A
        JNZ     CPHAVE
        LXI     H,NOFILES
        CALL    STATUS
        RET
CPHAVE: CALL    FINDSEL
        STA     SELMODE
        CALL    COUNTCP
        XRA     A
        STA     OPERROR
        STA     LOOPIDX
        STA     CPNUM
CPLOOP: LDA     LOOPIDX
        MOV     B,A
        LDA     SCOUNT
        CMP     B
        JZ      CPDONE
        LDA     SELMODE
        ORA     A
        JZ      CPCUR
        MOV     A,B
        CALL    SENTRY
        LXI     D,11
        DAD     D
        MOV     A,M
        ORA     A
        JZ      CPNEXT
        JMP     CPONE
CPCUR:  LDA     SCUR
        CMP     B
        JNZ     CPNEXT
CPONE:  MOV     A,B
        CALL    SENTRY
        SHLD    ENTRYPTR
        LDA     CPNUM
        INR     A
        STA     CPNUM
        CALL    PREPCOPY
        CALL    SHOWCOPY
        CALL    COPYONE
CPNEXT: LDA     LOOPIDX
        INR     A
        STA     LOOPIDX
        JMP     CPLOOP
CPDONE: LDA     DSTDRIVE
        CALL    INVALIDATE
        CALL    LOADL
        CALL    LOADR
        CALL    DRAW
        LDA     OPERROR
        ORA     A
        JNZ     SHOWCPERR
        CALL    SHOWCPDONE
        RET

SHOWCPERR:
        CALL    SHOWERROR
        RET

SETSOURCE:
        LDA     ACTIVE
        ORA     A
        JNZ     SRCRIGHT
        LDA     LDRIVE
        STA     SRCDRIVE
        LDA     RDRIVE
        STA     DSTDRIVE
        LDA     LCOUNT
        STA     SCOUNT
        LDA     LCUR
        STA     SCUR
        LXI     H,LFILES
        SHLD    SLIST
        RET
SRCRIGHT:
        LDA     RDRIVE
        STA     SRCDRIVE
        LDA     LDRIVE
        STA     DSTDRIVE
        LDA     RCOUNT
        STA     SCOUNT
        LDA     RCUR
        STA     SCUR
        LXI     H,RFILES
        SHLD    SLIST
        RET

FINDSEL:XRA     A
        STA     LOOPIDX
FSLOOP: LDA     LOOPIDX
        MOV     B,A
        LDA     SCOUNT
        CMP     B
        JZ      FSNONE
        MOV     A,B
        CALL    SENTRY
        LXI     D,11
        DAD     D
        MOV     A,M
        ORA     A
        MVI     A,1
        RNZ
        LDA     LOOPIDX
        INR     A
        STA     LOOPIDX
        JMP     FSLOOP
FSNONE: XRA     A
        RET

COUNTCP:LDA     SELMODE
        ORA     A
        JNZ     CCSEL
        MVI     A,1
        STA     CPTOTAL
        RET
CCSEL:  XRA     A
        STA     CPTOTAL
        STA     LOOPIDX
CCLOOP: LDA     LOOPIDX
        MOV     B,A
        LDA     SCOUNT
        CMP     B
        RZ
        MOV     A,B
        CALL    SENTRY
        LXI     D,11
        DAD     D
        MOV     A,M
        ORA     A
        JZ      CCNEXT
        LDA     CPTOTAL
        INR     A
        STA     CPTOTAL
CCNEXT: LDA     LOOPIDX
        INR     A
        STA     LOOPIDX
        JMP     CCLOOP

SENTRY: LHLD    SLIST
        JMP     ENTRYA

; The compact drive catalog already holds the selected file's exact virtual
; record count. Initialise its individual copy-progress counter from that cache.
PREPCOPY:
        LHLD    ENTRYPTR
        LXI     D,12
        DAD     D
        MOV     E,M
        INX     H
        MOV     D,M
        XCHG
        SHLD    CPTOTREC
        LXI     H,0
        SHLD    CPRECDONE
        RET

COPYONE:
        CALL    BUILDFCBS
        LXI     D,DIRBUF
        MVI     C,SETDMA
        CALL    BDOS
        LXI     D,DSTFCB
        MVI     C,SFIRST
        CALL    BDOS
        CPI     0FFH
        JZ      CPNEW
        CALL    ASKOVER
        ORA     A
        RZ
        CALL    BUILDFCBS
        LXI     D,DSTFCB
        MVI     C,DELETE
        CALL    BDOS
CPNEW:  CALL    BUILDFCBS
        LXI     D,SRCFCB
        MVI     C,OPENF
        CALL    BDOS
        CPI     0FFH
        JZ      CPFAIL
        LXI     D,DSTFCB
        MVI     C,MAKEF
        CALL    BDOS
        CPI     0FFH
        JZ      CPMKERR
CPBATCH:
        LXI     H,BUFFER
        SHLD    CPBUFPTR
        MVI     A,CPBUFR
        STA     CPBLEFT
        XRA     A
        STA     CPBCOUNT
        STA     CPEOF
CPREAD:
        LHLD    CPBUFPTR
        XCHG
        MVI     C,SETDMA
        CALL    BDOS
        LXI     D,SRCFCB
        MVI     C,READSEQ
        CALL    BDOS
        ORA     A
        JNZ     CPREADEOF
        LDA     CPBCOUNT
        INR     A
        STA     CPBCOUNT
        LHLD    CPBUFPTR
        LXI     D,128
        DAD     D
        SHLD    CPBUFPTR
        LDA     CPBLEFT
        DCR     A
        STA     CPBLEFT
        JNZ     CPREAD
        JMP     CPWRITESET
CPREADEOF:
        MVI     A,1
        STA     CPEOF
CPWRITESET:
        LDA     CPBCOUNT
        ORA     A
        JZ      CPRDEOF
        STA     CPBLEFT
        LXI     H,BUFFER
        SHLD    CPBUFPTR
CPWRITE:
        LHLD    CPBUFPTR
        XCHG
        MVI     C,SETDMA
        CALL    BDOS
        LXI     D,DSTFCB
        MVI     C,WRITSEQ
        CALL    BDOS
        ORA     A
        JNZ     CPWRERR
        LHLD    CPRECDONE
        INX     H
        SHLD    CPRECDONE
        LHLD    CPBUFPTR
        LXI     D,128
        DAD     D
        SHLD    CPBUFPTR
        LDA     CPBLEFT
        DCR     A
        STA     CPBLEFT
        JNZ     CPWRITE
        CALL    SHOWFILEPROG
        LDA     CPEOF
        ORA     A
        JNZ     CPCLOSE
        JMP     CPBATCH
CPWRERR:
        MVI     A,1
        STA     OPERROR
        JMP     CPCLOSE
CPRDEOF:
        CALL    SHOWFILEPROG
CPCLOSE:LXI     D,DSTFCB
        MVI     C,CLOSEF
        CALL    BDOS
        LXI     D,SRCFCB
        MVI     C,CLOSEF
        CALL    BDOS
        RET
CPMKERR:LXI     D,SRCFCB
        MVI     C,CLOSEF
        CALL    BDOS
CPFAIL: MVI     A,1
        STA     OPERROR
        RET

ASKOVER:CALL    MODBOX
        MVI     B,10
        MVI     C,22
        CALL    POS
        LXI     H,OVER1
        CALL    PRINTZ
        LHLD    ENTRYPTR
        CALL    PRINTSHORT
        LXI     H,OVER2
        CALL    PRINTZ
        MVI     A,NORMATT
        CALL    SETATTR
OVKEY:  CALL    GETKEY
        CPI     'a'
        JC      OVUP
        CPI     'z'+1
        JNC     OVUP
        SUI     20H
OVUP:   CPI     'Y'
        JZ      OVYES
        CPI     'N'
        JNZ     OVKEY
        XRA     A
        RET
OVYES:  CALL    SHOWCOPY
        MVI     A,1
        RET

; Four-row inverse-video copy modal. It deliberately stays clear of rows
; 22-23, so the two-row keyboard legend remains visible during the operation.
MODBOX: MVI     B,9
MBLOOP:CALL    MODROW
        INR     B
        MOV     A,B
        CPI     13
        JNZ     MBLOOP
        RET

MODROW:MOV     A,B
        STA     MODROWNO
        MVI     C,20
        CALL    POS
        MVI     A,INVATT
        CALL    SETATTR
        MVI     D,40
MRCLEAR:MVI     A,' '
        CALL    PUTC
        DCR     D
        JNZ     MRCLEAR
        LDA     MODROWNO
        MOV     B,A
        MVI     C,20
        CALL    POS
        RET

SHOWCOPY:
        CALL    MODBOX
        MVI     B,9
        MVI     C,32
        CALL    POS
        LXI     H,CPHEAD
        CALL    PRINTZ
        MVI     B,10
        MVI     C,22
        CALL    POS
        LXI     H,CPFILE
        CALL    PRINTZ
        LHLD    ENTRYPTR
        CALL    PRINTSHORT
        MVI     B,11
        MVI     C,29
        CALL    POS
        LXI     H,CPSTEP
        CALL    PRINTZ
        LDA     CPNUM
        CALL    PRINT3
        LXI     H,CPOF
        CALL    PRINTZ
        LDA     CPTOTAL
        CALL    PRINT3
        CALL    SHOWFILEPROG
        MVI     A,NORMATT
        CALL    SETATTR
        RET

SHOWFILEPROG:
        MVI     B,12
        MVI     C,29
        CALL    POS
        LXI     H,CPRECS
        CALL    PRINTZ
        LHLD    CPRECDONE
        CALL    PRINT5
        MVI     A,'/'
        CALL    PUTC
        LHLD    CPTOTREC
        CALL    PRINT5
        RET

SHOWCPDONE:
        CALL    MODBOX
        MVI     B,10
        MVI     C,33
        CALL    POS
        LXI     H,COPYOK
        CALL    PRINTZ
        JMP     SHOWACK

SHOWERROR:
        CALL    MODBOX
        MVI     B,10
        MVI     C,25
        CALL    POS
        LXI     H,COPYERR
        CALL    PRINTZ
SHOWACK:MVI     B,11
        MVI     C,31
        CALL    POS
        LXI     H,CPACK
        CALL    PRINTZ
        MVI     A,NORMATT
        CALL    SETATTR
        MVI     A,1
        STA     MODAL
        RET

BUILDFCBS:
        LXI     H,SRCFCB
        CALL    CLEAR36
        LXI     H,DSTFCB
        CALL    CLEAR36
        LDA     SRCDRIVE
        STA     SRCFCB
        LDA     DSTDRIVE
        STA     DSTFCB
        LHLD    ENTRYPTR
        XCHG
        LXI     H,SRCFCB+1
        MVI     B,11
BFSRC:  LDAX    D
        MOV     M,A
        INX     D
        INX     H
        DCR     B
        JNZ     BFSRC
        LHLD    ENTRYPTR
        XCHG
        LXI     H,DSTFCB+1
        MVI     B,11
BFDST:  LDAX    D
        MOV     M,A
        INX     D
        INX     H
        DCR     B
        JNZ     BFDST
        RET

; ---------------------------------------------------------------------------
; Delete

DELFILES:
        CALL    SETSOURCE
        LDA     SCOUNT
        ORA     A
        JNZ     DELHAVE
        LXI     H,NOFILES
        CALL    STATUS
        RET
DELHAVE:CALL    FINDSEL
        STA     SELMODE
        LXI     H,DELASK
        CALL    STATUS
        CALL    YESNO
        ORA     A
        RZ
        XRA     A
        STA     OPERROR
        STA     LOOPIDX
DELLOOP:LDA     LOOPIDX
        MOV     B,A
        LDA     SCOUNT
        CMP     B
        JZ      DELDONE
        LDA     SELMODE
        ORA     A
        JZ      DELCUR
        MOV     A,B
        CALL    SENTRY
        LXI     D,11
        DAD     D
        MOV     A,M
        ORA     A
        JZ      DELNEXT
        JMP     DELONE
DELCUR: LDA     SCUR
        CMP     B
        JNZ     DELNEXT
DELONE: MOV     A,B
        CALL    SENTRY
        SHLD    ENTRYPTR
        CALL    BUILDSRC
        LXI     D,SRCFCB
        MVI     C,DELETE
        CALL    BDOS
        CPI     0FFH
        JNZ     DELNEXT
        MVI     A,1
        STA     OPERROR
DELNEXT:LDA     LOOPIDX
        INR     A
        STA     LOOPIDX
        JMP     DELLOOP
DELDONE:LDA     SRCDRIVE
        CALL    INVALIDATE
        CALL    LOADL
        CALL    LOADR
        CALL    DRAW
        LDA     OPERROR
        ORA     A
        LXI     H,DELOK
        JZ      DELSTAT
        LXI     H,DELERR
DELSTAT:CALL    STATUS
        RET

BUILDSRC:
        LXI     H,SRCFCB
        CALL    CLEAR36
        LDA     SRCDRIVE
        STA     SRCFCB
        LHLD    ENTRYPTR
        XCHG
        LXI     H,SRCFCB+1
        MVI     B,11
BSONE:  LDAX    D
        MOV     M,A
        INX     D
        INX     H
        DCR     B
        JNZ     BSONE
        RET

; ---------------------------------------------------------------------------
; Rename

RENFILE:LDA     ACTIVE
        ORA     A
        JNZ     RENR
        LDA     LCOUNT
        ORA     A
        JZ      RENNONE
        LDA     LDRIVE
        STA     SRCDRIVE
        LDA     LCUR
        LXI     H,LFILES
        JMP     RENSET
RENR:   LDA     RCOUNT
        ORA     A
        JZ      RENNONE
        LDA     RDRIVE
        STA     SRCDRIVE
        LDA     RCUR
        LXI     H,RFILES
RENSET: SHLD    WORKLIST
        CALL    WENTRY
        SHLD    ENTRYPTR
        CALL    GETNEW
        ORA     A
        RZ
        CALL    NEWEXISTS
        ORA     A
        JZ      RENDO
        LXI     H,NAMEUSED
        CALL    STATUS
        RET
RENDO:  CALL    BUILDREN
        LXI     D,SRCFCB
        MVI     C,RENAME
        CALL    BDOS
        CPI     0FFH
        LXI     H,RENOK
        JNZ     RENRES
        LXI     H,RENERR
RENRES: PUSH    H
        LDA     SRCDRIVE
        CALL    INVALIDATE
        CALL    LOADL
        CALL    LOADR
        CALL    DRAW
        POP     H
        CALL    STATUS
        RET
RENNONE:LXI     H,NOFILES
        CALL    STATUS
        RET

GETNEW: LXI     H,NEWBUF
        MVI     M,0
        SHLD    INPTR
        XRA     A
        STA     INLEN
        LXI     H,NEWASK
        CALL    STATUS
        CALL    CURSON
GNKEY:  CALL    GETKEY
        CPI     1BH
        JZ      GNCANCEL
        CPI     0DH
        JZ      GNDONE
        CPI     08H
        JZ      GNBACK
        CPI     7FH
        JZ      GNBACK
        CPI     'a'
        JC      GNUP
        CPI     'z'+1
        JNC     GNUP
        SUI     20H
GNUP:   CPI     21H
        JC      GNKEY
        CPI     7FH
        JNC     GNKEY
        MOV     B,A
        LDA     INLEN
        CPI     12
        JNC     GNKEY
        MOV     A,B
        LHLD    INPTR
        MOV     M,A
        INX     H
        MVI     M,0
        SHLD    INPTR
        LDA     INLEN
        INR     A
        STA     INLEN
        MOV     A,B
        CALL    PUTC
        JMP     GNKEY
GNBACK: LDA     INLEN
        ORA     A
        JZ      GNKEY
        DCR     A
        STA     INLEN
        LHLD    INPTR
        DCX     H
        SHLD    INPTR
        MVI     M,0
        MVI     A,08H
        CALL    PUTC
        MVI     A,' '
        CALL    PUTC
        MVI     A,08H
        CALL    PUTC
        JMP     GNKEY
GNDONE: CALL    CURSOFF
        CALL    PARSENEW
        RET
GNCANCEL:
        CALL    CURSOFF
        XRA     A
        RET

PARSENEW:
        LXI     H,NEWNAME
        MVI     B,11
        MVI     A,' '
PNCLR:  MOV     M,A
        INX     H
        DCR     B
        JNZ     PNCLR
        LXI     H,NEWBUF
        LXI     D,NEWNAME
        MVI     B,0
        MVI     C,0
PNLOOP: MOV     A,M
        ORA     A
        JZ      PNEND
        CPI     '.'
        JZ      PNDOT
        CPI     '*'
        JZ      PNBAD
        CPI     '?'
        JZ      PNBAD
        CPI     '/'
        JZ      PNBAD
        CPI     ':'
        JZ      PNBAD
        CPI     ';'
        JZ      PNBAD
        CPI     '<'
        JZ      PNBAD
        CPI     '='
        JZ      PNBAD
        CPI     '>'
        JZ      PNBAD
        CPI     '['
        JZ      PNBAD
        CPI     ']'
        JZ      PNBAD
        MOV     A,C
        ORA     A
        JNZ     PNEXTC
        MOV     A,B
        CPI     8
        JNC     PNBAD
        MOV     A,M
        STAX    D
        INX     D
        INR     B
        INX     H
        JMP     PNLOOP
PNEXTC: MOV     A,B
        CPI     3
        JNC     PNBAD
        MOV     A,M
        STAX    D
        INX     D
        INR     B
        INX     H
        JMP     PNLOOP
PNDOT:  MOV     A,C
        ORA     A
        JNZ     PNBAD
        MOV     A,B
        ORA     A
        JZ      PNBAD
        MVI     C,1
        MVI     B,0
        LXI     D,NEWNAME+8
        INX     H
        JMP     PNLOOP
PNEND:  MOV     A,C
        ORA     A
        JZ      PNBCHK
        MOV     A,B
        ORA     A
        JZ      PNBAD
PNBCHK: LDA     NEWNAME
        CPI     ' '
        JZ      PNBAD
        MVI     A,1
        RET
PNBAD:  LXI     H,BADNAME
        CALL    STATUS
        XRA     A
        RET

NEWEXISTS:
        LXI     H,DSTFCB
        CALL    CLEAR36
        LDA     SRCDRIVE
        STA     DSTFCB
        LXI     H,NEWNAME
        LXI     D,DSTFCB+1
        MVI     B,11
NECOPY: MOV     A,M
        STAX    D
        INX     H
        INX     D
        DCR     B
        JNZ     NECOPY
        LXI     D,DIRBUF
        MVI     C,SETDMA
        CALL    BDOS
        LXI     D,DSTFCB
        MVI     C,SFIRST
        CALL    BDOS
        CPI     0FFH
        MVI     A,0
        RZ
        MVI     A,1
        RET

BUILDREN:
        CALL    BUILDSRC
        LDA     SRCDRIVE
        STA     SRCFCB+16
        LXI     H,NEWNAME
        LXI     D,SRCFCB+17
        MVI     B,11
BRCOPY: MOV     A,M
        STAX    D
        INX     H
        INX     D
        DCR     B
        JNZ     BRCOPY
        RET

; ---------------------------------------------------------------------------
; Common helpers

; P2FILE draws its own selection indicator, so the terminal's blinking cursor
; remains hidden while the application is active. Restore it before warm boot.
CURSOFF:MVI     A,1BH
        CALL    PUTC
        MVI     A,'c'
        JMP     PUTC

CURSON: MVI     A,1BH
        CALL    PUTC
        MVI     A,'C'
        JMP     PUTC

YESNO:  CALL    GETKEY
        CPI     'a'
        JC      YNUP
        CPI     'z'+1
        JNC     YNUP
        SUI     20H
YNUP:   CPI     'Y'
        JZ      YNYES
        CPI     'N'
        JNZ     YESNO
        XRA     A
        RET
YNYES:  MVI     A,1
        RET

CLEAR36:MVI     B,36
        XRA     A
C36LOOP:MOV     M,A
        INX     H
        DCR     B
        JNZ     C36LOOP
        RET

PRINTSHORT:
        PUSH    H
        MVI     B,8
PSBASE: MOV     A,M
        CPI     ' '
        CZ      PSNOP
        CNZ     PUTC
        INX     H
        DCR     B
        JNZ     PSBASE
        POP     H
        LXI     D,8
        DAD     D
        MOV     A,M
        CPI     ' '
        RZ
        MVI     A,'.'
        CALL    PUTC
        MVI     B,3
PSEXT:  MOV     A,M
        CPI     ' '
        CZ      PSNOP
        CNZ     PUTC
        INX     H
        DCR     B
        JNZ     PSEXT
PSNOP:  RET

PRINTZ: MOV     A,M
        ORA     A
        RZ
        CALL    PUTC
        INX     H
        JMP     PRINTZ

PUTC:   PUSH    B
        PUSH    D
        PUSH    H
        MOV     E,A
        MVI     C,CONOUT
        CALL    BDOS
        POP     H
        POP     D
        POP     B
        RET

GETKEY: PUSH    B
        PUSH    D
        PUSH    H
GKWAIT: MVI     E,0FFH
        MVI     C,DIRIO
        CALL    BDOS
        ORA     A
        JZ      GKWAIT
        POP     H
        POP     D
        POP     B
        RET

SHOWSTART:
        PUSH    PSW
        MVI     A,0CH
        CALL    PUTC
        LXI     H,STARTMSG
        CALL    PRINTZ
        POP     PSW
        ADI     'A'-1
        CALL    PUTC
        MVI     A,':'
        CALL    PUTC
        LXI     H,WAITMSG
        CALL    PRINTZ
        RET

SHOWREAD:
        PUSH    PSW
        LXI     H,READMSG
        CALL    STATUS
        POP     PSW
        ADI     'A'-1
        CALL    PUTC
        MVI     A,':'
        CALL    PUTC
        RET

; ---------------------------------------------------------------------------
; Data

STARTMSG:
        DB      'P2FILE: READING DRIVE ',0
WAITMSG:DB      ' - PLEASE WAIT',0
READMSG:DB      'P2FILE: READING DRIVE ',0
UNKSIZE:DB      '    ?',0
APPVER: DB      '0.2.0',0
SHORTVER:
        DB      'v0.2.0',0
TOPVER: DB      '0.2.0',0
APPNAME:DB      'P2FILE v0.2.0',0
MENU1:  DB      'TAB PANEL  W/S MOVE  SPACE MARK  C COPY  D DELETE',0
MENU2:  DB      'R RENAME  V DRIVE  H HELP  Q QUIT',0
HELPHEAD:
        DB      'P2FILE HELP',0
HELPDESC:
        DB      'Two-panel file manager for CP/M 2.2 on the Philips P2000C.',0
HELPKEYS:
        DB      'Keyboard',0
HELPK1: DB      'TAB       Switch the active panel',0
HELPK2: DB      'W/S       Move up/down       SPACE     Mark a file',0
HELPK3: DB      'C         Copy               D         Delete',0
HELPK4: DB      'R Rename  V Select drive     H Help    Q Quit',0
REPOHEAD:
        DB      'GitHub repository',0
REPOURL:DB      'https://github.com/ifilot/p2000c-file',0
LICHEAD:DB      'License',0
LICTEXT:DB      'GNU General Public License version 3 (GPL-3.0)',0
LICFILE:DB      'The complete license is in the repository LICENSE file.',0
HELPBACK:
        DB      'PRESS ANY KEY TO RETURN',0
DRIVEMSG:
        DB      ' DRIVE ',0
FILEMSG:DB      ' FILES ',0
DRVHEAD:DB      'SELECT DRIVE',0
DRVOPTS:DB      'A:  B:  C:  D:  E:  F:',0
DRVPROMPT:
        DB      'PRESS A-F OR ESC TO CANCEL',0
DRVREADY:
        DB      'INSERT DISK BEFORE SELECTING',0
BYEMSG: DB      'P2FILE finished.',13,10,0
NOFILES:DB      'No files in the active panel.',0
SAMEDRV:DB      'Choose two different drives before copying.',0
COPYOK: DB      'Copy complete.',0
COPYERR:DB      'Copy finished with a disk error.',0
CPHEAD: DB      'COPYING FILES',0
CPFILE: DB      'FILE: ',0
CPSTEP: DB      'FILE ',0
CPOF:   DB      ' OF ',0
CPRECS: DB      'RECORDS ',0
CPACK:  DB      'PRESS A KEY TO CONTINUE',0
OVER1:  DB      'Overwrite ',0
OVER2:  DB      '? (Y/N)',0
DELASK: DB      'Delete selected file(s)? (Y/N)',0
DELOK:  DB      'Delete complete.',0
DELERR: DB      'Delete finished with an error.',0
NEWASK: DB      'New name (ESC cancels): ',0
BADNAME:DB      'Invalid CP/M 8.3 filename.',0
NAMEUSED:
        DB      'That filename already exists.',0
RENOK:  DB      'Rename complete.',0
RENERR: DB      'Rename failed.',0

ACTIVE: DB      0
LDRIVE: DB      1
RDRIVE: DB      2
LCOUNT: DB      0
RCOUNT: DB      0
LCUR:   DB      0
RCUR:   DB      0
LTOP:   DB      0
RTOP:   DB      0

PCOL:   DB      0
PDRIVE: DB      0
PCOUNT: DB      0
PCUR:   DB      0
PTOP:   DB      0
PACTIVE:DB      0
DRAWIDX:DB      0
DRAWROW:DB      0
DRAWLEFT:
        DB      0
LINEIDX:DB      0
LINEOK: DB      0
LINEATT:DB      NORMATT
OLDCUR: DB      0
OLDTOP: DB      0

SRCDRIVE:
        DB      0
DSTDRIVE:
        DB      0
SCOUNT: DB      0
SCUR:   DB      0
SELMODE:DB      0
LOOPIDX:DB      0
OPERROR:DB      0
CPTOTAL:DB      0
CPNUM:  DB      0
MODAL:  DB      0
FOOTMSG:DB      0
KEYTMP: DB      0
MODROWNO:
        DB      0
INLEN:  DB      0
LEAD:   DB      0
CACHEDRV:
        DB      0
CACHEIDX:
        DB      0
CACHECOUNT:
        DB      0
CURUSER:DB      0
OLDDISK:DB      0
HASHIDX:DB      0
EXTEMP: DB      0
CANDLOW:DB      0
CANDMID:DB      0
CANDHI:DB       0
COPYLEFT:
        DB      0
CPBCOUNT:
        DB      0
CPBLEFT:
        DB      0
CPEOF:  DB      0

PLIST:  DW      0
SLIST:  DW      0
WORKLIST:
        DW      0
STOREPTR:
        DW      0
CNTPTR: DW      0
ENTRYPTR:
        DW      0
CACHEPTR:
        DW      0
RAWPTR: DW      0
MATCHPTR:
        DW      0
COPYSRCP:
        DW      0
INPTR:  DW      0
CPTOTREC:
        DW      0
CPRECDONE:
        DW      0
CPBUFPTR:
        DW      0

SRCHFCB:DS      36
SRCFCB: DS      36
DSTFCB: DS      36
NEWNAME:DS      11
NEWBUF: DS      13
LFILES:DS      MAXFILE*ENTSIZ
RFILES:DS      MAXFILE*ENTSIZ
DVALID:DS      6
DCOUNTS:DS     6
DCACHES:DS     6*CACHEBY
HASHBUF:DS     256
DIRBUF: DS      128
BUFFER: DS      CPBUFR*128

        DS      128
STACK:

        END     START

