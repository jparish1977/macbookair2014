#!/bin/bash
# Back up the live user data. Encrypted, versioned, and deliberately thin.
#
# WHAT THIS IS, AND WHAT IT IS NOT
#
# The system snapshots (system-snapshot.sh) exclude /home entirely, by design --
# they roll the machine back, not your files. This covers the other half, and it
# is a different job: system state changes at moments you notice, so snapshots
# are taken deliberately; user data changes continuously, so this wants running
# often and cheaply.
#
# THE REPO IS A BARE, STANDARD RESTIC REPO. THAT IS THE POINT.
#
# restic does everything that is actually hard here -- encryption, key handling,
# deduplication, compression, snapshots, retention, integrity checking, and a
# read-only FUSE mount. None of that is reimplemented here and none of it should
# be. Nothing in this script writes a custom format or a metadata sidecar.
#
# The test to hold this to: if this script vanished, you restore with stock
# restic and the passphrase, and lose nothing but convenience.
#
# So this only covers the parts restic genuinely leaves to you:
#
#   the exclusion list   real decisions that should be versioned and reviewable
#                        rather than retyped from memory
#   restore-test         restic has no equivalent. `check` proves the repo is
#                        INTACT; it does not prove you can get your files back,
#                        and this project does not accept a tool's own word for
#                        that -- see restore-test.sh and vm-restore-test.sh
#   browse               `restic mount` with a timeout and a log line, so
#                        looking at data is deliberate and self-closing
#   guards               battery, key, reachability -- the same refusals as the
#                        rest of this repo
#   restic               a passthrough that sets the repo and key, so every
#                        other restic command works without exporting anything
#
# WHY IT IS ENCRYPTED, WHICH IS NOT THE REASON YOU MIGHT ASSUME
#
# This laptop's disk is plain ext4 with no LUKS, so anyone holding it already
# has this data in the clear -- the passphrase protects nothing there. What it
# protects is every OTHER copy: iteration8's disk when it is eventually replaced
# or resold, the 7810's drives, and the everyday case of someone with access to
# a shared machine browsing where they did not mean to. An rsync'd home
# directory is one careless `ls` from showing you something you would rather not
# have seen. A restic repo is opaque blobs -- even the filenames live inside the
# encrypted metadata.
#
# Hence per-user repos with per-user passphrases: not distrust, just not putting
# anyone in that position.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="$HERE/.home-backup.conf"

# ---- defaults. Override any of these in .home-backup.conf (untracked). -------

REPO_HOST="${HOME_BACKUP_HOST:-iteration8.tail51fded.ts.net}"
REPO_USER="${HOME_BACKUP_USER:-joe}"
REPO_BASE="${HOME_BACKUP_BASE:-/home/joe/backups/restic}"
REPO_NAME="${HOME_BACKUP_NAME:-$(hostname)}"

# What is worth keeping. Explicit rather than "/home minus exclusions", because
# an include list fails safe: a new directory of junk is not backed up until
# somebody says so, whereas a new directory of secrets is not silently missed
# either -- you notice it is absent.
INCLUDE_DEFAULT=(projects Documents .config .thunderbird .claude drive-inventory .ssh .gnupg .mozilla)

# Deliberately absent: Downloads (11.7G of u810 recovery media, archived
# separately and permanently at iteration8:~/archive/u810 -- it never changes,
# so versioning it every day would be waste), batocera-backups (already on
# iteration8 twice over and reproducible from the source discs in ~/discs), and
# .steam (re-downloadable).
EXCLUDE_DEFAULT=(
  '**/.cache' '**/Cache' '**/CachedData' '**/Code Cache' '**/GPUCache'
  '**/node_modules' '**/__pycache__' '**/.venv' '**/venv'
  '**/.Trash*' '**/Trash'
  '*.iso' '*.qcow2' '*.img'
)

KEEP_DAILY="${HOME_BACKUP_KEEP_DAILY:-7}"
KEEP_WEEKLY="${HOME_BACKUP_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${HOME_BACKUP_KEEP_MONTHLY:-6}"

