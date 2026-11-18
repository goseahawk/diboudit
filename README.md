# mbaos

A from-source, minimal Unix-like OS for the 2015 MacBook Air (MacBookAir7,1/7,2).
Design and rationale: [DESIGN.md](DESIGN.md).

**Quick start:** on a 64-bit Linux machine, run `./doit.sh`. It does all of Phase 0 and
writes a log to `build/doit.log`.

```
doit.sh                run everything for Phase 0, start to finish
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
