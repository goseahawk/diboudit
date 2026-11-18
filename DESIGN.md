# mbaos — design

A minimal Unix-like OS for exactly one machine: the MacBook Air 7,1 / 7,2
(early 2015, Broadwell-U). Linux kernel; everything above it is built from source
here. This file is updated before each phase; each section records what was
decided and why, and lists every known stub.

## Overall stack (defaults; each is confirmed or revised in its phase)

| Layer            | Choice                                   | Decided in |
|------------------|------------------------------------------|------------|
| Toolchain        | GCC 16.2 + binutils 2.47, cross, musl target | Phase 0 ✔ |
| libc             | musl 1.2.6 + 2 upstream CVE patches      | Phase 0 ✔ |
| Boot             | Kernel EFI stub as `\EFI\BOOT\BOOTX64.EFI`, no bootloader | Phase 0 ✔ (layout), Phase 1 (kernel) |
| Kernel           | Latest stable, allnoconfig-up, built-in drivers, PREEMPT, HZ=1000 | Phase 1 |
| Init / services  | Our own PID 1 plus a supervisor          | Phase 2 |
| Userland         | BusyBox to start                         | Phase 2 |
| Device mgmt      | Small custom hotplug handler or mdev     | Phase 2/3 |
| Root fs          | ext4 (see Phase 0 §0.5); revisited in Phase 6 if snapshots become a goal | Phase 0 (provisional) |
| Graphics         | Own Wayland compositor                   | Phase 5 |
| Packages         | Source recipes → binary packages         | Phase 2 (format), Phase 6 (updates) |

---

## Phase 0 — build environment

### 0.1 Goal and deliverable

From a Linux build host, `./build.sh` checks the host, fetches pinned and
verified sources, builds an `x86_64-mba-linux-musl` cross toolchain, and proves
it makes hardened Broadwell binaries. `./build.sh image` and `./build.sh qemu`
turn any EFI-stub kernel into a reproducible GPT disk image and boot it under
QEMU + OVMF exactly the way the Mac's firmware will.

### 0.2 Compiler: GCC, not Clang

* The kernel is best tested with GCC, and one compiler for kernel and userland
  means one set of bugs to understand.
* GCC + musl is a well-trodden pairing (Alpine, musl-cross-make). A Clang/musl
  toolchain also has to bootstrap compiler-rt, libunwind and libc++ against
  musl. That's more moving parts for no measurable gain on this machine.
* Clang can still be added later for one-off uses (e.g. a sanitizer build of
  the compositor on the host).

### 0.3 Toolchain construction (LFS-style, `scripts/toolchain.sh`)

1. **binutils**: deterministic archives, RELRO, GNU hash, and warnings for
   executable stacks and RWX segments switched on.
2. **gcc pass 1**: C only, `--without-headers --with-newlib`, static libgcc.
   It exists only to compile musl.
3. **Linux UAPI headers**: `headers_install` into the sysroot.
4. **musl**: built with the pass-1 compiler and installed into the sysroot.
   The dynamic linker is `/lib/ld-musl-x86_64.so.1`.
5. **gcc pass 2**: C and C++, shared libgcc, libstdc++, POSIX threads.

GMP, MPFR and MPC are built in-tree with GCC (no host library dependencies).

**Machine baked in:** `--with-arch=broadwell --with-tune=broadwell`. Every
compile targets Broadwell (AVX2, BMI2, AES-NI, FMA) even if a recipe drops our
CFLAGS. The output deliberately won't run on CPUs older than Haswell.

### 0.4 Hardening, by default

| Feature | How | Status |
|---|---|---|
| PIE / ASLR | GCC `--enable-default-pie` | in place |
| Stack protector | GCC `--enable-default-ssp` (= `-fstack-protector-strong`) | in place |
| Stack clash | `-fstack-clash-protection` in `TARGET_CFLAGS` | in place (flags) |
| Full RELRO, BIND_NOW | `-Wl,-z,relro,-z,now` in `TARGET_LDFLAGS` | in place (flags). Phase 2 moves it into a GCC specs file so a recipe can't forget it |
| W^X: non-exec stack, no RWX segments | `-z noexecstack`; binutils warns on violations; smoke test checks | in place |
| `_FORTIFY_SOURCE` | needs **fortify-headers** (musl has none of its own) | **STUB: not enabled.** Added in Phase 2. It's left out until then because `-D_FORTIFY_SOURCE` without fortify-headers does nothing while looking like hardening |
| Sanitizers | libsanitizer only partly supports musl | disabled in the target toolchain |
| CET / IBT | Broadwell has no CET | not applicable |

