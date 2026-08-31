#!/usr/bin/env bash
# wl-escalate.sh -- open N concurrent TCP connections across the local /24 and
#                   see whether the wl driver survives it.
#
# WHAT THIS IS TESTING
#   WIFI.md:83 records, corroborated from batocera-watch's CLAUDE.md at the time
#   it happened: "the dev machine's Broadcom wl driver hard-locks the whole
#   laptop on connection bursts; a /24 sweep opening 254 sockets froze it. Cap
#   batches at ~24." The cap has been in place ever since, which is why the
#   fault has not been seen lately.
#
#   THE SUCCESS CONDITION OF THIS TEST IS A WHOLE-MACHINE HARD LOCK. It is not
#   a crash you recover from -- the machine stops responding and everything
#   unsaved is gone. Run it deliberately or not at all.
#
# WHY ONE LEVEL PER INVOCATION
#   So a human stays in the loop between escalations, and so the level that
#   locked is known rather than inferred. Escalate by hand: 24, 48, 96, 254.
#
# THE MARKER IS THE POINT
#   A hard lock flushes nothing, so the record has to exist BEFORE the attempt.
#   This fsyncs a marker file naming the level and the time, then starts. After
#   a lock, that file is the only evidence of what was being attempted.
#   pstore may also capture, IF the fault panics rather than hangs.
#
# USAGE
#   ./wl-escalate.sh 24        # start here: the known-safe cap, a CONTROL
#   ./wl-escalate.sh 48
#   ./wl-escalate.sh 96
#   ./wl-escalate.sh 254       # the level that froze it in August

set -uo pipefail

N="${1:?usage: $0 <concurrent-connections>}"
SUBNET="${SUBNET:-10.0.0}"
PORT="${PORT:-80}"
MARKER="${MARKER:-$HOME/.cache/wl-escalate-marker}"
IFACE="${IFACE:-wlp3s0}"

# Refuse to run if the sweep would not actually traverse the wireless link --
# the tether is the default route right now, and a test that exercises the USB
# adapter instead of the radio proves nothing.
route_dev=$(ip route get "${SUBNET}.47" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
if [ "$route_dev" != "$IFACE" ]; then
    echo "REFUSING: ${SUBNET}.0/24 routes via '${route_dev:-none}', not $IFACE." >&2
    echo "The sweep would not touch the radio. Nothing to learn." >&2
    exit 2
fi

python3 - "$N" "$SUBNET" "$PORT" "$MARKER" <<'PY'
import os, sys, socket, time, errno

n, subnet, port, marker = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), sys.argv[4]

# Write and FSYNC the marker before touching the radio. If the machine locks,
# this file is the only thing that says what it was doing.
with open(marker, "a") as f:
    f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')}  ATTEMPTING n={n} subnet={subnet}.0/24\n")
    f.flush()
    os.fsync(f.fileno())
os.sync()

print(f"marker fsynced. opening {n} concurrent sockets to {subnet}.0/24 ...", flush=True)

socks = []
t0 = time.time()
# All connects issued before any is waited on -- the burst is the point, not
# the throughput. A sequential sweep of the same 254 hosts never did this.
for i in range(n):
    host = f"{subnet}.{(i % 254) + 1}"
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setblocking(False)
    try:
        s.connect((host, port))
    except BlockingIOError:
        pass
    except OSError as e:
        if e.errno not in (errno.EINPROGRESS,):
            s.close()
            continue
    socks.append(s)

opened = len(socks)
print(f"{opened} sockets in flight after {time.time()-t0:.2f}s", flush=True)

time.sleep(5)                      # hold them open; the burst is what bites

for s in socks:
    try: s.close()
    except Exception: pass

with open(marker, "a") as f:
    f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')}  SURVIVED  n={n} opened={opened}\n")
    f.flush(); os.fsync(f.fileno())
os.sync()

print(f"SURVIVED n={n} (opened {opened}). Marker updated.", flush=True)
PY
