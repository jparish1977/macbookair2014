#!/bin/bash
# Build the SERVER side of this project from nothing, on any Debian/Ubuntu host.
#
#   ./server-provision.sh                       # report only, changes nothing
#   ./server-provision.sh apply                 # do it
#   ssh somehost 'bash -s' < server-provision.sh
#
# WHY THIS EXISTS
#
# workshop/provision.sh already makes the point for the kernel workshop: it is
# not a machine, it is a recipe. The other half of what this project needs from
# a server was never written down, and by 2026-08-10 that half had grown to
# hold the disaster-recovery copy of the laptop, the irreplaceable u810 recovery
# media, and the encrypted user-data repo.
#
# So: the laptop can be rebuilt from a snapshot in twenty minutes, and the
# machine that makes that possible was an afternoon of remembering what had been
# installed by hand. This closes that.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# ssh keys, tailscale membership, and the restic passphrase. Those are secrets
# and access decisions; a provisioning script that invents them is worse than
# one that lists them and stops. They are printed at the end as the manual tail.
#
# ON REDUNDANCY: PREFERRED, NOT REQUIRED
#
# The disaster-recovery copy spent its first days on the only disk in the estate
# with no redundancy -- the copy that exists BECAUSE a disk might die, on a disk
# whose death would take it. Worth catching, so this detects what is redundant
# and says so plainly.
#
# But it does not refuse. A host may have one disk and that is a real situation,
# not a misconfiguration; a copy on a single disk in another building still
# survives the laptop's death, which is the point of it. Compare
# system-snapshot.sh, which DOES refuse network targets -- that rule is absolute
# for a specific reason (Wi-Fi is the only interface, so the target is
# unreachable in exactly the scenario it exists for). This one is a preference,
# and preferences advise.

set -uo pipefail

MODE="${1:-check}"
VMTEST_DIR="${MBA_SERVER_VMTEST_DIR:-/srv/mba-vmtest}"
SNAP_LINK="${MBA_SERVER_SNAP_LINK:-/srv/mba-snapshots}"
ARCHIVE_DIR="${MBA_SERVER_ARCHIVE:-$HOME/archive}"
RESTIC_DIR="${MBA_SERVER_RESTIC:-$HOME/backups/restic}"

PKGS=(qemu-system-x86 qemu-utils ovmf p7zip-full cpio initramfs-tools
      rsync python3 curl gdisk dosfstools smartmontools sysstat)

say()  { echo; echo -e "\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m[ok]\033[0m   $*"; }
warn() { echo -e "    \033[33m[warn]\033[0m $*"; }
bad()  { echo -e "    \033[31m[!!]\033[0m   $*"; }
info() { echo "    $*"; }
die()  { echo; echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }

doing() { [ "$MODE" = apply ]; }
run()   { if doing; then "$@"; else echo "      would run: $*"; fi; }

# ---- storage -----------------------------------------------------------------
#
# Which filesystem is a given path on, and does that filesystem survive a disk?
# md is what this estate uses; LVM and btrfs can be redundant too and are
# reported as unknown rather than guessed at, because guessing wrong here is the
# one answer that matters.
backing_dev() { df --output=source "$1" 2>/dev/null | tail -1; }

redundancy_of() {   # $1 = path -> "redundant: raid5" | "single disk" | "unknown"
  local dev base lvl
  dev=$(backing_dev "$1")
  base=$(basename "$dev" | sed 's/p\?[0-9]*$//')
  if [ -r /proc/mdstat ] && grep -q "^$base " /proc/mdstat 2>/dev/null; then
    lvl=$(awk -v d="$base" '$1==d {for(i=1;i<=NF;i++) if($i ~ /^raid/) print $i}' /proc/mdstat)
    case "$lvl" in
      raid1|raid5|raid6|raid10) echo "redundant: $lvl" ;;
      raid0|linear)             echo "NOT redundant: $lvl" ;;
      *)                        echo "md, level unknown" ;;
    esac
  elif [ -e "/dev/$base" ]; then
    echo "single disk"
  else
    echo "unknown"
  fi
}

cmd_report() {
  say "This host"
  info "$(hostname) -- $(nproc) cpus, $(free -g | awk '/^Mem/{print $2}')G RAM"
  [ -e /dev/kvm ] && ok "/dev/kvm present" || bad "no /dev/kvm -- the VM rig cannot run here"
  modinfo nbd >/dev/null 2>&1 && ok "nbd module available" || warn "no nbd module -- testbase/usb-image need it"
  sudo -n true 2>/dev/null && ok "passwordless sudo" || warn "sudo wants a password (fine, but nothing here will be unattended)"

  say "Storage, and what survives a disk failure"
  local m
  while read -r m; do
    [ -n "$m" ] || continue
    printf '    %-28s %-14s %-22s %s\n' "$m" \
      "$(df -h --output=avail "$m" 2>/dev/null | tail -1 | tr -d ' ') free" \
      "$(backing_dev "$m")" "$(redundancy_of "$m")"
  done < <(df --output=target -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | grep -vE '^/(sys|proc|run|boot/efi)' | sort -u)

  say "Missing packages"
  local miss=() p
  for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || miss+=("$p"); done
  if [ "${#miss[@]}" = 0 ]; then ok "all present"
  else info "${miss[*]}"; fi
  MISSING=("${miss[@]}")
}

