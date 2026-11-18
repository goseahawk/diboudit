#!/usr/bin/env bash
# Assemble the root filesystem tree in build/rootfs.
# Phase 1: only the boot probe as /sbin/init (a stand-in, replaced by our real
# init in Phase 2) plus the mount points it and the kernel need.
. "$(dirname "$0")/lib.sh"
# shellcheck source=/dev/null
. "$BUILD/toolchain.env" 2>/dev/null || die "no cross toolchain; run ./build.sh toolchain first"

R=$BUILD/rootfs
rm -rf "$R"; mkdir -p "$R"/{dev,proc,sys,sbin,tmp}

log "rootfs: bootprobe (stand-in /sbin/init)"
# shellcheck disable=SC2086  # CFLAGS/LDFLAGS are intentionally word-split
$CC $CFLAGS -ffile-prefix-map="$TOP"=. -static-pie -o "$R/sbin/init" "$TOP/tests/bootprobe.c" -Wl,-z,relro,-z,now,-z,noexecstack
$STRIP "$R/sbin/init"
chmod 0755 "$R/sbin/init"
echo "mbaos Phase 1 root filesystem: /sbin/init is the boot probe (tests/bootprobe.c)" > "$R/README"
log "rootfs: $R ($(du -sh "$R" | cut -f1))"
