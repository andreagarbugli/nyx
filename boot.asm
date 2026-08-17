; boot.asm - Multiboot2 header + halt.

bits 32

; ==============================================================================
;   data GRUB looks for (not executed)
; ==============================================================================
section .multiboot_header
align 8
mb_start:
    dd      0xE85250D6                          ; magic: "I am Multiboot2"
    dd      0                                   ; arch: 0 = 32-bit protected mode
    dd      mb_end - mb_start                   ; total header length in bytes
    dd      0x100000000 - (0xE85250D6 + 0 + (mb_end - mb_start))
                                                ; checksum: magic+arch+len+this == 0
    dw      0                                   ; end tag, type
    dw      0                                   ; flags
    dd      8                                   ; size of this tag in bytes
mb_end:

; ==============================================================================
;   code GRUB jumpt to
; ==============================================================================
section .text
global _start
_start:
    cli
    cmp     eax, 0x36D76289
    jne     not_multiboot
.wait:
    mov     dx, 0x3FD           ; Line status register = data+5
    in      al, dx
    test    al, 0x20            ; bit 5 = TX Holding Empty
    jz      .wait

    mov     dx, 0x3F8           ; 0x3F8 = COM1
    mov     al, 'N'
    out     dx, al
    ;;
not_multiboot:
    cli
    hlt
    jmp     not_multiboot
