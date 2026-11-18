#!/usr/bin/env bash
# Build the x86_64-mba-linux-musl cross toolchain (LFS-style, 5 steps):
#   1. binutils                (cross assembler/linker)
#   2. gcc pass 1              (C only, static libgcc, no libc: enough to build musl)
#   3. linux UAPI headers      (into the sysroot)
#   4. musl                    (target libc, into the sysroot)
#   5. gcc pass 2              (C/C++, shared libgcc, libstdc++, PIE+SSP defaults)
# Output: build/tools/bin/x86_64-mba-linux-musl-{gcc,g++,ld,...}
#         build/tools/x86_64-mba-linux-musl/sysroot   (headers + musl)
#         build/toolchain.env                         (source it to use the toolchain)
. "$(dirname "$0")/lib.sh"

SRC=$BUILD/src
OBJ=$BUILD/obj
export PATH=$TOOLS/bin:$PATH
# Host build flags: the toolchain itself runs on the build host, not the Mac.
export CFLAGS="-O2 -pipe" CXXFLAGS="-O2 -pipe"

"$TOP/scripts/fetch.sh" binutils gcc gmp mpfr mpc musl linux

unpack() { # name -> prints source dir; extracts fresh if absent
	local name=$1 v u s g dir
	read -r v u s g < <(lock_get "$name")
	dir=$SRC/$name-$v
	if [[ ! -d $dir ]]; then
		mkdir -p "$SRC"
		log "unpack $name $v"
		tar -C "$SRC" -xf "$(src_tarball "$name")"
		[[ -d $dir ]] || die "unexpected tarball layout for $name"
		local p
		for p in "$TOP/patches/$name"/*.patch; do
			[[ -e $p ]] || continue
			log "  patch $(basename "$p")"
			patch -d "$dir" -p1 --forward --quiet < "$p"
		done
	fi
	printf '%s\n' "$dir"
}

fresh_obj() { rm -rf "${OBJ:?}/${1:?}"; mkdir -p "$OBJ/$1"; printf '%s\n' "$OBJ/$1"; }

COMMON_GCC_FLAGS=(
	--target="$TARGET" --prefix="$TOOLS" --with-sysroot="$SYSROOT"
	--with-arch="$TARGET_ARCH" --with-tune="$TARGET_ARCH"
	--disable-multilib --disable-nls --disable-werror --disable-bootstrap
	--enable-checking=release
)

# ---- 1. binutils ---------------------------------------------------------------
stamp_done binutils || {
	s=$(unpack binutils); o=$(fresh_obj binutils)
	log "binutils: configure + build"
	( cd "$o" && "$s/configure" \
		--target="$TARGET" --prefix="$TOOLS" --with-sysroot="$SYSROOT" \
		--disable-nls --disable-werror --disable-multilib \
		--disable-gprofng --disable-gdb --disable-gdbserver --disable-sim \
		--enable-deterministic-archives --enable-relro \
		--enable-default-hash-style=gnu --enable-new-dtags \
		--enable-warn-execstack=yes --enable-warn-rwx-segments=yes \
		>configure.log 2>&1 \
	  && make -j"$JOBS" >build.log 2>&1 && make install >install.log 2>&1 ) \
	  || die "binutils failed — see $o/*.log"
	stamp binutils
}

# gcc needs gmp/mpfr/mpc; build them in-tree (same as contrib/download_prerequisites)
link_gcc_prereqs() {
	local g=$1 p
	for p in gmp mpfr mpc; do
		ln -sfn "$(unpack "$p")" "$g/$p"
	done
}

# ---- 2. gcc pass 1 -------------------------------------------------------------
stamp_done gcc1 || {
	s=$(unpack gcc); link_gcc_prereqs "$s"; o=$(fresh_obj gcc1)
	log "gcc pass 1: configure + build (C only, no libc)"
	( cd "$o" && "$s/configure" "${COMMON_GCC_FLAGS[@]}" \
		--enable-languages=c --with-newlib --without-headers \
		--disable-shared --disable-threads --disable-decimal-float \
		--disable-libatomic --disable-libgomp --disable-libquadmath \
		--disable-libssp --disable-libvtv --disable-libstdcxx \
		--disable-libsanitizer \
		>configure.log 2>&1 \
	  && make -j"$JOBS" all-gcc all-target-libgcc >build.log 2>&1 \
	  && make install-gcc install-target-libgcc >install.log 2>&1 ) \
	  || die "gcc pass 1 failed — see $o/*.log"
	stamp gcc1
}

# ---- 3. linux UAPI headers -----------------------------------------------------
stamp_done linux-headers || {
	s=$(unpack linux)
	log "linux: headers_install into sysroot"
	make -C "$s" ARCH=x86_64 INSTALL_HDR_PATH="$SYSROOT/usr" headers_install >"$BUILD/linux-headers.log" 2>&1 \
	  || die "linux headers failed — see $BUILD/linux-headers.log"
	stamp linux-headers
}

# ---- 4. musl -------------------------------------------------------------------
# -fPIC: libc.a must be position-independent so it can be linked into
# static-pie binaries. gcc pass 1 does not default to PIE, so without this
# flag libc.a gets R_X86_64_32 relocations and every -static-pie link fails.
# The stamp is named musl-pic so builds made before this fix redo this step.
stamp_done musl-pic || {
	s=$(unpack musl); o=$(fresh_obj musl)
	log "musl: configure + build"
	( cd "$o" && CC="$TARGET-gcc" AR="$TARGET-ar" RANLIB="$TARGET-ranlib" \
		CFLAGS="-O2 -pipe -fPIC -march=$TARGET_ARCH -ffile-prefix-map=$s=/usr/src/musl" \
		"$s/configure" --prefix=/usr --target="$TARGET" --syslibdir=/lib \
		>configure.log 2>&1 \
	  && make -j"$JOBS" >build.log 2>&1 \
	  && make DESTDIR="$SYSROOT" install >install.log 2>&1 ) \
	  || die "musl failed — see $o/*.log"
	stamp musl-pic
}

# ---- 5. gcc pass 2 -------------------------------------------------------------
stamp_done gcc2 || {
	s=$(unpack gcc); link_gcc_prereqs "$s"; o=$(fresh_obj gcc2)
	log "gcc pass 2: configure + build (C, C++, hardened defaults)"
	( cd "$o" && "$s/configure" "${COMMON_GCC_FLAGS[@]}" \
		--enable-languages=c,c++ \
		--enable-shared --enable-threads=posix --enable-tls \
		--enable-default-pie --enable-default-ssp \
		--enable-__cxa_atexit --enable-initfini-array --enable-linker-build-id \
		--with-linker-hash-style=gnu \
		--disable-libsanitizer --disable-libssp --disable-libvtv \
		--disable-symvers --enable-libstdcxx-time=rt \
		>configure.log 2>&1 \
	  && make -j"$JOBS" >build.log 2>&1 \
	  && make install >install.log 2>&1 ) \
	  || die "gcc pass 2 failed — see $o/*.log"
	stamp gcc2
}

# ---- environment file ----------------------------------------------------------
cat > "$BUILD/toolchain.env" <<EOF
# Generated by scripts/toolchain.sh. Source this to cross-compile for the Mac.
export PATH="$TOOLS/bin:\$PATH"
export CROSS_COMPILE=$TARGET-
export CC=$TARGET-gcc CXX=$TARGET-g++ AR=$TARGET-ar RANLIB=$TARGET-ranlib
export STRIP=$TARGET-strip OBJCOPY=$TARGET-objcopy READELF=$TARGET-readelf
export SYSROOT="$SYSROOT"
export CFLAGS="$TARGET_CFLAGS" CXXFLAGS="$TARGET_CFLAGS" LDFLAGS="$TARGET_LDFLAGS"
EOF
log "toolchain ready: $TOOLS/bin/$TARGET-gcc  (env: build/toolchain.env)"
