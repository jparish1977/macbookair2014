#!/bin/bash
# Build an OEM image: Mint + this repo's fixes, ready to hand to somebody else.
#
#   ./oem-image.sh install     create the disk, boot the ISO -- YOU drive this one
#   ./oem-image.sh wire        make the installed disk scriptable (serial console)
#   ./oem-image.sh provision   apply the fixes, unattended
#   ./oem-image.sh seal        strip the rig and identity, arm the wizard, shut down
#   ./oem-image.sh verify      boot a THROWAWAY COPY and confirm the wizard appears
#   ./oem-image.sh status
#
# WHAT THIS PRODUCES
#
# A qcow2 whose first boot shows "create your account", not a login prompt. Write
# it to a USB stick and somebody boots a working Mac-on-Linux without installing
# anything; write it to an internal disk and it is a refurbished machine. One
# artefact for both.
#
# WHY A FRESH INSTALL AND NOT A SNAPSHOT
#
# Restoring one person's snapshot onto another person's machine is the one thing
# this project has a standing rule against -- it carries their files, their keys
# and their tailnet identity. This starts from stock Mint media for that reason,
# and it is also why nothing here needs the identity scrubbing a cloned system
# would: there is no identity yet.
#
# WHERE IT RUNS
#
# On the VM host, beside vm-restore-test.sh, sharing its work directory but NOT
# its images. golden.qcow2 is a restored copy of one laptop for testing updates;
# oem.qcow2 is a generic install for handing out. Two different artefacts that
# would be easy to confuse, so they never share a filename.
#
# THE INTERACTIVE BIT, AND WHY IT IS ONLY ONE
#
# Ubiquity's OEM mode is a GUI. Rather than install ssh or an agent into the
# image to make the rest scriptable, `wire` adds a serial console OFFLINE, with
# the disk attached over nbd and nothing running. So the image gains no package
# it would not otherwise have, and the one thing it does gain -- the serial
# console -- is removed again by `seal`. Everything after the installer reboots
# is unattended.

set -uo pipefail

WORK="${MBA_VMTEST_DIR:-/srv/mba-vmtest}"
ISO="${MBA_OEM_ISO:-$WORK/linuxmint-22.3-xfce-64bit.iso}"
DISK="$WORK/oem.qcow2"
SEALED="$WORK/oem-sealed.qcow2"
SOCK="$WORK/oem-serial.sock"
PIDF="$WORK/oem-qemu.pid"
VARS="$WORK/oem-vars.fd"

# 20 GiB: a fresh Mint XFCE install plus the DKMS toolchain and a fallback kernel
# is 10-12G, so this leaves ~40% free, fits any 32 GB stick, and grows to fill a
# bigger disk on first boot. Raise it for an image somebody will LIVE on -- 77%
# full is fine for a try-it-out stick and mean for a daily driver.
OEM_GB="${MBA_OEM_GB:-20}"
SMP="${MBA_OEM_SMP:-4}"
RAM="${MBA_OEM_RAM:-4096}"
VNC_DISP="${MBA_OEM_VNC:-7}"
NBD="${MBA_VMTEST_NBD:-/dev/nbd0}"

die()  { echo "error: $*" >&2; exit 1; }
say()  { echo; echo "  == $*"; }
warn() { echo "  WARN  $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; }
info() { echo "  --    $*"; }

# --- talking to the guest -----------------------------------------------------
#
# Same serial transport as vm-restore-test.sh, and the same rule: NEVER pipe
# guest() into `grep -q`. grep -q exits at the first match, the pipe closes, the
# reader dies of SIGPIPE, and under pipefail a SUCCESSFUL match is reported as
# failure. Capture first, match against a here-string. ./lint.sh checks for it.
guest() {
  python3 "$WORK/conv.py" "$SOCK" "" 1 "$1" "${2:-8}" 2>/dev/null \
    | tr -d '\r' | sed 's/\x1b\[[0-9?;]*[a-zA-Z]//g'
}
guest_says() {   # $1 = command, $2 = seconds, $3 = pattern
  local out; out=$(guest "$1" "$2")
  grep -q -- "$3" <<< "$out"
}

# `id` is the probe because its OUTPUT (uid=) cannot appear in the echo of the
# command itself -- a probe that greps for its own marker matches the echo and
# reports a login that has not happened. The settle at the end is not optional:
# the qemu serial socket takes ONE client, so the next caller connects to a
# refused socket if we do not let this one close.
wait_for_guest() {
  local i
  for i in $(seq 1 "${1:-60}"); do
    guest_says 'id' 8 'uid=' && { sleep 3; return 0; }
    sleep 5
  done
  return 1
}

nbd_attach() {   # $1 = image
  sudo modprobe nbd max_part=8 || die "cannot load the nbd module"
  # Never inherit a connection we did not make -- a stale one points at another
  # image, and everything below would edit the wrong disk.
  sudo qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
  sleep 1
  sudo qemu-nbd --connect="$NBD" "$1" || die "qemu-nbd could not attach $(basename "$1")"
  sleep 2
}

nbd_detach() { sudo qemu-nbd --disconnect "$NBD" >/dev/null 2>&1; }

# Find a partition by filesystem type rather than assuming p1/p2. Ubiquity's
# layout depends on what was clicked in the installer, and guessing wrong means
# mounting the ESP and writing systemd units into it -- which fails in a way that
# looks like the units were never written.
find_part() {   # $1 = fs type; echoes the device or nothing
  local p
  for p in "${NBD}"p*; do
    [ -b "$p" ] || continue
    [ "$(sudo blkid -o value -s TYPE "$p" 2>/dev/null)" = "$1" ] && { echo "$p"; return 0; }
  done
  return 1
}

vm_stop() {
  [ -f "$PIDF" ] || return 0
  local p; p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] && kill "$p" 2>/dev/null
  local i; for i in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -9 "$p" 2>/dev/null; rm -f "$PIDF"
}

vm_running() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }

