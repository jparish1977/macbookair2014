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

# WirePlumber's V4L2 monitor registers the camera as a PipeWire device and holds
# a reference to the module, so on a stock Mint desktop `modprobe -r` reports
# "in use" even with every camera app closed and no process holding an fd on
# /dev/video*. Stopping it is what actually frees the module — but it also
# carries audio, so only stop it if the plain unload fails, and always start it
# again afterwards.
desktop_user() {
  # The user whose session owns WirePlumber: whoever invoked sudo, else the
  # owner of the running wireplumber process.
  [ -n "${SUDO_USER:-}" ] && { echo "$SUDO_USER"; return; }
  ps -o user= -C wireplumber 2>/dev/null | head -1
}

as_user_systemctl() {
  local u="$1"; shift
  local uid; uid=$(id -u "$u" 2>/dev/null) || return 1
  runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    systemctl --user "$@" >/dev/null 2>&1
}

WP_STOPPED=""
unload_module() { modprobe -r "$MOD" 2>/dev/null; }

say "Reloading the driver"
if lsmod | grep -q "^$MOD"; then
  if ! unload_module; then
    user=$(desktop_user)
    if [ -n "$user" ] && as_user_systemctl "$user" stop wireplumber; then
      info "stopped WirePlumber (it holds the camera); retrying"
      WP_STOPPED="$user"
      sleep 2
    fi
  fi

  if ! lsmod | grep -q "^$MOD"; then
    : # already gone
  elif ! unload_module; then
    bad "The driver is stuck and won't unload."
    # A task frozen inside the driver (state D) cannot be signalled, and holds
    # the module against any unload. Only a reboot clears that.
    if ps -eo stat= | grep -q '^D'; then
      info "A process is frozen inside the driver — a reboot is the only fix."
    else
      info "Something still holds the camera that stopping WirePlumber did not free."
    fi
    [ -n "$WP_STOPPED" ] && as_user_systemctl "$WP_STOPPED" start wireplumber
    info "A reboot clears this cleanly:   sudo reboot"
    exit 1
  fi
  ok "old driver unloaded"
fi

modprobe "$MOD" || { bad "Could not load $MOD. Check:  dkms status $MOD"; exit 1; }
sleep 1
ok "driver reloaded"

# Bring audio back up if we took it down to free the module.
if [ -n "$WP_STOPPED" ]; then
  as_user_systemctl "$WP_STOPPED" start wireplumber && ok "WirePlumber restarted" \
    || warn "could not restart WirePlumber — log out and back in if sound is missing"
fi

say "Result"
node=$(ls /dev/video* 2>/dev/null | head -1)
if [ -n "$node" ]; then
  ok "camera is back at $node"
  info "Open ONE camera app now (Cheese, Zoom, or OBS) — not two at once."
else
  bad "No camera device appeared. A reboot should fix it:  sudo reboot"
  exit 1
fi
