#!/bin/bash
# Take a LOCAL "last known good" system snapshot, on demand, before a risky change.
#
# WHY THIS EXISTS
#
# apt-rollback.sh covers the revertible case: a named transaction changed known
# packages, put them back. This covers the other case -- "something broke and I
# do not know what changed", or the damage is outside dpkg entirely. That is the
# one job a filesystem snapshot does better than anything else.
#
# WHY IT INSISTS THE TARGET IS LOCAL
#
# This laptop has no ethernet port. Wi-Fi is the only interface and it depends on
# `wl` from broadcom-sta, a proprietary DKMS module that has already failed a
# kernel transition once (see WIFI.md). So the most likely bad update is one that
# costs you the network -- and a snapshot stored on another host is unreachable
# at exactly the moment you need it. Booting a live USB does not rescue you
# either: the live session needs that same driver to reach the network.
#
# Hence: this script REFUSES to create a snapshot on a network filesystem, and
# refuses on any filesystem that cannot hardlink (without hardlinks every
# snapshot is a full 18G copy instead of a ~1G incremental). Remote storage is
# right for disaster recovery -- disk dies, laptop stolen -- which is a different
# job. Local for rollback, remote for disk death. See SNAPSHOTS.md.
#
# WHY ON DEMAND AND NOT SCHEDULED
#
# 4GB of RAM and a spinning-rust-era budget for background work. A scheduled
# snapshot is disk churn you did not ask for, at a time you did not pick. An
# on-demand snapshot exists exactly when you meant it to, which is also when it
# is worth having. `configure` therefore turns every schedule OFF and keeps them
# off, and `status` complains if something turns them back on.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It never restores. Restoring is rare, destructive, and worth reading the screen
# for -- `restore-help` prints the procedure and the two things specific to this
# machine (EFI boot, and the driver you need afterwards) instead of doing it.

set -uo pipefail

CONF=/etc/timeshift/timeshift.json
SNAPDIR=/timeshift/snapshots
KEEP_DEFAULT=3

# Leave this much free AFTER a snapshot. A full disk on the machine you are
# trying to rescue is its own emergency.
MIN_FREE_AFTER_GB=12

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "  WARN  $*"; }
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; }

need_root() {
  [ "$(id -u)" = 0 ] || die "$1 needs root. Try: sudo $0 $*"
}

usage() {
  cat <<EOF
usage: $0 status              what is configured now, and whether it is sane
       $0 configure           make the config match SNAPSHOTS.md (root)
       $0 create ["reason"]   take one on-demand snapshot (root)
       $0 list                snapshots present (instant)
       $0 list --sizes        ... with hardlink-aware sizes (slow: walks every file)
       $0 prune [N]           keep the newest N, delete the rest (root, default $KEEP_DEFAULT)
       $0 check-esp [SNAP]    what a restore would do to the EFI partition (root)
       $0 restore-help        how to actually restore, and the local gotchas

Snapshots are local, system-only, on demand. Nothing here is scheduled.
Try ./apt-rollback.sh first when you know which update broke it -- this is for
when you do not.
EOF
  exit 1
}

# ---------------------------------------------------------------- config reads

# timeshift.json is plain JSON and python3 is present on this machine; jq is not.
jget() {
  python3 - "$CONF" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f: c = json.load(f)
except Exception:
    sys.exit(1)
v = c.get(sys.argv[2], "")
if isinstance(v, list): print("\n".join(str(x) for x in v))
else: print(v)
PY
}

# UUID -> /dev/... without needing root (blkid does; /dev/disk/by-uuid does not).
dev_for_uuid() {
  local u="$1" p
  [ -n "$u" ] || return 1
  p=/dev/disk/by-uuid/"$u"
  [ -e "$p" ] || return 1
  readlink -f "$p"
}

gb() { # bytes -> "12.3G"
  awk -v b="$1" 'BEGIN { printf "%.1fG", b/1024/1024/1024 }'
}

snap_names() { ls -1 "$SNAPDIR" 2>/dev/null | sort; }

# The reason you typed at `create`, back out of the snapshot's own control file.
snap_comment() {
  sed -n 's/.*"comments"[^:]*:[ ]*"\(.*\)".*/\1/p' "$SNAPDIR/$1/info.json" 2>/dev/null | head -1
}

# ------------------------------------------------------------------ the checks
#
# Returns 0 if a snapshot is safe to take, 1 if not. Prints a line per check
# either way, because "why did it refuse" should never need a second command.

FAILED=0

