#!/bin/bash
# Rehearse a full disaster recovery in a VM: offsite copy -> bootable system.
#
# WHAT THIS IS FOR
#
# snapshot-offsite.sh proves the copy is faithful at the file level, and
# restore-test.sh proves timeshift restores on real hardware. Neither answers the
# question that actually matters after a dead disk: starting from nothing but the
# offsite copy, can you rebuild a machine that BOOTS? This does that in a VM, so
# finding out costs an evening rather than a laptop.
#
# WHERE IT RUNS
#
# On the machine holding the offsite copy -- iteration8, not the laptop. The
# snapshot data is local there, so nothing crosses Wi-Fi, and a 4GB laptop is a
# poor VM host. Copy this script over and run it there:
#
#     scp vm-restore-test.sh iteration8:/srv/mba-vmtest/
#
# HOW IT AVOIDS NEEDING A SCREEN
#
# The whole thing is headless and scriptable, which took some doing:
#
#   * The VM boots UEFI (OVMF), because the laptop does and the ESP is part of
#     what is being restored. qemu's -kernel direct boot DOES work alongside
#     OVMF, which is what lets us set kernel arguments without a boot menu.
#   * console=ttyS0 + systemd.unit=multi-user.target gives a text-mode live
#     session on a serial port instead of a desktop.
#   * That serial port is a unix socket, driven by a small python conversation
#     helper, so every step can be scripted rather than typed.
#
# THE LIVE SESSION CANNOT BE LOGGED INTO, AND WHY
#
# Mint 22.3's live user is `linux` and its password hash is crypt("") --
# U6aMy0wojraho. That looks like "empty password works". It does not: pam_unix
# without `nullok` refuses an EMPTY ENTERED password before it ever compares the
# hash, so a serial getty can never be logged into. Guessing passwords is a dead
# end; the fix is to bypass PAM's password path entirely with autologin.
#
# So `prepare` unpacks the ISO's initrd, patches casper's own 15autologin hook to
# also write a serial-getty autologin drop-in, and repacks it. That is the single
# non-obvious step this whole script exists to remember.
#
# A RESTORED CLONE IS NOT A COPY OF YOUR SYSTEM. IT IS A SECOND INSTANCE OF ITS
# IDENTITY -- AND IT WILL FIGHT THE ORIGINAL FOR IT.
#
# This cost an hour of misdiagnosis on 2026-08-09, twice, and it is the single
# most important thing this script knows.
#
# The snapshot contains the system side, and machine identity lives there:
#
#     /var/lib/tailscale/tailscaled.state    the tailnet NODE KEY
#     /etc/machine-id, /var/lib/dbus/machine-id
#     /etc/ssh/ssh_host_*_key                the host's ssh identity
#
# Boot the restored clone with a route to the internet and its tailscaled starts
# up and registers with the SAME node key as the machine it was cloned from. The
# coordination server treats them as one node and follows whoever reported last,
# so the ORIGINAL LAPTOP GETS KNOCKED OFF ITS OWN TAILNET. It presents as a dead
# peer -- ssh times out, tailscale ping gets no reply, other peers fail too --
# which reads exactly like the remote host having crashed. It has not. Killing
# the clone restores the original immediately, with no tailscale restart needed.
#
# In a genuine recovery this does not arise: the original is dead, which is why
# you are restoring. It arises in REHEARSAL, where both are alive at once. A test
# that sabotages the machine it is testing for is worse than no test.
#
# Hence `bootdisk` runs the restored system with `-netdev user,restrict=on`: the
# guest gets a working NIC and DHCP but no route off the host. Never give a
# restored clone real network access while the original is running.
#
# HOW THE SNAPSHOT TREE REACHES THE GUEST
#
# Not over ssh, and not by sharing a directory. A --fake-super archive can only
# be decoded by an rsync SENDER that knows about it, and a local copy has no
# remote sender to tell. An rsync DAEMON with `fake super = yes` is the
# documented answer: it decodes on the way out, needs no ssh keys and no
# password, and binds to loopback so nothing is exposed. From inside the guest
# the host is always 10.0.2.2 under user-mode networking.

