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

**A new kernel may become the GRUB default.** Check what `update-grub` picked
before rebooting, especially if the version sorts above the distro's.

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
4. **Stale tree.** `git -C linux fetch --tags` if a ref is not found.

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
