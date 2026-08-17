ENTRY(_start)
OUTPUT_FORMAT(elf64-x86-64)

SECTIONS
{
    . = 1M;                 /* GRUB loads us around 1 MiB */

    .boot : {
        KEEP(*(.multiboot_header))
        *(.text)
    }
}
