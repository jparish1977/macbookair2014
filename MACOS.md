# Running newer macOS on this machine

Research notes, July 2026. The question was whether OpenCore can run macOS
versions *newer* than Apple allows on this machine, and what that costs.

**Answer: it works, and it is cleaner than expected — no root patches, no SIP
changes. The only real obstacle is 4GB of soldered RAM.** Not pursued, since the
machine was bought for $20 to run Linux and macOS was a novelty.

## The machine

| | |
| --- | --- |
| Model | `MacBookAir6,1` — Early 2014 11-inch |
| CPU | i5-4260U (Haswell), Intel HD 5000 |
| RAM | 3.8 GB usable, **soldered** |
| SSD | 113 GB — Apple proprietary PCIe connector |
| Firmware | `430.0.0.0.0`, booting UEFI |
| Disk layout | 512M ESP (`sda1`) + single ext4 filling `sda2`, 33G used |

No macOS partition and no Apple Recovery partition remain. The drive is Linux
end to end.

Apple's last release for this model is **Big Sur 11.7.10**. Monterey raised the
floor to Early-2015 Airs. Anything above Big Sur needs OCLP.

## OpenCore is two different projects

Search results conflate them, which matters because only one is relevant.

**OpenCorePkg** is a UEFI bootloader that injects patches, fake device
properties, and a spoofed SMBIOS so non-Apple hardware can boot macOS. That is
the hackintosh tool, and it is irrelevant on genuine Apple hardware.

**OpenCore Legacy Patcher (OCLP)** wraps OpenCorePkg for genuine but obsolete
Macs. Running newer macOS is its entire purpose.

## How far this machine goes, and what it costs

