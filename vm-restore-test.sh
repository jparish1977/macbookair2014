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
# The VM plays two roles and they want different sizing. One knob for both was
# wrong in both directions at once: too small to match the laptop, too small to
# build an image quickly.
#
# TEST sizing MATCHES THE LAPTOP, and has to. An i5-4260U is 1 socket, 2 cores,
# 2 threads per core -- `nproc` reports FOUR. DKMS `make -j`, systemd
# parallelism and initramfs compression all size themselves off that. The
# previous `-smp 2` was half the laptop while carrying a comment claiming to
# match it.
#
# qemu's emulated threads are not real SMT: each vCPU is its own host thread, so
# guest siblings never contend for one physical core the way real HT does. What
# topology emulation buys is that nproc-driven decisions come out the same as on
# the metal, which is the fidelity that matters for "does it build, does it boot".
TEST_SMP="${MBA_VMTEST_TEST_SMP:-4,sockets=1,cores=2,threads=2}"
TEST_RAM="${MBA_VMTEST_TEST_RAM:-4096}"

# BUILD sizing is for the restore, which CONSTRUCTS an artefact and tests nothing
# about the laptop, so holding it to laptop size buys no fidelity.
#
# IT IS ALSO UNPROVEN, and that is recorded here so nobody assumes it is doing
# work. Measured on iteration8: 2 cpu / 4G with a convert took 21m00; 8 cpu / 16G
# with the convert replaced by a move took 20m26. Twenty-six seconds, for four
# times the CPU and RAM plus 19G less written.
#
# Two reasons the measurement could not see anything. The host has 251G of RAM
# and vm.dirty_ratio of 20%, so ~50G of dirty pages are allowed -- more than the
# whole restore writes. Writes are absorbed and flushed after the command
# returns, so wall-clock hides I/O cost entirely. And run-to-run variance for the
# same phase was 9, 15 and 20 minutes, which swamps any effect this size.
#
# The floor here is four 7200rpm Hitachi disks and no SSD. Worth retrying on a
# host with different storage -- the 7810, if it is ever converted to Linux --
# before concluding that guest sizing never matters.
BUILD_SMP="${MBA_VMTEST_BUILD_SMP:-8}"
BUILD_RAM="${MBA_VMTEST_BUILD_RAM:-16384}"
# How big the rebuilt disk is. NOT a copy of the laptop's 111G -- the restore
# partitions with `-n2:0:0` so the root fills whatever it is given, and only the
# system side is restored (~20G, no /home).
#
# It matters for usb-image: `qemu-img convert -O raw` writes the FULL VIRTUAL
# SIZE including the zeros, so a 40G image needs a 64G stick to hold 20G of data.
# Build at 26 and it fits a 32G stick with room -- allowing for the gap between
# a "32 GB" stick and its 29.8 GiB of actual space.
#
# Raising it later is free; lowering it below what the snapshot holds makes the
# restore fail, so leave headroom.
TARGET_GB="${MBA_VMTEST_TARGET_GB:-40}"
CARRIER_GB="${MBA_VMTEST_CARRIER_GB:-30}"

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
       $0 restore [SNAP] [--force]
                         do the whole restore unattended, ending in golden.qcow2
                         (newest snapshot by default; skipped entirely when
                         golden is already built from it -- --force overrides)
       $0 testbase       golden.qcow2 + a serial console -> testbase.qcow2
       $0 verify [IMG]   boot a test image and check this project's fixes took
       $0 verify-control prove those checks can fail, by breaking three on purpose
       $0 usb-image [IMG] make a VM-approved image bootable from USB on the real
                         machine, with every identifier rewritten so it cannot
                         fight the internal disk
       $0 update-test [PKG...]
                         run the update the laptop is about to run, HERE first:
                         upgrade a candidate overlay, then re-check every fix
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
  # NOT `file ... | grep -q`. See the pipefail note by guest() below: grep -q
  # exits on the first match, the upstream dies of SIGPIPE, and pipefail turns a
  # successful match into a failed pipeline.
  case "$(file -b "$ISO")" in *ISO*) ;; *) die "$ISO is not an ISO image" ;; esac
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
  # A matching PROCESS is not a serving daemon. cmd_stop kills without waiting,
  # so a pgrep run immediately afterwards still matches a process that is about
  # to exit -- this then reports "already running", starts nothing, and the
  # daemon finishes dying. Intermittent, and it cost a whole update-test run.
  # Judge it by its REPLY, which is the same rule as "a forwarded port is not
  # evidence" from the batocera work: a listening socket proves nothing about a
  # service that answers.
  if rsync --port="$RSYNC_PORT" rsync://127.0.0.1/ >/dev/null 2>&1; then
    ok "daemon already running and answering"
    return 0
  fi
  # Clear anything mid-death before binding the port again, or the new daemon
  # fails with "address already in use" and we are back where we started.
  pkill -f "^rsync --daemon --config=$WORK" 2>/dev/null
  local w
  for w in 1 2 3 4 5; do
    pgrep -f "^rsync --daemon --config=$WORK" >/dev/null || break
    sleep 1
  done
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
  # Which disk the live session works on. Defaults to the blank restore target;
  # update-test points it at a candidate overlay instead, so the upgrade happens
  # in the phase that HAS a network and carries none of the laptop's identity.
  local disk="${1:-target.qcow2}"
  case "$disk" in /*) ;; *) disk="$WORK/$disk" ;; esac
  [ -s "$disk" ] || die "no such image: $disk"
  # "build" for constructing an image, anything else for a run that produces a
  # verdict. See the sizing block at the top for why these differ.
  local smp="$TEST_SMP" ram="$TEST_RAM"
  [ "${2:-test}" = build ] && { smp="$BUILD_SMP"; ram="$BUILD_RAM"; }

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
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$smp" -m "$ram" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -device ich9-ahci,id=ahci \
    -drive file="$disk",if=none,id=t0,format=qcow2  -device ide-hd,bus=ahci.0,drive=t0 \
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
  ok "VM started (pid $(cat "$WORK/qemu.pid" 2>/dev/null)), live session on $(basename "$disk") [${smp%%,*} cpu, $((ram / 1024))G]"
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

  # Audio is emulated on purpose -- it is the ONE helper area with a usable
  # stand-in, so unlike Wi-Fi and the camera the stack can be exercised instead
  # of merely built. -audiodev none because this host is headless: the guest gets
  # a real controller, the samples go nowhere.
  #
  # MBA_VMTEST_NO_AUDIO=1 takes the card away, which is how the audio checks are
  # shown to be capable of failing. Without that control they only ever prove
  # that qemu was asked for a sound card.
  local audio_args=(-audiodev none,id=snd0
                    -device ich9-intel-hda,id=hda
                    -device hda-duplex,bus=hda.0,audiodev=snd0)
  [ "${MBA_VMTEST_NO_AUDIO:-0}" = 1 ] && audio_args=()

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

  # Always TEST sizing. Everything booted from disk produces a verdict, and a
  # verdict from a machine shaped differently to the laptop is worth less.
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$TEST_SMP" -m "$TEST_RAM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file="$WORK/vars.fd" \
    -device ich9-ahci,id=ahci \
    -drive file="$img",if=none,id=t0,format=qcow2 -device ide-hd,bus=ahci.0,drive=t0 \
    -netdev user,id=n0,restrict=on -device e1000,netdev=n0 \
    "${audio_args[@]}" \
    -serial "unix:$WORK/serial.sock,server,nowait" -display none \
    -monitor "unix:$WORK/mon.sock,server,nowait" -pidfile "$WORK/qemu.pid" \
    > "$WORK/qemu-disk.log" 2>&1 &

  local i
  for i in $(seq 1 40); do [ -S "$WORK/mon.sock" ] && break; sleep 1; done
  [ -S "$WORK/mon.sock" ] || die "qemu did not start -- see $WORK/qemu-disk.log"

  # The socket appearing is NOT proof qemu survived. It creates the monitor
  # before it opens the drives, so an unreadable or corrupt image leaves you a
  # socket and a dead process -- and everything downstream then waits three
  # minutes for a login from a VM that never existed. Found by an image
  # accidentally left root-owned: "Permission denied" sat in the log while this
  # reported a successful boot.
  sleep 1
  local qp; qp=$(cat "$WORK/qemu.pid" 2>/dev/null)
  if [ -z "$qp" ] || ! kill -0 "$qp" 2>/dev/null; then
    bad "qemu exited immediately after starting"
    tail -3 "$WORK/qemu-disk.log" 2>/dev/null | sed 's/^/        /'
    die "see $WORK/qemu-disk.log"
  fi
  ok "booting $(basename "$img") from disk, pid $qp"
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

# NEVER pipe guest() into `grep -q`, and the reason is worth the paragraph.
#
# grep -q exits the instant it matches. That closes the pipe, the process
# upstream takes SIGPIPE and dies with 141 -- and under `set -o pipefail` the
# PIPELINE then reports failure even though the match succeeded. Whether it bites
# depends on whether the upstream had finished writing first, so it is
# intermittent and looks like anything but what it is. It cost real time here:
# "the guest could not fetch the update driver" on a fetch that had worked.
#
# guest_says captures first and matches second, so there is no pipeline to fail.
# A HERE-STRING, not a pipe. `printf ... | grep -q` reintroduces the very bug
# this helper exists to avoid -- which is exactly what happened on the first
# attempt: the fetch worked, RC=0, the file was there, and this still reported
# failure. If it is a pipeline, grep -q can SIGPIPE it.
guest_says() {   # $1 = command, $2 = seconds, $3 = pattern
  local out; out=$(guest "$1" "$2")
  grep -q -- "$3" <<< "$out"
}

# Wait for a login on the serial console, then let the probe's connection close.
#
# Three callers each grew their own copy of this loop, which is how one settle
# came to need adding in three places -- the reason it lives here now.
#
# `id` is the probe because its OUTPUT (uid=) cannot appear in the echo of the
# command itself. A probe that greps for its own marker matches the serial echo
# and passes before the guest is up.
wait_for_guest() {   # $1 = where to look if it never comes up
  local i up=0
  for i in $(seq 1 40); do
    guest_says "id" 4 "uid=" && { up=1; break; }
    sleep 5
  done
  [ "$up" = 1 ] || die "no login on the serial console after ~3 min${1:+ -- $1}"
  ok "guest is up"
  # qemu's unix serial takes ONE client at a time, so the next exchange issued
  # straight after this probe loses its first attempt to the connection still
  # closing. Seen as a fetch that fails once and succeeds on the retry, with the
  # daemon answering throughout -- which sends you after the daemon for an hour.
  sleep 3
}

# Pull a driver script into the guest over the vmtest rsync module.
#
# The daemon is started HERE and not before the ~90s boot: it is wanted for a few
# seconds, and a long window is one in which something can take it away.
#
# P''ULLED, not PULLED. The serial link echoes the command back before running
# it, so a marker spelled plainly appears in the output whether or not the
# command worked, and the check passes on failure. Splitting it with a quote
# makes the echo read P''ULLED while only the shell's own output reads PULLED.
# Make a disposable overlay.
#
# Always as THIS user. Building one under sudo leaves a root-owned image qemu
# cannot open, and that surfaces three minutes later as "no login on the serial
# console" rather than as the permissions error it is -- which cost a run.
make_overlay() {   # $1 = backing image, $2 = overlay to create
  [ -s "$1" ] || die "no backing image $(basename "$1")"
  rm -f "$2"
  qemu-img create -f qcow2 -b "$1" -F qcow2 "$2" >/dev/null \
    || die "could not create $(basename "$2") over $(basename "$1")"
}

# Attach an image as an nbd device and wait for its partitions to appear.
nbd_attach() {   # $1 = image, $2 = device
  sudo modprobe nbd max_part=8 || die "cannot load the nbd module"
  # Never inherit a connection we did not make: a stale one points at another
  # image, and everything downstream would edit the wrong disk.
  sudo qemu-nbd --disconnect "$2" >/dev/null 2>&1
  sleep 1
  sudo qemu-nbd --connect="$2" "$1" || die "qemu-nbd could not attach $(basename "$1")"
  sleep 2
  [ -b "${2}p2" ] || die "no partitions on $2 -- is $(basename "$1") really a restored disk?"
}

# Watch a detached in-guest job through its one-line status file.
#
# Both long guest drivers report identically -- STEP lines while working, a final
# DONE:rc=N -- so they are polled identically. They were not: the two copies had
# already drifted to different column widths, which is what duplication does
# while you are not looking.
#
# Sets POLL_RC, because bash cannot return a string. Returns 1 on timeout.
poll_guest_job() {   # $1 = status file inside the guest, $2 = timeout in seconds
  local waited=0 last="" line
  POLL_RC=""
  while [ "$waited" -lt "$2" ]; do
    sleep 20; waited=$((waited + 20))
    line=$(guest "cat $1" 5 | grep -E '^(STEP|DONE:rc=)' | tail -1)
    case "$line" in
      DONE:rc=*) POLL_RC="${line#DONE:rc=}"; return 0 ;;
      STEP*)     [ "$line" = "$last" ] || { last="$line"; info "$(printf '%4sm  ' $((waited / 60)))$line"; } ;;
    esac
  done
  return 1
}

fetch_driver() {   # $1 = file in $WORK, $2 = destination in the guest
  local try
  for try in 1 2; do
    cmd_serve >/dev/null 2>&1 \
      || die "the rsync daemon is not serving a decoded tree -- see $WORK/rsyncd.log"
    guest_says "rsync -a rsync://10.0.2.2:$RSYNC_PORT/vmtest/$1 $2 && echo P''ULLED" 20 "^PULLED" \
      && { ok "$1 is in the guest"; return 0; }
    [ "$try" = 2 ] && {
      bad "the guest could not fetch $1 from the vmtest module"
      info "daemon: $(pgrep -f "^rsync --daemon --config=$WORK" >/dev/null && echo running || echo "NOT running")"
      die "see $WORK/rsyncd.log"
    }
    warn "fetch failed on the first attempt, re-serving and retrying"
  done
}

cmd_restore() {
  cd "$WORK" || die "run '$0 prepare' first"
  local snap="" force=0 a
  for a in "$@"; do
    case "$a" in
      --force) force=1 ;;
      *)       snap="$a" ;;
    esac
  done
  [ -n "$snap" ] || snap=$(ls -1 "$SNAPSRC" 2>/dev/null | sort | tail -1)
  [ -n "$snap" ] || die "no snapshots in $SNAPSRC"
  [ -d "$SNAPSRC/$snap" ] || die "no such snapshot: $snap"

  # Rebuild only when there is something new to rebuild FROM.
  #
  # golden.qcow2 is a 19G read-only base that everything downstream overlays in
  # megabyte increments. Reproducing it from an unchanged snapshot costs ~40G of
  # writes and twenty minutes on a spinning disk to produce a byte-identical
  # image. The test is exact -- "built from this snapshot" -- rather than a
  # judgement about whether it is fresh enough.
  if [ "$force" = 0 ] && [ -s "$WORK/golden.qcow2" ] \
     && [ "$(cat "$WORK/golden.snapshot" 2>/dev/null)" = "$snap" ]; then
    ok "golden.qcow2 is already built from $snap -- nothing to rebuild"
    info "$(du -h "$WORK/golden.qcow2" | cut -f1), sealed $(date -r "$WORK/golden.qcow2" '+%Y-%m-%d %H:%M')"
    info "Rebuild it anyway with:  $0 restore --force"
    return 0
  fi

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

  # Bring up the pieces this needs. All of it is idempotent.
  #
  # target and carrier are SCRATCH -- this wipes and rewrites both anyway -- so
  # recreate them if a previous cleanup took them, rather than sending you to
  # `prepare` for two empty files. A missing ISO or initrd is a different matter:
  # that genuinely needs prepare, and saying so is useful.
  [ -s "$WORK/initrd.new" ] || die "no patched initrd -- run '$0 prepare' first"
  [ -s "$ISO" ]             || die "no ISO -- run '$0 prepare' first"
  if [ ! -s "$WORK/target.qcow2" ]; then
    qemu-img create -f qcow2 "$WORK/target.qcow2" "${TARGET_GB}G" >/dev/null || die "cannot create the target disk"
    info "recreated target.qcow2 (${TARGET_GB}G, scratch)"
  fi
  if [ ! -s "$WORK/carrier.qcow2" ]; then
    qemu-img create -f qcow2 "$WORK/carrier.qcow2" "${CARRIER_GB}G" >/dev/null || die "cannot create the carrier disk"
    info "recreated carrier.qcow2 (${CARRIER_GB}G, scratch)"
  fi
  # Not served yet -- see update-test for why. The daemon is needed for a few
  # seconds during the fetch, and starting it before a ~90s boot leaves a long
  # window for something to take it away again.
  cmd_boot target.qcow2 build || die "could not start the VM"

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

  say "waiting for the live session"
  local i
  wait_for_guest "'$0 status', then see $WORK/qemu.log"
  fetch_driver guest-restore.sh /tmp/g.sh

  say "restoring $snap -- 15-25 minutes, and it has run to 30"
  info "the VM does the work; this only polls /tmp/g.status"
  guest_says "sudo sh -c 'setsid /tmp/g.sh $snap $root_uuid $esp_id $RSYNC_PORT >/tmp/g.log 2>&1 </dev/null &'; echo L''AUNCHED" 8 "^LAUNCHED" \
    || die "could not launch the driver in the guest"

  local timeout="${MBA_VMTEST_RESTORE_TIMEOUT:-10800}" rc=""
  poll_guest_job /tmp/g.status "$timeout"
  rc="$POLL_RC"

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

  # Seal it with a MOVE, not a convert.
  #
  # target.qcow2 is already the finished article. Converting it read 19G and
  # wrote another 19G to gain a compaction nothing needs -- a third of this
  # command's entire I/O, on a 7200rpm disk, for no benefit. target is scratch
  # and gets recreated on the next run.
  say "sealing golden.qcow2"
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
  mv "$WORK/target.qcow2" "$WORK/golden.qcow2" || die "could not move the restored disk into place"
  if ! qemu-img check "$WORK/golden.qcow2" >/dev/null 2>&1; then
    warn "qemu-img check complained -- trying to repair leaked clusters"
    qemu-img check -r leaks "$WORK/golden.qcow2" >/dev/null 2>&1
    qemu-img check "$WORK/golden.qcow2" >/dev/null 2>&1 \
      || die "golden.qcow2 does not check out even after a repair pass"
  fi
  # Which snapshot this was built from, so the next run can tell whether there is
  # anything new to do. Written LAST: a partial restore must not look complete.
  echo "$snap" > "$WORK/golden.snapshot"
  ok "golden.qcow2 sealed ($(du -h "$WORK/golden.qcow2" | cut -f1)), from $snap"

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

  make_overlay "$WORK/golden.qcow2" "$WORK/testbase.qcow2"
  nbd_attach "$WORK/testbase.qcow2" "$dev"
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

  # Plant the repo's own helpers. The rig deliberately does NOT reimplement their
  # checks -- several already have `check`/`status` subcommands, and a second
  # implementation would drift from the first and start grading the wrong thing.
  # /home is empty in these snapshots (system-only), so the repo is not in the
  # image and has to be put there.
  local repo_src="${MBA_VMTEST_REPO:-$(cd "$(dirname "$0")" && pwd)}"
  sudo rm -rf "$mnt/opt/mba-verify"
  sudo mkdir -p "$mnt/opt/mba-verify"
  if [ -f "$repo_src/kernel-guard.sh" ]; then
    sudo cp "$repo_src"/*.sh "$mnt/opt/mba-verify/" || die "could not plant the helpers"
    sudo chmod 755 "$mnt/opt/mba-verify"/*.sh
    ok "planted $(ls "$repo_src"/*.sh | wc -l) helpers at /opt/mba-verify"
  else
    warn "no repo beside $0 -- helper checks will report SKIP"
    warn "deploy the whole repo, not just this script:  rsync -a ./ HOST:$WORK/"
  fi

  sudo tee "$mnt/opt/mba-verify/guest-verify.sh" >/dev/null <<'VERIFY'
#!/bin/sh
# Runs INSIDE the test image and prints one RESULT line per check.
# Written by vm-restore-test.sh testbase -- edit it there, not here.
#
# It verifies what this project's helpers TRY TO DO, on a machine with none of
# the hardware they were written for. Three tiers, and only the first two are
# attempted here:
#
#   artefact   the file/rule/firmware survived the restore   -- needs nothing
#   mechanism  it builds, it loads, the rule matches and acts -- needs a VM
#   device     Wi-Fi associates, the camera captures, sound comes out
#              -- needs the metal, and is deliberately NOT guessed at
REPO=/opt/mba-verify
K=$(uname -r)
R() { echo "RESULT $1|$2|$3"; }

# ---------------------------------------------------------------- artefacts
for spec in \
  "facetimehd-firmware|/lib/firmware/facetimehd/firmware.bin" \
  "kbd-backlight-rule|/etc/udev/rules.d/60-applesmc-kbd-backlight.rules" \
  "webcam-tune-rule|/etc/udev/rules.d/99-mba-webcam-tune.rules" \
  "kernel-guard-hook|/etc/apt/apt.conf.d/99-mba-kernel-guard"
do
  name=${spec%%|*}; path=${spec#*|}
  if [ -s "$path" ]; then R PASS "artefact:$name" "$path"
  else R FAIL "artefact:$name" "missing after restore: $path"; fi
done

# ----------------------------------------------------------------- modules
dkms_built() { dkms status 2>/dev/null | grep "^$1/" | grep "$K" | grep -q installed; }

for spec in "wl|broadcom-sta" "facetimehd|facetimehd"; do
  mod=${spec%%|*}; pkg=${spec#*|}
  if dkms_built "$pkg"; then R PASS "dkms:$mod" "$pkg built for $K"
  else R FAIL "dkms:$mod" "$pkg NOT built for $K -- this is the stranding case"; fi
  if modprobe "$mod" 2>/dev/null && lsmod | grep -q "^$mod "; then
    R PASS "load:$mod" "loads against $K with no hardware present"
  else
    R FAIL "load:$mod" "built but will not load against $K"
  fi
done

# applesmc is the odd one out and must not be graded like the others: it REFUSES
# to load without an Apple SMC ("No such device"), where wl and facetimehd load
# happily and simply bind nothing. So the honest check is that the kernel SHIPS
# it -- whether it binds is a tier-3 question this rig cannot ask.
if modinfo applesmc >/dev/null 2>&1; then
  R PASS "module:applesmc" "shipped by $K (cannot load without an SMC -- expected)"
else
  R FAIL "module:applesmc" "no applesmc module in $K"
fi

# ------------------------------------------------- the kbd-backlight fix
# The real test of the fix, without an SMC: make a SYNTHETIC LED with the name
# applesmc would have registered, and ask udev what it does with it.
#
# Note it is udevadm test that is the evidence, NOT the resulting trigger value:
# a fresh uleds LED defaults to "none" anyway, so reading the attribute back
# would "pass" even with the rule deleted.
modprobe uleds 2>/dev/null
python3 - <<'PY' >/dev/null 2>&1 &
import struct, time
f = open('/dev/uleds', 'r+b', buffering=0)
f.write(struct.pack('64si', b'smc::kbd_backlight', 255))
time.sleep(90)
PY
sleep 3
LED=/sys/class/leds/smc::kbd_backlight
if [ -d "$LED" ]; then
  if udevadm test "$LED" 2>&1 | grep -q "60-applesmc-kbd-backlight.rules.*writing 'none'"; then
    R PASS "rule:kbd-backlight" "udev matched a synthetic LED and wrote trigger=none"
  else
    R FAIL "rule:kbd-backlight" "the rule did not act on a synthetic smc::kbd_backlight"
  fi
else
  R SKIP "rule:kbd-backlight" "could not create a synthetic LED (no uleds)"
fi

# ------------------------------------------------------ the helpers themselves
if [ -x "$REPO/kernel-guard.sh" ]; then
  out=$("$REPO/kernel-guard.sh" check 2>&1); rc=$?
  case "$rc" in
    0) R PASS "helper:kernel-guard" "check says every installed kernel has its drivers" ;;
    1) R WARN "helper:kernel-guard" "non-critical gap (camera): $(echo "$out" | grep -c MISSING) kernel(s)" ;;
    2) R FAIL "helper:kernel-guard" "CRITICAL -- the newest kernel has no wl" ;;
    *) R FAIL "helper:kernel-guard" "check exited $rc" ;;
  esac
else
  R SKIP "helper:kernel-guard" "not planted at $REPO"
fi

# Run the backlight helper against the synthetic LED and assert on what it
# REPORTS, not merely that it exited 0.
if [ -x "$REPO/kbd-backlight.sh" ] && [ -d "$LED" ]; then
  out=$("$REPO/kbd-backlight.sh" status 2>&1)
  # Report WHICH assertion failed, not the first 90 characters of the output.
  # Dumping the raw text put "trigger none" in the failure line and read exactly
  # like a pass -- a misleading message is a bug, not a cosmetic issue.
  trig=no; rule=no
  echo "$out" | grep -q "trigger *none"        && trig=yes
  echo "$out" | grep -q "udev rule *installed" && rule=yes
  if [ "$trig" = yes ] && [ "$rule" = yes ]; then
    R PASS "helper:kbd-backlight" "reports trigger none and the rule installed"
  else
    R FAIL "helper:kbd-backlight" "trigger-is-none=$trig rule-installed=$rule"
  fi
else
  R SKIP "helper:kbd-backlight" "helper or synthetic LED absent"
fi

# ------------------------------------------------------------------- audio
# The one helper area with an emulated stand-in: bootdisk gives the guest an
# ich9-intel-hda controller, so unlike Wi-Fi and the camera the audio path can be
# exercised rather than merely built.
#
# WHAT THIS DOES NOT TEST. The laptop's codec is a Cirrus CS4208 and QEMU's is a
# generic one, so codec-specific behaviour -- jack detection, speaker/headphone
# routing, the model= quirks Macs so often need -- is NOT covered and cannot be.
# Everything ABOVE the codec is: the controller is found, snd_hda_intel binds it,
# ALSA presents playback and capture, and a PCM can actually be opened and
# written. That last is the difference between "a device node exists" and "the
# audio path works", and it is the only one of these a broken stack cannot fake.
if grep -q '\[' /proc/asound/cards 2>/dev/null; then
  R PASS "audio:card" "$(sed -n 's/^ *[0-9] \[\([^]]*\)\].*/\1/p' /proc/asound/cards | head -1 | tr -s ' ')"
