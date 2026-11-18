# shellcheck shell=bash
# Common environment for all mbaos scripts. Sourced, never executed.

set -euo pipefail

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../config/target.conf
. "$TOP/config/target.conf"

BUILD=${BUILD:-$TOP/build}
SOURCES=${SOURCES:-$TOP/sources}     # download cache (tarballs), safe to keep across builds
TOOLS=$BUILD/tools                   # cross toolchain prefix
SYSROOT=$TOOLS/$TARGET/sysroot       # target headers + libc the cross compiler links against
STAMPS=$BUILD/stamps
JOBS=${JOBS:-$(nproc)}

# Reproducible environment for everything we run.
export LC_ALL=C TZ=UTC SOURCE_DATE_EPOCH
umask 022

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# lock_get NAME -> prints "version url sha256 sigurl" with {v} expanded.
lock_get() {
	local name=$1 n v u s g
	while read -r n v u s g; do
		[[ -z $n || $n == \#* ]] && continue
		if [[ $n == "$name" ]]; then
			printf '%s %s %s %s\n' "$v" "${u//\{v\}/$v}" "$s" "${g//\{v\}/$v}"
			return 0
		fi
	done < "$TOP/sources.lock"
	die "source '$name' not in sources.lock"
}

lock_names() { awk '!/^[[:space:]]*(#|$)/ {print $1}' "$TOP/sources.lock"; }

# src_tarball NAME -> path of the cached tarball for NAME.
src_tarball() {
	local v u s g
	read -r v u s g < <(lock_get "$1")
	printf '%s/%s\n' "$SOURCES" "${u##*/}"
}

# Stamps make each step idempotent: `stamp_done X || { ...; stamp X; }`.
stamp_done() { [[ -f $STAMPS/$1 ]]; }
stamp()      { mkdir -p "$STAMPS"; : > "$STAMPS/$1"; }

# Clamp mtimes of a tree to SOURCE_DATE_EPOCH (for anything packed into an image).
clamp_mtimes() { find "$1" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +; }

# kconfig_verify FRAGMENT DOTCONFIG: every option in the fragment must appear
# exactly in the resolved .config. Kconfig silently drops options whose name
# changed or whose dependencies are unmet; this turns that into a build error.
kconfig_verify() {
	local frag=$1 cfg=$2 line want sym have missing=0
	while IFS= read -r line; do
		case $line in
		CONFIG_*=*)                 want=$line ;;
		"# CONFIG_"*" is not set")  want=$line ;;
		*) continue ;;
		esac
		sym=${want#\# }; sym=${sym%%[= ]*}
		have=$(grep -E "^(# )?${sym}[= ]" "$cfg" || true)
		if [[ $want == "#"* ]]; then
			[[ -z $have || $have == "$want" ]] && continue
		else
			[[ $have == "$want" ]] && continue
		fi
		printf '  wanted: %s\n  got:    %s\n' "$want" "${have:-(absent: unknown symbol or unmet dependency)}" >&2
		missing=1
	done < "$frag"
	return $missing
}
