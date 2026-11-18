#!/usr/bin/env bash
# Assemble the root filesystem tree in build/rootfs:
#   merged-/usr FHS layout (/bin, /sbin, /lib are symlinks into /usr)
#   musl (dynamic loader + libc), BusyBox, our init/svd/sv/bootreport,
#   and the plain-text configuration in rootfs/ (committed in the repo).
# Ownership is not set here: mkimage.sh makes every file root-owned.
. "$(dirname "$0")/lib.sh"
# shellcheck source=/dev/null
. "$BUILD/toolchain.env" 2>/dev/null || die "no cross toolchain; run ./build.sh toolchain first"
[[ -x $BUILD/busybox-root/usr/bin/busybox ]] || bash "$TOP/scripts/busybox.sh"

R=$BUILD/rootfs
rm -rf "$R"
mkdir -p "$R"/usr/{bin,sbin,lib,libexec} "$R"/{dev,proc,sys,run,tmp,root,home,mnt,etc} "$R"/var/tmp
ln -s usr/bin "$R/bin"; ln -s usr/sbin "$R/sbin"; ln -s usr/lib "$R/lib"
ln -s ../run "$R/var/run"
chmod 1777 "$R/tmp" "$R/var/tmp"; chmod 0700 "$R/root"

log "rootfs: musl"
install -m 0755 "$SYSROOT/usr/lib/libc.so" "$R/usr/lib/libc.so"
$STRIP "$R/usr/lib/libc.so"
ln -s libc.so "$R/usr/lib/ld-musl-x86_64.so.1"      # /lib/ld-musl-x86_64.so.1 via /lib -> usr/lib

log "rootfs: busybox"
cp -a "$BUILD/busybox-root/usr/." "$R/usr/"

log "rootfs: init, svd, sv, bootreport"
cc() { # out src [extra flags] — our CFLAGS/LDFLAGS (word splitting intended)
	local out=$1 src=$2; shift 2
	# shellcheck disable=SC2086
	$CC $CFLAGS -Wall -Wextra -Werror -ffile-prefix-map="$TOP"=. -o "$out" "$src" $LDFLAGS "$@"   # extra flags last: -static-pie must win over -pie
	$STRIP "$out"
}
# PID 1 and the supervisor are static-pie: they must work even if the dynamic
# loader or libc on disk is damaged.
cc "$R/usr/sbin/init" "$TOP/src/init/init.c" -static-pie
cc "$R/usr/sbin/svd"  "$TOP/src/init/svd.c"  -static-pie
cc "$R/usr/bin/bootreport" "$TOP/src/tools/bootreport.c"
install -m 0755 "$TOP/src/init/sv" "$R/usr/sbin/sv"

log "rootfs: configuration (rootfs/)"
cp -a "$TOP/rootfs/." "$R/"
# git records only 644/755; set the modes that matter
chmod 0600 "$R/etc/shadow"
chmod 0755 "$R/etc/rc" "$R"/etc/sv/*/run "$R"/usr/libexec/mbaos/*

# Everything dynamically linked must find its libraries in the image.
for f in "$R"/usr/bin/busybox "$R"/usr/bin/bootreport; do
	interp=$($READELF -l "$f" | sed -n 's/.*interpreter: \(.*\)]/\1/p')
	[[ -z $interp || -e $R$interp ]] || die "$f needs $interp, which is not in the rootfs"
done
log "rootfs: $R ($(du -sh "$R" | cut -f1), $(find "$R" | wc -l) entries)"
