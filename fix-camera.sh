#!/usr/bin/env bash
# fix-camera — recover the FaceTime HD camera when it stops working.
#
# The facetimehd driver on this MacBook Air stops delivering frames if two apps
# grab the camera at the same time (or sometimes after a single use). The kernel
# logs "facetimehd ...: IO: timeout" and every camera app then shows an error.
# Reloading the driver clears that without a reboot.
#
#   Just run:   fix-camera
#   It asks for a password once (needed to reload a driver).
#
# The one rule that avoids the whole problem: only ONE camera app open at a time
# — close Zoom before opening OBS, close Cheese before joining a call, etc.

set -uo pipefail

MOD=facetimehd

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[warn]\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m[!!]\033[0m   %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# Reloading a kernel module needs root, so re-run ourselves under sudo. This is
# why it prompts for a password; nothing else here is privileged.
if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

say "Closing camera apps"
# TERM the usual suspects by name, plus the whole Zoom tree, plus anything still
# holding a /dev/video* node. A clean TERM first, then KILL for stragglers so a
# hung app can't keep the driver pinned.
for app in zoom ZoomLauncher cheese obs guvcview; do
  pkill -TERM -x "$app" 2>/dev/null && info "asked $app to quit"
done
pkill -TERM -f /opt/zoom 2>/dev/null
fuser -k -TERM /dev/video* 2>/dev/null
sleep 2
fuser -k -KILL /dev/video* 2>/dev/null
sleep 1
ok "camera apps closed"

say "Reloading the driver"
if lsmod | grep -q "^$MOD"; then
  if ! modprobe -r "$MOD" 2>/dev/null; then
    bad "The driver is stuck and won't unload."
    # After an IO timeout a process can freeze *inside* the driver (state D),
    # holding it open against any signal. Nothing short of a reboot frees that.
    if ps -eo stat= | grep -q '^D'; then
      info "A process is frozen inside the driver (normal after an IO timeout)."
    else
      info "Something is still using the camera."
    fi
    info "A reboot clears this cleanly:   sudo reboot"
    exit 1
  fi
  ok "old driver unloaded"
fi

modprobe "$MOD" || { bad "Could not load $MOD. Check:  dkms status $MOD"; exit 1; }
sleep 1
ok "driver reloaded"

say "Result"
node=$(ls /dev/video* 2>/dev/null | head -1)
if [ -n "$node" ]; then
  ok "camera is back at $node"
  info "Open ONE camera app now (Cheese, Zoom, or OBS) — not two at once."
else
  bad "No camera device appeared. A reboot should fix it:  sudo reboot"
  exit 1
fi
