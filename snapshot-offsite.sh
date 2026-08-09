#!/bin/bash
# Copy the local snapshot tree to another machine. DISASTER RECOVERY, not rollback.
#
# WHY THIS IS A SEPARATE SCRIPT FROM system-snapshot.sh
#
# Those two jobs pull in opposite directions and conflating them is the mistake
# SNAPSHOTS.md exists to prevent:
#
#   rollback           local only. The likeliest bad update on this machine costs
#                      you Wi-Fi (wl/broadcom-sta, the only interface), and a
#                      snapshot on another host is unreachable at exactly that
#                      moment. system-snapshot.sh REFUSES a network target.
#   disaster recovery  remote only. /timeshift lives on the same sda as /, so a
#                      dead disk takes the system and every snapshot with it.
#                      That is what this script is for.
#
# Local for rollback, remote for disk death. Do not invert it, and do not let
# this script talk you into pointing timeshift itself at the network.
#
# WHY --fake-super
#
# Snapshots are a faithful copy of a root-owned system: setuid bits, ownership,
# device-ish permissions. Sending them to a normal remote account would flatten
# all of that and the copy would not be restorable. --fake-super makes the
# RECEIVER store the real ownership and mode in a user.rsync.%stat xattr, so an
# unprivileged remote account holds a faithful copy. That is why the target
# filesystem must support user xattrs -- `status` checks it rather than assuming.
#
# The trap this creates is on the way back: pulling the tree home ALSO needs
# --fake-super on the remote side, or you get a directory owned by your user with
# the real metadata stranded in xattrs nobody read. `restore-help` spells it out.
#
# WHY -H IS NOT OPTIONAL
#
# Every snapshot is a complete tree whose unchanged files are hardlinks into the
# previous one. Without -H each snapshot is sent as a full copy. Measured here on
# 2026-08-08: 20.03G occupied against 38.69G apparent -- -H saved 18.66G, very
# nearly halving it, and the saving grows with every snapshot kept.
#
# -H does NOT disable incremental recursion. Only --delete-before, --delete-after,
# --prune-empty-dirs and --delay-updates do that. rsync therefore keeps scanning
# while it transfers, which has one visible and alarming consequence: the progress
# percentage GOES BACKWARDS when it discovers more of the tree. It reached 98% of
# the first snapshot here, found the second, and dropped to 86%. Nothing is wrong.
#
# The percentage is misleading in a second way. It counts every hardlink at full
# size, so a 20G tree is measured against a ~38G total and a completed transfer
# reports "51%". `watch` exists because that line cannot be read as progress.
#
# The real cost of incremental recursion with -H is that rsync may send a file's
# data before finding another link to it later -- bytes wasted, never correctness.
# Sorting saves us: the oldest snapshot is the one the others link into and it
# transfers first. --no-inc-recursive would remove the waste at the price of a
# long silent scan before anything moves.

set -uo pipefail

SNAPDIR=/timeshift/snapshots

# $HOME is /root under sudo, so the invoking user's home is what we want for the
# ssh key. Deriving it also keeps this script working for someone who is not joe.
home_of_caller() { getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6; }

# Overridable so this is not welded to one machine.
REMOTE_HOST="${MBA_OFFSITE_HOST:-100.109.232.15}"   # tailnet IP on purpose: the
                                                    # `iteration8` ssh alias points
                                                    # at iteration8.local, which
                                                    # resolves only on its own LAN.
REMOTE_USER="${MBA_OFFSITE_USER:-joe}"
REMOTE_DIR="${MBA_OFFSITE_DIR:-/srv/mba-snapshots}"

CALLER_HOME="$(home_of_caller)"
SSH_KEY="${MBA_OFFSITE_KEY:-$CALLER_HOME/.ssh/id_ed25519_iteration8}"

# push and verify need root to read the snapshot tree, and under sudo $HOME
# becomes /root -- so ssh looks in /root/.ssh/known_hosts, which has never seen
# this host, and BatchMode cannot prompt to accept it. The whole thing then fails
# with "cannot reach", which points at the network and is entirely misleading.
# Use the invoking user's known_hosts: it reuses trust already established rather
# than turning host-key checking off, which is the other way people "fix" this.
KNOWN_HOSTS="${MBA_OFFSITE_KNOWN_HOSTS:-$CALLER_HOME/.ssh/known_hosts}"