# Boot oem.qcow2 headless with a serial console and outbound network.
#
# Networking is plain user-mode NAT rather than the restore rig's restrict=on.
# That rig blocks the network because a RESTORED CLONE with a route to the
# internet steals the original laptop's tailnet identity. This image is a fresh
# install with no identity to steal, and provisioning genuinely needs to reach
# the archive and Apple's firmware. Different image, different risk, different
# setting -- worth saying out loud, because copying restrict=on across would
# silently break provisioning and copying this back would break the rig.
vm_boot_headless() {
  vm_running && die "a VM is already running (pid $(cat "$PIDF")) -- ./oem-image.sh stop"
  rm -f "$SOCK"
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS" || die "cannot copy OVMF vars"
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$SMP" -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -device ich9-ahci,id=ahci \
    -drive file="${1:-$DISK}",if=none,id=t0,format=qcow2,discard=unmap,detect-zeroes=unmap \
      -device ide-hd,bus=ahci.0,drive=t0 \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -serial "unix:$SOCK,server,nowait" -display none \
    -pidfile "$PIDF" > "$WORK/oem-qemu.log" 2>&1 &
  local i; for i in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 1; done
  [ -S "$SOCK" ] || die "qemu never created the serial socket -- see $WORK/oem-qemu.log"
}

# ---- install -----------------------------------------------------------------

cmd_install() {
  [ -s "$ISO" ] || die "no ISO at $ISO (set MBA_OEM_ISO)"
  vm_running && die "a VM is already running -- ./oem-image.sh stop first"

  if [ -s "$DISK" ]; then
    warn "$DISK already exists ($(du -h "$DISK" | cut -f1))"
    info "Delete it first if you want to start over:  rm $DISK"
    exit 1
  fi
  qemu-img create -f qcow2 "$DISK" "${OEM_GB}G" >/dev/null || die "cannot create the disk"
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS" || die "cannot copy OVMF vars"
  ok "created $(basename "$DISK") (${OEM_GB}G)"

  rm -f "$SOCK"
  # VNC on the LOOPBACK only. A VNC server on a LAN address is an unauthenticated
  # framebuffer and keyboard on a machine holding everyone's backups; an ssh
  # tunnel costs one flag and removes the question entirely.
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$SMP" -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -device ich9-ahci,id=ahci \
    -drive file="$DISK",if=none,id=t0,format=qcow2 -device ide-hd,bus=ahci.0,drive=t0 \
    -drive file="$ISO",if=none,id=cd0,media=cdrom,readonly=on -device ide-cd,bus=ahci.1,drive=cd0 \
    -boot order=d \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -device ich9-intel-hda -device hda-duplex \
    -vga std -vnc "127.0.0.1:$VNC_DISP" \
    -pidfile "$PIDF" > "$WORK/oem-qemu.log" 2>&1 &

  local i; for i in $(seq 1 30); do vm_running && break; sleep 1; done
  vm_running || die "qemu did not start -- see $WORK/oem-qemu.log"
  ok "VM up (pid $(cat "$PIDF")), installer on VNC 127.0.0.1:$((5900 + VNC_DISP))"

  cat <<EOF

  == Your part. Everything after this is scripted.

  From your laptop, tunnel and connect:

      ssh -N -L $((5900 + VNC_DISP)):localhost:$((5900 + VNC_DISP)) $(hostname) &
      vncviewer localhost:$((5900 + VNC_DISP))

  In the boot menu pick:   OEM install (for manufacturers)

  That entry is the whole reason this is only ONE manual step -- it passes
  oem-config/enable=true, so Mint sets up the first-boot account wizard itself
  and none of it has to be reconstructed by hand.

  Then install normally:

    * Erase disk and install     -- it is a 20G virtual disk, nothing to lose
    * DO NOT tick third-party codecs if you want the image redistributable
    * The name it asks for is the OEM/staging account, not the end user's.
      Ubiquity replaces it at first boot. "oem" with any password is right.
    * When it offers to restart, let it -- then come back here.

  Watch for it to finish:      ./oem-image.sh status
  When it has shut down:       ./oem-image.sh wire

EOF
}

# ---- wire --------------------------------------------------------------------

# Give the installed system a serial console, offline.
#
# WHY OFFLINE, VIA NBD
#
# The alternative is installing openssh-server in the guest and putting a key in
# it -- which means the shipped image contains a package it does not need and an
# authorised key belonging to whoever built it. Editing the disk while nothing is
# running adds no package at all, and what it does add is two files that `seal`
# deletes.
cmd_wire() {
  vm_running && die "stop the VM first: ./oem-image.sh stop"
  [ -s "$DISK" ] || die "no $DISK -- run ./oem-image.sh install first"
  sudo -n true 2>/dev/null || die "this needs root for nbd and mount"

  local mnt="$WORK/oem-mnt"; mkdir -p "$mnt"
  cleanup() { sudo umount "$mnt/boot/efi" 2>/dev/null
              local m; for m in sys proc dev/pts dev; do sudo umount "$mnt/$m" 2>/dev/null; done
              sudo umount "$mnt" 2>/dev/null; nbd_detach; }
  trap cleanup EXIT

  say "Attaching the installed disk"
  nbd_attach "$DISK"

  local root; root=$(find_part ext4)
  [ -n "$root" ] || die "no ext4 partition on $NBD -- did the install finish?"
  ok "root is $root"

  sudo mount "$root" "$mnt" || die "cannot mount $root"
  [ -d "$mnt/etc" ] || die "$root has no /etc -- that is not a root filesystem"

  # Confirm OEM mode actually took. If the installer was driven through the
  # normal entry by mistake, everything below still "works" and the image ends
  # up with a fixed account instead of a wizard -- a failure you would not find
  # until you handed the stick to somebody.
  if [ -e "$mnt/var/lib/oem-config" ] || sudo chroot "$mnt" dpkg -s oem-config >/dev/null 2>&1; then
    ok "oem-config is present -- the OEM boot entry was used"
  else
    bad "oem-config is NOT installed in this image"
    info "The install was almost certainly done from the normal boot entry."
    die "start over with 'OEM install (for manufacturers)' -- see ./oem-image.sh install"
  fi

  say "Adding a serial console"
  sudo mkdir -p "$mnt/etc/systemd/system/serial-getty@ttyS0.service.d"
  sudo tee "$mnt/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" >/dev/null <<'EOF'
# ADDED BY oem-image.sh wire -- REMOVED BY oem-image.sh seal.
# A root autologin on a serial port. Fine on a disk that exists only inside a
# VM on a trusted host; absolutely not something to ship.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF
  sudo tee "$mnt/etc/default/grub.d/99-oem-build.cfg" >/dev/null <<'EOF'
# ADDED BY oem-image.sh wire -- REMOVED BY oem-image.sh seal.
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyS0,115200"
GRUB_TERMINAL="console serial"
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu

# os-prober OFF while building, and this is not about speed.
#
# update-grub here runs in a chroot on the BUILD HOST, so os-prober scans the
# host's disks and cheerfully writes a boot entry for the build server's own
# operating system into the image. Observed, not theorised: the first wire run
# added "Ubuntu 24.04.4 LTS on /dev/sdc4" -- iteration8's root -- to a public
# image, carrying its root UUID with it. Exactly the build-host contamination
# this repo has been scrubbing out of tracked files.
#
# It is set HERE, in the file seal deletes, so the shipped image keeps Mint's
# default. On a MacBook os-prober is how a macOS partition gets a menu entry,
# and disabling that permanently would be a real loss on the target hardware.
GRUB_DISABLE_OS_PROBER=true
EOF

  local m
  for m in dev dev/pts proc sys; do sudo mount --bind "/$m" "$mnt/$m" || die "bind /$m failed"; done
  local esp; esp=$(find_part vfat)
  if [ -n "$esp" ]; then
    sudo mount "$esp" "$mnt/boot/efi" || warn "could not mount the ESP ($esp)"
  else
    warn "no ESP found -- update-grub will still write grub.cfg, which is what we need"
  fi
  sudo chroot "$mnt" update-grub 2>&1 | sed 's/^/    /'

  # Verify rather than hope -- if console=ttyS0 did not reach grub.cfg then
  # provision will hang on a socket nothing ever writes to, which looks like a
  # dead VM rather than a missing kernel argument.
  if sudo grep -q "console=ttyS0" "$mnt/boot/grub/grub.cfg"; then
    ok "grub.cfg carries console=ttyS0"
  else
    die "console=ttyS0 did not reach grub.cfg -- provision would hang"
  fi

  cleanup; trap - EXIT
  ok "wired"
  echo
  info "Next:  ./oem-image.sh provision"
}

