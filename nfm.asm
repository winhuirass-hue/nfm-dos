; ======================================================================
;  NFM+ — Nano File Manager (DOS .COM)
;  - Mini-TUI: header (drive+path), footer (help)
;  - Exit: Esc / F10
;  - Disk switch: press A..Z
;  - Navigation: ↑/↓, PgUp/PgDn, Enter(open dir), Backspace(cd ..)
;  - Ops: Del(delete file), M(mkdir), R(rmdir empty), N(rename), T(touch)
;  - Sort by name (case-insensitive): ASC default; 'S' toggles ASC/DESC
;  Build: nasm -f bin nfm_plus_sort.asm -o NFM.COM
; ======================================================================

org 0x100

%define MAX_ITEMS      192
%define NAME_LEN        13         ; 8.3 + NUL
%define PAGE_ROWS       18

%define K_ESC           27
%define SC_F10         0x44
%define SC_UP          0x48
%define SC_DOWN        0x50
%define SC_PGUP        0x49
%define SC_PGDN        0x51
%define SC_DEL         0x53

; ----------------------------------------------------------------------
; Entry
; ----------------------------------------------------------------------
start:
    ; DS = CS
    push cs
    pop  ds

    ; Save original DTA (AH=2F)
    mov  ah, 0x2F
    int  0x21               ; ES:BX -> old DTA
    mov  [orig_dta_off], bx
    mov  [orig_dta_seg], es

    ; Set our DTA (AH=1Ah)
    mov  dx, dta_buf
    mov  ah, 0x1A
    int  0x21

    call UiFullRedraw

rescan_dir:
    call LoadDir
    call SortByName          ; <-- sorting by name (ASC/DESC)
    xor  bx, bx              ; current index = 0

draw_page:
    call UiHeader
    call DrawList

; ----------------------------------------------------------------------
; Main loop
; ----------------------------------------------------------------------
main_loop:
    call GetKeyEx            ; AL=ascii, AH=scancode

    ; Exit
    cmp  al, K_ESC
    je   quit
    cmp  ah, SC_F10
    je   quit

    ; Disk change A..Z
    cmp  al, 'A'
    jb   .chk_low
    cmp  al, 'Z'
    jbe  act_change_drive
.chk_low:
    cmp  al, 'a'
    jb   .nav
    cmp  al, 'z'
    jbe  act_change_drive

.nav:
    ; Navigation
    cmp  ah, SC_UP
    je   nav_up
    cmp  ah, SC_DOWN
    je   nav_down
    cmp  ah, SC_PGUP
    je   nav_pgup
    cmp  ah, SC_PGDN
    je   nav_pgdn
    cmp  ah, SC_DEL
    je   act_del

    cmp  al, 13              ; Enter
    je   act_enter
    cmp  al, 8               ; Backspace
    je   act_updir

    ; Ops
    cmp  al, 'm'
    je   act_mkdir
    cmp  al, 'M'
    je   act_mkdir

    cmp  al, 'r'
    je   act_rmdir_sel
    cmp  al, 'R'
    je   act_rmdir_sel

    cmp  al, 'n'
    je   act_rename_sel
    cmp  al, 'N'
    je   act_rename_sel

    cmp  al, 't'
    je   act_touch_sel
    cmp  al, 'T'
    je   act_touch_sel

    ; Sort toggle
    cmp  al, 's'
    je   act_toggle_sort
    cmp  al, 'S'
    je   act_toggle_sort

    jmp  main_loop

; ----------------------------------------------------------------------
; Navigation
; ----------------------------------------------------------------------
nav_up:
    cmp  bx, 0
    je   main_loop
    dec  bx
    jmp  draw_page

nav_down:
    mov  ax, [item_count]
    dec  ax
    cmp  bx, ax
    jae  main_loop
    inc  bx
    jmp  draw_page

nav_pgup:
    sub  bx, PAGE_ROWS
    js   .to0
    jmp  draw_page
.to0:
    xor  bx, bx
    jmp  draw_page

nav_pgdn:
    mov  ax, bx
    add  ax, PAGE_ROWS
    mov  dx, [item_count]
    dec  dx
    cmp  ax, dx
    jbe  .ok
    mov  bx, dx
    jmp  draw_page
.ok:
    mov  bx, ax
    jmp  draw_page

; ----------------------------------------------------------------------
; Actions
; ----------------------------------------------------------------------
act_enter:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10            ; DIR?
    jz   main_loop
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x3B            ; CHDIR
    int  0x21
    jc   UiStatusErr
    jmp  rescan_dir

