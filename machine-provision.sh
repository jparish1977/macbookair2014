#!/bin/bash
# Turn a fresh Mint install on a MacBookAir6,x into a working machine.
#
#   ./machine-provision.sh              # report only, changes nothing
#   ./machine-provision.sh apply
#   ./machine-provision.sh apply --tune # ...and the power tuning, which is OPT-IN
#
# WHY THIS EXISTS, AND WHY IT IS NAMED THIS
#
# Every fix in this repo already has an installer -- `mba-webcam.sh install`,
# `kbd-backlight.sh install`, `kernel-guard.sh install-hook`. What did not exist
# was the ORDER, so "Mint with our fixes" lived only in somebody's head. That is
# fine for the person who built it and useless for handing a machine to anyone
# else, which is the stated goal for Jenni's and for any refurbished Air.
#
# Named machine-provision.sh to pair with server-provision.sh, and to avoid
# being confused with workshop/provision.sh, which builds a kernel workshop and
# is a completely different job. Rename it if you would rather.
#
# WHAT IT ASSUMES
#
# A fresh Mint install with a network. Mint already ships the Broadcom driver,
# so Wi-Fi usually works from the installer -- which is the single biggest
# difference between Mint and Ubuntu on this hardware, and why the gap here is
# the camera, the backlight and the kernel guard rather than the network.
#
# IT DOES NOT TOUCH BACKUPS
#
# Snapshots, the offsite copy and the restic repo need a server and a
# passphrase. Those are client-setup.sh's job and yours respectively. This
# script gets the HARDWARE working; that is all.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-check}"; TUNE=0; IMAGE=0
for a in "$@"; do
  [ "$a" = "--tune" ]  && TUNE=1
  [ "$a" = "--image" ] && IMAGE=1
done

# --image: we are provisioning a DISK destined for a MacBookAir6,x, from a VM
# that is not one.
#
# This is not a weakening of the hardware check below, and it matters that it is
# not. The refusal exists so nobody installs Apple-specific drivers on non-Apple
# hardware they are going to USE. Building an image changes what "the target" is:
# the disk is bound for the right machine, the builder is scaffolding. So the
# vendor gate is answered rather than bypassed -- and everything that can only be
# true on real hardware (wl loaded, an SMC to attach an LED to) is reported as
# EXPECTED-ABSENT instead of as a fault, because in a VM those are not failures
# and calling them failures teaches you to ignore the report.
#
# oem-image.sh calls this. It used to carry its own copy of the order, which is
# precisely the duplication this repo keeps rediscovering: two lists that drift.
if [ "$IMAGE" = 1 ]; then
  export DEBIAN_FRONTEND=noninteractive
fi

say()  { echo; echo -e "\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m[ok]\033[0m   $*"; }
warn() { echo -e "    \033[33m[warn]\033[0m $*"; }
bad()  { echo -e "    \033[31m[!!]\033[0m   $*"; }
info() { echo "    $*"; }
die()  { echo; echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }

# lsmod ONCE, matched with a here-string. `lsmod | grep -q` under `set -o
# pipefail` reports failure on a SUCCESSFUL match -- grep -q exits at the first
# hit, lsmod dies of SIGPIPE, and the pipeline returns 141. This is the third
# script in this repo to be bitten by it; capture first, match second.
MODS=$(lsmod 2>/dev/null)
mod_loaded() { grep -q "^$1 " <<< "$MODS"; }

# "Did it build?" -- deliberately NO PIPELINE. The obvious spelling,
# `find ... | grep -q .`, is the SIGPIPE trap again: grep -q exits at the first
# hit, find dies of 141, and pipefail turns a module that IS there into "NO".
# Writing this the wrong way first is how it earned the comment.
have_ko() {   # $1 = filename glob
  local out; out=$(find /lib/modules -name "$1" 2>/dev/null)
  [ -n "$out" ]
}

doing() { [ "$MODE" = apply ]; }
run()   { if doing; then "$@"; else echo "      would run: $*"; fi; }

