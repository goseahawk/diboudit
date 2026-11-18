#!/usr/bin/env bash
# Build keys/trusted.gpg: the keys allowed to vouch for upstream sources.
#
#   GNU (binutils, gcc, gmp, mpfr, mpc): the GNU project keyring,
#        https://ftp.gnu.org/gnu/gnu-keyring.gpg (every GNU maintainer's key)
#   musl:  https://musl.libc.org/musl.pub (Rich Felker)
#   linux: kernel.org Web Key Directory for torvalds@ and gregkh@kernel.org
#
# Each comes over HTTPS from the project's own domain. That is a single channel,
# so the script prints every fingerprint that will be trusted for kernel/musl and
# asks you to confirm you cross-checked them (keys/README.md lists where).
# Uses a throwaway GNUPGHOME; never touches your personal keyring.
. "$(dirname "$0")/lib.sh"
command -v gpg >/dev/null || die "gpg not installed (gnupg)"

OUT=$TOP/keys/trusted.gpg
[[ -e $OUT && ${1:-} != --force ]] && die "$OUT exists; use './build.sh keys --force' to rebuild it"

G=$(mktemp -d); trap 'rm -rf "$G"' EXIT
export GNUPGHOME=$G; chmod 700 "$G"

log "GNU keyring (binutils, gcc, gmp, mpfr, mpc)"
"$TOP/scripts/fetch.sh" --download-only https://ftp.gnu.org/gnu/gnu-keyring.gpg "$G/gnu-keyring.gpg"
gpg --batch --quiet --import "$G/gnu-keyring.gpg" 2>/dev/null || true
gnu_count=$(gpg --batch --list-keys --with-colons | grep -c '^pub' || true)
(( gnu_count > 0 )) || die "GNU keyring imported no keys"

log "musl signing key"
"$TOP/scripts/fetch.sh" --download-only https://musl.libc.org/musl.pub "$G/musl.pub"
gpg --batch --quiet --import "$G/musl.pub" || die "musl.pub did not import"

log "kernel.org keys via WKD"
# WKD by hand with curl rather than `gpg --locate-keys`: gpg's dirmngr does its
# own DNS and ignores HTTPS proxies, so it fails on many networks.
wkd_hash() { python3 -I -c 'import hashlib,sys
a="ybndrfg8ejkmcpqxot1uwisza345h769"; h=hashlib.sha1(sys.argv[1].lower().encode()).digest()
n=int.from_bytes(h,"big"); print("".join(a[(n>>(155-5*i))&31] for i in range(32)))' "$1"; }
for addr in torvalds@kernel.org gregkh@kernel.org; do
	local_part=${addr%@*}; domain=${addr#*@}; h=$(wkd_hash "$local_part")
	"$TOP/scripts/fetch.sh" --download-only \
		"https://openpgpkey.$domain/.well-known/openpgpkey/$domain/hu/$h?l=$local_part" "$G/$local_part.key" 2>/dev/null \
	|| "$TOP/scripts/fetch.sh" --download-only \
		"https://$domain/.well-known/openpgpkey/hu/$h?l=$local_part" "$G/$local_part.key" \
	|| die "WKD lookup for $addr failed"
	# keep only the user ID for this address (WKD rule), then import
	gpg --batch --quiet --import-filter "keep-uid=mbox=$addr" --import "$G/$local_part.key" \
		|| die "key for $addr did not import"
done

echo
echo "Imported $gnu_count keys from the GNU keyring (fingerprint of the actual"
echo "signer is recorded per tarball in keys/fingerprints.log at lock time)."
echo
echo "Keys for musl and the kernel — CROSS-CHECK these fingerprints now:"
echo "  musl:   https://musl.libc.org/   (and the oss-security release announcements)"
echo "  kernel: https://www.kernel.org/signature.html"
echo
echo "--- musl ---"
gpg --batch --show-keys --fingerprint "$G/musl.pub" | grep -E '^(pub|uid| )' | grep -v '^ *$'
echo "--- kernel ---"
gpg --batch --export torvalds@kernel.org gregkh@kernel.org > "$G/kernel.gpg"
gpg --batch --show-keys --fingerprint "$G/kernel.gpg" | grep -E '^(pub|uid| )' | grep -v '^ *$'
echo
read -r -p "Do these match what the project websites publish? Type 'yes' to trust them: " ans
[[ $ans == yes ]] || die "not confirmed; keys/trusted.gpg not written"

gpg --batch --export > "$OUT.new"
mv "$OUT.new" "$OUT"
log "wrote $OUT ($(gpg --batch --list-keys --with-colons | grep -c '^pub') keys). Next: ./build.sh lock"