else
  R FAIL "audio:card" "no sound card enumerated at all"
fi

if lsmod | grep -q '^snd_hda_intel'; then
  R PASS "audio:driver" "snd_hda_intel loaded and bound"
else
  R FAIL "audio:driver" "snd_hda_intel did not bind the controller"
fi

if aplay -l 2>/dev/null | grep -q '^card '; then
  R PASS "audio:playback" "$(aplay -l 2>/dev/null | grep '^card ' | head -1 | cut -c1-58)"
else
  R FAIL "audio:playback" "ALSA lists no playback device"
fi

if arecord -l 2>/dev/null | grep -q '^card '; then
  R PASS "audio:capture" "a capture device is present"
else
  R FAIL "audio:capture" "ALSA lists no capture device -- the mic path is gone"
fi

if timeout 5 aplay -D hw:0,0 -f S16_LE -r 44100 -c 2 -d 1 /dev/zero >/dev/null 2>&1; then
  R PASS "audio:pcm-open" "opened hw:0,0 and wrote a second of samples"
else
  R FAIL "audio:pcm-open" "could not open and write the PCM"
fi

# Presence only. PipeWire is a per-user service and a serial root login has no
# session for it to run in, so "is it installed and would it start" is the
# honest limit here -- claiming more would be inventing a result.
if dpkg -l wireplumber 2>/dev/null | grep -q '^ii'; then
  R PASS "audio:userspace" "pipewire/wireplumber installed (not started: no user session)"
