; ======================================================================
;  NFM+ — Nano File Manager (DOS .COM) — Improved
;  - Mini-TUI: header (drive+path), footer (help)
;  - Exit: Esc / F10
;  - Disk switch: press A..Z
;  - Navigation: ↑/↓, PgUp/PgDn, Enter(open dir), Backspace(cd ..)
;  - Ops: Del(delete file, confirm), M(mkdir), R(rmdir empty, confirm),
;         N(rename), T(touch)
;  - Sort by name (case-insensitive): ASC default; 'S' toggles ASC/DESC
;  - Group [DIR] first: 'G' toggle
;  Build: nasm -f bin nfm_improved.asm -o NFM.COM
; ======================================================================

bits 16
org 0x100

%define MAX_ITEMS      192
%define NAME_LEN        13         ; 8.3 ASCIIZ
%define PAGE_ROWS       18

%define K_ESC           27
%define SC_F10         0x44
%define SC_UP          0x48
%define SC_DOWN        0x50
%define SC_PGUP        0x49
%define SC_PGDN        0x51
%define SC_DEL         0x53

; ----------------------------------------------------------------------
; Data
; ----------------------------------------------------------------------
section .data

mask_all       db '*.*',0
updir_txt      db '..',0
root_txt       db '\',0

; UI strings ($-terminated for AH=09h)
ui_help$       db 'Up/Down PgUp/PgDn Enter Backspace  Del  M R N T  S:Sort  G:Group  Esc/F10:Exit$'
err_prefix$    db 'Error ',0
crlf$          db 13,10,'$'

pr_del$        db 'Delete file? (Y/N): $'
pr_mkdir$      db 'New directory name: $'
pr_rmdir$      db 'Remove directory? (Y/N): $'
pr_ren_new$    db 'New name: $'

; Flags/state
item_count       dw 0
restore_sel      db 0
sort_desc        db 0
group_dirs_first db 1
prev_drv         db 0

; Buffers & tables
dta_buf          rb 128                       ; DTA (>=43 bytes)
name_table       rb MAX_ITEMS * NAME_LEN      ; list of ASCIIZ 8.3 names
attr_table       rw MAX_ITEMS                 ; attributes (byte used)
name_buf         rb NAME_LEN
old_name_buf     rb NAME_LEN
last_name_buf    rb NAME_LEN
path_buf         rb 64                        ; for AH=47h path (no drive)
header_tmp       rb 80

; DOS input buffer for AH=0Ah (max 12 chars for 8.3)
linein_buf:
    db 12           ; max length (12)
    db 0            ; actual length
    rb 13           ; data (max+1)

orig_dta_off    dw 0
orig_dta_seg    dw 0

; ----------------------------------------------------------------------
; Code
; ----------------------------------------------------------------------
section .text

; ---------------- Entry ----------------
start:
    push cs
    pop  ds

    ; Save original DTA (AH=2Fh)
    mov  ah, 0x2F
    int  0x21
    mov  [orig_dta_off], bx
    mov  [orig_dta_seg], es

    ; Set our DTA (AH=1Ah)
    mov  dx, dta_buf
    mov  ah, 0x1A
    int  0x21

    call UiFullRedraw

rescan_dir:
    call LoadDir
    call SortByName

    cmp  byte [restore_sel], 0
    jne  .restore
    xor  bx, bx                 ; default selection
    jmp  draw_page
.restore:
    call RestoreSelection
    mov  byte [restore_sel], 0

draw_page:
    call UiHeader
    call DrawList

; ---------------- Main loop ----------------
main_loop:
    call GetKeyEx                ; AL=ascii, AH=scancode

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

    cmp  al, 13                  ; Enter
    je   act_enter
    cmp  al, 8                   ; Backspace
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

    ; Group DIR first toggle
    cmp  al, 'g'
    je   act_toggle_group
    cmp  al, 'G'
    je   act_toggle_group

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
; Save selected name into last_name_buf for post-rescan restore
SaveSelectedName:
    push bx
    mov  dx, last_name_buf
    call GetNameByIndex
    pop  bx
    mov  byte [restore_sel], 1
    ret