# ---- provision ---------------------------------------------------------------

cmd_provision() {
  [ -s "$DISK" ] || die "no $DISK -- run install and wire first"
  local repo="${MBA_OEM_REPO:-$WORK}"
  [ -x "$repo/machine-provision.sh" ] || die "machine-provision.sh not in $repo (set MBA_OEM_REPO)"

  vm_stop
  say "Booting the installed system"
  vm_boot_headless "$DISK"
  info "waiting for a login on the serial console (up to 5 minutes)"
  wait_for_guest 60 || { bad "no serial login"; die "see $WORK/oem-qemu.log, and check ./oem-image.sh wire ran"; }
  ok "guest is up: $(guest 'hostnamectl --static' 8 | tail -2 | head -1)"

  # Hand the scripts over via HTTP on the user-mode gateway rather than typing
  # them down a 115200 serial line.
  say "Sending the fix scripts in"
  local tar="$WORK/oem-payload.tar.gz"
  tar -czf "$tar" -C "$repo" --exclude='.git' --exclude='*.qcow2' --exclude='*.iso' \
      $(cd "$repo" && ls *.sh 2>/dev/null) 2>/dev/null || die "could not build the payload"
  # Send the vaulted camera firmware in too, if there is one.
  #
  # Without it every image build byte-range-fetches a 2016 macOS update image
  # from Apple's CDN -- a dependency whose usual failure mode is Apple moving
  # the URL. With it, building an image needs the archive and nothing from
  # Apple. mba-webcam.sh still verifies the checksum and still falls back to the
  # network, so a stale or wrong cache cannot silently poison an image.
  local vault="${MBA_FW_VAULT:-$HOME/archive/facetimehd/firmware.bin}"
  local have_fw=0
  if [ -s "$vault" ]; then
    cp "$vault" "$WORK/oem-firmware.bin" && have_fw=1
    ok "camera firmware found in the vault -- this build needs nothing from Apple"
  else
    info "no vaulted firmware at $vault -- the guest will fetch from Apple's CDN"
  fi

  ( cd "$WORK" && exec python3 -m http.server 8099 --bind 0.0.0.0 >/dev/null 2>&1 ) &
  local srv=$!
  sleep 2
  # rm -rf FIRST. Extracting over the top leaves whatever a PREVIOUS provision
  # put there, and the toolkit is copied from this directory -- so a script that
  # has since been removed from the payload still ships. Found the hard way:
  # deleting two build drivers from the repo did nothing, because the guest's
  # /opt/mba still held the copies extracted on the run before.
  guest 'rm -rf /opt/mba && mkdir -p /opt/mba && cd /opt/mba && curl -sS -o p.tgz http://10.0.2.2:8099/oem-payload.tar.gz && tar xzf p.tgz && chmod +x *.sh && echo FE''TCHED' 30
  [ "$have_fw" = 1 ] && guest 'curl -sS -o /opt/mba/firmware.bin http://10.0.2.2:8099/oem-firmware.bin; echo rc=$?' 60
  kill "$srv" 2>/dev/null
  rm -f "$WORK/oem-firmware.bin"
  if guest_says 'ls /opt/mba/machine-provision.sh' 10 'machine-provision.sh'; then
    ok "scripts are in the guest"
  else
    die "the guest could not fetch the payload -- is its network up?"
  fi

  # The camera driver, the DKMS toolchain and the kernel headers all come off the
  # network, and DKMS builds take minutes. Detached with a status file, polled --
  # a foreground command on a serial console would time out mid-build and leave
  # no way to tell a slow build from a dead one.
  say "Applying the fixes -- DKMS builds, 10-20 minutes"
  info "machine-provision.sh apply --image does the work: it owns the ORDER, and"
  info "there is no second copy of it here to drift out of step with it."

  guest 'cat > /opt/mba/run.sh <<'"'"'EOS'"'"'
#!/bin/bash
exec >/var/log/oem-provision.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
# Use the vaulted firmware if it arrived. mba-webcam.sh checksums it and falls
# back to the Apple CDN if it does not match, so this is a shortcut and not a
# trust decision. (No apostrophes anywhere in this block: it is written through
# a single-quoted string, so one would end the string early. This comment said
# so while containing one, which is how the lesson was learned twice.)
[ -s /opt/mba/firmware.bin ] && export MBA_FW_CACHE=/opt/mba/firmware.bin
echo "STEP 1/2 machine-provision --image" > /tmp/oem.status
/opt/mba/machine-provision.sh apply --image
rc=$?
# Image-only, so it stays here rather than in machine-provision.sh: growpart is
# what lets one 20 GiB image fill a 128 GB SSD on first boot, and a machine
# being provisioned in place has no partition to grow.
echo "STEP 2/2 first-boot tooling" > /tmp/oem.status
apt-get install -y cloud-guest-utils attr || rc=$((rc + 1))
echo "DONE:rc=$rc" > /tmp/oem.status
EOS
chmod +x /opt/mba/run.sh' 15
  guest 'setsid /opt/mba/run.sh </dev/null >/dev/null 2>&1 & echo STAR''TED' 10

  local waited=0 last="" line
  while [ "$waited" -lt 2400 ]; do
    line=$(guest 'cat /tmp/oem.status' 10 | grep -E '^(STEP|DONE)' | tail -1)
    if [ -n "$line" ] && [ "$line" != "$last" ]; then
      printf '  --    %3dm  %s\n' "$((waited / 60))" "$line"; last="$line"
    fi
    case "$line" in DONE:*) break ;; esac
    sleep 20; waited=$((waited + 20))
  done
  case "$last" in
    DONE:rc=0) ok "provisioning finished" ;;
    DONE:*)    bad "provisioning failed: $last"; die "read /var/log/oem-provision.log in the guest" ;;
    *)         bad "timed out after $((waited / 60)) minutes"; die "last status: ${last:-none}" ;;
  esac

  # Ubiquity crashes on real hardware, and only on real hardware.
  #
  #   File "/usr/lib/ubiquity/ubiquity/misc.py", line 1061, in _on_got_unit_proxy
  #   AttributeError: 'NoneType' object has no attribute 'get_string'
  #
  # SystemdUnitWatcher('sound.target') calls LoadUnit, gets an object path, then
  # builds a DBus proxy for it ASYNCHRONOUSLY. sound.target is not active during
  # the wizard -- oem-config.target declares Conflicts=multi-user.target -- so
  # systemd is free to drop the unloaded unit again before the proxy caches its
  # properties. get_cached_property() then hands back None and upstream calls
  # .get_string() on it with no guard. The wizard dies on its first page.
  #
  # It is a RACE, which is why every VM build sailed through it and a 20MB/s USB
  # stick did not. The same oem-config.log shows dconf timing out in the same
  # session -- the machine was losing deadlines everywhere.
  #
  # The callback being guarded only plays the system-ready chime
  # (canberra-gtk-play, gtk_ui.py). Skipping it costs a sound effect.
  #
  # Sent as base64 because the patch contains quotes, backslashes and newlines,
  # and this goes over a serial console -- the same channel where an apostrophe
  # inside a comment has broken this script twice.
  say "Patching the ubiquity sound.target race"
  local ub_py ub_b64
  ub_py=$(cat <<'PYEOF'
import sys
p="/usr/lib/ubiquity/ubiquity/misc.py"
s=open(p).read()
old='        active_state = self.proxy.get_cached_property(\n            "ActiveState"\n        ).get_string()\n'
new='        prop = self.proxy.get_cached_property("ActiveState")\n        if prop is None:\n            return\n        active_state = prop.get_string()\n'
if new in s: print("PATCH already"); sys.exit(0)
if old not in s: print("PATCH notfound"); sys.exit(1)
open(p,"w").write(s.replace(old,new,1)); print("PATCH ok")
PYEOF
)
  ub_b64=$(printf '%s' "$ub_py" | base64 -w0)
  guest "echo $ub_b64 | base64 -d > /tmp/ubfix.py && python3 /tmp/ubfix.py \
         && python3 -m py_compile /usr/lib/ubiquity/ubiquity/misc.py; echo rc=\$?" 30 \
    | sed 's/^/      /'

  info ""
  # Leave the toolkit ON the machine, not just its effects.
  #
  # provision stages the scripts in /opt/mba and seal deletes that -- correctly,
  # it is build scaffolding. But deleting it shipped an image with working
  # hardware and no way to ASK about the hardware: no mba-wifi.sh on a laptop
  # whose only network is Wi-Fi, no client-setup.sh on a machine whose whole
  # selling point is that backups are a flip of a switch, no status commands for
  # any of it. The fixes are not the deliverable; being able to run and diagnose
  # them is.
  #
  # /opt/macbookair2014 is the real home, and a symlink goes into /etc/skel so
  # the account the wizard creates finds it in their own home directory without
  # anybody having to know the path.
  #
  # Only tracked scripts go in. Site configs (.offsite.conf, .home-backup.conf)
  # are untracked for a reason and belong to whoever built this, not to whoever
  # receives it -- the payload tar is *.sh only, so they cannot ride along.
  #
  # This runs BEFORE the checks below. It used to run after them, so a fresh
  # provision reported "toolkit installed" MISSING and then installed it -- a
  # red verdict on work the same function was about to do.
  # run.sh is on that list because THIS SCRIPT WRITES IT, into the same /opt/mba
  # the toolkit is copied from. It is the unattended provisioning runner, it is
  # meaningless on the finished machine, and it shipped in the first build that
  # had a toolkit at all.
  #
  # The wider trap: the payload is `ls *.sh` of MBA_OEM_REPO, so ANY stray script
  # in that directory is handed to whoever receives the machine. Point it at a
  # clean checkout, never at the work directory -- which also collects
  # guest-restore.sh, guest-update.sh and measure.sh at runtime.
  say "Installing the toolkit"
  # rm -rf the DESTINATION too, not just the source. Clearing /opt/mba was not
  # enough: /opt/macbookair2014 kept the copies made by the PREVIOUS build, so
  # scripts removed from the payload still shipped. Same bug as the source
  # directory, one level further down, and it survived a whole rebuild because
  # the fix looked obviously sufficient.
  guest 'rm -rf /opt/macbookair2014 && install -d /opt/macbookair2014 && cp /opt/mba/*.sh /opt/macbookair2014/ \
         && chmod +x /opt/macbookair2014/*.sh \
         && rm -f /opt/macbookair2014/oem-image.sh /opt/macbookair2014/vm-restore-test.sh \
                  /opt/macbookair2014/run.sh \
         && install -d /etc/skel \
         && ln -sfn /opt/macbookair2014 /etc/skel/macbookair2014; echo rc=$?' 30
  guest 'ls /opt/macbookair2014/ | wc -l; ls -l /etc/skel/macbookair2014 | tail -1' 20 | sed 's/^/      /'

  # THE CHECK MUST NOT BE ABLE TO MATCH ITS OWN COMMAND.
  #
  # The first version of this passed the thing it was looking for as the pattern
  # -- `find /lib/modules -name "facetimehd.ko*"` matched against "facetimehd".
  # A serial console ECHOES the command before running it, so the pattern was
  # present in the transcript no matter what the filesystem contained. Three
  # checks passed green on a guest where the camera driver had never installed,
  # and the two that failed honestly were the only two whose pattern did not
  # appear in their own command line.
  #
  # wait_for_guest already documents this trap and uses `id` because "uid=" cannot
  # appear in the echo of `id`. The same discipline, generalised: every check runs
  # a silent test and prints ONLY an exit code. "rc=0" cannot appear in a command
  # that ends in `rc=$?`.
  say "What actually landed"
  local n=0 f=0
  chk() {   # $1 = label, $2 = test expression (must print nothing)
    if guest_says "$2 >/dev/null 2>&1; echo rc=\$?" 20 'rc=0'; then
      ok "$1"; n=$((n + 1))
    else
      bad "$1"; f=$((f + 1))
    fi
  }
  chk "facetimehd firmware" 'test -s /lib/firmware/facetimehd/firmware.bin'
  chk "facetimehd module"   'test -n "$(find /lib/modules -name facetimehd.ko\*)"'
  chk "broadcom wl module"  'test -n "$(find /lib/modules -name wl.ko\*)"'
  chk "backlight udev rule" 'test -f /etc/udev/rules.d/60-applesmc-kbd-backlight.rules'
  chk "kernel-guard hook"   'test -f /etc/apt/apt.conf.d/99-mba-kernel-guard'
  chk "dkms has facetimehd" 'dkms status | grep -q facetimehd'
  chk "dkms has wl"         'dkms status | grep -q broadcom'
  chk "growpart available"  'command -v growpart'
  chk "toolkit installed"   'test -x /opt/macbookair2014/mba-wifi.sh'
  chk "toolkit in skel"     'test -L /etc/skel/macbookair2014'
  chk "ubiquity crash guard" 'grep -q "prop = self.proxy.get_cached_property" /usr/lib/ubiquity/ubiquity/misc.py'
  # The toolkit is what the recipient gets. Nothing that built the image belongs
  # in it, and twice now something has: run.sh because provision writes it into
  # the directory the toolkit is copied from, and two drivers because they were
  # parked in the payload directory and then survived in the guest across a
  # rebuild. Both were found by mounting the finished image, not by any check.
  chk "no build scripts in toolkit" \
      '! ls /opt/macbookair2014 | grep -qE "^(run|rebuild|unarm|finish|inspect|oem-image|vm-restore-test|guest-.*|measure)\.sh$"'
  echo
  if [ "$f" = 0 ]; then ok "$n/$n present"; else bad "$f of $((n + f)) missing"; fi

  info ""
  info "The modules BUILT. Whether they WORK cannot be tested here -- there is no"
  info "BCM4360, no FaceTime HD and no Apple SMC in this VM. That is what booting"
  info "the finished image on the real laptop is for."
  echo
  # EXIT NON-ZERO when a check failed. This used to only warn, so a scripted
  # run -- wire, provision, seal, verify, usb-image chained by &&  -- sailed
  # straight past a red check and sealed the image anyway. It did exactly that:
  # "FAIL no build scripts in toolkit" was printed, and eleven minutes later the
  # same run reported "VERDICT: the sealed image is intact and armed". Both
  # statements were true and the combination was worthless.
  if [ "$f" = 0 ]; then
    info "Next:  ./oem-image.sh seal"
  else
    warn "Fix the failures above before sealing."
    return 1
  fi
}