else
  R WARN "audio:userspace" "wireplumber not installed -- desktop audio would have no session manager"
fi

# ------------------------------------------------------------------ system
# Say plainly which kernel these answers are ABOUT. Every check above is keyed
# on the running kernel, so a verdict is meaningless without naming it -- and it
# is not always the one that was just installed.
R PASS "booted:kernel" "$K"

n=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
if [ "$n" = 0 ]; then R PASS "system:units" "no failed units"
else R FAIL "system:units" "$n failed: $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"; fi

sw=$(swapon --show --noheadings 2>/dev/null)
if echo "$sw" | grep -q zram && echo "$sw" | grep -q swapfile; then
  R PASS "system:swap" "both tiers up: zram0 and /swapfile"
else
  R WARN "system:swap" "expected zram0 and /swapfile, got: $(echo "$sw" | tr '\n' ' ')"
fi

echo "VERIFY-COMPLETE"
VERIFY
  sudo chmod 755 "$mnt/opt/mba-verify/guest-verify.sh"

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

# --------------------------------------------------------------------- verify

# Boot a test image and ask it whether this project's fixes actually took.
#
# The checks live in the GUEST (/opt/mba-verify/guest-verify.sh, planted by
# testbase) rather than being driven one at a time from here. Two reasons: each
# serial exchange costs seconds and there are a dozen checks, and a check driven
# remotely can only ever grade what fits in one line of output. Running in the
# guest, they can run the helpers and read their reports.
cmd_verify() {
  cd "$WORK" || die "run '$0 prepare' first"
  local img
  if [ -z "${1:-}" ]; then
    [ -s "$WORK/testbase.qcow2" ] || die "no testbase.qcow2 -- run '$0 testbase' first"
    # Boot a THROWAWAY overlay, never testbase itself. Booting an image writes to
    # it -- journal, logs, systemd state -- so verifying the base directly leaves
    # every later overlay standing on a slightly different base each time. The
    # entire point of a base image is that it does not move.
    make_overlay "$WORK/testbase.qcow2" "$WORK/verify-scratch.qcow2"
    img="$WORK/verify-scratch.qcow2"
  else
    img="$1"
    case "$img" in /*) ;; *) img="$WORK/$img" ;; esac
  fi
  [ -s "$img" ] || die "no such image: $img -- run '$0 testbase' first"

  cmd_bootdisk "$(basename "$img")" >/dev/null || die "could not boot $img"
  say "booted $(basename "$img"), waiting for it to come up"

  local i
  wait_for_guest "'$0 screenshot' to see why"

  guest_says "test -x /opt/mba-verify/guest-verify.sh && echo P''RESENT" 6 "^PRESENT" \
    || die "no verify script in the image -- rebuild it with '$0 testbase'"

  say "running the checks"
  guest_says "setsid /opt/mba-verify/guest-verify.sh >/tmp/verify.out 2>&1 </dev/null & echo S''TARTED" 6 "^STARTED" \
    || die "could not start the checks in the guest"

  local out=""
  for i in $(seq 1 30); do
    sleep 5
    out=$(guest "cat /tmp/verify.out" 12)
    echo "$out" | grep -q "VERIFY-COMPLETE" && break
  done
  echo "$out" | grep -q "VERIFY-COMPLETE" || {
    bad "the checks did not finish"
    info "look with:  $0 sh 'cat /tmp/verify.out'"
    return 1
  }

  # Keep the raw verdicts so verify-control can grade THIS run rather than
  # re-running the checks and hoping it got the same answers.
  echo "$out" | grep '^RESULT ' > "$WORK/verify.last"

  # Grade. RESULT lines are status|name|detail.
  local pass=0 fail=0 warn=0 skip=0 line st nm dt
  echo
  while IFS= read -r line; do
    case "$line" in RESULT\ *) ;; *) continue ;; esac
    line=${line#RESULT }
    st=${line%%|*}; line=${line#*|}
    nm=${line%%|*}; dt=${line#*|}
    case "$st" in
      PASS) pass=$((pass+1)); printf '  \033[32m[pass]\033[0m %-26s %s\n' "$nm" "$dt" ;;
      WARN) warn=$((warn+1)); printf '  \033[33m[warn]\033[0m %-26s %s\n' "$nm" "$dt" ;;
      SKIP) skip=$((skip+1)); printf '  [skip] %-26s %s\n' "$nm" "$dt" ;;
      *)    fail=$((fail+1)); printf '  \033[31m[FAIL]\033[0m %-26s %s\n' "$nm" "$dt" ;;
    esac
  done <<< "$out"

  echo
  info "$pass passed, $fail failed, $warn warned, $skip skipped"
  echo
  info "Not attempted, and not attemptable here: Wi-Fi association, camera"
  info "capture, sound output, and whether the backlight physically lights."
  info "Those need one boot on the metal -- see kernel-guard.sh boot-test."
  echo
  [ "$fail" -eq 0 ]
}

# --------------------------------------------------------------- update-test

# Run the update the laptop is about to run, here first.
#
# WHY IT RUNS THE REAL UPGRADE RATHER THAN INSTALLING A KERNEL BY HAND
#
# `apt-get install linux-image-X` would prove a kernel can be installed. It
# would not exercise the apt hook, the DKMS triggers, the initramfs rebuild or
# update-grub -- which is where an update actually goes wrong, and the whole
# reason kernel-guard's hook exists. So this runs what the machine would run,
# and one of the things it reports is whether the guard FIRED.
#
# WHY THE UPGRADE HAPPENS IN THE LIVE PHASE
#
# The two phases have exactly the properties the two halves need, and swapping
# them would be dangerous:
#
#   live ISO   has a network, carries NO identity  -> safe place to reach the
#              archive, so the upgrade and the DKMS build happen here, in a
#              chroot onto the candidate disk
#   disk boot  has the laptop's identity, no route -> stays restrict=on, and only
#              has to answer "does it come up, and do the fixes still hold"
#
# Giving the disk boot a network so apt could run there is what steals the
# laptop's tailnet node key. See the header.
#
# WHAT IT CANNOT TELL YOU
#
# Whether Wi-Fi associates, the camera captures or the backlight lights. It moves
# the line from "reboot the only machine and find out" to "the only thing left to
# find out on metal is whether the radio comes up".
cmd_update_test() {
  cd "$WORK" || die "run '$0 prepare' first"
  [ -s "$WORK/testbase.qcow2" ] || die "no testbase.qcow2 -- run '$0 testbase' first"
  # --unhold lifts apt holds inside the candidate only, to test the update that
  # the hold is deliberately deferring.
  local unhold=0 pkgs=""
  local a
  for a in "$@"; do
    case "$a" in
      --unhold) unhold=1 ;;
      *) pkgs="$pkgs $a" ;;
    esac
  done
  pkgs="${pkgs# }"

  make_overlay "$WORK/testbase.qcow2" "$WORK/candidate.qcow2"
  ok "candidate.qcow2 created over testbase"

  # The daemon is deliberately NOT started here. It is only needed for the few
  # seconds when the guest fetches the driver, and starting it before a ~90s boot
  # leaves a long window in which anything that tidies up stray processes can
  # take it away again -- which happened twice, intermittently, and each time
  # cost a full run. Start it immediately before it is used, below.
  cmd_stop >/dev/null 2>&1
  cmd_boot candidate.qcow2 || die "could not start the live session"

  cat > "$WORK/guest-update.sh" <<'GUEST'
#!/bin/sh
# Runs in the LIVE session, detached, with the candidate disk as /dev/sda.
# Chroots into it and runs the real upgrade. Written by vm-restore-test.sh.
set -u
PKGS="${1:-}"
UNHOLD="${2:-0}"
T=/mnt/t
step() { echo "STEP $*" > /tmp/u.status; echo "=== STEP $*"; }
fail() { echo "DONE:rc=$1" > /tmp/u.status; echo "=== FAILED rc=$1: $2"; exit "$1"; }

step "1/5 mounting the candidate"
mkdir -p $T
mount /dev/sda2 $T            || fail 20 "cannot mount the candidate root"
mount /dev/sda1 $T/boot/efi   || fail 20 "cannot mount its ESP"
for m in dev dev/pts proc sys; do mount --bind /$m $T/$m || fail 20 "bind /$m"; done

# apt in a chroot needs working DNS, and the image's resolv.conf is a stub
# symlink to a systemd-resolved that is not running in here.
cp -a $T/etc/resolv.conf /tmp/resolv.keep 2>/dev/null
rm -f $T/etc/resolv.conf
echo "nameserver 10.0.2.3" > $T/etc/resolv.conf     # qemu's user-mode DNS

# Stop the chroot trying to start or restart services on the host's behalf.
# Without this a package with a service unit fails the upgrade for reasons that
# have nothing to do with the update being tested.
printf '#!/bin/sh\nexit 101\n' > $T/usr/sbin/policy-rc.d
chmod 755 $T/usr/sbin/policy-rc.d

step "2/5 apt-get update"
chroot $T apt-get update -qq 2>&1 | sed 's/^/    /'

step "3/5 the upgrade itself"
BEFORE=$(ls $T/boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort | tr '\n' ' ')

# Holds are the FIRST thing to report, because a held kernel is the difference
# between "this update is safe" and "this update never happened". mba-wifi.sh
# puts them there deliberately, to keep a known-good fallback kernel installed --
# so finding them is the machine working, not a fault.
HELD=$(chroot $T apt-mark showhold 2>/dev/null | tr '\n' ' ')
echo "HELD: ${HELD:-none}"
if [ "$UNHOLD" = 1 ] && [ -n "$HELD" ]; then
  # Only ever in the candidate OVERLAY. This answers the question the hold
  # exists to defer -- "would it be safe to lift this?" -- without lifting
  # anything on the laptop.
  chroot $T apt-mark unhold $HELD >/dev/null 2>&1
  echo "UNHELD: $HELD"
fi
export DEBIAN_FRONTEND=noninteractive
# Ubuntu PHASES updates: apt holds a package back until the rollout percentage
# reaches this machine, and that decision is keyed on the MACHINE-ID. This image
# is a clone of the laptop and inherits its machine-id, so it makes exactly the
# same phasing decision -- without this override the rig is precisely as blind as
# the machine it exists to protect, and finds nothing to test right up until the
# day the update lands for real.
#
# The first run proved it: 3 packages upgradable, 0 upgraded, "kept back", and a
# cheerful green verdict on an image nothing had been done to.
APTOPT="-o APT::Get::Always-Include-Phased-Updates=true"
if [ -n "$PKGS" ]; then
  chroot $T apt-get install -y $APTOPT $PKGS > /tmp/apt.out 2>&1; rc=$?
else
  # dist-upgrade rather than upgrade, because a new kernel arrives via a
  # meta-package that changes dependencies and plain `upgrade` holds it back.
  chroot $T apt-get dist-upgrade -y $APTOPT > /tmp/apt.out 2>&1; rc=$?
fi
tail -25 /tmp/apt.out | sed 's/^/    /'
[ "$rc" = 0 ] || fail 21 "apt exited $rc"

step "4/5 what changed"
AFTER=$(ls $T/boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort | tr '\n' ' ')
echo "KERNELS-BEFORE: $BEFORE"
echo "KERNELS-AFTER:  $AFTER"
N=$(grep -c '^Setting up' /tmp/apt.out 2>/dev/null || echo 0)
echo "UPGRADED-COUNT: $N"
# Did anything actually happen? An upgrade that changed nothing must NOT be
# allowed to produce a green verdict -- that is a test of an untouched image
# wearing the words "safe to apply".
CHANGED=no
[ "$BEFORE" != "$AFTER" ] && CHANGED=yes
[ "$N" -gt 0 ] && CHANGED=yes
echo "CHANGED: $CHANGED"
KEPT=$(sed -n '/kept back/,+2p' /tmp/apt.out 2>/dev/null | tr '\n' ' ' | tr -s ' ')
[ -n "$KEPT" ] && echo "KEPT-BACK: $KEPT"
# The apt hook cannot be tested by looking for its output. It runs
# `kernel-guard check --quiet-ok`, and --quiet-ok means PRINT NOTHING WHEN
# EVERYTHING IS FINE -- so on a healthy machine silence is success, and grepping
# the apt transcript for it reports "never fired" every single time. That check
# was wrong in the first version of this script.
#
# What IS worth testing is the hook's guard. It is wrapped in
# `if [ -x /usr/local/bin/kernel-guard ]`, so if that binary ever goes missing
# the hook silently does nothing for ever -- no error, no output, and
# indistinguishable from a hook that ran and approved. That is the failure this
# rig exists to catch.
if chroot $T test -x /usr/local/bin/kernel-guard; then
  chroot $T /usr/local/bin/kernel-guard check --quiet-ok >/dev/null 2>&1
  echo "HOOK-TARGET: present, check rc=$?"
else
  echo "HOOK-TARGET: MISSING -- the hook is guarded by [ -x ] and will do NOTHING, silently"
fi
# Which kernels are NEW, and arm a one-shot boot into the newest of them.
#
# Without this the boot half is vacuous whenever the candidate is not the newest
# kernel installed -- and here that is the NORMAL case, not an edge case: a
# 6.17-series update always sits below the 7.0 kernel, so grub keeps booting
# 7.0.0-28 and `verify` cheerfully re-grades a kernel already known to be good.
#
# It arms it with the project's own kernel-guard boot-test, which means this
# exercises that path too -- and boot-test refuses outright if the target has no
# wl built, so a candidate that would strand the machine cannot even be armed.
NEW=""
for k in $AFTER; do
  case " $BEFORE " in *" $k "*) ;; *) NEW="$NEW $k" ;; esac
done
NEW=${NEW# }
echo "NEW-KERNELS: ${NEW:-none}"
if [ -n "$NEW" ]; then
  TARGET=$(echo "$NEW" | tr ' ' '\n' | sort -V | tail -1)
  if chroot $T /opt/mba-verify/kernel-guard.sh boot-test "$TARGET" > /tmp/bt.out 2>&1; then
    echo "BOOT-TEST-ARMED: $TARGET"
  else
    echo "BOOT-TEST-ARMED: FAILED for $TARGET"
    sed 's/^/    /' /tmp/bt.out
  fi
fi
echo "DKMS-AFTER:"
chroot $T dkms status 2>/dev/null | grep -v Deprecated | sed 's/^/    /'

step "5/5 kernel-guard's own verdict, in the chroot"
# Note its "(running)" marker is meaningless here -- the running kernel is the
# live ISO's. Its per-kernel DKMS grading is what matters.
chroot $T /opt/mba-verify/kernel-guard.sh check 2>&1 | sed 's/^/    /'
echo "GUARD-RC: $?"

# Keep the transcript INSIDE the image. /tmp/u.log dies with the live session,
# and the first run lost the apt output exactly when it was needed to explain a
# no-op upgrade. Written here, it travels with the candidate and can be read
# after booting it.
cp /tmp/apt.out $T/var/log/mba-update-test.log 2>/dev/null

rm -f $T/usr/sbin/policy-rc.d
rm -f $T/etc/resolv.conf
cp -a /tmp/resolv.keep $T/etc/resolv.conf 2>/dev/null
# Flush BEFORE unmounting, so a stubborn mount cannot cost us the upgrade we
# just did.
sync
umount $T/boot/efi 2>/dev/null
for m in sys proc dev/pts dev; do umount $T/$m 2>/dev/null; done
# -R matters. A plain umount leaves any submount in place and the parent then
# reports "target is busy" with NO process holding it -- fuser shows only
# "kernel mount", which sends you hunting for a process that does not exist.
umount -R $T 2>/dev/null || umount -l -R $T 2>/dev/null \
  || fail 22 "could not unmount the candidate even lazily"
sync
echo "DONE:rc=0" > /tmp/u.status
echo "=== upgrade complete"
GUEST
  chmod 755 "$WORK/guest-update.sh"

  say "waiting for the live session"
  local i
  wait_for_guest "see $WORK/qemu.log"
  fetch_driver guest-update.sh /tmp/u.sh

  say "running the upgrade the laptop would run${pkgs:+ (limited to: $pkgs)}"
  guest_says "sudo sh -c 'setsid /tmp/u.sh \"$pkgs\" $unhold >/tmp/u.log 2>&1 </dev/null &'; echo L''AUNCHED" 8 "^LAUNCHED" \
    || die "could not launch the update driver"

  local rc="" timeout="${MBA_VMTEST_UPDATE_TIMEOUT:-5400}"
  poll_guest_job /tmp/u.status "$timeout"
  rc="$POLL_RC"

  if [ -z "$rc" ] || [ "$rc" != 0 ]; then
    bad "the upgrade failed in the guest${rc:+ (rc=$rc)}"
    guest "tail -30 /tmp/u.log" 12 | sed 's/^/        /'
    info "the VM is left running:  $0 sh 'cat /tmp/u.log'"
    return 1
  fi
  ok "upgrade completed"

  # The interesting lines, pulled out of the guest's transcript.
  say "what the upgrade did"
  local report
  report=$(guest "grep -E '^(KERNELS-BEFORE|KERNELS-AFTER|UPGRADED-COUNT|CHANGED|KEPT-BACK|HELD|UNHELD|NEW-KERNELS|BOOT-TEST-ARMED|HOOK-TARGET|GUARD-RC):' /tmp/u.log" 12)
  echo "$report" | grep -E '^(KERNELS|UPGRADED|CHANGED|KEPT-BACK|HELD|UNHELD|NEW-|BOOT-TEST|HOOK|GUARD)' | sed 's/^/    /'

  # An upgrade that changed nothing must never reach the verdict. Verifying an
  # untouched image passes every check and means nothing at all -- the first run
  # of this did exactly that and said "safe to apply".
  if ! echo "$report" | grep -q '^CHANGED: yes'; then
    echo
    bad "the upgrade changed NOTHING -- there is nothing here to verify"
    info "This is not a pass. An untouched image passes every check."
    info ""
    if echo "$report" | grep -q '^HELD: [a-z]' && [ "$unhold" = 0 ]; then
      info "Those packages are HELD (see HELD: above). mba-wifi.sh puts kernel"
      info "holds there on purpose, to keep a known-good fallback installed, so"
      info "this is the machine working rather than a fault."
      info ""
      info "To answer the question the hold exists to defer -- would it be safe"
      info "to lift it? -- run:   $0 update-test --unhold"
      info "That lifts them in the CANDIDATE OVERLAY only. The laptop is untouched."
      return 3
    fi
    info "Usual cause: everything is already up to date in the snapshot this"
    info "image was built from. If apt reported packages KEPT BACK above, they"
    info "are phased updates that this clone declined for the same reason the"
    info "laptop does -- it inherits the laptop's machine-id. update-test forces"
    info "them in, so seeing them held here means something else is holding them."
    return 2
  fi

  local want
  want=$(echo "$report" | sed -n 's/^BOOT-TEST-ARMED: \([^ ]*\)$/\1/p' | tail -1)

  say "now booting the upgraded system and re-checking every fix"
  cmd_verify candidate.qcow2
  local vrc=$?

  # Did it actually land on the kernel we installed? grub boots the NEWEST
  # kernel, which is often not the candidate -- a 6.17 update sits below a 7.0
  # kernel and the one-shot is the only thing that puts it in front. If that
  # one-shot did not take, every check above graded the old kernel and the
  # verdict is about nothing.
  local booted
  booted=$(awk -F'|' '/^RESULT [A-Z]*\|booted:kernel\|/ {print $3}' "$WORK/verify.last" 2>/dev/null | tail -1)
  echo
  if [ -n "$want" ] && [ "$want" != "FAILED" ]; then
    if [ "$booted" = "$want" ]; then
      ok "booted the candidate kernel $booted -- the checks above are about IT"
    else
      bad "armed $want but booted $booted"
      info "The one-shot did not take, so every check above graded the OLD kernel."
      info "That is not a verdict on this update. Look at grub-editenv in the image."
      return 4
    fi
  elif [ -n "$booted" ]; then
    info "no new kernel to boot-test; the checks graded $booted"
  fi

  if [ "$vrc" -eq 0 ]; then
    ok "the update is safe to apply on the laptop, as far as a VM can tell"
  else
    bad "the update BROKE something -- do not apply it to the laptop yet"
  fi
  info "Still unproven, and unprovable here: Wi-Fi association, camera capture,"
  info "sound, and the backlight. One boot on the metal covers those."
  info "candidate.qcow2 kept for inspection -- delete it or re-run to replace it."
  return $vrc
}

# --------------------------------------------------------------- usb-image

# Turn a VM-approved image into one that can be booted on the real machine from
# a USB disk, WITHOUT touching the internal one.
#
# WHY THIS IS WORTH HAVING
#
# The VM can prove the update installs, builds its modules and boots. It can
# never prove Wi-Fi associates, the camera captures or the backlight lights --
# there is no BCM4360, no FaceTime HD and no Apple SMC to emulate. Today that
# last mile means applying the update to the only machine and rebooting.
# Booting the approved image from USB tests the same kernel on the same hardware
# with the internal disk untouched, and failure costs an unplug rather than a
# rollback.
#
# WHY IT REWRITES EVERY IDENTIFIER, AND WHY THAT IS NOT OPTIONAL
#
# A raw copy keeps the original's UUIDs, and a USB disk in the same machine is
# the definition of "a disk that coexists with the original". Two filesystems
# sharing a UUID make blkid ambiguous and mounts non-deterministic: you can boot
# the USB kernel and mount the INTERNAL root, or have grub resolve to the wrong
# disk -- and then an update-grub or a kernel install writes to the internal
# system you were trying to protect. So:
#
#   root      a fresh filesystem UUID (tune2fs -U), fstab and grub.cfg follow
#   GPT       fresh disk and partition GUIDs (sgdisk -G)
#   ESP       fstab switches to PARTUUID=, because changing a FAT volume id in
#             place needs mtools, which is not installed -- and a duplicated ESP
#             id is not harmless: it is how a kernel install ends up writing to
#             the internal ESP
#
# It also strips the VM-only bits (99-vmtest.cfg, the serial autologin), so what
# boots is a normal laptop with the update applied rather than a test rig.
cmd_usb_image() {
  cd "$WORK" || die "run '$0 prepare' first"
  local src="${1:-candidate.qcow2}"
  case "$src" in /*) ;; *) src="$WORK/$src" ;; esac
  [ -s "$src" ] || die "no such image: $src -- run '$0 update-test' first"
  command -v sgdisk >/dev/null || die "sgdisk missing (apt install gdisk)"
  sudo -n true 2>/dev/null || die "this needs root for nbd, mount and chroot"

  local out="$WORK/usb-$(basename "${src%.qcow2}").qcow2"
  local dev="${MBA_VMTEST_NBD:-/dev/nbd0}" mnt="$WORK/usb-mnt"
  mkdir -p "$mnt"

  usb_cleanup() {
    sudo umount "$mnt/boot/efi" 2>/dev/null
    local m; for m in sys proc dev/pts dev; do sudo umount "$mnt/$m" 2>/dev/null; done
    sudo umount "$mnt" 2>/dev/null
    sudo qemu-nbd --disconnect "$dev" >/dev/null 2>&1
  }
  trap 'usb_cleanup' EXIT

  say "Building a standalone copy of $(basename "$src")"
  info "A full copy, not an overlay -- it has to stand alone once written out."
  rm -f "$out"
  qemu-img convert -O qcow2 "$src" "$out" || die "qemu-img convert failed"
  ok "$(basename "$out") written ($(du -h "$out" | cut -f1))"

  nbd_attach "$out" "$dev"

  say "Giving it identifiers of its own"
  sudo sgdisk -G "$dev" >/dev/null || die "sgdisk could not regenerate the GPT GUIDs"
  sudo partprobe "$dev" 2>/dev/null; sudo udevadm settle 2>/dev/null; sleep 2

  local newroot; newroot=$(uuidgen)
  sudo e2fsck -fy "${dev}p2" >/dev/null 2>&1   # tune2fs -U refuses on an unchecked fs
  sudo tune2fs -U "$newroot" "${dev}p2" >/dev/null || die "could not set a new root UUID"
  local esp_partuuid; esp_partuuid=$(sudo blkid -o value -s PARTUUID "${dev}p1")
  [ -n "$esp_partuuid" ] || die "could not read the ESP's PARTUUID"
  info "root UUID  $newroot"
  info "ESP        PARTUUID=$esp_partuuid"

  sudo mount "${dev}p2" "$mnt" || die "cannot mount the copy's root"

  # fstab has to agree, or it boots to an emergency shell having found nothing.
  sudo sed -i "s|^UUID=[0-9a-fA-F-]\{36\}\([[:space:]]\+/[[:space:]]\)|UUID=$newroot\1|" "$mnt/etc/fstab"
  sudo sed -i "s|^UUID=[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}\([[:space:]]\+/boot/efi\)|PARTUUID=$esp_partuuid\1|" "$mnt/etc/fstab"

  # Strip the rig. What boots should be a laptop with the update applied, not a
  # test image: console=ttyS0 on a machine with no serial port is at best noise,
  # and a root autologin on it is not something to carry onto real hardware.
  sudo rm -f "$mnt/etc/default/grub.d/99-vmtest.cfg"
  sudo rm -rf "$mnt/etc/systemd/system/serial-getty@ttyS0.service.d"
  sudo rm -f "$mnt/opt/mba-verify/guest-verify.sh"

  local m
  for m in dev dev/pts proc sys; do sudo mount --bind "/$m" "$mnt/$m" || die "bind /$m failed"; done
  sudo mount "${dev}p1" "$mnt/boot/efi" || die "cannot mount the copy's ESP"
  sudo chroot "$mnt" update-grub 2>&1 | sed 's/^/    /'

  # Verify rather than hope: the new UUID must be in grub.cfg and the old one
  # must not, or this disk will still reach for the internal root.
  local n_new n_old
  n_new=$(sudo grep -c "$newroot" "$mnt/boot/grub/grub.cfg" 2>/dev/null || echo 0)
  n_old=$(sudo grep -c "b96739a5-34c1-403b-b440-80df9aa71a03" "$mnt/boot/grub/grub.cfg" 2>/dev/null || echo 0)
  [ "$n_new" -gt 0 ] || die "grub.cfg does not reference the new root UUID"
  if [ "$n_old" -gt 0 ]; then
    bad "grub.cfg still references the ORIGINAL root UUID in $n_old place(s)"
    die "this disk would fight the internal one -- refusing to call it ready"
  fi
  ok "grub.cfg points at the new root only ($n_new references)"
  sudo grep -E "^(UUID|PARTUUID)" "$mnt/etc/fstab" | sed 's/^/    /'

  usb_cleanup
  trap - EXIT

  echo
  ok "$(basename "$out") is ready and shares no identifier with the laptop"
  echo
  local virt_gb
  virt_gb=$(qemu-img info "$out" 2>/dev/null | sed -n 's/.*virtual size: \([0-9.]*\) GiB.*/\1/p')
  info "The stick must be at least ${virt_gb:-?} GiB -- convert -O raw writes the"
  info "whole virtual size, zeros included, not just the $(du -h "$out" | cut -f1) in use."
  info "For a smaller image, rebuild with:  MBA_VMTEST_TARGET_GB=26 $0 restore --force"
  echo
  info "Write it to a USB disk -- ON THE MACHINE THE USB IS PLUGGED INTO, and"
  info "check the device name twice. This overwrites whatever is on it:"
  echo
  echo "    lsblk -o NAME,SIZE,TRAN,MODEL          # find it. TRAN must say usb"
  echo "    sudo qemu-img convert -O raw $out /dev/sdX"
  echo "    sync"
  echo
  info "Then on the laptop: hold Option at the chime and pick the USB disk."
  info "The internal disk is untouched -- if it misbehaves, unplug and reboot."
  echo
  info "This is the ONLY way to test what a VM cannot: Wi-Fi associating, the"
  info "camera capturing, sound, and the backlight actually lighting."
  echo
}

