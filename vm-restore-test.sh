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
say()  { echo; echo "  == $*"; }
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
       $0 restore [SNAP] do the whole restore unattended, ending in golden.qcow2
                         (defaults to the newest snapshot)
       $0 testbase       golden.qcow2 + a serial console -> testbase.qcow2
       $0 sh "COMMAND"   run a command in the guest and print what it says
       $0 bootdisk [IMG] boot a restored image off the disk (network restricted;
                         defaults to target.qcow2)
       $0 screenshot     capture the guest's framebuffer (it has no serial console)
       $0 steps          the same restore by hand, and why each step is like that
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
# How the guest gets the restore driver. NOT fake super: this module serves
# ordinary files that want their own modes, and decoding would corrupt them.
# rsync re-reads this config on every connection, so adding a module does not
# need the daemon restarted.
[vmtest]
    path = $WORK
    read only = true
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
  # Which image to boot. Defaults to the disk a restore just wrote, but naming
  # one lets you boot testbase.qcow2 or a candidate overlay without copying 19G
  # over target.qcow2 first.
  local img="${1:-target.qcow2}"
  case "$img" in /*) ;; *) img="$WORK/$img" ;; esac
  [ -s "$img" ] || die "no such image: $img"

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
    -drive file="$img",if=none,id=t0,format=qcow2 -device ide-hd,bus=ahci.0,drive=t0 \
    -netdev user,id=n0,restrict=on -device e1000,netdev=n0 \
    -serial "unix:$WORK/serial.sock,server,nowait" -display none \
    -monitor "unix:$WORK/mon.sock,server,nowait" -pidfile "$WORK/qemu.pid" \
    > "$WORK/qemu-disk.log" 2>&1 &

  local i
  for i in $(seq 1 40); do [ -S "$WORK/mon.sock" ] && break; sleep 1; done
  [ -S "$WORK/mon.sock" ] || die "qemu did not start -- see $WORK/qemu-disk.log"
  ok "booting $(basename "$img") from disk, pid $(cat "$WORK/qemu.pid" 2>/dev/null)"
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

# -------------------------------------------------------------------- restore

# Everything `steps` describes, run unattended, ending in golden.qcow2.
#
# WHY THIS IS NOT JUST `sh` CALLED SIX TIMES
#
# Two steps -- the tree pull and the restore itself -- run for tens of minutes,
# and the serial helper drains for a fixed number of seconds per exchange. It
# has no idea what a shell prompt looks like and cannot wait for one. So the
# work is DETACHED inside the guest, writes one line to /tmp/g.status, and this
# side polls that file. The serial link carries status, never the work.
#
# WHY IT PULLS ONE SNAPSHOT RATHER THAN THE WHOLE MODULE
#
# The carrier is ${CARRIER_GB}G; the offsite copy is ~20G of HARDLINKED snapshots whose
# apparent size is 38G, and a pull expands every hardlink. The module would not
# fit and would spend most of its time on snapshots nothing here restores. One
# snapshot is a complete tree on its own. Pulling it straight into
# timeshift/snapshots/ also removes the `mv` that step 4 needs by hand.
#
# WHY IT MATCHES UUIDS INSTEAD OF ANSWERING THE PROMPTS
#
# Both work by hand; only matching works unattended. What makes this dangerous
# on real hardware -- two filesystems sharing a UUID -- cannot arise here: the
# target is a qcow2 that never coexists with the laptop.

# The ORIGINAL identifiers, read from the snapshot's own fstab. Nothing else
# knows them once the disk is gone, and timeshift matches mount points on them.
fstab_field() {   # $1=fstab  $2=mount point  $3=field number -> value or empty
  awk -v m="$2" -v f="$3" '!/^#/ && NF>=3 && $2==m {print $f; exit}' "$1"
}

# One exchange with the guest, cleaned up enough to grep.
#
# Two things have to come off first, and the second cost a whole run:
#
#   \r          serial line endings
#   ESC[?2004l  bash's BRACKETED PASTE off/on sequence, which it emits on the
#               SAME LINE as the first line of output. So `cat /tmp/g.status`
#               comes back as "ESC[?2004lDONE:rc=10" and any pattern anchored
#               with ^ silently never matches -- the poll below ran to its full
#               timeout against a guest that had already finished.
guest() {
  python3 "$WORK/conv.py" "$WORK/serial.sock" "" 1 "$1" "${2:-8}" 2>/dev/null \
    | tr -d '\r' | sed 's/\x1b\[[0-9?;]*[a-zA-Z]//g'
}

cmd_restore() {
  cd "$WORK" || die "run '$0 prepare' first"
  local snap="${1:-}"
  [ -n "$snap" ] || snap=$(ls -1 "$SNAPSRC" 2>/dev/null | sort | tail -1)
  [ -n "$snap" ] || die "no snapshots in $SNAPSRC"
  [ -d "$SNAPSRC/$snap" ] || die "no such snapshot: $snap"

  local fstab="$SNAPSRC/$snap/localhost/etc/fstab"
  [ -r "$fstab" ] || die "cannot read the snapshot's fstab at $fstab"

  # Refuse a layout this cannot rebuild rather than restoring a system whose
  # fstab names a filesystem that was never created. It would boot into an
  # emergency shell and look like a restore bug.
  local extra
  extra=$(awk '!/^#/ && NF>=3 && $3!="swap" && $2!="/" && $2!="/boot/efi" {print $2}' "$fstab")
  if [ -n "$extra" ]; then
    bad "the snapshot's fstab mounts more than / and /boot/efi:"
    echo "$extra" | sed 's/^/        /'
    die "this builds a two-partition disk only -- restore that layout by hand with '$0 steps'"
  fi

  local root_src esp_src root_type esp_type root_uuid esp_id
  root_src=$(fstab_field "$fstab" "/" 1);         root_type=$(fstab_field "$fstab" "/" 3)
  esp_src=$(fstab_field "$fstab" "/boot/efi" 1);  esp_type=$(fstab_field "$fstab" "/boot/efi" 3)
  case "$root_src" in UUID=*) root_uuid="${root_src#UUID=}" ;; *) die "root is not UUID-based: $root_src" ;; esac
  case "$esp_src"  in UUID=*) esp_id=$(echo "${esp_src#UUID=}" | tr -d '-') ;; *) die "ESP is not UUID-based: $esp_src" ;; esac
  [ "$root_type" = ext4 ] || die "root is $root_type, not ext4 -- adjust cmd_restore before trusting it"
  [ "$esp_type" = vfat ]  || die "/boot/efi is $esp_type, not vfat"

  echo
  info "snapshot   $snap"
  info "root       ext4  UUID=$root_uuid          -> /dev/sda2"
  info "ESP        vfat  volume id $esp_id        -> /dev/sda1"
  info "golden     $WORK/golden.qcow2"
  echo

  if [ -s "$WORK/golden.qcow2" ]; then
    warn "golden.qcow2 already exists ($(du -h "$WORK/golden.qcow2" | cut -f1)) and will be REPLACED at the end"
  fi

  # Bring up the pieces this needs. All three are idempotent.
  [ -s "$WORK/target.qcow2" ] && [ -s "$WORK/carrier.qcow2" ] || die "no disks -- run '$0 prepare' first"
  cmd_serve || die "the rsync daemon is not serving a decoded tree -- fix that first"
  cmd_boot  || die "could not start the VM"

  # The driver, fetched by the guest over the vmtest module. Sending a multi-KB
  # script down the serial line would be at the mercy of every echo and control
  # character on the way; rsync is already there and is exact.
  cat > "$WORK/guest-restore.sh" <<'GUEST'
#!/bin/sh
# Runs as root INSIDE the live session, detached. Driven by vm-restore-test.sh
# restore -- see the commentary there. Progress goes to /tmp/g.status (one line,
# overwritten) and the full transcript to stdout, which the caller redirects.
set -u
SNAP="$1"; ROOT_UUID="$2"; ESP_ID="$3"; PORT="$4"
CARRIER=/mnt/carrier
SNAPDIR="$CARRIER/timeshift/snapshots/$SNAP"

step() { echo "STEP $*" > /tmp/g.status; echo "=== STEP $*"; }
fail() { echo "DONE:rc=$1" > /tmp/g.status; echo "=== FAILED at rc=$1: $2"; exit "$1"; }

step "1/7 installing tools"
export DEBIAN_FRONTEND=noninteractive
# The live session's sources.list carries a `cdrom:` entry for the ISO it booted
# from, and that entry has no Release file here -- we boot with -kernel/-initrd
# rather than letting casper mount the disc as an apt source. apt-get update then
# exits non-zero having fetched every network list perfectly well. Drop the entry,
# and do not gate on update's exit code either way: the install is the real test,
# and it fails plainly if the lists never arrived.
sed -i '/^deb cdrom:/d' /etc/apt/sources.list 2>/dev/null
apt-get update -qq 2>&1 | grep -v "^$" | sed 's/^/    /'
apt-get install -y -qq gdisk dosfstools timeshift expect || fail 10 "apt-get install"

step "2/7 partitioning /dev/sda"
sgdisk -Z /dev/sda >/dev/null 2>&1
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI -n2:0:0 -t2:8300 -c2:root /dev/sda || fail 11 "sgdisk"
# The kernel needs telling, and udev needs to catch up, or mkfs races the
# partition nodes into existence and fails with "No such file or directory".
partprobe /dev/sda 2>/dev/null || blockdev --rereadpt /dev/sda 2>/dev/null
udevadm settle 2>/dev/null; sleep 2
[ -b /dev/sda1 ] && [ -b /dev/sda2 ] || fail 11 "partition nodes never appeared"

step "3/7 formatting with the ORIGINAL uuids"
mkfs.vfat -F32 -i "$ESP_ID" /dev/sda1 >/dev/null || fail 12 "mkfs.vfat"
mkfs.ext4 -qF -U "$ROOT_UUID" /dev/sda2         || fail 12 "mkfs.ext4"

step "4/7 pulling $SNAP onto the carrier"
mkfs.ext4 -qF /dev/sdb        || fail 13 "mkfs.ext4 on the carrier"
mkdir -p "$CARRIER"
mount /dev/sdb "$CARRIER"     || fail 13 "mount carrier"
# Only now, so the tree lands on the carrier rather than under its mount point.
# Timeshift looks in <device>/timeshift/snapshots/, which is why the pull
# targets that path instead of the device root.
mkdir -p "$SNAPDIR"
# The daemon decodes --fake-super on the way out; this side must NOT name it.
rsync -aHAX --numeric-ids "rsync://10.0.2.2:$PORT/snapshots/$SNAP/" "$SNAPDIR/" \
  || fail 14 "rsync pull"

step "5/7 checking the pull before restoring from it"
# If sudo is not setuid here, everything downstream is broken and it is far
# cheaper to stop now than to find out from a system that boots and cannot
# escalate. This is the single check that catches a mis-decoded archive.
mode=$(stat -c %A "$SNAPDIR/localhost/usr/bin/sudo" 2>/dev/null)
case "$mode" in
  -rwsr-xr-x*) echo "    sudo is $mode -- setuid survived the pull" ;;
  *)           fail 15 "sudo came through as '$mode', expected -rwsr-xr-x" ;;
esac
[ -f "$SNAPDIR/localhost/etc/shadow" ] || fail 15 "no /etc/shadow in the pulled tree"

step "6/7 seeding timeshift and restoring"
# On a live session timeshift has no config, enters first-run mode and prompts
# for a backup device -- a prompt --snapshot-device does not answer. Seed the
# config instead. blkid needs root here or it returns nothing and the config
# ends up reporting "Device : Not Selected".
U=$(blkid -o value -s UUID /dev/sdb)
[ -n "$U" ] || fail 16 "no UUID on the carrier"
mkdir -p /etc/timeshift
printf '{"backup_device_uuid":"%s","btrfs_mode":"false","do_first_run":"false"}\n' "$U" \
  > /etc/timeshift/timeshift.json
timeshift --list || fail 16 "timeshift cannot see the snapshots"

# expect, not `yes`: the sequence is ENTER, then two y/n prompts, so `yes`
# answers the first wrongly and `yes ""` answers the last two wrongly.
# No --skip-grub: unlike a same-machine rollback, here we DO want a bootloader.
cat > /root/restore.exp <<'EXP'
set timeout 7200
set snap [lindex $argv 0]
spawn timeshift --restore --snapshot $snap --target /dev/sda2 --grub-device /dev/sda
expect {
    -re "Press ENTER to continue"        { send "\r";  exp_continue }
    -re "Re-install GRUB2 bootloader.*:" { send "y\r"; exp_continue }
    -re "Continue with restore.*:"       { send "y\r"; exp_continue }
    -re "Enter device name or number.*:" { send "\r";  exp_continue }
    eof
}
catch wait result
exit [lindex $result 3]
EXP
expect -f /root/restore.exp "$SNAP" > /tmp/restore.out 2>&1
rc=$?
cat /tmp/restore.out
# An EMPTY "Data will be modified on:" table is how a failed mount mapping
# presents -- timeshift prints no error and can still exit 0. Check the table.
grep -q "/dev/sda2" /tmp/restore.out || fail 17 "timeshift's device table never named /dev/sda2 -- the UUID mapping failed"
[ "$rc" = 0 ] || fail 17 "timeshift exited $rc"

step "7/7 verifying the restored disk"
mkdir -p /mnt/t
mount /dev/sda2 /mnt/t || fail 18 "cannot mount the restored root"
mount /dev/sda1 /mnt/t/boot/efi 2>/dev/null
for f in /mnt/t/etc/fstab /mnt/t/usr/bin/sudo /mnt/t/boot/grub/grub.cfg; do
  [ -e "$f" ] || fail 18 "missing after restore: $f"
done
case "$(stat -c %A /mnt/t/usr/bin/sudo)" in
  -rwsr-xr-x*) ;; *) fail 18 "restored sudo is not setuid" ;;
esac
ls /mnt/t/boot/efi/EFI >/dev/null 2>&1 || fail 18 "the ESP has no EFI directory -- grub was not installed"
echo "    kernels on the restored disk:"; ls /mnt/t/boot/vmlinuz-* 2>/dev/null | sed 's/^/      /'

# Unmount and sync before the host freezes the image, or golden.qcow2 captures a
# filesystem with a dirty journal.
umount /mnt/t/boot/efi 2>/dev/null
umount /mnt/t          || fail 19 "could not unmount the restored root"
umount "$CARRIER"      2>/dev/null
sync
echo "DONE:rc=0" > /tmp/g.status
echo "=== restore complete"
GUEST
  chmod 755 "$WORK/guest-restore.sh"

  # Wait for the live session. `id` is the readiness probe because its OUTPUT
  # (uid=) cannot appear in the echo of the command itself -- a probe that greps
  # for its own marker matches the echo and passes before the guest is up.
  say "waiting for the live session"
  local i=0 up=0
  while [ "$i" -lt 40 ]; do
    guest "id" 4 | grep -q "uid=" && { up=1; break; }
    i=$((i + 1)); sleep 5
  done
  [ "$up" = 1 ] || die "no live session on the serial console after ~3 min -- '$0 status', then see $WORK/qemu.log"
  ok "live session is up"

  # P''ULLED, not PULLED, and the same trick below. The serial link echoes the
  # command back before running it, so a marker spelled plainly appears in the
  # output whether or not the command worked -- the check passes on failure.
  # Splitting it with a quote makes the echo read P''ULLED and only the shell's
  # own output read PULLED.
  guest "rsync -a rsync://10.0.2.2:$RSYNC_PORT/vmtest/guest-restore.sh /tmp/g.sh && echo P''ULLED" 20 \
    | grep -q "^PULLED" || die "the guest could not fetch the driver from the vmtest module"
  ok "driver in the guest"

  say "restoring $snap -- this runs for tens of minutes"
  info "the VM does the work; this only polls /tmp/g.status"
  guest "sudo sh -c 'setsid /tmp/g.sh $snap $root_uuid $esp_id $RSYNC_PORT >/tmp/g.log 2>&1 </dev/null &'; echo L''AUNCHED" 8 \
    | grep -q "^LAUNCHED" || die "could not launch the driver in the guest"

  local timeout="${MBA_VMTEST_RESTORE_TIMEOUT:-10800}"
  local waited=0 last="" line rc=""
  while [ "$waited" -lt "$timeout" ]; do
    sleep 20; waited=$((waited + 20))
    line=$(guest "cat /tmp/g.status" 5 | grep -E '^(STEP|DONE:rc=)' | tail -1)
    case "$line" in
      DONE:rc=*) rc="${line#DONE:rc=}"; break ;;
      STEP*)     [ "$line" = "$last" ] || { last="$line"; info "$(printf '%5sm  ' $((waited / 60)))$line"; } ;;
    esac
  done

  if [ -z "$rc" ]; then
    bad "no verdict after $((timeout / 60)) minutes"
    info "the guest may still be working. Look with:  $0 sh 'tail -20 /tmp/g.log'"
    return 1
  fi
  if [ "$rc" != 0 ]; then
    bad "the restore failed inside the guest (rc=$rc)"
    guest "tail -25 /tmp/g.log" 10 | sed 's/^/        /'
    info ""
    info "The VM is left running so you can look around:  $0 sh 'COMMAND'"
    return 1
  fi
  ok "restore verified inside the guest"

  # Freeze it. `convert` rather than `cp` because it drops the qcow2 slack a 40G
  # disk accumulates, and because the copy is read afterwards -- a truncated one
  # would be found now rather than at the next boot test.
  say "freezing golden.qcow2"
  # Capture the pid BEFORE stopping: cmd_stop removes the pidfile, so asking
  # afterwards gets nothing back and there is nothing left to wait on.
  local qpid; qpid=$(our_qemu)
  cmd_stop >/dev/null 2>&1
  # And wait for it to actually go. qemu-img takes an exclusive lock and fails
  # with "Failed to get shared 'write' lock" while the VM still holds the image;
  # a fixed sleep is a race, and losing it throws away the whole run at the last
  # step.
  for i in $(seq 1 30); do
    [ -n "$qpid" ] && kill -0 "$qpid" 2>/dev/null || break
    sleep 1
  done
  if [ -n "$qpid" ] && kill -0 "$qpid" 2>/dev/null; then
    die "qemu (pid $qpid) will not exit -- refusing to copy an image it still holds"
  fi
  rm -f "$WORK/golden.qcow2"
  qemu-img convert -O qcow2 "$WORK/target.qcow2" "$WORK/golden.qcow2" || die "qemu-img convert failed"
  qemu-img check "$WORK/golden.qcow2" >/dev/null 2>&1 || die "golden.qcow2 does not check out"
  ok "golden.qcow2 written ($(du -h "$WORK/golden.qcow2" | cut -f1)), from $snap"

  echo
  info "Boot it to confirm the whole path end to end:"
  info "  cp golden.qcow2 target.qcow2 && $0 bootdisk && sleep 90 && $0 screenshot"
  info ""
  info "Never give a restored clone real network access while the laptop is"
  info "running -- bootdisk uses restrict=on for that reason. See the header."
  echo
}

# ------------------------------------------------------------------- testbase

# golden.qcow2 + a console it can be asked questions over.
#
# WHY THIS IS A SEPARATE IMAGE AND NOT AN EDIT TO GOLDEN
#
# golden.qcow2 has one job: be exactly what the snapshot restores to. The moment
# it is edited it stops being evidence about the restore. testbase.qcow2 is a
# qcow2 OVERLAY on it -- seconds to make, costs nothing, and every divergence
# from the laptop is confined to a chain you can throw away and rebuild. That is
# not theoretical: the first attempt at this wrote to the wrong file and the fix
# was to delete the overlay and start again, with golden untouched throughout.
#
# WHY A CONSOLE AT ALL
#
# A restored system booted from disk is silent on the serial port, because the
# grub.cfg came from a laptop that boots to a screen. `screenshot` is fine for a
# human and useless as a verdict: a kernel test has to be able to ask `uname -r`,
# `modprobe wl` and `systemctl --failed` and read the answers.
#
# WHERE THE SETTINGS GO, AND WHY IT IS NOT /etc/default/grub
#
# grub-mkconfig sources /etc/default/grub and THEN /etc/default/grub.d/*.cfg, and
# Mint ships 50_linuxmint.cfg setting GRUB_DISABLE_OS_PROBER=false. So a setting
# written to the main file is silently overridden -- it was set there twice,
# correctly, and os-prober ran anyway. Everything goes in one 99- fragment that
# sorts last, which also makes the whole divergence a single file you can read.
cmd_testbase() {
  cd "$WORK" || die "run '$0 prepare' first"
  [ -s "$WORK/golden.qcow2" ] || die "no golden.qcow2 -- run '$0 restore' first"
  command -v qemu-nbd >/dev/null || die "qemu-nbd missing (apt install qemu-utils)"
  sudo -n true 2>/dev/null || die "this needs root for nbd, mount and chroot, and sudo is asking for a password"

  local dev="${MBA_VMTEST_NBD:-/dev/nbd0}"
  local mnt="$WORK/tb-mnt"
  mkdir -p "$mnt"

  tb_cleanup() {
    sudo umount "$mnt/boot/efi" 2>/dev/null
    local m
    for m in sys proc dev/pts dev; do sudo umount "$mnt/$m" 2>/dev/null; done
    sudo umount "$mnt" 2>/dev/null
    sudo qemu-nbd --disconnect "$dev" >/dev/null 2>&1
  }
  trap 'tb_cleanup' EXIT

  sudo modprobe nbd max_part=8 || die "cannot load the nbd module"
  # Never inherit a connection we did not make -- a stale one points at another
  # image, and everything below would edit the wrong disk.
  sudo qemu-nbd --disconnect "$dev" >/dev/null 2>&1
  sleep 1

  rm -f "$WORK/testbase.qcow2"
  qemu-img create -f qcow2 -b "$WORK/golden.qcow2" -F qcow2 "$WORK/testbase.qcow2" >/dev/null \
    || die "could not create the overlay"
  sudo qemu-nbd --connect="$dev" "$WORK/testbase.qcow2" || die "qemu-nbd could not attach the overlay"
  sleep 2
  [ -b "${dev}p2" ] || die "no partitions on $dev -- is golden.qcow2 really a restored disk?"
  sudo mount "${dev}p2" "$mnt" || die "cannot mount the restored root"

  sudo tee "$mnt/etc/default/grub.d/99-vmtest.cfg" >/dev/null <<'X'
# The only way this image differs from the machine it was restored from.
# Written by vm-restore-test.sh testbase.
#
# It lives here rather than in /etc/default/grub because grub-mkconfig sources
# this directory afterwards, and Mint's 50_linuxmint.cfg sets
# GRUB_DISABLE_OS_PROBER=false -- so the main file loses every time.
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200"
# Without this, update-grub run in a chroot with the HOST's /dev bind-mounted
# probes the host's own disks and writes boot entries for them into this image.
GRUB_DISABLE_OS_PROBER=true
# quiet/splash dropped deliberately: a failed boot that prints nothing is the one
# outcome this rig exists to diagnose.
GRUB_CMDLINE_LINUX_DEFAULT="acpi_osi=!Darwin"
X

  # Swap. The laptop has a 3960M /swapfile and its fstab references it, but
  # Timeshift EXCLUDES the file -- so a restored system carries the entry and not
  # the file, and swapfile.swap fails on every boot forever.
  #
  # Creating it here makes the healthy baseline ZERO failed units. That is worth
  # more than tidiness: "nothing failed" is a verdict that cannot rot, whereas
  # "exactly one failed and it must be that one" quietly stops being true the
  # first time anything else legitimately changes, and nobody notices.
  #
  # It also gives a 4G guest the same memory profile as the machine it stands in
  # for, which stops being cosmetic the moment something is BUILT in here rather
  # than merely booted.
  #
  # golden.qcow2 deliberately still fails this unit. That failure is honest
  # evidence that these snapshots are system-only, and the place to hide it is
  # the test image, not the record of what the restore produced.
  #
  # fallocate first, dd as the fallback, and the boot check is what settles it:
  # ext4 fallocate can leave UNWRITTEN extents and swapon has historically
  # refused those. If swapfile.swap comes back failed, that is why.
  local swap_mb="${MBA_VMTEST_SWAP_MB:-3960}"
  sudo fallocate -l "${swap_mb}M" "$mnt/swapfile" 2>/dev/null \
    || sudo dd if=/dev/zero of="$mnt/swapfile" bs=1M count="$swap_mb" status=none \
    || die "could not create the swapfile"
  sudo chmod 600 "$mnt/swapfile"
  sudo mkswap "$mnt/swapfile" >/dev/null 2>&1 || die "mkswap failed on the new swapfile"
  ok "swapfile ${swap_mb}M created, matching the laptop"

  # Autologin, for the same reason the live ISO needs it: this bypasses PAM's
  # password path rather than trying to satisfy it.
  sudo mkdir -p "$mnt/etc/systemd/system/serial-getty@ttyS0.service.d"
  sudo tee "$mnt/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" >/dev/null <<'X'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 vt220
X

  local m
  for m in dev dev/pts proc sys; do sudo mount --bind "/$m" "$mnt/$m" || die "bind mount /$m failed"; done
  sudo mount "${dev}p1" "$mnt/boot/efi" || die "cannot mount the ESP"
  sudo chroot "$mnt" update-grub 2>&1 | sed 's/^/    /'

  # Verify rather than assume, and do it without naming this host's disks: every
  # UUID grub searches for must belong to THIS image. Anything else is an
  # os-prober entry for the machine that built the image.
  local rootuuid espuuid foreign consoles
  rootuuid=$(sudo blkid -o value -s UUID "${dev}p2")
  espuuid=$(sudo blkid -o value -s UUID "${dev}p1")
  foreign=$(sudo grep -o 'fs-uuid --set=root [^ ]*' "$mnt/boot/grub/grub.cfg" 2>/dev/null \
            | awk '{print $3}' | sort -u | grep -v -e "^$rootuuid\$" -e "^$espuuid\$" || true)
  consoles=$(sudo grep -c 'console=ttyS0' "$mnt/boot/grub/grub.cfg" 2>/dev/null || echo 0)

  if [ -n "$foreign" ]; then
    bad "grub.cfg searches for UUIDs that are not in this image:"
    echo "$foreign" | sed 's/^/        /'
    die "os-prober leaked the build host's disks into the image"
  fi
  [ "$consoles" -gt 0 ] || die "no console=ttyS0 in grub.cfg -- the fragment did not take"
  ok "grub.cfg: $consoles serial console entries, no foreign disks"

  tb_cleanup
  trap - EXIT
  ok "testbase.qcow2 ready ($(du -h "$WORK/testbase.qcow2" | cut -f1) over golden.qcow2)"
  echo
  info "Boot it and ask it something:"
  info "  $0 bootdisk testbase.qcow2 && sleep 95 && $0 sh 'uname -r; modprobe wl && echo WL_OK'"
  echo
  info "Baseline on a healthy image: ZERO failed units. golden.qcow2 fails"
  info "swapfile.swap (Timeshift excludes /swapfile); testbase supplies one, so"
  info "here anything failed at all is real signal."
  echo
}

# ------------------------------------------------------------ status / teardown

cmd_status() {
  echo
  echo "  work dir  $WORK"
  echo "  snapshots $SNAPSRC"
  echo
  [ -d "$WORK" ] || { info "not prepared yet"; echo; return 0; }
  local f
  for f in "$(basename "$ISO")" initrd.new target.qcow2 carrier.qcow2 golden.qcow2 testbase.qcow2; do
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
  ok "deleted the working disks. ISO and patched initrd kept -- 'prepare' is quick now."
  # golden.qcow2 is the expensive artefact -- an hour of restore -- and it is
  # what anything downstream boots from. Deleting it here would make `clean`
  # mean two very different things depending on what had been run.
  if [ -s "$WORK/golden.qcow2" ]; then
    info "golden.qcow2 kept ($(du -h "$WORK/golden.qcow2" | cut -f1)). Delete it by hand if you mean to."
  fi
}

case "${1:-status}" in
  prepare) cmd_prepare ;;
  serve)   cmd_serve ;;
  boot)    cmd_boot ;;
  restore) cmd_restore "${2:-}" ;;
  sh)         cmd_sh "${2:-}" "${3:-8}" ;;
  testbase)   cmd_testbase ;;
  bootdisk)   cmd_bootdisk "${2:-}" ;;
  screenshot) cmd_screenshot "${2:-}" ;;
  steps)   cmd_steps ;;
  status)  cmd_status ;;
  stop)    cmd_stop ;;
  clean)   cmd_clean ;;
  *)       usage ;;
esac