# ---- seal --------------------------------------------------------------------

cmd_seal() {
  [ -s "$DISK" ] || die "no $DISK"
  vm_running || { say "Booting to seal"; vm_boot_headless "$DISK"
                  wait_for_guest 60 || die "no serial login"; }

  say "Removing the build rig"
  # /opt/mba is the STAGING copy and goes; /opt/macbookair2014 is the installed
  # toolkit and stays. One character of difference, opposite intentions.
  guest 'rm -rf /etc/systemd/system/serial-getty@ttyS0.service.d /etc/default/grub.d/99-oem-build.cfg /opt/mba && update-grub 2>&1 | tail -2' 90
  if guest_says 'grep -c console=ttyS0 /boot/grub/grub.cfg || true' 15 '^0'; then
    ok "serial console gone from grub.cfg"
  else
    warn "console=ttyS0 may still be in grub.cfg -- harmless on a laptop, but check"
  fi

  # No disk but this one may be named in grub.cfg.
  #
  # `wire` regenerates grub in a chroot on the build host, where os-prober scans
  # the HOST's disks -- and on the first run it duly added a menu entry for
  # iteration8's own Ubuntu root, UUID and all, to an image meant to be handed
  # out. wire now disables os-prober while building, but a fix you do not check
  # is a fix you hope for, and this is the last point at which it can be caught.
  #
  # Regenerating inside the guest, where the build host's disks do not exist,
  # should clear any such entry. This confirms it did: every UUID mentioned in
  # grub.cfg must belong to a partition of this image.
  # The RESULT goes to a file and only a COUNT comes back over the wire.
  #
  # The first version of this echoed "FOREIGN $u" and then grepped the transcript
  # for FOREIGN -- so it matched the serial console's echo of its own command and
  # failed a perfectly good image, reporting a foreign UUID that was the empty
  # string. That is the self-matching trap for the second time in one session,
  # after fixing it in the provision checks an hour earlier.
  #
  # The rule that actually holds: never match a literal that appears in the
  # command. A count cannot -- the command says "n=$(wc -l ...)", the reply says
  # "foreign=0", and no echo can produce that.
  say "Checking grub.cfg names no disk but its own"
  local scan
  scan=$(guest 'own=$(blkid -o value -s UUID /dev/sda1 /dev/sda2 /dev/sda3 2>/dev/null | tr "\n" " ");
    : > /tmp/oem-foreign.txt;
    for u in $(grep -ohE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" /boot/grub/grub.cfg | sort -u); do
      case " $own " in *" $u "*) ;; *) echo "$u" >> /tmp/oem-foreign.txt ;; esac
    done; echo "foreign=$(wc -l < /tmp/oem-foreign.txt)"' 30)
  if grep -q 'foreign=0' <<< "$scan"; then
    ok "every UUID in grub.cfg belongs to this image"
  else
    bad "grub.cfg references a disk that is not part of this image:"
    guest 'cat /tmp/oem-foreign.txt' 20 | sed 's/^/      /'
    die "that is a build-host identifier -- do not ship this image"
  fi

  # First boot has to grow the filesystem, or a 20 GiB image on a 128 GB SSD
  # wastes 108 GB. cloud-init is not present on a desktop install, so this is a
  # one-shot unit that disables itself -- deliberately NOT tied to oem-config, so
  # it also works when the image is written straight to an internal disk.
  say "Arming first-boot growth"
  guest 'cat > /etc/systemd/system/oem-firstboot-grow.service <<'"'"'EOS'"'"'
[Unit]
Description=Grow the root filesystem to fill the disk, once
ConditionPathExists=!/var/lib/oem-firstboot-grown
DefaultDependencies=no
After=local-fs.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '"'"'set -e; r=$(findmnt -no SOURCE /); d=$(lsblk -no PKNAME "$r"); n=$(echo "$r" | grep -o "[0-9]*$"); growpart "/dev/$d" "$n" || true; resize2fs "$r" || true; touch /var/lib/oem-firstboot-grown'"'"'
[Install]
WantedBy=multi-user.target
EOS
systemctl enable oem-firstboot-grow.service 2>&1 | tail -1' 30
  guest_says 'systemctl is-enabled oem-firstboot-grow.service' 15 'enabled' \
    && ok "first-boot grow is enabled" || warn "could not enable the grow unit"

  # Identity. Every copy of this image would otherwise share one machine-id and
  # one set of host keys -- the clone problem this project already hit once with
  # a tailnet node key, except at fleet scale and baked in at manufacture.
  # machine-id is TRUNCATED, not deleted: systemd treats an empty file as
  # first-boot and generates one, while a missing file is an error.
  say "Clearing identity"
  guest 'truncate -s 0 /etc/machine-id; rm -f /var/lib/dbus/machine-id; rm -f /etc/ssh/ssh_host_*; rm -rf /var/lib/tailscale; echo CLE''ARED' 20
  guest_says 'wc -c < /etc/machine-id' 10 '^0$' && ok "machine-id is empty" || warn "machine-id is not empty"
  guest_says 'ls /etc/ssh/ | grep -c ssh_host || true' 10 '^0' && ok "no ssh host keys" || warn "ssh host keys still present"

  # Tidying, in two parts that are doing genuinely different jobs.
  #
  # PART ONE IS NOT ABOUT SIZE. /etc/NetworkManager/system-connections holds the
  # PSK of every wi-fi network the builder joined, in a file the wizard never
  # touches. This VM only ever had wired DHCP, so there is nothing to leak here
  # -- but the whole point of oem-image.sh is that somebody else runs it, and
  # Jenni installing over her own wi-fi would bake her house password into every
  # copy of an image meant to be handed out. Same for the installer logs, and for
  # the shell history of the serial session that provisioned it.
  say "Tidying: things that should not be handed to a stranger"
  guest 'rm -f /etc/NetworkManager/system-connections/*; \
         rm -rf /var/log/installer /var/crash/*; \
         rm -f /root/.bash_history /home/*/.bash_history; \
         rm -rf /root/.cache /home/*/.cache/thumbnails; \
         : > /var/log/wtmp 2>/dev/null; : > /var/log/btmp 2>/dev/null; \
         echo SCRU''BBED' 60
  guest_says 'ls -A /etc/NetworkManager/system-connections/ 2>/dev/null | wc -l' 15 '^0$' \
    && ok "no saved network credentials" || warn "saved network connections remain -- check them"

  say "Tidying: reclaiming space"
  guest 'apt-get clean; rm -rf /var/lib/apt/lists/*; rm -f /var/log/oem-provision.log; \
         find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null; \
         rm -rf /var/lib/dkms/*/*/build 2>/dev/null; \
         journalctl --rotate --vacuum-time=1s >/dev/null 2>&1; echo CLEA''NED' 90

  # fstrim is what actually shrinks the artefact. Deleting a file inside the
  # guest frees nothing in the qcow2 -- the cluster stays allocated and gets
  # copied forever after. The drive is opened with discard=unmap so TRIM reaches
  # the image and punches real holes.
  local before after
  before=$(du -m "$DISK" | cut -f1)
  say "Discarding freed blocks"
  guest 'fstrim -av 2>&1 | head -3' 180
  sleep 3
  after=$(du -m "$DISK" | cut -f1)
  if [ "$after" -lt "$before" ]; then
    ok "reclaimed $(( (before - after) )) MiB in the image (${before} -> ${after} MiB)"
  else
    warn "fstrim freed nothing in the image -- the convert below still compacts it"
  fi

  # oem-config-prepare LAST, and then nothing else. It arms the first-boot
  # wizard; anything done after it risks being what the wizard finds.
  say "Arming the account wizard"
  guest 'oem-config-prepare --quiet 2>&1 | tail -2; echo rc=$?' 60

  # Check the mechanism this version of oem-config ACTUALLY uses.
  #
  # The first version looked for a /var/lib/oem-config/run flag file, which is
  # how older oem-config armed itself. Mint 22.3 does it by pointing
  # default.target at oem-config.target -- so oem-config-prepare succeeded,
  # printed the symlink it had just created, returned 0, and the check called it
  # a failure and refused to seal a perfectly good image.
  #
  # Worth naming the difference from the last two bugs: those were checks that
  # PASSED without evidence. This one FAILED with evidence sitting in front of
  # it. Both come from the check and the thing being checked disagreeing about
  # what success looks like -- and only the false pass is dangerous, which is
  # exactly why it is worth erring this way round.
  if guest_says 'test "$(systemctl get-default)" = oem-config.target; echo rc=$?' 20 'rc=0'; then
    ok "armed: default.target is oem-config.target -- next boot asks for an account"
  else
    bad "default.target is not oem-config.target"
    guest 'systemctl get-default' 15 | sed 's/^/      /'
    die "the image would boot to a login prompt for the staging account"
  fi

  say "Shutting down"
  guest 'systemctl poweroff' 5 >/dev/null 2>&1
  local i; for i in $(seq 1 60); do vm_running || break; sleep 2; done
  vm_running && { warn "still running -- forcing"; vm_stop; }
  rm -f "$PIDF"
  ok "powered off cleanly"

  # Sealed as a separate file, so a half-finished run can never be mistaken for a
  # finished one: oem-sealed.qcow2 exists only if everything above passed.
  #
  # convert, not cp. A plain copy carries every cluster the image ever touched,
  # including the apt cache that was just deleted -- the qcow2 has no idea those
  # clusters are dead. convert writes only what is live, so the deletions above
  # turn into an actually smaller artefact rather than a tidier-looking guest.
  say "Compacting"
  rm -f "$SEALED"
  qemu-img convert -O qcow2 "$DISK" "$SEALED" || die "could not write $SEALED"
  local raw_mb sealed_mb
  raw_mb=$(du -m "$DISK" | cut -f1); sealed_mb=$(du -m "$SEALED" | cut -f1)
  ok "$(basename "$SEALED") sealed: $(du -h "$SEALED" | cut -f1) of ${OEM_GB}G virtual"
  info "compaction saved $(( raw_mb - sealed_mb )) MiB over a straight copy"
  echo
  info "Confirm it before trusting it -- on a COPY, because verifying by booting"
  info "consumes the very wizard you are checking for:"
  info "    ./oem-image.sh verify"
  echo
  info "Then make it bootable from USB, which rewrites its UUIDs so it cannot"
  info "fight the internal disk:"
  info "    ./vm-restore-test.sh usb-image $(basename "$SEALED")"
  echo
}

