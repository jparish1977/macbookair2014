#!/bin/bash
# Stop the keyboard backlight from being used as a disk-activity light.
#
# THE BUG IS IN THE DRIVER, NOT IN THE DESKTOP.
#
# drivers/hwmon/applesmc.c registers the backlight like this:
#
#     static struct led_classdev applesmc_backlight = {
#             .name             = "smc::kbd_backlight",
#             .default_trigger  = "nand-disk",
#             .brightness_set   = applesmc_brightness_set,
#     };
#
# So the LED comes up bound to an activity trigger. Each blink ends with
# led_timer_function writing 0 -- indistinguishable, from the outside, from
# something deliberately switching the backlight off.
#
# It is NOT an SSD activity light, however much the name suggests one.
# "nand-disk" is fired by the MTD subsystem, and the SSD here is SATA (sda,
# APPLE SSD SD0128F). The only MTD device on the machine is mtd0 "BIOS" -- the
# 8MB EFI SPI flash, exposed through spi_nor. Ordinary disk I/O never fires it.
#
# So the visible symptom was "the keys go dark as I log in", and the actual
# sequence is: gnome-software activates fwupd on the first login after boot,
# fwupd's mtd plugin reads mtd0 during coldplug, the trigger fires once, and the
# blink leaves the LED at 0. Logging out and back in never reproduced it because
# that refresh happens once per boot.
#
# The trigger looks like a 2007 mistake that lay inert for a decade: Macs of
# that era had no MTD device for it to fire on, and the 2008 patch that wanted
# real disk activity for the case LED used "ide-disk", not this. It only became
# visible once the kernel started exposing the SPI flash as MTD and fwupd
# started reading it at startup.
#
# Proven by kernel stack, not by elimination:
#
#     applesmc_brightness_set  value=0
#           applesmc_brightness_set+1
#           led_timer_function+100      <-- the trigger's blink timer
#           call_timer_fn+46
#           run_timer_softirq+138
#
# Blind alleys, recorded so they are not walked again:
#   - csd-power is innocent. Its only startup write is an out-of-range guard
#     (value < 0 or > max), and restarting it leaves the LED alone -- tested.
#   - The process shown against the write is meaningless. It is a softirq, so
#     the pid is whatever was on the CPU; here it read "fwupd", which is what
#     sent this investigation chasing fwupd's plugins for an hour.
#   - `DisabledPlugins=` in /etc/fwupd/fwupd.conf did not take effect the way
#     it was written, so a plugin bisection "ruled out" plugins while fwupd was
#     visibly still loading them. Check the journal for FuPlugin* lines before
#     believing any such result.
#
# The fix is one sysfs write, made permanent with a udev rule that runs before
# systemd-backlight restores the saved level.

set -uo pipefail

# --image: install into a DISK bound for a MacBookAir6,x, from a machine that is
# not one. The udev rule is just a file and is the whole persistent fix; what
# cannot be done without the hardware is the "apply it to this session too" half,
# because there is no LED to write to. So --image installs the rule and skips
# that, rather than dying on a precondition that is meaningless for an image.
IMAGE=0
for _a in "$@"; do [ "$_a" = "--image" ] && IMAGE=1; done

LED_DIR='/sys/class/leds/smc::kbd_backlight'
TRIGGER="$LED_DIR/trigger"
BRIGHTNESS="$LED_DIR/brightness"
RULE='/etc/udev/rules.d/60-applesmc-kbd-backlight.rules'

die() { echo "error: $*" >&2; exit 1; }

need_root() {
  [[ $EUID -eq 0 ]] || die "'$1' needs root: sudo $0 $1"
}

need_led() {
  [[ -e "$TRIGGER" ]] || die "no $LED_DIR -- is applesmc loaded?"
}

active_trigger() {
  # The trigger file lists every trigger and brackets the active one.
  grep -o '\[[a-z0-9_-]*\]' "$TRIGGER" 2>/dev/null | tr -d '[]'
}

# UPower's D-Bus API writes the LED without root, which is worth knowing: the
# sysfs file is root-owned, but this works from any active session.
set_brightness() {
  local v="$1"
  if [[ $EUID -eq 0 ]]; then
    echo "$v" > "$BRIGHTNESS"
  else
    gdbus call --system --dest org.freedesktop.UPower \
      -o /org/freedesktop/UPower/KbdBacklight \
      -m org.freedesktop.UPower.KbdBacklight.SetBrightness "$v" >/dev/null 2>&1
  fi
}