set -uo pipefail

WORK="${MBA_VMTEST_DIR:-/srv/mba-vmtest}"
SNAPSRC="${MBA_VMTEST_SNAPSRC:-/srv/mba-snapshots}"
ISO_URL="${MBA_VMTEST_ISO_URL:-https://mirrors.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-xfce-64bit.iso}"
ISO="$WORK/$(basename "$ISO_URL")"
RSYNC_PORT="${MBA_VMTEST_RSYNC_PORT:-8730}"
VM_RAM="${MBA_VMTEST_RAM:-4096}"      # match the laptop: 4G
VM_CPUS="${MBA_VMTEST_CPUS:-2}"       # match the laptop: 2 cores
TARGET_GB=40
CARRIER_GB=30

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "  WARN  $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; }
info() { echo "  --    $*"; }

# Two pgrep traps, both of which cost real time to diagnose:
#
#   pgrep -f PATTERN  also matches THIS script, because our own command line
#                     contains the pattern. It once killed the session that ran
#                     it. Anchor with ^ so a shell invocation cannot match.
#   pgrep -x NAME     silently matches nothing when NAME is over 15 characters,
#                     and "qemu-system-x86_64" is 19.
#
# There is also a live batocera VM on this host. Only ever kill our own pidfile.
qemu_pids() { pgrep -f '^qemu-system-x86_64' 2>/dev/null; }
our_qemu()  { [ -f "$WORK/qemu.pid" ] && cat "$WORK/qemu.pid" 2>/dev/null; }

usage() {
  cat <<EOF
usage: $0 prepare        fetch the ISO, make disks, patch the initrd for autologin
       $0 serve          start the loopback rsync daemon that decodes --fake-super
       $0 boot           launch the VM headless, serial on a unix socket
       $0 sh "COMMAND"   run a command in the guest and print what it says
       $0 bootdisk       boot the RESTORED system off the disk (network restricted)
       $0 screenshot     capture the guest's framebuffer (it has no serial console)
       $0 steps          the in-guest restore procedure
       $0 status         what exists and what is running
       $0 stop           stop OUR vm and daemon (never touches other VMs)
       $0 clean          stop, then delete the disks (keeps the ISO)

Run on the host holding the offsite copy, not on the laptop.
Work dir $WORK, snapshots from $SNAPSRC.
EOF
  exit 1
}

# ------------------------------------------------------------------- prepare