; Enter into directory (if selected is DIR)
act_enter:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10                ; DIR?
    jz   main_loop
    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x3B                ; CHDIR
    int  0x21
    jc   UiShowLastError
    jmp  rescan_dir

; Updir: chdir ..
act_updir:
    mov  dx, updir_txt
    mov  ah, 0x3B
    int  0x21
    jc   UiShowLastError
    mov  byte [restore_sel], 0
    jmp  rescan_dir

; Delete file (confirm). Directories are ignored.
act_del:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10                ; DIR?
    jnz  main_loop

    mov  dx, pr_del$
    call AskYesNo
    or   al, al
    jz   draw_page

    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x41                ; DELETE
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; MKDIR (prompt)
act_mkdir:
    mov  dx, pr_mkdir$
    call PromptNameToBuf
    jc   draw_page
    call SaveSelectedName
    mov  dx, name_buf
    mov  ah, 0x39                ; MKDIR
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; RMDIR (if selected is DIR, confirm)
act_rmdir_sel:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10
    jz   draw_page               ; not a dir

    mov  dx, pr_rmdir$
    call AskYesNo
    or   al, al
    jz   draw_page

    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x3A                ; RMDIR
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; RENAME selected (prompt new name)
act_rename_sel:
    ; Copy old name to old_name_buf
    push bx
    mov  dx, old_name_buf
    call GetNameByIndex
    pop  bx

    mov  dx, pr_ren_new$
    call PromptNameToBuf
    jc   draw_page

    call SaveSelectedName
    mov  dx, old_name_buf        ; DS:DX old
    push ds
    pop  es
    mov  di, name_buf            ; ES:DI new
    mov  ah, 0x56                ; RENAME
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; TOUCH selected: update timestamp or create
act_touch_sel:
    call SaveSelectedName

    ; get selected name -> name_buf
    push bx
    mov  dx, name_buf
    call GetNameByIndex
    pop  bx

    ; exists? FindFirst for file attrs only (no DIR)
    mov  dx, name_buf
    mov  cx, 0x27                ; R|H|S|A (files)
    mov  ah, 0x4E
    int  0x21
    jc   .create

    ; open R/W
    mov  ax, 0x3D02              ; open
    mov  dx, name_buf
    int  0x21
    jc   UiShowLastError
    mov  bx, ax                  ; handle

    ; ---- build CX = time ----
    mov  ah, 0x2C                ; CH hour, CL min, DH sec
    int  0x21
    xor  cx, cx
    mov  al, ch                  ; hour
    xor  ah, ah
    shl  ax, 11
    mov  cx, ax
    xor  ax, ax
    mov  al, cl                  ; minute
    shl  ax, 5
    or   cx, ax
    xor  ax, ax
    mov  al, dh                  ; second
    shr  al, 1
    or   cx, ax                  ; CX=time

    ; ---- build DX = date ----
    mov  ah, 0x2A                ; CX year, DH month, DL day
    int  0x21
    sub  cx, 1980
    mov  dx, cx
    shl  dx, 9                   ; (year-1980)<<9
    xor  ax, ax
    mov  al, dh                  ; month
    shl  ax, 5
    or   dx, ax
    xor  ax, ax
    mov  al, dl                  ; day
    or   dx, ax                  ; DX=date

    mov  ax, 0x5701              ; set by handle
    int  0x21
    mov  ah, 0x3E                ; close
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

.create:
    mov  cx, 0
    mov  dx, name_buf
    mov  ah, 0x3C                ; CREATE
    int  0x21
    jc   UiShowLastError
    mov  bx, ax
    mov  ah, 0x3E                ; CLOSE
    int  0x21
    jmp  rescan_dir

; Toggle sort order
act_toggle_sort:
    xor  byte [sort_desc], 1
    call SortByName
    jmp  draw_page

; Toggle group directories first
act_toggle_group:
    xor  byte [group_dirs_first], 1
    call SortByName
    jmp  draw_page

