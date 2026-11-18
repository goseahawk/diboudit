# Upstream signing keys

`./build.sh lock` pins a source only after `gpgv` verifies its upstream
signature against `keys/trusted.gpg`. Build that keyring once:

```bash
./build.sh keys
```

It uses a throwaway GnuPG home, so your personal keyring is untouched. It fetches:

| Sources | Keys | From |
|---|---|---|
| binutils, gcc, gmp, mpfr, mpc | GNU project keyring (all GNU maintainers) | https://ftp.gnu.org/gnu/gnu-keyring.gpg |
| musl | Rich Felker's release key | https://musl.libc.org/musl.pub |
| linux | Linus Torvalds, Greg Kroah-Hartman | kernel.org Web Key Directory |

It then prints the musl and kernel fingerprints and writes the keyring only
if you type `yes`. **Before you do, cross-check them** on a second channel:

* kernel: https://www.kernel.org/signature.html
* musl: the musl website and the release announcements on the oss-security list

Trade-offs, stated plainly:

* Each key arrives over HTTPS from the project's own domain. That is one
  channel; the cross-check is the second.
* The GNU keyring trusts every GNU maintainer, not only the release managers
  for our five packages. To narrow that, `keys/fingerprints.log` records the
  key that actually signed each locked tarball, so you can audit the exact
  signer after `lock`.

Then:

```bash
./build.sh lock      # verifies signatures, writes sha256 into sources.lock
./build.sh           # fetch, toolchain, smoke test
```

Commit `keys/trusted.gpg`, `keys/fingerprints.log` and `sources.lock` together.