`tests/toolchain-smoke.sh` checks each "in place" row on real binaries: PIE,
BIND_NOW, GNU_RELRO, RW stack, no RWE segment, `__stack_chk_fail` referenced,
`-march=broadwell` default, `__AVX2__` defined. It also runs static-pie,
dynamic (through musl's loader) and C++/threads binaries, and checks that two
builds of the same source are identical.

### 0.5 Disk image and boot path (`scripts/mkimage.sh`)

```
GPT  (disk GUID fixed)
 p1  1 MiB  .. 257 MiB   ESP, FAT32 "MBAOS-ESP"    \EFI\BOOT\BOOTX64.EFI = kernel (EFI stub)
 p2  257 MiB .. 1281 MiB  root, ext4 "mbaos-root"  type 8304 (Linux x86-64 root)
```

* **No bootloader.** The Linux EFI stub *is* a UEFI application. Apple's
  64-bit EFI on the 7,x lists any removable disk with the fallback path
  `\EFI\BOOT\BOOTX64.EFI` as **"EFI Boot"** in the Option-key picker. The kernel
  command line will be built into the kernel (`CONFIG_CMDLINE`, Phase 1), so
  the firmware doesn't need to pass one.
* Built **without root or loop devices**: each filesystem is made in a file
  (`mkfs.vfat`, `mtools`, `mkfs.ext4 -d`) and placed with `dd`.
* **ext4, provisionally.** It's simplest and fastest to mount (which matters
  for the 3 s target), has the most mature fsck, and handles TRIM via
  `fstrim` or `discard`. btrfs would bring snapshots for atomic updates, but
  also more mount-time work, more code and more failure modes. The final call
  belongs to Phase 6, when the update mechanism is designed.
* **ESP 256 MiB.** It only holds a ~10 MB kernel today, but leaves room for a
  fallback kernel and stays above the size firmware updaters expect.
* **Reproducible.** Fixed GUIDs, FAT serial, ext4 UUID and hash seed;
  `mkfs.vfat --invariant`; every mtime clamped to `SOURCE_DATE_EPOCH`. ext4
  inode ctimes are rewritten with `debugfs`, because `mkfs.ext4 -d` copies the
  host ctime, which `touch` can't set. The repro check caught exactly this.
  `./build.sh repro-check` builds twice and compares the bytes.

### 0.6 Source pinning and trust (`sources.lock`, `scripts/{lock,fetch}.sh`)

* Every source has a pinned version, URL and **sha256**. `fetch` refuses an
  unpinned source and moves a mismatching download aside.
* Pinning (`./build.sh lock`) happens once per version bump. It verifies the
  upstream **GPG signature** with `gpgv` against `keys/trusted.gpg`, which you
  build by cross-checking fingerprints (`keys/README.md`). Only then is the
  sha256 written. `keys/fingerprints.log` records which key vouched for each
  tarball.
* Downloads are HTTPS-only (`--proto =https`) with retries.
* Build environment: `LC_ALL=C TZ=UTC umask 022 SOURCE_DATE_EPOCH`, plus
  `-ffile-prefix-map` for target code.
* **Known trust gap:** the toolchain is bootstrapped from the host's GCC and
  isn't bit-reproducible across build paths. Reproducibility is promised for
  *target outputs* (packages, images), not for the cross compiler binary.
  This is the normal LFS trade-off; diverse double-compiling is out of scope.

### 0.7 QEMU test harness (`scripts/qemu.sh`)

| Mac hardware | QEMU model |
|---|---|
| Broadwell-U i5/i7, 2C/4T, TSX disabled | `-cpu Broadwell-noTSX-IBRS -smp 4,sockets=1,cores=2,threads=2` |
| 4 or 8 GiB | `-m 4096` (override `QEMU_MEM`) |
| Apple AHCI PCIe SSD | q35's ICH9 AHCI controller, non-rotational, `discard=unmap` |
| 64-bit UEFI | OVMF; a fresh copy of the variable store every run (deterministic) |
| Internal USB keyboard | xHCI with `usb-kbd` and `usb-tablet` |