act_updir:
    mov  dx, updir_txt
    mov  ah, 0x3B
    int  0x21
    jc   UiStatusErr
    jmp  rescan_dir

act_del:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10            ; if DIR -> ignore
    jnz  main_loop
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x41            ; DELETE
    int  0x21
    jc   UiStatusErr
    jmp  rescan_dir

act_mkdir:
    mov  dx, pr_mkdir$
    call PromptNameToBuf
    jc   draw_page
    mov  dx, name_buf
    mov  ah, 0x39            ; MKDIR
    int  0x21
    jc   UiStatusErr
    jmp  rescan_dir

act_rmdir_sel:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10
    jz   UiStatusErr
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x3A            ; RMDIR
    int  0x21
    jc   UiStatusErr
    jmp  rescan_dir

act_rename_sel:
    ; old -> old_name_buf
    push bx
    mov  dx, old_name_buf
    call GetNameByIndex
    pop  bx

    mov  dx, pr_ren_new$
    call PromptNameToBuf
    jc   draw_page

    mov  dx, old_name_buf    ; DS:DX = old
    push ds
    pop  es                  ; ES = DS
    mov  di, name_buf        ; ES:DI = new
    mov  ah, 0x56            ; RENAME
    int  0x21
    jc   UiStatusErr
    jmp  rescan_dir

act_touch_sel:
    ; name from selected
    push bx
    mov  dx, name_buf
    call GetNameByIndex
    pop  bx

    ; exists? FindFirst
    mov  dx, name_buf
    mov  cx, 0x37
    mov  ah, 0x4E
    int  0x21
    jc   .create

    ; open and set date/time
    mov  ax, 0x3D02          ; open R/W
    mov  dx, name_buf
    int  0x21
    jc   UiStatusErr
    mov  bx, ax              ; handle

    ; time
    mov  ah, 0x2C            ; CH hour, CL min, DH sec
    int  0x21
    xor  ax, ax
    mov  al, ch              ; hour
    shl  ax, 11
    mov  cx, ax
    mov  al, cl              ; minute
    shl  ax, 5
    or   cx, ax
    mov  al, dh              ; sec
    shr  al, 1
    or   cx, ax              ; CX = time

    ; date
    mov  ah, 0x2A            ; CX year, DH month, DL day
    int  0x21
    sub  cx, 1980
    shl  cx, 9
    mov  dx, cx
    xor  ax, ax
    mov  al, dh              ; month
    shl  ax, 5
    or   dx, ax
    xor  ax, ax
    mov  al, dl              ; day
    or   dx, ax              ; DX = date

    mov  ax, 0x5701          ; set by handle
    int  0x21
    mov  ah, 0x3E            ; close
    int  0x21
    jc   UiStatusErr
    jmp  draw_page

.create:
    mov  cx, 0
    mov  dx, name_buf
    mov  ah, 0x3C            ; CREATE
    int  0x21
    jc   UiStatusErr
    mov  bx, ax
    mov  ah, 0x3E            ; CLOSE
    int  0x21
    jmp  draw_page

; Toggle sort order
act_toggle_sort:
    xor  byte [sort_desc], 1 ; 0->1, 1->0
    call SortByName
    xor  bx, bx
    jmp  draw_page

; Disk change: A..Z in AL
act_change_drive:
    and  al, 0xDF            ; upper
    sub  al, 'A'
    cmp  al, 25
    ja   main_loop

    ; remember previous
    mov  ah, 0x19            ; AL=current drive (0=A)
    int  0x21
    mov  [prev_drv], al

    mov  dl, al              ; DL=new drive (0=A)
    mov  ah, 0x0E            ; Set default drive
    int  0x21

    ; test with GetCWD
    mov  dl, 0               ; current default
    mov  si, cwd_buf
    mov  byte [si], 64
    mov  dx, si
    mov  ah, 0x47
    int  0x21
    jnc  rescan_dir          ; ok

    ; rollback
    mov  dl, [prev_drv]
    mov  ah, 0x0E
    int  0x21
    call UiStatusErr
    jmp  draw_page

; Exit
quit:
    ; restore original DTA
    mov  dx, [orig_dta_off]
    mov  ds, [orig_dta_seg]
    mov  ah, 0x1A
    int  0x21

    mov  ax, 0x4C00
    int  0x21

; ======================================================================
; Directory scan and drawing
; ======================================================================
LoadDir:
    push ds
    push es
    push si
    push di

    push cs
    pop  ds

    xor  ax, ax
    mov  [item_count], ax

    mov  dx, patt_all
    mov  cx, 0x37
    mov  ah, 0x4E            ; FindFirst
    int  0x21
    jc   .done

