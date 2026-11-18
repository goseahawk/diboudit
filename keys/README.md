# Upstream signing keys

`scripts/lock.sh` only pins a source after `gpgv` verifies its upstream
signature against `keys/trusted.gpg`. That keyring starts empty on purpose:
I didn't write fingerprints from memory. You build it once and check each
fingerprint against a second, independent channel.

| Source   | Who signs releases                         | Where to cross-check the fingerprint            |
|----------|--------------------------------------------|-------------------------------------------------|
| binutils | GNU binutils release manager (Nick Clifton) | release announcement on sourceware.org mailing lists |
| gcc      | GCC release managers                       | gcc.gnu.org/mirrors.html (lists signing keys)   |
| gmp      | GMP maintainers (Niels Möller)             | gmplib.org                                      |
| mpfr     | Vincent Lefèvre                            | mpfr.org                                        |
| mpc      | Andreas Enge                               | multiprecision.org                              |
| musl     | Rich Felker                                | musl.libc.org (key linked from releases page)   |
| linux    | Greg Kroah-Hartman / Linus Torvalds        | kernel.org/signature.html (WKD: `gpg --locate-keys gregkh@kernel.org`) |

Procedure:

```bash
gpg --locate-keys torvalds@kernel.org gregkh@kernel.org   # kernel.org WKD
gpg --recv-keys <FPR> ...                                 # the others, by full fingerprint
gpg --fingerprint                                         # compare against the sites above
gpg --export <FPR> ... > keys/trusted.gpg
./build.sh lock
```

`keys/fingerprints.log` then records which key signed every pinned tarball.
Commit `trusted.gpg`, `fingerprints.log` and `sources.lock` together.
