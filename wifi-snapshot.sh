#!/usr/bin/env bash
# wifi-snapshot.sh — capture the state of the Wi-Fi stack at the moment it
#                    misbehaves, while the machine is still responsive.
#
# WHY THIS EXISTS
#   The wl driver is a binary blob. When it fails there is often nothing useful
#   in the logs afterwards — the 2026-07 panics flushed nothing at all — so the
#   evidence has to be collected while the fault is happening. Rebooting first
#   destroys everything worth having.
#
#   Run this the moment Wi-Fi misbehaves, before rebooting:
#
#       ./wifi-snapshot.sh
#
#   It writes a timestamped file under ~/wifi-snapshots/ and prints a verdict.
#   No arguments, no sudo required — it degrades gracefully without root.
#
# WHAT IT IS ACTUALLY FOR
#   A single dump cannot distinguish "the link dropped but the driver is fine"
#   from "the driver is wedged" — an idle driver and a dead one look identical.
#   So this does not just look, it POKES: it asks the driver an nl80211 question
#   and pushes packets at the gateway, then checks whether frames actually left
#   the interface.
#
#   Interrupt counts are reported but deliberately discounted. This BCM4360 has
#   no MSI vector, so it shares a legacy IRQ line with i801_smbus and the count
#   keeps rising whether or not wl is alive.

set -uo pipefail

IFACE="${IFACE:-}"
GAP="${GAP:-4}"                       # seconds between the two samples
OUTDIR="${OUTDIR:-$HOME/wifi-snapshots}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[warn]\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m[!!]\033[0m   %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

# Everything below is best-effort. A diagnostic that aborts because one tool is
# missing collects nothing, which is the one outcome that cannot be salvaged.
have() { command -v "$1" >/dev/null 2>&1; }

# Every command that touches the driver runs under a timeout. A wedged wl can
# block an nl80211 query indefinitely, and a diagnostic that hangs instead of
# writing its file is worse than useless — the hang IS the finding, so record it
# and move on.
try()  { timeout 6 "$@" 2>&1 || echo "[no response within 6s or command failed: $*]"; }
tryq() { timeout 6 "$@" 2>/dev/null; }

