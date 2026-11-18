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
sources.lock           pinned versions + sha256 of every upstream source
keys/                  upstream signing keyring + record of who signed what
patches/<name>/        patches applied automatically after unpacking
scripts/               fetch, lock, toolchain, mkimage, qemu, write-usb
tests/                 toolchain smoke test, harness self-test, bootprobe (Phase 1 stand-in init), phase1-boot test
build/  sources/       outputs and download cache (not committed)
```

Status: **Phase 1** (kernel). Phase 0 complete. See DESIGN.md §1.7 for what has been verified.