# Refuse to start a multi-hour transfer that would leave the remote disk full.
MIN_REMOTE_FREE_GB=10

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "  WARN  $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; }
info() { echo "  --    $*"; }

need_root() { [ "$(id -u)" = 0 ] || die "$1 needs root -- the snapshot tree is root-owned and unreadable otherwise.
       Try: sudo $0 $1"; }

gb() { awk -v b="$1" 'BEGIN { printf "%.1fG", b/1024/1024/1024 }'; }

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30
          -o IdentitiesOnly=yes -o "UserKnownHostsFile=$KNOWN_HOSTS")
rsh() { ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" "$@"; }

# "cannot reach" is a conclusion, not a diagnosis. ssh already knows exactly what
# went wrong -- refused, no route, bad key, unknown host key -- so show it rather
# than making the next person re-run it by hand to find out.
why_unreachable() {
  echo "        ssh said:"
  ssh "${SSH_OPTS[@]}" -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_HOST" true 2>&1 \
    | sed 's/^/          /' | head -4
  [ -r "$KNOWN_HOSTS" ] || echo "          (no readable known_hosts at $KNOWN_HOSTS)"
  [ -r "$SSH_KEY" ]     || echo "          (no readable key at $SSH_KEY)"
}

usage() {
  cat <<EOF
usage: $0 status                what exists both ends, and whether a push can work
       $0 push [--dry-run]      copy the snapshot tree to $REMOTE_HOST (root)
       $0 push --mirror         ... and delete remote snapshots no longer held here
       $0 verify                compare both ends without transferring anything (root)
       $0 watch [SECONDS]       readable progress for a push running elsewhere
       $0 pull-test [DIR]       prove the copy restores: pull probes back (root)
       $0 restore-help          how to get the tree back, and the trap on the way

This is DISASTER RECOVERY -- for a dead disk. For rolling back a bad update use
./system-snapshot.sh (local) or ./apt-rollback.sh (precise). Never point timeshift
itself at the network: see the header of this script and SNAPSHOTS.md.

Override the target with MBA_OFFSITE_HOST / _USER / _DIR / _KEY.
EOF
  exit 1
}

# --------------------------------------------------------------------- helpers

local_snaps()  { ls -1 "$SNAPDIR" 2>/dev/null | sort; }
remote_snaps() { rsh "ls -1 '$REMOTE_DIR' 2>/dev/null | sort" 2>/dev/null; }

snap_comment() {
  sed -n 's/.*"comments"[^:]*:[ ]*"\(.*\)".*/\1/p' "$SNAPDIR/$1/info.json" 2>/dev/null | head -1
}

# The rsync invocation lives in ONE place because every subcommand has to agree
# on it. If `verify` compared with different flags than `push` transferred with,
# it would report a clean copy that is not the one on disk -- and -H or
# --fake-super differing between the two is exactly the kind of copy that looks
# fine and does not restore.
build_rsync_cmd() {   # sets RSYNC_CMD
  RSYNC_CMD=(rsync -aHAX --numeric-ids
             --partial-dir=.rsync-partial
             --rsync-path="rsync --fake-super"
             -e "ssh ${SSH_OPTS[*]} -i $SSH_KEY")
}

# ---------------------------------------------------------------------- status

cmd_status() {
  echo
  echo "  DISASTER RECOVERY copy -- for a dead disk, not for rolling back an update."
  echo
  echo "  local   $SNAPDIR"
  echo "  remote  $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
  echo

  local FAILED=0

  # -- local side
  local n; n=$(local_snaps | grep -c .)
  if [ "$n" = 0 ]; then
    bad "no local snapshots to copy. Take one: sudo ./system-snapshot.sh create \"reason\""
    FAILED=1
  else
    ok "$n local snapshot(s):"
    local s
    while read -r s; do
      [ -n "$s" ] && printf '          %-22s %s\n' "$s" "$(snap_comment "$s")"
    done <<< "$(local_snaps)"
  fi

  # -- the -H memory cost, which is the one local resource this can exhaust
  local entries avail_kb
  entries=$(python3 - "$SNAPDIR" <<'PY' 2>/dev/null
import json, os, sys
t = 0
d = sys.argv[1]
for s in os.listdir(d):
    p = os.path.join(d, s, "info.json")
    try:
        with open(p) as f: t += int(json.load(f).get("file_count", 0))
    except Exception: pass
print(t)
PY
)
  avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
  if [ -n "$entries" ] && [ "$entries" -gt 0 ]; then
    info "$entries entries across all snapshots"
    echo "        rsync tracks inodes to spot hardlinks; MemAvailable $(gb "$((avail_kb * 1024))"),"
    echo "        swap free $(gb "$(( $(awk '/SwapFree/{print $2}' /proc/meminfo) * 1024 ))"). Measured: 1.48M entries transferred fine here."
    echo "        The progress percentage WILL go backwards -- -H does not disable"
    echo "        incremental recursion, so rsync is still discovering the total"
    echo "        while it transfers. 98% then 86% is normal, not a fault."
  fi

  # -- reachability
  if ! rsh true 2>/dev/null; then
    bad "cannot reach $REMOTE_USER@$REMOTE_HOST with $SSH_KEY"
    why_unreachable
    echo "        Wi-Fi is the only interface here. If it is down, this job simply"
    echo "        waits -- that is the correct behaviour, not a fault to work around."
    FAILED=1
    echo
    return "$FAILED"
  fi
  ok "reachable: $(rsh hostname 2>/dev/null)"

  # -- can the remote filesystem hold the metadata --fake-super needs?
  local xa
  xa=$(rsh "d='$REMOTE_DIR'; sudo -n mkdir -p \"\$d\" 2>/dev/null || mkdir -p \"\$d\" 2>/dev/null
            sudo -n chown \$(id -u):\$(id -g) \"\$d\" 2>/dev/null
            t=\$(mktemp -p \"\$d\" 2>/dev/null) || { echo NOWRITE; exit; }
            if setfattr -n user.t -v 1 \"\$t\" 2>/dev/null; then echo XATTR_OK; else echo XATTR_NO; fi
            rm -f \"\$t\"" 2>/dev/null)
  case "$xa" in
    XATTR_OK) ok "$REMOTE_DIR is writable and supports user xattrs (--fake-super will work)" ;;
    XATTR_NO) bad "$REMOTE_DIR cannot store user xattrs -- --fake-super would silently
        lose every file's real owner and mode, and the copy would not restore."
              FAILED=1 ;;
    *)        bad "cannot write to $REMOTE_DIR on the remote"; FAILED=1 ;;
  esac

  # -- remote space and what is already there
  local ravail
  ravail=$(rsh "df -B1 --output=avail '$REMOTE_DIR' 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null)
  [ -n "$ravail" ] && info "remote free: $(gb "$ravail")"

  # wc -l, not `grep -c . || echo 0`: grep exits 1 on no matches, so the fallback
  # fires *in addition to* grep's own "0" and the count becomes the string "0\n0".
  local rn; rn=$(remote_snaps | wc -l)
  if [ "${rn:-0}" -eq 0 ]; then
    info "nothing copied yet -- the first push sends the full tree"
  else
    ok "$rn snapshot(s) already there:"
    remote_snaps | while read -r s; do [ -n "$s" ] && echo "          $s"; done
    # Anything remote-only is either a local prune or a stale copy. Say which.
    local only
    only=$(comm -13 <(local_snaps) <(remote_snaps) 2>/dev/null)
    [ -n "$only" ] && { warn "remote-only (deleted here since, kept there):"
                        printf '          %s\n' $only
                        echo "        'push --mirror' would delete these. Plain 'push' keeps them."; }
  fi
  echo
  return "$FAILED"
}

