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
    call SortByName

    cmp  byte [restore_sel], 0
    jne  .restore
    xor  bx, bx             ; default selection on fresh load
    jmp  draw_page
.restore:
    call RestoreSelection
    mov  byte [restore_sel], 0

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
SaveSelectedName:
    ; BX=index -> last_name_buf
    push bx
    mov  dx, last_name_buf
    call GetNameByIndex
    pop  bx
    mov  byte [restore_sel], 1
    ret

act_enter:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10            ; DIR?
    jz   main_loop
    call SaveSelectedName
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
    mov  byte [restore_sel], 0
    jmp  rescan_dir

; ----------- Delete file (confirm) ----------
act_del:
    ; only files
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10
    jnz  main_loop

    ; prompt: "Delete file? (Y/N): "
    mov  dx, pr_del$
    call AskYesNo
    or   al, al
    jz   draw_page

    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x41            ; DELETE
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; ----------- MKDIR ----------
act_mkdir:
    mov  dx, pr_mkdir$
    call PromptNameToBuf
    jc   draw_page
    call SaveSelectedName     ; position by name typed (close enough)
    mov  dx, name_buf
    mov  ah, 0x39            ; MKDIR
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; ----------- RMDIR (empty, confirm) ----------
act_rmdir_sel:
    mov  si, bx
    shl  si, 1
    mov  ax, [attr_table + si]
    test al, 0x10
    jz   draw_page           ; not a dir

    mov  dx, pr_rmdir$
    call AskYesNo
    or   al, al
    jz   draw_page

    call SaveSelectedName
    mov  dx, name_buf
    call GetNameByIndex
    mov  ah, 0x3A            ; RMDIR
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; ----------- RENAME ----------
act_rename_sel:
    ; old -> old_name_buf
    push bx
    mov  dx, old_name_buf
    call GetNameByIndex
    pop  bx

    mov  dx, pr_ren_new$
    call PromptNameToBuf
    jc   draw_page

    call SaveSelectedName
    mov  dx, old_name_buf    ; DS:DX = old
    push ds
    pop  es                  ; ES = DS
    mov  di, name_buf        ; ES:DI = new
    mov  ah, 0x56            ; RENAME
    int  0x21
    jnc  rescan_dir
    call UiShowLastError
    jmp  draw_page

; ----------- TOUCH ----------
act_touch_sel:
    call SaveSelectedName

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
    jnc  rescan_dir
    call UiShowLastError
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
    jmp  rescan_dir

; Toggle sort order
act_toggle_sort:
    xor  byte [sort_desc], 1 ; 0->1, 1->0
    call SortByName
    jmp  draw_page

; Toggle group directories first
act_toggle_group:
    xor  byte [group_dirs_first], 1
    call SortByName
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