cmd_status() {
  need_led
  local trig; trig=$(active_trigger)
  echo "  device      $LED_DIR"
  echo "  brightness  $(cat "$BRIGHTNESS" 2>/dev/null)/$(cat "$LED_DIR/max_brightness" 2>/dev/null)"
  printf '  trigger     %s' "$trig"
  case "$trig" in
    none) echo "   (good -- the LED holds whatever level it is set to)" ;;
    nand-disk) echo "   (BAD -- driver default; disk activity blinks it off)" ;;
    *) echo "   (unexpected)" ;;
  esac
  if [[ -f "$RULE" ]]; then
    echo "  udev rule   installed at $RULE"
  else
    echo "  udev rule   NOT installed -- the trigger returns on the next boot"
    echo "              install it with:  sudo $0 install"
  fi
}

cmd_install() {
  need_root install
  [[ "$IMAGE" == 1 ]] || need_led

  # 60- so it runs before 99-systemd.rules, which is what starts
  # systemd-backlight@ for this LED. Clearing a trigger turns the LED off, so
  # doing it first lets systemd-backlight's restore be the last word.
  cat > "$RULE" <<'EOF'
# applesmc registers smc::kbd_backlight with .default_trigger = "nand-disk"
# (drivers/hwmon/applesmc.c), so the keyboard backlight blinks on MTD activity
# and each blink ends by writing 0. The only MTD device here is the BIOS SPI
# flash, which fwupd reads once per boot -- so the backlight goes out shortly
# after the first login. Detach the trigger.
#
# Numbered 60 to run before 99-systemd.rules, which starts systemd-backlight@
# for this device: clearing a trigger sets the LED to 0, so the restore must
# come afterwards, not before.
ACTION=="add", SUBSYSTEM=="leds", KERNEL=="smc::kbd_backlight", ATTR{trigger}="none"
EOF
  echo "wrote $RULE"

  udevadm control --reload-rules 2>/dev/null && echo "reloaded udev rules"

  if [[ "$IMAGE" == 1 ]]; then
    echo "--image: rule installed; not applying to this session (no LED here)"
    echo "The rule is the persistent fix -- it fires on the target machine's"
    echo "first boot, when applesmc registers the LED with its nand-disk default."
    echo
    return 0
  fi

  # Apply now as well, so this session benefits without a reboot. Detaching the
  # trigger zeroes the LED, hence saving and putting the level back.
  local saved; saved=$(cat "$BRIGHTNESS" 2>/dev/null)
  echo none > "$TRIGGER"
  echo "$saved" > "$BRIGHTNESS"
  echo "trigger set to none; brightness restored to $saved"
  echo
  cmd_status
}

cmd_revert() {
  need_root revert
  need_led
  rm -f "$RULE" && echo "removed $RULE"
  udevadm control --reload-rules 2>/dev/null && echo "reloaded udev rules"
  local saved; saved=$(cat "$BRIGHTNESS" 2>/dev/null)
  echo nand-disk > "$TRIGGER"
  echo "$saved" > "$BRIGHTNESS"
  echo "trigger set back to the driver default (nand-disk)"
}

# Reproduce the fault on demand rather than waiting for a login. Restarting
# fwupd re-runs the MTD coldplug that fires the trigger.
cmd_test() {
  need_root test
  need_led
  local level=204 before after trig
  trig=$(active_trigger)
  echo "trigger is '$trig'"
  set_brightness "$level"
  sleep 0.5
  before=$(cat "$BRIGHTNESS")
  echo "set backlight to $before, restarting fwupd..."
  systemctl restart fwupd
  sleep 8
  after=$(cat "$BRIGHTNESS")
  echo "backlight after fwupd restart: $after"
  echo
  if [[ "$after" == "$before" ]]; then
    echo "PASS -- the backlight survived. The trigger is not eating it."
  else
    echo "FAIL -- backlight went $before -> $after."
    [[ "$trig" == "nand-disk" ]] &&
      echo "        expected with trigger 'nand-disk'; run: sudo $0 install"
  fi
  set_brightness "$level"
}

case "${1:-status}" in
  status)  cmd_status ;;
  install) cmd_install ;;
  revert)  cmd_revert ;;
  test)    cmd_test ;;
  *)
    cat <<EOF
usage: $0 {status|install|revert|test}

  status   show the LED's trigger, level, and whether the fix is installed
  install  detach the nand-disk trigger, now and on every boot (root)
  revert   put the driver default back (root)
  test     restart fwupd and report whether the backlight survives (root)
EOF
    exit 1 ;;
esac