# Is the configured target local, and can it hardlink?
#
# The obvious version of this check -- "is /timeshift on ext4?" -- is wrong, and
# wrong in the direction that matters. Timeshift only writes to /timeshift when
# the backup device IS the root device; point it at any other device and it
# mounts that under /run at runtime instead, so /timeshift then describes a
# filesystem the snapshots never touch. The check would print "ok, local ext4"
# while rsync wrote to an NFS server. This script exists to prevent precisely
# that, so the check follows the config, not a hardcoded path.
check_target() {
  local uuid root_uuid dev base tran fstype src where local_ok=0
  uuid=$(jget backup_device_uuid)
  root_uuid=$(findmnt -no UUID / 2>/dev/null)

  if [ -z "$uuid" ]; then
    bad "no backup_device_uuid set -- run: sudo $0 configure"
    FAILED=1
    return
  fi

  dev=$(dev_for_uuid "$uuid")
  if [ -z "$dev" ]; then
    bad "backup_device_uuid ${uuid:0:8}... is not attached right now."
    echo "        Nothing local to write to. If that UUID lives on a drive you"
    echo "        plug in, plug it in; if it was a network target, read"
    echo "        SNAPSHOTS.md before setting it again."
    FAILED=1
    return
  fi

  if [ "$uuid" = "$root_uuid" ]; then
    # Snapshots land in /timeshift on the root filesystem. Still worth a mount
    # lookup: someone could have mounted something else at that path.
    where="$SNAPDIR"
    fstype=$(findmnt -no FSTYPE -T "$(dirname "$SNAPDIR")" 2>/dev/null)
    src=$(findmnt -no SOURCE -T "$(dirname "$SNAPDIR")" 2>/dev/null)
  else
    # A separate local disk is arguably better than root -- say so, but the
    # filesystem type has to come from the device, not from a path that is not
    # mounted yet.
    where="$dev (mounted by timeshift at run time)"
    fstype=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1 | tr -d ' ')
    src="$dev"
  fi

  case "$fstype" in
    nfs|nfs4|cifs|smb3|smbfs|fuse.sshfs|fuse.rclone|9p|afs|glusterfs|ceph)
      bad "target is a NETWORK filesystem ($fstype from $src)."
      echo "        This is the configuration that fails in the one scenario it"
      echo "        was set up for -- Wi-Fi is the only interface on this"
      echo "        machine. Read the top of this script, and SNAPSHOTS.md."
      FAILED=1 ;;
    vfat|exfat|ntfs|ntfs3|msdos)
      bad "target is $fstype, which has no hardlinks."
      echo "        Every snapshot would be a full ~18G copy instead of a ~1G"
      echo "        delta. This is why win7810 (SMB/CIFS) is disqualified."
      FAILED=1 ;;
    ext2|ext3|ext4|xfs|btrfs|f2fs|zfs)
      ok "target $where -- $fstype, hardlinks work"; local_ok=1 ;;
    "")
      bad "cannot determine the filesystem of $src"
      FAILED=1 ;;
    *)
      warn "target is $fstype -- unrecognised; confirm it supports hardlinks" ;;
  esac

  # A block device is not the same thing as a local one. iSCSI and NBD hand you
  # a /dev node with a real UUID, which passes every check above and still
  # disappears the moment Wi-Fi does. TRAN is empty on partitions, so ask the
  # parent disk.
  base=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1 | tr -d ' ')
  [ -n "$base" ] && tran=$(lsblk -no TRAN "/dev/$base" 2>/dev/null | head -1 | tr -d ' ') \
                 || tran=$(lsblk -no TRAN "$dev" 2>/dev/null | head -1 | tr -d ' ')
  case "$dev:$tran" in
    /dev/nbd*:*|*:iscsi|*:fcoe|*:srp)
      bad "target is a REMOTE block device (${tran:-nbd}) -- local-looking, but"
      echo "        it is gone as soon as the network is. That is the failure"
      echo "        mode this script refuses. See SNAPSHOTS.md."
      FAILED=1 ;;
    *:usb)
      warn "target is USB -- fine, but it has to be plugged in to restore." ;;
  esac

  # Same disk as root: not a failure, but it bounds what this protects against,
  # so it gets said out loud every time rather than buried in a doc. Suppressed
  # when the target already failed -- a refusal should not be followed by advice
  # about a snapshot that is not going to happen.
  if [ "$uuid" = "$root_uuid" ] && [ "$local_ok" = 1 ]; then
    warn "snapshots live on the same disk as / -- rollback insurance, NOT"
    echo "        disaster recovery. A dead sda takes both. The offsite copy to"
    echo "        iteration8 is a separate job (SNAPSHOTS.md step 3)."
  fi
}

