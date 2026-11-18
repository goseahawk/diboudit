#!/usr/bin/env bash
# Write the disk image to a USB stick — and ONLY a USB stick.
#   sudo scripts/write-usb.sh build/mbaos.img /dev/sdX
# Refuses: partitions, non-USB/non-removable disks, mounted disks, the build
# host's own root disk, disks smaller than the image. Asks for the device path
# to be typed back before writing. This runs on the Linux build host; it has
# no way to reach the Mac's internal SSD.
. "$(dirname "$0")/lib.sh"

IMG=${1:-} DEV=${2:-}
[[ -f $IMG && -n $DEV ]] || die "usage: write-usb.sh IMAGE /dev/sdX"
[[ -b $DEV ]] || die "$DEV is not a block device"
[[ $(lsblk -dno TYPE "$DEV") == disk ]] || die "$DEV is not a whole disk (give /dev/sdX, not /dev/sdX1)"

name=${DEV##*/}
tran=$(lsblk -dno TRAN "$DEV" | tr -d ' ')
removable=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)
[[ $tran == usb || $removable == 1 ]] || die "$DEV is not USB/removable (transport='$tran'); refusing"

rootdev=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
[[ $name != "$rootdev" ]] || die "$DEV holds this host's root filesystem; refusing"
if lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then die "$DEV has mounted partitions; unmount them first"; fi

img_size=$(stat -c %s "$IMG"); dev_size=$(blockdev --getsize64 "$DEV")
(( dev_size >= img_size )) || die "$DEV ($dev_size bytes) is smaller than the image ($img_size bytes)"

echo
lsblk -o NAME,SIZE,TRAN,VENDOR,MODEL,SERIAL "$DEV"
echo
echo "ALL DATA ON $DEV WILL BE DESTROYED. Type the device path ($DEV) to continue:"
read -r answer
[[ $answer == "$DEV" ]] || die "confirmation did not match; nothing written"

dd if="$IMG" of="$DEV" bs=4M conv=fsync oflag=direct status=progress
# The stick is larger than the image: move the backup GPT header to the real end
# of the device so firmware and the kernel see a consistent GPT.
sgdisk --move-second-header "$DEV" >/dev/null
sync
log "written. Eject with: sudo eject $DEV"