# ---- verify ------------------------------------------------------------------

# Boot a THROWAWAY OVERLAY, never the sealed image.
#
# oem-config runs once and then removes its own flag. Booting the sealed image to
# check the wizard appears would consume it, and hand somebody a stick that goes
# straight to a login prompt for an account they do not have the password for.
cmd_verify() {
  [ -s "$SEALED" ] || die "no $SEALED -- run ./oem-image.sh seal first"
  vm_stop
  local scratch="$WORK/oem-verify.qcow2"
  rm -f "$scratch"
  qemu-img create -f qcow2 -b "$SEALED" -F qcow2 "$scratch" >/dev/null \
    || die "cannot create the throwaway overlay"
  ok "booting a throwaway overlay -- $(basename "$SEALED") is not touched"

  say "Booting"
  vm_boot_headless "$scratch"
  info "the wizard is graphical, so there will be NO serial login -- that is the"
  info "expected result here, and a serial login would mean it is NOT armed"
  sleep 120

  if guest_says 'id' 10 'uid='; then
    bad "got a root shell on the serial console"
    die "this image boots to a logged-in system, not an account wizard"
  fi
  ok "no serial shell, as expected"

  # ...but ON ITS OWN that proves very little, and pretending otherwise would be
  # the same self-congratulation this project keeps catching. "No serial login"
  # is equally consistent with "the graphical wizard is running" and "the kernel
  # panicked before reaching userspace". Absence of evidence, read as evidence.
  #
  # The overlay is the discriminator: a system that reached userspace writes --
  # journal, logs, oem-config state -- and every one of those writes lands in the
  # overlay because the backing file is read-only. A qcow2 that is still nearly
  # empty means nothing ever ran.
  local grew; grew=$(du -m "$scratch" | cut -f1)
  if [ "${grew:-0}" -ge 8 ]; then
    ok "the overlay grew to ${grew} MiB -- userspace ran and wrote to disk"
  else
    bad "the overlay is only ${grew} MiB -- nothing wrote to it"
    warn "that means this did NOT boot, and the check above passed for the wrong reason"
    warn "look at it directly:  ./oem-image.sh preview"
  fi

  # Ask the DISK, not the screen. The flag file is the thing that decides, and
  # the question is about the sealed image -- which the overlay has been
  # protecting all along. Checking the overlay would only tell us what one boot
  # did to a scratch file; checking the sealed image tells us what the next
  # person gets.
  vm_stop; sleep 2
  local mnt="$WORK/oem-mnt"; mkdir -p "$mnt"
  local verdict=0

  nbd_attach "$SEALED"
  local root; root=$(find_part ext4)
  [ -n "$root" ] || { nbd_detach; die "no ext4 partition in the sealed image"; }
  sudo mount -o ro "$root" "$mnt" || { nbd_detach; die "cannot mount the sealed image"; }
  if sudo test -s "$mnt/etc/machine-id"; then bad "the sealed image has a machine-id"; verdict=1
  else ok "machine-id is still empty -- every copy will generate its own"; fi
  # Same mechanism seal checks, read off the disk instead of from inside a guest:
  # Mint 22.3 arms the wizard by pointing default.target at oem-config.target,
  # not by leaving a run flag.
  local deftgt; deftgt=$(sudo readlink "$mnt/etc/systemd/system/default.target" 2>/dev/null)
  if grep -q oem-config.target <<< "$deftgt"; then
    ok "still armed -- the boot above consumed nothing"
  else
    bad "NOT armed -- this would boot to a login prompt"
    sed 's/^/      now: /' <<< "$deftgt"
    verdict=1
  fi
  if sudo sh -c "ls '$mnt'/etc/ssh/ssh_host_* >/dev/null 2>&1"; then
    bad "the sealed image carries ssh host keys"; verdict=1
  else ok "no ssh host keys"; fi
  sudo umount "$mnt" 2>/dev/null; nbd_detach
  rm -f "$scratch"

  echo
  [ "$verdict" = 0 ] && ok "VERDICT: the sealed image is intact and armed" \
                     || bad "VERDICT: do not ship this image"
  echo
  return "$verdict"
}