check_all() {
  local mode="${1:-report}"   # report | strict
  FAILED=0

  [ -r "$CONF" ] || die "cannot read $CONF -- is timeshift installed?"

  # -- rsync mode. btrfs mode has different space behaviour and this machine is ext4.
  if [ "$(jget btrfs_mode)" = "false" ]; then
    ok "rsync mode (btrfs mode off) -- hardlinked incrementals"
  else
    bad "btrfs_mode is on, but / is $(findmnt -no FSTYPE /). Fix the config."
    FAILED=1
  fi

  # -- the target, and whether it is genuinely local
  check_target

  # -- exclusions. /home dwarfs the system side (27G vs 18G on the machine this
  # was written for) and reinstallable flatpaks are another 1.8G.
  #
  # The pattern is /home/*/** rather than one named user: this is a system-only
  # snapshot on any machine, not just a single-user one, and a config naming one
  # user silently includes everybody else's home in the snapshot.
  local ex; ex=$(jget exclude)
  if echo "$ex" | grep -qx '/home/\*/\*\*'; then
    ok "/home/*/ excluded (system-only snapshot)"
  else
    # Accept an older per-user config, but only if every home that actually
    # exists is named. One unlisted user is a silently much larger snapshot.
    local missing="" covered="" h u
    for h in /home/*/; do
      [ -d "$h" ] || continue          # no match: the glob stays literal
      u=$(basename "$h")
      if echo "$ex" | grep -qx "/home/$u/\*\*"; then
        covered="${covered:+$covered, }$u"
      else
        missing="$missing $u"
      fi
    done
    if [ -z "$missing" ] && [ -z "$covered" ]; then
      warn "/home/*/** not excluded, but /home has no user directories."
      echo "        Harmless now; it would not stay that way. Run: sudo $0 configure"
    elif [ -z "$missing" ]; then
      ok "every /home user excluded ($covered) -- consider /home/*/** instead"
    else
      bad "/home not excluded for:$missing -- adds all of their data. Run: sudo $0 configure"
      FAILED=1
    fi
  fi
  if echo "$ex" | grep -q '^/var/lib/flatpak/\*\*$'; then
    ok "/var/lib/flatpak excluded (~1.8G, flatpaks reinstall trivially)"
  else
    warn "/var/lib/flatpak not excluded -- ~1.8G of avoidable snapshot."
    echo "        Run: sudo $0 configure"
  fi

  # -- schedules. Any of these on means background disk churn on a 4GB machine.
  local s on=""
  for s in hourly daily weekly monthly boot; do
    [ "$(jget "schedule_$s")" = "true" ] && on="$on $s"
  done
  if [ -z "$on" ]; then
    ok "no schedules enabled (on demand only)"
  else
    warn "schedules enabled:$on -- something re-enabled these."
    echo "        Run: sudo $0 configure"
  fi

  # -- space
  local free_b n
  free_b=$(df -B1 --output=avail "$(dirname "$SNAPDIR")" 2>/dev/null | tail -1 | tr -d ' ')
  n=$(snap_names | wc -l)
  echo "  --    $n snapshot(s) present, $(gb "${free_b:-0}") free"

  [ "$mode" = strict ] && return "$FAILED"
  return 0
}

# What the first snapshot will actually cost, measured rather than guessed.
#
# This has to mirror what timeshift itself skips, or the number is wrong in a way
# that matters. `du -sx /` on this machine reads 22.3G, but 3.87G of that is
# /swapfile -- active swap at priority -1, behind zram, and on timeshift's own
# built-in exclusion list (confirmed: `strings /usr/bin/timeshift | grep swap`).
# Counting it turns an 18.0G snapshot into a 22.3G one and could refuse a
# snapshot that fits fine. -x drops /proc, /sys, /dev and /run for free, since
# those are separate filesystems; the rest are listed because they are not.
TIMESHIFT_BUILTIN=(
  /swapfile /snap /lost+found /timeshift /timeshift-btrfs
  /var/cache/apt/archives /var/tmp /var/lib/schroot /cdrom /tmp /media /mnt
)
estimate_full_b() {
  local args=(-sxB1) p
  for p in "${TIMESHIFT_BUILTIN[@]}"; do args+=("--exclude=$p"); done
  while read -r p; do
    [ -z "$p" ] && continue
    args+=("--exclude=${p%/\*\*}")
  done < <(jget exclude)
  du "${args[@]}" / 2>/dev/null | cut -f1
}

# ---------------------------------------------------------------- subcommands

