#!/usr/bin/env bash
# shellcheck disable=SC2206  # $SUDO is intentionally empty or one word
# doit.sh — build everything up to the current phase on your Linux machine.
#
#   ./doit.sh
#
# What it does, in order (it stops at the first thing that fails):
#   1. installs any missing build tools (asks before using sudo)
#   2. gets the upstream signing keys        (asks you to check 2 fingerprints)
#   3. pins every source download (sha256)
#   4. builds the cross compiler             (the long part: ~20-60 minutes)
#   5. tests the cross compiler
#   6. builds the kernel                      (~3-10 minutes)
#   7. builds the disk image
#   8. boots the image in QEMU and checks what it reports
#   9. offers to write the image to a USB stick for the Mac (asks twice)
#  10. offers to commit + push the pinned checksums to GitHub
#
# Everything is also written to build/doit.log — send that file to Claude.
# Safe to run again: finished steps are skipped.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
mkdir -p build
LOG=$PWD/build/doit.log
exec > >(tee -a "$LOG") 2>&1

B=$'\033[1m' G=$'\033[1;32m' R=$'\033[1;31m' Y=$'\033[1;33m' N=$'\033[0m'
step()  { printf '\n%s━━━ Step %s ━━━%s\n' "$B" "$*" "$N"; }
ok()    { printf '%s✔ %s%s\n' "$G" "$*" "$N"; }
fail()  {
	printf '\n%s✘ %s%s\n' "$R" "$*" "$N"
	printf '\nStopped. Send this file to Claude:  %s\n' "$LOG"
	exit 1
}
ask()   { local a; read -r -p "$1 [y/N] " a </dev/tty; [[ $a == [yY]* ]]; }

echo "mbaos (up to Phase 1) — $(date -u '+%Y-%m-%d %H:%M UTC') — $(uname -srm)"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail "This needs a 64-bit x86 Linux machine (got $(uname -sm))."
SUDO=; [[ $EUID -ne 0 ]] && SUDO=sudo

# ---- 1. build tools ---------------------------------------------------------------
step "1/10: build tools"
if ! bash ./build.sh check-host >/dev/null 2>&1; then
	if   command -v apt-get >/dev/null; then
		cmd=($SUDO apt-get install -y build-essential bison flex gawk texinfo m4 perl python3 bc rsync xz-utils curl gpgv gnupg patch gdisk dosfstools mtools e2fsprogs qemu-system-x86 ovmf file lz4 libelf-dev)
		pre=($SUDO apt-get update)
	elif command -v pacman >/dev/null; then
		cmd=($SUDO pacman -S --needed --noconfirm base-devel bison flex gawk texinfo perl python bc rsync xz curl gnupg patch gptfdisk dosfstools mtools e2fsprogs qemu-system-x86 edk2-ovmf file lz4 libelf)
		pre=(true)
	elif command -v dnf >/dev/null; then
		cmd=($SUDO dnf install -y gcc gcc-c++ make bison flex gawk texinfo m4 perl python3 bc rsync xz curl gnupg2 patch gdisk dosfstools mtools e2fsprogs qemu-system-x86 edk2-ovmf file lz4 elfutils-libelf-devel)
		pre=(true)
	else
		bash ./build.sh check-host
		fail "Unknown Linux distribution. Install the tools listed above, then run ./doit.sh again."
	fi
	echo "Some build tools are missing. This command will install them:"
	echo "  ${cmd[*]}"
	ask "Install them now?" || fail "Tools not installed."
	"${pre[@]}" && "${cmd[@]}" || fail "Package install failed."
fi
bash ./build.sh check-host || fail "Build tools still missing (see above)."
ok "build tools present"

# ---- 2. signing keys --------------------------------------------------------------
step "2/10: upstream signing keys"
if [[ -s keys/trusted.gpg ]]; then
	ok "already have keys/trusted.gpg"
else
	cat <<EOF
${Y}Your one manual check:${N} the script will show fingerprints (long hex strings)
for the Linux kernel and musl keys. Open these pages and check that the
fingerprints match:
    kernel:  https://www.kernel.org/signature.html   (Torvalds + Kroah-Hartman)
    musl:    https://musl.libc.org/