; Disk change: AL='A'..'Z'/'a'..'z'
act_change_drive:
    ; Normalize to 0..25 in AL
    and  al, 0xDF
    sub  al, 'A'
    cmp  al, 25
    ja   main_loop

    ; remember previous drive
    mov  ah, 0x19                ; AL=current (0=A)
    int  0x21
    mov  [prev_drv], al

    ; select new drive: DL=drive+1 (1=A)
    mov  dl, al
    inc  dl
    mov  ah, 0x0E                ; Select Disk
    int  0x21
    ; go to root
    mov  dx, root_txt
    mov  ah, 0x3B                ; CHDIR "\"
    int  0x21
    jc   UiShowLastError

    mov  byte [restore_sel], 0
    jmp  rescan_dir

; ----------------------------------------------------------------------
; Directory loading, sorting, selection restore
; ----------------------------------------------------------------------

; LoadDir:
; - Scans "*.*" with CX=0x37 (include files+dirs+hidden+system+archive)
; - Skips volume labels
; - Fills name_table[], attr_table[], item_count
LoadDir:
    xor  ax, ax
    mov  [item_count], ax

    mov  dx, mask_all
    mov  cx, 0x37                ; R/H/S/D/A
    mov  ah, 0x4E                ; FindFirst
    int  0x21
    jc   .done

.next:
    ; DTA layout: attr at +0x15, name at +0x1E
    mov  si, dta_buf
    mov  al, [si + 0x15]         ; attributes
    test al, 0x08                ; volume label?
    jnz  .skip_add

    ; add item
    mov  dx, [item_count]
    cmp  dx, MAX_ITEMS
    jae  .skip_add

    ; dest DI = name_table + index*NAME_LEN
    mov  di, dx
    ; di = di*13
    mov  ax, di
    shl  ax, 1                   ; 2x
    add  ax, di                  ; 3x
    shl  ax, 2                   ; 12x
    add  ax, di                  ; 13x
    mov  di, ax
    add  di, name_table

    ; copy 13 bytes name
    push si
    lea  si, [si + 0x1E]
    mov  cx, NAME_LEN
    rep  movsb
    pop  si

    ; store attr (word)
    mov  si, dx
    shl  si, 1
    mov  ah, 0
    mov  [attr_table + si], ax   ; AL had attr, AH=0

    ; increment count
    inc  word [item_count]

.skip_add:
    ; FindNext
    mov  ah, 0x4F
    int  0x21
    jnc  .next
.done:
    ret

; Case-insensitive compare of two ASCIIZ 8.3 names
; IN: DS:SI -> name1, ES:DI -> name2
; OUT: CF=0, AX= -1/0/1 like strcmp (AX<0 if name1<name2)
; Uses: AX,BX,CX,DX
StrICmp83:
    push bx
    push dx
.nextc:
    lodsb                         ; AL = *SI++
    mov  bl, al
    ; to upper (A..Z), cheap mapping
    cmp  bl, 'a'
    jb   .n1
    cmp  bl, 'z'
    ja   .n1
    and  bl, 0xDF
.n1:
    mov  al, [es:di]
    inc  di
    mov  bh, al
    cmp  bh, 'a'
    jb   .n2
    cmp  bh, 'z'
    ja   .n2
    and  bh, 0xDF
.n2:
    mov  al, bl
    cmp  al, bh
    jb   .lt
    ja   .gt
    cmp  bl, 0
    jne  .nextc
    ; both zero -> equal
    xor  ax, ax
    jmp  .out
.lt:
    mov  ax, -1
    jmp  .out
.gt:
    mov  ax, 1
.out:
    pop  dx
    pop  bx
    ret

; Swap items i<->j (name_table and attr_table)
; IN: SI=i, DI=j
SwapItems:
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    ; compute ptrs: p1= name_table + i*13 ; p2= name_table + j*13
    mov  bx, si
    mov  ax, bx
    shl  ax, 1
    add  ax, bx
    shl  ax, 2
    add  ax, bx
    mov  dx, ax                  ; dx = i*13
    mov  bx, di
    mov  ax, bx
    shl  ax, 1
    add  ax, bx
    shl  ax, 2
    add  ax, bx
    ; ax = j*13

    push ds
    push es
    pop  ds                      ; DS=ES (same segment)
    ; swap 13 bytes using temp buffer name_buf
    lea  si, [name_table + dx]
    lea  di, [name_buf]
    mov  cx, NAME_LEN