BROWSE_MINUTES_DEFAULT="${HOME_BACKUP_BROWSE_MINUTES:-15}"
ACCESS_LOG="${HOME_BACKUP_ACCESS_LOG:-$HOME/.local/state/home-backup-access.log}"

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

INCLUDE=("${INCLUDE[@]:-${INCLUDE_DEFAULT[@]}}")
EXCLUDE=("${EXCLUDE[@]:-${EXCLUDE_DEFAULT[@]}}")

REPO="sftp:$REPO_USER@$REPO_HOST:$REPO_BASE/$REPO_NAME"

say()  { echo; echo -e "\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m[ok]\033[0m   $*"; }
warn() { echo -e "    \033[33m[warn]\033[0m $*"; }
bad()  { echo -e "    \033[31m[!!]\033[0m   $*"; }
info() { echo "    $*"; }
die()  { echo; echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }

usage() {
  cat <<EOF

home-backup.sh -- the live user data, encrypted and versioned

  $0 status              repo, last snapshot, what is covered, where the key is
  $0 init                create the repo (once)
  $0 backup              the main verb
  $0 restore-test        restore to scratch and COMPARE -- the thing restic
                         cannot tell you
  $0 browse [MINUTES]    read-only mount, auto-unmounts (default $BROWSE_MINUTES_DEFAULT min), logged
  $0 forget              apply retention ($KEEP_DAILY daily / $KEEP_WEEKLY weekly / $KEEP_MONTHLY monthly), then prune
  $0 restic ARGS...      plain restic against this repo -- snapshots, ls, diff,
                         check, stats, restore. Learn the real tool.
  $0 restore-help        how to get it back when this laptop is gone

The repo is a BARE STANDARD RESTIC REPO. If this script disappears you restore
with stock restic and the passphrase. Config: $CONF (untracked).

EOF
  exit 1
}

# ---- key ---------------------------------------------------------------------
#
# The passphrase lives in the login keyring, not in a file on a disk that has no
# encryption of its own. It still needs to exist somewhere this machine is not:
# WRITE IT DOWN. An encrypted backup you cannot decrypt is a very thorough way
# of losing your data, and that failure is silent until the day it matters.
key_command() { echo "secret-tool lookup restic $REPO_NAME"; }

have_key() { secret-tool lookup restic "$REPO_NAME" >/dev/null 2>&1; }

require_key() {
  command -v secret-tool >/dev/null || die "secret-tool missing: sudo apt install libsecret-tools"
  have_key && return 0
  bad "no passphrase in the keyring for '$REPO_NAME'"
  info "Store it (you will be prompted, and it is kept in the login keyring):"
  info "  secret-tool store --label=\"restic $REPO_NAME\" restic $REPO_NAME"
  info ""
  info "Then WRITE IT DOWN somewhere that is not this machine. If the laptop"
  info "dies, the keyring dies with it and the backup becomes unreadable."
  exit 1
}

restic_env() {
  export RESTIC_REPOSITORY="$REPO"
  export RESTIC_PASSWORD_COMMAND="$(key_command)"
}

on_mains() {
  [ -r /sys/class/power_supply/ADP1/online ] || return 0
  [ "$(cat /sys/class/power_supply/ADP1/online)" = 1 ]
}

# ---- status ------------------------------------------------------------------

cmd_status() {
  say "Repo"
  info "$REPO"
  command -v restic >/dev/null || die "restic missing: sudo apt install restic"

  if have_key; then ok "passphrase found in the login keyring"
  else warn "NO passphrase in the keyring for '$REPO_NAME' -- see '$0 init'"; fi

  on_mains && ok "on mains" || warn "on battery (backup will refuse)"

  say "What is covered"
  local p
  for p in "${INCLUDE[@]}"; do
    if [ -e "$HOME/$p" ]; then
      printf '    %-18s %s\n' "$p" "$(du -sh "$HOME/$p" 2>/dev/null | cut -f1)"
    else
      printf '    %-18s %s\n' "$p" "(absent)"
    fi
  done
  info ""
  info "Not covered, on purpose: Downloads (u810 media archived separately),"
  info "batocera-backups (already on iteration8 twice), .steam (re-downloadable)."

  have_key || return 0
  restic_env
  say "Snapshots"
  restic snapshots --latest 5 2>&1 | tail -8 | sed 's/^/    /' \
    || warn "could not reach the repo (or it does not exist yet -- '$0 init')"
}