cmd_prepare() {
  mkdir -p "$WORK" || die "cannot create $WORK"
  cd "$WORK" || die

  local m
  for m in qemu-system-x86_64 qemu-img 7z unmkinitramfs cpio gzip rsync python3 curl; do
    command -v "$m" >/dev/null || die "missing: $m"
  done
  [ -e /dev/kvm ] || die "no /dev/kvm -- this needs hardware virtualisation"
  ls /usr/share/OVMF/OVMF_CODE_4M.fd >/dev/null 2>&1 \
    || die "OVMF missing (sudo apt install ovmf) -- UEFI is not optional here,
       the laptop boots EFI and the ESP is part of what gets restored"
  [ -d "$SNAPSRC" ] || die "no offsite copy at $SNAPSRC"
  ok "dependencies, /dev/kvm and OVMF present"

  if [ ! -s "$ISO" ]; then
    echo "  fetching $(basename "$ISO") ..."
    curl -sSL -C - -o "$ISO" "$ISO_URL" || die "download failed"
  fi
  file -b "$ISO" | grep -q ISO || die "$ISO is not an ISO image"
  ok "ISO present ($(du -h "$ISO" | cut -f1))"

  qemu-img create -f qcow2 "$WORK/target.qcow2"  "${TARGET_GB}G"  >/dev/null || die
  qemu-img create -f qcow2 "$WORK/carrier.qcow2" "${CARRIER_GB}G" >/dev/null || die
  ok "disks: target ${TARGET_GB}G, carrier ${CARRIER_GB}G"

  # Kernel + initrd for direct boot. Direct boot is what lets us pass
  # console=ttyS0 without a boot menu we would need a screen to use.
  rm -rf "$WORK/bootextract"
  7z x -o"$WORK/bootextract" "$ISO" "casper/vmlinuz*" "casper/initrd*" >/dev/null 2>&1
  [ -s "$WORK/bootextract/casper/vmlinuz" ] || die "no kernel found inside the ISO"
  local ird; ird=$(ls "$WORK"/bootextract/casper/initrd* 2>/dev/null | head -1)
  [ -n "$ird" ] || die "no initrd found inside the ISO"
  ok "extracted kernel and $(basename "$ird")"

  # The autologin patch. See the header for why this is unavoidable.
  rm -rf "$WORK/ird"; mkdir -p "$WORK/ird"
  ( cd "$WORK/ird" && unmkinitramfs "$ird" . >/dev/null 2>&1 ) || die "could not unpack the initrd"
  local hook="$WORK/ird/main/scripts/casper-bottom/15autologin"
  [ -f "$hook" ] || die "casper's 15autologin hook is not where it was -- the ISO layout changed"

  if ! grep -q 'serial-getty' "$hook"; then
    python3 - "$hook" <<'PY' || die "patching 15autologin failed"
import sys
p = sys.argv[1]; s = open(p).read().rstrip()
assert s.endswith('log_end_msg'), 'unexpected tail in 15autologin'
add = '''
# --- serial autologin, added by vm-restore-test.sh ---
# The live user's hash is crypt("") and pam_unix without nullok rejects an empty
# entered password outright, so a serial getty can never be logged into.
# Autologin skips PAM's password path entirely.
if [ -d /root/etc/systemd/system ]; then
    mkdir -p /root/etc/systemd/system/serial-getty@ttyS0.service.d
    cat > /root/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I 115200 vt220
EOF
fi

log_end_msg'''
open(p, 'w').write(s[:-len('log_end_msg')].rstrip('\n') + '\n' + add + '\n')
PY
  fi

  # Repack. The early cpios (microcode) stay uncompressed and go first; only the
  # main archive is compressed. --owner=root:root because we are repacking as an
  # ordinary user and the initramfs must not end up owned by uid 1000.
  rm -f "$WORK/initrd.new"
  local d
  for d in early early2 early3; do
    [ -d "$WORK/ird/$d" ] && \
      ( cd "$WORK/ird/$d" && find . | cpio -o -H newc --owner=root:root --quiet ) >> "$WORK/initrd.new"
  done
  ( cd "$WORK/ird/main" && find . | cpio -o -H newc --owner=root:root --quiet | gzip -1 ) >> "$WORK/initrd.new"
  [ -s "$WORK/initrd.new" ] || die "repacked initrd is empty"
  ok "initrd repacked with serial autologin ($(du -h "$WORK/initrd.new" | cut -f1))"

  # The conversation helper. One connection per exchange: qemu's unix serial
  # takes a single client, and splitting a login across connections loses state.
  cat > "$WORK/conv.py" <<'PY'
import socket, sys, time
sock, steps = sys.argv[1], sys.argv[2:]     # alternating: text, seconds
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sock); s.settimeout(0.4)
out = b""
def drain(sec):
    global out
    end = time.time() + sec
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d: break
            out += d
        except socket.timeout: pass
drain(1.0)
for i in range(0, len(steps), 2):
    s.sendall((steps[i] + "\n").encode()); drain(float(steps[i+1]))
sys.stdout.write(out.decode("utf-8", "replace"))
PY
  ok "prepared. Next:  $0 serve  &&  $0 boot"
}

# --------------------------------------------------------------------- serve