Matching means the downloads really come from those projects. If they match,
type yes.
EOF
	bash ./build.sh keys || fail "Getting signing keys failed (or you did not type yes)."
	ok "keys/trusted.gpg written"
fi

# ---- 3. pin sources ---------------------------------------------------------------
step "3/10: pin source downloads (verify signatures, record sha256)"
bash ./build.sh lock || fail "Pinning sources failed."
ok "all sources pinned in sources.lock"

# ---- 4+5. toolchain + smoke test ----------------------------------------------------
step "4/10: build the cross compiler (long: get a coffee)"
start=$SECONDS
bash ./build.sh fetch     || fail "Downloading sources failed."
bash ./build.sh toolchain || fail "Cross compiler build failed. The logs named above have the details."
ok "cross compiler built in $(( (SECONDS-start)/60 )) min"

step "5/10: test the cross compiler"
bash ./build.sh smoke || fail "Cross compiler test failed."
ok "cross compiler passes every check"

# ---- 6-8. kernel, image, QEMU boot test -------------------------------------------
step "6/10: build the kernel"
bash ./build.sh kernel || fail "Kernel build failed."
ok "kernel built: build/kernel/bzImage"

step "7/10: build the disk image"
bash ./build.sh rootfs && bash ./build.sh image || fail "Disk image build failed."
ok "disk image: build/mbaos.img"

step "8/10: boot the image in QEMU (the same way the Mac will)"
bash ./build.sh test || fail "QEMU boot test failed."
ok "QEMU boot test passed (screenshot: build/phase1/screen.png)"

# ---- 9. USB stick (optional) ---------------------------------------------------------
step "9/10: USB stick for the Mac (optional)"
# USB disks with media in them (an empty card reader shows up as size 0)
usb=$(lsblk -dnpbo NAME,TRAN,SIZE,MODEL 2>/dev/null | awk '$2=="usb" && $3>0 {printf "%-10s %6.1f GB  ", $1, $3/1e9; for (i=4;i<=NF;i++) printf "%s ", $i; print ""}')
if [[ -z $usb ]]; then
	echo "No USB stick plugged in. Skipping. Later: plug one in and run ./doit.sh again,"
	echo "or: ./build.sh usb /dev/sdX"
else
	echo "USB disks found (everything on the one you pick will be ERASED):"
	echo "$usb" | sed 's/^/    /'
	if ask "Write the image to one of these now?"; then
		read -r -p "Device path (e.g. /dev/sdb): " dev </dev/tty
		bash ./build.sh usb "$dev" || printf '%s! USB write did not happen%s (see above)\n' "$Y" "$N"
	else
		echo "Skipped. Later: ./build.sh usb /dev/sdX"
	fi
fi

# ---- 7. save pinned checksums to GitHub ----------------------------------------------
step "10/10: save the pinned checksums to GitHub"
if git rev-parse --git-dir >/dev/null 2>&1 && [[ -n $(git status --porcelain -- sources.lock keys/) ]]; then
	git --no-pager diff --stat -- sources.lock keys/ 2>/dev/null
	if ! git config user.name >/dev/null || ! git config user.email >/dev/null; then
		printf '%s! git does not know who you are yet.%s Run these once, then ./doit.sh again:\n' "$Y" "$N"
		echo '    git config --global user.name  "Your Name"'
		echo '    git config --global user.email "you@users.noreply.github.com"'
	elif ask "Commit sources.lock + keys/ and push to GitHub?"; then
		git add sources.lock keys/trusted.gpg keys/fingerprints.log &&
		git commit -q -m "Pin Phase 0 sources (GPG-verified sha256 + signing keys)" &&
		{ git push && ok "pushed" || printf '%s! push failed%s — run: git push\n' "$Y" "$N"; }
	else
		echo "Skipped. Later: git add sources.lock keys/ && git commit -m 'Pin sources' && git push"
	fi
else
	ok "nothing new to commit"
fi

printf '\n%s━━━ ALL DONE (up to Phase 1) ━━━%s\nSend this file to Claude:  %s\n' "$G" "$N" "$LOG"
