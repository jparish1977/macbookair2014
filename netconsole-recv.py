#!/usr/bin/env python3
"""netconsole-recv -- receive kernel messages from a machine that is about to die.

WHY NOT `nc -u -l`
    The most valuable datum in this capture is WHEN THE MESSAGES STOPPED. A raw
    byte dump cannot tell you that: it ends, and the end has no timestamp. This
    stamps every datagram on arrival and flushes immediately, so the last line's
    clock IS the moment of death, to within the network delay.

    Flushing matters for the same reason. A buffered writer loses the final
    seconds -- exactly the seconds worth having -- if this process is killed or
    the box it runs on is rebooted.

WHY THIS EXISTS AT ALL
    A hard lock flushes nothing to disk, so the journal on the dying machine is
    useless afterwards. pstore survives a PANIC and captures the crash dump, but
    it does not capture the RUN-UP. Netconsole streams printk off-box in real
    time, so the two are complements rather than alternatives:

        netconsole   the seconds BEFORE      (lost to pstore)
        pstore       the panic itself        (lost to netconsole, if the CPU
                                              stops before it can transmit)

    Note the honest limit, established the hard way: ON A TRUE HARD LOCK THE CPU
    IS STUCK AND NOTHING TRANSMITS, over any interface. USB tether, wifi, it
    makes no difference -- the packets stop because the kernel stopped, not
    because the link did. So netconsole does not capture the lock. It captures
    everything up to it, and the timestamp of the last line.

USAGE
    ./netconsole-recv.py [port] [logfile]        default 6666, ~/.cache/netconsole/

    Sender side, on the dying machine:
        modprobe netconsole \\
          netconsole=6665@<SRC_IP>/<SRC_IF>,6666@<DEST_IP>/<DEST_MAC>
"""
import os
import socket
import sys
import time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 6666
if len(sys.argv) > 2:
    path = sys.argv[2]
else:
    d = os.path.expanduser("~/.cache/netconsole")
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, time.strftime("air-%Y%m%d-%H%M%S.log"))

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", port))

print(f"listening udp/{port} -> {path}", flush=True)
last = None
with open(path, "a", buffering=1) as f:
    f.write(f"# netconsole-recv started {time.strftime('%Y-%m-%dT%H:%M:%S')}\n")
    while True:
        data, addr = s.recvfrom(9216)
        now = time.time()
        stamp = time.strftime("%H:%M:%S", time.localtime(now)) + f".{int(now%1*1000):03d}"

        # A GAP is itself evidence -- it is how you see the machine struggling
        # before it stops. Mark anything over a second so it cannot be missed
        # when reading back a few thousand lines at 3am.
        if last is not None and now - last > 1.0:
            f.write(f"--- GAP {now - last:.1f}s ---\n")

        f.write(f"{stamp} {addr[0]} {data.decode('utf-8', 'replace').rstrip()}\n")
        last = now
