#!/usr/bin/env bash
# Lock (pin) sources: download, verify upstream GPG signature against the
# project keyring keys/trusted.gpg, then record the sha256 in sources.lock.
#   lock.sh             lock every unlocked source
#   lock.sh NAME...     (re)lock those sources, e.g. after bumping a version
# The signing key fingerprint is appended to keys/fingerprints.log so every
# key that ever vouched for a source is on record.
. "$(dirname "$0")/lib.sh"

KEYRING=$TOP/keys/trusted.gpg
[[ -s $KEYRING ]] || die "no keyring at keys/trusted.gpg — run ./build.sh keys first (see keys/README.md)"
command -v gpgv >/dev/null || die "gpgv not installed"

lock_one() {
	local name=$1 v u s g f sig data status fpr sum
	read -r v u s g < <(lock_get "$name")
	f=$SOURCES/${u##*/}
	sig=$SOURCES/${g##*/}
	mkdir -p "$SOURCES"
	[[ -f $f ]]   || { log "download $name $v"; bash "$TOP/scripts/fetch.sh" --download-only "$u" "$f"; }
	[[ -f $sig ]] || bash "$TOP/scripts/fetch.sh" --download-only "$g" "$sig"

	data=$f
	if [[ $sig == *.tar.sign ]]; then
		# kernel.org signs the uncompressed tarball
		data=$BUILD/lock-tmp.tar
		mkdir -p "$BUILD"
		xz -dc "$f" > "$data"
	fi
	status=$(gpgv --keyring "$KEYRING" --status-fd 1 "$sig" "$data" 2>/dev/null) \
		|| die "$name: BAD or unverifiable signature — not locking"
	[[ $data != "$f" ]] && rm -f "$data"
	fpr=$(awk '$2=="VALIDSIG"{print $3; exit}' <<<"$status")
	[[ -n $fpr ]] || die "$name: no VALIDSIG in gpgv output"

	sum=$(sha256sum "$f" | cut -d' ' -f1)
	# rewrite only the 4th column of this source's line
	awk -v n="$name" -v sum="$sum" '
		$1==n && !/^[[:space:]]*#/ { $4=sum } { print }' OFS='  ' "$TOP/sources.lock" > "$TOP/sources.lock.new"
	mv "$TOP/sources.lock.new" "$TOP/sources.lock"
	printf '%s %s %s signed-by %s\n' "$name" "$v" "$sum" "$fpr" >> "$TOP/keys/fingerprints.log"
	log "locked $name $v  sha256=$sum  key=$fpr"
}

# --verify: re-check the signature of every LOCKED source against our keyring
# and its pinned sha256, without changing anything. Proves that pins made
# elsewhere (another machine, the development container) hold up here.
if [[ ${1:-} == --verify ]]; then
	bad=0
	while read -r n _; do
		read -r v u s g < <(lock_get "$n")
		[[ $s == - ]] && continue
		f=$SOURCES/${u##*/}; sig=$SOURCES/${g##*/}
		bash "$TOP/scripts/fetch.sh" "$n" >/dev/null || { bad=1; continue; }
		[[ -f $sig ]] || bash "$TOP/scripts/fetch.sh" --download-only "$g" "$sig"
		data=$f
		if [[ $sig == *.tar.sign ]]; then data=$BUILD/lock-tmp.tar; mkdir -p "$BUILD"; xz -dc "$f" > "$data"; fi
		if fpr=$(gpgv --keyring "$KEYRING" --status-fd 1 "$sig" "$data" 2>/dev/null | awk '$2=="VALIDSIG"{print $3; exit}') && [[ -n $fpr ]]; then
			log "ok  $n $v  signed by $fpr"
		else
			warn "BAD $n $v: signature does not verify against keys/trusted.gpg"; bad=1
		fi
		[[ $data != "$f" ]] && rm -f "$data"
	done < <(lock_names | sed 's/$/ x/')
	(( bad == 0 )) || die "signature verification failed (missing key? run: ./build.sh keys --force)"
	log "all locked sources: sha256 pinned and signatures verified"
	exit 0
fi

names=("$@")
if [[ ${#names[@]} -eq 0 ]]; then
	mapfile -t names < <(awk '!/^[[:space:]]*(#|$)/ && $4=="-" {print $1}' "$TOP/sources.lock")
fi
[[ ${#names[@]} -eq 0 ]] && { log "all sources already locked"; exit 0; }
for n in "${names[@]}"; do lock_one "$n"; done
