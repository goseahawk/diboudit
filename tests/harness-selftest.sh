#!/usr/bin/env bash
# Prove the image builder and QEMU/OVMF harness work, independent of our own
# kernel (which arrives in Phase 1). Any x86_64 EFI-stub kernel works; Phase 0
# used a stock Ubuntu kernel as a stand-in. Three checks:
#   1. disk path:   OVMF finds and starts \EFI\BOOT\BOOTX64.EFI on our GPT image
#                   (the same path the Mac's Option-key picker uses)
#   2. kernel path: OVMF runs the kernel's EFI stub and we see the kernel log on
#                   serial, up to the expected "no root fs" panic (no userland yet)
#   3. reproducible image
. "$(dirname "$0")/../scripts/lib.sh"
K=${1:?usage: harness-selftest.sh BZIMAGE}
T=$BUILD/selftest; mkdir -p "$T"

log "1/3 disk boot: firmware -> ESP -> BOOTX64.EFI"
bash "$TOP/scripts/mkimage.sh" --kernel "$K" --out "$T/disk.img"
# The stand-in kernel has no built-in command line, so after the firmware hands
# over it only draws on the framebuffer; capture it as proof.
bash "$TOP/scripts/qemu.sh" --disk "$T/disk.img" --timeout 300 --log "$T/disk-serial.log" \
	--expect 'BdsDxe: starting Boot[0-9A-F]+ .*QEMU HARDDISK' --screendump "$T/disk-screen.png" --settle 25

log "2/3 kernel boot via EFI stub, kernel log on serial"
bash "$TOP/scripts/qemu.sh" --kernel "$K" --append "earlycon=uart8250,io,0x3f8,115200 console=ttyS0,115200 ignore_loglevel panic=-1" --timeout 600 \
	--log "$T/kernel-serial.log" --expect 'Kernel panic - not syncing|Run /init as init process'
grep -m1 'Linux version' "$T/kernel-serial.log" || die "no kernel banner on serial"

log "3/3 reproducibility"
bash "$TOP/scripts/mkimage.sh" --kernel "$K" --out "$T/disk2.img"
cmp -s "$T/disk.img" "$T/disk2.img" || die "image is NOT reproducible"
log "harness self-test PASSED (logs and screenshot in $T)"
