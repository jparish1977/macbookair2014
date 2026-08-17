#!/usr/bin/env bash
# wl-sample.sh -- sample the Wi-Fi sensors that nobody was recording when the
#                 2026-08-16 wedge happened.
#
# WHY THIS EXISTS
#   The Fable review of that incident found one open question it called
#   "unknowable post-hoc": the scan cache carries a signal reading AND a
#   freshness timestamp ("last seen: N ms ago"), and nobody knows whether that
#   cache keeps refreshing while the link is wedged. If it goes stale during a
#   fault, it is a passive detector for a failure mode that currently has none.
#   The only way to find out is to be recording BEFORE the fault, so: this.
#
#   Everything here is read-only. It never touches the radio. `iw scan dump`
#   reads the cache and does NOT trigger a scan.
#
# OUTPUT
#   One TSV line per sample to $OUT. Fields chosen so a wedge is visible by
#   reading down a column:
#
#     ts  connectivity  state  bssid  freq  signal_dbm  last_seen_ms  stations
#
#   stations is the count of entries in `iw station dump`, which on this card
#   is expected to be 0 always -- wl publishes no per-association statistics.
#   It is sampled anyway so that "always 0" is measured rather than assumed.

set -uo pipefail

IFACE="${IFACE:-wlp3s0}"
OUT="${OUT:-$HOME/.cache/wl-sample.tsv}"
INTERVAL="${INTERVAL:-30}"

[ -f "$OUT" ] || printf 'ts\tconnectivity\tstate\tbssid\tfreq\tsignal_dbm\tlast_seen_ms\tstations\n' > "$OUT"

while true; do
    ts=$(date '+%Y-%m-%dT%H:%M:%S')

    conn=$(nmcli -g CONNECTIVITY general 2>/dev/null); : "${conn:=?}"
    state=$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v i="$IFACE" '$1==i{print $2}')
    : "${state:=?}"

    # Associated BSSID, from the link query. Absent when not associated.
    bssid=$(iw dev "$IFACE" link 2>/dev/null | awk '/^Connected to/{print $3}')
    : "${bssid:=-}"
    freq=$(iw dev "$IFACE" link 2>/dev/null | awk '/freq:/{print $2}')
    : "${freq:=-}"

    # The two fields this script exists for. Read from the scan CACHE for the
    # BSS flagged "associated", so they describe the link in use.
    read -r sig seen < <(iw dev "$IFACE" scan dump 2>/dev/null | awk '
        /^BSS /            { assoc = /associated/ ? 1 : 0 }
        assoc && /signal:/    { s = $2 }
        assoc && /last seen:/ { l = $3; print s, l; exit }
    ')
    : "${sig:=-}"; : "${seen:=-}"

    # Expected to be 0 on this hardware. Measured, not assumed.
    stations=$(iw dev "$IFACE" station dump 2>/dev/null | command grep -c '^Station')

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$conn" "$state" "$bssid" "$freq" "$sig" "$seen" "$stations" >> "$OUT"

    sleep "$INTERVAL"
done
