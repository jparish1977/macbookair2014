# Rollback and snapshots — the decision, and what is still open

Written 2026-08-08. Joe asked whether Timeshift could be pointed at iteration8 or
the 7810 as a backup host, and clarified that the goal is **rollback: undoing bad
updates**, not file backup.

The short answer was *yes, technically* — and *no, don't*, for a reason specific
to this machine. `apt-rollback.sh` was built first, for the case where you know
which update broke things.

**Updated later the same day:** the deferred half is no longer deferred.
`system-snapshot.sh` implements the local, system-only, on-demand shape
recommended at the bottom of this file, and encodes the reasoning above it as
refusals — it will not write a snapshot to a network target, and it says why. The
two tools cover different cases and neither replaces the other:

| you know which update broke it | you do not |
| --- | --- |
| `apt-rollback.sh` — reverts exactly those packages, costs nothing | `system-snapshot.sh` — roll the system side back to a known-good point |

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
snapshot would be a full copy instead of an incremental. That claim about *that
host* is still unverified — but it no longer needs to be, because
`system-snapshot.sh` now refuses any target whose filesystem cannot hardlink,
whatever host it is on. The general rule got encoded instead of the specific fact
getting checked.

There is one more way to get this wrong that the original reasoning missed.
Timeshift's config takes a **UUID**, so the obvious mental model is "a UUID means
a local disk". It does not: iSCSI and NBD hand you a `/dev` node with a real UUID
that passes every locality test and still vanishes the moment Wi-Fi does.
`system-snapshot.sh` checks the device's *transport*, not just that it is a block
device.

## The numbers, measured

    /usr      15.3G        /home        26.7G
    /var       3.7G        /swapfile     3.9G  (excluded — see below)
    /opt        0.9G       free         53.5G of 111G
    /boot       0.3G
    /etc       0.02G

- **First snapshot = 18G**, and this is now the real thing rather than an
  estimate: 741,884 files, 53.5G free before, 36G after. The pre-flight estimate
  said 18.2G, so it was accurate to about 1%.
- **Each snapshot after that: 0.5–2G**, because rsync mode hardlinks unchanged
  files. A kernel update is ~400M of delta; a large apt upgrade 1–3G.
- **Three snapshots ≈ 20–22G total**, leaving ~32G. Not 3 × 18G — a common
  misreading, and the one Joe asked about directly.

The first estimate written here was ~21G, and a naive `du -sx /` says 22.3G. Both
are wrong in the same place: **`/swapfile` is 3.9G** of the root filesystem.
It is *not* dead space — it is active swap at priority -1, sitting behind zram0
at priority 100 as the overflow path, and it is in `/etc/fstab`. Leave it alone.
But Timeshift excludes it (`strings /usr/bin/timeshift | grep swapfile` confirms
it is on the built-in list), so counting it inflates the snapshot estimate by
nearly 4G and could talk you out of a snapshot that fits comfortably.
`system-snapshot.sh` mirrors Timeshift's built-in exclusions when it measures,
which is how 22.3G becomes the correct 18.0G.

Timeshift itself was **already installed** (25.12.4) and its config at
`/etc/timeshift/` was already most of the way to the right shape: rsync mode,
target `/dev/sda2`, every schedule off, `/home/joe` and `/root` excluded (that
per-user pattern was later generalised to `/home/*/**` — see below).
Snapshots were deleted and schedules disabled earlier, as a deliberate choice on
a 4GB machine — see the `macbookair-optimization` memory. So this was a config
change, not an install: what was actually missing was the flatpak exclusion and
a snapshot.

## What was built first

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

## The gap that made snapshots worth doing anyway

`apt-rollback.sh` only sees packaged files. It cannot help with:

- config files edited by hand, or diverged from package defaults
- anything written outside dpkg — manual installs, scripts, `/usr/local`
- whatever a postinst did to the system
- **"something broke and I do not know what changed"** — the case snapshots are
  genuinely good at

That gap is real, and 18.0G against 53.5G free turned out to be a fair price for
closing it. What is still *not* covered, deliberately:

- **`/home` is not in these snapshots at all** (26.7G, and it would dominate
  them). Your files are never at risk from a restore — but neither are they
  recoverable from one. That is a backup job, not a rollback job.
- **Disk death.** The snapshots live on `/dev/sda2`, the same disk as `/`. A dead
  sda takes both. `system-snapshot.sh status` says so every time it runs rather
  than leaving it in this file.

## The shape, as implemented

All three steps below are done. Step 3 (the offsite copy) was implemented and
verified on 2026-08-08/09, and the full recovery path rehearsed in a VM.

1. **Local Timeshift, system-only, on demand.** Excludes `/home/*/`, `/root` and
   `/var/lib/flatpak`. The home pattern is a wildcard rather than one named user:
   a config naming `joe` silently includes every other account's home in the
   snapshot, and this repo is not written for a single-user machine.
   `configure` migrates an older per-user config and drops the stale entry.
   Snapshots are taken manually before risky changes rather
   than on a schedule — no background service, no scheduled disk churn on a 4GB
   machine, and the snapshot exists exactly when you meant it to.
   `system-snapshot.sh configure` enforces this and re-disables every schedule;
   `status` complains if something turns them back on.
2. **Keep 2–3 snapshots**, not more — `system-snapshot.sh prune` defaults to 3.
   The value is in "last known good", not history. Note that on-demand (`O`)
   snapshots are never auto-pruned by Timeshift, so this is a manual step by
   design.

   **But prune by count is the wrong tool once you have a deliberate baseline.**
   After the restore and bounce tests there were four snapshots: the three newest
   were disposable test artifacts and the only pristine one was the *oldest*, so
   `prune 1` would have deleted the one worth keeping. `prune` now refuses to
   delete any snapshot carrying a comment — a comment means somebody labelled it
   on purpose, which age cannot see — and points at `delete NAME`, which removes
   one snapshot without disturbing the rest. `--force` restores the old
   behaviour, and unlabelled snapshots still prune normally.