.collect:
    mov  si, dta_buf
    mov  al, [si+0x15]       ; attr
    mov  bx, [item_count]
    shl  bx, 1
    mov  [attr_table + bx], ax

    ; copy 13 bytes name from DTA (0x1E)
    mov  si, dta_buf
    add  si, 0x1E
    ; compute dest = names_area + index*13
    mov  di, names_area
    mov  cx, [item_count]
    jcxz .addr_ok
.addr_loop:
    add  di, NAME_LEN
    loop .addr_loop
.addr_ok:
    mov  cx, NAME_LEN
.copy13:
    lodsb
    stosb
    loop .copy13

    mov  ax, [item_count]
    inc  ax
    mov  [item_count], ax
    cmp  ax, MAX_ITEMS
    jae  .done

    mov  ah, 0x4F            ; FindNext
    int  0x21
    jnc  .collect

.done:
    pop  di
    pop  si
    pop  es
    pop  ds
    ret

DrawList:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    call UiBodyClear

    ; page first index = (bx / rows) * rows
    xor  dx, dx
    mov  ax, bx
    mov  cx, PAGE_ROWS
    div  cx
    mul  cx
    mov  si, ax              ; first index
    xor  di, di              ; row 0..PAGE_ROWS-1

.row_loop:
    mov  ax, si
    cmp  ax, [item_count]
    jae  .end

    ; cursor at row 3+di, col 2
    mov  dh, 3
    add  dh, di
    mov  dl, 2
    call GotoXY

    ; selection mark
    mov  ax, si
    cmp  ax, bx
    jne  .space2
    mov  dl, '>'
    call PutChar
    mov  dl, ' '
    call PutChar
    jmp  .print_name
.space2:
    mov  dl, ' '
    call PutChar
    mov  dl, ' '
    call PutChar

.print_name:
    push bx
    mov  bx, si
    mov  dx, name_buf
    call GetNameByIndex
    pop  bx

    mov  ax, [attr_table + si*2]
    test al, 0x10
    jz   .file
    mov  dx, dir_tag$
    call PrintStr$
    mov  dx, name_buf
    call PrintStrZ
    jmp  .next
.file:
    mov  dx, name_buf
    call PrintStrZ

.next:
    inc  si
    inc  di
    cmp  di, PAGE_ROWS
    jb   .row_loop

.end:
    call UiFooter
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

GetNameByIndex:               ; BX=index, DS=CS, DX=dest
    push si
    push di
    push cx

    mov  di, names_area
    mov  cx, bx
    jcxz .addr_ok
.addr_loop:
    add  di, NAME_LEN
    loop .addr_loop
.addr_ok:
    mov  si, di
    mov  di, dx
    mov  cx, NAME_LEN
    rep  movsb

    pop  cx
    pop  di
    pop  si
    ret

; ======================================================================
; Sorting by name (case-insensitive)
; ======================================================================
; sort_desc = 0 -> ASC, 1 -> DESC
SortByName:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov  cx, [item_count]
    cmp  cx, 2
    jb   .done

    mov  bx, 1               ; i = 1..count-1
.for_i:
    mov  si, bx              ; j = i
.inner:
    cmp  si, 0
    je   .next_i

    mov  dx, si
    dec  dx                  ; DX = j-1, SI = j
    push bx
    push si
    push dx
    call CompareNames        ; AL = -1(A<B) / 0 / +1(A>B)
    ; sort order
    cmp  byte [sort_desc], 0
    jne  .desc

    ; ASC: if A > B -> swap
    cmp  al, 1
    jne  .asc_break
    mov  bx, si
    mov  dx, si
    dec  dx
    call SwapItems
    dec  si
    pop  dx
    pop  si
    pop  bx
    jmp  .inner

.asc_break:
    pop  dx
    pop  si
    pop  bx
    jmp  .next_i

.desc:
    ; DESC: if A < B -> swap
    cmp  al, -1
    jne  .desc_break
    mov  bx, si
    mov  dx, si
    dec  dx
    call SwapItems
    dec  si
    pop  dx
    pop  si
    pop  bx
    jmp  .inner

.desc_break:
    pop  dx
    pop  si
    pop  bx

.next_i:
    inc  bx
    mov  ax, [item_count]
    cmp  bx, ax
    jb   .for_i

