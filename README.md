# mbaos

A from-source, minimal Unix-like OS for the 2015 MacBook Air (MacBookAir7,1/7,2).
Design and rationale: [DESIGN.md](DESIGN.md).

```
build.sh               single entry point (./build.sh help lists commands)
config/target.conf     machine, flags, fixed IDs for reproducibility
sources.lock           pinned versions + sha256 of every upstream source
keys/                  upstream signing keyring + record of who signed what
patches/<name>/        patches applied automatically after unpacking
scripts/               fetch, lock, toolchain, mkimage, qemu, write-usb
tests/                 toolchain smoke test, harness self-test
build/  sources/       outputs and download cache (not committed)
```

Status: **Phase 0** (build environment). See DESIGN.md §0.9 for what has been verified.