3. **Rsync the snapshot tree to iteration8** over the tailnet as an offsite copy.
   Local for rollback, remote for disk death. Do not invert this. **Implemented
   as `snapshot-offsite.sh`** — deliberately a separate script, because merging
   it with `system-snapshot.sh` is exactly the confusion this file exists to
   prevent. Target `/srv/mba-snapshots` on iteration8: `/home` there is 92% full
   while `/` has 1.6T free, and `/srv` is already where the kernel workshop
   lives.

   Three flags carry it, and each one wrong gives a copy that looks complete and
   does not restore: `-H` (snapshots are hardlink trees — without it two
   snapshots ship as ~37G rather than ~18.5G; note it does **not** disable
   incremental recursion, so the transfer's percentage legitimately goes
   backwards as rsync discovers more of the tree), `--fake-super` (an unprivileged
   remote account stores real ownership and mode in a `user.rsync.%stat` xattr,
   chosen over `--rsync-path="sudo rsync"` so it survives a change to the
   remote's sudo policy), and `--partial-dir` (a 75-minute transfer over Wi-Fi
   *will* be interrupted).

   **Done 2026-08-08.** 1,483,788 files in 79m11s at ~3.8 MB/s over Wi-Fi,
   occupying **20.03G** remotely against 38.69G apparent — `-H` saved 18.66G,
   very nearly half, and that saving grows with every snapshot kept. `verify`
   passed all three checks: every local snapshot present, no content differences
   on a full dry-run comparison, and the `user.rsync.%stat` xattr confirmed on
   `/etc/shadow` inside the remote copy.

   **The full disaster path is rehearsed and works (2026-08-09).** From nothing
   but the offsite copy, in a VM on iteration8: 499,328 files pulled and decoded,
   Timeshift restored onto a blank virtual disk, GRUB installed to a fresh ESP,
   and it booted UEFI to the LightDM greeter as `joe-MacBookAir`. See
   `vm-restore-test.sh` and the README for the two findings that came out of it —
   **a restored clone fights the original for its tailnet identity**, and
   **Timeshift maps mount points from the snapshot's own fstab**, aborting with
   an empty table and no error on a disk whose UUIDs do not match.

   The trap is on the way back: **pulling the tree home also needs
   `--fake-super`, named on the remote side.** Omit it and rsync cheerfully
   hands you a tree owned by your own user with every mode wrong, which looks
   like it worked. `snapshot-offsite.sh restore-help` spells out the procedure.

   **The pull is tested too, 2026-08-09: 7 of 7 probes correct, all 7 wrong in
   the control.** `pull-test` copies seven probe files rather than 20G and grades
   them against the local snapshot. Without `--fake-super` everything comes back
   owned `1000:1000` with **both setuid bits gone** — a recovered system that
   boots and cannot escalate. The control is what makes the pass evidence rather
   than an assumption.

   One thing that surfaced there: **the offsite copy is an encoded archive, not a
   browsable filesystem.** rsync stores symlinks, devices and special files as
   ordinary placeholder files, recording the real type in the xattr's mode field
   (`120777`, where `0120000` is `S_IFLNK`); `/usr/bin/X11` is a 1-byte file
   containing `.` over there. So `cp`, `tar`, `scp` or an rsync without the flag
   will copy that tree into something broken that looks fine.

Do **not** set Timeshift's target to NFS from iteration8 and call it done. That
is the configuration that fails in the one scenario it was installed for — and
the script will now refuse it outright rather than let it look configured.

## Restoring, which has now been tested

A snapshot you cannot restore is 18G of decoration. **It was tested on
2026-08-08 and it works: 6 of 6 checks passed.** `restore-test.sh` plants
markers, you snapshot, `break` them, restore, reboot, then `verify` grades the
result. The run: markers planted 21:01, baseline snapshot `2026-08-08_21-01-42`,
restore 21:06, reboot 21:08, verified clean.

| check | result |
| --- | --- |
| unchanged file (the control) | PASS |
| modified file reverted | PASS |
| deleted file put back | PASS |
| added file removed | PASS |
| `/etc/restore-test.conf` reverted | PASS |
| package `hello` removed | PASS |

**The control is the point.** A restore that did nothing at all would pass every
check except that one — "the file I did not touch is untouched" is only evidence
when the other five moved.

Two design choices in the test that are worth reusing:

- **The manifest lives in `$HOME`,** which is outside the snapshot. Put your
  evidence on the system side and the restore reverts the thing you were about to
  grade the restore against.
- **Restore the baseline taken *after* `arm`,** not an older snapshot. An older
  one has no markers, so the restore deletes them as unknown files and every
  check fails for the wrong reason.

Belt and braces beforehand: 4.42 GB of `$HOME` (10,844 files) was rsynced to
`iteration8:~/backups/mba-home/` and checksum-spot-checked first. Being wrong
would have cost time, not data. Do that again before the next one.

### What the restore actually did

The restore writes its own itemized rsync log inside the snapshot
(`rsync-log-restore`) — a complete audit trail, and the only evidence of what
happened rather than what was claimed. It was **93 lines**: 11 deletions, 24
files written, 54 directory timestamps. Every one accounted for. Under `/etc`,
exactly one file changed. Nothing under `/boot`, `/home` or `/root` appeared at
all. One collateral deletion, `var/tmp/flatpak-cache-*/repo-*-lock`, a stale lock
created after the snapshot.

`/home` exclusion held in practice, with three overlapping patterns in the
generated restore exclude list: the configured `/home/*/**`, plus `/home/*/**`
and `/root/**` that Timeshift appends itself.

### The machine-specific traps

- **It boots EFI** (`/dev/sda1`, vfat, `/boot/efi`). Timeshift will offer to
  reinstall GRUB, which you do not want on EFI unless GRUB is the broken thing.
  Use `--skip-grub`.
