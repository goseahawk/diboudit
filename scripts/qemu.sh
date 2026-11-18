#!/usr/bin/env bash
# QEMU + OVMF harness modelled on the MacBook Air 7,x.
#
#   qemu.sh --disk IMG                     boot the disk image exactly as the Mac would
#                                          (firmware -> \EFI\BOOT\BOOTX64.EFI)
#   qemu.sh --kernel BZIMAGE [--append S]  fast loop: OVMF loads the kernel's EFI stub
#                                          from QEMU fw_cfg, with a command line
# Automation:
#   --expect REGEX     exit 0 as soon as a serial line matches; print time-to-match
#   --timeout SECS     give up (exit 1) after SECS (default 120)
#   --log FILE         timestamped serial log (default build/qemu/serial.log)
#   --screendump FILE  save the framebuffer as PNG just before exiting
#   --settle SECS      after a match, keep running SECS before the screendump (default 3)
#   --gui              show a window (default: headless, serial on the terminal)
#   --keep-vars        keep UEFI variables between runs (default: fresh each run)
#
# Machine model: q35 (ICH9 AHCI ~ Apple's AHCI PCIe SSD), Broadwell CPU without
# TSX (as Broadwell-U ships, microcode-disabled), 1 socket / 2 cores / 2 threads,
# 4 GiB, xHCI with USB keyboard + tablet (the Mac's keyboard is internal USB).
. "$(dirname "$0")/lib.sh"

DISK= KERNEL= APPEND="console=ttyS0,115200 console=tty0" EXPECT= TIMEOUT=120
LOG=$BUILD/qemu/serial.log SHOT= SETTLE=3 GUI=0 KEEPVARS=0 MEM=${QEMU_MEM:-4096}
while [[ $# -gt 0 ]]; do
	case $1 in
	--disk) DISK=$2; shift 2 ;;       --kernel) KERNEL=$2; shift 2 ;;
	--append) APPEND=$2; shift 2 ;;   --expect) EXPECT=$2; shift 2 ;;
	--timeout) TIMEOUT=$2; shift 2 ;; --log) LOG=$2; shift 2 ;;
	--screendump) SHOT=$2; shift 2 ;; --gui) GUI=1; shift ;;
	--keep-vars) KEEPVARS=1; shift ;; --settle) SETTLE=$2; shift 2 ;;
	*) die "unknown option $1 (see header of $0)" ;;
	esac
done
[[ -n $DISK || -n $KERNEL ]] || die "need --disk IMG or --kernel BZIMAGE"

# ---- firmware ------------------------------------------------------------------------
find_first() { local f; for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done; }
OVMF_CODE=${OVMF_CODE:-$(find_first /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd)}
OVMF_VARS_TEMPLATE=${OVMF_VARS:-$(find_first /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS.fd)}
[[ -n $OVMF_CODE && -n $OVMF_VARS_TEMPLATE ]] || die "OVMF not found; set OVMF_CODE and OVMF_VARS"
Q=$BUILD/qemu; mkdir -p "$Q" "$(dirname "$LOG")"
VARS=$Q/OVMF_VARS.fd
[[ $KEEPVARS == 1 && -f $VARS ]] || cp "$OVMF_VARS_TEMPLATE" "$VARS"

# ---- acceleration --------------------------------------------------------------------
if [[ -w /dev/kvm ]]; then ACCEL=kvm; else
	ACCEL=tcg
	warn "no /dev/kvm: using TCG emulation. Boot TIMES are meaningless here; only correctness is."
fi

MON=$Q/monitor.sock; PIDF=$Q/qemu.pid; rm -f "$MON" "$PIDF"
args=(
	-name mbaos -machine q35,accel="$ACCEL" -cpu Broadwell-noTSX-IBRS
	-smp 4,sockets=1,cores=2,threads=2 -m "$MEM"
	-drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
	-drive "if=pflash,format=raw,unit=1,file=$VARS"
	-device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0
	-nic none -rtc base=utc
	-monitor "unix:$MON,server,nowait" -pidfile "$PIDF"
)
if [[ -n $DISK ]]; then
	# q35's built-in ICH9 AHCI controller, like the Mac's AHCI SSD
	args+=(-drive "if=none,id=ssd,format=raw,file=$DISK,discard=unmap" -device ide-hd,drive=ssd,bus=ide.0,rotation_rate=1)
fi
[[ -n $KERNEL ]] && args+=(-kernel "$KERNEL" -append "$APPEND")
if [[ $GUI == 1 ]]; then args+=(-display gtk); else args+=(-display none -vga std); fi
# With a screenshot requested, a guest power-off pauses the VM instead of
# exiting QEMU, so the final screen can still be captured.
if [[ -n $SHOT ]]; then args+=(-no-shutdown); rm -f "$SHOT" "$Q/screen.ppm"; fi

monitor() { python3 -I -c 'import socket,sys,time
s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall((sys.argv[2]+"\n").encode()); time.sleep(1); s.close()' "$MON" "$1"; }

finish() {
	if [[ -n $SHOT && -S $MON ]]; then
		monitor "screendump $Q/screen.ppm" && [[ -s $Q/screen.ppm ]] \
			&& python3 -I "$TOP/scripts/ppm2png.py" "$Q/screen.ppm" "$SHOT" && log "screendump: $SHOT"
	fi
	[[ -f $PIDF ]] && kill "$(cat "$PIDF")" 2>/dev/null || true
	if [[ -n $SHOT && ! -s $SHOT ]]; then warn "NO screenshot captured ($SHOT does not exist)"; fi
}

if [[ -z $EXPECT && -z $SHOT ]]; then
	# Interactive: serial + QEMU monitor multiplexed on this terminal (Ctrl-A X quits).
	exec qemu-system-x86_64 "${args[@]}" -serial mon:stdio
fi

# Automated: stamp every serial line with time since QEMU start.
log "qemu ($ACCEL) ${DISK:+disk=$DISK }${KERNEL:+kernel=$KERNEL }timeout=${TIMEOUT}s"
t0=$EPOCHREALTIME; rc=1; : > "$LOG"
while IFS= read -r line; do
	line=${line//$'\r'/}
	el=$(awk -v a="$t0" -v b="$EPOCHREALTIME" 'BEGIN{printf "%8.3f", b-a}')
	printf '[%s] %s\n' "$el" "$line" | tee -a "$LOG"
	if [[ -n $EXPECT ]] && [[ $line =~ $EXPECT ]]; then
		log "MATCH /$EXPECT/ after ${el// /}s"
		rc=0; break
	fi
done < <(timeout --foreground "$TIMEOUT" qemu-system-x86_64 "${args[@]}" -serial stdio </dev/null 2>&1)
[[ $rc == 0 && -n $SHOT ]] && sleep "$SETTLE"   # let the framebuffer catch up
finish
[[ $rc == 0 ]] || { [[ -n $EXPECT ]] && warn "no match for /$EXPECT/ within ${TIMEOUT}s (log: $LOG)"; [[ -z $EXPECT ]] && rc=0; }
exit $rc
