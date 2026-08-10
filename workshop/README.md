# Kernel workshop

A place to build and bisect kernels for old machines, so that "nagging issue on
vintage hardware" becomes something you can actually chase down instead of live
with.

**If you are reading this on iteration8 months later and remember nothing: start
at [Quick start](#quick-start). Everything you need is in this directory.**

    /srv/kernel-workshop/
      linux/            full git clone of mainline (full, not shallow -- bisect needs history)
      targets/<name>/   one profile per machine you build for
      builds/<t>-<ref>/ .deb output
      bin/              the scripts below
      README.md         this file

## The one thing to understand first

**The build happens here. The test always happens on the vintage machine.**

This host has 32 cores and no Apple SMC, no vintage chipset, no failing
hardware. It can compile anything and prove nothing. Every verdict comes from
the old machine. That is why the workflow is always: capture a profile here,
build here, install and boot *there*.

It also means a kernel build is often the wrong tool. If the bug is in a driver
and the driver is a module — which covers most vintage-hardware complaints —
`module-patch-test.sh` in the macbookair2014 repo tests a fix in seconds on the
target itself, with no kernel build at all. Reach for this workshop when the fix
is not in a module, or when you need to **bisect**.

## Quick start

```sh
# 1. On the vintage machine, once (and again after any distro kernel upgrade):
./capture-target.sh mba --push

# 2. Here:
/srv/kernel-workshop/bin/kbuild.sh --target mba --ref v7.0

# 3. On the vintage machine:
scp iteration8:/srv/kernel-workshop/builds/mba-v7.0/linux-image-*.deb .
sudo dpkg -i linux-image-*.deb
sudo update-grub
sudo reboot          # AT THE KEYBOARD -- see the warnings below
```

## Reaching this host

Use the **tailnet** name, from anywhere:

    ssh iteration8.tail51fded.ts.net        # or 100.109.232.15

Not the bare `iteration8` ssh alias. That alias sets `HostName iteration8.local`,
which resolves only on i8's own LAN — so it works at home and fails everywhere
else, which is exactly when you are least able to debug it. `capture-target.sh`
defaults to the tailnet name for this reason.

## Rebuilding the workshop somewhere else

The workshop is a recipe, not a machine:

```sh
ssh newhost 'bash -s' < provision.sh
```

That installs the toolchain, makes the layout, sets up ccache and clones the
tree. If you ever want this in a VM or container, that is the whole job — run
`provision.sh` inside it. Nothing here is specific to iteration8 except that
iteration8 is where the cores are.

## The scripts

| | |
| --- | --- |
| `provision.sh` | Build the workshop from nothing on any Debian/Ubuntu host. Idempotent. |
| `capture-target.sh` | **Run on the vintage machine.** Captures its kernel config, loaded modules and identity into a profile. |
| `kbuild.sh` | **Run here.** Builds an installable kernel for a target profile at a given git ref. |

## Warnings that matter more than the build

**A self-built kernel has no DKMS modules.** On the MacBook Air that means **no
Wi-Fi**, because `wl` comes from broadcom-sta via DKMS, and that machine has no
Ethernet port. A test kernel there is offline unless DKMS rebuilds `wl` for it,
which it may not. Plan the test to need no network — boot, check the thing,
reboot back — or have USB tethering ready. `capture-target.sh` records each
machine's DKMS modules and interfaces in `facts.txt` for exactly this reason.

**Reboot at the keyboard, not over SSH.** A kernel that does not boot is
recovered by picking an older entry in the GRUB menu, and the menu times out in
five seconds. You cannot do that from another room.

**Keep the distro kernels.** They are the fallback. Never remove the last known
good kernel to make room, and check `apt-mark showhold` before an upgrade — on
the MacBook Air several 6.17 packages are deliberately held for this reason.

**A self-built kernel becomes the GRUB default and stays there — forever.**
Not just "may". GRUB's own comparison strips at the first `-` and ranks the
suffix, so `7.0.0-mba` beats `7.0.0-28-generic`, `7.0.0-29-generic`,
`7.1.0-5-generic` and even `8.0.0-1-generic`. Verified with GRUB's own helper:

    . /usr/share/grub/grub-mkconfig_lib
    version_test_gt 7.0.0-mba 8.0.0-1-generic && echo "the test kernel wins"

With `GRUB_DEFAULT=0` that means every unattended reboot from now on lands on a
hand-built kernel that receives no security updates, no matter how many distro
kernels arrive later.

**So remove a test kernel once it has answered its question.** Reboot onto a
distro kernel first — actively picking it, since the test kernel is the default
— and then:

    sudo dkms remove <module>/<version> -k <rel>    # before the package, or wl.ko
    sudo dpkg -P linux-image-<rel> linux-headers-<rel>   #   is orphaned in /lib/modules
    sudo update-grub

Leaving it installed also leaves permanent noise: any DKMS module that cannot
build against it fails on every kernel or driver update, and `kernel-guard`
reports a gap on every apt run. A guard that warns every single time is a guard
that gets ignored, which is worse than not having installed it.

Rebuilding takes minutes. Keeping a test kernel around does not pay for itself.

## Why builds fail, in order of likelihood

1. **Certificate errors.** A distro config sets `CONFIG_SYSTEM_TRUSTED_KEYS`
   and `CONFIG_SYSTEM_REVOCATION_KEYS` to Canonical certificates that do not
   exist in a mainline tree. `kbuild.sh` blanks both — this is the single most
   common failure when building an Ubuntu config in a mainline tree, and the
   error message does not point at the cause.
2. **pahole / BTF mismatch.** `CONFIG_DEBUG_INFO_BTF` needs a matching pahole.
   `kbuild.sh` disables debug info by default; `--keep-debug` puts it back.
3. **`localmodconfig` dropped something needed to boot.** `--trim` builds only
   what the target had loaded when the profile was captured. If the machine was
   not exercising some hardware at that moment, that driver is gone. If a
   trimmed kernel misbehaves, rebuild with `--full` before suspecting anything
   else.

   A real example from the first `mba` build: the laptop had `videobuf2-*`
   loaded, but only because the out-of-tree `facetimehd` pulled them in. Trimming
   kept `MEDIA_SUPPORT=m` and dropped `VIDEOBUF2_CORE`, so on that kernel the
   `facetimehd` DKMS build would fail for want of a dependency that the trim had
   no reason to keep. **Out-of-tree modules make `--trim` lie about what the
   machine needs**, because their dependencies look like idle drivers. If a
   target has DKMS modules, expect to want `--full`.

   Checking a package before trusting it:

       dpkg-deb -c linux-image-*.deb | grep '\.ko' > mods.txt
       # module FILES use dashes; config symbols use underscores. Searching
       # for snd_hda_intel.ko finds nothing while snd-hda-intel.ko is right there.
       grep -E '/(ahci|applesmc|snd-hda-intel)\.ko' mods.txt

   And check `config-used` in the build directory for anything `=y`: built-in
   drivers are absent from the module list and that is correct, not a gap.
   `EXT4_FS=y` and `USB_XHCI_PCI=y` both looked alarming until checked.
4. **Stale tree.** `git -C linux fetch --tags` if a ref is not found.

### DKMS on a self-built kernel

Two things bite in order:

**Install the headers package too.** Without it, `dpkg -i linux-image-*.deb`
prints `dkms: autoinstall ... was skipped since the kernel headers for this
kernel do not seem to be installed` and builds nothing — so the machine gets a
kernel with none of its out-of-tree drivers. On the Air that means no Wi-Fi, and
it is quiet enough to miss in the scroll.

**`bindeb-pkg`'s headers package contains no `.config`.** DKMS warns
`Kernel config /lib/modules/<rel>/build/.config not found, modules won't be
signed` and carries on, using `Module.symvers` — `wl` builds fine. But a module
that reads the config will fail. The build directory keeps a copy, so:

    sudo cp config-used /lib/modules/<rel>/build/.config

Expect out-of-tree modules whose dependencies were trimmed away to fail
regardless — `facetimehd` cannot build against a kernel with no
`VIDEOBUF2_CORE`, no matter what the headers contain. See the `--trim` note
above.

## Targets that are not x86-64

### 32-bit x86 — supported, and probably what you actually need

Mainline still supports it: `CONFIG_X86_32` and `arch/x86/configs/i386_defconfig`
are both present as of v7.0. `gcc-multilib` and `libc6-dev-i386` were installed
on i8 on 2026-08-08 and verified by compiling an `ELF 32-bit ... Intel 80386`
binary, so the host can emit 32-bit code.

**This is not cross-compiling.** A 32-bit x86 target is the same toolchain with
`-m32`, which is why it is cheap. `kbuild.sh` passes `ARCH=i386` automatically
when the target profile says the machine is 32-bit — `capture-target.sh` records
that, so it happens without you thinking about it.

**First candidate: the Fujitsu LifeBook U810.** Its Intel A110 ("Stealey") is a
Pentium M derivative with no Intel 64, so that machine is 32-bit only and lands
squarely in this case rather than needing a cross toolchain. Treat that as
expected, not established — run `capture-target.sh` on it and believe the `arch`
file it writes.

Reaching it: it appears on the tailnet as `u810-bunsenlabs` (100.90.76.72), and
like `iteration8` its ssh alias points at a `.local` name that only resolves on
its own LAN. Use the tailnet address from anywhere else.

### ARM — Raspberry Pis and a Jetson Nano — not wired up yet

There are Pis in quantity and a Jetson Nano to serve, so this is a real gap
rather than a hypothetical one. It is deliberately deferred, and the reason is
worth knowing before anyone starts: **the hard part is not the compiler.**

Toolchains are one `apt install` away:

| target | package | `ARCH=` |
| --- | --- | --- |
| Pi 1 / Zero / Zero W (armv6) | `gcc-arm-linux-gnueabihf` | `arm` |
| Pi 2 / 3 / 4 on 32-bit Pi OS | `gcc-arm-linux-gnueabihf` | `arm` |
| Pi 3 / 4 / 5 on 64-bit Pi OS | `gcc-aarch64-linux-gnu` | `arm64` |
| Jetson Nano | `gcc-aarch64-linux-gnu` | `arm64` |

Three things break the assumptions this workshop currently makes:

1. **Mainline is often the wrong tree.** Raspberry Pi OS runs the Foundation's
   `raspberrypi/linux`, not `torvalds/linux`, and the Jetson Nano runs NVIDIA's
   L4T/JetPack kernel — a vendor BSP, on an old kernel, for a board NVIDIA has
   since dropped. Building mainline for a Nano is a research project, not a
   build. So `kbuild.sh` would need to work against **several trees**, not the
   one it clones today.
2. **`bindeb-pkg` is not how these get installed.** A Pi kernel is `Image` or
   `kernel8.img` copied into `/boot/firmware` alongside its device tree blobs,
   plus `make modules_install`. The deb pipeline this script is built around
   does not apply.
3. **Device trees matter.** On ARM the kernel alone is not enough; the matching
   DTBs have to land too, and a mismatch fails in ways that look nothing like a
   kernel bug.

None of that is hard, but it is a different shape of job from x86 — enough that
bolting it onto `kbuild.sh` badly would be worse than a second script. Revisit
with a specific board and a specific problem, not in the abstract.

PowerPC (`gcc-powerpc-linux-gnu`) is available too, should an old Mac ever
join the list.

## Bisecting a regression

This is the reason the clone is full rather than shallow, and the reason this
machine is involved at all. Use it when something worked on an older kernel and
broke on a newer one.

You need a **reproducer you can run in one command on the target**, that exits 0
for good and non-zero for bad. Write that first — everything else is mechanical,
and a vague reproducer wastes a whole evening of builds.

```sh
cd /srv/kernel-workshop/linux
git bisect start
git bisect bad  v7.0        # known broken
git bisect good v6.12       # known working

# each step:
/srv/kernel-workshop/bin/kbuild.sh --target mba --here --trim
#   install on the target, boot it, run the reproducer, then back here:
git bisect good     # or: git bisect bad
```

Repeat. Between two releases it is roughly 12–15 steps, each one a build plus a
reboot on the old machine. Budget an evening. When it finishes, `git bisect log`
is your record and `git bisect reset` puts the tree back.

Two things that ruin a bisect:

- **Skipping steps you cannot test.** If a build fails or will not boot, use
  `git bisect skip`, not a guess. A wrong `good`/`bad` sends the search into the
  wrong half and there is no way to tell from the inside.
- **Testing something other than what you think.** Keep the reproducer identical
  at every step. Use `--trim` consistently — mixing trimmed and full builds
  changes the kernel between steps.

## Maintenance

```sh
git -C /srv/kernel-workshop/linux fetch --tags      # before building a new release
CCACHE_DIR=/srv/kernel-workshop/.ccache ccache -s   # hit rate
du -sh /srv/kernel-workshop/builds/*                # old builds pile up; delete freely
```

Re-run `capture-target.sh` on a machine after it takes a distro kernel upgrade,
or you will be building against a config that no longer matches it.

## NUMA: worth an experiment, not a default

iteration8 is genuinely dual-socket — 2 × Xeon E5-2687W, 8 cores / 16 threads
each — so `nproc` reports **32 across two NUMA nodes**:

    node0  CPUs 0-7,16-23
    node1  CPUs 8-15,24-31

A `-j32` build spans both sockets and pays cross-node memory traffic. Confining
it to one node is worth timing:

    numactl --cpunodebind=0 --membind=0 ./kbuild.sh --jobs 16

Sometimes that beats `-j32`, because the working set stops crossing the
interconnect. Sometimes it does not. **Measure both on the same tree, more than
once** — this host's timings vary enough run-to-run that a single comparison
proves nothing.

Worth contrasting with the VM work in the parent repo, where pinning is *not*
worth doing: those guests are blocked on 7200rpm disks, and taking one from
2 vCPU / 4G to 8 vCPU / 16G moved the wall clock by 26 seconds. A kernel build
is one of the few jobs on this machine that is actually CPU and
memory-bandwidth bound, which is exactly when NUMA placement starts to matter.
