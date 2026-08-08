#!/bin/bash
# Capture what the kernel workshop needs to know about a machine.
#
# Run this ON the vintage machine you want to build kernels for -- not on the
# build host. It collects the running kernel's config, the set of modules
# actually in use, and enough identity to tell profiles apart later.
#
#   ./capture-target.sh                    # profile named after the hostname
#   ./capture-target.sh mba --push         # and copy it to the workshop on i8
#
# The lsmod capture is the important part: `make localmodconfig` uses it to
# strip a distro config of the thousands of drivers this machine will never
# have, which is the difference between a ten-minute build and an hour.
#
# Re-run it after a distro kernel upgrade, so the profile keeps matching the
# machine.

set -uo pipefail

NAME="${1:-$(hostname -s)}"
[[ "$NAME" == --* ]] && NAME="$(hostname -s)"
PUSH=0
for a in "$@"; do [[ "$a" == "--push" ]] && PUSH=1; done

# The tailnet name, deliberately, not the bare "iteration8" ssh alias: that
# alias forces HostName iteration8.local, which resolves only on i8's own LAN.
# From anywhere else it fails, while the tailnet name works in both places.
# Override with WORKSHOP_HOST=... if the workshop moves.
WORKSHOP_HOST="${WORKSHOP_HOST:-iteration8.tail51fded.ts.net}"
WORKSHOP_DIR="${WORKSHOP_DIR:-/srv/kernel-workshop}"

REL=$(uname -r)
OUT="$HOME/target-profile-$NAME"
mkdir -p "$OUT" || { echo "cannot write $OUT" >&2; exit 1; }

echo "capturing profile '$NAME' from $(hostname) ($REL)"

cp "/boot/config-$REL" "$OUT/config" 2>/dev/null || {
  echo "error: no /boot/config-$REL -- cannot build a matching kernel without it" >&2
  exit 1
}
lsmod > "$OUT/lsmod"
echo "$REL" > "$OUT/uname"

{
  echo "captured:   $(date -Is)"
  echo "hostname:   $(hostname)"
  echo "kernel:     $REL"
  echo "product:    $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo "vendor:     $(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
  echo "bios:       $(cat /sys/class/dmi/id/bios_version 2>/dev/null)"
  echo "cpu:        $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')"
  echo "arch:       $(uname -m)"
  echo "modules:    $(($(wc -l < "$OUT/lsmod") - 1)) loaded"
  echo "root:       $(findmnt -no SOURCE / 2>/dev/null) $(findmnt -no FSTYPE / 2>/dev/null)"
  echo "secureboot: $(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print ($NF==1?"ENABLED":"disabled")}' || echo "no efivar")"
  echo
  echo "installed kernels (fallbacks if a test kernel will not boot):"
  ls /boot/vmlinuz-* 2>/dev/null | sed 's/.*vmlinuz-/  /'
  echo
  echo "out-of-tree modules this machine needs (DKMS) -- a self-built kernel"
  echo "will NOT have these unless DKMS rebuilds them:"
  dkms status 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo
  echo "network interfaces -- if there is no ethernet, a kernel that breaks"
  echo "wifi leaves this machine with no way to fetch a fix:"
  ip -o link show 2>/dev/null | awk -F': ' '{print "  " $2}'
} > "$OUT/facts.txt"

cat "$OUT/facts.txt"

echo
echo "profile written to $OUT"

if [[ "$PUSH" == "1" ]]; then
  echo "pushing to $WORKSHOP_HOST:$WORKSHOP_DIR/targets/$NAME/"
  ssh "$WORKSHOP_HOST" "mkdir -p '$WORKSHOP_DIR/targets/$NAME'" &&
  scp -q "$OUT"/* "$WORKSHOP_HOST:$WORKSHOP_DIR/targets/$NAME/" &&
  echo "pushed." ||
  echo "push FAILED -- copy $OUT yourself to $WORKSHOP_DIR/targets/$NAME/"
else
  echo "copy it to the workshop with:"
  echo "  scp -r $OUT $WORKSHOP_HOST:$WORKSHOP_DIR/targets/$NAME"
fi
