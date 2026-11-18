#!/usr/bin/env bash
# Download sources listed in sources.lock and verify their sha256.
#   fetch.sh            fetch + verify every locked source; refuse unlocked ones
#   fetch.sh NAME...    only those sources
# Never trusts a download whose checksum is not pinned.
. "$(dirname "$0")/lib.sh"

download() { # url dest
	local tmp=$2.part
	curl --fail --location --proto '=https' --tlsv1.2 --retry 4 --retry-delay 3 \
	     --silent --show-error -o "$tmp" "$1"
	mv "$tmp" "$2"
}

fetch_one() {
	local name=$1 v u s g f
	read -r v u s g < <(lock_get "$name")
	[[ $s == - ]] && die "$name $v is not locked (sha256 '-'). Run: ./build.sh lock $name"
	f=$SOURCES/${u##*/}
	mkdir -p "$SOURCES"
	if [[ ! -f $f ]]; then
		log "fetch $name $v"
		download "$u" "$f"
	fi
	if ! echo "$s  $f" | sha256sum --check --quiet --status; then
		mv "$f" "$f.bad"
		die "$name: sha256 mismatch (kept as $f.bad). Expected $s"
	fi
}

if [[ ${1:-} == --download-only ]]; then shift; download "$@"; exit; fi

names=("$@")
[[ ${#names[@]} -eq 0 ]] && mapfile -t names < <(lock_names)
for n in "${names[@]}"; do fetch_one "$n"; done
log "sources verified: ${names[*]}"
