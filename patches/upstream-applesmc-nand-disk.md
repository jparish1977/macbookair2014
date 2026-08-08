# Upstream draft: drop the nand-disk default trigger from applesmc

**Status: draft, not sent.** This is a submission package, not a patch to apply
locally — the local fix is `kbd-backlight.sh install`. Nothing here goes
anywhere until you decide it does.

The one-line change is trivial. Everything below exists so that if a maintainer
pushes back, the answer is already known and checked.

## What is verified, and how

Every claim the patch makes was checked on this machine or against the current
tree. None of it is recalled or assumed.

| Claim | How it was verified |
| --- | --- |
| The line is in mainline today | Fetched `drivers/hwmon/applesmc.c` from `torvalds/linux` master, 2026-08-08; it is line 1071 |
| It came in with the driver | Commit `6f2fad748ccced5b9313efce2a2c7ae4c04ef564`, "Apple SMC driver (hardware monitoring and control)", Nicolas Boichat, 2007-05-08 — fetched the commit's own patch and grepped it |
| First released in v2.6.22 | `applesmc.c` absent from the v2.6.20 and v2.6.21 tags, present with the line in v2.6.22 |
| `nand-disk` is an MTD trigger | `drivers/leds/trigger/ledtrig-mtd.c` registers `mtd` and `nand-disk`; `ledtrig_mtd_activity()` calls `led_trigger_blink_oneshot()` |
| The blink ends at 0 | bpftrace stack, below — `applesmc_brightness_set value=0` called from `led_timer_function` |
| This machine has an MTD device | `/proc/mtd` shows `mtd0 "BIOS"`, 8MB; `0000:00:1f.0` → `intel-spi` → `spi-nor`; dmesg: `Creating 1 MTD partitions on "intel-spi"` |
| The SSD is not involved | Root disk is `sda`, SATA, `APPLE SSD SD0128F` — not an MTD device, so normal disk I/O never fires the trigger |
| fwupd is what touches it | `systemctl restart fwupd` reproduces the fault on demand |
| Nobody has reported this | lore.kernel.org search for `applesmc nand-disk`: 38 results, all the 2007 driver submission, the 2007 heartbeat crash fix, René Rebe's 2008 case-LED patch, and unrelated stable-release noise |
| Detaching the trigger fixes it | `trigger` set to `none` via udev rule; survives reboot and an fwupd restart |
| **The distro ships stock upstream source** | `applesmc.c` built from the `v7.0` tag has srcversion `4B4E296F44EBB1541BCA045` — identical to the shipped `applesmc.ko`. Same srcversion means same source, so the driver under test *is* mainline's |
| **The patch itself was built and loaded** | Patched build (`AF9F6279C4AFB73358F535A`) `insmod`ed on this hardware |
| **With a control condition** | Rule moved aside + stock module reloaded reproduced `[nand-disk]` first, so the subsequent `[none]` means something |
| **The patched driver holds the level** | 204 set, `systemctl restart fwupd`, still 204 |