# ---- init --------------------------------------------------------------------

cmd_init() {
  command -v restic >/dev/null || die "restic missing: sudo apt install restic"
  command -v secret-tool >/dev/null || die "secret-tool missing: sudo apt install libsecret-tools"

  if ! have_key; then
    say "Set a passphrase first"
    info "  secret-tool store --label=\"restic $REPO_NAME\" restic $REPO_NAME"
    info ""
    info "Choose something you can write down and type. Then WRITE IT DOWN --"
    info "off this machine. The keyring is unlocked by your login password and"
    info "dies with the laptop; the written copy is what makes this recoverable."
    exit 1
  fi

  restic_env
  say "Creating $REPO"
  restic init || die "restic init failed"
  ok "repo created"
  info "Now: $0 backup"
}

# ---- backup ------------------------------------------------------------------

cmd_backup() {
  require_key
  on_mains || die "on battery -- this reads several GB; plug in first"
  restic_env

  local -a args=(backup --verbose --exclude-caches)
  local p
  for p in "${EXCLUDE[@]}"; do args+=(--exclude "$p"); done
  for p in "${INCLUDE[@]}"; do [ -e "$HOME/$p" ] && args+=("$HOME/$p"); done

  say "Backing up"
  info "$(( ${#INCLUDE[@]} )) paths, ${#EXCLUDE[@]} exclusion patterns"
  restic "${args[@]}" || die "backup failed"
  echo
  ok "done"
  info "Retention is NOT applied automatically -- run '$0 forget' when you mean to."
}

# ---- restore-test ------------------------------------------------------------
#
# The one thing restic will not tell you. `check` verifies the repo's own
# integrity; it says nothing about whether the files come back. This restores a
# real subset to a scratch directory and diffs it against the live tree.
cmd_restore_test() {
  require_key
  restic_env
  local scratch="${TMPDIR:-/tmp}/home-backup-restore-test.$$"
  local subject="${1:-projects}"

  [ -e "$HOME/$subject" ] || die "no such path to test with: ~/$subject"

  say "Restoring ~/$subject from the newest snapshot into scratch"
  info "$scratch"
  mkdir -p "$scratch" || die "cannot create $scratch"
  restic restore latest --target "$scratch" --include "$HOME/$subject" \
    || { rm -rf "$scratch"; die "restore failed"; }

  say "Comparing restored against live"
  local out rc
  out=$(diff -rq "$HOME/$subject" "$scratch$HOME/$subject" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    ok "identical -- every file came back byte for byte"
    info "$(find "$scratch$HOME/$subject" -type f 2>/dev/null | wc -l) files compared"
  else
    warn "differences found (files changed since the snapshot will show here):"
    echo "$out" | head -15 | sed 's/^/        /'
    info ""
    info "Differences are only a fault if they are files you have NOT touched"
    info "since the last backup. Check the timestamps before worrying."
  fi
  rm -rf "$scratch"
  info "scratch removed"
}

# ---- browse ------------------------------------------------------------------
#
# Deliberate, time-boxed, logged. Most troubleshooting never needs this: `restic
# ls` and `restic diff` answer "is it there / what changed" with filenames only,
# and `stats` answers "how big" with nothing at all. Reach for this only when you
# need to see content, and it closes itself whether or not you remember.
cmd_browse() {
  require_key
  local mins="${1:-$BROWSE_MINUTES_DEFAULT}"
  case "$mins" in ''|*[!0-9]*) die "minutes must be a number" ;; esac
  command -v fusermount3 >/dev/null || command -v fusermount >/dev/null \
    || die "no fusermount -- restic mount needs FUSE"
  restic_env

  local mnt="${TMPDIR:-/tmp}/home-backup-browse.$$"
  mkdir -p "$mnt" || die "cannot create $mnt"
  mkdir -p "$(dirname "$ACCESS_LOG")" 2>/dev/null
  echo "$(date -Is) mounted $REPO at $mnt for ${mins}m by $(whoami)" >> "$ACCESS_LOG"

  say "Mounting read-only for $mins minutes"
  info "$mnt"
  info "Logged to $ACCESS_LOG -- so 'did I look at that, and when' is answerable."
  info "It will unmount itself. Ctrl-C here also unmounts."

  ( sleep $(( mins * 60 ))
    fusermount3 -u "$mnt" 2>/dev/null || fusermount -u "$mnt" 2>/dev/null
    echo "$(date -Is) auto-unmounted $mnt" >> "$ACCESS_LOG" ) &
  local timer=$!

  restic mount "$mnt"
  kill "$timer" 2>/dev/null
  fusermount3 -u "$mnt" 2>/dev/null || fusermount -u "$mnt" 2>/dev/null
  rmdir "$mnt" 2>/dev/null
  echo "$(date -Is) unmounted $mnt" >> "$ACCESS_LOG"
  ok "unmounted"
}