cmd_status() {
  echo
  echo "  timeshift $(dpkg-query -W -f='${Version}' timeshift 2>/dev/null || echo '(not installed)')"
  echo
  check_all report
  echo

  # Offer the measurement rather than just claiming root could get it. du needs
  # root to read everything under /usr and /var; as a normal user it silently
  # skips what it cannot open and undercounts -- the wrong direction for a space
  # check, since it would talk you into a snapshot that does not fit.
  if [ "$(snap_names | wc -l)" = 0 ]; then
    if [ "$(id -u)" = 0 ]; then
      echo "  measuring the first snapshot..."
      local b; b=$(estimate_full_b)
      [ -n "$b" ] && echo "  first snapshot would be ≈$(gb "$b")" \
                  || echo "  (could not measure)"
    else
      echo "  (run as root for a measured first-snapshot size)"
    fi
    echo
  fi
}

cmd_configure() {
  need_root configure

  local root_uuid
  root_uuid=$(findmnt -no UUID / 2>/dev/null)
  [ -n "$root_uuid" ] || die "cannot determine the UUID of /"

  cp -a "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)" || die "could not back up $CONF"

  python3 - "$CONF" "$root_uuid" <<'PY' || die "could not rewrite $CONF"
import json, re, sys
path, root_uuid = sys.argv[1], sys.argv[2]
with open(path) as f: c = json.load(f)

c["backup_device_uuid"] = root_uuid   # local root. Never a network target.
c["btrfs_mode"] = "false"             # ext4 here; rsync mode hardlinks
c["do_first_run"] = "false"
c["stop_cron_emails"] = "true"
for s in ("hourly", "daily", "weekly", "monthly", "boot"):
    c["schedule_" + s] = "false"      # on demand only -- 4GB machine

# /home/*/** covers every user, present and future -- naming one user means the
# next account added to the machine lands in the snapshot without anyone noticing.
want = ["/home/*/**", "/root/**", "/var/lib/flatpak/**"]
# Drop any per-user home entry a previous version wrote; the wildcard supersedes
# it, and leaving both makes the exclude list look like it disagrees with itself.
stale = re.compile(r"^/home/[^/*]+/\*\*$")
ex = [e for e in c.get("exclude", []) if e not in want and not stale.match(e)]
c["exclude"] = want + ex

with open(path, "w") as f:
    json.dump(c, f, indent=2)
    f.write("\n")
PY

  echo
  echo "  config written (previous copy kept as $CONF.bak.*)"
  echo
  check_all report
  echo
  echo "  Next: sudo $0 create \"before <whatever you are about to do>\""
  echo
}

cmd_create() {
  need_root create
  local reason="${1:-manual snapshot}"

  echo
  check_all strict
  local st=$?
  echo
  [ "$st" = 0 ] || die "preflight failed -- see FAIL lines above. Nothing was created."

  local free_b n need_b
  free_b=$(df -B1 --output=avail "$(dirname "$SNAPDIR")" | tail -1 | tr -d ' ')
  n=$(snap_names | wc -l)

  local first=0
  if [ "$n" = 0 ]; then
    first=1
    echo "  measuring what the first snapshot will copy..."
    need_b=$(estimate_full_b)
    [ -n "$need_b" ] || die "could not estimate the snapshot size"
    echo "  first snapshot ≈ $(gb "$need_b") (later ones are ~0.5-2G, hardlinked)"
  else
    # Deltas are small but a big apt upgrade can be 1-3G. Ask for headroom, not
    # a full copy -- demanding 18G again is how you talk yourself out of the
    # snapshot you actually wanted.
    need_b=$((3 * 1024 * 1024 * 1024))
    echo "  incremental snapshot -- budgeting $(gb "$need_b") of delta"
  fi

  local after_b min_b
  after_b=$((free_b - need_b))
  min_b=$((MIN_FREE_AFTER_GB * 1024 * 1024 * 1024))
  if [ "$after_b" -lt "$min_b" ]; then
    echo
    bad "not enough room: $(gb "$free_b") free, need $(gb "$need_b") and want"
    echo "        $(gb "$min_b") left over. Free some space, or prune:"
    echo "          sudo $0 prune 1"
    exit 1
  fi
  echo "  $(gb "$free_b") free now, ≈$(gb "$after_b") after"

  # Warn before the wait, not after it. Timeshift shows progress by counting
  # rsync's itemized output against the PREVIOUS snapshot's file_count -- the rsync
  # command it builds has no --info=progress2 -- so a first snapshot has no
  # denominator and sits at "0.00% complete (??? remaining)" from start to finish.
  # Incrementals count fine. Without this note the natural conclusion is that it
  # has hung, and killing it half-written is the worst available outcome.
  if [ "$first" = 1 ]; then
    echo
    echo "  NOTE the progress line will read '0.00% complete (??? remaining)' for"
    echo "       this entire run and never move. That is expected on a FIRST"
    echo "       snapshot -- there is no parent snapshot to measure against yet."
    echo "       It is not stuck. Watch it from another terminal with:  df -h /"
    echo "       Free space should fall toward $(gb "$after_b")."
  fi
  echo

  timeshift --create --rsync --tags O --comments "$reason" --yes
  local rc=$?
  echo
  if [ "$rc" != 0 ]; then
    die "timeshift --create exited $rc. Nothing to trust here; read its output."
  fi

  # Let timeshift's orphaned wrapper script finish writing to stderr before we
  # print anything. It is not our child, so there is nothing to wait on -- and
  # left to itself its stray "status: No such file or directory" line lands in the
  # middle of the table below, which reads as though the listing broke. Two
  # seconds after a multi-minute snapshot costs nothing and keeps the output in a
  # sane order. Deliberately NOT filtered out: a rescue tool should not teach
  # itself to swallow stderr from the thing it is wrapping.
  sleep 2

  verify_newest "$reason"

  echo "  Snapshots now:"
  cmd_list
  echo "  Restoring is not automatic on purpose: $0 restore-help"
  echo
}