Hardware and kernel actually tested on:

    MacBookAir6,1, Apple Inc., BIOS 430.0.0.0.0, Intel Core i5-4260U
    Linux 7.0.0-28-generic (Ubuntu #28~24.04.1)

## What is NOT verified — know this before you send

- **The host kernel is Ubuntu's 7.0.0-28, not a mainline build.** The *driver*
  tested is mainline's — built from the v7.0 tag, and proven identical to the
  distro's by matching srcversion — but it was loaded into a distro kernel. For
  this driver that distinction is thin, and the patch says exactly this rather
  than overclaiming. If a maintainer wants a full mainline kernel test, build
  one on iteration8 and retest.
- **Only tested on one machine so far.** A MacBookAir6,1. Jenni's machine is
  the same model and can confirm it independently once reachable; a second
  model would be better still, but neither is available here.
- **The lore search was for `applesmc nand-disk`.** A report phrased differently
  ("keyboard backlight turns off") could exist and not match. Worth one more
  search on other terms before sending.
- **No claim is made about why the trigger was chosen in 2007.** It looks like a
  mistake — the trigger cannot fire on hardware of that era, and the 2008
  case-LED patch used `ide-disk` when it actually wanted disk activity — but
  that is inference about someone's intent, and it stays out of the patch. The
  patch argues from present behaviour only.

## The change

    --- a/drivers/hwmon/applesmc.c
    +++ b/drivers/hwmon/applesmc.c
    @@ static struct led_classdev applesmc_backlight = {
     static struct led_classdev applesmc_backlight = {
     	.name			= "smc::kbd_backlight",
    -	.default_trigger	= "nand-disk",
     	.brightness_set		= applesmc_brightness_set,
     };

One deleted line. Do not hand-write the diff — generate it with
`git format-patch` from a real tree, so the index line and context are right.

## Commit message

Subject line, then body, to paste verbatim. The Signed-off-by is a DCO
assertion, so it must carry a real name and a real address — note that this is
*not* the identity git is configured with on this machine, which is `joe
<...@users.noreply.github.com>` and would be rejected.

```
hwmon: (applesmc) Drop nand-disk default trigger for keyboard backlight

The keyboard backlight LED is registered with

	.default_trigger	= "nand-disk",

so it comes up bound to the MTD activity trigger. ledtrig_mtd_activity()
issues a oneshot blink, and the off phase of that blink sets brightness to
zero. On a machine that has an MTD device, ordinary MTD access therefore
switches the keyboard backlight off and discards the level the user set.

This went unnoticed for a long time because Macs exposed no MTD device for
the trigger to fire on. That is no longer true: the BIOS SPI flash is now
exposed as an MTD device, and userspace reads it during normal operation.
On a MacBookAir6,1 the keyboard backlight goes out a few seconds after the
first login of each boot, when fwupd's mtd plugin reads /dev/mtd0 while
enumerating devices.

The LED is a keyboard backlight, a light the user sets to taste, rather than
a status indicator, so an activity trigger is a poor default for it. Drop it.
Nothing is lost: a trigger can still be attached from sysfs or by a udev rule
for anyone who wants one.

Signed-off-by: Joe Parish <jparish1977@gmail.com>
---
Present since the driver was added in commit 6f2fad748ccc ("Apple SMC driver
(hardware monitoring and control)"), first released in v2.6.22. No Fixes: tag,
since the driver did not regress -- what changed is the environment around it.
Happy to add one if you would prefer.

Tested on a MacBookAir6,1 (BIOS 430.0.0.0.0, Core i5-4260U) running
7.0.0-28-generic. The distro ships this driver unmodified: applesmc.c built
from the v7.0 tag has the same srcversion as the distro's module,
4B4E296F44EBB1541BCA045, so the driver tested here is mainline's.

Before, stock module:

  # cat /proc/mtd
  dev:    size   erasesize  name
  mtd0: 00800000 00001000 "BIOS"
  # cat /sys/class/leds/smc::kbd_backlight/trigger
  none ... mtd [nand-disk] cpu ...
  # echo 204 > /sys/class/leds/smc::kbd_backlight/brightness
  # systemctl restart fwupd        # its mtd plugin reads /dev/mtd0
  # cat /sys/class/leds/smc::kbd_backlight/brightness
  0

After, with this patch applied:

  # cat /sys/class/leds/smc::kbd_backlight/trigger
  [none] ... mtd nand-disk cpu ...
  # echo 204 > /sys/class/leds/smc::kbd_backlight/brightness
  # systemctl restart fwupd
  # cat /sys/class/leds/smc::kbd_backlight/brightness
  204

The zero comes from the trigger's blink timer rather than from any process,
which is what makes it hard to attribute from userspace:

  applesmc_brightness_set  value=0
          applesmc_brightness_set+1
          led_timer_function+100
          call_timer_fn+46
          __run_timers+555
          run_timer_softirq+138
          handle_softirqs+229
```

Everything after the `---` is notes for reviewers and is dropped by `git am`,
which is exactly where a test report belongs.

## Sending it without process mistakes

**Do not paste a patch into Gmail's web interface.** It rewrites whitespace and
wraps lines, and the result will not apply. That is the single most common way
to look careless on a kernel list.

Consider doing this on **iteration8** instead of this laptop — 32 cores and
251 GB of RAM versus 4 GB here, and it is reachable over the tailnet
(`ssh iteration8`). A shallow clone is a couple of GB either way; this machine
has the disk space (54 GB free) but the build, if you want one, would be
painful here.

```sh
sudo apt install git-email                     # git send-email is not installed
git clone --depth 1 \
  https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux

# make the one-line deletion in drivers/hwmon/applesmc.c, then:
git config user.name  "Joe Parish"
git config user.email "jparish1977@gmail.com"
git commit -s drivers/hwmon/applesmc.c         # -s adds Signed-off-by
git format-patch -1

scripts/checkpatch.pl --strict 0001-*.patch    # must be clean
scripts/get_maintainer.pl 0001-*.patch         # authoritative recipient list
```

Sending through Gmail needs an **app password**, not the account password, and
2FA has to be on for Google to offer one. Configure it once:

```sh
git config --global sendemail.smtpServer     smtp.gmail.com
git config --global sendemail.smtpServerPort 587
git config --global sendemail.smtpEncryption tls
git config --global sendemail.smtpUser       jparish1977@gmail.com
# password is prompted for, or stored in ~/.git-credentials

git send-email --dry-run --to='...' --cc='...' 0001-*.patch   # ALWAYS dry-run first
```

Send it to yourself first and check that `git am` applies the received mail
cleanly. That one step catches every mangling problem before a list sees it.

`get_maintainer.pl` is the right answer for who to send to, not a list written
from memory. For reference, what MAINTAINERS says today:

- Henrik Rydberg `<rydberg@bitmath.org>` — APPLE SMC DRIVER, marked **`S: Odd fixes`**
- Guenter Roeck `<linux@roeck-us.net>` — HARDWARE MONITORING, `F: drivers/hwmon/`
- `linux-hwmon@vger.kernel.org`, `linux-kernel@vger.kernel.org`

`Odd fixes` means minimal maintenance, so expect Guenter to be the one who acts
on it. Silence for a couple of weeks is normal; a single polite resend after
that is normal too.

## Likely review questions, and honest answers

**"Why no Fixes: tag?"** Nothing in the driver regressed — the default has been
there since v2.6.22. What changed is that the platform started exposing an MTD
device and userspace started reading it. Say you are happy to add one.

**"Won't this break someone relying on the trigger?"** No capability is removed.
The trigger is still attachable from sysfs or udev. And on hardware where it
does fire, it makes the keyboard backlight unusable, so it is hard to rely on.

**"Did you test on mainline?"** The driver is mainline's — built from the v7.0
tag, with srcversion matching the distro module, so the source is provably
identical — and the patched build was loaded on the affected hardware. The
host kernel was Ubuntu's 7.0.0-28. If they want a full mainline kernel, build
one on iteration8 and retest; do not claim it until then.

**"How do you know the line is what fixed it, and not your udev rule?"** The
test moves the rule aside and reloads the stock module first, confirming
`[nand-disk]` comes back, before loading the patched module and getting
`[none]`. `applesmc-patch-test.sh` in this repo runs exactly that sequence and
aborts if the control does not reproduce.

**"Should the LED core preserve brightness across a oneshot blink instead?"**
Arguably, but that is an LED-core change affecting every driver. Not defaulting
a keyboard backlight to an activity trigger is the smaller, safer fix.

## Two decisions that are yours

1. **Whether to disclose AI assistance.** The analysis here was done with an AI
   assistant; the verification and the hardware are yours. Kernel norms on this
   are unsettled and vary by subsystem. Read
   `Documentation/process/submitting-patches.rst` in the tree you clone before
   deciding — do not take my word for what current practice is.
2. **Whether to send at all.** The udev rule already fixes both of your
   machines. Upstreaming helps other people with this hardware and nobody else.
   Entirely reasonable to keep it local.
