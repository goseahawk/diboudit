# mbaos

A from-source, minimal Unix-like OS for the 2015 MacBook Air (MacBookAir7,1/7,2).
Design and rationale: [DESIGN.md](DESIGN.md).

**Quick start:** on a 64-bit Linux machine, run `./doit.sh`. It builds everything up to the current phase, tests it in QEMU, can write a USB stick, and
writes a log to `build/doit.log`.

```
doit.sh                build + test everything up to the current phase
build.sh               single entry point (./build.sh help lists commands)
config/target.conf     machine, flags, fixed IDs for reproducibility
config/kernel.fragment the kernel config: allnoconfig + exactly these options (checked)
config/kernel.resolved.config  the full resulting kernel config, for review
config/busybox.fragment BusyBox: allnoconfig + exactly these applets (checked)
rootfs/                plain-text system configuration, copied into the image as-is
src/init/              our init (PID 1), svd (service supervisor), sv (control)
src/tools/             bootreport
metrics/history.csv    boot time / idle RAM / wakeups per test run
sources.lock           pinned versions + sha256 of every upstream source
keys/                  upstream signing keyring + record of who signed what
patches/<name>/        patches applied automatically after unpacking
scripts/               fetch, lock, toolchain, mkimage, qemu, write-usb
tests/                 toolchain smoke test, harness self-test, phase2-boot.py (QEMU acceptance test)
build/  sources/       outputs and download cache (not committed)
```

Status: Phases 0-2 complete (toolchain, kernel, base system with our init), verified in QEMU and on the Mac. Next: Phase 3, hardware bring-up. See DESIGN.md §2.9.
