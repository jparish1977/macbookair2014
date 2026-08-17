#!/usr/bin/env bash
# ap-control.sh -- an independent witness for the MacBook Air's Wi-Fi faults.
#
# WHY THIS RUNS ON A DIFFERENT MACHINE
#   The Air's BCM4360 publishes NO link statistics: `iw station dump` is empty
#   even as root, /proc/net/wireless has no row for it, and wpa_supplicant logs
#   "bgscan simple: Failed to enable signal strength monitoring" after every
#   association. So when the link rots, nothing on that machine can see it --
#   not a bug in the tooling, an absence of the sensor.
#
#   That is only true of THAT CARD. A second machine associated to the SAME AP
#   on the SAME BAND can measure everything the Air cannot, and its readings
#   describe the same radio environment. Run this there.
#
#   Verified 2026-08-17 on joe-ThinkPad-E15-Gen-3 (rtw89_8852ae, in-tree):
#     both boxes associated to the same SSID, same BSSID, same channel,
#     same 5 GHz band -- verified before trusting a single reading
#     /proc/net/wireless has a live row; zero bgscan failures.
#
#   This is the control m18-ginger could not provide: that machine was on a
#   different BSSID *and* a different band, so its healthy link ruled out only a
#   whole-network outage, not an AP-side or band-specific fault.
#
# WHAT IT DECIDES
#   When the Air next wedges, compare timestamps:
#     this box degraded too   -> environmental / AP-side, NOT the card
#     this box stayed clean   -> the fault is local to the Air's BCM4360
#   Either answer settles a question that has been open since 2026-08-16.
#
# Read-only. Never touches the radio.
#
# NOTE: `iw` is a hard dependency (station dump, below). It was NOT installed on
# this ThinkPad until 2026-08-17 -- an early draft avoided it for that reason and
# the avoidance is now stale. Check for it rather than assuming, because "which
# tools exist" is exactly the sort of claim a transcript from another machine
# hands you wrongly.

set -uo pipefail

IFACE="${IFACE:-wlp2s0}"
OUT="${OUT:-$HOME/.cache/ap-control.tsv}"
INTERVAL="${INTERVAL:-30}"
# The AP the observed machine is on. Readings only count as a control while
# this box stays associated to the SAME AP -- hence the same_ap column.
#
# Derived from the live association by default rather than hardcoded, so this
# stays correct across network changes AND carries no site-specific identifier
# into a PUBLIC repository. Override to pin it deliberately:
#     WATCH_BSSID=aa:bb:cc:dd:ee:ff ./ap-control.sh
WATCH_BSSID="${WATCH_BSSID:-$(iw dev "${IFACE:-wlp2s0}" link 2>/dev/null | awk '/^Connected to/{print toupper($3); exit}')}"

# NOTE ON `iw survey dump`: it returns EMPTY on this card even as root, and the
# driver advertises no survey capability, so there is no channel-busy-time or
# noise floor to be had here. /proc/net/wireless also reports noise as -256,
# meaning "not reported". Congestion is therefore NOT measurable on this box --
# say so rather than inferring it from signal.

[ -f "$OUT" ] || printf 'ts\tconnectivity\tbssid\tsame_ap\tchan\tsignal_pct\tlink\tlevel_dbm\tsignal_dbm\tsignal_avg\tbeacon_sig_avg\ttx_retries\ttx_failed\tbeacon_loss\tbeacon_rx\trx_drop_misc\ttx_bitrate\trx_bitrate\tinactive_ms\n' > "$OUT"

while true; do
    ts=$(date '+%Y-%m-%dT%H:%M:%S')

    conn=$(nmcli -g CONNECTIVITY general 2>/dev/null); : "${conn:=?}"

    # Active AP, from the in-use row. nmcli escapes colons in BSSID, hence sed.
    read -r bssid chan sigpct rate < <(
        nmcli -t -f IN-USE,BSSID,CHAN,SIGNAL,RATE dev wifi 2>/dev/null \
        | awk -F: '$1=="*"{ $1=""; print }' \
        | sed 's/\\//g' \
        | awk '{ b=$1$2$3$4$5$6; print b, $7, $8, $9" "$10 }'
    )
    : "${bssid:=-}"; : "${chan:=-}"; : "${sigpct:=-}"; : "${rate:=-}"

    if [ "${bssid^^}" = "${WATCH_BSSID//:/}" ] || [ "${bssid^^}" = "${WATCH_BSSID^^}" ]; then
        same="YES"
    else
        same="NO"   # readings still useful, but no longer a same-AP control
    fi

    # Coarse, always available.
    read -r link level < <(
        awk -v i="${IFACE}:" '$1==i { gsub(/\./,"",$3); gsub(/\./,"",$4); print $3, $4 }' /proc/net/wireless 2>/dev/null
    )
    : "${link:=-}"; : "${level:=-}"

    # The real prize: per-association statistics. The Air's BCM4360 returns an
    # EMPTY station dump even as root -- this is the telemetry that does not
    # exist over there, measured on the same AP, same band, same channel.
    # Counters (retries, failed, beacon_loss, drops) are cumulative: diff them.
    eval "$(iw dev "$IFACE" station dump 2>/dev/null | awk -F'\t' '
        /signal:/          { split($3,a," "); print "s_sig="   a[1] }
        /signal avg:/      { split($3,a," "); print "s_avg="   a[1] }
        /beacon signal avg/{ split($3,a," "); print "s_bavg="  a[1] }
        /tx retries:/      { print "s_retr="  $3 }
        /tx failed:/       { print "s_fail="  $3 }
        /beacon loss:/     { print "s_bloss=" $3 }
        /beacon rx:/       { print "s_brx="   $3 }
        /rx drop misc:/    { print "s_drop="  $3 }
        /tx bitrate:/      { split($3,a," "); print "s_txr="   a[1] }
        /rx bitrate:/      { split($3,a," "); print "s_rxr="   a[1] }
        /inactive time:/   { split($3,a," "); print "s_inact=" a[1] }
    ')"
    for v in s_sig s_avg s_bavg s_retr s_fail s_bloss s_brx s_drop s_txr s_rxr s_inact; do
        [ -z "${!v:-}" ] && printf -v "$v" '%s' '-'
    done

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$conn" "$bssid" "$same" "$chan" "$sigpct" "$link" "$level" \
        "$s_sig" "$s_avg" "$s_bavg" "$s_retr" "$s_fail" "$s_bloss" "$s_brx" \
        "$s_drop" "$s_txr" "$s_rxr" "$s_inact" >> "$OUT"

    sleep "$INTERVAL"
done
