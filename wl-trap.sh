#!/usr/bin/env bash
# wl-trap.sh -- an ARMED TRAP for the two BCM4360 faults, not a recorder.
#
# It does nothing until something happens. `journalctl -f` blocking on a filter
# costs ~3.8 MB RSS and ZERO CPU while idle, because it is not polling. On a
# 3.8 GB machine that matters, and it is why this is a trap rather than a
# sampler: the samplers used during the 2026-08-17 escalation were deliberately
# temporary.
#
# TRIGGERS -- both have MEASURED false-positive rates over the same 9-day journal
#
#   supplicant interface state: completed -> associated
#       Fires IMMEDIATELY. Occurs ONCE in the entire retained journal (the
#       unexplained 12:43 event on 2026-08-16). Zero false positives. It is a
#       state-machine violation -- you cannot associate when already completed --
#       so its base rate is near zero BY CONSTRUCTION rather than by luck.
#
#   NetworkManager state is now CONNECTED_SITE
#       Requires >60s SUSTAINED loss before firing. The bare transition occurs
#       63 times in 9 days, 56 of them under 2 seconds -- it is a legal stage of
#       every reconnect. Dwell over 60s occurred ONCE: the 17:27:24 wedge.
#       Alerting on the transition would cry wolf ~7 times a day.
#
# ON TRIGGER it captures a snapshot and STOPS. It does not try to recover the
# link, does not touch the radio, and does not reload anything. Recovery is a
# human decision: `sudo modprobe -r wl && sudo modprobe wl` re-associates in ~6s
# (measured), and toggling Wi-Fi also works.
#
#   ./wl-trap.sh              arm it
#   ./wl-trap.sh --test       verify the capture path without waiting for a fault
#
# Runs as an ordinary user. Anything needing root is captured only if a
# passwordless wrapper exists (wl-stat); its absence is recorded, not fatal.

set -uo pipefail

IFACE="${IFACE:-wlp3s0}"
OUTDIR="${OUTDIR:-$HOME/.cache/wl-trap}"
KEEP="${KEEP:-10}"                 # log rotation: snapshots to retain
DWELL="${DWELL:-60}"               # seconds of sustained loss before firing
POLL="${POLL:-10}"                 # seconds between connectivity checks

mkdir -p "$OUTDIR"

# --- log rotation -----------------------------------------------------------
# Oldest-first deletion, keeping $KEEP. Done at ARM time and after each capture,
# so a box that traps repeatedly cannot fill a 4GB disk. Snapshots are a few KB
# each; this is about not leaving unbounded growth behind, not about space today.
rotate() {
    local n
    n=$(find "$OUTDIR" -maxdepth 1 -name 'snap-*.txt' -type f 2>/dev/null | wc -l)
    [ "$n" -le "$KEEP" ] && return 0
    find "$OUTDIR" -maxdepth 1 -name 'snap-*.txt' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | head -n "$((n - KEEP))" | cut -d' ' -f2- | while read -r f; do rm -f "$f"; done
}

capture() {
    local reason="$1" stamp out
    stamp=$(date '+%Y%m%dT%H%M%S')
    out="$OUTDIR/snap-$stamp.txt"

    {
        echo "=== wl-trap snapshot ==="
        echo "reason:  $reason"
        echo "date:    $(date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "uptime:  $(uptime -p 2>/dev/null)"
        echo "kernel:  $(uname -r)"

        echo; echo "--- link ---"
        iw dev "$IFACE" link 2>&1
        echo "power_save: $(iw dev "$IFACE" get power_save 2>&1)"

        echo; echo "--- connectivity ---"
        nmcli -g CONNECTIVITY,STATE general 2>&1
        nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>&1
        ip route show default 2>&1

        echo; echo "--- per-association stats ---"
        # station GET, not DUMP: dump_station is unimplemented in the wl shim and
        # returns an EMPTY LIST rather than an error, which reads as "no data".
        if command -v /usr/local/sbin/wl-stat >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo -n /usr/local/sbin/wl-stat 2>&1
        else
            echo "(wl-stat not available without a password -- signal/bitrate NOT captured)"
            echo "(this is the ONE thing a fault snapshot most wants; see wl-stat-wrapper notes)"
        fi

        echo; echo "--- interface counters ---"
        for f in carrier carrier_changes rx_packets tx_packets rx_errors tx_errors rx_dropped tx_dropped; do
            printf '%-16s %s\n' "$f" "$(cat "/sys/class/net/$IFACE/statistics/$f" 2>/dev/null \
                                        || cat "/sys/class/net/$IFACE/$f" 2>/dev/null || echo '-')"
        done

        echo; echo "--- scan cache (signal is a SNAPSHOT from the last scan, not live) ---"
        iw dev "$IFACE" scan dump 2>/dev/null | grep -aE '^BSS|signal:|last seen:|SSID:' | head -20

        echo; echo "--- recent NetworkManager + supplicant ---"
        journalctl -u NetworkManager -u wpa_supplicant --since '-15min' --no-pager -o short-iso 2>&1 | tail -60

        echo; echo "--- kernel, wifi-related ---"
        journalctl -k --since '-15min' --no-pager -o short-iso 2>&1 \
            | grep -aiE "$IFACE|cfg80211|\bwl\b" | grep -av 'Modules linked in' | tail -20

        echo; echo "--- crash archive (NOT /sys/fs/pstore, which is empty by design) ---"
        ls -1 /var/lib/systemd/pstore/ 2>/dev/null | sed 's/^/record: /' || echo "(unreadable without root)"
    } > "$out" 2>&1

    rotate
    echo "$(date '+%Y-%m-%dT%H:%M:%S')  CAPTURED  $reason  -> $out"
}

if [ "${1:-}" = "--test" ]; then
    echo "test capture (no fault required):"
    capture "TEST -- capture path verification, not a real fault"
    exit 0
fi

rotate
echo "$(date '+%Y-%m-%dT%H:%M:%S')  wl-trap armed on $IFACE"
echo "  triggers: 'completed -> associated' (immediate) | CONNECTED_SITE sustained >${DWELL}s"
echo "  output:   $OUTDIR  (keeping $KEEP)"

# Blocking read. No polling, no timer, no CPU while idle.
journalctl -f -n0 -u NetworkManager -u wpa_supplicant -o cat 2>/dev/null \
| while IFS= read -r line; do
    case "$line" in
        *"supplicant interface state: completed -> associated"*)
            # Zero false positives in 9 days. Fire at once.
            capture "completed -> associated (state-machine violation, 1 occurrence in 9 days)"
            exit 0
            ;;
        *"state is now CONNECTED_SITE"*)
            # 63 occurrences in 9 days, 56 under 2s. Confirm it SUSTAINS.
            waited=0
            while [ "$waited" -lt "$DWELL" ]; do
                sleep "$POLL"; waited=$((waited + POLL))
                if [ "$(nmcli -g CONNECTIVITY general 2>/dev/null)" = "full" ]; then
                    waited=-1; break        # recovered: a normal transient
                fi
            done
            if [ "$waited" -ge "$DWELL" ]; then
                capture "CONNECTED_SITE sustained ${DWELL}s (link held, data not moving)"
                exit 0
            fi
            ;;
    esac
done