usage() {
  cat <<EOF

machine-provision.sh -- a fresh Mint install -> a working MacBookAir6,x

  $0               report what is missing; change nothing
  $0 apply         install the drivers, rules and the kernel guard
  $0 apply --tune  ...and optimize-mba.sh, which is deliberately opt-in

Afterwards, for backups:  ./client-setup.sh YOUR-SERVER --write

EOF
  exit 1
}
case "$MODE" in check|apply) ;; *) usage ;; esac

# ---- hardware ----------------------------------------------------------------
#
# REFUSE on the wrong machine, and this one is absolute rather than a
# preference. facetimehd is a driver for one specific camera and applesmc's
# quirks are Apple-specific; building them elsewhere is not conservative, it is
# breakage. Compare server-provision.sh, which only ADVISES about redundancy --
# that is a preference, this is a hardware requirement.
say "Hardware"
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
info "$VENDOR $MODEL"
if [ "$IMAGE" = 1 ]; then
  ok "--image: building a disk for a MacBookAir6,x, not provisioning this host"
  info "  Hardware checks below are ADVISORY here. A driver cannot load against"
  info "  a device this machine does not have, so 'not loaded' is the expected"
  info "  result in a VM -- what matters is that it BUILT and will be there when"
  info "  the disk reaches the machine it is for."
else
  case "$VENDOR" in
    *Apple*) ;;
    *) bad "this is not an Apple machine"
       info "If you meant to build an IMAGE for one, use: $0 apply --image"
       die "these fixes are for a MacBookAir6,x -- installing them here would just break things" ;;
  esac
  case "$MODEL" in
    MacBookAir6,*) ok "supported model" ;;
    *) warn "$MODEL is a Mac but not a MacBookAir6,x"
       info "The camera and backlight fixes were written and tested for 6,1."
       info "They may be right for you; nobody has checked. Proceeding." ;;
  esac
fi

[ -d /sys/firmware/efi ] && ok "booted UEFI" || warn "not booted UEFI -- unusual on this hardware"

# ---- prerequisites -----------------------------------------------------------

say "Build toolchain"
NEED=()
for p in dkms build-essential git curl xz-utils cpio; do
  dpkg -s "$p" >/dev/null 2>&1 || NEED+=("$p")
done

# Headers for the RUNNING kernel, checked the way DKMS actually needs them --
# not `linux-headers-generic`, which is a SERIES meta-package. This machine runs
# 7.0.0-28 and holds linux-headers-generic-6.17; asking for the bare meta
# reported a false "missing" and would have pulled a different kernel series'
# headers, which is worse than the wrong message.
if [ -d "/lib/modules/$(uname -r)/build" ]; then
  ok "headers present for $(uname -r)"
else
  warn "no headers for the running kernel $(uname -r) -- DKMS cannot build"
  NEED+=("linux-headers-$(uname -r)")
fi
if [ "${#NEED[@]}" = 0 ]; then
  ok "present"
else
  info "missing: ${NEED[*]}"
  info "  DKMS and headers are not a one-off: they rebuild wl and facetimehd on"
  info "  every kernel update, so they have to stay installed."
  run sudo apt-get update -qq
  run sudo apt-get install -y "${NEED[@]}"
fi

if ! ping -c1 -W3 archive.ubuntu.com >/dev/null 2>&1 && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
  warn "no network detected -- the camera firmware and any missing packages need one"
fi

# ---- 1. Wi-Fi ----------------------------------------------------------------

say "Wi-Fi (BCM4360)"
if mod_loaded wl; then
  ok "wl is loaded -- Mint ships broadcom-sta, so this usually needs nothing"
elif [ "$IMAGE" = 1 ] && dpkg -s broadcom-sta-dkms >/dev/null 2>&1; then
  ok "broadcom-sta-dkms installed and built; wl cannot load with no BCM4360 here"
elif dpkg -s broadcom-sta-dkms >/dev/null 2>&1; then
  warn "broadcom-sta-dkms is installed but wl is not loaded"
  info "  Try: sudo modprobe wl    (and check 'dkms status' built it for $(uname -r))"
else
  info "installing broadcom-sta-dkms"
  info "  This machine has NO ETHERNET, so wl is the only way it talks to"
  info "  anything. Install it before you need it."
  run sudo apt-get install -y broadcom-sta-dkms
fi
[ -x "$HERE/mba-wifi.sh" ] && info "diagnostics available: ./mba-wifi.sh status"

