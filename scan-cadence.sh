#!/usr/bin/env bash
# scan-cadence.sh -- how often does the scan cache actually refresh?
#
# WHY THIS IS SEPARATE FROM ap-control.sh
#   It answers one question and it has to sample FASTER and run LONGER than the
#   thing it measures. That is the whole point.
#
# THE MISTAKE THIS EXISTS TO NOT REPEAT
#   On 2026-08-16 the Air's session sampled `iw scan dump` for 60 seconds, saw
#   "last seen" climb monotonically and the signal sit at -59.00 on every
#   sample, and concluded the scan cache never refreshes and the signal is
#   frozen -- so scan-cache staleness was dead as a wedge detector.
#
#   Both conclusions were wrong. Measured over 70 minutes the cache refreshes
#   roughly every 5 minutes: "last seen" sawtooths from ~0 to a ceiling near
#   300s and resets, and the signal moves across -54 to -61. The 60s window was
#   shorter than one period, so a sawtooth looked monotonic and a periodic value
#   looked constant.
#
#   AN OBSERVATION WINDOW SHORTER THAN THE PHENOMENON'S PERIOD RETURNS A
#   CONFIDENT WRONG ANSWER, NOT NO ANSWER. Nothing in the output announces that
#   the window was a fragment. Run this for at least 3x the period you expect,
#   and if you do not know the period, that is the reason to run it, not a
#   reason to guess.
#
# WHAT THE DETECTOR PROBABLY IS
#   Not "the cache went stale" -- it always does, between scans. The real signal
#   is SCAN CESSATION: if the healthy ceiling is ~300s, then "last seen" beyond
#   roughly 360s means scanning itself has stopped. That has a threshold, and a
#   baseline is required before anyone can set it. Hence this.
#
# Read-only. `iw scan dump` reads the cache; it does NOT trigger a scan.

set -uo pipefail

IFACE="${IFACE:-wlp2s0}"
OUT="${OUT:-$HOME/.cache/scan-cadence.tsv}"
INTERVAL="${INTERVAL:-10}"

[ -f "$OUT" ] || printf 'ts\tlast_seen_ms\tsignal_dbm\tbssid\n' > "$OUT"

while true; do
    ts=$(date '+%Y-%m-%dT%H:%M:%S')

    # The BSS flagged "associated" is the link in use. Its "last seen" is the
    # age of this cache entry, which resets when a scan refreshes it.
    # CAREFUL: this iw prints TWO "last seen" lines per BSS --
    #   last seen: 443071.182s [boottime]   <- a boottime stamp, not an age
    #   last seen: 76 ms ago                <- the age of the cache entry
    # Matching the first one silently yields a number that looks plausible and
    # is not the quantity. Anchor on "ago".
    read -r seen sig bss < <(iw dev "$IFACE" scan dump 2>/dev/null | awk '
        /^BSS /                  { bssid=$2; sub(/\(.*/,"",bssid); assoc = /associated/ ? 1 : 0 }
        assoc && /signal:/       { s=$2 }
        assoc && /last seen:.*ago/ { print $3, s, bssid; exit }')
    : "${seen:=-}"; : "${sig:=-}"; : "${bss:=-}"

    printf '%s\t%s\t%s\t%s\n' "$ts" "$seen" "$sig" "$bss" >> "$OUT"
    sleep "$INTERVAL"
done
