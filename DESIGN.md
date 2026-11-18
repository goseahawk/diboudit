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
| Sources pinned | locked on the owner's Arch machine (GPG-verified, signers in `keys/fingerprints.log`); every sha256 independently re-confirmed by downloading from a second network |
| Cross toolchain build and smoke test | all 14 checks pass: on the owner's Arch host, and in a from-scratch build of this repo in a clean Ubuntu 24.04 container (19 min on 4 cores; smoke test repeated 6×, no flakes) |
| Harness self-test on a KVM host | passes (OVMF → `BOOTX64.EFI` in 2.3 s; EFI-stub kernel to the expected panic) |

Bugs the first real run found, all fixed:

* `libc.a` was not PIE-compatible, so `-static-pie` failed to link. Pass-1 GCC
  now defaults to PIE and musl is built with `-fPIE`.
* The C++ test loaded the host's glibc `libstdc++`. Cross target libraries
  live in `lib64`; the test now asks the compiler (`-print-file-name`).
* `cmd | grep -q` under `pipefail` failed at random (SIGPIPE). Checks now run
  with `pipefail` off.
* Distro kernels register the serial console late and drop early lines. The
  self-test passes `earlycon`.

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

---

## Phase 1 — kernel

### 1.1 Goal and deliverable

Our own Linux 7.3.5, configured for this machine only, booted the way the Mac
boots it: firmware → `\EFI\BOOT\BOOTX64.EFI` (the kernel's EFI stub) → built-in
command line → root partition by GPT GUID → `/sbin/init`. In QEMU and on the
Mac from a USB stick. Boot time measured.

`/sbin/init` is **`bootprobe`** (`tests/bootprobe.c`), a **stand-in, not the
real init**. It is built with our musl toolchain (so it proves that toolchain
works on the target), reports what the kernel found and how long boot took,
and then waits so you can read the screen. In QEMU it powers off so tests
finish. Phase 2 replaces it with our init.

### 1.2 Configuration method (`config/kernel.fragment`, `scripts/kernel.sh`)

* `make allnoconfig KCONFIG_ALLCONFIG=config/kernel.fragment`: every option
  starts OFF; the fragment turns on exactly what this machine needs, with a
  comment for each group and a phase tag.
* **Verified, not hoped for.** Kconfig silently drops an option whose
  dependencies are unmet or whose name changed. `kernel.sh` checks that every
  fragment line is in the final `.config` and fails otherwise. On the first run
  that caught six problems: renamed `RANDOM_KMALLOC_CACHES`, `HID` needing
  `HID_SUPPORT`, `HID_APPLE` needing the LED class, `SECCOMP_FILTER` needing
  networking, and vendor selection needing `EXPERT`.
* The fully resolved config is committed as `config/kernel.resolved.config`,
  so every change to what is in the kernel shows up in review.
* **No `CONFIG_EXPERT`.** Combined with `allnoconfig` it silently removes
  dozens of standard features (PCI quirks, `madvise`, …). The cost is keeping
  support code for other CPU vendors (~50 KB).
* **Built with our own GCC 16.2** (`CROSS_COMPILE=x86_64-mba-linux-musl-`) and
  `KCFLAGS=-march=broadwell`. The kernel then does not depend on the host
  compiler, and the build is reproducible: fixed `KBUILD_BUILD_TIMESTAMP`,
  user and host. A clean rebuild gives a bit-identical `bzImage`.
* **No modules** (`CONFIG_MODULES=n`): nothing to load, nothing to sign, no
  module-loading attack surface. Revisited in Phase 4: broadcom-wl is
  out-of-tree and needs modules (or patching into the tree).
* **No initramfs** until full-disk encryption needs one (Phase 6).
* **Compression: LZ4**, the fastest to decompress. Measured against zstd and
  gzip in Phase 7.

### 1.3 Boot path and command line

Apple's firmware passes **no arguments** to `BOOTX64.EFI`, so the command line
is built in:

```
root=PARTUUID=6d62616f-7300-4000-8000-000000000003 rootfstype=ext4 rootwait ro
console=ttyS0,115200 console=tty0 printk.devkmsg=on
```

* Root by **partition GUID**, which `mkimage.sh` sets (`ROOT_PART_GUID`).
  `kernel.sh` refuses to build if the two disagree. Device names (`sda`/`sdb`)
  differ between the USB stick and the internal SSD; the GUID does not.
* `rootwait`: a USB stick enumerates after the kernel is ready to mount root.
* `console=tty0` is listed last, so `/dev/console` is the screen (the Mac has
  no serial port); `ttyS0` is for QEMU.
* Arguments from a boot loader (QEMU `-append`) are **appended**.
  `CMDLINE_OVERRIDE` (ignore them, so nobody can change the command line from
  the firmware) comes with the lockdown/verified-boot work in Phase 6.
* Display: the firmware's GOP framebuffer through `simpledrm` + fbcon until
  i915 takes over in Phase 3. Legacy `/dev/fb0` (`FB_DEVICE`) is off.

### 1.4 Hardening

Kernel lockdown is forced to **integrity** mode from early boot: no
`/dev/mem`, no unsigned kexec, no `iopl`/`ioperm`, no MSR writes from user
space, no ACPI table overrides. Also enabled: KASLR (base and memory regions),
`VMAP_STACK`, strong stack protector, zero-initialised stack variables,
hardened usercopy, `FORTIFY_SOURCE`, slab freelist randomisation and
hardening, partitioned kmalloc caches, page allocator shuffling, list
hardening, `BUG_ON_DATA_CORRUPTION`, no legacy vsyscall, no `/dev/mem`, no
kexec, no hibernation.

### 1.5 CPU vulnerability mitigations

**Policy:** build in every mitigation that applies to Intel CPUs and let the
kernel choose at runtime from the CPU model and microcode. `allnoconfig`
otherwise turns each one off individually: the first test boot reported
Spectre v1/v2, MDS and SSB as *Vulnerable*, and the boot probe caught it.

Left out on purpose: AMD-only (IBPB_ENTRY, SRSO, TSA), KVM-only (VMSCAPE),
SLS (AMD-motivated compile-time padding), and the Skylake Retbleed defences
(call-depth tracking, IBRS on entry). Broadwell is not affected by Retbleed.

**SMT stays on.** MDS can leak between the two hyperthreads of a core, and
the strict fix is `nosmt`, which costs a quarter to a third of multi-threaded
throughput. This machine runs no VMs and no other users' code; browser
JavaScript is the realistic attacker, and browsers have their own
mitigations. Revisit if that changes.

**Microcode:** MDS (`MD_CLEAR`) and SSB (`SSBD`) need microcode features. The
Mac's firmware loads whatever microcode Apple last shipped. Phase 3 pins
Intel's microcode as a verified source and builds it into the kernel.

QEMU's Broadwell model lacks those microcode features, so in QEMU exactly
two lines say *Vulnerable* (MDS, SSB). The test allows only those two. In
QEMU (TCG) the rest read: Meltdown: PTI; Spectre v1: usercopy/swapgs
barriers; Spectre v2: retpolines; ITS: aligned thunks; L1TF: PTE inversion.

### 1.6 Measuring boot time

`bootprobe` records two clocks the moment it starts:

* **kernel → init**: `CLOCK_BOOTTIME`, from the kernel's start.
* **CPU reset → init**: the TSC divided by its measured frequency. The TSC
  counts from zero when the CPU comes out of reset, so this **includes
  firmware time**. Firmware ≈ the difference. Not captured: the time between
  pressing the power button and CPU reset (power sequencing in the SMC).

Notes for the Mac: holding Option and sitting in the boot picker counts as
firmware time. For a true number, make the stick the default startup disk
(see the Phase 1 checklist) and cold-boot without Option. Under a hypervisor
the TSC is not reset at power-on, so the probe prints n/a.

### 1.7 Verification record

| Check | Result |
|---|---|
| Fragment fully present in final config | verified by `kernel.sh` on every build |
| Kernel build reproducible (clean rebuild, `cmp`) | ok: bit-identical bzImage |
| Whole disk image reproducible (`repro-check`) | ok |
| QEMU: firmware starts `BOOTX64.EFI` from our disk | ok |
| QEMU: our kernel boots with the built-in command line | ok |
| QEMU: root mounted read-only by PARTUUID; init = boot probe | ok |
| QEMU: lockdown `[integrity]`, 4 CPUs, DMI, AHCI disk, DRM console | ok |
| QEMU: no kernel warnings/oopses; no unexpected *Vulnerable* | ok |
| Mac (MacBookAir7,2, firmware 489.0.0.0.0): boots from USB stick via Option → "EFI Boot" | **ok**, first try |
| Mac: DMI, i5-5250U 4 threads, 7.7 GiB, internal APPLE SSD SM0256 + SD reader + USB stick, 1440x900, lockdown integrity | **ok** |
| Mac: mitigations with Apple's firmware microcode | **ok**: MDS clear CPU buffers (SMT vulnerable, see 1.5), SSB via prctl, SRBDS microcode, Spectre v2 retpolines + IBPB + STIBP, Meltdown PTI |

### 1.8 Measurements

| Metric | QEMU TCG (this container) | Mac (USB stick) |
|---|---|---|
| bzImage size | 5.4 MiB (LZ4) | same image |
| kernel start → init | 1.63 s (emulated CPU; not representative) | **4.39 s** (first boot, before fixes) |
| CPU reset → init | n/a (hypervisor) | 15.3 s, includes sitting in the Option boot picker, so not a firmware measurement |
| memory used at init | 69 MiB of 3.9 GiB | 92 MiB of 7.7 GiB (to investigate in Phase 2) |

First Mac boot, where the 4.39 s went (from the photo of the screen):

* `usb-storage` waits 1 s ("delay_use") before scanning each new USB disk:
  the stick was enumerated at 3.14 s but attached at 4.37 s. Fixed with
  `usb-storage.delay_use=0` on the command line. It only affects booting from
  USB; the internal SSD is AHCI.
* 0 → 3.1 s scrolled off the screen. The boot probe now reads the kernel log
  and prints the ten largest gaps between messages, so the next Mac boot
  shows where that time goes.
* `vmscape: Vulnerable` appears on the Mac (not in QEMU). VMSCAPE is a
  guest-to-host attack on KVM hosts; this kernel has no KVM, so it does not
  apply.