cmd_serve() {
  cd "$WORK" || die "run '$0 prepare' first"
  # Default lock/pid/log live under /var/run and need root. Keep them here.
  cat > "$WORK/rsyncd.conf" <<EOF
use chroot = false
lock file = $WORK/rsyncd.lock
pid file  = $WORK/rsyncd.pid
log file  = $WORK/rsyncd.log
[snapshots]
    path = $SNAPSRC
    read only = true
    fake super = yes
EOF
  pgrep -f "^rsync --daemon --config=$WORK" >/dev/null && { ok "daemon already running"; return 0; }
  ( rsync --daemon --config="$WORK/rsyncd.conf" --port="$RSYNC_PORT" --address=127.0.0.1 >/dev/null 2>&1 & )
  sleep 2
  rsync --port="$RSYNC_PORT" rsync://127.0.0.1/ >/dev/null 2>&1 \
    && ok "rsync daemon on 127.0.0.1:$RSYNC_PORT, module 'snapshots', fake super on" \
    || die "daemon did not start -- see $WORK/rsyncd.log"

  # Prove it DECODES rather than serving the raw fake-super tree. A setuid file
  # reported as 0755, or owned by this user, means the archive is being served
  # verbatim and anything restored from it would be unusable.
  local snap probe
  snap=$(ls -1 "$SNAPSRC" | sort | tail -1)
  probe=$(rsync --port="$RSYNC_PORT" --numeric-ids \
          "rsync://127.0.0.1:$RSYNC_PORT/snapshots/$snap/localhost/usr/bin/sudo" 2>/dev/null)
  case "$probe" in
    -rwsr-xr-x*) ok "fake-super decoding confirmed: sudo is still setuid over the wire" ;;
    "")          warn "could not probe usr/bin/sudo in $snap" ;;
    *)           bad "sudo comes over as: $probe"
                 echo "        Expected -rwsr-xr-x. The daemon is NOT decoding --fake-super,"
                 echo "        so anything restored through it would lose every mode and owner."
                 return 1 ;;
  esac
}

# ---------------------------------------------------------------------- boot

cmd_boot() {
  cd "$WORK" || die "run '$0 prepare' first"
  [ -s "$WORK/initrd.new" ] || die "no patched initrd -- run '$0 prepare'"

  local mine; mine=$(our_qemu)
  if [ -n "$mine" ] && kill -0 "$mine" 2>/dev/null; then
    ok "our VM is already running (pid $mine). '$0 stop' first to restart it."
    return 0
  fi

  rm -f "$WORK/serial.sock"
  cp /usr/share/OVMF/OVMF_VARS_4M.fd "$WORK/vars.fd" || die "cannot copy OVMF vars"

  # AHCI rather than virtio so the guest sees /dev/sda like the real machine.
  # The laptop's initramfs is MODULES=most so virtio would work too, but there is
  # no reason to introduce a difference the restored system has never seen.
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$VM_CPUS" -m "$VM_RAM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -device ich9-ahci,id=ahci \
    -drive file="$WORK/target.qcow2",if=none,id=t0,format=qcow2  -device ide-hd,bus=ahci.0,drive=t0 \
    -drive file="$WORK/carrier.qcow2",if=none,id=c0,format=qcow2 -device ide-hd,bus=ahci.1,drive=c0 \
    -drive file="$ISO",if=none,id=cd0,media=cdrom,readonly=on    -device ide-cd,bus=ahci.2,drive=cd0 \
    -kernel "$WORK/bootextract/casper/vmlinuz" -initrd "$WORK/initrd.new" \
    -append "boot=casper console=ttyS0,115200 systemd.unit=multi-user.target ---" \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -serial "unix:$WORK/serial.sock,server,nowait" -display none \
    -pidfile "$WORK/qemu.pid" > "$WORK/qemu.log" 2>&1 &

  local i
  for i in $(seq 1 60); do [ -S "$WORK/serial.sock" ] && break; sleep 1; done
  [ -S "$WORK/serial.sock" ] || die "qemu never created the serial socket -- see $WORK/qemu.log"
  ok "VM started (pid $(cat "$WORK/qemu.pid" 2>/dev/null)), booting the live session"
  echo "  give it ~50s, then:  $0 sh 'id'"
}