# Prove the snapshot is real, rather than trusting an exit code.
#
# This exists because timeshift prints a stray line of its own after finishing:
#
#   /tmp/timeshift-XXXXXXXX/NNNNNNNNNN: line 10: status: No such file or directory
#
# That is timeshift's async-task plumbing racing its own cleanup, not a failed
# snapshot. It runs commands through a generated wrapper script in a per-run temp
# dir and captures the result with `echo ${exitCode} > status` -- a RELATIVE
# redirect (visible with `strings /usr/bin/timeshift | grep 'exitCode'`). When the
# parent has already deleted that temp dir, the wrapper's cwd is gone and the
# write fails. Harmless, cosmetic, and nothing to do with this script.
#
# But "that error was probably fine" is not a sentence a rollback tool should
# leave you with, so check the artefacts instead: the control file timeshift
# writes last, the tag, and a non-empty tree.
verify_newest() {
  local want="$1" newest base info count tags
  newest=$(snap_names | tail -1)
  if [ -z "$newest" ]; then
    die "timeshift reported success but no snapshot directory exists."
  fi
  base="$SNAPDIR/$newest"
  info="$base/info.json"

  # info.json is written LAST, after rsync and after tagging, so its presence is
  # the real completion marker.
  [ -s "$info" ] || die "no info.json in $newest -- the snapshot is incomplete."

  count=$(sed -n 's/.*"file_count"[^:]*:[ ]*"\([0-9]*\)".*/\1/p' "$info" | head -1)
  tags=$(sed -n 's/.*"tags"[^:]*:[ ]*"\([^"]*\)".*/\1/p' "$info" | head -1)
  [ -d "$base/localhost" ] || die "no localhost/ tree in $newest -- nothing was copied."
  [ "${count:-0}" -gt 1000 ] 2>/dev/null \
    || die "$newest claims only ${count:-0} files -- that is not a system snapshot."

  ok "verified $newest -- ${count} files, tagged '${tags:-none}'"
  if ! grep -qF "\"comments\" : \"$want\"" "$info" 2>/dev/null; then
    warn "the comment in info.json is not \"$want\" -- check $info"
  fi
  echo "        (if timeshift printed a stray \"status: No such file or"
  echo "        directory\" line above, that is its bug, not a bad snapshot --"
  echo "        the check just done is what actually settles it.)"
  echo
}

# Fast listing -- no du, so it is instant regardless of how many snapshots exist.
#
# This is the default because the sizes are NOT cheap. Measuring hardlink-aware
# sizes means one du across every snapshot; at 7 snapshots of ~742k files each
# that is ~5.2M stat calls and took 1m57s (11s user, 54s sys, rest I/O). `create`
# used to call the sizing version, so every snapshot ended with a growing stall
# after the work was already finished. Sizes are now opt-in via `list --sizes`.
#
# file_count comes from info.json, which timeshift already wrote -- free to read.
cmd_list() {
  [ "${1:-}" = "--sizes" ] && { cmd_list_sizes; return $?; }

  local n names s count
  names=$(snap_names)
  n=$(echo "$names" | grep -c . )
  echo
  if [ "$n" = 0 ]; then
    echo "  no snapshots. sudo $0 create \"reason\""
    echo
    return 0
  fi

  printf '  %-22s %-10s %s\n' "NAME" "FILES" "REASON"
  while read -r s; do
    [ -z "$s" ] && continue
    count=$(sed -n 's/.*"file_count"[^:]*:[ ]*"\([0-9]*\)".*/\1/p' "$SNAPDIR/$s/info.json" 2>/dev/null | head -1)
    printf '  %-22s %-10s %s\n' "$s" "${count:-?}" "$(snap_comment "$s")"
  done <<< "$names"

  echo
  echo "  $n snapshot(s), $(gb "$(df -B1 --output=avail "$(dirname "$SNAPDIR")" | tail -1 | tr -d ' ')") free"
  echo
  echo "  Sizes are omitted on purpose: measuring them walks every file in every"
  echo "  snapshot ($(awk -v n="$n" 'BEGIN{printf "~%.1fM", n*0.742}') stat calls here) and takes minutes."
  echo "  Use '$0 list --sizes' when you actually want them."
  echo
}