Two boot modes:

* `--disk IMG`: the real path (firmware → ESP → `BOOTX64.EFI`), the same thing
  the Mac does.
* `--kernel F --append …`: OVMF loads the kernel's EFI stub through fw_cfg.
  This is the fast edit-boot loop.

Automation: `--expect REGEX` stamps each serial line with the time since QEMU
started, exits 0 on a match, and prints the time to match. `--timeout`,
`--screendump PNG` and `--settle` round it out. Boot-time tracking from Phase 2
on is built on this. Without `/dev/kvm` the harness warns that timings are
meaningless.

**What QEMU cannot model, so it's tested only on the Mac:** applesmc (fans and
sensors), the bcm5974 trackpad, BCM4360 Wi-Fi, i915/HD 6000, Apple's firmware
quirks, real suspend, and real boot times. Phase 3 is mostly Mac-only.

### 0.8 Writing USB sticks (`scripts/write-usb.sh`)

The script refuses anything that isn't a whole USB/removable disk. It also
refuses mounted disks, the host's root disk, and devices smaller than the
image. You must type the device path back before it writes. Afterwards it
moves the backup GPT header to the end of the stick. It runs on the build
host and has no path to the Mac's internal SSD.

### 0.9 Phase 0 verification record

| Check | Result |
|---|---|
| shellcheck on all scripts | clean (`.shellcheckrc` documents three disabled style rules) |
| `check-host` | passes |
| `fetch` refuses unlocked sources | verified |
| Image builds unprivileged; `sgdisk --verify` | verified |
| Image reproducible (two builds, `cmp`) | verified, after fixing ext4 ctimes |
| OVMF boots `BOOTX64.EFI` from our GPT disk over AHCI | verified (serial `BdsDxe: starting Boot0001 … QEMU HARDDISK`, plus a framebuffer screendump of the kernel running) |
| EFI-stub kernel boot with a kernel log on serial | verified, up to the expected no-root panic |
| `lock`/`fetch` logic (signature check, sha256 pin, tamper and bad-signature refusal) | verified offline with a throwaway key |
| Key import (`./build.sh keys`), incl. kernel.org WKD through an HTTPS proxy | verified; fingerprints shown matched kernel.org and the musl site |
| Cross toolchain build and smoke test | **NOT YET RUN.** It needs you to confirm the signing keys first. Run `./doit.sh`. |

The harness was checked with a stock Ubuntu 6.8 kernel used as a **test
fixture only**; it isn't part of mbaos. Phase 1 replaces it with our own
kernel.

### 0.10 Versions and security patches

Versions were checked against upstream on 2026-11-18 and pinned to the newest
stable release of each: binutils 2.47, GCC 16.2.0, GMP 6.3.0, MPFR 4.2.2,
MPC 1.3.1, musl 1.2.6, Linux 7.3.5 (UAPI headers only in Phase 0; the Phase 1
kernel uses the same tree).

musl 1.2.6 fixes CVE-2025-26519. It is still affected by advisories listed on
musl.libc.org; patches are vendored in `patches/musl/` (applied automatically,
and pinned by git):

| CVE | Affects | Action |
|---|---|---|
| CVE-2026-107891 | `regcomp` integer overflows → heap OOB write | patched (`0001-…`, Szabolcs Nagy) |
| CVE-2026-6042 | `iconv` GB18030 decoder DoS | patched (`0002-…`, Rich Felker) |
| CVE-2026-40200 | `qsort` on 32-bit archs only | not applicable (x86_64), not applied |

Drop the patches once musl 1.2.7 is released and pinned.

### 0.11 One-command bootstrap

`./doit.sh` runs every Phase 0 step in order: tools, keys, lock, fetch,
toolchain, smoke test, harness self-test, then commits the pins. It logs
everything to `build/doit.log`. It stops for exactly two human decisions:
installing packages with sudo, and confirming the signing-key fingerprints.