# ---- 2. Camera ---------------------------------------------------------------

say "FaceTime HD camera"
if [ ! -x "$HERE/mba-webcam.sh" ]; then
  warn "mba-webcam.sh is not here -- skipping"
elif mod_loaded facetimehd || [ -s /lib/firmware/facetimehd/firmware.bin ]; then
  ok "facetimehd already installed (firmware present)"
else
  info "installing the driver and extracting its firmware"
  info "  The blob is downloaded, not shipped -- Apple's, and the extractor"
  info "  fetches it. That makes it an external dependency worth vaulting."
  run "$HERE/mba-webcam.sh" install
fi

# ---- 3. Keyboard backlight ---------------------------------------------------

say "Keyboard backlight"
RULE=/etc/udev/rules.d/60-applesmc-kbd-backlight.rules
if [ -f "$RULE" ]; then
  ok "udev rule already installed"
else
  info "installing the udev rule"
  info "  applesmc registers the backlight LED with a 'nand-disk' default"
  info "  trigger, so disk activity blinks it off. The rule sets it to none."
  run "$HERE/kbd-backlight.sh" install
fi

# ---- 4. Kernel guard ---------------------------------------------------------

say "Kernel guard"
HOOK=/etc/apt/apt.conf.d/99-mba-kernel-guard
if [ -f "$HOOK" ]; then
  ok "apt hook already installed"
else
  info "installing the apt hook"
  info "  It warns AFTER an apt run and BEFORE a reboot if a kernel has landed"
  info "  without wl -- which on a machine with no Ethernet is the difference"
  info "  between a reboot and a rescue."
  run sudo "$HERE/kernel-guard.sh" install-hook --notify
fi

# ---- 5. Power tuning, opt-in -------------------------------------------------

say "Power tuning"
if [ "$TUNE" = 1 ]; then
  info "applying optimize-mba.sh (you asked with --tune)"
  run "$HERE/optimize-mba.sh"
else
  info "NOT applied. Pass --tune if you want it."
  info "  Deliberately opt-in: it was declined on the machine this repo was"
  info "  written for, and an image should not quietly impose a choice its"
  info "  author rejected. Somebody else's laptop is somebody else's decision."
fi

# ---- report ------------------------------------------------------------------

say "State"
# In an image the question is "did it BUILD", not "did it load" -- there is no
# BCM4360 to bind to. Reporting a bare NO here would be a false alarm on every
# single image build, and a report that always shows a failure gets ignored.
if [ "$IMAGE" = 1 ]; then
  printf '    %-22s %s\n' "wl module built"  "$(have_ko 'wl.ko*'         && echo yes || echo NO)"
  printf '    %-22s %s\n' "facetimehd built" "$(have_ko 'facetimehd.ko*' && echo yes || echo NO)"
else
  printf '    %-22s %s\n' "wl loaded"        "$(mod_loaded wl && echo yes || echo NO)"
fi
printf '    %-22s %s\n' "facetimehd fw"    "$([ -s /lib/firmware/facetimehd/firmware.bin ] && echo yes || echo no)"
printf '    %-22s %s\n' "backlight rule"   "$([ -f "$RULE" ] && echo yes || echo no)"
printf '    %-22s %s\n' "kernel-guard hook" "$([ -f "$HOOK" ] && echo yes || echo no)"

if [ -x "$HERE/kernel-guard.sh" ]; then
  say "Every installed kernel, and whether it has its drivers"
  "$HERE/kernel-guard.sh" check 2>&1 | sed 's/^/    /'
fi

say "What is left"
if ! doing; then
  info "Nothing was changed. Re-run as: $0 apply"
else
  info "1. REBOOT and confirm the hardware actually works. A driver that built"
  info "   is not a driver that works -- that distinction is the whole reason"
  info "   kernel-guard has a boot-test."
  info "     ./mba-wifi.sh status ; ./mba-webcam.sh status ; ./kbd-backlight.sh status"
fi
info ""
info "2. Backups, when there is a server to point at:"
info "     ./client-setup.sh YOUR-SERVER --write"
info "     ./home-backup.sh init && ./home-backup.sh backup"
info "     sudo ./system-snapshot.sh configure"
echo