- **`--skip-grub` does not keep the restore out of the ESP.** This was not
  obvious and took reading the log to establish. The restore is `rsync -avir
  --force --delete --delete-before` with **no `-x`**, and `/boot/efi` is in
  neither exclude list, so the rsync crosses the filesystem boundary into the
  vfat ESP and `--delete` applies there. `--skip-grub` only suppresses
  `grub-install`.

  Measured, this is **sound rather than alarming**: the snapshot's ESP copy was
  complete and byte-identical to the live one (8 files, 6,394,698 bytes), so the
  restore was a same-for-same rewrite. Reverting `grubx64.efi` alongside
  `/boot/grub` is also the *consistent* outcome — an EFI binary that does not
  match its modules is a classic no-boot. The cases worth checking first are a
  snapshot older than a `grub-efi`/`shim-signed` update, or a firmware capsule
  staged in the ESP by fwupd that `--delete` would silently discard.
  `system-snapshot.sh check-esp` reports exactly that, and the whole ESP is 6.1 MB
  of a 511 MB partition, so backing it up first costs nothing.
- **A restore rewinds logs generally, not just one.** `/var/log/wtmp` comes back
  with everything else, so after a restore `last reboot` shows a truncated boot
  history — on 2026-08-09 it began at the restore itself, erasing the record of
  the boots before it. Harmless, but disconcerting if you are using boot history
  to date something, and it is the same mechanism as the apt case below.
- **A restore rewinds apt's own history.** `/var/log/apt/history.log` is inside
  the snapshot, so after a restore `apt-rollback.sh` cannot see anything that
  happened after it was taken — including the transaction you just undid. The
  test's `hello` install left no trace: `grep -c hello` returns 0. **The two
  rollback tools compose in one direction only.** Copy `history.log` to `$HOME`
  first if the precise apt-level record matters. This was masked here because a
  forced logrotate at 19:30 had already emptied `history.log`, so the snapshot's
  copy was empty too and `apt-rollback.sh` still reads back through the rotated
  `.gz` files — but that was luck, not design.
- **Wi-Fi is the only interface and needs `wl` from broadcom-sta.** Restore to a
  state whose DKMS module does not match the kernel you then boot and you come
  back with no network — the same trap `kernel-guard.sh` exists for. Check it
  before rebooting, and keep the 6.17 fallbacks held. The test came back on
  `7.0.0-28-generic` with `wl` loaded and Wi-Fi up, and the udev keyboard-backlight
  rule and the kernel-guard apt hook both survived.
- **A restore is not checksum-verified.** Timeshift restores with `rsync -avir
  --force --delete` and **no `--checksum`**, so rsync's quick check applies: a
  file is skipped when its size matches *and* its mtime matches to the second.
  A file rewritten in the same second it was snapshotted, at the same size,
  is silently not restored. In normal use the window is tiny — a snapshot you
  restore is hours or days old — but it means a restore is a fast reconstruction,
  not a guaranteed byte-for-byte one. This was found the hard way: the bounce
  test's first markers were both 8 bytes and written milliseconds apart, and the
  restore skipped them, reporting a failure that had not happened. The markers
  now differ in length so the quick check cannot fire.

## A restored system is a second copy of your machine's identity

The single most important thing learned from rehearsing recovery, and it is not
about snapshots at all — it is about what a snapshot *contains*.

Machine identity lives on the system side, so it is inside every snapshot:

    /var/lib/tailscale/tailscaled.state    the tailnet NODE KEY
    /etc/machine-id, /var/lib/dbus/machine-id
    /etc/ssh/ssh_host_*_key

Boot a restored copy with a route to the internet and its `tailscaled` registers
under **the same node key as the machine it was cloned from**. The coordination
server treats them as one node and follows whoever reported last, so **the
original drops off its own tailnet.** On 2026-08-09 that happened twice, and both
times it presented as *the remote host having died* — ssh timeouts, `tailscale
ping` no reply even via DERP, other peers failing too — while iteration8 was up
the entire time (`up 3 days, 21:06`). Killing the clone restored the laptop
immediately, with no tailscale restart. That intervention is the proof.

In a real recovery this never arises: the original is dead, which is why you are
restoring. It is purely a **rehearsal** hazard, and it is why
`vm-restore-test.sh bootdisk` runs restored systems with `-netdev
user,restrict=on` — a working NIC and DHCP lease, but no route off the host.

The same shape appears one layer down with filesystem UUIDs (see `disk-plan`):
**duplicated identity is safe only when the original is gone.**

## Bouncing between restore points

Restore points are **not one-way**, and a restore does not consume the ones newer
than it. **Tested on 2026-08-08: 14 of 14 checks across both hops.** The enabling
detail is that `/timeshift/*` is in the exclude list, so a restore never touches
the snapshot store: the restore log shows `timeshift/` exactly once, as
`.d..t......`, a directory timestamp with no recursion into it.

    A  2026-08-08_21-48-22   741,915 files   state.txt 8 bytes,  hello absent
    B  2026-08-08_21-49-38   741,927 files   state.txt 49 bytes, hello installed

    B -> A  (backwards, rolling past B)   7/7
    A -> B  (forwards, into the rolled-past snapshot)   7/7

What the backward hop showed is that `--delete` genuinely removes: `only-in-b.txt`
disappeared from the live system and `hello` was uninstalled, while snapshot B
kept its own `only-in-b.txt`, its 49-byte `state.txt`, its `file_count` of 741,927
and its comment — rolling past it changed nothing about it. All four snapshots on
disk survived both hops.

The forward hop is the stronger test of the two, because `hello` had to be
reconstructed from a snapshot the system had already moved past: afterwards
`dpkg -V hello` reported no checksum discrepancies, all 15 paths in `dpkg -L`
were present, and the binary ran. **The package database and the filesystem
agree** — a restore does not leave dpkg believing something the disk contradicts.
Combined with rsync-mode snapshots each being a *complete* hardlinked tree rather
than a diff against a parent, any snapshot restores independently of the others,
in any order, as often as you like.

`restore-test.sh bounce-arm` proves it rather than asserting it. It builds two
full states, snapshots each, and leaves you on B; you restore A, reboot,
`bounce-verify A`, restore B, reboot, `bounce-verify B`. Each state holds a file
the other lacks, so **every hop must both create and delete** — a restore that
only ever added files back would pass a one-way test and fail this one. The last
two checks are the real point: that the snapshot you rolled *past* still exists,
and that its contents still checksum correctly, because that is the only thing
that makes the way back real.

**Yes, snapshot before restoring.** For a bounce it is not optional — the forward
destination has to exist on disk before you hop backwards. In general it is your
undo-the-undo: the restore overwrites the state you are leaving, and without a
snapshot that state is gone. It costs ~300–450M and about a minute. Two
exceptions: not when you are restoring *because* the disk is full, and not worth
it if the disk itself is failing.