# ------------------------------------------------------------------------ push

cmd_push() {
  need_root push
  local dry=no mirror=no a
  for a in "$@"; do
    case "$a" in
      --dry-run|-n) dry=yes ;;
      --mirror)     mirror=yes ;;
      '')           ;;
      *)            die "unknown option: $a" ;;
    esac
  done

  [ "$(local_snaps | grep -c .)" -gt 0 ] || die "no local snapshots to copy"
  [ -r "$SSH_KEY" ] || die "cannot read ssh key $SSH_KEY"
  if ! rsh true 2>/dev/null; then
    bad "cannot reach $REMOTE_USER@$REMOTE_HOST"
    why_unreachable
    die "run '$0 status' for the full picture"
  fi

  # A laptop that suspends mid-transfer turns 75 minutes into an unknown state.
  # rsync resumes from --partial-dir, but say so before rather than after.
  local ac; ac=$(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -1)
  if [ "${ac:-1}" = 0 ]; then
    warn "on battery. This is a long transfer -- plug in first."
    echo "        (it resumes from --partial-dir if interrupted, but do not rely on it)"
  fi

  echo
  echo "  measuring the local tree (hardlink-aware; this walks every file)..."
  # -B1, NOT -sb. `du -sb` reports APPARENT size -- the sum of file sizes -- but
  # what the remote has to find is ALLOCATED blocks, and with ~740k small files
  # rounding up to 4K each the two differ by well over 10%. Measured 2026-08-08:
  # 17.7G apparent against 20.03G actually occupied. Checking free space against
  # the apparent number is checking against a figure that is always too small.
  local need; need=$(du -s -B1 --one-file-system "$SNAPDIR" 2>/dev/null | cut -f1)
  local ravail; ravail=$(rsh "df -B1 --output=avail '$REMOTE_DIR' | tail -1 | tr -d ' '")
  echo "  local tree $(gb "${need:-0}"), remote free $(gb "${ravail:-0}")"

  if [ -n "$need" ] && [ -n "$ravail" ]; then
    local floor=$((MIN_REMOTE_FREE_GB * 1024 * 1024 * 1024))
    if [ "$ravail" -lt "$((need + floor))" ]; then
      die "not enough room: needs $(gb "$need") plus ${MIN_REMOTE_FREE_GB}G headroom, has $(gb "$ravail").
       Free space there, or point elsewhere with MBA_OFFSITE_DIR."
    fi
  fi

  build_rsync_cmd
  [ "$mirror" = yes ] && RSYNC_CMD+=(--delete)
  [ "$dry" = yes ]    && RSYNC_CMD+=(--dry-run --itemize-changes) \
                      || RSYNC_CMD+=(--info=progress2 --human-readable)

  echo
  echo "  $( [ "$dry" = yes ] && echo 'DRY RUN -- nothing will be written' || echo 'transferring' )"
  [ "$mirror" = yes ] && echo "  --mirror: remote snapshots absent here WILL be deleted"
  echo "  hardlinks preserved (-H), ownership via --fake-super, resumable"
  echo "  Wi-Fi is a single sustained connection here, so this does not trip the"
  echo "  burst-of-sockets lockup described in WIFI.md."
  echo

  # Over an hour of transfer on a laptop: idle-suspend would drop the ssh and
  # leave a partial tree. systemd-inhibit holds sleep off for exactly this
  # command and releases it when rsync exits -- better than changing a power
  # setting and forgetting to change it back.
  local -a RUN=()
  if command -v systemd-inhibit >/dev/null 2>&1 && [ "$dry" = no ]; then
    RUN=(systemd-inhibit --what=sleep:idle --who="snapshot-offsite.sh"
         --why="copying the snapshot tree to $REMOTE_HOST" --mode=block)
    echo "  suspend inhibited for the duration (lid-close still sleeps: that is"
    echo "  a separate switch, so leave the lid open)."
    echo
  fi

  local t0 t1 rc
  t0=$(date +%s)
  "${RUN[@]}" "${RSYNC_CMD[@]}" "$SNAPDIR/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/"
  rc=$?
  t1=$(date +%s)

  echo
  if [ "$rc" = 0 ]; then
    ok "$( [ "$dry" = yes ] && echo 'dry run complete' || echo 'transfer complete' ) in $(( (t1 - t0) / 60 ))m $(( (t1 - t0) % 60 ))s"
    [ "$dry" = no ] && echo "  Confirm it independently rather than trusting the exit code:  sudo $0 verify"
  else
    bad "rsync exited $rc"
    echo "        Partial data is kept in $REMOTE_DIR/.rsync-partial and the next"
    echo "        push resumes from it. Re-run when the link is back."
  fi
  return "$rc"
}

