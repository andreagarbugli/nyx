#!/bin/bash

set -e

CC=clang    # C Compiler
AS=nasm     # Assembler
LD=ld.lld   # Linker

# Check if the build folder exists or create it
if [ ! -d "build" ]; then
    mkdir build
fi

# Create the folder structure for the ISO image
if [ ! -d "build/iso/boot/grub" ]; then
    mkdir -p "build/iso/boot/grub"
fi

cd build
# Compile the assembly using nasm
$AS -f elf64 -o boot.o ../boot.asm
$LD -T ../linker.ld -o nyx.elf boot.o
grub-file --is-x86-multiboot2 nyx.elf

# create the ISO
cp nyx.elf iso/boot/nyx.elf

# Create a temp file
cat << 'EOF' > iso/boot/grub/grub.cfg
set timeout=0
set default=0

menuentry "Nyx OS" {
    multiboot2 /boot/nyx.elf
    boot
}
EOF

grub-mkrescue -o nyx.iso iso
cd ..

echo "Starting QEMU..."
qemu-system-x86_64                  \
    -cdrom ./build/nyx.iso          \
    -display none                   \
    -serial stdio                   \
    -no-reboot -no-shutdown         \
    -d int,cpu_reset,guest_errors   \
    -D build/qemu.log