# Boot the RESTORED system off the target disk -- no ISO, no -kernel, so the
# firmware has to find the bootloader itself. That is the whole question.
#
# restrict=on is not optional. See the identity warning in the header: with a
# route to the internet this clone will claim the original's tailnet node key and
# knock it offline. restrict=on still gives the guest a NIC and a DHCP lease, so
# the system boots normally and you can see whether networking came up -- it just
# cannot reach anything beyond the emulated network.
#
# The restored system's grub.cfg came from a laptop that boots to a screen, so it
# has no console=ttyS0 and the serial port stays SILENT. That is expected, not a
# failure. Use `screenshot` to see the console.
cmd_bootdisk() {
  cd "$WORK" || die "run '$0 prepare' first"
  [ -s "$WORK/target.qcow2" ] || die "no target disk -- has a restore been done?"

  local mine; mine=$(our_qemu)
  [ -n "$mine" ] && kill -0 "$mine" 2>/dev/null && { kill "$mine"; sleep 3; }
  rm -f "$WORK/serial.sock" "$WORK/mon.sock"

  cat > "$WORK/mon.py" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(sys.argv[1]); s.settimeout(0.5)
def drain(sec):
    out, end = b"", time.time() + sec
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d: break
            out += d
        except socket.timeout: pass
    return out
drain(1.0); s.sendall((sys.argv[2] + "\n").encode())
sys.stdout.write(drain(4).decode("utf-8", "replace"))
PY

  qemu-system-x86_64 -enable-kvm -cpu host -smp "$VM_CPUS" -m "$VM_RAM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -device ich9-ahci,id=ahci \
    -drive file="$WORK/target.qcow2",if=none,id=t0,format=qcow2 -device ide-hd,bus=ahci.0,drive=t0 \
    -netdev user,id=n0,restrict=on -device e1000,netdev=n0 \
    -serial "unix:$WORK/serial.sock,server,nowait" -display none \
    -monitor "unix:$WORK/mon.sock,server,nowait" -pidfile "$WORK/qemu.pid" \
    > "$WORK/qemu-disk.log" 2>&1 &

  local i
  for i in $(seq 1 40); do [ -S "$WORK/mon.sock" ] && break; sleep 1; done
  [ -S "$WORK/mon.sock" ] || die "qemu did not start -- see $WORK/qemu-disk.log"
  ok "booting the RESTORED system from disk, pid $(cat "$WORK/qemu.pid" 2>/dev/null)"
  info "network is restricted: the clone cannot reach your tailnet"
  echo "  give it ~90s, then:  $0 screenshot"
}

# The restored system has no serial console, so the framebuffer is the only way
# to see what it is doing.
cmd_screenshot() {
  [ -S "$WORK/mon.sock" ] || die "no monitor socket -- is the VM running? '$0 status'"
  local out="${1:-$WORK/screen.ppm}"
  python3 "$WORK/mon.py" "$WORK/mon.sock" "screendump $out" >/dev/null 2>&1
  sleep 1
  [ -s "$out" ] || die "screendump produced nothing"
  # PPM is inconvenient to look at remotely; convert if anything here can.
  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$out" > "${out%.ppm}.png" 2>/dev/null && out="${out%.ppm}.png"
  elif command -v convert >/dev/null 2>&1; then
    convert "$out" "${out%.ppm}.png" 2>/dev/null && out="${out%.ppm}.png"
  fi
  ok "screenshot: $out ($(du -h "$out" | cut -f1))"
  echo "  fetch it with:  scp $(hostname):$out ."
}

cmd_sh() {
  local c="${1:-}"
  [ -n "$c" ] || die "usage: $0 sh \"COMMAND\""
  [ -S "$WORK/serial.sock" ] || die "no serial socket -- is the VM running? '$0 status'"
  python3 "$WORK/conv.py" "$WORK/serial.sock" "" 1 "$c" "${2:-8}"
}