# ---------------------------------------------------------------------- verify

cmd_verify() {
  need_root verify
  if ! rsh true 2>/dev/null; then bad "cannot reach $REMOTE_USER@$REMOTE_HOST"; why_unreachable; exit 1; fi

  echo
  echo "  comparing both ends. Nothing is transferred."
  echo

  local FAILED=0

  # 1. The same snapshots exist on both sides.
  local missing extra
  missing=$(comm -23 <(local_snaps) <(remote_snaps))
  extra=$(comm -13 <(local_snaps) <(remote_snaps))
  if [ -z "$missing" ]; then ok "every local snapshot is present remotely"
  else bad "not copied yet:"; printf '          %s\n' $missing; FAILED=1; fi
  [ -n "$extra" ] && info "remote-only (pruned here since): $(echo $extra | tr '\n' ' ')"

  # 2. What would still transfer? A dry run is the honest answer -- it compares
  #    every file's size and mtime, not just the directory names.
  echo
  echo "  checking for content differences (dry run over the whole tree)..."
  build_rsync_cmd
  local diffs
  diffs=$("${RSYNC_CMD[@]}" --dry-run --itemize-changes \
          "$SNAPDIR/" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/" 2>/dev/null \
          | grep -cE '^[<>ch.][fdLDS]' )
  if [ "${diffs:-1}" -eq 0 ]; then
    ok "no differences -- the remote copy is current"
  else
    warn "$diffs path(s) would still transfer. Run: sudo $0 push"
    FAILED=1
  fi

  # 3. Did --fake-super actually record ownership? Without this the copy looks
  #    complete and restores as a tree owned by the remote user.
  echo
  local probe
  probe=$(remote_snaps | head -1)
  if [ -n "$probe" ]; then
    local xattr
    xattr=$(rsh "getfattr -n user.rsync.%stat -d '$REMOTE_DIR/$probe/localhost/etc/shadow' 2>/dev/null | grep -c 'user.rsync'" 2>/dev/null)
    if [ "${xattr:-0}" -ge 1 ]; then
      ok "--fake-super metadata present (checked /etc/shadow in $probe)"
    else
      bad "no user.rsync.%stat xattr on a file that must be root-owned."
      echo "        The copy is NOT faithfully restorable. Re-push after confirming"
      echo "        the remote filesystem supports user xattrs: $0 status"
      FAILED=1
    fi
  fi

  echo
  [ "$FAILED" = 0 ] && echo "  OFFSITE COPY IS GOOD." \
                    || echo "  PROBLEMS ABOVE -- do not treat this as disaster recovery yet."
  echo
  return "$FAILED"
}

# ----------------------------------------------------------------------- watch

# A second, readable view of a push running in another terminal.
#
# rsync's --info=progress2 line is genuinely hard to read for this job: its
# percentage counts every hardlink at full size, so a tree that occupies 20G is
# reported against a ~38G total and finishes at "51%". Worse, the percentage goes
# BACKWARDS whenever incremental recursion discovers more of the tree. This
# instead reports what is actually on the remote disk, which only ever goes up.
#
# Read-only, and it never touches the running transfer.
#
# It reads `df`, not `du`. du over this tree means ~1.5M stat calls on the remote
# and took ~40s per sample when first tried -- longer than a sensible poll
# interval, so the watcher spent all its time measuring. df is instant. The
# trade-off is that it measures the whole filesystem, so anything else writing to
# that disk shows up as apparent progress; on a dedicated backup host that is a
# fair price for a number that arrives immediately.
cmd_watch() {
  local interval="${1:-60}"
  case "$interval" in ''|*[!0-9]*) die "watch takes seconds, got '$interval'" ;; esac
  rsh true 2>/dev/null || { bad "cannot reach $REMOTE_USER@$REMOTE_HOST"; why_unreachable; exit 1; }

  echo
  echo "  polling $REMOTE_HOST every ${interval}s. Ctrl-C to stop -- this does not"
  echo "  affect a transfer running elsewhere."
  echo "  Reading df (instant) rather than du (~40s here): it tracks the whole"
  echo "  filesystem, so other writers on that host would also show up."
  echo
  printf '  %-9s %10s %12s %10s\n' TIME USED DELTA RATE
  local prev=0 now delta rate t
  while :; do
    now=$(rsh "df -B1 --output=used '$REMOTE_DIR' 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null)
    t=$(date +%H:%M:%S)
    if [ -z "$now" ]; then
      printf '  %-9s %10s\n' "$t" "unreachable"
    elif [ "$prev" = 0 ]; then
      printf '  %-9s %10s %12s %10s\n' "$t" "$(gb "$now")" "-" "-"
    else
      delta=$((now - prev))
      rate=$(awk -v d="$delta" -v s="$interval" 'BEGIN{printf "%.2fMB/s", d/s/1048576}')
      printf '  %-9s %10s %12s %10s\n' "$t" "$(gb "$now")" "+$(gb "$delta")" "$rate"
    fi
    prev=$now
    sleep "$interval"
  done
}

# ------------------------------------------------------------------- pull-test

# Prove the way BACK works, which is the half a push can never demonstrate.
#
# The claim under test: a remote tree written with --fake-super restores real
# ownership and modes when pulled with --fake-super named on the REMOTE side, and
# silently does not when it is omitted. The second half matters as much as the
# first -- without it, "the pull worked" might only mean "we did not look".
#
# It pulls a handful of probe files rather than 20G, chosen to cover the metadata
# that actually breaks: a non-root group, setuid bits, a plain file, a symlink.
# The ground truth is the LOCAL snapshot, which is the same tree the remote copy
# was made from and is readable here as root.
PROBES=(
  etc/shadow          # root:shadow 640 -- non-root GROUP, missed by naive copies
  etc/gshadow         # same
  usr/bin/sudo        # root:root 4755 -- setuid, the one with security weight
  usr/bin/passwd      # setuid
  usr/bin/wall        # plain 755, the control within the control
  etc/hostname        # plain 644
  usr/bin/X11         # a symlink -- stored remotely as a PLACEHOLDER FILE, below
)

# The symlink probe was expected to fail, on the reasoning that Linux forbids
# user.* xattrs on symlinks so --fake-super would have nowhere to record one. It
# passed, and the reason matters more than the result:
#
#   remote:  regular file, 1 byte, contents "."   owner joe:joe
#   xattr:   user.rsync.%stat = "120777 0,0 0:0"
#                                ^^^^^^ 0120000 is S_IFLNK
#
# rsync does not skip symlinks under --fake-super -- it stores each one as an
# ordinary placeholder file holding the link target, and records the real TYPE in
# the mode field of the xattr. Pulling with --fake-super reads 120777, sees the
# symlink bit and recreates a genuine root-owned symlink. (A plain file carries
# 100644: 0100000 is S_IFREG.) Device and special files are handled the same way.
#
# So the offsite copy is NOT a browsable filesystem, and that is the real trap:
# anything that copies it WITHOUT understanding --fake-super -- cp, tar, scp, or
# an rsync missing the flag -- propagates placeholder files where symlinks and
# devices belong, and every mode and owner flattened, while looking like it
# worked. Treat that tree as an encoded archive, not a directory.

meta_of() { stat -c '%u:%g:%04a' "$1" 2>/dev/null || echo MISSING; }

pull_one() {   # $1 = dest dir, $2 = remote snapshot, $3 = yes|no fake-super
  local dest="$1" snap="$2" fake="$3" list
  mkdir -p "$dest" || return 1
  list=$(mktemp); printf '%s\n' "${PROBES[@]}" > "$list"

  local -a cmd=(rsync -aHAX --numeric-ids --files-from="$list"
                -e "ssh ${SSH_OPTS[*]} -i $SSH_KEY")
  [ "$fake" = yes ] && cmd+=(--rsync-path="rsync --fake-super")

  "${cmd[@]}" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/$snap/localhost/" "$dest/" >/dev/null 2>&1
  local rc=$?
  rm -f "$list"
  return $rc
}

cmd_pull_test() {
  need_root pull-test
  local dir="${1:-/var/tmp/mba-pull-test}"
  rsh true 2>/dev/null || { bad "cannot reach $REMOTE_USER@$REMOTE_HOST"; why_unreachable; exit 1; }

  local snap; snap=$(remote_snaps | tail -1)
  [ -n "$snap" ] || die "no snapshots on the remote -- run: sudo $0 push"
  [ -d "$SNAPDIR/$snap" ] || die "the local copy of $snap is gone, so there is no ground truth to grade against"

  echo
  echo "  pulling probe files from $snap into $dir"
  echo "  ground truth: the local $SNAPDIR/$snap"
  echo

  rm -rf "$dir"; mkdir -p "$dir" || die "cannot create $dir"

  pull_one "$dir/with-fake-super" "$snap" yes || die "the --fake-super pull failed outright"
  pull_one "$dir/without"         "$snap" no  || warn "the control pull failed outright (still informative)"

  local FAILED=0 ctrl_differs=0 p want got_w got_n
  printf '  %-16s %-18s %-18s %s\n' FILE 'SNAPSHOT (truth)' 'PULLED --fake-super' 'PULLED WITHOUT'
  for p in "${PROBES[@]}"; do
    want=$(meta_of "$SNAPDIR/$snap/localhost/$p")
    got_w=$(meta_of "$dir/with-fake-super/$p")
    got_n=$(meta_of "$dir/without/$p")
    printf '  %-16s %-18s %-18s %s\n' "$(basename "$p")" "$want" "$got_w" "$got_n"
    [ "$got_w" = "$want" ] || FAILED=$((FAILED + 1))
    [ "$got_n" = "$want" ] || ctrl_differs=$((ctrl_differs + 1))
  done

  echo
  if [ "$FAILED" = 0 ]; then
    ok "every probe came back with its real owner, group and mode"
  else
    bad "$FAILED probe(s) did NOT come back correctly -- the offsite copy is not"
    echo "        restorable as it stands. Do not rely on it until this is understood."
  fi

  # The control. If pulling WITHOUT --fake-super produced identical metadata, then
  # this test proves nothing -- something else is supplying the ownership and the
  # passing result above is not evidence.
  if [ "$ctrl_differs" -gt 0 ]; then
    ok "control: $ctrl_differs probe(s) came back WRONG without --fake-super,"
    echo "        so the flag is doing the work and this test can actually fail"
  else
    warn "control: omitting --fake-super changed nothing. The result above is"
    echo "        therefore not evidence -- find out what is really supplying"
    echo "        the metadata before trusting it."
    FAILED=$((FAILED + 1))
  fi

  echo
  echo "  probe copies left in $dir for inspection. Remove with:  sudo rm -rf $dir"
  echo
  return "$FAILED"
}

# ---------------------------------------------------------------- restore-help

cmd_restore_help() {
  cat <<EOF

  GETTING IT BACK -- read before you need it.

  This copy answers one question: sda died, how do I get the system back? It is
  NOT the tool for a bad update -- that is ./apt-rollback.sh or a local snapshot.

  1. Install the same distro on the new disk, and timeshift:

         sudo apt install timeshift

  2. Pull the tree back. THE TRAP IS HERE. --fake-super has to be named on the
     REMOTE side, because that is where the real ownership is parked in xattrs.
     Leave it out and rsync happily gives you a tree owned by your user with
     every mode wrong, which looks like it worked:

         sudo rsync -aHAX --numeric-ids \\
              --rsync-path="rsync --fake-super" \\
              -e "ssh -i $SSH_KEY" \\
              $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR/ /timeshift/snapshots/

     Run it as root locally, or the ownership it just recovered cannot be applied.

  3. Point timeshift at the local disk and let it see them:

         sudo ./system-snapshot.sh configure
         ./system-snapshot.sh list

  4. Restore as usual, and read ./system-snapshot.sh restore-help first --
     --skip-grub on EFI, and the wl/DKMS trap that decides whether you come back
     with a network.

  THE COPY IS AN ENCODED ARCHIVE, NOT A BROWSABLE FILESYSTEM.

  Under --fake-super every file on the remote is owned by the remote account with
  its real owner, group, mode AND TYPE parked in a user.rsync.%stat xattr.
  Symlinks, devices and special files are stored as ordinary placeholder files;
  /usr/bin/X11 is a 1-byte regular file there containing ".", tagged 120777.

  So anything that copies that tree WITHOUT understanding --fake-super -- cp,
  tar, scp, or an rsync missing the flag -- silently produces placeholder files
  where symlinks belong, every mode flattened and everything owned by one user.
  It looks like it worked. Only rsync, with --fake-super naming the side that
  holds the xattrs, reads it correctly.

  Proven on 2026-08-09 with '$0 pull-test': 7 of 7 probes came back with their
  real owner, group and mode -- including setuid 4755 on sudo and passwd, the
  non-root group on /etc/shadow, and the symlink. The control, pulling the same
  files without --fake-super, got all 7 wrong: everything owned 1000:1000 and
  BOTH SETUID BITS GONE. A system recovered that way boots and cannot escalate.

  Re-run pull-test any time; it copies seven files, not 20G.

EOF
}

case "${1:-status}" in
  status)              cmd_status ;;
  push)                shift; cmd_push "$@" ;;
  verify)              cmd_verify ;;
  watch)               cmd_watch "${2:-60}" ;;
  pull-test)           cmd_pull_test "${2:-}" ;;
  restore-help|help)   cmd_restore_help ;;
  *)                   usage ;;
esac