# ------------------------------------------------------------- verify-control

# Prove the checks can FAIL. Without this, "14 passed" is not evidence.
#
# This project already works this way elsewhere and for good reason:
# restore-test.sh grades an UNCHANGED control so a no-op cannot pass by default,
# and snapshot-offsite.sh's pull-test got 7/7 right with all 7 wrong in the
# control. A verifier nobody has ever seen fail is an assumption with a progress
# bar.
#
# It breaks three artefacts in a throwaway overlay and asserts that exactly the
# right checks go red -- including one, rule:kbd-backlight, that must catch the
# missing rule through BEHAVIOUR (udev acting on a synthetic LED) rather than by
# re-reading the same file the artefact check already read.
CONTROL_BREAKS="/etc/udev/rules.d/60-applesmc-kbd-backlight.rules
/lib/firmware/facetimehd/firmware.bin
/etc/apt/apt.conf.d/99-mba-kernel-guard"

CONTROL_EXPECT="artefact:facetimehd-firmware
artefact:kbd-backlight-rule
artefact:kernel-guard-hook
rule:kbd-backlight
helper:kbd-backlight"

cmd_verify_control() {
  cd "$WORK" || die "run '$0 prepare' first"
  [ -s "$WORK/testbase.qcow2" ] || die "no testbase.qcow2 -- run '$0 testbase' first"
  sudo -n true 2>/dev/null || die "this needs root for nbd and mount, and sudo is asking for a password"

  local dev="${MBA_VMTEST_NBD:-/dev/nbd0}"
  local mnt="$WORK/ctl-mnt"
  mkdir -p "$mnt"

  ctl_cleanup() {
    sudo umount "$mnt" 2>/dev/null
    sudo qemu-nbd --disconnect "$dev" >/dev/null 2>&1
  }
  trap 'ctl_cleanup' EXIT

  cmd_stop >/dev/null 2>&1
  make_overlay "$WORK/testbase.qcow2" "$WORK/control.qcow2"
  nbd_attach "$WORK/control.qcow2" "$dev"
  sudo mount "${dev}p2" "$mnt" || die "cannot mount the control image"

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sudo test -e "$mnt$f" || die "cannot break $f -- it is already missing from testbase"
    sudo rm -f "$mnt$f"
    info "broke $f"
  done <<< "$CONTROL_BREAKS"

  ctl_cleanup
  trap - EXIT
  ok "control image built"

  cmd_verify control.qcow2 || true

  # Grade the grader.
  local failed expected missing unexpected
  failed=$(awk -F'|' '/^RESULT FAIL\|/ {print $2}' "$WORK/verify.last" 2>/dev/null | sort)
  expected=$(echo "$CONTROL_EXPECT" | sort)
  missing=$(comm -23 <(echo "$expected") <(echo "$failed"))
  unexpected=$(comm -13 <(echo "$expected") <(echo "$failed"))

  say "control result"
  if [ -z "$missing" ] && [ -z "$unexpected" ]; then
    ok "exactly the expected $(echo "$expected" | grep -c .) checks failed -- the verifier discriminates"
    info "and every unrelated check stayed green, so it is not simply failing everything"
    rm -f "$WORK/control.qcow2"
    return 0
  fi
  [ -n "$missing" ] && { bad "these SHOULD have failed and did not:"; echo "$missing" | sed 's/^/        /'; }
  [ -n "$unexpected" ] && { bad "these failed unexpectedly:"; echo "$unexpected" | sed 's/^/        /'; }
  info "control image kept at $WORK/control.qcow2 for inspection"
  return 1
}

# ------------------------------------------------------------ status / teardown

cmd_status() {
  echo
  echo "  work dir  $WORK"
  echo "  snapshots $SNAPSRC"
  echo
  [ -d "$WORK" ] || { info "not prepared yet"; echo; return 0; }
  local f
  [ -s "$WORK/golden.snapshot" ] && printf '  %-28s %s\n' "golden built from" "$(cat "$WORK/golden.snapshot")"
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
  boot)    cmd_boot "${2:-}" "${3:-}" ;;
  restore) shift 2>/dev/null; cmd_restore "$@" ;;
  sh)         cmd_sh "${2:-}" "${3:-8}" ;;
  testbase)   cmd_testbase ;;
  verify)     cmd_verify "${2:-}" ;;
  verify-control) cmd_verify_control ;;
  usb-image)  cmd_usb_image "${2:-}" ;;
  update-test) shift 2>/dev/null; cmd_update_test "$@" ;;
  bootdisk)   cmd_bootdisk "${2:-}" ;;
  screenshot) cmd_screenshot "${2:-}" ;;
  steps)   cmd_steps ;;
  status)  cmd_status ;;
  stop)    cmd_stop ;;
  clean)   cmd_clean ;;
  *)       usage ;;
esac
