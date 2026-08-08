# BCM4360 on this MacBook Air — history and current state

Why `mba-wifi.sh` is as defensive as it is, what has actually gone wrong, and
what is known versus assumed. Kept because the reasoning is not recoverable
from the scripts, and because a future session that does not know this history
tends to re-derive it wrongly.

## The hardware constraint

A BCM4360 `[14e4:43a0]` on Apple's proprietary connector. It cannot be swapped.
Its only working driver is `wl` from `broadcom-sta-dkms` — an open shim around
a binary blob Broadcom froze in 2015 (`wlc_hybrid.o_shipped`). `brcmfmac` does
not support this device ID.

**There is no Ethernet port.** A broken `wl` therefore means no network at all,
including no way to fetch the fix. That single fact is the reason for the
fallback kernels, the holds, the trial/revert structure, and `kernel-guard.sh`.
The only escape hatch that does not depend on `wl` is a USB adapter on an
in-tree driver (mt7921au / mt7612u) or USB tethering from a phone.

## What actually went wrong, 2026-07-21

**This is Joe's first-hand account and is authoritative. Do not re-derive it
from logs.** An apt upgrade to 7.0.0-28 failed the DKMS build for `wl`; the
upgrade completed anyway. On rebooting into 7.0 the machine hit a **kernel
panic — repeatably, on every boot with the driver enabled.** Disabling the
driver stopped the panic, and 7.0 then booted fine but with no wireless.

The journal preserves none of this: panics never flushed, and the only 7.0
boots it recorded were after the driver had already been purged. **The logs
therefore look misleadingly clean.** A previous session wasted time
relitigating this from logs and reached the wrong conclusion. Take the account
as given.

All 7.x kernels were then blocked via
`/etc/apt/preferences.d/block-kernel-7.pref` (Pin-Priority -1).

## The 7.x trial, 2026-07-29

`mba-wifi.sh trial-accept` ran after a supervised manual `modprobe wl` on
7.0.0-28 did not panic. The block was lifted, the machine rebooted, and `wl`
auto-loaded and associated on its own. State is recorded in
`/var/lib/mba-wifi/accept.state`; `trial-revert` from a 6.x kernel undoes all
of it.

