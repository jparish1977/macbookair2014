# macbookair2014

Scripts for running Linux Mint 22.x / Ubuntu 24.04 on a 2014 MacBook Air
(MacBookAir6,1 / 6,2 — Haswell, 4GB RAM, BCM4360 Wi-Fi).

> **These run as root and change system configuration.** Read them before you
> run them. They are written for a specific machine and a specific distro; on
> anything else, treat them as a reference rather than something to execute.

## What is in here

**Making the hardware work**

| | |
| --- | --- |
| [`mba-wifi.sh`](#mba-wifish) | BCM4360 Wi-Fi via broadcom-sta, with the 7.x trial/revert structure |
| [`mba-webcam.sh`](#mba-webcamsh) | FaceTime HD camera via facetimehd, per kernel |
| [`fix-camera.sh`](#fix-camerash) | Recover the camera when it wedges (+ desktop launcher) |
| [`kbd-backlight.sh`](#kbd-backlightsh) | Stop the keyboard backlight being used as a disk-activity light |
| [`optimize-mba.sh`](#optimize-mbash) | zram, earlyoom, noatime, low-memory MySQL |
| [`chromium-google-search.sh`](#chromium-google-searchsh) | Add Google as a search engine |

**Not getting stranded**

| | |
| --- | --- |
| [`client-setup.sh`](#client-setupsh) | Point a machine at a provisioned server — discovers the layout by asking the server, writes both configs |
| [`server-provision.sh`](#server-provisionsh) | Build the **server** side from nothing on any Debian/Ubuntu host — packages, layout, and which filesystems actually survive a disk |
| [`preflight.sh`](#preflightsh) | **Test an update before this machine takes it** — snapshot, push, rebuild in a VM, run the real upgrade, report a verdict |
| [`kernel-guard.sh`](#kernel-guardsh) | Apt hook: warn *before* a reboot that would leave the machine with no Wi-Fi |
| [`apt-rollback.sh`](#apt-rollbacksh) | Undo a bad apt transaction precisely, from apt's own records |
| [`system-snapshot.sh`](#system-snapshotsh) | A local known-good snapshot for when you *don't* know what changed |
| [`restore-test.sh`](#restore-testsh) | Prove the restore works *before* you need it, with a control condition |
| [`snapshot-offsite.sh`](#snapshot-offsitesh) | Copy the snapshot tree to another machine — for a dead disk, not a bad update |
| [`vm-restore-test.sh`](#vm-restore-testsh) | Rehearse the whole disaster recovery in a VM, headless and scriptable |

**Working out what is actually wrong**

| | |
| --- | --- |
| [`who-writes.sh`](#sysfs-watchsh-and-who-writessh) | Name what writes a sysfs attribute — or prove nothing in userspace does |
| [`sysfs-watch.sh`](#sysfs-watchsh-and-who-writessh) | Log every change to a sysfs attribute, surviving logout or a reboot |
| [`wifi-snapshot.sh`](#wifi-snapshotsh) | Capture Wi-Fi state *during* a fault (+ desktop launcher) |
| [`crash-report.sh`](#crash-reportsh) | Read apport `.crash` files without the GUI |
| [`module-patch-test.sh`](#module-patch-testsh) | Test a kernel module patch on the machine that has the bug, with a control |
| `applesmc-patch-test.sh` | The purpose-built ancestor of the above; kept as the worked example |

**Building kernels**

| | |
| --- | --- |
| [`workshop/`](#workshop) | Kernel build and bisect host on iteration8 — has its own README |

**Write-ups** — reasoning that is not recoverable from the scripts

| | |
| --- | --- |
| [`WIFI.md`](#wifimd) | Why `mba-wifi.sh` is so defensive; the panic history; the lockup trigger |
| [`SNAPSHOTS.md`](#snapshotsmd) | Why rollback here is apt-level *and* local-snapshot, and why never remote |
| [`MACOS.md`](#macosmd) | Whether OpenCore can run newer macOS on this model |
| [`patches/`](#patches) | The facetimehd fix in use, and the applesmc patch drafted for upstream |

## `mba-wifi.sh`

Broadcom BCM4360 survival tool.

These Airs use a BCM4360 `[14e4:43a0]` on Apple's proprietary connector, so the
card cannot be swapped. Its only working driver is `wl`, built by DKMS from
`broadcom-sta-dkms` — a shim around a prebuilt binary Broadcom froze in 2015.
Kernel 7.x breaks the DKMS build (objtool rejects the blob,
[LP#2161038](https://bugs.launchpad.net/bugs/2161038)).

Because these laptops have no Ethernet port, a broken `wl` means no network at
all, including no way to fetch the fix. Two modes:

| Mode    | Purpose                                       | Risk           |
| ------- | --------------------------------------------- | -------------- |
| `guard` | Keep the machine off 7.x and able to recover  | Safe, idempotent |
| `trial` | Deliberately test 7.x with a full undo path   | Risky, opt-in  |

```sh
sudo ./mba-wifi.sh help
```

[**WIFI.md**](WIFI.md) has the history this script exists because of — the
2026-07-21 kernel panic, the 7.x trial, why the objtool bypass is scoped rather
than global, and what is known versus merely suspected about the flakiness.
Worth reading before changing anything here.

## `mba-webcam.sh`

Gets the FaceTime HD camera working.

The camera is a Broadcom 1570 `[14e4:1570]` on the **PCIe** bus, not USB, so
`uvcvideo` never enumerates it and a stock install has no `/dev/video*` at all.
Nothing is broken — there is simply no in-tree driver. The only one that works
is [`facetimehd`](https://github.com/patjak/facetimehd), out-of-tree, and it
needs a firmware blob Apple ships only inside macOS.

Kernel 7.x removed the `vb2_ops` `wait_prepare`/`wait_finish` callbacks, which
broke every release before 0.7.0.1. The script pins **0.7.0.2** for that reason;
do not move the pin backwards.

```sh
sudo ./mba-webcam.sh                 # install (default)
sudo ./mba-webcam.sh uninstall       # full undo
     ./mba-webcam.sh status          # no root needed
     ./mba-webcam.sh install --dry-run
```

### Tuning a dark picture

```sh
     ./mba-webcam.sh tune                       # show current values
sudo ./mba-webcam.sh tune brightness=180 contrast=140
sudo ./mba-webcam.sh tune --reset              # back to defaults
```

The driver registers five controls (`fthd_v4l2.c:707`) — `brightness`,
`contrast`, `saturation`, `hue` (0–255, default 128) and
`white_balance_automatic` (0/1, default 1). These are real: `brightness`
dispatches to `fthd_isp_cmd_channel_brightness_set()`, an actual ISP command.

It registers **no exposure and no gain control**, so nothing here lengthens
sensor integration time. Raising brightness lifts the noise floor along with the
image — good lighting still matters, it is just not the only lever.

Settings are applied immediately and persisted through a udev rule that matches
`ATTR{name}=="Apple Facetime HD"` rather than a node number (see below). Use
`--no-persist` to apply without writing the rule.

Note the control is `white_balance_automatic`, not the kernel's
`V4L2_CID_AUTO_WHITE_BALANCE` spelling — `v4l2-ctl` rejects the latter. The
script accepts either and normalises.

### The camera is not necessarily `/dev/video0`

On the machine this was written for it comes up as `/dev/video1` (sysfs index 0)
because another driver claims the lower minor first. The script resolves the
node by asking sysfs which one `facetimehd` owns, and the udev rule matches on
device name — neither assumes a number.

Two things worth knowing:

- **Firmware is a ~2.8MB HTTP byte-range request** into a 10.11.5 update image,
  not a full download — chosen deliberately for a 4GB machine with a small SSD.
  If it fails, Apple has usually rotated the CDN URL baked into the upstream
  Makefile.
- **DKMS carries it across kernel upgrades** (`AUTOINSTALL=yes`), the same way
  `broadcom-sta` already does here. It does *not* carry backwards: `AUTOINSTALL`
  fires when a kernel is installed, so booting a kernel that was already on disk
  before the camera was set up gives you a registered package with no module
  built for it, and no `/dev/video*`. That is not a hypothetical here — booting
  the older kernel is this machine's documented Wi-Fi recovery path. Re-run
  `sudo ./mba-webcam.sh install`; it detects the gap and builds just the missing
  module without re-cloning or re-downloading anything.

`dkms.conf` upstream does not reliably track the git tag — master still declares
`0.7.0.1` while `0.7.0.2` is released — so the script reads `PACKAGE_VERSION`
from the checkout rather than assuming the tag, otherwise `dkms add` fails on a
source-tree name mismatch.

Washed-out or dark output is this driver's known-weak auto-exposure, not a
failed install.

## `fix-camera.sh`

One-command recovery for when the camera stops delivering video.

What was actually observed, on a machine where the camera had been working:
after a session with Zoom, the kernel logged `facetimehd 0000:02:00.0: IO:
timeout` repeatedly with a backtrace through `fthd_buffer_prepare`, and from
then on *every* camera app errored — Cheese included. A reboot cleared it
completely; `dmesg` after the reboot showed zero timeouts and the camera worked
in Cheese, Zoom and OBS in turn.

**The trigger is unknown.** "Two camera apps at once" was the working theory and
is repeated all over the internet. It was tested directly, on the same model of
hardware and the same driver, and it is wrong:

| Test | Result |
| --- | --- |
| Cheese streaming, then Zoom opened on top | no timeout — Zoom gets a clean busy failure and shows a blank preview |
| OBS alone, 3077 frames over two sessions, closed normally | no timeout, clean stop, no leaks |

V4L2 streaming is exclusive, so a second app is simply refused; it does not
corrupt anything. What actually provoked the one real wedge we have seen is
still open. Differences not yet ruled out: it happened on a MacBookAir**6,1**
rather than a 6,2, on the unpatched driver, during a real Zoom *call* rather
than a local preview.

**`modprobe -r` failing with "in use" is explained, and it is not a stuck
task.** See *WirePlumber holds the camera* below. On the one occasion it was
seen during a wedge, `fuser /dev/video*` was empty seconds later with no process
in state `D`.

So the script tries the cheap thing first and does not pretend to know more
than that: it closes the camera apps (Zoom, Cheese, OBS, guvcview), reloads
`facetimehd`, and reports the fresh node. It re-execs itself under `sudo`, so a
non-technical user just runs `fix-camera` and enters a password — no arguments,
no driver knowledge. If the unload fails it checks for a `D`-state process at
that moment and says which case it is, then points at `sudo reboot` — the one
recovery actually confirmed to work.

Install it as a plain command so it is reachable from any terminal:

```sh
sudo install -m 755 fix-camera.sh /usr/local/bin/fix-camera
```

Running one camera app at a time is still sensible — a second one gets nothing
anyway — but it is housekeeping, not a fix for the wedge. It was tested and does
not prevent it, because it does not cause it.

`fix-camera.desktop` is an optional clickable launcher for a non-technical user
who would rather not open a terminal. It runs the command in a terminal window
anyway (the sudo prompt and result need to be visible) and holds the window open
until a key is pressed. Install it into the menu, and optionally onto the
desktop:

```sh
sudo desktop-file-install fix-camera.desktop          # adds "Fix Camera" to the menu
cp fix-camera.desktop ~/Desktop/ && chmod +x ~/Desktop/fix-camera.desktop
```

On Cinnamon a desktop launcher is untrusted until you right-click it once and
pick **Allow Launching**; the menu entry needs no such step.

### WirePlumber holds the camera

`modprobe -r facetimehd` reports "in use" on a stock Mint desktop even with
every camera app closed and *no* process holding an fd on `/dev/video*`.
WirePlumber's V4L2 monitor registers the camera as a PipeWire device
(`wpctl status` lists it under Video) and keeps a reference to the module.

`fix-camera.sh` therefore tries the plain unload first and only stops
WirePlumber if that fails — it also carries audio — then restarts it afterwards.
If you are doing this by hand:

```sh
systemctl --user stop wireplumber
sudo modprobe -r facetimehd && sudo modprobe facetimehd
systemctl --user start wireplumber
```

## `patches/`

Two different things live here, and they are not the same kind of object.

| | |
| --- | --- |
| `fthd-recover-from-firmware-timeout.patch` | **In use.** Applied to the local facetimehd source before the DKMS build. Described below. |
| `upstream-applesmc-nand-disk.md` | **A submission package, not applied locally.** The one-line kernel patch for the keyboard backlight bug, with its evidence, its remaining gaps, and how to send it. Fully tested — including on a mainline kernel — and **not sent**. See [`kbd-backlight.sh`](#kbd-backlightsh) for the local fix, which is a udev rule. |

The rest of this section is about the facetimehd patch. It is a local patch
against the pinned upstream driver, applied to `/usr/src/facetimehd-$VER` before
the DKMS build.

`fthd-recover-from-firmware-timeout.patch` addresses upstream
[issue #332](https://github.com/patjak/facetimehd/issues/332) — "one firmware
timeout kills the camera until the module is reloaded". On stop failure the
driver did:

```c
vb2_buffer_done(ctx->vb, VB2_BUF_STATE_DONE);
ctx->vb = NULL;
ctx->state = BUF_ALLOC;
```

`ctx->vb` is the only reference tying a slot to its vb2 buffer. Clearing it
makes the slot unreachable to `fthd_buffer_prepare()`, which matches
`BUF_ALLOC` only when `ctx->vb == vb` — so every later prepare returns
`-ENOBUFS` and the camera is dead in *every* application — and to
`fthd_buffer_cleanup()`, which finds slots by `ctx->vb`, leaking the iommu and
dma_desc allocations. The patch keeps `ctx->vb` and reports `VB2_BUF_STATE_ERROR`
instead of `DONE`, matching the send-failure path already in
`fthd_buffer_queue()`.

Apply, rebuild and verify:

```sh
sudo patch -b -d /usr/src/facetimehd-0.7.0.2 -p1 < patches/fthd-recover-from-firmware-timeout.patch
sudo dkms build   -m facetimehd -v 0.7.0.2 -k "$(uname -r)" --force
sudo dkms install -m facetimehd -v 0.7.0.2 -k "$(uname -r)" --force
modinfo -F srcversion /lib/modules/"$(uname -r)"/updates/dkms/facetimehd.ko.zst
```

> **`dkms install --force` alone does not rebuild.** If a build already exists
> for that kernel it reinstalls the cached one and prints no "Building module"
> step, so a source patch silently does not reach the running system. Always run
> `dkms build --force` first and confirm `srcversion` actually changed — the
> unpatched 0.7.0.2 is `BFD95833D1A467A419F3EE0`, patched is
> `594BD4C77FD51B8CD4381BD`.

Reverting is `sudo patch -R -d /usr/src/facetimehd-0.7.0.2 -p1 < …` followed by
the same rebuild; `patch -b` also leaves `fthd_v4l2.c.orig` behind.

> **Patching the source does not update kernels already built.** `dkms status`
> reports every kernel as `installed` whether or not its module predates the
> patch, so it will not tell you. Rebuild each one and check:
>
> ```sh
> for k in $(ls /lib/modules); do
>   f=/lib/modules/$k/updates/dkms/facetimehd.ko.zst
>   [ -f "$f" ] && printf '%-22s %s\n' "$k" "$(modinfo -F srcversion "$f")"
> done
> ```

**This is not verified to fix the wedge.** It builds, loads and runs the camera
normally, and the reasoning is confirmed against the 0.7.0.2 source, but
provoking a firmware timeout on demand was not possible — the real test is
whether a future wedge recovers on its own. Upstream is also explicit that this
addresses the driver's inability to *recover* from a timeout, not the reason the
firmware times out.

## `kernel-guard.sh`

Stops a kernel landing quietly without its out-of-tree drivers.

    ./kernel-guard.sh check                    every installed kernel and its drivers
    ./kernel-guard.sh boot-test                kernels you could boot-test
    sudo ./kernel-guard.sh boot-test VERSION   boot one ONCE, then back on its own


With no apt pin, 7.x point releases arrive unattended and DKMS rebuilds `wl` and
`facetimehd` for each one. When that build fails, DKMS does say so — in the
middle of hundreds of lines of `apt upgrade` output, where it is trivially
missed. The consequence appears one reboot later, as a machine with no `wl`, no
Ethernet port, and therefore no way to fetch the fix.

The check has to happen at upgrade time, while the machine is still online and
the working kernel is still running. That is what the apt hook is for:

```sh
./kernel-guard.sh check            # report every installed kernel
sudo ./kernel-guard.sh install-hook
```

Afterwards every apt operation ends with a driver check that prints **nothing**
when all is well, and this when it is not:

```
  ###################################################################
  #  DO NOT REBOOT YET                                              #
  #  The newest kernel has no wl module. This machine has no        #
  #  Ethernet port, so booting it means no network at all.          #
  #    sudo dkms autoinstall -k 7.0.0-28-generic                    #
  ###################################################################
```

Exit codes are `0` fine, `1` a non-critical gap (camera only), `2` the newest
kernel has no `wl`. It distinguishes the two deliberately: a missing camera is
an inconvenience, a missing `wl` strands the machine, and only the second is
worth shouting about.

The hook ends in `|| true`, which is load-bearing rather than sloppy: apt aborts
the run on a failing hook, and breaking apt on a machine whose recovery path
*is* apt would be a worse failure than the one being guarded against.

### On a machine that updates through the GUI

Terminal output is the wrong channel if updates come from Mint's Update Manager
— the warning lands in a details pane nobody opens. Install with `--notify` and
it also raises a desktop notification:

```sh
sudo ./kernel-guard.sh install-hook --notify
```

It finds the graphical session's owner via `loginctl` (not whoever ran `sudo`)
and sends through that user's D-Bus socket. Every step is best-effort — no
session, no `notify-send`, no bus, and it silently does nothing rather than
disturbing the apt run.

`install-hook` always refreshes `/usr/local/bin/kernel-guard` rather than
skipping when the file exists: a stale copy would accept newer flags and ignore
them, leaving a guard that looks installed and quietly does less than you think.

### Seeing it fire

```sh
./kernel-guard.sh test-alarm
```

Prints the real banner — and sends the real notification, if the hook was
installed with `--notify` — clearly marked as a test, then reports the machine's
actual state underneath so a drill can never be mistaken for a fault. It calls
the same function the live check does, because a drill that exercises a *copy*
of the alarm only proves the copy works.

Worth doing once on any machine you install this on, particularly with
`--notify`, since a notification that silently fails to appear looks exactly
like a healthy machine. The alternative test — removing a module to see what
happens — means deliberately breaking Wi-Fi on a machine with no Ethernet port,
which is a poor way to test a guard against losing Wi-Fi.

`remove-hook` undoes it and removes the installed copy.

## `wifi-snapshot.sh`

Captures the state of the Wi-Fi stack **while it is misbehaving**, before the
reboot that destroys the evidence.

```sh
./wifi-snapshot.sh          # no arguments, no sudo needed
```

`wl` is a binary blob, and when it fails there is often nothing useful in the
logs afterwards — the 2026-07 panics flushed nothing at all. So the evidence has
to be collected during the fault.

**It does not just dump state, it probes.** A static dump cannot tell an idle
driver from a wedged one; both look identical. So it asks the driver an nl80211
question and pushes packets at the default gateway, then checks whether frames
actually left the interface. The verdict distinguishes:

| Finding | Meaning |
| --- | --- |
| control path did not answer in 6s | strongest wedge signal — driver gone, not just the link |
| answered, but not associated | association failure, not a wedged blob |
| associated, but no frames left | the interesting failure — a dump would have looked idle |
| frames left, no replies | link alive, far end or association stale |
| replies received | driver is fine; look above it (DNS, routing) |

Three things learned building it, all of which would have produced wrong
answers:

- **Interrupt counts are useless here.** This BCM4360 has no MSI vector
  (`/sys/bus/pci/devices/*/msi_irqs` is empty), so it shares a legacy line with
  `i801_smbus` — the count keeps rising whether or not `wl` is alive. Reported,
  but explicitly discounted.
- **`iw dev link` exits 255 when unprivileged**, printing the association
  correctly and then failing on the signal/bitrate part that needs root. Judging
  it by exit status reports a healthy driver as wedged.
- **One ping burst is not evidence.** The script was seen flipping between
  "wedged" and "healthy" on consecutive runs against a working link, so the
  transmit test now has to fail twice before it is believed. Six consecutive
  runs now give an identical verdict.

Every command that touches the driver runs under `timeout`, because a wedged
`wl` can block an nl80211 query forever and a diagnostic that hangs instead of
writing its file is worse than useless. Output goes to `~/wifi-snapshots/` and
is `sync`ed, on the assumption the machine may not survive much longer.

`wifi-snapshot.desktop` puts it a click away, which matters for a tool whose
whole value depends on being run *during* the fault rather than remembered
afterwards:

```sh
sudo install -m 755 wifi-snapshot.sh /usr/local/bin/wifi-snapshot
sudo desktop-file-install wifi-snapshot.desktop
cp wifi-snapshot.desktop ~/Desktop/ && chmod +x ~/Desktop/wifi-snapshot.desktop
```

It runs in a terminal because the verdict is the point, and holds the window
open so it can be read. The icon is `network-error` rather than
`network-wireless` — you will be looking for it while annoyed and possibly with
a dead link, and the broken-network glyph is easier to pick out. Running it
needs no root, so nothing prompts for a password mid-fault; only installing
does. On Cinnamon the desktop copy needs a one-time right-click →
**Allow Launching**.

## `crash-report.sh`

Reads the crash reports `mintreport-tray` nags about.

Apport `.crash` files look like plain text but are not: the fields worth reading
— the Xorg log, the dmesg tail, the stack — are stored as a literal `base64`
marker followed by base64-encoded gzip. Opening one in a pager gives megabytes
of encoded noise and no answer, which is why these tend to get dismissed rather
than read.

```sh
./crash-report.sh                 # what is queued
sudo ./crash-report.sh show       # summarise each one, decoded
sudo ./crash-report.sh clear      # delete them, asks first — stops the popup
```

It decodes those fields, prints the signal with its meaning (`6` is an abort
from a failed internal assertion, `11` a segfault — a distinction that changes
where to look), pulls the `(EE)` lines out of an Xorg log, and reports which
video driver was actually *loaded* rather than merely probed.

The most useful line it prints is often this one:

```
[warn] obs-studio is no longer installed — this report is moot
```

A report for a package you have since removed or replaced needs no
investigation at all. Both reports queued on this machine turned out that way or
close to it.

Reading another user's report needs root — Xorg's are root-owned — so `list`
works unprivileged but `show` generally wants `sudo`.

### The Xorg crash: what the coredump actually said

`/var/crash` was cleared on 2026-08-08 to start a clean observation window. The
first report to land was 2026-08-09, on the `6.17.0-42` boot-test — signal 6,
`SIGABRT`, no `AssertionMessage`, no `XorgLog`, nothing but a 3.5MB coredump.

`apport-retrace -s` on the saved report gave a usable trace *without* any
`-dbgsym` packages, because the crash came from this machine running the same
package version still installed, so gdb resolved the exported symbols:

    #12 main
    #11 InitOutput()                    <- Xorg setting up screens
    #10 ?? in modesetting_drv.so        <- inside the modesetting driver
    #9  <signal handler called>         <- a fatal signal arrived HERE
    #8  ??
    #7  FatalError()
    #6  ??
    #5  OsAbort()
    #4  abort()  ->  raise(6)  ->  SIGABRT

**Frame #9 is the one that matters, and it inverts the obvious reading.** The
`SIGABRT` is not the fault — Xorg took a fatal signal *inside*
`modesetting_drv.so` during `InitOutput()`, and its own handler turned that into
`FatalError → OsAbort → abort`. So `Signal: 6` in the report is the symptom of
Xorg's error path, not a failed assertion. Any crash routed through `FatalError`
will look like `SIGABRT` here.

**A near-miss on the same code path, same night.** The very next boot (back on
`7.0.0-28`) *also* failed to start lightdm, but cleanly:

    (EE) open /dev/dri/card0: No such file or directory
    (EE) Device(s) detected, but none match those in the config file
    Fatal server error: no screens found          -> exit(1), no coredump

Xorg started at 12.5s, before the DRM device existed, declined, and systemd's
restart succeeded at 14.1s. Both failures are `modesetting` during `InitOutput`
at the same moment of boot, gated on when `/dev/dri/card0` appears — graceful if
you lose the race cleanly, a fatal signal if you lose it mid-probe. That is a
hypothesis, not a conclusion.

**Do not read matching restart counts as the same fault.** Both boots showed
exactly one `lightdm.service: Main process exited` and two lightdm PIDs, which
looked like one recurring problem. The timings differed — 1s versus 9s — and the
causes turned out to be different. The counts were the misleading part.

**Two things that make the next one cheaper to diagnose:**

- **A pending report blocks the next one.** Apport will not write a second report
  for the same executable while one exists, so leaving it in `/var/crash`
  silently suppresses collection. Copy it out, then delete it, to keep the
  evidence *and* re-arm capture.
- **When apport has no `XorgLog`, read `/var/log/Xorg.0.log.old`.** That is the
  previous Xorg invocation — on a fail-then-retry boot it is the failed one, and
  it explained the second failure entirely. It only survives until the next
  restart, so grab it early.

The discriminating experiment is already running: `/var/crash` is clear, so the
next crash is captured automatically, and **which kernel it happens on** is the
answer. Another on `7.0.0-28` means the kernel is irrelevant; only ever on
`6.17.0-42` means it is not. A fully symbolised trace needs Ubuntu's ddebs repo
and `xserver-xorg-core-dbgsym`, which would name frames #10, #8 and #6.

The saved report is `~/xorg-crash-6.17.0-42-2026-08-09.crash`, outside the repo.

## `optimize-mba.sh`

Memory and disk tuning for 4GB. In order: reclaim disk, drop Timeshift
snapshots, enable zram, tune VM sysctls for zram, install earlyoom, set
`noatime` on root, disable absent hardware, shrink the MySQL 8 footprint.

```sh
sudo ./optimize-mba.sh
```

The largest win is zram: zstd averages ~3:1, so a 3.8G zram device holds roughly
3.8G of pages in ~1.3G of real RAM. `vm.swappiness` is set *high* (180) on
purpose — swapping to compressed RAM is cheaper than evicting page cache.

Deliberately does **not** touch power management (TLP/ASPM/PPD), Apache/MySQL/PHP
as installed services, or any XFCE component.

### Old kernels

Never purged automatically. The script lists removable kernels — everything
except the running one and the newest — and asks which to remove, defaulting to
none. If there is no terminal to prompt on, it skips the step entirely.

Keep at least one known-good kernel. On these machines the previous kernel is
the recovery path: if a DKMS rebuild of `wl` fails, the older kernel is the only
way back to a working Wi-Fi card, and there is no Ethernet port to fall back on.

### Known rough edges

The MySQL section assumes `/etc/mysql/mysql.conf.d/` exists. Disk-space figures
in the output are whatever `df` reports for `/`.

## `chromium-google-search.sh`

Makes Google the default search engine in Mint's Chromium.

Mint patches Chromium's prepopulated engine list down to Yahoo and DuckDuckGo,
both carrying Mint referral codes (`c=19111&surl=intl.linuxmint.com`, `t=lm`).
Google is not in the list, so it has to be added rather than selected. Editing
`~/.config/chromium/Default/Preferences` does not work either —
`default_search_provider_data` is listed under `protection.macs`, so Chromium
reads an unsigned edit as tampering and reverts it on the next launch.

An enterprise policy in `/etc/chromium/policies/managed/` is the only route that
survives a restart.

```sh
sudo ./chromium-google-search.sh          # install
sudo ./chromium-google-search.sh remove   # undo
     ./chromium-google-search.sh status   # no root needed
```

Quit Chromium completely afterwards; policies are read once at startup. Verify
at `chrome://policy`.

The tradeoff is that policies are mandatory: `chrome://settings/search` will say
"managed by your organization" and stop being editable. There is no unlocked
equivalent — the `DefaultSearchProvider*` policies are not recommendable, so
`/etc/chromium/policies/recommended/` is ignored for them. To keep the setting
switchable, skip the script and add Google by hand in
`chrome://settings/searchEngines`.

## `MACOS.md`

Whether OpenCore Legacy Patcher can run macOS newer than Apple's cutoff
(Big Sur) on this model. It can, up to Sequoia, and Haswell needs no graphics
root patches at any version — so SIP stays on and updates need no re-patching.
The only real obstacle is the 4GB of soldered RAM. Kept so the question stays
answered.

## `kbd-backlight.sh`

The keyboard backlight went dark "as soon as I log in". Nothing was turning it
off. The `applesmc` driver ships the backlight bound to an **LED activity
trigger**, and what looked like a switch-off was the end of a blink.

`drivers/hwmon/applesmc.c`, unchanged upstream:

```c
static struct led_classdev applesmc_backlight = {
        .name             = "smc::kbd_backlight",
        .default_trigger  = "nand-disk",
        .brightness_set   = applesmc_brightness_set,
};
```

So `/sys/class/leds/smc::kbd_backlight/trigger` reads `[nand-disk]` from boot,
and `led_timer_function` ends each blink by writing 0.

**This is not an SSD activity light, despite how it reads.** `nand-disk` is
fired by the MTD subsystem, and the SSD is not an MTD device:

```
/proc/mtd:  mtd0  00800000  "BIOS"        <- the 8MB EFI SPI flash, via spi_nor
lsblk:      sda   113G  sata  APPLE SSD SD0128F
```

The only MTD device on this machine is the firmware flash chip. Ordinary disk
I/O never fires this trigger. What does is a read of the BIOS flash — which
happens about once per boot.

That is the whole shape of the bug. `gnome-software` activates `fwupd` on the
**first** login after boot, `fwupd`'s `mtd` plugin reads mtd0 during coldplug,
the trigger fires once, and the blink leaves the LED at 0. It looked like a
login event because that refresh happens once per boot — which is also why
logging out and back in never reproduced it.

### Was the trigger intended?

Almost certainly not, though this is inference rather than a quote from the
author. The evidence:

- `.default_trigger = "nand-disk"` was already on the keyboard backlight before
  the [January 2008 case-LED patch](https://lkml.rescloud.iu.edu/0801.3/1513.html),
  so it dates from the original LED support.
- That same patch added a *case* LED and, wanting real disk activity, gave it
  `ide-disk` — the actual disk trigger of the era. Someone who meant disk
  activity did not reach for `nand-disk`.
- `nand-disk` is an MTD trigger. MacBooks of 2007 exposed no MTD device at all,
  so on the hardware it was written for this trigger could never have fired.

The likeliest reading is a wrong pick from the trigger list in 2007 that was
harmless precisely because it was inert. It only became visible on this machine
because two much later changes gave it a source of events: the kernel began
exposing the Intel SPI flash as an MTD device, and `fwupd` began reading that
flash at every startup. A dormant mistake, switched on a decade later by two
unrelated projects.

Detaching the trigger therefore costs nothing real. The behaviour being given
up is "blink the keyboard when firmware flash is read", which nobody asked for
and which fires once per boot.

    sudo ./kbd-backlight.sh install    # detach the trigger, now and every boot
    ./kbd-backlight.sh status          # trigger, level, is the rule installed
    sudo ./kbd-backlight.sh test       # restart fwupd, check the level survives
    sudo ./kbd-backlight.sh revert     # driver default back

`install` writes `/etc/udev/rules.d/60-applesmc-kbd-backlight.rules`. The `60`
matters: `99-systemd.rules` is what starts `systemd-backlight@` for this LED,
and clearing a trigger sets the LED to 0, so the detach has to happen *before*
the restore, not after.

### How it was found, and four ways it was nearly missed

Elimination failed repeatedly here; a kernel stack settled it in one shot.

**The pid on the write is a lie.** The trace named `fwupd`:

```
applesmc_brightness_set  pid=37035  comm=fwupd  value=0
        applesmc_brightness_set+1
        led_timer_function+100      <-- the actual caller
        call_timer_fn+46
        run_timer_softirq+138
        ...
        vfs_read+388                <-- fwupd merely got interrupted here
```

This is a softirq. The pid is whatever was on the CPU when the timer fired.
That name alone sent this chasing fwupd's 130 plugins. **In a softirq or
interrupt stack, read the frames, not `comm`.**

**A restore is not proof of survival.** An earlier session saw
`systemd-backlight` restore 12, saw 24 later, and concluded something was
zeroing the LED. There was never a zero — 12 → 24 is one press of the up key,
the steps being 12 apart. That wrong inference framed the whole problem as
"who writes the zero at login" and cost the most time of anything here.

**A bisection that cannot prove its own intervention proves nothing.** Disabling
fwupd's plugins via `DisabledPlugins=` reported "plugins ruled out" while the
journal plainly showed `FuPluginUefiCapsule` and `FuPluginDfu` still loading —
the config edit never took effect. A toggle-based bisect must verify the toggle
applied before trusting a single round.

**Root was never needed to write the LED.** The sysfs file is `root:root 0644`,
which is why the earlier note here insisted any fix had to be a system unit.
But UPower exposes the write on the system bus and it succeeds unprivileged
from the active session:

```
gdbus call --system --dest org.freedesktop.UPower \
  -o /org/freedesktop/UPower/KbdBacklight \
  -m org.freedesktop.UPower.KbdBacklight.SetBrightness 204
```

Only the *trigger* needs root, and only once.

### This affects Jenni's machine too

Same model, same driver, same default trigger — see the pending list outside
this repo. `kbd-backlight.sh install` is all it needs.

### `boot-test`: "built" and "works" are different claims

`check` proves a kernel's drivers were **built**. It cannot prove the kernel
comes up — DKMS will report a clean build for something that never brings the
interface online. A held fallback you have never booted is a belief, and this
machine keeps three of them.

`boot-test` boots one **once**, using GRUB's one-shot `next_entry`, so the boot
after it returns to the default with nothing to undo. It refuses outright if the
target has no `wl` built, since booting that is precisely the stranding this
script exists to prevent.

**It builds a numeric GRUB path rather than passing a title, and that is the
point.** Run by hand on 2026-08-09:

    grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 6.17.0-42-generic"

was accepted, written to `grubenv`, **consumed by GRUB at boot** — and still
booted the default. `grub-reboot "1>2"` worked first try.

**The check that diagnoses this is reading `grub-editenv list` *after* the boot,
not before.** Before, it only proves `grub-reboot` wrote the variable; it says
nothing about whether GRUB can resolve it. Afterwards:

| `next_entry` | booted | meaning |
| --- | --- | --- |
| empty | the kernel you asked for | worked |
| empty | the default | GRUB consumed it and could not resolve the path |
| still set | the default | GRUB never read `grubenv` at all — a different fault |

Parsing that menu has its own trap, caught by testing against a synthetic
`grub.cfg` rather than the real one: **every inner `menuentry` closes with `}`
too**, so treating any closing brace as the end of the submenu ends it at the
first entry and yields a top-level index for a nested kernel — i.e. silently
boots the wrong thing. Only an unindented brace closes a submenu.

Proven end to end: `6.17.0-42` was installed alongside the held fallbacks, DKMS
built `wl` and `facetimehd` for it, and it booted with Wi-Fi up, camera present
and the keyboard-backlight fix intact — making it the first fallback that is
*proven* rather than merely built.

## `apt-rollback.sh`

Undo a bad apt transaction precisely, using evidence apt already keeps.

    ./apt-rollback.sh list [N]     recent transactions, newest first
    ./apt-rollback.sh show ID      every package one transaction changed
    ./apt-rollback.sh revert ID    the command that undoes it (--run to execute)

`/var/log/apt/history.log` records every transaction with the old *and* new
version of everything it touched, and rotated logs go back further — 76
transactions to late July on this machine. `/var/cache/apt/archives` often still
holds the .deb. So "undo that update" is answerable for free, and it puts back
exactly what changed instead of rolling the whole system back to Tuesday.

This was built **before Timeshift**, not instead of it. The machine's genuinely
dangerous updates — kernels — are already covered better by held fallbacks, the
GRUB menu and `kernel-guard.sh`, and package breakage is precisely revertible
from apt's own records for free. Snapshots remain the right tool for the other
case: something broke, you do not know what changed, or the damage is outside
dpkg. This tool says so rather than pretending otherwise, and
[`system-snapshot.sh`](#system-snapshotsh) now covers that case.

It prints commands and stops. `--run` simulates, shows the plan, and asks.

### Two things testing it caught

**Version strings are not regexes.** The availability check used awk's `$2 ~ v`,
so `30.0.2+dfsg-3build1` was matched as a pattern where `+` is a quantifier — it
never matches the string it came from. The tool confidently reported "NOT
AVAILABLE — a snapshot would be the only route" for a package sitting in
`noble/universe`. Now compared literally.

**It contradicted its own warning.** For a kernel transaction it printed "do not
revert these with apt", then printed a command removing
`linux-image-7.0.0-28-generic` — the running kernel, on a laptop with no
Ethernet. Advice followed by the means to ignore it is worse than silence.
Kernel packages are now filtered out of every generated command and listed
separately as deliberately omitted.

## `system-snapshot.sh`

The other half of rollback: a **local**, system-only, on-demand Timeshift
snapshot, for when something broke and you do not know what changed.

    ./system-snapshot.sh status              what is configured, and whether it is sane
    sudo ./system-snapshot.sh configure      make the config match SNAPSHOTS.md
    sudo ./system-snapshot.sh create "why"   one snapshot, tagged on-demand
    ./system-snapshot.sh list                what exists (instant)
    ./system-snapshot.sh list --sizes        ... with real sizes (slow — see below)
    sudo ./system-snapshot.sh prune [N]      keep the newest N (default 3)
    sudo ./system-snapshot.sh delete NAME    delete one snapshot (name or its reason)
    sudo ./system-snapshot.sh check-esp      what a restore would do to the ESP
    ./system-snapshot.sh restore-help        the procedure, and the local traps

`status` needs no root and is the one to run first. Reach for
`apt-rollback.sh` before this — if you know which update broke it, reverting
those packages beats rolling back 18G.

**Why it refuses a remote target.** This laptop has no Ethernet port. Wi-Fi is
the only interface and it depends on `wl` from broadcom-sta, which has already
failed a kernel transition once (see [`WIFI.md`](#wifimd)). So the likeliest bad
update is one that costs you the network — and a snapshot on iteration8 is
unreachable at exactly that moment. A live USB does not rescue you either; the
live session needs the same driver. So the script hard-refuses network
filesystems, refuses filesystems that cannot hardlink (without hardlinks every
snapshot is a full 18G copy, not a ~1G delta), and refuses **remote block
devices** — iSCSI and NBD hand you a `/dev` node with a real UUID that looks
local and disappears with the network.

Snapshots are on demand, never scheduled: on a 4GB machine a scheduled snapshot
is disk churn you did not ask for at a time you did not pick. `configure`
disables every schedule and `status` complains if something re-enables them.

Measured on this machine: the **first** snapshot took ~4 minutes for 18G (741,884
files; 53.5G free before, 36G after), and the pre-flight estimate was accurate to
about 1%. Six snapshots occupy **20G in total**. Each incremental cost ~437M, and
taking it apart explained all but 3 MB of that:

| ~196M | 50,246 directory inodes at 4K — directories **cannot** be hardlinked, so every snapshot pays for the whole tree |
| --- | --- |
| ~165M | `/var/log` churn — rsync copies whole files, so an appended log cannot share with the previous snapshot |
| ~75M | `rsync-log` + `rsync-log-changes`, which Timeshift writes *inside* every snapshot |

That gave a testable prediction: rotate the oversized log and the next incremental
should still cost ~437M (the rotated file is new, so it is copied once), and the
one after should fall to ~290M. Measured **446M, then 291M** — `/var/log` churn
went 165M → 16M.

So the steady-state floor is **~271M per snapshot even when nothing has changed**,
and **93% of a quiet incremental is structural overhead rather than your data**.

Two things this turned up that are not about snapshots at all, and cost real time
to work out — see [`SNAPSHOTS.md`](#snapshotsmd) for the full write-up:
**`logrotate.service` sets `ConditionACPower=true`**, so on a laptop "weekly"
means "weekly, if you are plugged in at midnight"; and forcing a rotation with
`logrotate -f /etc/logrotate.d/rsyslog` **fails with a misleading "insecure
permissions" error**, because passing a fragment directly skips
`/etc/logrotate.conf` and its `su root adm`. Use `logrotate -f
/etc/logrotate.conf`.

> **On the FIRST snapshot the percentage sits at `0.00% complete (??? remaining)`
> for the whole run. It is not stalled.** The rsync command Timeshift builds has
> no `--info=progress2` and no `--progress`, so Timeshift counts rsync's itemized
> output against an expected file total — and that total comes from the *previous*
> snapshot's `file_count` in its `info.json`. With no parent there is no
> denominator, hence `???`. **Later snapshots do show real progress**, because by
> then there is a parent to divide by. Watch `df -h /` during the first one; free
> space falls toward the predicted number. Do not kill it.

> **Timeshift may also print one stray line after it finishes:**
> `/tmp/timeshift-XXXX/NNNN: line 10: status: No such file or directory`. That is
> its own bug — it captures exit codes with `echo ${exitCode} > status`, a
> *relative* redirect, and its cleanup deletes the temp dir first, so the
> wrapper's cwd is gone. The snapshot is fine. `create` verifies the result
> rather than asking you to believe that, and says so.

### Five things writing it caught

**The obvious locality check was wrong in the dangerous direction.** Checking
"is `/timeshift` on ext4?" only works when the backup device *is* the root
device. Point Timeshift at any other device and it mounts that under `/run` at
run time, so `/timeshift` describes a filesystem the snapshots never touch — the
check would print "ok, local ext4" while rsync wrote to an NFS server. That is
precisely the failure the script exists to prevent, so the check follows the
config rather than a hardcoded path.

**A UUID does not mean a local disk.** Timeshift's config takes a UUID, which
invites exactly that assumption. iSCSI and NBD satisfy it. The check now looks at
the parent disk's transport — `TRAN` is empty on partitions, so asking about
`/dev/sda2` tells you nothing and you have to ask `/dev/sda`.

**`du -sx /` overstated the snapshot by 3.9G.** That difference is `/swapfile`,
which Timeshift excludes by default (`strings /usr/bin/timeshift | grep
swapfile`). Counting it turns a real 18.0G snapshot into 22.3G and could refuse
one that fits comfortably. The estimator now mirrors Timeshift's built-in
exclusions. Worth knowing separately: that swapfile is **active swap** at
priority -1 behind zram0 at 100, and is in `/etc/fstab` — it is the overflow
path, not 3.9G of reclaimable junk.

**An exit code of 0 was not enough.** Timeshift's stray `status: No such file or
directory` line (above) lands in the middle of this script's output, which makes
a successful snapshot look broken. Rather than annotate it away, `create` now
checks the artefacts: `info.json` is written *after* rsync and *after* tagging,
so its presence plus a plausible `file_count` and a non-empty `localhost/` tree
is the real completion marker. A rescue tool that says "probably fine" is not
doing its job.

**`du` per snapshot doubled the reported disk usage.** Listing two snapshots ran
`du` once per snapshot and printed `18G` for each — but they occupy 19G between
them, not 36G. Every separate invocation counts the same shared inodes again. The
giveaway was that taking the second snapshot moved free space by zero. `list` now
runs **one** `du -shxc` over all snapshots oldest-first, so each inode is counted
once and attributed to the first path that referenced it; the column became
`ADDS` — what each snapshot costs on top of the older ones — with a real total:

    NAME                   ADDS      REASON
    2026-08-08_18-29-26    18G       first known-good
    2026-08-08_18-42-18    437M      test

    2 snapshot(s), 19G on disk in total, 35.1G free

This also fixes a worse misconception it was feeding: that deleting the oldest
snapshot reclaims ~18G. It reclaims almost nothing, because a file is only freed
when the *last* snapshot referencing it goes. `prune` now says so before asking
for confirmation, and reports the actual difference afterwards.

**Those honest sizes cost two minutes, so they are no longer the default.** One
`du` across every snapshot is the only way to attribute hardlinked data correctly,
but at 7 snapshots of ~742k files that is ~5.2M stat calls: **1m57s** measured (11s
user, 54s sys, the rest I/O). `create` called it, so every snapshot ended with a
growing stall *after* the work was done — it read as a hang. `list` is now instant
(names, `file_count` from the `info.json` Timeshift already wrote, and comments)
and sizing moved behind `list --sizes`, which prints a time estimate before it
starts rather than going silent:

    1m56.7s  ->  0.079s

**"Keep the newest N" assumes newest means most valuable, and that stopped being
true the moment the restore tests ran.** After the one-way test and the bounce
test there were four snapshots: the three newest were disposable test artifacts
with markers and a `hello` package inside them, and the only pristine one was the
*oldest*. `prune 1` would have deleted the single snapshot worth keeping and kept
three full of test residue — and the docs here had been recommending `prune` as
the cleanup step.

So `prune` now **refuses to delete a snapshot that carries a comment**, on the
grounds that a comment means a human labelled it on purpose and age cannot see
that. It prints the labelled ones, the exact `delete` command for each, and
`--force` if you really did mean by-count. Unlabelled snapshots still prune
normally. The missing piece it points at is `delete NAME`, which removes one
snapshot without disturbing the others — the thing prune's model structurally
cannot express, since the snapshot you want rid of is often not the oldest. It
also accepts the **reason** you typed at `create`, because that is how a person
identifies a snapshot; comments are free text and not unique, so an ambiguous
one lists the candidates and refuses rather than picking.

Both commands warn that hardlinked data is only freed when the *last* snapshot
referencing it goes, and that was then measured: deleting a throwaway snapshot
holding **741,921 files freed 0.5G**, because everything in it but the delta was
still referenced by the two being kept.

## `restore-test.sh`

A snapshot you have never restored is 18G of decoration. This proves the restore
works, on a schedule you choose, instead of finding out on the day something is
broken.

    sudo ./restore-test.sh arm             plant markers, write the manifest to $HOME
    sudo ./restore-test.sh break           modify, delete, add, edit a conf, install a package
    ./restore-test.sh state                what the markers look like right now
    ./restore-test.sh verify               grade the restore (no root needed)
    sudo ./restore-test.sh bounce-arm      build two restore points, A and B
    ./restore-test.sh bounce-verify A|B    grade a hop between them

The sequence is `arm` → `system-snapshot.sh create` → `break` → restore → reboot
→ `verify`. **Run on this machine 2026-08-08: all six checks passed.**

Three things make it a real test rather than a reassuring one:

**There is a control.** One marker is never touched. A restore that silently did
nothing would pass every other check — "the file I did not modify is unmodified"
only means something when the other five moved. It is the check that makes the
result evidence.

**The manifest lives in `$HOME`, outside the snapshot.** Put your expected values
anywhere on the system side and the restore reverts the thing you were about to
grade the restore against. The same applies to anything else you want to survive
as evidence.

**It covers four rsync classes plus dpkg state.** Modified, deleted, added and
unchanged files exercise different paths — in particular, `added.txt` can only
disappear via `--delete`, which is the behaviour most likely to surprise you
elsewhere. The `hello` package proves `/var/lib/dpkg/status` came back too, so
the package database matches the filesystem rather than drifting from it.

Restore the baseline taken *after* `arm`, never an older snapshot: an older one
has no markers, so the restore deletes them as unknown files and every check
fails for the wrong reason.

What running it actually taught — both findings are in
[`SNAPSHOTS.md`](#snapshotsmd), and neither would have shown up on a test machine:
`--skip-grub` does not keep the restore out of the EFI system partition, and a
restore rewinds `/var/log/apt/history.log`, which is the only thing
[`apt-rollback.sh`](#apt-rollbacksh) reads.

### `bounce-arm`: are restore points one-way?

No. A restore never touches the snapshot store (`/timeshift/*` is excluded), so
snapshots newer than the one you restore survive being rolled past, and you can
go forward into them again. **Tested 2026-08-08: 14 of 14 checks across both
hops.** `bounce-arm` builds two complete states, snapshots each, and
`bounce-verify A|B` grades each hop — including that the snapshot you rolled
*past* still exists **and still checksums correctly**, which is the only thing
that makes the way back real.

The forward hop is the stronger of the two: `hello` had to be rebuilt from a
snapshot the system had already moved past, and afterwards `dpkg -V` found no
discrepancies, all 15 of its paths were present and the binary ran. The package
database and the filesystem agree — a restore does not leave dpkg believing
something the disk contradicts.

Each state holds a file the other lacks, so every hop must both create and
delete. A restore that only ever put files back would pass the one-way test and
fail this one.

Building it turned up a property of Timeshift restores worth knowing: **they are
not checksum-verified.** The restore is `rsync -avir --force --delete` with no
`--checksum`, so rsync's quick check applies — same size and same mtime *to the
second* means the file is skipped. The first version of these markers was two
8-byte files written milliseconds apart, and the restore skipped them, reporting
a failure that had not happened. The markers now differ in length so the quick
check cannot fire. In real use the window is small, but a restore is a fast
reconstruction rather than a guaranteed byte-for-byte one.

Snapshot before restoring — for a bounce it is not optional, since the forward
destination has to exist before you hop backwards.

## `snapshot-offsite.sh`

The other half of the snapshot story: `/timeshift` lives on the same `sda` as
`/`, so a dead disk takes the system *and* every snapshot with it. This copies
the tree to another machine.

    ./snapshot-offsite.sh status           what exists both ends, and whether a push can work
    ./snapshot-offsite.sh list [--sizes]   what is on the far end: names, counts, reasons
    sudo ./snapshot-offsite.sh push        copy the tree (--dry-run, --mirror)
    sudo ./snapshot-offsite.sh verify      compare both ends, transferring nothing
    ./snapshot-offsite.sh watch [SECONDS]  readable progress for a push running elsewhere
    ./snapshot-offsite.sh restore-help     how to get it back, and the trap on the way

**Run for real on 2026-08-08**, two snapshots to `iteration8` over the tailnet:

    79m 11s      1,483,788 files at ~3.8 MB/s over Wi-Fi
    20.03G       occupied remotely
    38.69G       apparent size -- so -H saved 18.66G, very nearly half
    verify       all three checks passed

`list` reads each remote snapshot's `info.json` for its file count and the reason
you typed — no root needed, because `--fake-super` leaves the copy owned by the
remote account. `--sizes` adds a single hardlink-aware `du` across every snapshot
at once: **4–5s there against ~2 minutes for the same thing locally.** As with the
local tool those figures are *relative attribution*, not standalone sizes — the
oldest snapshot absorbs all the shared data and looks enormous, and deleting it
frees far less than its number implies.

`verify` is the part worth running: it re-compares the whole tree with the same
flags `push` used, and confirms `/etc/shadow` in the remote copy really does carry
its `user.rsync.%stat` xattr. That last check is the difference between a faithful
copy and 20G that merely looks complete.

**Which host holds your copy is site config, not part of the repo.** Put it in
`.offsite.conf` next to the script (gitignored) or in the environment:

    OFFSITE_HOST=100.x.y.z        # tailnet address of the backup host
    OFFSITE_USER=you              # defaults to $(id -un)
    OFFSITE_DIR=/srv/mba-snapshots

Without it the script says exactly that rather than failing obscurely. Use the
**tailnet** address, not an ssh alias — `iteration8` resolves to `iteration8.local`,
which only works on that host's own LAN.

It is deliberately a **separate script** from `system-snapshot.sh`, because the
two jobs pull in opposite directions and merging them is precisely the mistake
[`SNAPSHOTS.md`](#snapshotsmd) exists to prevent. Rollback must be **local** — the
likeliest bad update here costs you the only network interface, so a snapshot on
another host is unreachable exactly when you need it, and `system-snapshot.sh`
*refuses* a network target. Disaster recovery must be **remote**, for the case
where the disk itself is gone. Local for rollback, remote for disk death.

Three flags carry the design, and getting any of them wrong yields a copy that
looks complete and does not restore:

**`-H` is not optional.** Each snapshot is a full tree whose unchanged files are
hardlinks into the previous one. Without it, two snapshots ship as ~37G instead
of ~18.5G and it worsens linearly.

> An earlier version of this section claimed `-H` disables rsync's incremental
> recursion and forces the whole file list into memory first. **That is wrong.**
> Only `--delete-before`, `--delete-after`, `--prune-empty-dirs` and
> `--delay-updates` disable it. `-H` costs memory for the inode→path table it
> needs to spot links, but rsync still scans and transfers concurrently.
>
> The visible consequence is a **progress percentage that goes backwards**: it
> reached 98% of the first snapshot, then recursed into the second, added the
> newly-discovered work to the denominator, and fell to 86%. It is a percentage
> of a total rsync has not finished discovering. It also explains why both
> snapshot directories appear on the remote within seconds — incremental
> recursion creates subdirectories before recursing into them, so their presence
> says nothing about progress.
>
> One real caveat comes with it: with incremental recursion active, `-H` may send
> a file's data before finding another link to it later. That costs bytes, never
> correctness — the hardlinks are still built correctly. Sorting works in our
> favour here, since the oldest snapshot is the one the others link into and it
> transfers first. `--no-inc-recursive` would eliminate the waste at the cost of
> a long silent scan before anything moves.

**`--fake-super`** lets an unprivileged remote account hold a faithful root-owned
tree: real ownership and mode go into a `user.rsync.%stat` xattr. This was chosen
over `--rsync-path="sudo rsync"` even though the remote *has* passwordless sudo,
because it keeps working if that policy ever changes. `status` checks the target
filesystem actually supports user xattrs instead of assuming it.

**`--partial-dir`** because 75 minutes over Wi-Fi will eventually be interrupted,
and the default behaviour is to discard the partial file and start that file over.

`push` also holds off idle-suspend with `systemd-inhibit` for the duration of the
transfer — scoped to the command, so there is no power setting left changed
afterwards. Lid-close is a separate switch it cannot cover.

### The pull is tested too, with a control

`pull-test` proves the way back, which a push can never demonstrate. It copies
seven probe files rather than 20G, chosen to cover the metadata that actually
breaks, and grades them against the local snapshot the remote copy was made from:

    FILE       SNAPSHOT (truth)   WITH --fake-super   WITHOUT (control)
    shadow     0:42:0640          0:42:0640           1000:1000:0640
    sudo       0:0:4755           0:0:4755            1000:1000:0755
    X11        0:0:0777           0:0:0777            1000:1000:0777

**7 of 7 correct, and all 7 wrong in the control** (2026-08-09). The control is
what makes it evidence: if omitting the flag changed nothing, the pass would only
mean something else was supplying the ownership, and the script says so and fails
rather than claiming a win.

Look at the `sudo` row. Recovered without `--fake-super` you get a system where
`sudo` and `passwd` are **not setuid and owned by a normal user** — it boots, and
nothing can escalate.

**The copy is an encoded archive, not a browsable filesystem.** The symlink probe
was expected to fail, since Linux forbids `user.*` xattrs on symlinks. It passed,
and why matters more than that it did: rsync stores each symlink as an ordinary
placeholder file containing the link target, recording the real *type* in the
mode field — `120777`, where `0120000` is `S_IFLNK`. On the remote, `/usr/bin/X11`
is a 1-byte regular file containing `.`. Devices and special files work the same
way.

So anything that copies that tree without understanding `--fake-super` — `cp`,
`tar`, `scp`, or an rsync missing the flag — produces placeholder files where
symlinks belong and flattens every mode and owner, while looking like it worked.

### Two measurement mistakes worth not repeating

**`du -sb` answers a different question than "will this fit".** The pre-flight
used it and got 17.7G apparent, where the same tree occupies 18.3G of *allocated
blocks*. `-b` sums file sizes; what a destination must find is blocks. It now
uses `du -s -B1`.

**But that was not the whole story, and the rest is more interesting.** The
remote copy occupies **20.03G** against the source's 18.3G — identical content
(both report 17.7G apparent), yet 1.7G more on disk. Two wrong guesses first:

- *`--fake-super` xattr overhead?* No. A controlled test — the same 13,141 files
  copied with and without the flag — differed by **4096 bytes in total**, zero
  per file. The `user.rsync.%stat` value is ~35 bytes and fits inline in this
  filesystem's 256-byte inodes.
- *Expanded sparse files?* No. `lastlog` and friends are zero-length on both
  sides, and block sizes match at 4096.

**It is the symlinks.** `--fake-super` stores each one as a placeholder regular
file containing the link target — the same mechanism that makes `/usr/bin/X11` a
1-byte file over there. ext4 keeps short symlinks *inline in the inode* at zero
block cost; a placeholder costs a full 4K block. On one identical subtree:

    apparent    109,595,972  both sides
    files       local 11,755   remote 13,141      +1,386
    allocated   local 154,988,544   remote 160,649,216      +5,660,672

and `1,386 × 4096 = 5,677,056`. The subtree has exactly 1,386 symlinks. Across
both snapshots there are 384,866 readable ones — 1.47G at 4K, with root-only
subtrees excluded, which closes the gap.

**So a destination needs roughly 10% more than the source**, and the pre-flight
now says so explicitly rather than sizing against the source alone.

**`watch` reads `df`, not `du`.** The obvious implementation polls `du` on the
remote tree, which is ~1.5M stat calls and took ~40 seconds per sample — longer
than any sensible poll interval, so the watcher spent all its time measuring and
printed nothing. `df` returns instantly. The trade-off is that it tracks the
whole filesystem, so another writer on that host would look like progress.

### The failure that pointed at the wrong thing

The first `sudo push` died with *"cannot reach"*, immediately after an
unprivileged `status` had reported the host reachable. Wi-Fi was fine. Under
`sudo`, `$HOME` becomes `/root`, so ssh consulted `/root/.ssh/known_hosts`, which
had never seen the host — and `BatchMode=yes` cannot prompt to accept a new host
key, so it failed with `Host key verification failed`.

The script now points ssh at the *invoking user's* `known_hosts`, reusing trust
already established rather than disabling host-key checking, which is the other
common way to make this symptom disappear. The failure path also prints ssh's own
words now: **"cannot reach" was a conclusion presented as a diagnosis**, and it
sent the first investigation at the network, which was never the problem.

## `client-setup.sh`

    ./client-setup.sh HOST            # discover and show; writes nothing
    ./client-setup.sh HOST --write

`server-provision.sh` made the server a recipe. The client side was still two
hand-written files — `.offsite.conf` and `.home-backup.conf` — which meant
somebody had to know the host, the user, the paths and the repo name. Fine for
whoever built it, useless for anyone else.

**It asks the server rather than asking you.** `server-provision.sh` creates a
known layout, so this discovers it: where the snapshot store really is
(following the symlink), where restic repos live, and — importantly — whether
that store can hold the xattrs `--fake-super` depends on, because a store that
can't produces copies that look complete and restore a system owning nothing
correctly.

Validated against the config written by hand months earlier: it reproduces it
field for field.

**Two things it refuses to guess at.** The ssh key is found by *probing* which
key file actually authenticates, not by parsing `ssh -v` — when the key comes
from the agent, `Offering public key:` prints the key's *comment* rather than a
path, and the first version cheerfully wrote that into the config.
`snapshot-offsite.sh` passes it to `ssh -i`, where only a real path works.

**What it will not do, deliberately:** exchange ssh keys, join a tailnet, or set
the restic passphrase. Those are access decisions and a secret — and the
passphrase must never pass through this project, because the per-user design is
precisely what stops two people reading each other's backups.

## `server-provision.sh`

    ./server-provision.sh              # report only, changes nothing
    ./server-provision.sh apply
    ssh somehost 'bash -s' < server-provision.sh

`workshop/provision.sh` already makes the point for the kernel workshop: it is
not a machine, it is a recipe. The other half of what this project needs from a
server was never written down — and that half grew to hold the disaster-recovery
copy, the irreplaceable U810 media, and the encrypted user-data repo. So the
laptop could be rebuilt in twenty minutes while the machine that makes that
possible was an afternoon of remembering.

It reports the storage estate and **says which filesystems survive a disk
failure**, by reading `/proc/mdstat` rather than assuming:

    /        1.6T free   /dev/sdc4    single disk
    /home     404G free  /dev/md0p1   redundant: raid5

then puts the snapshot store and archives on the redundant filesystem with the
most room, reached through a symlink so configs naming the old path keep working.

**Redundancy is preferred, not required.** The disaster-recovery copy spent its
first days on the only disk with no redundancy — the copy that exists *because*
a disk might die, on a disk whose death would take it. Worth catching. But a
host may genuinely have one disk, and a copy on a single disk in another
building still survives the laptop dying, which is the point of it. Compare
`system-snapshot.sh`, which *does* refuse network targets: that rule is absolute
for a specific reason. This one is a preference, and preferences advise.

It also flags a large ext4 root reserve — 5% of a 3.6 T array is 186 GB doing
nothing on a data filesystem — and reports rather than changes it.

### Proven on a machine it had never seen

Tested by building a throwaway Ubuntu 24.04 cloud-image VM — the same distro
iteration8 runs — with three disks: one root and two blanks made into a real
`md` RAID1 inside the guest.

    provision      apply -> correct layout; BOTH redundancy branches exercised
    snapshot store a --fake-super tree received with metadata identical to
                   source: sudo still 104755 0,0 0:0
    restic repo    init, backup, check, and a restore that came back IDENTICAL
                   (451 files, byte for byte)

Not covered: the VM rig itself, which needs ~40 GB for target and carrier and
the guest had 17.

**It found two bugs the real server could not.** `redundancy_of()` reported a
genuine RAID1 as "unknown" — it stripped a partition suffix before checking
`/proc/mdstat`, so `md0p1` matched and a bare `md0` became `md` and matched
nothing. And `attr` was missing from the package list, so `getfattr` did not
exist; with `2>/dev/null` that is indistinguishable from absent metadata, and it
cost twenty minutes chasing a transfer that was fine. Both were invisible on
iteration8 precisely *because* it was configured by hand over months — it
already had everything.

**What it deliberately will not do:** ssh keys, tailscale membership, the restic
passphrase. Those are secrets and access decisions, and a provisioning script
that invents them is worse than one that lists them and stops. The passphrase in
particular lives on the *laptop's* keyring — the machine storing the backup
should not be able to read it.

## `preflight.sh`

The one command that ties the rest together. It runs **from the laptop** and does
the whole chain: snapshot this machine, push it offsite, rebuild it in a VM on
iteration8, run the update the laptop is about to run, and report a verdict with
the exact next steps.

    ./preflight.sh                    # the whole chain, about an hour
    ./preflight.sh --skip-push        # reuse the offsite copy as it stands
    ./preflight.sh --keep-holds       # do not lift the kernel holds in the VM
    ./preflight.sh --confirm-good     # AFTER applying and rebooting: re-baseline
    ./preflight.sh --dry-run

**Do not run it with sudo.** It refuses, and the reason is not fussiness: under
`sudo`, ssh reads `/root/.ssh/known_hosts`, which has never seen iteration8, and
`BatchMode` cannot prompt — so it fails as a network error that is not a network
error. The steps needing root call `sudo` themselves, and the push depends on
`SUDO_USER` pointing at *you* to find your SSH key.

**The snapshot it takes does two jobs, deliberately.** It is the input to the
test, so what gets tested is *this machine* rather than an approximation; and it
is the rollback point if the update goes badly on the metal. That is why the
order matters — it is taken before anything is applied.

**Long remote steps are detached and polled, not held open.** The restore and the
update each run 15–25 minutes, and holding one ssh connection that long *from
this laptop* invites the documented Wi-Fi lockup to eat a run that was otherwise
fine. A dropped connection costs a poll, not the run — and because `golden` is
marked with the snapshot it was built from, resuming with `--skip-push` skips the
restore entirely rather than repeating it.

### The verdict distinguishes two very different outcomes

A run where a **new kernel** arrived and one where **only packages moved** need
different advice, and conflating them is how you get told to boot-test something
that does not exist. When no kernel changed it says so and tells you no reboot is
needed — the four things a VM cannot test (Wi-Fi associating, camera, sound,
backlight) are only at risk from a kernel change.

Both paths tell you to **put the holds back** after upgrading. Leaving them
unheld removes the protection that stops a new kernel arriving unannounced, which
has been the procedure on this machine.

### `--confirm-good`, the other half

Run it *after* applying an update and rebooting. It checks the machine really is
good — `wl` loaded, Wi-Fi connected, `facetimehd`, no failed units,
`kernel-guard` clean — and **refuses to snapshot if `wl` is missing**. A snapshot
labelled "known good" of a machine that is not is worse than none: it is a
rollback point that restores the problem, and you find out on the day you need
it.

It needs mains power, like every other path that writes for minutes on an
eleven-year-old battery.

## `vm-restore-test.sh`

The offsite copy is verified faithful and the restore is proven on real hardware,
but neither answers the question that matters after a dead disk: **starting from
nothing but the offsite copy, can you rebuild a machine that boots?** This
rehearses exactly that in a VM, so finding out costs an evening rather than a
laptop.

    ./vm-restore-test.sh prepare      fetch the ISO, make disks, patch the initrd
    ./vm-restore-test.sh serve        rsync daemon that decodes --fake-super
    ./vm-restore-test.sh boot         launch the VM headless, serial on a socket
    ./vm-restore-test.sh restore      the whole restore unattended -> golden.qcow2
    ./vm-restore-test.sh testbase     golden.qcow2 + a serial console -> testbase.qcow2
    ./vm-restore-test.sh verify [IMG] boot it and check this project's fixes took
    ./vm-restore-test.sh verify-control
                                      prove those checks can fail
    ./vm-restore-test.sh update-test [--unhold] [PKG...]
                                      run the update the laptop is about to run,
                                      here first
    ./vm-restore-test.sh sh "CMD"     run a command in the guest
    ./vm-restore-test.sh bootdisk [IMG]
                                      boot a restored image (network restricted)
    ./vm-restore-test.sh screenshot   capture its framebuffer -- it has no serial console
    ./vm-restore-test.sh steps        the same restore by hand, and why each step is like that
    ./vm-restore-test.sh status       what exists, what is running
    ./vm-restore-test.sh stop|clean   teardown that never touches other VMs

**It runs on the machine holding the offsite copy**, not on the laptop — the
snapshot data is local there so nothing crosses Wi-Fi, and a 4GB laptop is a poor
VM host. `scp` it across and run it there.

**How long it takes: 15–25 minutes, once over 30, and the spread is real.** Watch
the step numbers rather than the clock, and do not kill a run for being slow.

The cause was chased and is now understood, which is worth recording because two
plausible explanations were wrong. It is **not** qcow2 first-write allocation
(falsified by a controlled repeat), and it is **not** contention from the other
VM on the host (its I/O counters were frozen at zero for an entire 21-minute
run). It is write buffering: iteration8 has 251 GB of RAM and a 20%
`vm.dirty_ratio`, so ~50 GB of dirty pages are permitted — more than the whole
restore writes. A run starting with cache headroom absorbs almost everything and
finishes in nine minutes; one starting with 180 GB already cached hits writeback
throttling partway and drops to disk speed. The floor is four 7200 RPM disks and
no SSD.

**Guest sizing for the restore is unproven.** 2 cpu / 4G took 21m00; 8 cpu / 16G
with 19 GB less written took 20m26. Twenty-six seconds. Wall-clock cannot see the
difference while writes are being buffered, and the run-to-run variance swamps
it. The generous sizing is kept because it costs nothing on a 32-core host, not
because it was shown to help. Worth retrying somewhere with different storage.

**`golden.qcow2` is ~22.6 GB rather than 19 GB** since sealing became a move
rather than a convert. The convert was compacting it; the move does not. That is
a deliberate trade — 19 GB less written on every build, ~3.6 GB more held
permanently — on a host with 1.5 T free.

**Run end to end on 2026-08-09, and it worked.** From nothing but the offsite
copy: 499,328 files pulled and decoded, Timeshift restored onto a blank virtual
disk, GRUB installed to a fresh ESP, and the VM booted UEFI off that disk to the
LightDM greeter — hostname `joe-MacBookAir`, user `Joe`, the right theme.

    pull      499,328 files, 19.02G, speedup 1.92 (hardlinks preserved)
    metadata  sudo -rwsr-xr-x 0:0 · shadow 0:640 0:42 · X11 a real symlink again
    restore   completed, exit 0; fsck clean, 741,886 files
    boot      LightDM greeter, "joe-MacBookAir"

The greeter offers `Joe` but `/home/joe` is empty, which is correct: these
snapshots are system-only. This restores *the machine*, not your files — those
live in the separate `~/backups/mba-home/` copy.

### `restore` — the same thing, unattended

That first run was six steps driven by hand over a serial console. Fine once,
useless as something to re-run whenever a snapshot changes. `restore` does the
whole thing and ends in **`golden.qcow2`**, a frozen image of the restored
machine:

    ./vm-restore-test.sh restore              # newest snapshot
    ./vm-restore-test.sh restore 2026-08-09_02-41-39

It reads the original root UUID and ESP volume id out of the snapshot's own
fstab, builds the disk to match, pulls the tree, seeds Timeshift's config, drives
the prompts with `expect`, checks the result and freezes the image. `steps` stays
as the by-hand version and the explanation of why each step looks like that.

**The work is detached inside the guest and this side only polls.** The serial
helper drains for a fixed number of seconds per exchange — it cannot recognise a
shell prompt or wait for one. So the driver runs under `setsid`, writes one line
to `/tmp/g.status` and its transcript to `/tmp/g.log`; the serial link carries
status, never the work. Steps shorter than the 20s poll go by unprinted, and
`sh 'cat /tmp/g.log'` has the rest.

**It pulls one snapshot, not the module.** The carrier is 30G and the offsite
copy is ~20G of hardlinked snapshots with a 38G apparent size, which a pull
expands. One snapshot is a complete tree by itself, and pulling it straight into
`timeshift/snapshots/` removes the `mv` the manual procedure needs.

It refuses rather than guesses if the snapshot's fstab mounts anything past `/`,
`/boot/efi` and the swapfile — it builds a two-partition disk, and a restored
system whose fstab names a filesystem nobody created boots to an emergency shell
and reads like a restore bug. And `clean` deliberately **keeps** `golden.qcow2`:
it costs an hour to make, everything downstream boots from it, and deleting it
there would make `clean` mean two different things depending on what had run.

#### Three things only a real run found

Two of them fail silently, which is why the first run had to happen:

- **`apt-get update` exits non-zero in the live session.** Its `sources.list`
  carries a `cdrom:` entry for the ISO, and that has no Release file when the VM
  boots via `-kernel`/`-initrd` instead of letting casper mount the disc. Every
  network list fetches fine. Drop the entry and gate on the *install*, which
  fails plainly if the lists never arrived.
- **Bash prints its bracketed-paste escape on the same line as the output.**
  `cat /tmp/g.status` returns `ESC[?2004lDONE:rc=10`, so anything anchored with
  `^` never matches. The first run polled to its full timeout against a guest
  that had already failed and was sitting there saying so. Strip
  `ESC[…[a-zA-Z]` along with the `\r`s before grepping a serial line.
- **A marker echoed back by the console matches before the command runs.**
  `guest "rsync … && echo PULLED" | grep PULLED` passes whether the rsync worked
  or not, because the link echoes the command text first. Spell it
  `echo P''ULLED` and only the shell's own output matches.

And one from driving it rather than from the script: **`pkill -f "…restore"`
killed the ssh session that issued it**, the pattern being in its own command
line. This script's header already warns about that for `pgrep`; use a character
class — `rest[o]re` — so a pattern cannot match itself.

### `testbase` — an image you can ask questions

A restored system booted from disk is **silent on the serial port**: its
`grub.cfg` came from a laptop that boots to a screen. `screenshot` is fine for a
human and useless as a verdict — a kernel test has to ask `uname -r`,
`modprobe wl` and `systemctl --failed` and read the answers back.

    ./vm-restore-test.sh testbase
    ./vm-restore-test.sh bootdisk testbase.qcow2

`golden.qcow2` is left alone, because its one job is to be exactly what the
snapshot restores to — edit it and it stops being evidence. `testbase.qcow2` is a
qcow2 **overlay** on it, and the whole divergence costs **2.7M over a 19G base**:

    golden.qcow2       faithful restore, untouched
      └─ testbase.qcow2     + serial console, + autologin  (2.7M)
           └─ candidate overlays, made and thrown away per test

That is not a theoretical tidiness argument. The first attempt wrote the settings
to the wrong file, and the fix was `rm testbase.qcow2` and start again — with
`golden` never at risk.

Everything that differs from the laptop is in **one file**,
`/etc/default/grub.d/99-vmtest.cfg`. It boots verbose (`quiet splash` dropped)
because a failed boot that prints nothing is the one outcome the rig exists to
diagnose.

#### Two more traps, both silent

- **`/etc/default/grub` is not the last word on Mint.** `grub-mkconfig` sources
  `/etc/default/grub.d/*.cfg` afterwards, and Mint ships `50_linuxmint.cfg`
  setting `GRUB_DISABLE_OS_PROBER=false`. The setting was written into the main
  file — correctly, twice — and os-prober ran regardless. Anything that must win
  goes in a `99-` fragment.
- **`update-grub` in a chroot probes the *build host's* disks.** With `/dev`
  bind-mounted, os-prober found `Ubuntu 24.04.4 LTS on /dev/sdc4` — iteration8's
  own root — and wrote boot entries for it into the image. `testbase` now
  verifies this rather than trusting it, and does so without naming any
  host-specific device: every UUID `grub.cfg` searches for must belong to the
  image, and anything else is a leak.

#### What a healthy image looks like

Worth knowing before it's used as a verdict, because two of these read as
failures and are not:

| check | healthy answer | why |
| --- | --- | --- |
| `lsmod \| grep wl` | **0** | nothing autoloads `wl` — there's no BCM4360 to match. A test must modprobe explicitly, or it reports a false failure forever |
| `modprobe wl` | loads, pulls in `cfg80211` | the strong signal: the module links against *this* kernel. Stronger than "DKMS exited 0", short of "Wi-Fi works" |
| `systemctl --failed` | **0** | `testbase` supplies the swapfile Timeshift excludes, so anything failed at all is real signal |
| `systemctl is-system-running` | `running` | not `degraded` — see below |
| `swapon --show` | `/swapfile` at **-1**, `/dev/zram0` at **100** | both come back, priorities intact |

**Why `testbase` creates a swapfile.** The laptop's `/swapfile` is 3960M and its
fstab references it, but Timeshift *excludes* the file — so a restored system
carries the entry and not the file, and `swapfile.swap` fails on every boot
forever. Supplying one makes the baseline **zero failed units**, and that is
worth more than tidiness: "nothing failed" is a verdict that cannot rot, where
"exactly one failed, and it must be that one" quietly stops being true the first
time anything else legitimately changes and nobody notices.

`golden.qcow2` deliberately still fails that unit. The failure is honest evidence
that these snapshots are system-only, and the place to paper over it is the test
image, not the record of what the restore produced.

`fallocate` turned out to be enough — `swapon` accepted it and the overlay stayed
**4.0M**, because a qcow2 grows only on real writes. The `dd` fallback stays in
for an image that refuses unwritten extents.

### `verify` — does everything this repo installs still work?

    ./vm-restore-test.sh verify              # 21 checks, ~3 minutes
    ./vm-restore-test.sh verify-control      # prove they can fail

The rig does **not** reimplement the helpers' checks. Several already have
`check`/`status` subcommands, and a second implementation would drift from the
first and start grading the wrong thing — so `testbase` plants the repo at
`/opt/mba-verify` and `verify` runs the real ones. (`/home` is empty in these
snapshots, so the repo isn't in the image and has to be put there.)

The checks live *in the guest* rather than being driven one at a time over
serial: a dozen round trips cost minutes, and a remotely-driven check can only
grade what fits in one line of output. In the guest they can run a helper and
read its report.

| tier | proves | needs |
| --- | --- | --- |
| **artefact** | the file/rule/firmware survived the restore | nothing |
| **mechanism** | it builds, it loads, the rule matches and acts | a VM |
| **device** | Wi-Fi associates, the camera captures, sound comes out | metal — **not guessed at here** |

What it checks, all 21 passing on a healthy image:

    artefact   facetimehd firmware, kbd-backlight rule, webcam tune rule,
               kernel-guard apt hook
    dkms       broadcom-sta and facetimehd built for the running kernel
    load       wl and facetimehd both load with no hardware present
    module     applesmc is shipped (see below)
    rule       udev acts on a SYNTHETIC smc::kbd_backlight
    helper     kernel-guard check, kbd-backlight status
    audio      card, driver, playback, capture, PCM open, userspace (see below)
    system     which kernel was booted, no failed units, both swap tiers up

**`applesmc` is graded differently, and has to be.** It *refuses* to load without
an Apple SMC — `No such device` — where `wl` and `facetimehd` load happily and
simply bind nothing. So the honest check is that the kernel ships it; whether it
binds is a tier-3 question. Grading it like the others would produce a permanent
false failure on the one driver whose bug was already chased once.

**The keyboard-backlight fix is tested for real, without an SMC.** `uleds` makes
a synthetic LED named exactly what `applesmc` would have registered, and udev is
asked what it does with it:

    smc::kbd_backlight: 60-applesmc-kbd-backlight.rules:8
        ATTR '/sys/devices/virtual/misc/uleds/smc::kbd_backlight/trigger' writing 'none'

Note it is `udevadm test` that is the evidence, **not** the resulting trigger
value — a fresh `uleds` LED defaults to `none` anyway, so reading the attribute
back would "pass" with the rule deleted.

#### `verify-control`, because 14 passed is not evidence

A verifier nobody has seen fail is an assumption with a progress bar. This repo
already works this way — `restore-test.sh` grades an *unchanged* control,
`pull-test` got 7/7 right with all 7 wrong in the control — so `verify-control`
breaks three artefacts in a throwaway overlay and asserts exactly the right
checks go red:

    broke 3 files  ->  5 checks failed, 9 unrelated stayed green

Five, not three, and that is the point: `rule:kbd-backlight` and
`helper:kbd-backlight` catch the missing rule through **behaviour** — udev acting
on a synthetic LED, and the helper's own report — rather than by re-reading the
file the artefact check already read.

Two bugs came out of building it, both of the "passes for the wrong reason"
family this project keeps finding:

- **`bootdisk` reported success on a VM that never started.** It waited for the
  QEMU monitor socket, and QEMU creates that *before* opening the drives — so a
  root-owned image gave a socket, a dead process, and a three-minute wait for a
  login that could never come. It now checks the pid is alive.
- **A failure message that read like a pass.** `helper:kbd-backlight` dumped the
  first 90 characters of the helper's output, which put `trigger none` in the
  failure line. It now reports which assertion failed —
  `trigger-is-none=yes rule-installed=no`.

### `update-test` — run the update here before the laptop sees it

    ./vm-restore-test.sh update-test              # what the machine would run
    ./vm-restore-test.sh update-test --unhold     # ...if the kernel holds were lifted

It runs **the real upgrade**, not a hand-picked `apt-get install`. Installing a
kernel by hand proves a kernel can be installed; it does not exercise the apt
hook, the DKMS triggers, the initramfs rebuild or `update-grub`, which is where
an update actually goes wrong.

The two VM phases have exactly the properties the two halves need:

| phase | has | does |
| --- | --- | --- |
| live ISO | a network, **no identity** | chroot into the candidate, run the upgrade, build DKMS |
| disk boot | the laptop's identity, **no route** | stays `restrict=on`; boots it and re-runs `verify` |

Giving the disk boot a network so apt could run there is precisely what steals
the laptop's tailnet node key. The upgrade lands in `candidate.qcow2`, an overlay
— so the baseline never moves and the same update can be tested repeatedly from
where the laptop actually is.

**Proven end to end on `6.17.0-42`:** 10 packages upgraded, `broadcom-sta` and
`facetimehd` both built for the new kernel, one-shot boot into it, and 15/15
checks *about that kernel*.

#### Five findings, four of which were the tool lying

- **The kernel packages are on hold, and that is the procedure.** `mba-wifi.sh`
  holds them to keep a known-good fallback installed. So `update-test` found
  nothing to do — correctly. `--unhold` lifts them **in the candidate overlay
  only**, answering the question the hold exists to defer: *would it be safe to
  lift this?* On the laptop you would lift only the meta-packages and leave the
  specific `linux-image-6.17.0-4x` holds in place, since those are the fallback.
- **A no-op upgrade produced a green "safe to apply".** An untouched image passes
  every check. It now reports `CHANGED: no` and exits 2 without a verdict.
- **Phased updates are keyed on the machine-id, which a clone inherits.** So the
  VM declines an update for exactly the same reason the laptop does — a
  pre-flight rig built from a clone is by default *as blind as the machine it
  protects*. Forced in with `APT::Get::Always-Include-Phased-Updates`. (This is
  the tailnet-identity problem again, one layer down.)
- **GRUB boots the newest kernel, which is usually not the candidate.** A
  6.17-series update sits below the 7.0 kernel, so the first working run booted
  `7.0.0-28` and cheerfully re-graded a kernel already known good. It now arms a
  one-shot with the project's own `kernel-guard boot-test` — which *refuses to
  arm* a kernel with no `wl`, so a stranding candidate cannot even be selected —
  and then checks armed-against-booted, because assuming the one-shot took is how
  you get a confident verdict about the wrong kernel.
- **The apt hook cannot be tested by looking for its output.** It runs
  `kernel-guard check --quiet-ok`, and `--quiet-ok` means *print nothing when
  fine* — so on a healthy machine silence is success and grepping for it reports
  "never fired" every time. What is worth testing is its guard: the hook is
  wrapped in `if [ -x /usr/local/bin/kernel-guard ]`, so if that binary goes
  missing the hook does nothing **for ever, silently, indistinguishable from
  having run and approved**.

Two mechanical ones worth keeping: `umount` without `-R` leaves a submount and
the parent reports `target is busy` with **no process holding it** — `fuser`
shows only `kernel mount`, sending you after a process that does not exist. And
the rsync daemon is now started *immediately before the guest fetches from it*
rather than before a 90-second boot, because a long window is one in which
anything that tidies stray processes takes it away, intermittently.

#### Audio is the one area with a usable stand-in

Wi-Fi and the camera can only be *built* in a VM. Audio can be **exercised**,
because QEMU emulates an HDA controller — `bootdisk` gives the guest
`ich9-intel-hda` with `-audiodev none`, so it gets a real controller on a
headless host and the samples go nowhere.

    audio:card        Intel                         controller found
    audio:driver      snd_hda_intel loaded and bound
    audio:playback    card 0: Intel [HDA Intel], device 0: Generic Analog
    audio:capture     a capture device is present
    audio:pcm-open    opened hw:0,0 and wrote a second of samples
    audio:userspace   pipewire/wireplumber installed

`audio:pcm-open` is the one that matters. Enumeration proves a device node
exists; opening the PCM and writing to it proves the path works, and it is the
one check a broken stack cannot fake.

**What this does not and cannot test:** the laptop's codec is a Cirrus CS4208
and QEMU's is generic, so codec-specific behaviour — jack detection,
speaker/headphone routing, the `model=` quirks Macs so often need — is out of
reach. And PipeWire is a per-user service with no session to run in behind a
serial root login, so `audio:userspace` checks presence only. Claiming more would
be inventing a result.

**Proven able to fail.** `MBA_VMTEST_NO_AUDIO=1 ./vm-restore-test.sh verify`
takes the card away: the five hardware checks go red and `audio:userspace`
correctly stays green, being a package check. Without that control they would
only ever prove that qemu was asked for a sound card.

### `usb-image` — test on the real machine without touching its disk

    ./vm-restore-test.sh usb-image [IMAGE]

The VM can prove an update installs, builds its modules and boots. It can never
prove Wi-Fi associates, the camera captures or the backlight lights — there is no
BCM4360, no FaceTime HD and no Apple SMC to emulate. This writes a VM-approved
image to a USB disk so that last mile can be tested on real hardware **with the
internal disk untouched**: failure costs an unplug rather than a rollback.

**It rewrites every identifier, and that is not optional.** A raw copy keeps the
original's UUIDs, and a USB disk in the same machine is the definition of a disk
that coexists with the original — two filesystems sharing a UUID make mounts
non-deterministic, and then a kernel install writes to the *internal* ESP you
were trying to protect.

    root   a fresh filesystem UUID (tune2fs -U), fstab and grub.cfg follow
    GPT    fresh disk and partition GUIDs (sgdisk -G)
    ESP    fstab switches to PARTUUID=, since changing a FAT volume id in place
           needs mtools, which is not installed

It also strips the VM-only bits, so what boots is a laptop with the update
applied rather than a test rig.

**Practicalities, and how to need a smaller stick.** `convert -O raw` writes the
full *virtual* size including the zeros, not just the data. The default build is
40 GiB holding 19.7 GiB, so it needs a **64 GB** target. The size is not fixed —
the restore partitions with `-n2:0:0`, so the root simply fills whatever it is
given:

    MBA_VMTEST_TARGET_GB=26 ./vm-restore-test.sh restore --force

That produces an image that fits a **32 GB** stick (allowing for the gap between
a "32 GB" stick and its 29.8 GiB of real space), with the root about 77% full.
Raising the size later is free; setting it below what the snapshot holds makes
the restore fail, so leave headroom. Prefer a USB 3 SSD over a stick either way
unless you enjoy waiting. The ESP already carries
`/EFI/BOOT/BOOTX64.EFI`, so Apple's boot picker will list it when you hold
Option; that missing fallback path is the usual reason a hand-rolled USB never
appears.

**Not yet run.** It is also the only thing in this repo that writes to a block
device, so its first use deserves supervision.

**zram needs no help at all.** `/dev/zram0` comes back with the restore at
priority 100, ahead of the disk swapfile at -1, because it is configured on the
system side and is pure software — there is no hardware for a VM to be missing.
So the guest inherits the laptop's real two-tier arrangement rather than an
approximation of it, which matters the moment anything is *built* in here: zram
is a compression window, not extra capacity, and the disk swapfile is the
backstop for when it stops helping.

### The clone fights the original for its identity

**This is the most important thing the rehearsal found, and it cost an hour of
diagnosing the wrong machine.**

A restored snapshot is not a copy of your system, it is a **second instance of
its identity**. Machine identity lives on the system side and therefore comes
back with the restore: `/var/lib/tailscale/tailscaled.state` (the tailnet **node
key**), `/etc/machine-id`, `/var/lib/dbus/machine-id`, the SSH host keys.

Boot that clone with a route to the internet and its `tailscaled` registers using
the **same node key as the laptop it was cloned from**. The coordination server
treats them as one node and follows whoever reported last, so **the original gets
knocked off its own tailnet.** It presents exactly like the remote host having
died: ssh times out, `tailscale ping` gets no reply, other peers fail too. It
happened twice here and both times the conclusion looked obvious and was wrong —
iteration8 was up the whole time, `up 3 days, 21:06`.

Killing the clone restored the laptop **instantly**, with no tailscale restart.
That is the proof: intervention on the clone fixed the original.

In a genuine recovery this never arises — the original is dead, which is why
you are restoring. It arises only in rehearsal, where both are alive. So
`bootdisk` runs the restored system with `-netdev user,restrict=on`: a working
NIC and DHCP lease, but no route off the host. **Never give a restored clone real
network access while the original is running.** A test that sabotages the machine
it is testing for is worse than no test.

### Timeshift maps mount points from the snapshot's own fstab

Restoring to a blank disk aborted with `Data will be modified on: <empty>` and
**no error message** — just an immediate exit after the confirmation prompt.
`--target` does not populate that mapping. Timeshift builds it from the
**snapshot's `/etc/fstab`**, matched by UUID, and on a fresh disk nothing matches
and `/boot/efi` has no candidate at all.

The log shows it does ask — `Select '/boot/efi' device (default = /dev/sda1):` —
so one fix is to **answer those prompts with device names**, which works on any
replacement disk and needs nothing known in advance.

The other is to **give the new disk the original UUIDs**, and it earns its keep
for two reasons. `fstab` is not the only place UUIDs appear — `crypttab`, the
hibernation resume device and anything hand-written in `/etc` carry them too, and
while Timeshift runs `update-grub` nothing sweeps the rest. Match them and every
reference is correct by construction. It is also the only way to make recovery
**unattended**, since the prompts then have correct defaults.

Those UUIDs exist nowhere but the snapshot once the disk is gone, so
`snapshot-offsite.sh disk-plan` reads them out of its fstab and prints the exact
commands:

    sudo mkfs.ext4 -U b96739a5-34c1-403b-b440-80df9aa71a03 /dev/sdXN   # /
    sudo mkfs.vfat -F32 -i 1AE41280 /dev/sdXN                          # /boot/efi

**Never do this to a disk that will sit alongside the original.** Two filesystems
with one UUID make `blkid` ambiguous and mounts non-deterministic — you can boot
the wrong disk. Replacement in a dead machine: fine. Spare in a live one: no.
It is the same hazard as a restored clone stealing the original's tailnet
identity, one layer further down — **duplicated identity is safe only when the
original is gone.**

Driving those prompts needs `expect`, not `yes`. The sequence is `Press ENTER`,
then two `(y/n)` — so `yes` answers half of them wrongly and `yes ""` answers the
other half wrongly. (`debconf-set-selections` is the tool for *apt* prompts;
Timeshift rolls its own stdin loop and debconf has nothing to do with it.)

Three things had to be solved to make it headless and scriptable, and each one is
the kind of thing that is miserable to rediscover:

**qemu's `-kernel` direct boot does work alongside UEFI firmware.** That matters
because the VM must boot EFI — the laptop does, and the ESP is part of what gets
restored — but a UEFI boot menu needs a screen. Direct boot lets us pass
`console=ttyS0` and `systemd.unit=multi-user.target`, giving a text-mode live
session on a serial port instead of a desktop.

**The live session cannot be logged into, and guessing passwords is a dead end.**
Mint 22.3's live user is `linux` with the password hash `U6aMy0wojraho` — which is
`crypt("")`, so "empty password" looks right. It isn't: `pam_unix` without
`nullok` rejects an *entered* empty password before it ever compares the hash. The
fix is to bypass PAM's password path entirely, so `prepare` unpacks the ISO's
initrd, patches casper's own `15autologin` hook to also write a serial-getty
autologin drop-in, and repacks it. That single step is most of why this script
exists.

**A `--fake-super` archive can only be decoded by a sender that knows about it**,
and a local copy has no remote sender to tell. Sharing the directory into the
guest would not help for the same reason. An **rsync daemon with `fake super =
yes`** is the documented answer: it decodes on the way out, needs no ssh keys or
passwords, and binds to loopback. From inside the guest the host is always
`10.0.2.2` under user-mode networking. `serve` proves the decoding works by
checking `sudo` is still `-rwsr-xr-x` over the wire, rather than assuming.

The teardown is deliberately narrow: it only ever kills the pid in its own
pidfile, and `status` names any other qemu on the host as *not ours*. That host
runs a long-lived batocera VM, and a stray `pkill` would have taken it out —
`pgrep -f` matching this script's own command line already killed one session
during development.

## `sysfs-watch.sh` and `who-writes.sh`

Two general tools that came out of the keyboard backlight hunt above, kept
because the next mystery on this machine will look much the same: a value
changes, and nothing says what changed it.

### `sysfs-watch.sh` — when did it change, and what was running

Polls any sysfs attribute and logs each change with a timestamp, the uptime,
and the twenty most recently started processes.

    ./sysfs-watch.sh /sys/class/leds/smc::kbd_backlight/brightness --detach
    ./sysfs-watch.sh /sys/class/power_supply/BAT0/status --seconds 3600 --detach
    ./sysfs-watch.sh <attr> --at-boot 600        # then --at-boot-off to remove

The two flags are the whole point. `--detach` outlives logout, which works
because logind's `KillUserProcesses` is at its default of `no`. `--at-boot`
installs a `@reboot` crontab entry, which is the only way to be watching
*before* a login when the login is the suspect — a session autostart is already
too late. It rewrites the crontab through a filter so the existing
`rescue-status.sh` entry survives; verified by installing and removing.

It names the neighbourhood, not the culprit. That is often enough to decide
what to reach for next; when it is not, use the other one.

### `who-writes.sh` — what actually wrote it

Traces `kernfs_fop_write_iter`, the single funnel every sysfs write passes
through, filtered in-kernel to one file. Needs `bpftrace` and root.

    sudo ./who-writes.sh /sys/class/leds/smc::kbd_backlight/brightness \
         --run 'systemctl restart fwupd'
    sudo ./who-writes.sh <attr> --probe applesmc_brightness_set --run '...'

**Both outcomes are answers.** Events printed means a process wrote the file,
with pid, comm and stack. Nothing printed *while the value changed anyway*
means no userspace process wrote it at all — which is the finding, not a failed
run: stop accusing processes and go look at the driver, with `--probe` on its
setter to get the kernel stack. Recognising that case an hour earlier would
have saved an hour on the backlight.

### Two rules these encode

**Read the stack, not `comm`.** If a write happens in a softirq or interrupt,
the pid is whatever was running on that CPU. The backlight trace said `fwupd`
and sent this on a bisection of 130 fwupd plugins; the frame that mattered was
`led_timer_function`, four lines further up.

**Verify the instrument before believing the result.** A bisection whose toggle
silently failed to apply still produced a confident conclusion — `DisabledPlugins=`
never took effect, and the run reported "plugins ruled out" while the journal
plainly showed plugins still loading. `who-writes.sh` refuses to start the clock
until bpftrace reports its probes attached, for the same reason.

## `module-patch-test.sh`

Test a patch to a one-file kernel module on the machine that actually has the
hardware, with a control condition and a restore that always runs.

    sudo ./module-patch-test.sh --module NAME (--patch FILE | --sed EXPR) \
         --check CMD [--setup CMD] [--teardown CMD] [--provoke CMD] [--prepare CMD]

Generalised from `applesmc-patch-test.sh` after that one proved the backlight
fix. The shape recurs on old hardware: the fault is in a driver, the driver is
one `.c` file, and the only machine qualified to judge the fix is the broken
one. What the tool contributes is the two checks it is easy to skip.

**The control condition.** By the time you have a patch you usually have a
workaround too, and a workaround reaches the same end state whether or not the
patch does anything. So the stock module is loaded first and the fault *must*
reproduce; if `--check` passes there, the run aborts rather than grading its own
homework. `--setup` exists to disable the workaround for the duration — omit it
and the abort is exactly what you get.

**The srcversion check.** `srcversion` is a hash over a module's source, so
building the untouched upstream file and comparing against the running module
answers two questions at once: whether the distro patches this driver, and
whether the module really is a single `.c` file. A mismatch means your source
set is wrong and the test would be meaningless, so it stops.

Verified by re-running the applesmc case through it end to end: same control
failure, same pass, same patched srcversion `AF9F6279C4AFB73358F535A` as the
purpose-built script produced.

One sharp edge it cannot smooth over: reloading a module resets state the module
owned — for applesmc the LED drops to 0 — and the tool has no way to know which
of that you cared about. Restore it in `--teardown`, which deliberately runs
*before* the stock module is loaded again, so anything acting on the module's
add event (a udev rule, most likely) is back in place in time to apply.

## `workshop/`

A kernel build and bisect host, living on **iteration8** at
`/srv/kernel-workshop`. It has [its own README](workshop/README.md), deployed to
that machine as well so `cat /srv/kernel-workshop/README.md` after an ssh tells
you everything.

| | |
| --- | --- |
| `provision.sh` | Build the whole workshop from nothing on any Debian/Ubuntu host. Idempotent. |
| `capture-target.sh` | **Run on the vintage machine.** Records its config, loaded modules, DKMS modules and interfaces. |
| `kbuild.sh` | **Run on the build host.** Builds installable debs for a target profile at a git ref. |

The setup is scripted rather than hand-built on purpose: reproducing it
elsewhere — including in a VM — is `provision.sh` plus somewhere to run it.

Two things it insists on, both learned the hard way and written up there in
full: **the build happens on the fast machine and every verdict comes from the
old one**, and **a test kernel outranks distro kernels in GRUB permanently**, so
remove it once it has answered its question.

Reach iteration8 by its **tailnet** name — the bare `iteration8` ssh alias
points at a `.local` name that resolves only on its own LAN.

## `WIFI.md`

The history behind `mba-wifi.sh`: the July 2026 kernel panic that led to
blocking 7.x, the trial that lifted it, why the objtool bypass exists and why it
is scoped to 7.x, and what is known versus assumed about the lockups.

Read it before touching Wi-Fi on this machine. It is kept because the reasoning
is not recoverable from the scripts, and because a session that does not know
the history reliably re-derives it wrongly — which has happened.

The lockup trigger is now corroborated: **bursts of concurrent connections**, not
throughput. A /24 sweep opening 254 sockets hard-locks the whole laptop; batches
are capped at ~24 in the batocera-watch project as a result. That also confounds
the power-save experiment currently running, which the file says plainly so
nobody credits the wrong change months from now.

## `SNAPSHOTS.md`

The rollback decision on this machine, with the measured numbers, what it leaves
uncovered, and where it was left.

The short version: a snapshot on another host is unreachable in the exact
scenario it was installed for, because the likeliest bad update here costs you
the only network interface. So rollback is `apt-rollback.sh` when you know what
changed, and a **local** `system-snapshot.sh` when you do not — never a remote
snapshot target.

It also records the restore test of 2026-08-08 — 6 of 6 checks passed — and the
two findings that only surfaced by running it on the real hardware: the restore
crosses into the EFI system partition despite `--skip-grub`, and it rewinds
`/var/log/apt/history.log`, which is `apt-rollback.sh`'s only input.

## Prior art, and claims checked against this machine

Other write-ups for this hardware. Each one's advice was tested here rather than
repeated, because most of it is copied between guides without being re-checked.

| Source | Scope |
| --- | --- |
| [BrBorghi/linux-mint-22-macbook-air-2014-guide](https://github.com/BrBorghi/linux-mint-22-macbook-air-2014-guide) | Closest match — 2014 Air on Mint 22, prose steps. Also covers non-US keyboard layout and AirPods, which this repo does not. |
| [hsnuc09/bcm4360-fix](https://github.com/hsnuc09/bcm4360-fix) | BCM4360 only, on the kernel 6.17 build failure. |
| [jamieede123/macbookair6-1-mint-tweaks](https://github.com/jamieede123/macbookair6-1-mint-tweaks) | Battery/performance on the 11" **6,1**, same 4GB and distro. |
| [Debian wiki: MacBookAir 6-2](https://wiki.debian.org/InstallingDebianOn/Apple/MacBookAir/6-2) / [6-1](https://wiki.debian.org/InstallingDebianOn/Apple/MacBookAir/6-1) | Per-component reference tables. |
| [patjak/facetimehd](https://github.com/patjak/facetimehd) | The camera driver itself. |

### Checked, and not needed here

- **`intel_iommu=off`** — presented as a required boot parameter for this model.
  This machine has never set it (`/proc/cmdline` is just `quiet splash`) and the
  camera works, so it is not a prerequisite. It may still matter on a 6,1.
- **`sudo apt install facetimehd-dkms facetimehd-firmware`** — offered as the
  easy alternative to building the driver. **Those packages do not exist in
  Ubuntu 24.04 or Mint 22** (`apt-cache search facetimehd` returns nothing);
  they are Debian-only. Following that advice leaves you with no camera and no
  error explaining why, which is the reason `mba-webcam.sh` exists.
- **`mem_sleep_default=deep`** — recommended to stop overnight battery drain.
  Already the default here: `/sys/power/mem_sleep` reads `s2idle [deep]`, so the
  parameter changes nothing on this kernel.
- **Switching the trackpad to `xserver-xorg-input-synaptics`** — the Debian wiki
  rates the trackpad as working out of the box with taps, two-finger scroll and
  tap-to-drag, which matches this machine under libinput.

### Checked, and worth knowing

- **`acpi_osi=!Darwin` was the one real gap, and it is now applied here.**
  Before, the only backlight interface was `acpi_video0` with
  `max_brightness=100`. After adding the parameter, `acpi_video0` is gone and
  `intel_backlight` appears with `max_brightness=2777` — about 27× finer, and
  the brightness keys drive it. The Debian wiki also credits it for slow display
  wake from sleep.

  ```sh
  sudo cp /etc/default/grub /etc/default/grub.bak.$(date +%s)
  # single quotes matter: ! is history expansion in interactive bash
  sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash acpi_osi=!Darwin"/' /etc/default/grub
  sudo update-grub
  ```

  It is still a boot-path change on a machine whose display and Wi-Fi you least
  want to break, so keep the backup. If the display misbehaves, press `e` at the
  GRUB menu, delete `acpi_osi=!Darwin` from the `linux` line and `Ctrl-X` to boot
  once without it; restore the backup and `update-grub` to make that permanent.

  Verified after the change, on **kernel 7.0.0-28** — the riskiest combination
  here, since that is where `wl` is most fragile: Wi-Fi associated with v4 and v6
  addresses, and the camera up on `/dev/video0` with zero `IO: timeout`.
- **The shipped Broadcom driver now carries its own kernel fixes.**
  `broadcom-sta-dkms 6.30.223.271-23ubuntu1.2` is in `noble-updates/restricted`
  (no `-proposed` needed) and its changelog lists patches for kernel 6.15, 6.16
  and 6.17, including `42-broadcom-wl-fix-linux-6.17.patch` (LP #2120508).
  **This is not the same bug** as the objtool rejection this repo works around
  (LP #2161038, kernel 7.x). Those patches fix *source-level* API breaks;
  objtool is rejecting Broadcom's precompiled blob, which no source patch
  reaches. Tested directly, with the bypass removed, on `23ubuntu1.2`:

  | Kernel | Build with objtool enabled |
  | --- | --- |
  | 6.17.0-41 | clean — `wl.ko` produced |
  | 7.0.0-28 | `wl.o: error: objtool: aes_cbc_encrypt_pad+0x4c: unannotated intra-function call` |

  So the bypass is still required, and only on 7.x. `mba-wifi.sh` therefore
  scopes it rather than applying it to every build:

  ```sh
  MAKE[0]="make KVER=$kernelver $([ "${kernelver%%.*}" -ge 7 ] 2>/dev/null && echo objtool=/bin/true)"
  ```

  `dkms.conf` is sourced as shell with `$kernelver` set, so this is evaluated per
  build. If `kernelver` is ever unset the test fails, stderr is discarded, `&&`
  short-circuits and `MAKE[0]` comes out clean — failing toward a loud 7.x build
  error rather than a silently unvalidated 6.x module.

  `6.30.223.271-29ubuntu1` is reported to fix 7.x properly, but it is not in
  noble — `apt-cache madison` offers only `23ubuntu1` and `23ubuntu1.2`.
- **AirPods need `ControllerMode = bredr`** in `/etc/bluetooth/main.conf`. Not
  tested here, recorded because it is a real and non-obvious workaround.

## License

Released into the public domain under [the Unlicense](LICENSE). No conditions,
no attribution required.
