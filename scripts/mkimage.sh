#!/usr/bin/env bash
# Assemble a bootable GPT disk image, unprivileged (no loop devices, no root).
#
#   mkimage.sh --kernel BZIMAGE --out IMG [--rootfs DIR]
#
# Layout (1 MiB aligned):
#   p1  ESP   FAT32  ESP_SIZE_MIB   \EFI\BOOT\BOOTX64.EFI = the kernel (EFI stub)
#   p2  root  ext4   ROOT_SIZE_MIB  type 4f68bce3-... "Linux x86-64 root" (8304)
#
# The kernel IS the EFI application: no GRUB, no systemd-boot. Apple's Option-key
# boot picker shows a removable disk with \EFI\BOOT\BOOTX64.EFI as "EFI Boot".
# Every identifier and timestamp is fixed (config/target.conf), so the same
# inputs give a bit-identical image (checked by `./build.sh repro-check`).
. "$(dirname "$0")/lib.sh"

KERNEL= OUT= ROOTFS=
while [[ $# -gt 0 ]]; do
	case $1 in
	--kernel) KERNEL=$2; shift 2 ;;
	--out)    OUT=$2;    shift 2 ;;
	--rootfs) ROOTFS=$2; shift 2 ;;
	*) die "usage: mkimage.sh --kernel BZIMAGE --out IMG [--rootfs DIR]" ;;
	esac
done
[[ -f $KERNEL ]] || die "kernel not found: '$KERNEL'"
[[ -n $OUT ]] || die "--out required"

W=$(mktemp -d "${OUT%/*}/.mkimage.XXXXXX"); trap 'rm -rf "$W"' EXIT

MiB=1048576
esp_start=1                                   # MiB
root_start=$((esp_start + ESP_SIZE_MIB))
total=$((root_start + ROOT_SIZE_MIB + 1))     # +1 MiB for the backup GPT

# ---- ESP --------------------------------------------------------------------------
mkdir -p "$W/esp/EFI/BOOT"
cp "$KERNEL" "$W/esp/EFI/BOOT/BOOTX64.EFI"
clamp_mtimes "$W/esp"
truncate -s $((ESP_SIZE_MIB * MiB)) "$W/esp.img"
mkfs.vfat -F 32 -n MBAOS-ESP -i "$ESP_VOLID" --invariant "$W/esp.img" >/dev/null
# mtools: -m keeps the (clamped) mtime; SOURCE_DATE_EPOCH fixes directory entries.
mmd   -i "$W/esp.img" ::/EFI ::/EFI/BOOT
mcopy -i "$W/esp.img" -m "$W/esp/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

# ---- root ---------------------------------------------------------------------------
if [[ -z $ROOTFS ]]; then
	# Phase 0/1: no userland yet. An empty, labelled root fs keeps the disk layout
	# stable from day one; Phase 2 fills it.
	ROOTFS=$W/rootfs; mkdir -p "$ROOTFS"
	echo "mbaos root filesystem placeholder (no userland until Phase 2)" > "$ROOTFS/README"
else
	cp -a "$ROOTFS" "$W/rootfs"; ROOTFS=$W/rootfs
fi
clamp_mtimes "$ROOTFS"
truncate -s $((ROOT_SIZE_MIB * MiB)) "$W/root.img"
E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH mkfs.ext4 -q -F -L mbaos-root \
	-U "$ROOT_FS_UUID" -E "hash_seed=$ROOT_FS_HASH_SEED,root_owner=0:0" \
	-d "$ROOTFS" "$W/root.img"
# mkfs -d copies each file's owner and ctime from the build machine. Make every
# file owned by root (a normal-user build would otherwise ship files, even
# /etc/shadow, owned by that user's uid), and rewrite every ctime, which
# `touch` cannot set, so the image does not depend on when it was built.
if (cd "$ROOTFS" && find . -name '*[[:space:]\"]*' | grep -q .); then
	die "rootfs contains paths with whitespace or quotes; not supported"
fi
(cd "$ROOTFS" && find . -mindepth 1) | sed 's|^\.||' | { echo /; cat; } \
	| awk -v t="$SOURCE_DATE_EPOCH" '{ printf "sif %s uid 0\nsif %s gid 0\nsif %s ctime @%s\n", $0, $0, $0, t }' \
	| E2FSPROGS_FAKE_TIME=$SOURCE_DATE_EPOCH debugfs -w -f - "$W/root.img" >/dev/null 2>"$W/debugfs.log"
grep -qi 'error\|invalid\|not found' "$W/debugfs.log" && die "debugfs ctime fixup failed: $(cat "$W/debugfs.log")"

# ---- GPT + assembly ---------------------------------------------------------------
rm -f "$OUT"; truncate -s $((total * MiB)) "$OUT"
sgdisk --clear -U "$DISK_GUID" \
	-n "1:${esp_start}M:+${ESP_SIZE_MIB}M"  -t 1:EF00 -c 1:"EFI System"  -u "1:$ESP_PART_GUID" \
	-n "2:${root_start}M:+${ROOT_SIZE_MIB}M" -t 2:8304 -c 2:"mbaos-root" -u "2:$ROOT_PART_GUID" \
	"$OUT" >/dev/null
dd if="$W/esp.img"  of="$OUT" bs=1M seek=$esp_start  conv=notrunc,sparse status=none
dd if="$W/root.img" of="$OUT" bs=1M seek=$root_start conv=notrunc,sparse status=none
sgdisk --verify "$OUT" >/dev/null || die "GPT verification failed"
log "image: $OUT ($total MiB)  sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