`MacBookAir6,1` appears in [OCLP's model
table](https://dortania.github.io/OpenCore-Legacy-Patcher/MODELS.html) **with no
caveats or version ceiling listed**. Monterey through Sequoia all work. Tahoe
(macOS 26) support was still in development as of mid-2026.

The important finding is that this machine needs **no graphics root patches at
any version**:

| Version | Graphics status on Haswell |
| --- | --- |
| Monterey 12 | Native. Root patches are for Ivy Bridge HD 4000, Kepler, non-Metal. |
| Ventura 13 | Native. Ventura requires AVX2.0; confirmed present on this CPU (below). |
| Sonoma 14 | Native. |
| Sequoia 15 | Native. Only dropped Airs were T2 models (`MacBookAir8,x`). |

### AVX2.0 verified on this CPU, not assumed

Ventura's native-acceleration cutoff is AVX2.0, so the whole verdict above rests
on this machine actually having it. Checked rather than inferred from the
generation:

```console
$ grep -m1 ^flags /proc/cpuinfo | tr ' ' '\n' | grep -E '^(avx2?|fma|bmi[12]|f16c|movbe|abm)$'
avx  avx2  fma  bmi1  bmi2  f16c  movbe  abm
$ grep -E '^(cpu family|model\s|stepping)' /proc/cpuinfo | head -3
cpu family : 6    model : 69    stepping : 1        # 0x45, Haswell-ULT
```

This matters because "Haswell" alone is not sufficient. Haswell-era **Celeron and
Pentium** parts — 2955U, 2957U, 2847U and similar — ship with AVX2, FMA, and BMI
fuse-disabled despite being Haswell dies. A 2014 Air built on one of those would
fail Ventura's check and fall back to needing root patches. This one is a genuine
Core i5-4260U with the feature set intact.

(`lzcnt` is reported by Linux as `abm`; grepping for `lzcnt` returns nothing even
though the instruction is present.)

Because nothing needs patching, OCLP on this machine is close to a stock
install: the bootloader sits on the EFI system partition, **SIP stays fully
enabled**, and OS updates do not require re-running the patcher. That is a much
lower maintenance burden than OCLP's general reputation implies, which mostly
comes from genuinely unsupported GPUs.

## What actually rules it out

Hardware, not software:

- **3.8 GB of soldered RAM.** Not upgradeable at any price. Sequoia on 4GB is
  slow but functional; macOS memory compression helps. Monterey would be the
  sweet spot for a novelty install.
- **1.4 GHz dual-core i5-4260U** and a 128 GB disk.

None of this is a blocker in the sense of not booting. It is a "this will be
unpleasant" verdict, weighed against the machine's actual job, which is Linux.

## If it is ever revisited

Put macOS on an **external SSD in a UASP enclosure** — the port is USB 3.0 and
gives real throughput, but a flash drive running a full macOS install is
unusable. This keeps the Mint install untouched.

Apple's firmware already has a boot picker: **hold Option at power-on**. It
enumerates every bootable EFI volume, internal or external, so GRUB and macOS
both appear. Dual-boot and USB boot are firmware features and need no
third-party bootloader — OCLP is only for the newer-OS part.

Getting an installer without an existing Mac:

- `macrecovery.py`, a utility in the OpenCorePkg repo — the *script*, not the
  bootloader — fetches Apple's `BaseSystem.dmg`. Write it to USB, boot it, let
  Recovery pull the full OS down.
- **Cmd-Option-R at power-on** starts Internet Recovery from Apple's servers over
  Wi-Fi and should offer Big Sur, which OCLP can then upgrade from. Free to
  attempt; sometimes fails on decade-old firmware over TLS.

Two machine-specific notes:

- OCLP wants `/EFI/BOOT/BOOTx64.efi` on the ESP, which is the same fallback path
  Mint's GRUB uses on Macs. Install it to the external disk's own ESP and leave
  `sda1` alone.
- The BCM4360 is a first-party Apple card in macOS and needs none of the `wl`
  misery documented in [`README.md`](README.md).

## Corrections to bad information found while researching

Both of these came from search-result summaries and were wrong. Verified against
Dortania's own pages.

- **"Apple removed graphics support for Haswell through Skylake in Ventura."**
  False. Ventura's cutoff is AVX2.0 support, and Haswell is the first generation
  that has it. Haswell keeps native acceleration.
- **"`MacBookAir6,x` is non-Metal"** and **"Haswell requires MetallibSupportPkg
  on Sequoia."** False. Intel HD 5000 is fully Metal-capable. Non-Metal means
  Intel Iron Lake / Sandy Bridge, Nvidia Tesla/Fermi, AMD TeraScale.
  MetallibSupportPkg is for Legacy Metal GPUs, which HD 5000 is not.

Also worth knowing: OCLP does **not** flash Apple firmware. It lives on the EFI
system partition and is removable.

## Unrelated but relevant

The 128 GB drive is the binding constraint on this machine and *is* upgradeable:
an M.2 NVMe plus a Sintech-style adapter works on `MacBookAir6,x` despite the
proprietary connector. Relevant to Linux regardless of macOS.

## Open idea: a bootable macOS USB, if the fleet happens

Noted 2026-08-09, not started. It came out of building `vm-restore-test.sh
usb-image`, which writes a VM-approved *Linux* image to a USB disk so the last
mile — Wi-Fi associating, the camera capturing, the backlight lighting — can be
tested on real hardware without touching the internal disk.

**Almost none of that machinery transfers, and it is worth writing down why so
nobody tries.** Those images are GPT + ext4 and macOS install media is
HFS+/APFS with an Apple-specific boot path; there is no converting one into the
other. What transfers is only the cheap part: a Mac boots from USB with Option
held.

What it would actually need:

- **`Install macOS Big Sur.app`** — 11.7.10 is Apple's last for this model, per
  the table above.
- **`createinstallmedia`, which runs only on macOS.** So it needs a working Mac
  to build the media. The Linux route (`dmg2img` plus HFS+ tooling) exists and
  is fiddly enough to get subtly wrong.
- **A source.** This machine has no macOS partition and no Recovery partition
  left — the drive is Linux end to end — so there is nothing local to build from.

**It is not needed for the camera.** `mba-webcam.sh` downloads the `facetimehd`
blob directly (2.8 MB) rather than extracting it from a macOS install, so that
problem is already solved and is not a reason to do this.

### Automating it — and the shortcut that might delete the whole job

Asked 2026-08-09: could rebuilding the recovery partition and the rest be
automated? Two things reframe it.

**On Big Sur there is no separate Recovery partition to rebuild.** It is a volume
inside the APFS container, and the installer creates the whole layout — System
(a sealed signed snapshot), Data, Preboot, Recovery, VM — in one pass. So the
task is not "rebuild Recovery", it is "run the installer non-interactively":

    startosinstall --eraseinstall --agreetolicense --nointeraction \
      --newvolumename "Macintosh HD"

That much is scriptable and can live on the installer USB. What cannot be
automated away is the start — someone holds Option and picks the disk. For a
refurb line that is about a minute of attention per machine, then 30-60 minutes
unattended. Fully hands-off imaging needs DEP/MDM enrolment, which second-hand
machines will not have.

**Do not depend on Internet Recovery, even if it works.** Joe's point, and it is
the right instinct: the early-internet promise of everything being available for
ever was a lie, and drivers and installers evaporate. Apple retiring recovery
images for a 2014 model is exactly the kind of withdrawal you discover on the day
you need it. Test it, because the test is free -- but treat capturing the
installer while it is still served as the actual task, not as a fallback.

**Test Internet Recovery anyway, because it is free and may save the effort.**
Command-Option-R boots Apple's recovery over the network — the firmware drives
the Wi-Fi itself, no OS involved — and reinstalls the latest macOS this model
supports, with no media to build at all. If it still works for `MacBookAir6,1`,
the entire "build a macOS USB" project reduces to a keyboard shortcut. It is slow
over Wi-Fi and depends on Apple continuing to serve these models, so it wants
confirming on one machine **before** any effort goes into building media.

**Where it would pay is refurbishment, not this project.** Joe paid $20 for this
machine and may be able to get around a hundred more (uncertain as of
2026-08-09). A $20 Air with macOS on it is worth more than a bare one, so a
repeatable macOS-restore USB would be an *imaging* tool for a fleet. That is a
different shape of job from update pre-flight and wants its own scripts rather
than bending the ones in this repo.

## Sources

- [OCLP supported models](https://dortania.github.io/OpenCore-Legacy-Patcher/MODELS.html)
- [Monterey drop — which GPUs need root patches](https://dortania.github.io/OpenCore-Legacy-Patcher/MONTEREY-DROP.html)
- [Ventura drop — AVX2.0 requirement](https://dortania.github.io/OpenCore-Legacy-Patcher/VENTURA-DROP.html)
- [Sequoia drop](https://dortania.github.io/OpenCore-Legacy-Patcher/SEQUOIA-DROP.html)
- [OCLP FAQ](https://dortania.github.io/OpenCore-Legacy-Patcher/FAQ.html)