Three things bite when bouncing, none of them Timeshift's fault:

- **`/home` never moves.** The system side hops; your home directory does not.
  Roll back a month and `~/.config` is still today's. That is the usual reason a
  bounce feels broken when nothing has actually failed.
- **Anything created and never snapshotted dies on the first backward hop.**
  `--delete` removes system-side files absent from the target. Going forward
  restores whatever the forward snapshot holds — but a file that lived only in
  the running system, in no snapshot at all, is gone at the first hop.
- **Every hop rewinds `/var/log/apt/history.log`,** so `apt-rollback.sh`'s view of
  history changes under you each time.

## The rehearsal, automated

The 2026-08-09 rehearsal proved the disaster path works, but it was six manual
steps driven by hand over a serial console — fine once, useless as something to
re-run whenever a snapshot changes. `vm-restore-test.sh restore` now runs the
whole thing unattended and ends in **`golden.qcow2`**, a frozen image of the
restored machine. `steps` is kept as the by-hand version and the explanation of
*why* each step is shaped the way it is.

    ./vm-restore-test.sh restore [SNAP]      # defaults to the newest snapshot

It reads the ORIGINAL root UUID and ESP volume id out of the snapshot's own
fstab, builds the disk to match, pulls the tree, seeds Timeshift's config, drives
the restore prompts with `expect`, verifies the result and freezes the image.
Three decisions in it are worth keeping:

- **The work is detached inside the guest and the host only polls.** The serial
  helper drains for a fixed number of seconds per exchange — it has no idea what
  a shell prompt looks like and cannot wait for one. So the driver runs under
  `setsid`, writes one line to `/tmp/g.status` and its full transcript to
  `/tmp/g.log`. The serial link carries status, never the work. A step shorter
  than the 20s poll interval never gets printed; `sh 'cat /tmp/g.log'` has
  everything.
- **It pulls one snapshot, not the whole module.** The carrier is 30G and the
  offsite copy is ~20G of *hardlinked* snapshots with a 38G apparent size, which
  a pull expands. The module would not fit. One snapshot is a complete tree on
  its own, and pulling it straight into `timeshift/snapshots/` removes the `mv`
  the manual procedure needs.
- **It matches UUIDs rather than answering the prompts.** Both work by hand;
  only matching works unattended. What makes this dangerous on real hardware —
  two filesystems sharing a UUID — cannot arise against a qcow2 that never
  coexists with the laptop.

It refuses rather than guesses if the snapshot's fstab mounts anything beyond
`/`, `/boot/efi` and the swapfile: it builds a two-partition disk, and restoring
a system whose fstab names a filesystem that was never created would boot to an
emergency shell and read as a restore bug.

`clean` deliberately keeps `golden.qcow2`. It costs an hour to make and is what
anything downstream boots from; deleting it there would make `clean` mean two
different things depending on what had been run.

### `testbase` — an image that can be asked questions

A restored system booted from disk is **silent on the serial port**: its
`grub.cfg` came from a laptop that boots to a screen. `screenshot` is fine for a
human and useless as a verdict. `testbase` puts a serial console and autologin
into a qcow2 **overlay** on `golden.qcow2`, leaving golden faithful — its one job
is to be exactly what the snapshot restores to, and editing it destroys that.

    golden.qcow2       faithful restore, untouched
      └─ testbase.qcow2     + console, + autologin   (2.7M over a 19G base)
           └─ candidate overlays, per kernel test

Every divergence is one file, `/etc/default/grub.d/99-vmtest.cfg`, and it boots
verbose — `quiet splash` dropped, because a failed boot that prints nothing is
the outcome the rig exists to diagnose. Two traps, both silent:

- **`/etc/default/grub` is not the last word on Mint.** `grub-mkconfig` sources
  `/etc/default/grub.d/*.cfg` afterwards and Mint's `50_linuxmint.cfg` sets
  `GRUB_DISABLE_OS_PROBER=false`. It was set in the main file, correctly, twice,
  and os-prober ran anyway. Anything that must win goes in a `99-` fragment.
- **`update-grub` in a chroot probes the build host's disks.** With `/dev`
  bind-mounted it found `Ubuntu 24.04.4 LTS on /dev/sdc4` — iteration8's own root
  — and wrote boot entries for it into the image. `testbase` now checks this
  without naming any host-specific device: every UUID `grub.cfg` searches for
  must belong to the image.

**What a healthy image answers**, which matters because two of these read as
failures and are not:

| check | healthy | why |
| --- | --- | --- |
| `lsmod \| grep wl` | **0** | nothing autoloads `wl` with no BCM4360 present. A test must modprobe explicitly or it fails forever |
| `modprobe wl` | loads, pulls `cfg80211` | the module links against *this* kernel — stronger than "DKMS exited 0", short of "Wi-Fi works" |
| `systemctl --failed` | **0** | `testbase` supplies the swapfile Timeshift excludes, so anything failed at all is real signal |
| `swapon --show` | `/swapfile` -1, `/dev/zram0` 100 | both return, priorities intact |

`testbase` creates the 3960M `/swapfile` because Timeshift excludes it, so a
restored system has the fstab entry and not the file and `swapfile.swap` fails
forever. A **zero** baseline cannot rot the way "exactly one, and it must be that
one" does. `golden.qcow2` still fails it deliberately — that failure is honest
evidence the snapshots are system-only. `fallocate` sufficed, so the overlay
stayed 4.0M; a qcow2 grows only on real writes. **zram needed nothing**: it comes
back with the restore at priority 100 ahead of the disk swapfile, being
system-side config with no hardware to be missing — so the guest inherits the
laptop's real two-tier swap rather than an approximation.

### `verify` — checking that everything this repo installs still works

`testbase` plants the repo at `/opt/mba-verify` and `verify` runs the helpers'
**own** `check`/`status` subcommands rather than reimplementing them, because a
second implementation drifts from the first and starts grading the wrong thing.
The checks run *in the guest* — a dozen serial round trips cost minutes, and a
remotely-driven check can only grade one line of output. **21 checks, all passing
on a healthy image**, across three tiers: artefact (survived the restore),
mechanism (builds, loads, the rule acts), device (needs metal, not attempted).

