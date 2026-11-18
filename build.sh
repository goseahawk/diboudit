#!/usr/bin/env bash
# mbaos — one entry point for everything.
#
#   ./build.sh                 = ./build.sh all
#   ./build.sh all             check-host, fetch, toolchain, smoke, kernel, rootfs, image
#   ./build.sh check-host      verify the build host has every required tool
#   ./build.sh keys            build keys/trusted.gpg (upstream signing keys; asks you to cross-check)
#   ./build.sh lock [NAME..]   pin sources: verify GPG signature, record sha256
#   ./build.sh fetch [NAME..]  download + sha256-verify pinned sources
#   ./build.sh toolchain       build the musl cross toolchain into build/tools
#   ./build.sh smoke           test the toolchain (hardening, musl, Broadwell)
#   ./build.sh kernel          configure (allnoconfig + config/kernel.fragment), verify, build
#   ./build.sh kernel-config   only regenerate + verify config/kernel.resolved.config
#   ./build.sh rootfs          assemble build/rootfs (Phase 1: the boot probe as /sbin/init)
#   ./build.sh image           build build/mbaos.img (our kernel + rootfs; KERNEL=F overrides)
#   ./build.sh test            Phase 1 acceptance test: boot the image in QEMU, check the report
#   ./build.sh usb /dev/sdX    write build/mbaos.img to a USB stick (guarded, asks first)
#   ./build.sh qemu [ARGS]     boot build/mbaos.img in QEMU/OVMF (args go to scripts/qemu.sh)
#   ./build.sh repro-check KERNEL=F   build the image twice, compare sha256
#   ./build.sh harness-selftest KERNEL=F   prove image + QEMU harness work with any EFI-stub kernel
#   ./build.sh clean           remove build/ (keeps the sources/ download cache)
set -euo pipefail
cd "$(dirname "$0")"
. scripts/lib.sh

for a in "$@"; do [[ $a == KERNEL=* ]] && KERNEL=${a#KERNEL=}; done
args=(); for a in "$@"; do [[ $a == KERNEL=* ]] || args+=("$a"); done
set -- "${args[@]+"${args[@]}"}"
IMG=$BUILD/mbaos.img

need_kernel() {
	KERNEL=${KERNEL:-$BUILD/kernel/bzImage}
	[[ -f $KERNEL ]] || die "no kernel at $KERNEL; run ./build.sh kernel (or pass KERNEL=/path/to/bzImage)"
}

cmd=${1:-all}; shift || true
case $cmd in
check-host)  exec bash scripts/check-host.sh ;;
keys)        exec bash scripts/import-keys.sh "$@" ;;
lock)        exec bash scripts/lock.sh "$@" ;;
fetch)       exec bash scripts/fetch.sh "$@" ;;
toolchain)   exec bash scripts/toolchain.sh ;;
smoke)       exec bash tests/toolchain-smoke.sh ;;
kernel)      exec bash scripts/kernel.sh ;;
kernel-config) exec bash scripts/kernel.sh --config ;;
rootfs)      exec bash scripts/rootfs.sh ;;
image)       need_kernel; [[ -d $BUILD/rootfs ]] || bash scripts/rootfs.sh
             exec bash scripts/mkimage.sh --kernel "$KERNEL" --rootfs "$BUILD/rootfs" --out "$IMG" "$@" ;;
test)        exec bash tests/phase1-boot.sh ;;
usb)         [[ -f $IMG ]] || die "no image; run ./build.sh image first"
             if [[ $EUID -eq 0 ]]; then exec bash scripts/write-usb.sh "$IMG" "${1:?usage: ./build.sh usb /dev/sdX}"
             else exec sudo bash scripts/write-usb.sh "$IMG" "${1:?usage: ./build.sh usb /dev/sdX}"; fi ;;
qemu)        [[ -f $IMG ]] || die "no image; run ./build.sh image first"; exec bash scripts/qemu.sh --disk "$IMG" "$@" ;;
repro-check)
	need_kernel; mkdir -p "$BUILD/repro"
	[[ -d $BUILD/rootfs ]] || bash scripts/rootfs.sh
	bash scripts/mkimage.sh --kernel "$KERNEL" --rootfs "$BUILD/rootfs" --out "$BUILD/repro/a.img"
	sleep 2   # different wall-clock time must not change the output
	bash scripts/mkimage.sh --kernel "$KERNEL" --rootfs "$BUILD/rootfs" --out "$BUILD/repro/b.img"
	if cmp -s "$BUILD/repro/a.img" "$BUILD/repro/b.img"; then log "REPRODUCIBLE: images are bit-identical"
	else die "NOT reproducible: images differ (cmp -l build/repro/{a,b}.img | head)"; fi ;;
harness-selftest) need_kernel; exec bash tests/harness-selftest.sh "$KERNEL" ;;
clean)       rm -rf "$BUILD"; log "removed build/ (sources/ cache kept)" ;;
all)
	bash scripts/check-host.sh
	bash scripts/fetch.sh
	bash scripts/toolchain.sh
	bash tests/toolchain-smoke.sh
	if [[ -n ${KERNEL:-} ]]; then scripts/mkimage.sh --kernel "$KERNEL" --out "$IMG"
	else log "Phase 0 complete. No kernel yet, so no disk image (Phase 1)."; fi ;;
*) sed -n '2,27p' "$0"; exit 1 ;;
esac
