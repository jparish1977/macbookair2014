#!/bin/bash
# Prove that a Timeshift restore actually restores, before you need it to.
#
# WHY THIS EXISTS
#
# system-snapshot.sh had every path exercised except the only one that matters.
# A snapshot you have never restored is a belief, not a backup: the restore path
# is code in someone else's program, running against your disk, and the first time
# you run it should not be the day something is already broken.
#
# HOW IT WORKS
#
# It plants markers covering the four things rsync can do to a file, plus the two
# real-world classes that a snapshot is supposed to cover and apt-rollback.sh
# cannot:
#
#     unchanged.txt   present, untouched  -> must survive identical (control)
#     modified.txt    content changed     -> must revert to the original
#     deleted.txt     deleted             -> must come back
#     added.txt       created afterwards  -> must be REMOVED (tests rsync --delete)
#     /etc/...conf    a config file edited by hand
#     hello           a package installed after the snapshot
#
# The control matters as much as the rest: if every check "passes" because the
# restore did nothing at all, only the control tells you.
#
# WHERE THE MANIFEST LIVES, AND WHY IT IS NOT NEGOTIABLE
#
# In $HOME, which is excluded from both the snapshot and the restore. Anything
# stored under /opt or /etc is inside the scope of the thing being tested -- the
# restore would revert the expectations along with the markers, and the test would
# grade itself against whatever it had just been reset to. Evidence has to live
# outside the blast radius.
#
# ORDER OF OPERATIONS
#
#     sudo ./restore-test.sh arm                     plant markers, write manifest
#     sudo ./system-snapshot.sh create "restore test" snapshot the GOOD state
#     sudo ./restore-test.sh break                   mutate everything
#     ./restore-test.sh state                        see the damage
#     sudo timeshift --restore --snapshot '<name>' --skip-grub
#     (reboot)
#     ./restore-test.sh verify                       grade it
#     sudo ./restore-test.sh clean                   remove all traces

# BOUNCING BETWEEN RESTORE POINTS
#
# `bounce-arm` builds two complete states, A and B, snapshots each, and leaves you
# on B. You then restore A, reboot, `bounce-verify A`, restore B, reboot,
# `bounce-verify B`. That answers a question a one-way test cannot:
#
#   - does a snapshot NEWER than the one you restore survive being rolled past?
#     (it should: /timeshift/* is in the exclude list, so the restore never
#     touches the snapshot store -- but "should" is what this repo tests)
#   - can you then go forward again into it?
#
# Each state has a file the other does not, so every hop must both create and
# delete. A restore that only ever adds files back would pass a one-way test and
# fail this one.
#
#     sudo ./restore-test.sh bounce-arm       build A and B, snapshot both
#     sudo timeshift --restore --snapshot '<A>' --skip-grub   (reboot)
#     ./restore-test.sh bounce-verify A
#     sudo timeshift --restore --snapshot '<B>' --skip-grub   (reboot)
#     ./restore-test.sh bounce-verify B
#     sudo ./restore-test.sh clean

set -uo pipefail

DIR=/opt/restore-test
CONF=/etc/restore-test.conf
PKG=hello
SNAPDIR=/timeshift/snapshots
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { echo "error: $*" >&2; exit 1; }
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILED=$((FAILED + 1)); }
info() { echo "  --    $*"; }

need_root() { [ "$(id -u)" = 0 ] || die "$1 needs root. Try: sudo $0 $1"; }

# $HOME is /root under sudo, which is inside the snapshot. Resolve the invoking
# user's home instead, or the manifest lands somewhere the restore will revert.
home_of_caller() {
  getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6
}
MANIFEST="$(home_of_caller)/restore-test-manifest.txt"
BOUNCE="$(home_of_caller)/restore-test-bounce.txt"

