#!/bin/bash
# Test the proposed upstream applesmc patch by building and loading it for real.
#
# See patches/upstream-applesmc-nand-disk.md for the patch and its reasoning.
#
# WHY THIS EXISTS RATHER THAN JUST TRUSTING THE UDEV RULE
#
# kbd-backlight.sh detaches the trigger *after* the driver registers the LED,
# so it reaches the same end state whether or not removing the line would work.
# It cannot tell you the patch is right. This builds the patched driver, loads
# it, and checks the trigger the driver itself installs -- and it runs a control
# first (rule out of the way, stock module, expect nand-disk back) so that a
# pass actually means something. If the control does not reproduce, it stops
# rather than reporting a success it has not earned.
#
# Sequence:
#   0. build unpatched upstream source; its srcversion must equal the running
#      module's, or the distro patches this driver and the test is invalid
#   1. rule aside, stock module          -> expect trigger [nand-disk]
#   2. patched module                    -> expect trigger [none]
#   3. patched module + fwupd restart    -> expect the level to survive
#   4. restore everything, on every exit path
#
# Needs root, gcc, and the running kernel's headers. Unloads applesmc briefly,
# so hwmon sensors disappear for a few seconds; fan control is in the SMC
# firmware, not this driver, so that window is not a thermal risk.

set -uo pipefail

LED='/sys/class/leds/smc::kbd_backlight'
RULE='/etc/udev/rules.d/60-applesmc-kbd-backlight.rules'
RULE_HIDDEN='/root/60-applesmc-kbd-backlight.rules.testing'
LEVEL=204
B="${1:-}"

die() { echo "error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0 [builddir]"
[[ -e "$LED/trigger" ]] || die "no $LED -- is applesmc loaded?"
command -v gcc >/dev/null || die "gcc not installed"
[[ -d "/lib/modules/$(uname -r)/build" ]] || \
  die "no kernel headers for $(uname -r) (apt install linux-headers-$(uname -r))"

if [[ -e /sys/firmware/efi ]] && \
   od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | grep -qE '1$'; then
  die "Secure Boot is enabled; an unsigned module will not load"
fi

if [[ -z "$B" ]]; then
  B=$(mktemp -d /tmp/applesmc-test-XXXXXX)
  OWN_DIR=1
fi
mkdir -p "$B"

# Match the source to the running kernel: 7.0.0-28-generic -> v7.0
if [[ ! -f "$B/applesmc.c" ]]; then
  tag="v$(uname -r | cut -d. -f1-2)"
  echo "fetching upstream $tag applesmc.c ..."
  curl -fsSL -o "$B/applesmc.c" \
    "https://raw.githubusercontent.com/torvalds/linux/$tag/drivers/hwmon/applesmc.c" \
    || die "could not fetch applesmc.c for $tag"
fi

trig() { grep -o '\[[a-z0-9_-]*\]' "$LED/trigger" 2>/dev/null | tr -d '[]'; }
bright() { cat "$LED/brightness" 2>/dev/null; }
build() { make -C "/lib/modules/$(uname -r)/build" M="$B" modules >/dev/null 2>&1; }

restore() {
  echo
  echo "--- restoring ---"
  rmmod applesmc 2>/dev/null
  modprobe applesmc 2>/dev/null && echo "stock applesmc reloaded"
  [[ -f "$RULE_HIDDEN" ]] && mv "$RULE_HIDDEN" "$RULE" && \
    udevadm control --reload-rules && echo "udev rule restored"
  sleep 1
  [[ -f "$RULE" ]] && echo none > "$LED/trigger" 2>/dev/null
  echo "$LEVEL" > "$LED/brightness" 2>/dev/null
  echo "trigger=$(trig) brightness=$(bright)"
  [[ "${OWN_DIR:-0}" == "1" ]] && rm -rf "$B"
  return 0
}
trap restore EXIT

printf 'obj-m := applesmc.o\n' > "$B/Makefile"
cp "$B/applesmc.c" "$B/applesmc-unpatched.c"

echo "=== 0. integrity: does this distro ship stock upstream source? ==="
shipped=$(modinfo -F srcversion applesmc 2>/dev/null)
build || die "build of unpatched source failed"
built=$(modinfo -F srcversion "$B/applesmc.ko")
echo "  shipped: $shipped"
echo "  built:   $built"
[[ "$shipped" == "$built" ]] || die "MISMATCH -- distro patches this driver; this would not test the upstream patch"
echo "  match -- distro source is stock upstream"
cp "$B/applesmc.ko" "$B/applesmc-stock.ko"

echo
echo "=== 1. control: rule aside, stock module ==="
[[ -f "$RULE" ]] && mv "$RULE" "$RULE_HIDDEN" && udevadm control --reload-rules
rmmod applesmc 2>/dev/null; sleep 1
insmod "$B/applesmc-stock.ko" || die "insmod of stock build failed"
sleep 2
c=$(trig); echo "  trigger = $c"
[[ "$c" == "nand-disk" ]] || die "control did not reproduce the default trigger; a later pass would prove nothing"
echo "  control good -- the driver really does default to nand-disk"

echo
echo "=== 2. patched module ==="
sed '/\.default_trigger[[:space:]]*=[[:space:]]*"nand-disk",/d' \
  "$B/applesmc-unpatched.c" > "$B/applesmc.c"
removed=$(( $(wc -l < "$B/applesmc-unpatched.c") - $(wc -l < "$B/applesmc.c") ))
echo "  lines removed: $removed (want 1)"
[[ "$removed" -eq 1 ]] || die "the deletion did not remove exactly one line"
build || die "build of patched source failed"
echo "  patched srcversion: $(modinfo -F srcversion "$B/applesmc.ko")"
cp "$B/applesmc.ko" "$B/applesmc-patched.ko"
cp "$B/applesmc-unpatched.c" "$B/applesmc.c"

rmmod applesmc 2>/dev/null; sleep 1
insmod "$B/applesmc-patched.ko" || die "insmod of patched build failed"
sleep 2
p=$(trig); echo "  trigger = $p"
[[ "$p" == "none" ]] || die "expected 'none', got '$p'"
echo "  PASS -- removing the line is sufficient; nothing re-attaches a trigger"

echo
echo "=== 3. does the backlight survive a real MTD read? ==="
echo "$LEVEL" > "$LED/brightness"; sleep 0.5
before=$(bright)
echo "  set to $before, restarting fwupd..."
systemctl restart fwupd
sleep 8
after=$(bright)
echo "  after: $after"
[[ "$before" == "$after" ]] || die "FAIL -- went $before -> $after"
echo "  PASS -- patched driver holds the level through the MTD read"

echo
echo "================================================================"
echo "  All checks passed on $(cat /sys/class/dmi/id/product_name 2>/dev/null), $(uname -r)"
echo "    control (stock, no rule): nand-disk"
echo "    patched:                  none"
echo "    patched + fwupd restart:  $before held"
echo "================================================================"