# ---- forget ------------------------------------------------------------------

cmd_forget() {
  require_key
  restic_env
  say "Applying retention: $KEEP_DAILY daily, $KEEP_WEEKLY weekly, $KEEP_MONTHLY monthly"
  info "Dry run first -- nothing is removed yet."
  restic forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
                --keep-monthly "$KEEP_MONTHLY" --dry-run 2>&1 | tail -20 | sed 's/^/    /'
  echo
  read -r -p "  Apply and prune? [y/N] " a
  case "$a" in
    y|Y) restic forget --keep-daily "$KEEP_DAILY" --keep-weekly "$KEEP_WEEKLY" \
                       --keep-monthly "$KEEP_MONTHLY" --prune || die "forget failed"
         ok "applied" ;;
    *)   info "left alone" ;;
  esac
}

# ---- restic passthrough ------------------------------------------------------

cmd_restic() {
  require_key
  restic_env
  [ "$#" -gt 0 ] || die "usage: $0 restic snapshots|ls|diff|check|stats|restore ..."
  restic "$@"
}

# ---- restore-help ------------------------------------------------------------

cmd_restore_help() {
  cat <<EOF

  GETTING IT BACK -- read before you need it.

  This is a BARE STANDARD RESTIC REPO. Nothing here is required to restore it.
  On any machine with restic and the passphrase:

      restic -r $REPO snapshots
      restic -r $REPO restore latest --target /somewhere

  THREE THINGS MUST SURVIVE THIS LAPTOP, and two of them are not data:

  1. The passphrase. It lives in this machine's login keyring, which dies with
     the machine. THE WRITTEN COPY IS THE REAL ONE. Without it the repo is
     unreadable by anyone including you -- that is the point of encryption and
     it does not make an exception for the owner.

  2. A restic binary. It is a single static Go binary; keep a copy alongside
     the archive at $REPO_USER@$REPO_HOST:~/archive/ so recovery does not
     depend on a working package manager or a live internet.

  3. Knowing WHERE the repo is. It is written above; it is also in this repo's
     README, which is on GitHub.

  The repo is on iteration8's RAID5, so a single disk failure there does not
  lose it. It is NOT proof against that machine being lost entirely -- for that,
  copy the repo directory to the 7810 (D: has 1.6T free). It is just files:

      rsync -a $REPO_USER@$REPO_HOST:$REPO_BASE/$REPO_NAME/ /d/backups/$REPO_NAME/

  What is NOT in here, deliberately: Downloads (the u810 recovery media is
  archived whole at ~/archive/u810 -- it never changes), batocera-backups
  (already on iteration8 and reproducible from ~/discs), .steam.

EOF
}

case "${1:-status}" in
  status)        cmd_status ;;
  init)          cmd_init ;;
  backup)        cmd_backup ;;
  restore-test)  cmd_restore_test "${2:-projects}" ;;
  browse)        cmd_browse "${2:-}" ;;
  forget)        cmd_forget ;;
  restic)        shift; cmd_restic "$@" ;;
  restore-help)  cmd_restore_help ;;
  -h|--help)     usage ;;
  *)             usage ;;
esac