# ---- preview -----------------------------------------------------------------

# Boot the sealed image on screen, so a human can watch the first-boot wizard.
#
# ALWAYS ON A THROWAWAY OVERLAY, for the same reason verify is: oem-config runs
# once and deletes its own flag. Booting the sealed image to look at the wizard
# would consume the thing being looked at, and the stick you handed out would go
# straight to a login prompt for an account nobody has the password for. The
# overlay makes this repeatable -- click all the way through the wizard, create a
# fake account, prove the whole path works, then throw the overlay away and the
# sealed image is untouched.
#
# This is also the closest a VM can get to the real test. It proves the image
# BOOTS and the wizard RUNS. It cannot prove Wi-Fi associates, the camera
# captures or the backlight lights: no BCM4360, no FaceTime HD, no Apple SMC.
# That is what usb-image and the real laptop are for.
cmd_preview() {
  [ -s "$SEALED" ] || die "no $SEALED -- run ./oem-image.sh seal first"
  vm_stop
  local scratch="$WORK/oem-preview.qcow2"
  rm -f "$scratch"
  qemu-img create -f qcow2 -b "$SEALED" -F qcow2 "$scratch" >/dev/null \
    || die "cannot create the throwaway overlay"
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS" || die "cannot copy OVMF vars"
  rm -f "$SOCK"

  qemu-system-x86_64 -enable-kvm -cpu host -smp "$SMP" -m "$RAM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$VARS" \
    -device ich9-ahci,id=ahci \
    -drive file="$scratch",if=none,id=t0,format=qcow2 -device ide-hd,bus=ahci.0,drive=t0 \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -device ich9-intel-hda -device hda-duplex \
    -vga std -vnc "127.0.0.1:$VNC_DISP" \
    -serial "unix:$SOCK,server,nowait" \
    -monitor "unix:$WORK/oem-mon.sock,server,nowait" \
    -pidfile "$PIDF" > "$WORK/oem-qemu.log" 2>&1 &

  local i; for i in $(seq 1 30); do vm_running && break; sleep 1; done
  vm_running || die "qemu did not start -- see $WORK/oem-qemu.log"

  ok "booting oem-preview.qcow2 -- $(basename "$SEALED") is NOT touched"
  echo
  info "From your laptop:"
  echo "    ssh -N -L $((5900 + VNC_DISP)):localhost:$((5900 + VNC_DISP)) $(hostname)"
  echo "    vncviewer localhost:$((5900 + VNC_DISP))"
  echo
  info "Expect: Mint boots, then the OEM wizard asks for language, keyboard,"
  info "timezone and an account. That is the whole point of the image."
  info "Click all the way through if you like -- it is a scratch overlay."
  echo
  info "When done:  ./oem-image.sh stop   (then rm $scratch)"
  echo
}

