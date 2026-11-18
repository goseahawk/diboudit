#!/usr/bin/env bash
# Build BusyBox: allnoconfig + config/busybox.fragment (verified), cross-compiled
# with our musl toolchain, dynamically linked. Installs into build/busybox-root.
. "$(dirname "$0")/lib.sh"
# shellcheck source=/dev/null
. "$BUILD/toolchain.env" 2>/dev/null || die "no cross toolchain; run ./build.sh toolchain first"

FRAG=$TOP/config/busybox.fragment
bash "$TOP/scripts/fetch.sh" busybox
read -r BV _ < <(lock_get busybox)
SRC=$BUILD/src/busybox-$BV
OBJ=$BUILD/obj/busybox
OUT=$BUILD/busybox-root
[[ -d $SRC ]] || { log "unpack busybox $BV"; mkdir -p "$BUILD/src"; tar -C "$BUILD/src" -xf "$(src_tarball busybox)"; }

bbmake() {
	make -C "$SRC" O="$OBJ" CROSS_COMPILE="$TOOLS/bin/$TARGET-" \
		CONFIG_EXTRA_CFLAGS="$TARGET_CFLAGS -ffile-prefix-map=$SRC=busybox" \
		CONFIG_EXTRA_LDFLAGS="$TARGET_LDFLAGS" \
		KBUILD_VERBOSE=0 "$@"
}

mkdir -p "$OBJ"
log "busybox $BV: allnoconfig + $(basename "$FRAG")"
# BusyBox's older kconfig ignores KCONFIG_ALLCONFIG for allnoconfig, so:
# allnoconfig -> overlay the fragment's values -> oldconfig resolves dependencies.
# kconfig_verify below still proves that every fragment value survived.
bbmake allnoconfig >"$OBJ/config.log" 2>&1 || die "busybox allnoconfig failed — see $OBJ/config.log"
awk 'NR==FNR {
		if ($0 ~ /^CONFIG_[A-Za-z0-9_]+=/) { split($0, kv, "="); want[kv[1]] = $0 }
		else if ($0 ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) want[$2] = $0
		next
	}
	{
		sym = ""
		if ($0 ~ /^CONFIG_[A-Za-z0-9_]+=/) { split($0, kv, "="); sym = kv[1] }
		else if ($0 ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) sym = $2
		if (sym in want) { print want[sym]; done[sym] = 1 } else print
	}
	END { for (k in want) if (!(k in done)) print want[k] }' "$FRAG" "$OBJ/.config" > "$OBJ/.config.new"
mv "$OBJ/.config.new" "$OBJ/.config"
(set +o pipefail; yes "" | bbmake oldconfig) >>"$OBJ/config.log" 2>&1 || die "busybox oldconfig failed — see $OBJ/config.log"
kconfig_verify "$FRAG" "$OBJ/.config" || die "busybox config does not match busybox.fragment (see above)"
log "config verified: every fragment option present"

log "busybox $BV: build"
bbmake -j"$JOBS" busybox >"$OBJ/build.log" 2>&1 || { tail -30 "$OBJ/build.log" >&2; die "busybox build failed — see $OBJ/build.log"; }
rm -rf "$OUT"; mkdir -p "$OUT"/usr/{bin,sbin}
ln -s usr/bin "$OUT/bin"; ln -s usr/sbin "$OUT/sbin"
bbmake CONFIG_PREFIX="$OUT" install >"$OBJ/install.log" 2>&1 || die "busybox install failed — see $OBJ/install.log"
$STRIP "$OUT/usr/bin/busybox"
log "busybox: $(( $(stat -c %s "$OUT/usr/bin/busybox") / 1024 )) KiB, $(find "$OUT" -type l | wc -l) applet links  sha256=$(sha256sum "$OUT/usr/bin/busybox" | cut -d' ' -f1)"
