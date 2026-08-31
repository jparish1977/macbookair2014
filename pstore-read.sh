#!/usr/bin/env bash
# pstore-read.sh -- read the archived kernel crash dumps this machine has been
#                   collecting without anyone looking at them.
#
# WHY THIS IS NOT `ls /sys/fs/pstore`
#   Checking /sys/fs/pstore finds it EMPTY and that means nothing, because
#   systemd-pstore.service archives the contents to /var/lib/systemd/pstore/
#   on boot and then CLEARS the pstore. An empty /sys/fs/pstore is the normal
#   state of a machine that has crashed and successfully recorded it.
#
#   Measured 2026-08-16: /sys/fs/pstore was empty and the archive held an
#   18-part EFI dump from 2026-08-08 00:08:23. The instrument was working the
#   whole time and was being read in the wrong place.
#
# Needs root: the archive is 0600 root.
#
#   sudo ./pstore-read.sh            # summarise every archived crash
#   sudo ./pstore-read.sh --full ID  # dump one record whole

set -uo pipefail

ARCHIVE=/var/lib/systemd/pstore
LIVE=/sys/fs/pstore

if [ "$(id -u)" -ne 0 ]; then
    echo "needs root: sudo $0 $*" >&2
    exit 1
fi

if [ "${1:-}" = "--full" ]; then
    id="${2:?usage: $0 --full <timestamp-id>}"
    f="$ARCHIVE/$id/001/dmesg.txt"
    [ -f "$f" ] || { echo "no such record: $f" >&2; exit 1; }
    cat "$f"
    exit 0
fi

echo "=== live pstore (expected EMPTY on a healthy boot -- see header) ==="
ls -1 "$LIVE" 2>/dev/null | head || true
[ -z "$(ls -A "$LIVE" 2>/dev/null)" ] && echo "  (empty -- NOT evidence of no crash)"

echo
echo "=== archived crash records ==="
shopt -s nullglob
recs=("$ARCHIVE"/*/)
if [ ${#recs[@]} -eq 0 ]; then
    echo "  none -- this machine has never archived a crash dump"
    exit 0
fi

for d in "${recs[@]}"; do
    id=$(basename "$d")
    when=$(date -d "@$id" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "id $id")
    f="$d/001/dmesg.txt"
    parts=$(find "$d" -name 'dmesg-*' 2>/dev/null | wc -l)

    echo
    echo "-------------------------------------------------------------"
    echo "RECORD $id   crashed: $when   ($parts EFI fragments)"
    echo "-------------------------------------------------------------"
    [ -f "$f" ] || { echo "  no reassembled dmesg.txt"; continue; }

    echo "--- why it died ---"
    grep -aiE 'kernel panic|BUG:|Oops|unable to handle|general protection|watchdog: BUG|RIP:' "$f" \
        | head -8 | sed 's/^/  /' || echo "  (no panic banner found)"

    # Which driver is actually in the trace. NOTE: "Modules linked in" lists
    # every loaded module and wraps onto continuation lines, so a naive grep
    # for a driver name matches on machines where it is merely present. Only
    # the Call Trace frames say who was executing. Match the [module] suffix
    # the kernel puts on traced frames instead.
    echo "--- drivers named in the CALL TRACE (not the module list) ---"
    culprits=$(awk '/Call Trace/,/end trace|<\/TASK>/' "$f" \
        | grep -ao '\[[a-z0-9_]*\]' | sort | uniq -c | sort -rn | head -6)
    if [ -n "$culprits" ]; then
        printf '%s\n' "$culprits" | sed 's/^/  /'
    else
        echo "  (no module-attributed frames)"
    fi

    echo "--- is the wifi driver in the trace? ---"
    if awk '/Call Trace/,/end trace|<\/TASK>/' "$f" \
        | grep -qaE '\[(wl|cfg80211|brcmfmac|mac80211)\]'; then
        echo "  YES -- wl/cfg80211 appears in the call trace"
    else
        echo "  no -- wifi appears only in the module list, which means nothing"
    fi

    echo "--- call trace (first 12 frames) ---"
    awk '/Call Trace/{c=1} c&&n<13{print "  "$0; n++}' "$f" || true

    echo "--- last 8 lines before it stopped ---"
    tail -8 "$f" | sed 's/^/  /'
done

echo
echo "============================================================="
echo "Full text of a record:  sudo $0 --full <ID>"
echo "Records live under $ARCHIVE and are NOT cleared automatically."