cmd_list_sizes() {
  local n names
  names=$(snap_names)
  n=$(echo "$names" | grep -c . )
  echo
  if [ "$n" = 0 ]; then
    echo "  no snapshots. sudo $0 create \"reason\""
    echo
    return 0
  fi
  # Measured: 1m57s for 7 snapshots of ~742k files, so ~17s per snapshot. Printed
  # as an estimate because a two-minute silence with no explanation is exactly what
  # made this look like a hang in the first place.
  echo "  measuring $n snapshot(s) -- one du across every file in each."
  echo "  Expect roughly $(awk -v n="$n" 'BEGIN{printf "%.0f", n*17}')s. Ctrl-C is safe; this only reads."
  echo
  # ONE du over every snapshot, oldest first, because that is the only way to get
  # honest numbers out of a hardlinked tree.
  #
  # The obvious version -- du per snapshot, in its own invocation -- reported "18G"
  # for each of two snapshots that together occupy 18G of disk. Every invocation
  # counts the same shared inodes again, so the column added up to double the real
  # usage and made an incremental look like a full copy. (The giveaway: taking the
  # second snapshot moved free space by 0.)
  #
  # In a single invocation du counts each inode once and attributes it to the first
  # path that referenced it. Oldest first therefore reads as: the baseline, then
  # what each later snapshot genuinely added. That is order-dependent by nature --
  # delete the oldest and its shared data is simply re-attributed to the next one,
  # so no space is freed by deleting it. Said plainly below, because it is exactly
  # the thing people get wrong when pruning to reclaim disk.
  local -a paths=()
  local s
  while read -r s; do [ -n "$s" ] && paths+=("$SNAPDIR/$s"); done <<< "$names"

  local out total=""
  out=$(du -shxc "${paths[@]}" 2>/dev/null)

  printf '  %-22s %-9s %s\n' "NAME" "ADDS" "REASON"
  local size path nm
  while read -r size path; do
    [ -z "$size" ] && continue
    if [ "$path" = "total" ]; then total="$size"; continue; fi
    nm=$(basename "$path")
    printf '  %-22s %-9s %s\n' "$nm" "$size" "$(snap_comment "$nm")"
  done <<< "$out"

  echo
  echo "  $n snapshot(s), ${total:-?} on disk in total, $(gb "$(df -B1 --output=avail "$(dirname "$SNAPDIR")" | tail -1 | tr -d ' ')") free"
  echo
  echo "  ADDS is what each snapshot costs ON TOP of the older ones -- unchanged"
  echo "  files are hardlinks, counted once. So deleting the oldest frees little or"
  echo "  nothing: its shared data just gets attributed to the next one. Only the"
  echo "  total above is real disk usage."
  [ "$(id -u)" = 0 ] || echo "  (as a normal user du cannot walk every directory, so these undercount)"
  echo
}

