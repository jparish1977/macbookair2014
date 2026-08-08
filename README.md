# macbookair2014

Scripts for running Linux Mint 22.x / Ubuntu 24.04 on a 2014 MacBook Air
(MacBookAir6,1 / 6,2 — Haswell, 4GB RAM, BCM4360 Wi-Fi).

> **These run as root and change system configuration.** Read them before you
> run them. They are written for a specific machine and a specific distro; on
> anything else, treat them as a reference rather than something to execute.

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

Local patches against the pinned upstream driver, applied to
`/usr/src/facetimehd-$VER` before the DKMS build.

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