# --------------------------------------------------------------------- steps

cmd_steps() {
  local snap; snap=$(ls -1 "$SNAPSRC" 2>/dev/null | sort | tail -1)
  cat <<EOF

  THE RESTORE, STEP BY STEP -- run these with '$0 sh "..."'

  The guest reaches this host at 10.0.2.2 under user-mode networking, and the
  rsync daemon from '$0 serve' decodes --fake-super on the way out.

  Everything below has been run end to end and ends at a login screen. The
  awkward parts are steps 4 and 5, and neither is guessable.

  1. Partition the target the way the real machine is: GPT, EFI system
     partition, ext4 root.

       sudo sgdisk -Z /dev/sda
       sudo sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:root /dev/sda

     Now the UUIDs. Timeshift maps mount points from the SNAPSHOT'S OWN fstab,
     matched by UUID -- not from --target. On a disk whose UUIDs do not match it
     aborts with "Data will be modified on: <empty>" and NO error message at all.
     Either format with the original UUIDs (get them from
     'snapshot-offsite.sh disk-plan'):

       sudo mkfs.vfat -F32 -i <VOLID>  /dev/sda1     # e.g. 1AE41280, no dash
       sudo mkfs.ext4 -qF -U <UUID>    /dev/sda2

     ...or format plainly and answer the mapping prompts in step 5 with explicit
     device names. Matching also fixes crypttab and resume references and lets
     the restore run unattended; answering works on any replacement disk.

  2. Format the carrier and pull the snapshot tree onto it. This is the step
     that has to preserve ownership -- and the daemon, not the client, is what
     decodes it.

       sudo mkfs.ext4 -F /dev/sdb
       sudo mkdir -p /mnt/carrier && sudo mount /dev/sdb /mnt/carrier
       sudo rsync -aHAX --numeric-ids --info=progress2 \\
            rsync://10.0.2.2:$RSYNC_PORT/snapshots/ /mnt/carrier/

  3. Sanity-check the pull BEFORE restoring from it. If sudo is not setuid here,
     stop: everything downstream would be broken and it is cheaper to find out now.

       ls -l /mnt/carrier/$snap/localhost/usr/bin/sudo
       ls -l /mnt/carrier/$snap/localhost/etc/shadow

  4. Make timeshift able to SEE the snapshots. Two things bite here.

     First, the offsite copy holds the CONTENTS of /timeshift/snapshots, so on
     the carrier they land at the root and timeshift reports "No snapshots on
     this device". It looks in <device>/timeshift/snapshots/ :

       sudo mkdir -p /mnt/carrier/timeshift/snapshots
       sudo mv /mnt/carrier/2026-* /mnt/carrier/timeshift/snapshots/

     Second, on a live session timeshift has no config, enters "First run mode"
     and prompts for a backup device -- a prompt --snapshot-device does NOT
     answer and --yes cannot either. Seed a config instead. Note the UUID needs
     sudo: plain blkid returns nothing and you get an empty config that reports
     "Device : Not Selected".

       sudo apt-get install -y timeshift expect
       U=\$(sudo blkid -o value -s UUID /dev/sdb)
       printf '{"backup_device_uuid":"%s","btrfs_mode":"false","do_first_run":"false"}\\n' "\$U" \\
         | sudo tee /etc/timeshift/timeshift.json >/dev/null
       sudo timeshift --list          # must show your snapshots with comments

  5. Restore -- and drive the prompts with expect, not 'yes'.

     The sequence is "Press ENTER to continue", then "Re-install GRUB2 (y/n)",
     then "Continue with restore? (y/n)". So 'yes' answers the first wrongly and
     'yes ""' answers the last two wrongly; each failed here. (debconf-set-
     selections is for apt prompts -- timeshift rolls its own stdin loop.)
     If you did NOT match UUIDs, answer "Select '<mount>' device" with the
     device name rather than accepting the empty default.

       cat > /root/restore.exp <<'X'
       set timeout 5400
       spawn timeshift --restore --snapshot <SNAP> --target /dev/sda2 --grub-device /dev/sda
       expect {
           -re "Press ENTER to continue"        { send "\\r";  exp_continue }
           -re "Re-install GRUB2 bootloader.*:" { send "y\\r"; exp_continue }
           -re "Continue with restore.*:"       { send "y\\r"; exp_continue }
           -re "Enter device name or number.*:" { send "\\r";  exp_continue }
           eof
       }
       X
       sudo expect -f /root/restore.exp

     Check the plan it prints says "Data will be modified on: /dev/sda2 / and
     /dev/sda1 /boot/efi". An EMPTY table means the mapping failed -- go back to
     the UUIDs in step 1. Note --skip-grub does NOT apply here: unlike a
     same-machine rollback, this time you DO want a bootloader installed.

  6. Boot it -- and keep it OFF the network.

       $0 bootdisk        # uses -netdev user,restrict=on, deliberately
       $0 screenshot      # the restored system has no serial console

     The restored system is a second copy of this machine's IDENTITY: tailscale
     node key, machine-id, ssh host keys. Give it real network access while the
     original is running and it will claim the original's tailnet identity and
     knock it offline -- see the warning at the top of this script.

EOF
}

