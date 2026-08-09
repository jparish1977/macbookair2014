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

set -uo pipefail

DIR=/opt/restore-test
CONF=/etc/restore-test.conf
PKG=hello

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

sha() { [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo "ABSENT"; }
pkg_installed() { dpkg -s "$1" 2>/dev/null | grep -q "^Status: install ok installed"; }

usage() {
  cat <<EOF
usage: $0 arm        plant markers in their GOOD state, write the manifest (root)
       $0 break      mutate them: modify, delete, add, edit config, install $PKG (root)
       $0 state      what the markers look like right now
       $0 verify     grade the current state against the manifest
       $0 clean      remove every marker and purge $PKG (root)

Run 'arm', then take a snapshot, then 'break', then restore that snapshot,
then 'verify'. See the header of this script for the full sequence.
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

cmd_clean() {
  need_root clean
  rm -rf "$DIR"
  rm -f "$CONF"
  pkg_installed "$PKG" && DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PKG" >/dev/null 2>&1
  rm -f "$MANIFEST"
  echo "  cleaned: $DIR, $CONF, package $PKG, and the manifest."
  echo "  The test snapshot itself is still there -- remove it with:"
  echo "    sudo ./system-snapshot.sh prune 1"
}

case "${1:-state}" in
  arm)     cmd_arm ;;
  break)   cmd_break ;;
  state)   cmd_state ;;
  verify)  cmd_verify ;;
  clean)   cmd_clean ;;
  *)       usage ;;
esac