cmd_prune() {
  need_root prune
  local keep="${1:-$KEEP_DEFAULT}"
  case "$keep" in ''|*[!0-9]*) die "prune takes a number, got '$keep'" ;; esac

  # 'prune 0' parses fine and means "delete every snapshot" -- a rollback tool
  # should not wipe out the only thing it exists to provide because of one keystroke
  # next to '1'. Refuse it and name the explicit command instead.
  if [ "$keep" -eq 0 ]; then
    die "prune 0 would delete EVERY snapshot, leaving nothing to roll back to.
       If that is really what you want:  sudo timeshift --delete-all"
  fi

  local names total doomed ans
  names=$(snap_names)
  total=$(echo "$names" | grep -c .)
  if [ "$total" -le "$keep" ]; then
    echo "  $total snapshot(s), keeping $keep -- nothing to delete."
    return 0
  fi
  doomed=$(echo "$names" | head -n "$((total - keep))")

  # Show the reasons, and show what SURVIVES as well as what goes. A column of bare
  # timestamps gives you nothing to judge by at a prompt that deletes things -- and
  # the question actually worth answering here is "is the one I am keeping the right
  # one?", which a list of the doomed cannot answer.
  local kept
  kept=$(echo "$names" | tail -n "$keep")

  echo
  echo "  KEEPING (newest $keep):"
  while read -r s; do
    [ -n "$s" ] && printf '    %-22s %s\n' "$s" "$(snap_comment "$s")"
  done <<< "$kept"
  echo
  echo "  DELETING $((total - keep)):"
  while read -r s; do
    [ -n "$s" ] && printf '    %-22s %s\n' "$s" "$(snap_comment "$s")"
  done <<< "$doomed"
  echo
  # Manage expectations before the confirmation, not after. A file is only freed
  # when the LAST snapshot referencing it goes, so deleting the oldest of several
  # near-identical snapshots typically returns almost nothing. If disk space is the
  # actual goal, deleting all of them is the honest answer.
  local free_before
  free_before=$(df -B1 --output=avail "$(dirname "$SNAPDIR")" | tail -1 | tr -d ' ')
  echo "  Do not expect much space back: hardlinked data is only freed when the"
  echo "  last snapshot referencing it is deleted. $(gb "$free_before") free now;"
  echo "  it will be reported again afterwards so you can see the real difference."
  echo
  # ${ans:-} because read leaves it unset on EOF, and `set -u` would then abort
  # here rather than take the safe default -- which on a delete prompt matters.
  read -r -p "  Proceed? [y/N] " ans || true
  case "${ans:-}" in [yY]*) ;; *) echo "  aborted. Nothing deleted."; return 0 ;; esac

  local s
  while read -r s; do
    [ -z "$s" ] && continue
    timeshift --delete --snapshot "$s" --yes || warn "could not delete $s"
  done <<< "$doomed"

  sleep 2   # same orphaned-stderr race as create; keep the listing readable

  local free_after
  free_after=$(df -B1 --output=avail "$(dirname "$SNAPDIR")" | tail -1 | tr -d ' ')
  echo
  echo "  freed $(gb "$((free_after - free_before))") -- $(gb "$free_before") before, $(gb "$free_after") after"
  cmd_list
}

# The ESP is in scope for a restore, and that is not obvious.
#
# Timeshift's restore is `rsync -avir --force --delete --delete-before` with no
# -x, and neither its snapshot exclude list nor its restore exclude list mentions
# /boot/efi. So the restore crosses the filesystem boundary into the vfat ESP and
# --delete applies there too. `--skip-grub` does NOT change this: it only
# suppresses grub-install, not the rsync.
#
# Measured 2026-08-08 on this machine: the snapshot's ESP copy was complete and
# byte-identical to the live one (8 files, 6,394,698 bytes), so the restore was a
# same-for-same rewrite. Reverting grubx64.efi alongside /boot/grub is also the
# *consistent* outcome -- an EFI binary that does not match its modules is a
# classic no-boot. So this is sound rather than alarming.
#
# What is worth checking before a restore is the case that is not same-for-same:
# a snapshot older than a grub-efi/shim-signed update, or a firmware capsule
# staged in the ESP by fwupd that --delete would silently discard.
cmd_check_esp() {
  need_root check-esp

  local snap="${1:-}"
  [ -n "$snap" ] || snap=$(snap_names | tail -1)
  [ -n "$snap" ] || die "no snapshots present"
  [ -d "$SNAPDIR/$snap" ] || die "no such snapshot: $snap"

  local esp; esp=$(findmnt -no TARGET /boot/efi 2>/dev/null)
  if [ -z "$esp" ]; then
    echo
    ok "no EFI system partition mounted -- nothing here applies to this machine"
    echo
    return 0
  fi

  local s="$SNAPDIR/$snap/localhost$esp"
  echo
  echo "  snapshot: $snap"
  echo "  ESP:      $esp  ($(findmnt -no SOURCE,FSTYPE "$esp"))"
  echo

  if [ ! -d "$s" ]; then
    bad "the snapshot has no $esp -- a restore would DELETE the whole ESP."
    echo "        Back it up first (it is small):"
    echo "          sudo tar czf \$HOME/esp-backup-\$(date +%F).tgz -C $esp ."
    echo
    return 1
  fi

  local live_list snap_list gone added
  live_list=$(mktemp); snap_list=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$live_list' '$snap_list'" RETURN

  find "$esp" -type f -printf '%P\n' 2>/dev/null | sort > "$live_list"
  find "$s"   -type f -printf '%P\n' 2>/dev/null | sort > "$snap_list"

  gone=$(comm -23 "$live_list" "$snap_list")
  added=$(comm -13 "$live_list" "$snap_list")

  echo "  $(wc -l < "$live_list") files live, $(wc -l < "$snap_list") in the snapshot"
  echo

  local rc=0
  if [ -n "$gone" ]; then
    bad "a restore would DELETE these (present live, absent from the snapshot):"
    printf '          %s\n' $gone
    rc=1
  fi
  if [ -n "$added" ]; then
    warn "a restore would put these back (in the snapshot, absent live):"
    printf '          %s\n' $added
  fi

  # Content, not just names -- same filename with different bytes is the grub
  # version-skew case, and it is the one that decides whether you can boot.
  local f differs=0
  while IFS= read -r f; do
    [ -f "$s/$f" ] || continue
    cmp -s "$esp/$f" "$s/$f" || { differs=$((differs + 1)); echo "          differs: $f"; }
  done < "$live_list"

  if [ "$differs" = 0 ] && [ -z "$gone" ] && [ -z "$added" ]; then
    ok "identical both sides -- a restore is a same-for-same rewrite of the ESP"
  elif [ "$differs" != 0 ]; then
    warn "$differs file(s) differ -- the restore will revert the bootloader too."
    echo "        Usually correct (it keeps grub's binary and modules in step),"
    echo "        but back the ESP up first; it is only a few MB:"
    echo "          sudo tar czf \$HOME/esp-backup-\$(date +%F).tgz -C $esp ."
  fi

  # fwupd stages firmware capsules in the ESP. --delete discards them silently,
  # which cancels a pending firmware update without saying so.
  local staged; staged=$(find "$esp" \( -ipath '*fw*' -o -iname '*.cap' \) 2>/dev/null)
  if [ -n "$staged" ]; then
    warn "fwupd appears to have staged firmware in the ESP:"
    printf '          %s\n' $staged
    echo "        A restore would discard it. Let the firmware update finish first."
  fi
  echo
  return $rc
}

