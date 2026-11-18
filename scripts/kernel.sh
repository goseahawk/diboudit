#!/usr/bin/env bash
# Build the mbaos kernel.
#   kernel.sh             configure (allnoconfig + config/kernel.fragment), verify, build
#   kernel.sh --config    configure + verify only (fast; updates kernel.resolved.config)
# Output: build/kernel/bzImage (EFI-stub PE image = BOOTX64.EFI), System.map, .config
. "$(dirname "$0")/lib.sh"

FRAG=$TOP/config/kernel.fragment
RESOLVED=$TOP/config/kernel.resolved.config
OUT=$BUILD/kernel
OBJ=$BUILD/obj/kernel
CONFIG_ONLY=0; [[ ${1:-} == --config ]] && CONFIG_ONLY=1

[[ -x $TOOLS/bin/$TARGET-gcc ]] || die "no cross toolchain; run ./build.sh toolchain first"
bash "$TOP/scripts/fetch.sh" linux
read -r KV _ < <(lock_get linux)
SRC=$BUILD/src/linux-$KV
if [[ ! -d $SRC ]]; then
	log "unpack linux $KV"; mkdir -p "$BUILD/src"; tar -C "$BUILD/src" -xf "$(src_tarball linux)"
fi
# An out-of-tree build (O=) needs a pristine source tree. Older toolchain builds
# ran headers_install in-tree; clean that up.
if [[ -e $SRC/.config || -d $SRC/include/config || -d $SRC/usr/include/linux ]]; then
	log "linux: source tree not pristine, running mrproper"
	make -C "$SRC" -s mrproper
fi

# The command line's root= must name the partition mkimage.sh creates.
grep -q "root=PARTUUID=$ROOT_PART_GUID " "$FRAG" \
	|| die "kernel.fragment CONFIG_CMDLINE root=PARTUUID does not match ROOT_PART_GUID=$ROOT_PART_GUID"

kmake() {
	make -C "$SRC" O="$OBJ" ARCH=x86_64 CROSS_COMPILE="$TOOLS/bin/$TARGET-" \
		KCFLAGS="-march=$TARGET_ARCH -mtune=$TARGET_ARCH" \
		KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S UTC')" \
		KBUILD_BUILD_USER=mbaos KBUILD_BUILD_HOST=mbaos KBUILD_BUILD_VERSION=1 \
		"$@"
}

log "linux $KV: allnoconfig + $(basename "$FRAG")"
mkdir -p "$OBJ"
kmake -s KCONFIG_ALLCONFIG="$FRAG" allnoconfig >"$OBJ/config.log" 2>&1 \
	|| die "kernel config failed — see $OBJ/config.log"

kconfig_verify "$FRAG" "$OBJ/.config" || die "kernel config does not match kernel.fragment (see above)"
log "config verified: every fragment option present"

# Resolved config without the host-dependent compiler lines. A normal build
# only compares it with the committed copy (a difference means this machine
# configures the kernel differently: a reproducibility problem worth knowing
# about); `./build.sh kernel-config` updates the committed copy.
mkdir -p "$BUILD/kernel"
grep -v -E '^CONFIG_(CC_VERSION_TEXT|GCC_VERSION|AS_VERSION|LD_VERSION|PAHOLE_VERSION|RUSTC_VERSION|BINDGEN_VERSION|CC_HAS_|AS_HAS_|LD_CAN_|LD_IS_|TOOLS_SUPPORT_)' \
	"$OBJ/.config" > "$BUILD/kernel/resolved.config"
if (( CONFIG_ONLY )); then
	cp "$BUILD/kernel/resolved.config" "$RESOLVED"
	log "resolved config updated: $RESOLVED"; exit 0
fi
if ! cmp -s "$BUILD/kernel/resolved.config" "$RESOLVED"; then
	warn "this machine's resolved kernel config differs from config/kernel.resolved.config:"
	diff "$RESOLVED" "$BUILD/kernel/resolved.config" | grep '^[<>]' | head -20 >&2
	warn "(if you changed kernel.fragment, run ./build.sh kernel-config and commit the result)"
fi

log "linux $KV: build bzImage (-j$JOBS)"
start=$SECONDS
kmake -j"$JOBS" bzImage >"$OBJ/build.log" 2>&1 || { tail -30 "$OBJ/build.log" >&2; die "kernel build failed — see $OBJ/build.log"; }
mkdir -p "$OUT"
cp "$OBJ/arch/x86/boot/bzImage" "$OUT/bzImage"
cp "$OBJ/System.map" "$OBJ/.config" "$OUT/"
log "kernel: $OUT/bzImage ($(( $(stat -c %s "$OUT/bzImage") / 1024 )) KiB, $(( SECONDS - start ))s)  sha256=$(sha256sum "$OUT/bzImage" | cut -d' ' -f1)"
