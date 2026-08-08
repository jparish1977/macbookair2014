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

## License

Released into the public domain under [the Unlicense](LICENSE). No conditions,
no attribution required.