.done:
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; Compare names at indices DX (A) and SI (B), case-insensitive
; AL = -1 if A<B, 0 if A==B, +1 if A>B
CompareNames:
    push bx
    push cx
    push di

    ; DI = ptrA
    mov  di, names_area
    mov  bx, dx
    mov  cx, bx
    jcxz .haveA
.ca:
    add  di, NAME_LEN
    loop .ca
.haveA:

    ; SI = ptrB  (reuse SI)
    push si
    mov  bx, si
    mov  si, names_area
    mov  cx, bx
    jcxz .haveB
.cb:
    add  si, NAME_LEN
    loop .cb
.haveB:

    mov  cx, NAME_LEN
.cmp_loop:
    lodsb                    ; AL = B[i], SI++
    mov  bl, [di]            ; BL = A[i]
    inc  di

    ; to upper
    push ax
    mov  al, bl
    call ToUpper
    mov  bl, al
    pop  ax
    call ToUpper             ; AL -> upper

    cmp  bl, al
    jne  .diff
    test al, al
    jz   .equal
    loop .cmp_loop

.equal:
    xor  al, al
    jmp  .ret

.diff:
    cmp  bl, al
    jb   .less
    mov  al, 1               ; A > B
    jmp  .ret
.less:
    mov  al, -1              ; A < B

.ret:
    pop  si
    pop  di
    pop  cx
    pop  bx
    ret

ToUpper:                     ; AL -> upper if 'a'..'z'
    cmp  al, 'a'
    jb   .ok
    cmp  al, 'z'
    ja   .ok
    sub  al, 32
.ok:
    ret

; Swap items at indices DX (A) and BX (B): names (13) + attr (word)
SwapItems:
    push ax
    push cx
    push si
    push di

    ; ptrA -> DI
    mov  di, names_area
    mov  cx, dx
.sa:
    cmp  cx, 0
    je   .haveA
    add  di, NAME_LEN
    dec  cx
    jmp  .sa
.haveA:
    ; ptrB -> SI
    mov  si, names_area
    mov  cx, bx
.sb:
    cmp  cx, 0
    je   .haveB
    add  si, NAME_LEN
    dec  cx
    jmp  .sb
.haveB:

    ; tmp <- A
    push di
    push si
    mov  cx, NAME_LEN
    mov  si, di
    mov  di, tmp_name_buf
.cp_A_tmp:
    lodsb
    stosb
    loop .cp_A_tmp

    ; A <- B  (restore DI, SI)
    pop  si
    pop  di
    mov  cx, NAME_LEN
.cp_B_A:
    mov  al, [si]
    mov  [di], al
    inc  si
    inc  di
    loop .cp_B_A

    ; B <- tmp (recompute DI to ptrB)
    mov  di, names_area
    mov  cx, bx
.sb2:
    cmp  cx, 0
    je   .haveB2
    add  di, NAME_LEN
    dec  cx
    jmp  .sb2
.haveB2:
    mov  si, tmp_name_buf
    mov  cx, NAME_LEN
.cp_tmp_B:
    lodsb
    stosb
    loop .cp_tmp_B

    ; swap attributes (word)
    push dx
    push bx
    shl  dx, 1
    shl  bx, 1
    mov  ax, [attr_table + dx]
    xchg ax, [attr_table + bx]
    mov  [attr_table + dx], ax
    pop  bx
    pop  dx

    pop  di
    pop  si
    pop  cx
    pop  ax
    ret

; ======================================================================
; UI: header/footer/body and status
; ======================================================================
UiFullRedraw:
    call ClearScreen
    ret

UiHeader:
    ; Title at (0,0)
    mov  dh, 0
    mov  dl, 0
    call GotoXY
    mov  dx, title$
    call PrintStr$

    ; Current drive
    mov  ah, 0x19            ; AL=current (0=A)
    int  0x21
    add  al, 'A'
    mov  [cur_drv_char], al

    mov  dh, 1
    mov  dl, 0
    call GotoXY
    mov  dx, drv_lbl$
    call PrintStr$
    mov  dl, [cur_drv_char]
    call PutChar
    mov  dl, ':'
    call PutChar
    mov  dl, ' '
    call PutChar

    ; Current path (GetCWD DL=0)
    mov  dl, 0
    mov  si, cwd_buf
    mov  byte [si], 64       ; max
    mov  dx, si
    mov  ah, 0x47
    int  0x21
    jc   .done

    mov  cl, [cwd_buf]       ; length
    inc  si                  ; SI -> first char
    mov  dx, si              ; PrintStrRawLen uses DS:DX
    call PrintStrRawLen