sha() { [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo "ABSENT"; }
pkg_installed() { dpkg -s "$1" 2>/dev/null | grep -q "^Status: install ok installed"; }

usage() {
  cat <<EOF
usage: $0 arm        plant markers in their GOOD state, write the manifest (root)
       $0 break      mutate them: modify, delete, add, edit config, install $PKG (root)
       $0 state      what the markers look like right now
       $0 verify     grade the current state against the manifest
       $0 clean      remove every marker and purge $PKG (root)

       $0 bounce-arm         build two states A and B, snapshot each (root)
       $0 bounce-verify A|B  grade a hop, and check the other point survived

Run 'arm', then take a snapshot, then 'break', then restore that snapshot,
then 'verify'. See the header of this script for the full sequence.

'bounce-arm' answers a different question: whether you can move back AND
forward between restore points, and whether a snapshot survives being rolled
past. It takes its own snapshots, because the forward destination has to exist
on disk before you hop backwards.
EOF
  exit 1
}

cmd_arm() {
  need_root arm

  mkdir -p "$DIR" || die "could not create $DIR"
  printf 'control -- this must survive a restore byte-identical\n' > "$DIR/unchanged.txt"
  printf 'ORIGINAL CONTENT -- a restore must bring this back\n'    > "$DIR/modified.txt"
  printf 'this file must reappear after a restore\n'               > "$DIR/deleted.txt"
  rm -f "$DIR/added.txt"          # must NOT exist in the snapshot
  printf '# planted by restore-test.sh\nsetting = original\n'      > "$CONF"
  chmod 644 "$DIR"/*.txt "$CONF"

  if pkg_installed "$PKG"; then
    die "$PKG is already installed. Pick a different package, or: sudo apt-get purge $PKG"
  fi

  cat > "$MANIFEST" <<EOF
# restore-test manifest -- expected state AFTER a successful restore.
# Written $(date -Is). Lives in \$HOME on purpose: /opt and /etc are inside the
# snapshot, so a restore would revert this file too and the test would grade
# itself against its own reset expectations.
unchanged $DIR/unchanged.txt present $(sha "$DIR/unchanged.txt")
modified  $DIR/modified.txt  present $(sha "$DIR/modified.txt")
deleted   $DIR/deleted.txt   present $(sha "$DIR/deleted.txt")
added     $DIR/added.txt     absent  -
config    $CONF              present $(sha "$CONF")
package   $PKG               absent  -
EOF
  # Hand it back to the user so 'verify' needs no root after the reboot.
  [ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$MANIFEST"

  echo
  echo "  armed. markers planted:"
  cmd_state
  echo "  manifest: $MANIFEST"
  echo
  echo "  NEXT -- snapshot this state, which is the one you want back:"
  echo "    sudo ./system-snapshot.sh create \"restore test baseline\""
  echo
}

cmd_break() {
  need_root break
  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST -- run 'sudo $0 arm' first"
  [ -f "$DIR/unchanged.txt" ] || die "markers missing -- run 'sudo $0 arm' first"

  printf 'MUTATED -- if you can still read this, the restore did not work\n' > "$DIR/modified.txt"
  rm -f "$DIR/deleted.txt"
  printf 'added AFTER the snapshot -- a restore must delete this\n' > "$DIR/added.txt"
  printf '# planted by restore-test.sh\nsetting = MUTATED\n' > "$CONF"

  echo
  echo "  installing $PKG so the restore has a package to undo..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" >/dev/null 2>&1 \
    || echo "  (apt install failed -- the file checks still stand on their own)"

  echo
  echo "  broken. current state:"
  cmd_state
  echo "  NEXT -- restore the snapshot you took after 'arm':"
  echo "    sudo ./system-snapshot.sh list"
  echo "    sudo timeshift --restore --snapshot '<NAME>' --skip-grub"
  echo
  echo "  --skip-grub matters: this machine boots EFI and you do not want"
  echo "  timeshift reinstalling the bootloader unless GRUB is the broken thing."
  echo "  Then reboot, and: ./restore-test.sh verify"
  echo
}

cmd_state() {
  echo
  printf '    %-26s %s\n' "$DIR/unchanged.txt" "$(sha "$DIR/unchanged.txt")"
  printf '    %-26s %s\n' "$DIR/modified.txt"  "$(sha "$DIR/modified.txt")"
  printf '    %-26s %s\n' "$DIR/deleted.txt"   "$(sha "$DIR/deleted.txt")"
  printf '    %-26s %s\n' "$DIR/added.txt"     "$(sha "$DIR/added.txt")"
  printf '    %-26s %s\n' "$CONF"              "$(sha "$CONF")"
  printf '    %-26s %s\n' "package $PKG"       "$(pkg_installed "$PKG" && echo INSTALLED || echo absent)"
  echo
}

cmd_verify() {
  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST -- was 'arm' ever run?"
  FAILED=0
  local n=0

  echo
  echo "  grading against $MANIFEST"
  echo

  local kind target want want_sha now
  while read -r kind target want want_sha; do
    case "$kind" in ''|'#'*) continue ;; esac
    n=$((n + 1))

    if [ "$kind" = package ]; then
      if pkg_installed "$target"; then
        [ "$want" = present ] && pass "package $target present, as expected" \
                              || fail "package $target is STILL INSTALLED -- the restore did not revert dpkg"
      else
        [ "$want" = absent ] && pass "package $target removed by the restore" \
                             || fail "package $target is missing but should be present"
      fi
      continue
    fi

    now=$(sha "$target")
    if [ "$want" = absent ]; then
      if [ "$now" = ABSENT ]; then
        pass "$kind: $target correctly deleted by the restore"
      else
        fail "$kind: $target STILL EXISTS -- restore did not apply --delete"
      fi
    elif [ "$now" = ABSENT ]; then
      fail "$kind: $target is MISSING -- restore did not bring it back"
    elif [ "$now" = "$want_sha" ]; then
      pass "$kind: $target matches the snapshot ($now)"
    else
      fail "$kind: $target content differs -- got $now, wanted $want_sha"
    fi
  done < "$MANIFEST"

  echo
  if [ "$FAILED" = 0 ]; then
    echo "  ALL $n CHECKS PASSED -- the restore genuinely restored."
    echo "  Note the 'unchanged' control passed too, so this is not a case of the"
    echo "  restore doing nothing and everything looking fine by default."
  else
    echo "  $FAILED of $n CHECKS FAILED. The restore did not do what it claims."
    echo "  Do not treat these snapshots as a rollback until this is understood."
  fi
  echo
  return 0
}

# ------------------------------------------------------------------ bouncing

newest_snap() { ls -1 "$SNAPDIR" 2>/dev/null | sort | tail -1; }

# Each state carries a file the other lacks, so a hop in either direction has to
# delete something as well as write something.
#
# The two states are deliberately DIFFERENT LENGTHS, which is not cosmetic.
# Timeshift restores with `rsync -avir --force --delete` and no --checksum, so
# rsync's quick check applies: a file is skipped when its size matches and its
# mtime matches to the second. Equal-length markers written inside the same
# second as the snapshot would be silently skipped, and the test would report a
# failed restore that never actually happened. Differing sizes defeat the quick
# check outright rather than relying on the snapshot taking over a second.
plant_state() {
  mkdir -p "$DIR" || die "could not create $DIR"
  case "$1" in
    A) printf 'STATE A\n'                                              > "$DIR/state.txt"
       printf 'only in A -- hopping to B must DELETE this\n'           > "$DIR/only-in-a.txt"
       rm -f "$DIR/only-in-b.txt"
       printf '# planted by restore-test.sh bounce\nsetting = A\n'     > "$CONF" ;;
    B) printf 'STATE B -- the second state, deliberately longer\n'     > "$DIR/state.txt"
       printf 'only in B -- hopping to A must DELETE this\n'           > "$DIR/only-in-b.txt"
       rm -f "$DIR/only-in-a.txt"
       printf '# planted by restore-test.sh bounce\nsetting = B, and this line differs in length\n' > "$CONF" ;;
    *) die "plant_state: unknown state $1" ;;
  esac
  chmod 644 "$DIR"/*.txt "$CONF" 2>/dev/null
}

# The manifest records both states in full, so one file grades either direction.
record_state() {
  local st=$1 pkgwant=$2
  {
    printf '%s file %s present %s\n' "$st" "$DIR/state.txt"     "$(sha "$DIR/state.txt")"
    printf '%s file %s %s %s\n'      "$st" "$DIR/only-in-a.txt" \
      "$([ -f "$DIR/only-in-a.txt" ] && echo present || echo absent)" "$(sha "$DIR/only-in-a.txt")"
    printf '%s file %s %s %s\n'      "$st" "$DIR/only-in-b.txt" \
      "$([ -f "$DIR/only-in-b.txt" ] && echo present || echo absent)" "$(sha "$DIR/only-in-b.txt")"
    printf '%s file %s present %s\n' "$st" "$CONF"              "$(sha "$CONF")"
    printf '%s package %s %s -\n'    "$st" "$PKG"               "$pkgwant"
  } >> "$BOUNCE"
}

take_snapshot() {
  local label=$1 before after
  before=$(newest_snap)
  # stdout here is captured by the caller for the snapshot name, so the tool's
  # own progress has to go to stderr or it lands in the variable instead.
  "$SELFDIR/system-snapshot.sh" create "$label" >&2 || die "snapshot failed: $label"
  after=$(newest_snap)
  [ "$after" != "$before" ] || die "no new snapshot appeared after '$label'"
  printf '%s' "$after"
}

cmd_bounce_arm() {
  need_root bounce-arm
  [ -x "$SELFDIR/system-snapshot.sh" ] || die "system-snapshot.sh not found next to this script"
  pkg_installed "$PKG" && die "$PKG is already installed. sudo apt-get purge $PKG"

  # A pre-restore snapshot is not optional here -- it IS the forward destination.
  # Without B on disk there is nowhere to bounce to.
  rm -f "$BOUNCE"
  printf '# bounce manifest -- both states, written %s\n' "$(date -Is)" > "$BOUNCE"

  echo
  echo "  building state A..."
  plant_state A
  record_state A absent
  local snap_a; snap_a=$(take_snapshot "bounce test state A") || exit 1

  echo
  echo "  building state B..."
  plant_state B
  echo "  installing $PKG so dpkg state differs between the two..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$PKG" >/dev/null 2>&1 \
    || echo "  (apt install failed -- the file checks still stand on their own)"
  record_state B present
  local snap_b; snap_b=$(take_snapshot "bounce test state B") || exit 1

  printf 'snapshot A %s\nsnapshot B %s\n' "$snap_a" "$snap_b" >> "$BOUNCE"
  [ -n "${SUDO_UID:-}" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$BOUNCE"

  cat <<EOF

  armed. two restore points now exist:

    A  $snap_a   (state.txt = STATE A, only-in-a.txt, $PKG absent)
    B  $snap_b   (state.txt = STATE B, only-in-b.txt, $PKG installed)

  The system is currently in state B. Hop backwards first:

    sudo timeshift --restore --snapshot '$snap_a' --skip-grub
    (reboot)
    ./restore-test.sh bounce-verify A

  then forwards again into the snapshot you just rolled past:

    sudo timeshift --restore --snapshot '$snap_b' --skip-grub
    (reboot)
    ./restore-test.sh bounce-verify B

  manifest: $BOUNCE  (in \$HOME, outside the snapshot, so it survives both hops)

EOF
}

cmd_bounce_verify() {
  local want=${1:-}
  case "$want" in A|a) want=A ;; B|b) want=B ;; *) die "usage: $0 bounce-verify <A|B>" ;; esac
  [ -f "$BOUNCE" ] || die "no bounce manifest at $BOUNCE -- run 'sudo $0 bounce-arm' first"

  FAILED=0
  local n=0 snap_a snap_b other
  snap_a=$(awk '$1=="snapshot" && $2=="A" {print $3}' "$BOUNCE")
  snap_b=$(awk '$1=="snapshot" && $2=="B" {print $3}' "$BOUNCE")
  [ "$want" = A ] && other=$snap_b || other=$snap_a

  echo
  echo "  grading against state $want in $BOUNCE"
  echo

  local st kind target expect want_sha now
  while read -r st kind target expect want_sha; do
    case "$st" in ''|'#'*|snapshot) continue ;; esac
    [ "$st" = "$want" ] || continue
    n=$((n + 1))

    if [ "$kind" = package ]; then
      if pkg_installed "$target"; then
        [ "$expect" = present ] && pass "package $target present, as state $want expects" \
                                || fail "package $target STILL INSTALLED -- dpkg state did not follow the hop"
      else
        [ "$expect" = absent ] && pass "package $target absent, as state $want expects" \
                               || fail "package $target MISSING -- the hop forward did not restore dpkg"
      fi
      continue
    fi

    now=$(sha "$target")
    if [ "$expect" = absent ]; then
      [ "$now" = ABSENT ] && pass "$(basename "$target") correctly absent in state $want" \
                          || fail "$(basename "$target") STILL EXISTS -- the hop did not delete it"
    elif [ "$now" = ABSENT ]; then
      fail "$(basename "$target") is MISSING -- the hop did not bring it back"
    elif [ "$now" = "$want_sha" ]; then
      pass "$(basename "$target") matches state $want ($now)"
    else
      fail "$(basename "$target") content is wrong -- got $now, wanted $want_sha"
    fi
  done < "$BOUNCE"

  # The point of the whole exercise: the snapshot we did NOT restore has to have
  # survived being rolled past, contents and all, or there is no way back.
  echo
  n=$((n + 1))
  if [ -d "$SNAPDIR/$other" ]; then
    pass "the other restore point ($other) still exists after the hop"
    n=$((n + 1))
    local inside="$SNAPDIR/$other/localhost$DIR/state.txt"
    if [ -r "$inside" ]; then
      # Compare checksums against the manifest rather than grepping for a string:
      # it is exact, and it cannot drift when the marker text is edited.
      local other_st; [ "$want" = A ] && other_st=B || other_st=A
      local want_other now_other
      want_other=$(awk -v s="$other_st" -v f="$DIR/state.txt" \
                       '$1==s && $2=="file" && $3==f {print $5}' "$BOUNCE")
      now_other=$(sha "$inside")
      if [ -n "$want_other" ] && [ "$now_other" = "$want_other" ]; then
        pass "and its contents are intact (state $other_st, $now_other) -- the way back is real"
      else
        fail "but its contents are wrong -- got $now_other, wanted $want_other (state $other_st)"
      fi
    else
      info "could not read inside $other to confirm contents (permissions)"
      n=$((n - 1))
    fi
  else
    fail "the other restore point ($other) is GONE -- a restore destroyed it"
  fi

  echo
  if [ "$FAILED" = 0 ]; then
    echo "  ALL $n CHECKS PASSED for state $want."
    [ "$want" = B ] && cat <<'EOF'

  That is the round trip: back to an older state, then forward again into a
  snapshot that had been rolled past. Restore points are not one-way, and a
  restore does not consume the ones newer than it.
EOF
  else
    echo "  $FAILED of $n CHECKS FAILED for state $want."
  fi
  echo
  return 0
}

cmd_clean() {
  need_root clean
  rm -rf "$DIR"
  rm -f "$CONF"
  pkg_installed "$PKG" && DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PKG" >/dev/null 2>&1
  rm -f "$MANIFEST" "$BOUNCE"
  echo "  cleaned: $DIR, $CONF, package $PKG, and both manifests."
  echo "  The test snapshots themselves are still there. Check what you have"
  echo "  before pruning -- a bounce leaves two, and the older ones may be real:"
  echo "    ./system-snapshot.sh list"
  echo "    sudo ./system-snapshot.sh prune N"
}

case "${1:-state}" in
  arm)            cmd_arm ;;
  break)          cmd_break ;;
  state)          cmd_state ;;
  verify)         cmd_verify ;;
  clean)          cmd_clean ;;
  bounce-arm)     cmd_bounce_arm ;;
  bounce-verify)  cmd_bounce_verify "${2:-}" ;;
  *)              usage ;;
esac