cmd_restore_help() {
  cat <<EOF

  RESTORING -- read this before you need it, not during.

  This path is TESTED. On 2026-08-08 restore-test.sh planted markers, they were
  broken, a snapshot was restored, and all six checks passed after the reboot --
  including the unchanged control, so it was a real restore and not a no-op that
  grades clean. What follows is what that run actually showed.

  Three things about this machine change the procedure:

  1. It boots EFI (/dev/sda1 vfat at /boot/efi). Timeshift will offer to
     reinstall GRUB; on EFI you normally do NOT want it touching the
     bootloader. Use --skip-grub unless GRUB is the thing that is broken.

     --skip-grub does NOT keep the restore out of the ESP. It only suppresses
     grub-install; the rsync still crosses into /boot/efi with --delete, which
     is excluded by neither exclude list. That is usually right -- it keeps
     grub's EFI binary in step with its modules -- but check it first:

         sudo $0 check-esp '<NAME>'

  2. Wi-Fi is the only network interface, and it needs \`wl\` from
     broadcom-sta. If you restore to a state whose DKMS module does not match
     the kernel you boot, you come back with no network. Check kernel-guard.sh
     before rebooting into anything, and keep the 6.17 fallbacks held.

  3. A restore rewinds apt's own history. /var/log/apt/history.log is inside the
     snapshot, so afterwards apt-rollback.sh cannot see anything that happened
     after the snapshot was taken -- including the transaction you just undid.
     The two tools compose in one direction only. If you might want the precise
     apt-level record, copy it out first:

         cp /var/log/apt/history.log \$HOME/apt-history-before-restore.log

  From the running system (the normal path -- rsync mode restores in place and
  then reboots):

      sudo timeshift --list
      sudo timeshift --restore --snapshot '<NAME>' --skip-grub

  Read the plan it prints. It tells you what it will overwrite. /home is not in
  these snapshots at all, so your files are not at risk -- but neither are they
  recoverable from here. The 2026-08-08 run confirmed the exclusion holds in
  practice: the restore's own rsync log named nothing under /home or /root.

  Anything you want to survive the restore as EVIDENCE -- a manifest, a log you
  copied out -- must live in \$HOME. Put it anywhere on the system side and the
  restore reverts the thing you were going to grade the restore against.

  Before reaching for this, try the cheaper tool: if you know which update
  broke it, ./apt-rollback.sh reverts exactly that and nothing else.

EOF
}

case "${1:-status}" in
  status)                    cmd_status ;;
  configure|config)          cmd_configure ;;
  create)                    cmd_create "${2:-}" ;;
  list|ls)                   cmd_list "${2:-}" ;;
  prune)                     cmd_prune "${2:-}" ;;
  check-esp|esp)             cmd_check_esp "${2:-}" ;;
  restore-help|restore)      cmd_restore_help ;;
  *)                         usage ;;
esac
