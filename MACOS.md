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

## Sources

- [OCLP supported models](https://dortania.github.io/OpenCore-Legacy-Patcher/MODELS.html)
- [Monterey drop — which GPUs need root patches](https://dortania.github.io/OpenCore-Legacy-Patcher/MONTEREY-DROP.html)
- [Ventura drop — AVX2.0 requirement](https://dortania.github.io/OpenCore-Legacy-Patcher/VENTURA-DROP.html)
- [Sequoia drop](https://dortania.github.io/OpenCore-Legacy-Patcher/SEQUOIA-DROP.html)
- [OCLP FAQ](https://dortania.github.io/OpenCore-Legacy-Patcher/FAQ.html)