# Capture the framebuffer.
#
# Added because "it booted" is a report and a screenshot is evidence -- and the
# distinction between those two has been the whole theme of building this. The
# restore rig has had this since the beginning; preview shipped without it and
# the gap showed up the first time somebody needed to say what was on screen.
cmd_screenshot() {
  [ -S "$WORK/oem-mon.sock" ] || die "no monitor socket -- only 'preview' opens one, and only since this was added (restart it)"
  local out="${1:-$WORK/oem-screen.ppm}"
  python3 "$WORK/mon.py" "$WORK/oem-mon.sock" "screendump $out" >/dev/null 2>&1
  sleep 1
  [ -s "$out" ] || die "screendump produced nothing"
  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$out" > "${out%.ppm}.png" 2>/dev/null && out="${out%.ppm}.png"
  elif command -v convert >/dev/null 2>&1; then
    convert "$out" "${out%.ppm}.png" 2>/dev/null && out="${out%.ppm}.png"
  fi
  ok "screenshot: $out ($(du -h "$out" | cut -f1))"
}

# ---- status ------------------------------------------------------------------

cmd_status() {
  say "OEM image"
  printf '    %-16s %s\n' "ISO"    "$([ -s "$ISO" ] && echo "$(basename "$ISO") ($(du -h "$ISO" | cut -f1))" || echo "MISSING")"
  printf '    %-16s %s\n' "disk"   "$([ -s "$DISK" ] && du -h "$DISK" | cut -f1 || echo "not created")"
  printf '    %-16s %s\n' "sealed" "$([ -s "$SEALED" ] && du -h "$SEALED" | cut -f1 || echo "not sealed")"
  printf '    %-16s %s\n' "VM"     "$(vm_running && echo "running (pid $(cat "$PIDF"))" || echo "stopped")"
  if vm_running; then
    printf '    %-16s %s\n' "VNC" "127.0.0.1:$((5900 + VNC_DISP)) on $(hostname)"
  fi
  echo
}

case "${1:-}" in
  install)   cmd_install ;;
  wire)      cmd_wire ;;
  provision) cmd_provision ;;
  seal)      cmd_seal ;;
  verify)    cmd_verify ;;
  preview)   cmd_preview ;;
  screenshot) cmd_screenshot "${2:-}" ;;
  status)    cmd_status ;;
  stop)      vm_stop; ok "stopped" ;;
  sh)        guest "${2:-id}" "${3:-10}" ;;
  *) cat <<EOF

oem-image.sh -- Mint + this repo's fixes, as an image to hand somebody

  install     create the disk and boot the ISO      <- the one manual step
  wire        add a serial console, offline
  provision   apply the fixes, unattended
  seal        strip the rig, clear identity, arm the wizard
  verify      boot a throwaway copy and check
  preview     boot a throwaway copy ON SCREEN, to watch the wizard
  screenshot  capture what preview is showing
  status      where things stand
  stop        kill the VM
  sh CMD      run CMD in the running guest

Env: MBA_OEM_GB (default $OEM_GB), MBA_OEM_ISO, MBA_OEM_VNC (default $VNC_DISP),
     MBA_OEM_SMP, MBA_OEM_RAM, MBA_OEM_REPO

EOF
     exit 1 ;;
esac