Three things worth carrying:

- **`applesmc` must be graded differently.** It *refuses* to load without an
  Apple SMC (`No such device`), where `wl` and `facetimehd` load happily and bind
  nothing. The honest check is that the kernel ships it. Grading it like the
  others gives a permanent false failure on the one driver whose bug was already
  chased once.
- **The keyboard-backlight fix is testable without an SMC.** `uleds` makes a
  synthetic LED named exactly what `applesmc` would register, and `udevadm test`
  shows the rule matching it and writing `trigger=none`. It is the `udevadm test`
  output that is the evidence — a fresh `uleds` LED defaults to `none`, so
  reading the attribute back would pass with the rule deleted.
- **Audio is the one area with a usable stand-in.** Wi-Fi and the camera can only
  be *built* in a VM; audio can be exercised, because `bootdisk` gives the guest
  an emulated `ich9-intel-hda`. Six checks: card, driver bound, playback,
  capture, **PCM actually opened and written**, and userspace present. The
  pcm-open one is what matters — enumeration proves a node exists, opening and
  writing proves the path works. Not testable: the Cirrus CS4208's own quirks
  (jack detection, routing, `model=` options), since QEMU's codec is generic; and
  PipeWire, a per-user service with no session behind a serial root login.
  `MBA_VMTEST_NO_AUDIO=1` removes the card and turns exactly the five hardware
  checks red, which is what makes them evidence.
- **`verify-control` proves the checks can fail.** Same discipline as
  `restore-test`'s unchanged control and `pull-test`'s all-7-wrong control: break
  three artefacts in a throwaway overlay, and **exactly 5 checks go red while 9
  stay green**. Five rather than three because the rule and helper checks catch
  it through *behaviour*, not by re-reading the file the artefact check read.

Two more "passes for the wrong reason" bugs came out of it: **`bootdisk`
reported success on a VM that never started** (it waited for the QEMU monitor
socket, which QEMU creates *before* opening the drives — a root-owned image gave
a socket and a dead process), and **a failure message that read like a pass**
(dumping 90 characters of helper output put `trigger none` in the failure line;
it now reports `trigger-is-none=yes rule-installed=no`).

### `update-test` — running the update here before the laptop sees it

It runs the **real** upgrade in a chroot from the live phase (network, no
identity) and then boots the result under `restrict=on` and re-runs `verify`.
The upgrade lands in `candidate.qcow2`, an overlay, so the baseline never moves
and the same update can be tested repeatedly from where the laptop actually is.
**Proven on `6.17.0-42`: 10 packages, both DKMS modules built, one-shot boot into
it, 15/15 about that kernel.**

Findings worth carrying, most of them the tool lying:

- **The kernel holds are the procedure, not a fault.** `mba-wifi.sh` holds kernel
  packages to keep a known-good fallback installed, so `update-test` correctly
  found nothing to do. `--unhold` lifts them in the candidate overlay only. On
  the laptop, lift only the meta-packages — the specific `linux-image-6.17.0-4x`
  holds *are* the fallback.
- **A no-op upgrade produced a green verdict.** An untouched image passes every
  check. It now reports `CHANGED: no` and refuses to grade.
- **Phased updates are keyed on machine-id, which a clone inherits** — so the VM
  declines an update for the same reason the laptop does, making a clone-based
  rig as blind as the machine it protects. This is the tailnet-identity problem
  one layer down. Forced in with `APT::Get::Always-Include-Phased-Updates`.
- **GRUB boots the newest kernel, which is usually not the candidate.** A 6.17
  update sits below the 7.0 kernel, so the first working run re-graded
  `7.0.0-28`. It now arms a one-shot via `kernel-guard boot-test` and then
  **checks armed-against-booted** — assuming the one-shot took is how you get a
  confident verdict about the wrong kernel.
- **The apt hook cannot be tested by its output.** `--quiet-ok` means silence on
  success, so grepping for it reports "never fired" every time. Its *guard* is
  what matters: wrapped in `[ -x /usr/local/bin/kernel-guard ]`, so a missing
  binary makes it do nothing for ever, silently, indistinguishable from approval.

Mechanically: `umount` needs `-R` or a leftover submount makes the parent "busy"
with **no process holding it** (`fuser` shows only `kernel mount`), and the rsync
daemon must be started immediately before the guest fetches, not before a 90s
boot — a long window is one something else can close.

### Three bugs it took a real run to find

None of these would have shown up in a dry run, and two of them fail *silently*:

- **`apt-get update` exits non-zero in the live session** because its
  `sources.list` carries a `cdrom:` entry for the ISO, which has no Release file
  when the VM boots via `-kernel`/`-initrd` rather than letting casper mount the
  disc. Every network list fetches perfectly well. Drop the entry and gate on the
  *install* instead — that fails plainly if the lists never arrived.
- **Bash emits its bracketed-paste escape on the same line as the output.**
  `cat /tmp/g.status` comes back as `ESC[?2004lDONE:rc=10`, so a pattern anchored
  with `^` never matches. The first run polled to its full timeout against a
  guest that had already failed and was sitting there saying so. Strip
  `ESC[…[a-zA-Z]` alongside the `\r`s before grepping anything off a serial line.
- **A marker echoed back by the serial console matches before the command runs.**
  `guest "rsync … && echo PULLED" | grep PULLED` passes whether or not the rsync
  worked, because the link echoes the command text first. Spell the marker
  `echo P''ULLED` so only the shell's own output matches.

A fourth, from driving it rather than from the script: **`pkill -f "…restore"`
killed the ssh session issuing it**, because the pattern was in its own command
line. `vm-restore-test.sh` already warns about exactly this for `pgrep`; use a
character class (`rest[o]re`) so the pattern cannot match itself.

## Where this was left

- `apt-rollback.sh` written, tested against real transactions, committed and
  pushed (`e3396c5`). apt accepts its generated downgrade commands.
