#!/usr/bin/env bash
# mbaos — one entry point for everything.
#
#   ./build.sh                 = ./build.sh all
#   ./build.sh all             check-host, fetch, toolchain, smoke (+ image once a kernel exists)
#   ./build.sh check-host      verify the build host has every required tool
#   ./build.sh lock [NAME..]   pin sources: verify GPG signature, record sha256
#   ./build.sh fetch [NAME..]  download + sha256-verify pinned sources
#   ./build.sh toolchain       build the musl cross toolchain into build/tools
#   ./build.sh smoke           test the toolchain (hardening, musl, Broadwell)
#   ./build.sh image KERNEL=F  build build/mbaos.img with kernel F as BOOTX64.EFI
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
	# Phase 1 will set this to the kernel we build ourselves.
	[[ -n ${KERNEL:-} ]] || die "no kernel yet (Phase 1 builds ours). Pass KERNEL=/path/to/bzImage"
	[[ -f $KERNEL ]] || die "KERNEL=$KERNEL does not exist"
}

cmd=${1:-all}; shift || true
case $cmd in
check-host)  exec scripts/check-host.sh ;;
lock)        exec scripts/lock.sh "$@" ;;
fetch)       exec scripts/fetch.sh "$@" ;;
toolchain)   exec scripts/toolchain.sh ;;
smoke)       exec tests/toolchain-smoke.sh ;;
image)       need_kernel; mkdir -p "$BUILD"; exec scripts/mkimage.sh --kernel "$KERNEL" --out "$IMG" "$@" ;;
qemu)        [[ -f $IMG ]] || die "no image; run ./build.sh image first"; exec scripts/qemu.sh --disk "$IMG" "$@" ;;
repro-check)
	need_kernel; mkdir -p "$BUILD/repro"
	scripts/mkimage.sh --kernel "$KERNEL" --out "$BUILD/repro/a.img"
	sleep 2   # different wall-clock time must not change the output
	scripts/mkimage.sh --kernel "$KERNEL" --out "$BUILD/repro/b.img"
	if cmp -s "$BUILD/repro/a.img" "$BUILD/repro/b.img"; then log "REPRODUCIBLE: images are bit-identical"
	else die "NOT reproducible: images differ (cmp -l build/repro/{a,b}.img | head)"; fi ;;
harness-selftest) need_kernel; exec tests/harness-selftest.sh "$KERNEL" ;;
clean)       rm -rf "$BUILD"; log "removed build/ (sources/ cache kept)" ;;
all)
	scripts/check-host.sh
	scripts/fetch.sh
	scripts/toolchain.sh
	tests/toolchain-smoke.sh
	if [[ -n ${KERNEL:-} ]]; then scripts/mkimage.sh --kernel "$KERNEL" --out "$IMG"
	else log "Phase 0 complete. No kernel yet, so no disk image (Phase 1)."; fi ;;
*) sed -n '2,20p' "$0"; exit 1 ;;
esac
