#!/usr/bin/env bash
# Verify the Linux build host has what the build needs. Prints a package hint
# for Debian/Ubuntu and Arch for anything missing.
. "$(dirname "$0")/lib.sh"

missing=()
need() { command -v "$1" >/dev/null || missing+=("$1 ($2)"); }
need gcc        "gcc / build-essential"
need g++        "g++ / build-essential"
need make       "make"
need bison      "bison"
need flex       "flex"
need gawk       "gawk"
need makeinfo   "texinfo"
need m4         "m4"
need perl       "perl"
need python3    "python3"
need bc         "bc"
need rsync      "rsync (kernel headers_install)"
need xz         "xz-utils / xz"
need curl       "curl"
need gpgv       "gpgv / gnupg"
need gpg        "gnupg (./build.sh keys)"
need sha256sum  "coreutils"
need patch      "patch"
need sgdisk     "gdisk"
need mkfs.vfat  "dosfstools"
need mcopy      "mtools"
need mkfs.ext4  "e2fsprogs"
need qemu-system-x86_64 "qemu-system-x86"
need file       "file"

ovmf=$(ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/edk2/x64/OVMF_CODE*.fd /usr/share/edk2/ovmf/OVMF_CODE*.fd 2>/dev/null | head -1 || true)
[[ -n $ovmf || -n ${OVMF_CODE:-} ]] || missing+=("OVMF firmware (ovmf / edk2-ovmf)")

if (( ${#missing[@]} )); then
	printf 'missing: %s\n' "${missing[@]}" >&2
	echo "Debian/Ubuntu: sudo apt install build-essential bison flex gawk texinfo m4 perl python3 bc rsync xz-utils curl gpgv gnupg patch gdisk dosfstools mtools e2fsprogs qemu-system-x86 ovmf file" >&2
	echo "Arch:          sudo pacman -S base-devel bison flex gawk texinfo perl python bc rsync xz curl gnupg patch gptfdisk dosfstools mtools e2fsprogs qemu-system-x86 edk2-ovmf file" >&2
	exit 1
fi
grep -qw avx2 /proc/cpuinfo || warn "host CPU lacks AVX2: toolchain smoke test cannot run target binaries natively"
[[ -w /dev/kvm ]] || warn "no /dev/kvm: QEMU will use slow TCG emulation; boot-time numbers will be meaningless"
avail=$(df -Pk "$TOP" | awk 'NR==2{print int($4/1048576)}')
(( avail >= 15 )) || warn "only ${avail} GiB free; the toolchain build needs ~10 GiB"
log "host OK ($(nproc) jobs, ${avail} GiB free)"