# ---- the ext4 reserve --------------------------------------------------------
#
# ext4 reserves 5% for root by default. On / that is a safety net worth having.
# On a multi-terabyte DATA filesystem it is a lot of space doing nothing: 186G
# on this estate's 3.6T array, reclaimed instantly and online with tune2fs -m 1.
# Reported, not changed -- it is somebody's filesystem.
check_reserve() {
  local path="$1" dev pct total res
  dev=$(backing_dev "$path")
  case "$dev" in /dev/*) ;; *) return 0 ;; esac
  total=$(sudo tune2fs -l "$dev" 2>/dev/null | awk '/^Block count/{print $3}')
  res=$(sudo tune2fs -l "$dev" 2>/dev/null | awk '/^Reserved block count/{print $4}')
  [ -n "$total" ] && [ -n "$res" ] || return 0
  pct=$(( res * 100 / total ))
  local gb=$(( res * 4096 / 1073741824 ))
  if [ "$pct" -ge 5 ] && [ "$gb" -ge 20 ]; then
    warn "$path reserves ${gb}G (${pct}%) for root on $dev"
    info "  On a data filesystem that buys little. To reclaim most of it:"
    info "      sudo tune2fs -m 1 $dev"
  fi
}

# ---- layout ------------------------------------------------------------------

cmd_layout() {
  say "Where things should live"

  # Prefer redundant storage for anything irreplaceable. Advise, do not refuse:
  # a host with one disk is a real situation, and a copy on a single disk
  # elsewhere still survives the laptop dying, which is the whole point.
  local best="" bestfree=0 m free red
  while read -r m; do
    [ -n "$m" ] || continue
    red=$(redundancy_of "$m")
    case "$red" in redundant:*) ;; *) continue ;; esac
    free=$(df --output=avail "$m" 2>/dev/null | tail -1 | tr -d ' ')
    [ "${free:-0}" -gt "$bestfree" ] && { bestfree="$free"; best="$m"; }
  done < <(df --output=target -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2 | grep -vE '^/(sys|proc|run|boot/efi)' | sort -u)

  if [ -n "$best" ]; then
    ok "redundant filesystem with the most room: $best ($(( bestfree / 1048576 ))G free)"
    info "Put the snapshot store and the archives there. They are the copies"
    info "that exist because a disk might die."
  else
    warn "no redundant filesystem found on this host"
    info "That is not a blocker -- a copy on a single disk somewhere else still"
    info "survives the laptop dying, which is the point of it. But if this host"
    info "ever gains a second disk, mirroring it is the cheapest win available."
  fi

  local snap_store="${MBA_SERVER_SNAP_STORE:-${best:-/srv}/mba-snapshots}"
  info ""
  info "snapshot store   $snap_store"
  info "  reached as     $SNAP_LINK (symlink, so configs naming the old path still work)"
  info "archive          $ARCHIVE_DIR      static, irreplaceable, never versioned"
  info "restic repos     $RESTIC_DIR       one per machine, each with its own passphrase"
  info "VM rig           $VMTEST_DIR       disposable; needs no redundancy, it rebuilds"

  say "Creating it"
  run sudo mkdir -p "$snap_store"
  run sudo chown "$(id -u):$(id -g)" "$snap_store"
  run mkdir -p "$ARCHIVE_DIR" "$RESTIC_DIR"
  run sudo mkdir -p "$VMTEST_DIR"
  run sudo chown "$(id -u):$(id -g)" "$VMTEST_DIR"

  if [ -e "$SNAP_LINK" ] && [ ! -L "$SNAP_LINK" ]; then
    warn "$SNAP_LINK exists and is not a symlink -- leaving it alone"
    info "  If it holds the store already, move it to $snap_store and symlink."
  elif [ "$snap_store" != "$SNAP_LINK" ]; then
    run sudo ln -sfn "$snap_store" "$SNAP_LINK"
  fi

  check_reserve "${best:-/}"
}

# ---- packages ----------------------------------------------------------------

cmd_packages() {
  say "Packages"
  [ "${#MISSING[@]}" = 0 ] && { ok "nothing to install"; return 0; }
  info "installing: ${MISSING[*]}"
  run sudo apt-get update -qq
  run sudo apt-get install -y "${MISSING[@]}"
}

# ---- the manual tail ---------------------------------------------------------

cmd_manual() {
  say "What this script deliberately will not do"
  info "These are secrets and access decisions. A provisioning script that"
  info "invents them is worse than one that lists them and stops."
  echo
  info "1. ssh: the laptop must reach this host by key, and this host must reach"
  info "   anywhere it pushes third copies to."
  info "2. tailscale, if this host should be reachable away from the LAN. Note"
  info "   a bare LAN alias works at home and fails everywhere else, which is a"
  info "   confusing way to discover it."
  info "3. The restic passphrase lives on the LAPTOP's keyring, not here -- this"
  info "   host only ever holds opaque blobs. That is deliberate: the machine"
  info "   storing the backup should not be able to read it."
  echo
  info "Then, from the laptop:"
  info "  ./snapshot-offsite.sh status      # is the store reachable and writable"
  info "  ./home-backup.sh init             # create the restic repo"
  info "  ssh HOST '$VMTEST_DIR/vm-restore-test.sh prepare'"
}

case "$MODE" in
  check)
    cmd_report; cmd_layout; cmd_manual
    echo; info "Nothing was changed. Re-run as: $0 apply"; echo ;;
  apply)
    cmd_report; cmd_packages; cmd_layout; cmd_manual
    echo; ok "done"; echo ;;
  -h|--help) sed -n '2,12p' "$0" ;;
  *) die "usage: $0 [check|apply]" ;;
esac