The `objtool=/bin/true` workaround ([LP#2161038](https://bugs.launchpad.net/bugs/2161038))
was applied as part of that trial. It costs one boot-time warning —
`Unpatched return thunk in use` from `getvar` in `wl` — which is harmless on
this CPU, which reports retbleed and SRSO as "Not affected".

## Current state, 2026-08-08

- **No apt pin.** 7.x point releases arrive unattended via
  `linux-image-generic-hwe-24.04`.
- **The objtool bypass is scoped to 7.x**, not applied to every build. Verified
  by test build against `23ubuntu1.2`: 6.17 compiles clean *with* objtool; 7.0
  fails with `wl.o: error: objtool: aes_cbc_encrypt_pad+0x4c: unannotated
  intra-function call`. Earlier documentation warning that the bypass disables
  validation for the 6.x fallbacks is **obsolete**.
- **Ten 6.17.0-40/-41 packages held** as the fallback — 334MB. Booted and
  confirmed online 2026-08-08.
- **`broadcom-sta-dkms` is no longer held.** Its hold existed only to stop
  updates rebuilding the fallback modules through the bypass, which the scoping
  fixed. `29ubuntu1` reportedly fixes 7.x properly but is not in noble.
- **`kernel-guard.sh` installed**, so a kernel that lands without a `wl` module
  is reported before the reboot that would strand the machine.

## The distro fix is not the same bug

`broadcom-sta-dkms 6.30.223.271-23ubuntu1.2` (in `noble-updates/restricted`)
carries patches for kernels 6.15, 6.16 and 6.17 — LP#2120508. Those fix
*source-level* API breaks (`timer_delete`, `timer_container_of`,
`EXTRA_CFLAGS`). The 7.x failure is objtool rejecting the **precompiled blob**,
which no source patch reaches. Do not assume the distro update retires the
bypass.

## The lockup trigger — corroborated 2026-08-08

Earlier notes here called "too many requests at once" an uncorroborated
recollection. **It is corroborated.** The batocera-watch project recorded it in
`CLAUDE.md` as an architecture constraint at the time it happened:

> **Never fan out unbounded concurrent connections.** The dev machine's Broadcom
> `wl` driver hard-locks the whole laptop on connection bursts; a /24 sweep
> opening 254 sockets froze it. Cap batches at ~24.

Three details in that matter more than the confirmation itself:

- **The trigger is concurrent connection count, not throughput.** A /24 sweep is
  trivial traffic; what killed it was 254 sockets opening at once. Bulk transfers
  have never done this.
- **The symptom is a whole-machine hard lock**, not Wi-Fi dropping. That fits the
  panic history above and explains why the journal is useless afterwards — the
  machine never gets to flush anything.
- **A mitigation has been in place ever since:** batches capped at ~24. That is
  why the fault has not been seen lately.

### This confounds the power-save experiment

Power save was turned off on 2026-08-08 to see whether the flakiness recurs. It
almost certainly will not — but **not because power save was the cause**. The
known trigger is avoided by a cap that has been in the batocera code the whole
time. Absence of lockups therefore says nothing either way, and it would be
easy to wrongly credit the power-save change months from now.

To actually settle it, the trigger has to be applied deliberately: escalate
concurrent connection counts (24, 48, 96, 254) with power save off and see
whether it still locks. If it survives 254 with power save off and reliably dies
with it on, power save was the cause. If it dies either way, the cap is the only
real defence and belongs everywhere, not just in batocera-watch.

**That test hard-locks the machine when it works.** Nothing flushes to disk, so
run it with no unsaved work, expect an unclean shutdown, and remember this
machine has no Timeshift snapshots. Not something to do casually — but it is the
only way to convert a documented anecdote into a rule.

What the evidence shows as of 2026-08-08:

- **No `wl` errors in the kernel log at all** across the retained journal
  (2026-08-05 onward, 190MB) — only the module taint messages and the
  `wlan0 → wlp3s0` rename.
- **Interface counters clean**: 0 RX errors, 0 TX errors, 1 TX dropped across
  112MB transmitted in one session.
- **`Power save: on`** — the best-known cause of `wl` stalls and latency spikes
  on this chipset, and an obvious variable to control in any test.
- One boot (2026-08-07 21:24) ended at `PM: suspend entry (deep)` with **no
  resume logged** and a fresh boot 39 minutes later. That is consistent with a
  failed resume, which `wl` is a known cause of — but it is a single instance
  and equally consistent with a deliberate power-off while suspended. Not
  evidence of anything on its own.

Boots ending at `PM: hibernation: hibernation entry` are **normal** — the
machine powered off and the next start is legitimately a new boot. They are not
crash signatures, and an unclean-shutdown scan will wrongly flag them.

### Power save disabled as a test, 2026-08-08

**Read the confounder above before drawing any conclusion from this.** The real
trigger turned out to be documented — bursts of concurrent connections — and it
is already avoided by a cap in the batocera code, so "no lockups since" cannot
be credited to this change.

`Power save: on` was the leading suspect, so it was turned off to see whether
the flakiness recurs. Ubuntu ships `wifi.powersave = 3` in
`/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf`; that file is
package-managed and would be overwritten, so the override goes in a file that
sorts later:

```ini
# /etc/NetworkManager/conf.d/zz-wifi-powersave-off.conf
[connection]
wifi.powersave = 2
```

Confirmed after `systemctl restart NetworkManager`: `iw dev wlp3s0 get
power_save` reports `off`, connection reassociated on 5GHz with the same
address.

**This is a diagnostic, not a recommendation.** It increases idle draw by
roughly 0.1–0.5W against ~11W idle and about an hour of runtime — the opposite
direction from the power tuning deliberately declined elsewhere on this
machine. Revert by deleting that one file and restarting NetworkManager.

The result is only meaningful over time. If the lockups stop, power save was
the cause. If they recur with it off, the leading suspect is eliminated and the
next step is a real reproduction with out-of-band capture.

### If this is investigated

Prerequisites, learned from the panic history: the failure mode may be a hard
lock that flushes nothing to the journal, so a test that relies on post-mortem
logs can produce no evidence at all. Any real attempt needs out-of-band capture
(netconsole to another machine, or a synchronous log written with `fsync`), a
known-good fallback kernel to boot into, and a way back online that does not
depend on `wl`.

## Capturing a fault when it happens

`wifi-snapshot.sh` exists because the evidence has to be collected *during* the
fault — see the panic history above for why a post-mortem log read can come back
empty. Run it the moment Wi-Fi misbehaves and before rebooting; it writes a
timestamped capture to `~/wifi-snapshots/` and prints a verdict distinguishing a
wedged driver from an association failure from a problem above the driver.

The README documents the three false-answer traps found while building it: the
shared IRQ line that makes interrupt counts meaningless on this device, `iw dev
link` exiting 255 when unprivileged despite working, and single-ping-burst
verdicts that were not reproducible run to run.