- `system-snapshot.sh` written. Every check and every refusal path was exercised
  — vfat target, absent UUID, detached UUID, missing `/home` exclusion, schedules
  re-enabled, btrfs/ext4 mismatch, and a simulated NFS target — and all fire
  correctly. The size estimator was checked against a hand-measured `du`.
- **Every subcommand has now been run for real, restore included.** Nine snapshots
  were taken over 90 minutes and then pruned back to one. Two are kept now:

      2026-08-08_20-10-29    "known-good, post-logrotate"    18G, 741,906 files
      2026-08-08_21-01-42    "restore test baseline"              741,911 files

  The first is the baseline — it postdates the `auth.log` rotation, so it does not
  carry the 145 MB log the earlier ones did. The second is what the restore test
  restored; its `file_count` is 5 higher, which accounts for itself exactly: three
  marker files in `/opt`, one in `/etc`, plus the `/opt/restore-test` directory.
  35.3G free.
- **The first snapshot, measured:**

      snapshot size   18G          predicted 18.2G
      files           741,884
      elapsed         ~4 minutes   18:29:26 -> 18:33  (254s by timeshift's count)
      free space      53.5G -> 36G

  The estimator was accurate to within about 1%. The write started at ~125 MB/s
  on large files and fell to ~33 MB/s once it reached the many-small-files parts
  of `/usr` and `/var` — IOPS-bound, not throughput-bound, which is why "a few
  minutes" rather than "18G at disk speed".
- **`prune` works, and it proved the `ADDS` column is not contents.** Pruning eight
  snapshots freed **2.9G** (32.7G → 35.6G) — not the 21G the total suggested, for
  the reason the tool warns about before asking. The survivor had been displaying
  as `291M` under `ADDS`; with the others gone `list --sizes` reports it as **18G**.
  Nothing was lost by deleting the original 18G baseline: every snapshot is a
  complete tree of hardlinks, so `ADDS` is relative attribution and the contents
  are whole regardless. That distinction is the single easiest thing to get wrong
  here, and it is now confirmed from both directions.
- **The progress percentage is dead on the first snapshot only — and it is not
  stalled.** It sat at `0.00% complete (??? remaining)` for the entire 254s. The
  rsync command Timeshift builds contains **no `--info=progress2` and no
  `--progress`**, so Timeshift counts rsync's itemized (`-ii`) output against an
  expected file total. That total comes from the **previous snapshot's
  `file_count`** in its `info.json`; with no parent there is nothing to divide by,
  which is what `???` means. The second snapshot, which logged `Linking from
  snapshot: 2026-08-08_18-29-26`, incremented normally.

  So: on a first-ever snapshot, `df -h /` is the honest progress meter — free
  space falls toward the predicted figure. Do not kill a snapshot stuck at 0%.
  (Mechanism inferred from `strings /usr/bin/timeshift` plus the two runs, not
  from reading the source.)
- **Timeshift printed one stray error, and it is Timeshift's, not ours:**

      /tmp/timeshift-TbqNobcb/17862284202443484360: line 10: status: No such file or directory

  It runs commands through a wrapper script in a per-invocation temp dir and
  captures the result with `echo ${exitCode} > status` — a **relative** redirect
  (`strings /usr/bin/timeshift | grep exitCode` shows it). Its own cleanup had
  already deleted that directory, so the wrapper's cwd was gone and the write
  failed. Cosmetic; the snapshot completed normally. It also litters `/tmp` with
  `timeshift-*` dirs containing a single `status` file, which are never removed.

  Because "that error was probably fine" is not an acceptable thing for a
  rollback tool to leave you with, `create` now **verifies the snapshot instead
  of trusting the exit code** — `info.json` is written last, so its presence plus
  a plausible `file_count` and a non-empty `localhost/` tree is the real
  completion marker. It reports `verified <name> -- 741884 files, tagged
  'ondemand'`, and says outright that the stray line does not change that.
- **What an incremental actually costs, taken apart.** Successive snapshots minutes
  apart each added 437M, 437M, 439M — suspiciously identical, so it was worth
  measuring rather than assuming:

      ~196 MB   50,246 directory inodes at 4K. Directories CANNOT be hardlinked,
                so every snapshot pays for the whole tree no matter what changed.
      ~165 MB   /var/log churn -- 138.7 MB of it a single bloated auth.log (see
                below). rsync copies whole files, so an appended log is re-copied
                in full and cannot share with the previous snapshot.
       ~75 MB   rsync-log + rsync-log-changes, which Timeshift writes INSIDE each
                snapshot. You pay for these once per snapshot, forever.
      -------
       436 MB   against 439 MB measured. 3 MB unaccounted.

  **Confirmed by rotating the log and re-measuring.** The prediction was that one
  more snapshot would still cost ~437M (the freshly rotated `auth.log.1` is a new
  145 MB file, copied once) and that the next would fall to ~290M. Measured: 446M,
  then **291M**. `/var/log` churn dropped 165 MB → 16 MB, and the composition
  settled at 196 + 75 + 16 = 287 MB against 291 MB measured.

  So the steady-state floor is **~271M per snapshot even if nothing changes**, and
  after rotation **93% of an incremental is structural overhead rather than your
  data** — 196M of directory inodes plus 75M of Timeshift's own logs. "0.5–2G per
  incremental" was the right ballpark for the wrong reason.

- **`auth.log` had grown to 145 MB, and it is not an ongoing fault.** 857k sudo
  lines from `batocera-watch` calling `sudo /usr/bin/ntfsls` in a loop, confined to
  Aug 4–5 (272k lines then 585k lines; Aug 6–8 are back to ~1,000/day). The loop is
  long stopped — the file simply has not rotated since Aug 1. Worth a
  `sudo logrotate -f /etc/logrotate.d/rsyslog` before the next snapshot, which
  takes ~138 MB off every future incremental.

  **Decision: `/var/log` stays IN the snapshots.** Joe's call, 2026-08-08. It costs
  ~162 MB per incremental and means a restore replaces current logs with the
  snapshot's — worth knowing, because those are the logs that would explain
  whatever you were recovering from. Copy anything you need out of `/var/log`
  before restoring.

- **Why the log was allowed to reach 145 MB — two causes, both worth knowing.**

  1. **`logrotate.service` has `ConditionACPower=true`.** On a laptop that is
     often unplugged, "weekly" quietly becomes "weekly, if you happen to be on AC
     at 00:00". The journal shows the 2026-08-08 run skipped for exactly this
     reason: `logrotate.service was skipped because of an unmet condition check
     (ConditionACPower=true)`. Nothing warns you; the logs just keep growing.
  2. **Forcing a rotation the obvious way does not work.** This looks right and is
     wrong:

         sudo logrotate -f /etc/logrotate.d/rsyslog     # WRONG

     Passing a `/etc/logrotate.d/` fragment directly does **not** load
     `/etc/logrotate.conf`, so its global `su root adm` never applies. With no `su`
     in effect logrotate applies its safety check, sees `/var/log` is
     group-writable by `syslog`, and skips every file with *"insecure
     permissions"*. That message strongly implies a misconfigured system. Nothing
     is misconfigured: `/var/log` is the stock `drwxrwxr-x root:syslog`, and
     `/etc/logrotate.conf` passes `dpkg -V` unmodified. Use:

         sudo logrotate -f /etc/logrotate.conf          # RIGHT

     which is what the timer itself runs (`ExecStart=/usr/sbin/logrotate
     /etc/logrotate.conf`), just forced.

     The wrong form was run **twice** before this was worked out, and both times it
     printed six confident "insecure permissions" errors and changed nothing. The
     proof the conf form is the right one was already on disk: `syslog.1` dated
     Aug 2 and `auth.log.1` dated Aug 1, both rotated by the timer using exactly
     that config. Rotation then worked first try — `auth.log` went to 0 bytes and
     the 138.7 MB body became `auth.log.1`.
- **Honest hardlink sizes are expensive, and that turned into a fake hang.**
  Attributing shared data correctly needs one `du` across every snapshot at once.
  At 7 snapshots of ~742k files that is ~5.2M stat calls — **1m57s** measured (11s
  user, 54s sys, rest I/O), and it grows linearly with every snapshot kept. Because
  `create` printed the listing when it finished, every snapshot ended with a
  lengthening silence *after* the real work was over, which reads as a hang and
  invites a Ctrl-C. `list` is now instant (**0.079s**) using names, comments and the
  `file_count` timeshift already recorded in `info.json`; the sizing lives behind
  `list --sizes` and prints an ETA before it starts. Cheap default, expensive on
  request, and never a silent wait.
- **Restore has now been tested, and there is no untested path left.** `status`,
  `configure`, `create`, `list`, `list --sizes`, `prune` and `check-esp` have all
  run against real data, including their refusal and abort paths — and restore,
  the one the others exist to serve, passed 6 of 6 on 2026-08-08. "We have a
  rollback" is no longer a claim resting on an unexercised code path in someone
  else's program.

  It was tested here rather than somewhere disposable, deliberately: the
  machine-specific traps (EFI, the ESP, `wl`/DKMS, apt history) are exactly what a
  test on a different machine would not have found. The risk was bought down with
  a verified off-machine copy of `$HOME` first, not accepted blind. Two of the
  four findings above — the ESP being in scope, and the apt-history rewind — only
  exist because it ran on the real hardware.
- Nothing on iteration8 was set up for backups. The kernel workshop there
  (`/srv/kernel-workshop`, see `workshop/README.md`) is unrelated to this.

### Other threads open at the same time

| thread | state |
| --- | --- |
| Jenni's MacBookAir6,1 | four pending items in `~/jenni-camera-todo.md`; her machine is also the last thing gating the upstream applesmc patch |
| applesmc upstream patch | drafted and fully tested, `patches/upstream-applesmc-nand-disk.md`, not sent |
| Wi-Fi lockups | trigger corroborated (connection bursts, ~254 sockets); the power-save experiment is confounded — see `WIFI.md` |
| Automate kernel-update testing in the VM | **Designed; the foundation is built.** A kernel update currently gets proven by installing it on the laptop and boot-testing (`kernel-guard boot-test`) — a real reboot on the only machine. `vm-restore-test.sh restore` now rebuilds this system in a VM unattended and freezes it as `golden.qcow2`, so the expensive part is done once and each candidate can start from an instant qcow2 overlay. **The design decided 2026-08-09: the two questions split across the two VM phases the script already has, and neither needs a new network hole.** The live-ISO phase is networked *and carries no identity*, so chroot into the restored root there and `apt-get install` the candidate — DKMS builds against the target's headers, not the running kernel, and `kernel-guard.sh check` run in that chroot is the verdict (it already exits 2 for "newest kernel has no `wl`"). The disk phase then boots it under `restrict=on`, exactly as now, answering only "does it come up" — plus `modprobe wl` succeeding, which is a strictly stronger signal than "it built". **Built and proven end to end 2026-08-09.** `testbase` boots and answers over serial; `verify` runs the helpers' own checks (15, with `verify-control` proving they can fail); `update-test --unhold` ran the real upgrade to **6.17.0-42**, built both DKMS modules, booted that kernel via a one-shot and graded 15/15 against it. Note `golden.qcow2` is a point-in-time — the first one carries 6.17.0-40/-41 and 7.0.0-28, already behind the laptop's -42 — so refresh it when a newer snapshot is pushed. **The limitation that must not get lost: a VM has no BCM4360, no FaceTime camera and no Apple SMC**, so it can prove the `wl` build succeeds and the system boots, but *cannot* prove Wi-Fi works. That is a real split rather than a flaw — a failed DKMS build is the common stranding cause and is exactly what a VM catches, while the hardware path still needs one boot on the metal. Note iteration8 already hosts the kernel workshop (`/srv/kernel-workshop`), so build-and-test could live on one machine |
| Retry the build-sizing measurement on different storage | **Unproven, 2026-08-09.** Giving the restore guest 8 cpu / 16G instead of the laptop-matching 2 cpu / 4G, *and* removing a 19G write, together bought **26 seconds** (21m00 → 20m26). Wall-clock cannot see it: iteration8 has 251G of RAM and `vm.dirty_ratio` 20%, so ~50G of dirty pages are allowed — more than the whole restore writes — and the cost is flushed after the command returns. Run-to-run variance for the same phase (9, 15, 20 min) swamps anything this size. The floor is four 7200rpm Hitachi disks and no SSD. The generous sizing is kept because it costs nothing on a 32-core host, **not** because it was shown to help. Worth retrying on a host with different storage — the 7810, if it is ever converted from Windows to Linux |
| OEM image: Mint + these fixes, bootable, no install required | **Scoped 2026-08-09, not started.** The mechanism for the provisioning half of the two-golden thread below. Goal: hand someone a USB they boot into a working Mac-on-Linux with a "create your account" wizard — no installing, macOS untouched, stick out and they are back. **Use OEM mode, not an ISO remaster**: `oem-config`/`oem-config-gtk` are in Mint's archive (`24.04.3+mint19`), which is the supported way to ship a preconfigured system. Build: install Mint fresh in a VM (NOT from Joe's snapshot — see the rule about never restoring it onto someone else's machine), apply the fixes, `oem-config-prepare`, shut down, and that qcow2 is the image. **Most of the machinery already exists** — `usb-image`'s UUID rewriting, `nbd_attach`, the chroot + `update-grub` pass, and `qemu-img convert -O raw`. Genuinely new: the one-off fresh install, and a `provision.sh` that orchestrates the existing `install` subcommands (`mba-webcam.sh install`, `kbd-backlight.sh install`, `kernel-guard.sh install-hook`) — which do not currently have a single entry point or a documented order. **Two things OEM mode does not cover:** `/etc/machine-id` and the SSH host keys must be blanked so each first boot generates its own, or every stick and every refurbished machine shares one identity — the tailnet problem at fleet scale, see [[restored-clone-identity]]. And build smaller than 40G if it is destined for sticks rather than USB SSDs. **`optimize-mba.sh` must be opt-in**: Joe declined the power tuning for his own machine and a provisioning image should not impose it. Note plain Mint already ships the Broadcom driver, so stock media usually gets Wi-Fi on a MacBookAir6,1 — what it lacks is the camera, the backlight fix and the kernel guard |
| Two different "golden" images, and why they must not be conflated | **Raised 2026-08-09.** A fresh install from the ISO with this repo's tools in place would make a better base *for provisioning*, and a worse one *for update pre-flight*. They answer opposite questions and wanting one name for both is how someone eventually tests an update against the wrong image. **Pre-flight needs the snapshot**, because `update-test` asks "will this break MY machine" and the interesting failures come from accumulated state — held kernels, the DKMS versions actually installed, config drift, whatever got hand-installed. A fresh install would pass updates that break the real laptop, and the metal boot would be where you found out. **Provisioning needs a fresh install**, and is better than a clone in three ways: it has **no identity** (its own machine-id, no tailnet node key, no SSH host keys — so the whole `restrict=on` dance and the clone-steals-the-tailnet hazard simply do not arise, see [[restored-clone-identity]]); it is perhaps 6-8G rather than 19; and it is reproducible from first principles rather than from a snapshot that has to cross Wi-Fi first. One wants *no* history, the other wants *all* of it. Practical wrinkle: Mint uses Ubiquity, which takes preseed only partially, so a fully unattended build is awkward — the usual dodge is to install once by hand and snapshot *that* as the provisioning base, which is the machinery already here pointed at a clean machine |
| Move the offsite copy onto redundant storage | **Found 2026-08-09, not done.** `/srv/mba-snapshots` — the laptop's entire disaster-recovery copy, 22G — lives on **`/dev/sdc4`, the one disk in iteration8 with no redundancy.** The other three (`sda`, `sdb`, `sdd`) are a RAID5 `md0` holding `/home`; `sdc` is standalone and carries iteration8's root, the snapshots, and the VM images. So the copy that exists *because a disk might die* is itself a single point of failure. Raised after a recent drive failure, which is precisely the scenario it insures against. **`sdc` itself is healthy** — SMART PASSED, 0 reallocated, 0 pending, 0 offline uncorrectable, 3536 power-on hours — so this is not urgent, it is structural. The fix is to move the 22G onto `md0`, which has 287G free, at the cost of taking `/home` from 92% to ~95%, and repoint `snapshot-offsite.sh`. **Only the snapshots need moving**: `golden.qcow2` and the overlays are rebuildable from them in twenty minutes and can stay on the non-redundant disk. Worth knowing while considering this: **writes do not wear these disks.** Write endurance is an SSD concern; an HDD's wear is mechanical — spindle hours and head actuation — and accrues whether or not anything is being written. The ~40G a restore writes costs essentially nothing in disk life, so the I/O volume is the wrong thing to economise on. Redundancy is the right one |
| Vault the external dependencies | **Idea, 2026-08-09, not started.** Prompted by the observation that drivers and installers evaporate over time — the early-internet promise of permanent availability was a lie, and you find out on the day you need it. Inventory of what this project depends on from outside, and where it stands: the **facetimehd firmware blob** (a two-hop dependency — patjak's GitHub repo, which itself pulls a package Apple hosts) is **already safe by accident**, because it lives in `/lib/firmware` and is therefore inside every system snapshot; likewise **broadcom-sta's DKMS source** in `/usr/src` and the installed kernels. The real gaps are the things needed to build a *new* machine rather than restore this one: the **Mint 22.3 ISO** (only on iteration8, and stable releases migrate to archive mirrors) and a **macOS installer** (does not exist yet, and is the one on a clock — see `MACOS.md`). That gap is precisely the fleet case. iteration8 has 1.6T free, so the cost of vaulting is nil compared with the cost of discovering a dead URL |
| Xorg crash | **First report captured 2026-08-09**, on the `6.17.0-42` boot-test. Retrace says the `SIGABRT` is Xorg's own `FatalError` path — the real fault was a fatal signal *inside* `modesetting_drv.so` during `InitOutput()`. The next boot (7.0.0-28) failed the same code path cleanly (`no screens found`, `/dev/dri/card0` not yet present), so a DRM-availability race is the working hypothesis, not a conclusion. Full write-up under [`crash-report.sh`](#crash-reportsh); coredump kept at `~/xorg-crash-6.17.0-42-2026-08-09.crash`. `/var/crash` is clear, so **which kernel the next one lands on is the discriminator** |
