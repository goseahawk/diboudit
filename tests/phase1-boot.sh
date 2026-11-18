#!/usr/bin/env bash
# Phase 1 acceptance test: boot OUR kernel from the disk image exactly like the
# Mac does (OVMF -> \EFI\BOOT\BOOTX64.EFI -> built-in command line -> root by
# PARTUUID -> /sbin/init), and check what the boot probe reports.
. "$(dirname "$0")/../scripts/lib.sh"
IMG=$BUILD/mbaos.img
LOG=$BUILD/phase1/serial.log
mkdir -p "$BUILD/phase1"
[[ -f $IMG ]] || die "no image; run ./build.sh image"

bash "$TOP/scripts/qemu.sh" --disk "$IMG" --timeout 300 --log "$LOG" \
	--expect 'bootprobe: done' --screendump "$BUILD/phase1/screen.png" --settle 2 >/dev/null \
	|| { tail -40 "$LOG" >&2; die "boot probe never reported 'done' (log: $LOG)"; }

fail=0
check() { if grep -qE "$2" "$LOG"; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=1; fi; }
echo "Phase 1 boot checks:"
check "firmware started BOOTX64.EFI from disk"  'BdsDxe: starting Boot.*HARDDISK'
check "our kernel (-mbaos) booted"              'Linux version [0-9.]+-mbaos'
check "built-in command line used"              'Kernel command line: root=PARTUUID=6d62616f'
check "root mounted by PARTUUID, read-only"     'VFS: Mounted root \(ext4 filesystem\) readonly'
check "init is the boot probe (static-pie, musl)" 'bootprobe: ==== mbaos Phase 1'
check "kernel lockdown active (integrity)"     'bootprobe: lockdown .*\[integrity\]'
check "4 logical CPUs online"                   'bootprobe: cpu .*4 logical CPUs'
check "framebuffer console"                     'bootprobe: display +card[0-9]-[^ ]+ connected [0-9]+x[0-9]+'
check "AHCI disk found"                         'bootprobe: disk +sda'
check "machine identified via DMI"              'bootprobe: machine +QEMU'
# QEMU's Broadwell CPU model lacks the microcode features these mitigations
# need (MD_CLEAR for MDS, SSBD for speculative store bypass). On the Mac they
# depend on the microcode version (loaded from Phase 3 on). Anything else
# reported as Vulnerable fails the test.
QEMU_VULN_OK=${QEMU_VULN_OK:-'vuln +mds +Vulnerable: Clear CPU buffers attempted, no microcode|vuln +spec_store_bypass +Vulnerable$'}
if grep -E 'bootprobe: vuln .*Vulnerable' "$LOG" | grep -vqE "$QEMU_VULN_OK"; then
	echo "  FAIL unexpected 'Vulnerable' mitigation status:"; grep -E 'bootprobe: vuln .*Vulnerable' "$LOG" | grep -vE "$QEMU_VULN_OK"; fail=1
fi
if grep -qE 'WARNING:|Oops|BUG:|Call Trace' "$LOG"; then
	echo "  FAIL kernel printed a warning/oops:"; grep -E 'WARNING:|Oops|BUG:' "$LOG" | head -5; fail=1
else
	echo "  ok   no kernel warnings or oopses"
fi

echo; echo "Boot probe report:"
grep -o 'bootprobe: .*' "$LOG" | sed 's/^bootprobe: /  /'
k=$(grep -o 'TIME kernel->init [0-9.]*' "$LOG" | awk '{print $3}')
echo; echo "kernel start -> init: ${k:-?} s   (QEMU; $( [[ -w /dev/kvm ]] && echo KVM || echo 'TCG emulation, not representative'))"
exit $fail
