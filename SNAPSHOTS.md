# Rollback and snapshots — the decision, and what is still open

Written 2026-08-08, at the end of a long session. Joe asked whether Timeshift
could be pointed at iteration8 or the 7810 as a backup host, and clarified that
the goal is **rollback: undoing bad updates**, not file backup.

The short answer was *yes, technically* — and *no, don't*, for a reason specific
to this machine. `apt-rollback.sh` was built instead. Snapshots are **deferred,
not rejected**, and this file exists so the reasoning does not have to be
rebuilt from scratch.

## Why a remote snapshot target is wrong for rollback

Timeshift cannot write to a remote path directly. It takes a block device or a
local directory, so the network has to be made to look local first — NFS, SMB,
or iSCSI. All three work. That is not the problem.

**The problem is what a bad update looks like on this machine.** Wi-Fi is the
only network interface; there is no Ethernet port. Wi-Fi depends on `wl` from
broadcom-sta, a proprietary DKMS module that has already failed a kernel
transition once (see `WIFI.md`). So the most likely bad update is one that costs
you the network — and a snapshot stored on iteration8 is unreachable at exactly
that moment.

The usual escape hatch does not help either: booting a live USB to restore over
NFS needs that same Broadcom driver working in the live session.

**For rollback, the snapshot has to be local.** Remote storage is right for
*disaster recovery* — the disk dies, the laptop is stolen — which is a different
job with different tools.

The 7810 is worse than iteration8 regardless: its ssh alias is `win7810`
(10.0.0.79), i.e. it appears to be a Windows host, which means SMB/CIFS, which
does not support the **hardlinks** Timeshift's rsync mode relies on. Every
snapshot would be a full copy instead of an incremental. Verify that assumption
before acting on it, but if it holds, that host is disqualified for this.

## The numbers, measured

    /usr    16G          /home   27G
    /var    3.7G         free    54G of 111G
    /opt    918M         → system side ≈ 21G
    /boot   336M
    /etc     19M

- **First snapshot ≈ 21G**, about 39% of free space.
- **Each snapshot after that: 0.5–2G**, because rsync mode hardlinks unchanged
  files. A kernel update is ~400M of delta; a large apt upgrade 1–3G.
- **Three snapshots ≈ 23–25G total**, leaving ~30G. Not 3 × 21G — a common
  misreading, and the one Joe asked about directly.
- Excluding `/var/lib/flatpak` (1.8G — flatpaks reinstall trivially) brings the
  first snapshot to roughly 19G.

Timeshift itself is **still installed** (25.12.4) with its config at
`/etc/timeshift/`. Snapshots were deleted and schedules disabled earlier, as a
deliberate choice on a 4GB machine — see the `macbookair-optimization` memory.
Re-enabling is a config change, not an install.

## What was built instead

`apt-rollback.sh` — see the README section for detail. It reads
`/var/log/apt/history.log` (76 transactions back to late July, including rotated
logs), shows what each one changed, and generates the command that reverses it.
Costs nothing, reverts exactly what changed, needs no network.

Two considerations made this the better first move:

- **Kernels, the genuinely dangerous update class here, are already covered
  better than snapshots would cover them** — held 6.17 fallbacks, the GRUB menu,
  and `kernel-guard.sh` warning before a reboot that would strand the machine.
- **Package breakage is precisely revertible** from apt's own records, without
  rolling the whole system back.

## What is still uncovered

`apt-rollback.sh` only sees packaged files. It cannot help with:

- config files edited by hand, or diverged from package defaults
- anything written outside dpkg — manual installs, scripts, `/usr/local`
- whatever a postinst did to the system
- **"something broke and I do not know what changed"** — the case snapshots are
  genuinely good at

That gap is real. It is simply not worth 21G *yet*.

## If you revisit this

Recommended shape, in order:

1. **Local Timeshift, system-only, on-demand.** Exclude `/home` (default) and
   `/var/lib/flatpak`. Create a snapshot manually before risky changes rather
   than on a schedule — no background service, no scheduled disk churn on a 4GB
   machine, and the snapshot exists exactly when you meant it to.
2. **Keep 2–3 snapshots**, not more. The value is in "last known good", not
   history.
3. **Then, optionally, rsync the snapshot tree to iteration8** over the tailnet
   as an offsite copy. Local for rollback, remote for disk death. Do not invert
   this.

Do **not** set Timeshift's target to NFS from iteration8 and call it done. That
is the configuration that fails in the one scenario it was installed for.

## Where this was left

- `apt-rollback.sh` written, tested against real transactions, committed and
  pushed (`e3396c5`). apt accepts its generated downgrade commands.
- No snapshots taken. No Timeshift config changed. 54G still free.
- Nothing on iteration8 was set up for backups. The kernel workshop there
  (`/srv/kernel-workshop`, see `workshop/README.md`) is unrelated to this.

### Other threads open at the same time

| thread | state |
| --- | --- |
| Jenni's MacBookAir6,1 | four pending items in `~/jenni-camera-todo.md`; her machine is also the last thing gating the upstream applesmc patch |
| applesmc upstream patch | drafted and fully tested, `patches/upstream-applesmc-nand-disk.md`, not sent |
| Wi-Fi lockups | trigger corroborated (connection bursts, ~254 sockets); the power-save experiment is confounded — see `WIFI.md` |
| Xorg crash | recurring `.crash` report; needs `/var/crash` cleared and a reboot before anyone can tell whether it repeats |