detect_iface() {
  [ -n "$IFACE" ] && { echo "$IFACE"; return; }
  # The wireless interface as the kernel sees it, not as a config file claims.
  for d in /sys/class/net/*/wireless; do
    [ -e "$d" ] && { basename "$(dirname "$d")"; return; }
  done
  echo ""
}

# PCI address of the wireless device, for bus and interrupt lookups.
wifi_pci() {
  local i="$1" p
  p=$(readlink -f "/sys/class/net/$i/device" 2>/dev/null) || return 1
  basename "$p"
}

counters() {                          # rx_bytes rx_errors tx_bytes tx_errors
  local i="$1" b="/sys/class/net/$1/statistics"
  printf '%s %s %s %s' \
    "$(cat "$b/rx_bytes" 2>/dev/null || echo 0)" \
    "$(cat "$b/rx_errors" 2>/dev/null || echo 0)" \
    "$(cat "$b/tx_bytes" 2>/dev/null || echo 0)" \
    "$(cat "$b/tx_errors" 2>/dev/null || echo 0)"
}

# Total interrupts on the line this interface sits on.
#
# CAVEAT, and it matters: this BCM4360 has no MSI vector — check
# /sys/bus/pci/devices/<pci>/msi_irqs, it is empty — so it sits on the legacy
# shared IRQ alongside i801_smbus. The count is therefore NOT wifi-exclusive and
# a rising number does not prove the driver is alive. It is reported as a weak
# signal only. The active probe below is the real test.
irq_count() {
  local iface="$1" n=0 line
  while IFS= read -r line; do
    case "$line" in
      *"$iface"*)
        n=$(printf '%s' "$line" | awk '{s=0; for(i=2;i<=NF;i++) if ($i ~ /^[0-9]+$/) s+=$i; print s}')
        echo "$n"; return ;;
    esac
  done < /proc/interrupts
  echo 0
}

irq_is_shared() {
  local iface="$1" line
  while IFS= read -r line; do
    case "$line" in
      *"$iface"*)
        # More than one driver name after the controller field means shared.
        printf '%s' "$line" | grep -q ',' && return 0 || return 1 ;;
    esac
  done < /proc/interrupts
  return 1
}

# The real liveness test: make the driver do something and see whether it does.
#
# Passive counters cannot tell a wedged driver from an idle one — both show
# zero. So push packets at the default gateway and check whether they actually
# leave the interface. tx_bytes not moving while we are actively transmitting
# means the driver is not accepting frames, which no amount of log reading
# establishes as clearly.
active_probe() {
  local iface="$1" gw
  gw=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
  PROBE_GW="${gw:-none}"
  PROBE_TX_DELTA=0
  PROBE_REPLIES=0
  PROBE_IW_OK=0

  # Does the control path answer at all? A hang here is itself the diagnosis.
  #
  # Judge this on the ANSWER, not the exit code. Run unprivileged, `iw dev link`
  # prints the association fine and then exits 255 with "Operation not
  # permitted" because the signal/bitrate part of the query needs root. Testing
  # the status therefore reports a perfectly healthy driver as wedged — which is
  # exactly the false positive this script must never produce.
  local iwout
  iwout=$(timeout 6 iw dev "$iface" link 2>/dev/null)
  if printf '%s' "$iwout" | grep -qiE 'Connected to|Not connected'; then
    PROBE_IW_OK=1
  fi
  PROBE_ASSOC=0
  printf '%s' "$iwout" | grep -qi 'Connected to' && PROBE_ASSOC=1

  [ -n "$gw" ] || return 0

  # Two attempts. A single ping burst can come back empty for reasons that have
  # nothing to do with the driver — a roam, a momentarily busy CPU, one dropped
  # frame — and this script was observed flipping between "wedged" and "healthy"
  # on consecutive runs against a perfectly working link because of exactly
  # that. A verdict that is not reproducible is worse than none, so "no frames
  # left the interface" has to fail twice before it is believed.
  local attempt t1 t2
  PROBE_ATTEMPTS=0
  for attempt in 1 2; do
    PROBE_ATTEMPTS=$attempt
    t1=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
    PROBE_REPLIES=$(timeout 8 ping -c 4 -i 0.3 -W 1 -I "$iface" "$gw" 2>/dev/null \
                    | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+' || echo 0)
    : "${PROBE_REPLIES:=0}"
    t2=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
    PROBE_TX_DELTA=$((t2 - t1))
    # Anything moved, or anything came back: no need to retry.
    [ "$PROBE_TX_DELTA" -gt 0 ] && break
    [ "$PROBE_REPLIES" -gt 0 ] && break
    [ "$attempt" -eq 1 ] && sleep 1
  done
}

main() {
  local iface pci stamp out
  iface=$(detect_iface)
  if [ -z "$iface" ]; then
    bad "No wireless interface found in /sys/class/net."
    info "If the device fell off the PCI bus entirely, that is itself the finding:"
    try lspci -nn | grep -i network
    exit 1
  fi
  pci=$(wifi_pci "$iface" || echo "")

  mkdir -p "$OUTDIR" 2>/dev/null || { bad "cannot create $OUTDIR"; exit 1; }
  stamp=$(date +%Y%m%d-%H%M%S)
  out="$OUTDIR/wifi-$stamp.txt"

  say "Capturing $iface${pci:+ ($pci)} — $GAP second sample window"

  # First sample, before anything slow runs.
  local c1 i1 c2 i2
  c1=$(counters "$iface")
  i1=$(irq_count "$iface")

  {
    echo "=== wifi-snapshot $stamp"
    echo "host      $(hostname)"
    echo "kernel    $(uname -r)"
    echo "uptime    $(uptime -p 2>/dev/null)"
    echo "iface     $iface"
    echo "pci       ${pci:-unknown}"
    echo
    echo "=== driver"
    try lsmod | grep -E '^(wl|brcmfmac|b43|bcma) '
    echo "-- module version"
    try modinfo -F version wl
    echo "-- taint (from the blob, expected)"
    try cat /proc/sys/kernel/tainted
    echo
    echo "=== is the device still on the bus"
    [ -n "$pci" ] && try lspci -nnvv -s "$pci" | head -25
    echo "-- PCI link state (a device that dropped off shows here)"
    [ -n "$pci" ] && try cat "/sys/bus/pci/devices/$pci/power/runtime_status"
    echo
    echo "=== link"
    try iw dev "$iface" link
    try iw dev "$iface" get power_save
    try iw reg get
    echo "-- station (signal, retries, failures)"
    try iw dev "$iface" station dump
    echo
    echo "=== addressing"
    try ip -br addr show "$iface"
    try ip route
    echo
    echo "=== rfkill"
    try rfkill list
    echo
    echo "=== NetworkManager"
    try nmcli -t -f NAME,STATE,DEVICE connection show --active
    try nmcli -t -f GENERAL.STATE,GENERAL.REASON device show "$iface"
    echo
    echo "=== kernel messages mentioning the driver"
    try dmesg 2>/dev/null | grep -iE 'wl[: ]|wlc_|ieee80211|cfg80211|firmware' | tail -40
    echo
    echo "=== last 60 kernel lines regardless of subsystem"
    try dmesg 2>/dev/null | tail -60
    echo
    echo "=== recent supplicant / NM journal"
    try journalctl --no-pager -n 60 -u NetworkManager -u wpa_supplicant 2>/dev/null | tail -60
  } > "$out" 2>&1

  # Probe during the sample window rather than merely waiting through it.
  active_probe "$iface"
  sleep 1
  c2=$(counters "$iface")
  i2=$(irq_count "$iface")

  # The delta is the point of the whole exercise, so it goes in the file too.
  local rx1 rxe1 tx1 txe1 rx2 rxe2 tx2 txe2
  read -r rx1 rxe1 tx1 txe1 <<<"$c1"
  read -r rx2 rxe2 tx2 txe2 <<<"$c2"
  local drx=$((rx2 - rx1)) dtx=$((tx2 - tx1)) dirq=$((i2 - i1))
  local drxe=$((rxe2 - rxe1)) dtxe=$((txe2 - txe1))

  IRQ_NOTE=""
  irq_is_shared "$iface" && IRQ_NOTE="  [SHARED LINE — not wifi-exclusive, weak signal]"

  {
    echo
    echo "=== active probe  (the real test)"
    echo "gateway            $PROBE_GW"
    echo "iw link responded  $([ "$PROBE_IW_OK" -eq 1 ] && echo yes || echo "NO - control path hung or errored")"
    echo "tx_bytes moved     $PROBE_TX_DELTA  (while actively pinging)"
    echo "ping replies       $PROBE_REPLIES of 4  (attempts: $PROBE_ATTEMPTS)"
    echo
    echo "=== passive movement over the window"
    printf 'rx_bytes   +%s\n' "$drx"
    printf 'tx_bytes   +%s\n' "$dtx"
    printf 'rx_errors  +%s\n' "$drxe"
    printf 'tx_errors  +%s\n' "$dtxe"
    printf 'interrupts +%s   (was %s, now %s)%s\n' "$dirq" "$i1" "$i2" "$IRQ_NOTE"
  } >> "$out"

  sync 2>/dev/null || true      # the machine may not survive much longer

  ok "written to $out"

  # Verdict, led by the active probe. The passive counters and the shared
  # interrupt line are corroboration, not the test — an idle driver and a wedged
  # one look identical to both.
  say "Reading"

  if [ "$PROBE_IW_OK" -eq 0 ]; then
    bad "the driver did not answer an nl80211 query within 6s"
    info "That is the strongest wedge signal available — the control path is"
    info "gone, not just the link. Note the time and what was running."
  elif [ "$PROBE_ASSOC" -eq 0 ]; then
    warn "driver responds, but the interface is NOT associated to any AP"
    info "Not a wedged blob — this is an association failure. Check the AP,"
    info "the saved credentials, and the supplicant journal in the capture."
  elif [ "$PROBE_GW" = "none" ]; then
    warn "no default route, so transmit could not be tested"
    info "The driver answered control queries, so it is not fully wedged."
  elif [ "$PROBE_TX_DELTA" -eq 0 ]; then
    bad "frames did NOT leave the interface, across $PROBE_ATTEMPTS attempts"
    info "The driver is accepting nl80211 queries but not transmitting."
    info "This is the interesting failure — a dump alone would have looked idle."
  elif [ "$PROBE_REPLIES" -eq 0 ]; then
    warn "transmitted ${PROBE_TX_DELTA}B but got 0 of 4 replies from $PROBE_GW"
    info "Frames are leaving and nothing is coming back: association may be"
    info "stale, or the AP has stopped answering. The driver itself is alive."
  else
    ok "driver alive and passing traffic — $PROBE_REPLIES/4 replies from $PROBE_GW"
    info "If Wi-Fi still feels wrong, the fault is above the driver:"
    info "DNS, routing, or the far end. Capture again when it is actually bad."
  fi

  if [ "$drxe" -gt 0 ] || [ "$dtxe" -gt 0 ]; then
    warn "interface errors increased during the window (rx +$drxe, tx +$dtxe)"
  fi

  # Reported, but explicitly discounted: this device has no MSI vector so it
  # shares a legacy line with i801_smbus, and that alone keeps the count rising.
  if irq_is_shared "$iface"; then
    info "interrupts +$dirq (shared line with another device — proves nothing on its own)"
  else
    info "interrupts +$dirq on a dedicated line"
  fi

  if [ "$PROBE_IW_OK" -eq 0 ] || [ "$PROBE_TX_DELTA" -eq 0 ]; then
    info ""
    info "A module reload may clear it without a reboot:"
    info "  systemctl --user stop wireplumber   # only if it holds the device"
    info "  sudo modprobe -r wl && sudo modprobe wl"
    info "If that hangs, only a reboot will help — this file survives it."
  fi

  info ""
  info "Attach $out to whatever you write up."
}

main "$@"
