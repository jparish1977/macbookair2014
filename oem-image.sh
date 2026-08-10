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
  ( cd "$WORK" && exec python3 -m http.server 8099 --bind 0.0.0.0 >/dev/null 2>&1 ) &
  local srv=$!
  sleep 2
  guest 'mkdir -p /opt/mba && cd /opt/mba && curl -sS -o p.tgz http://10.0.2.2:8099/oem-payload.tar.gz && tar xzf p.tgz && chmod +x *.sh && echo FE''TCHED' 30
  kill "$srv" 2>/dev/null
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

  say "What actually landed"
  local n=0 f=0
  chk() {   # $1 = label, $2 = command, $3 = pattern
    if guest_says "$2" 15 "$3"; then ok "$1"; n=$((n + 1)); else bad "$1"; f=$((f + 1)); fi
  }
  chk "facetimehd firmware"  'ls -l /lib/firmware/facetimehd/firmware.bin' 'firmware.bin'
  chk "facetimehd module"    'find /lib/modules -name "facetimehd.ko*"'    'facetimehd'
  chk "broadcom wl module"   'find /lib/modules -name "wl.ko*"'            'wl.ko'
  chk "backlight udev rule"  'ls /etc/udev/rules.d/'                       'applesmc-kbd-backlight'
  chk "kernel-guard hook"    'ls /etc/apt/apt.conf.d/'                     'mba-kernel-guard'
  chk "dkms present"         'dkms status'                                 'facetimehd'
  chk "growpart available"   'command -v growpart'                         'growpart'
  echo
  if [ "$f" = 0 ]; then ok "$n/$n present"; else bad "$f of $((n + f)) missing"; fi

  info ""
  info "The modules BUILT. Whether they WORK cannot be tested here -- there is no"
  info "BCM4360, no FaceTime HD and no Apple SMC in this VM. That is what booting"
  info "the finished image on the real laptop is for."
  echo
  [ "$f" = 0 ] && info "Next:  ./oem-image.sh seal" \
               || warn "Fix the failures above before sealing."
}

# ---- seal --------------------------------------------------------------------

cmd_seal() {
  [ -s "$DISK" ] || die "no $DISK"
  vm_running || { say "Booting to seal"; vm_boot_headless "$DISK"
                  wait_for_guest 60 || die "no serial login"; }

  say "Removing the build rig"
  guest 'rm -rf /etc/systemd/system/serial-getty@ttyS0.service.d /etc/default/grub.d/99-oem-build.cfg /opt/mba && update-grub 2>&1 | tail -2' 90
  if guest_says 'grep -c console=ttyS0 /boot/grub/grub.cfg || true' 15 '^0'; then
    ok "serial console gone from grub.cfg"
  else
    warn "console=ttyS0 may still be in grub.cfg -- harmless on a laptop, but check"
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
  if guest_says 'ls /var/lib/oem-config/' 15 'run'; then
    ok "oem-config is armed -- next boot asks for an account"
  else
    bad "oem-config-prepare did not leave its run flag"
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
  if sudo test -e "$mnt/var/lib/oem-config/run"; then ok "still armed -- the boot above consumed nothing"
  else bad "NOT armed -- this would boot to a login prompt"; verdict=1; fi
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
  status      where things stand
  stop        kill the VM
  sh CMD      run CMD in the running guest

Env: MBA_OEM_GB (default $OEM_GB), MBA_OEM_ISO, MBA_OEM_VNC (default $VNC_DISP),
     MBA_OEM_SMP, MBA_OEM_RAM, MBA_OEM_REPO

EOF
     exit 1 ;;
esac