.done:
    ret

UiBodyClear:
    ; clear rows 3..22
    mov  ax, 0x0600
    mov  bh, 0x07
    mov  cx, (3<<8)|0
    mov  dx, (22<<8)|79
    int  0x10
    ret

UiFooter:
    mov  dh, 23
    mov  dl, 0
    call GotoXY
    mov  dx, help_line$
    call PrintStr$
    ret

UiStatusErr:
    mov  dh, 23
    mov  dl, 0
    call GotoXY
    mov  dx, err_line$
    call PrintStr$
    call PressAnyKey
    ret

; ======================================================================
; Console / input helpers
; ======================================================================
PromptNameToBuf:              ; DS:DX ($-prompt) -> ASCIIZ in name_buf; CF=1 if empty
    push ax
    push dx

    call NewLine
    call PrintStr$

    mov  byte [inpbuf], 63
    mov  byte [inpbuf+1], 0
    mov  dx, inpbuf
    mov  ah, 0x0A            ; buffered input
    int  0x21

    mov  al, [inpbuf+1]
    or   al, al
    jz   .empty

    lea  si, [inpbuf+2]
    mov  di, name_buf
.cp:
    lodsb
    cmp  al, 13
    je   .zero
    stosb
    jmp  .cp
.zero:
    mov  al, 0
    stosb
    clc
    jmp  .done
.empty:
    stc
.done:
    pop  dx
    pop  ax
    ret

GetKeyEx:                     ; AL=ASCII, AH=scancode
    mov  ah, 0x10
    int  0x16
    ret

ClearScreen:
    mov  ax, 0x0600
    mov  bh, 0x07
    mov  cx, 0x0000
    mov  dx, 0x184F
    int  0x10
    ret

GotoXY:                       ; DH=row, DL=col
    push bx
    mov  bh, 0
    mov  ah, 0x02
    int  0x10
    pop  bx
    ret

PutChar:                      ; DL=char
    push ax
    push bx
    xor  bh, bh
    mov  ah, 0x0E
    mov  al, dl
    mov  bl, 0x07
    int  0x10
    pop  bx
    pop  ax
    ret

PrintStr$:                    ; DS:DX -> '$'-terminated string
    mov  ah, 0x09
    int  0x21
    ret

PrintStrZ:                    ; DS:DX -> ASCIIZ
    push ax
    push dx
    mov  si, dx
.next:
    lodsb
    or   al, al
    jz   .done
    push dx
    mov  dl, al
    call PutChar
    pop  dx
    jmp  .next
.done:
    pop  dx
    pop  ax
    ret

PrintStrRawLen:               ; DS:DX -> buffer, CL=len
    push ax
    push cx
    push dx
    mov  si, dx
    jcxz .done
.more:
    lodsb
    push cx
    mov  dl, al
    call PutChar
    pop  cx
    loop .more
.done:
    pop  dx
    pop  cx
    pop  ax
    ret

NewLine:
    mov  dl, 13
    mov  ah, 0x02
    int  0x21
    mov  dl, 10
    mov  ah, 0x02
    int  0x21
    ret

PressAnyKey:
    mov  dx, any$
    call PrintStr$
    xor  ax, ax
    int  0x16
    ret

; ======================================================================
; Data
; ======================================================================
title$       db 'NFM+ — Nano File Manager (DOS)',13,10,'$'
drv_lbl$     db 'Drive ', '$'
dir_tag$     db '[DIR] ', '$'
help_line$   db 'Enter:open  Backspace:up  Del:del  M:mkdir  R:rmdir  N:rename  T:touch  S:sort  A..Z:drive  F10/Esc:exit', '$'
err_line$    db 'Error (CF=1). Press any key...', '$'
any$         db '  (press any key)', '$'

pr_mkdir$    db 'MKDIR name: $'
pr_ren_new$  db 'RENAME to  : $'

updir_txt    db '..',0
patt_all     db '*.*',0

cur_drv_char db 0
prev_drv     db 0

sort_desc    db 0                 ; 0 = ASC, 1 = DESC
tmp_name_buf rb NAME_LEN

orig_dta_off dw 0
orig_dta_seg dw 0

cwd_buf      db 64 dup(0)
inpbuf       rb 66
name_buf     rb 64
old_name_buf rb 64

dta_buf      rb 128
item_count   dw 0
attr_table   dw MAX_ITEMS dup(0)
names_area   rb MAX_ITEMS * NAME_LEN

; ======================================================================
; End
; ======================================================================