# ------------------------------------------------------------ status / teardown

cmd_status() {
  echo
  echo "  work dir  $WORK"
  echo "  snapshots $SNAPSRC"
  echo
  [ -d "$WORK" ] || { info "not prepared yet"; echo; return 0; }
  local f
  for f in "$(basename "$ISO")" initrd.new target.qcow2 carrier.qcow2; do
    [ -e "$WORK/$f" ] && printf '  %-28s %s\n' "$f" "$(du -h "$WORK/$f" | cut -f1)" \
                      || printf '  %-28s %s\n' "$f" "missing"
  done
  echo
  local mine; mine=$(our_qemu)
  if [ -n "$mine" ] && kill -0 "$mine" 2>/dev/null; then
    ok "our VM running, pid $mine ($(ps -o etime= -p "$mine" | tr -d ' ') elapsed)"
  else
    info "our VM is not running"
  fi
  # Name other VMs explicitly so nobody assumes a stray qemu is this script's.
  local others; others=$(qemu_pids | grep -vx "${mine:-none}" | tr '\n' ' ')
  [ -n "$others" ] && warn "other qemu processes on this host (NOT ours, leave alone): $others"
  pgrep -f "^rsync --daemon --config=$WORK" >/dev/null \
    && ok "rsync daemon up on 127.0.0.1:$RSYNC_PORT" || info "rsync daemon not running"
  echo
}

cmd_stop() {
  local mine; mine=$(our_qemu)
  if [ -n "$mine" ] && kill -0 "$mine" 2>/dev/null; then
    kill "$mine" && ok "stopped our VM (pid $mine)"
  else
    info "our VM was not running"
  fi
  rm -f "$WORK/qemu.pid" "$WORK/serial.sock"
  pgrep -f "^rsync --daemon --config=$WORK" | xargs -r kill 2>/dev/null && ok "stopped the rsync daemon"
  info "other VMs on this host were not touched"
}

cmd_clean() {
  cmd_stop
  rm -f "$WORK/target.qcow2" "$WORK/carrier.qcow2" "$WORK/vars.fd"
  ok "deleted the disks. ISO and patched initrd kept -- 'prepare' is quick now."
}

case "${1:-status}" in
  prepare) cmd_prepare ;;
  serve)   cmd_serve ;;
  boot)    cmd_boot ;;
  sh)         cmd_sh "${2:-}" "${3:-8}" ;;
  bootdisk)   cmd_bootdisk ;;
  screenshot) cmd_screenshot "${2:-}" ;;
  steps)   cmd_steps ;;
  status)  cmd_status ;;
  stop)    cmd_stop ;;
  clean)   cmd_clean ;;
  *)       usage ;;
esac
