#!/usr/bin/env bash
# Prove the cross toolchain produces correct, hardened Broadwell/musl binaries.
# Runs on the x86_64 build host (needs AVX2, i.e. Haswell or newer; QEMU-free).
. "$(dirname "$0")/../scripts/lib.sh"
# shellcheck source=/dev/null
. "$BUILD/toolchain.env"

T=$BUILD/smoke; rm -rf "$T"; mkdir -p "$T"; cd "$T" || exit 1
fail=0
check() { if eval "$2"; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=1; fi; }

cat > hello.c <<'EOF'
#include <stdio.h>
#include <string.h>
int copy(const char *s) { char buf[64]; strcpy(buf, s); return (int)strlen(buf); }
int main(int argc, char **argv) { printf("hello from musl (%d)\n", copy(argv[0])); return 0; }
EOF
cat > hello.cc <<'EOF'
#include <iostream>
#include <string>
#include <thread>
int main() { std::string s = "c++"; std::thread t([&]{ s += " threads"; }); t.join(); std::cout << "hello from " << s << "\n"; }
EOF

$CC  $CFLAGS hello.c  -o hello-dyn $LDFLAGS
$CC  $CFLAGS hello.c  -o hello-static -static-pie
$CXX $CXXFLAGS hello.cc -o hello-cxx $LDFLAGS -pthread

LOADER=$SYSROOT/usr/lib/libc.so     # musl's libc.so is also its dynamic linker
echo "toolchain: $($CC --version | head -1)"
check "default -march is broadwell"   "$CC -Q --help=target 2>/dev/null | grep -Eq '^\s+-march=\s+broadwell'"
check "AVX2 enabled by default"       "echo | $CC -dM -E - | grep -q __AVX2__"
check "static-pie binary runs"        "./hello-static | grep -q 'hello from musl'"
check "dynamic binary runs (musl ld)" "$LOADER ./hello-dyn | grep -q 'hello from musl'"
# gcc puts the target's libstdc++/libgcc_s in lib/ or lib64/ depending on the
# target; find it rather than guess. Without the right path musl's loader
# falls back to the host's /lib and picks up glibc's libstdc++.
CXXLIBDIR=$(dirname "$(find "$TOOLS/$TARGET" -name 'libstdc++.so.6' -print -quit 2>/dev/null)" 2>/dev/null || true)
check "C++ runtime libs found"        "[[ -n \$CXXLIBDIR && -e \$CXXLIBDIR/libstdc++.so.6 ]]"
check "C++ + threads runs"            "$LOADER --library-path \"\$CXXLIBDIR\" ./hello-cxx | grep -q 'c++ threads'"
check "interpreter is ld-musl"        "$READELF -l hello-dyn | grep -q 'ld-musl-x86_64.so.1'"
check "PIE (ELF type DYN)"            "$READELF -h hello-dyn | grep -q 'DYN'"
check "full RELRO (BIND_NOW)"         "$READELF -d hello-dyn | grep -Eq 'BIND_NOW|FLAGS.*NOW'"
check "GNU_RELRO segment"             "$READELF -l hello-dyn | grep -q GNU_RELRO"
check "non-executable stack"          "$READELF -lW hello-dyn | awk '/GNU_STACK/{print \$7}' | grep -qx RW"
check "no RWX segments (W^X)"         "! $READELF -lW hello-dyn | awk '/LOAD/{print \$7}' | grep -q RWE"
check "stack protector emitted"       "$READELF -sW hello-dyn | grep -q __stack_chk_fail"
check "deterministic: rebuild same"   "$CC $CFLAGS hello.c -o hello-dyn2 $LDFLAGS && cmp -s hello-dyn hello-dyn2"
exit $fail
