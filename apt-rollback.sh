#!/bin/bash
# Undo a bad apt transaction, precisely, using what apt already records.
#
# WHY THIS INSTEAD OF SNAPSHOTS
#
# "Undo the last update" usually means "put back the handful of packages that
# changed", not "roll the whole system back to Tuesday". apt already keeps the
# evidence: /var/log/apt/history.log records every transaction with the old and
# new version of everything it touched, and /var/cache/apt/archives often still
# holds the .deb you want. That costs nothing, reverts exactly what changed, and
# leaves everything else alone.
#
# A filesystem snapshot is the right tool for the other case -- something broke
# and you do not know what changed, or the damage is outside dpkg. This tool
# cannot help there, and says so rather than pretending.
#
# WHAT IT WILL NOT DO
#
# It prints the command and stops. Downgrades can pull half the system with them
# when a dependency will not go backwards, so the apt output is worth reading
# before anything happens. --run executes, and even then only after showing you.
#
# Kernels are deliberately special-cased: this machine boots from a GRUB menu
# with held fallback kernels, so picking an older kernel there beats downgrading
# packages. See kernel-guard.sh and WIFI.md.

set -uo pipefail

HIST=/var/log/apt/history.log
RUN=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: $0 list [N]        recent apt transactions, newest first (default 15)
       $0 show ID         everything one transaction changed
       $0 revert ID       the command to undo it  (add --run to execute)

  ID is the number shown by 'list'. 1 is the most recent.

Only packaged files are covered. Config edits, files written outside dpkg, and
anything a postinst script did to your system are invisible here -- that is what
a snapshot would be for.
EOF
  exit 1
}

# Rotated logs oldest-first, then the live one, so numbering is chronological.
collect() {
  local f
  for f in $(ls -1 "$HIST".*.gz 2>/dev/null | sort -rV); do zcat "$f" 2>/dev/null; echo; done
  for f in $(ls -1 "$HIST".[0-9] 2>/dev/null | sort -rV); do cat "$f" 2>/dev/null; echo; done
  [ -r "$HIST" ] && cat "$HIST"
}

WORK=$(mktemp -d /tmp/apt-rollback-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

split_blocks() {
  collect | awk -v d="$WORK" 'BEGIN { RS=""; n=0 }
    /Start-Date/ { n++; print > (d "/" sprintf("%05d", n)) }
    END { print n > (d "/count") }'
}

# Pull out "pkg:arch (stuff)" tokens. Splitting the line on ", " is wrong,
# because the version pair inside the parentheses contains ", " too.
tokens() {
  awk '{
    while (match($0, /[A-Za-z0-9._+~-]+:[a-z0-9]+ \([^)]*\)/)) {
      print substr($0, RSTART, RLENGTH)
      $0 = substr($0, RSTART + RLENGTH)
    }
  }'
}

field() { grep -m1 "^$1:" "$2" 2>/dev/null | cut -d' ' -f2-; }

block_for_id() {
  local id="$1" total n
  total=$(cat "$WORK/count" 2>/dev/null || echo 0)
  [ "$total" -gt 0 ] || die "no apt transactions found in $HIST"
  [ "$id" -ge 1 ] 2>/dev/null && [ "$id" -le "$total" ] || die "ID must be between 1 and $total"
  n=$((total - id + 1))
  printf '%s/%05d' "$WORK" "$n"
}

summarise() {
  local b="$1" i u r
  i=$(field Install "$b" | tokens | wc -l)
  u=$(field Upgrade "$b" | tokens | wc -l)
  r=$(( $(field Remove "$b" | tokens | wc -l) + $(field Purge "$b" | tokens | wc -l) ))
  local out=""
  [ "$u" -gt 0 ] && out="$out ${u} upgraded"
  [ "$i" -gt 0 ] && out="$out ${i} installed"
  [ "$r" -gt 0 ] && out="$out ${r} removed"
  [ -z "$out" ] && out=" (nothing recorded)"
  echo "$out"
}

cmd_list() {
  local limit="${1:-15}" total n b id
  split_blocks
  total=$(cat "$WORK/count" 2>/dev/null || echo 0)
  [ "$total" -gt 0 ] || die "no apt transactions found"
  echo
  printf '  %-4s %-20s %s\n' "ID" "WHEN" "WHAT"
  for id in $(seq 1 "$total"); do
    [ "$id" -gt "$limit" ] && break
    b=$(block_for_id "$id")
    local when cmdline kern=""
    when=$(field Start-Date "$b")
    cmdline=$(field Commandline "$b")
    [ -z "$cmdline" ] && cmdline="(no commandline recorded — unattended?)"
    grep -qE 'linux-image|linux-modules|linux-headers' "$b" && kern="  [touches kernels]"
    printf '  %-4s %-20s %s\n' "$id" "$when" "$(echo "$cmdline" | cut -c1-60)$kern"
    printf '       %-20s %s\n' "" "$(summarise "$b")"
  done
  echo
  echo "  $0 show ID      to see every package"
  echo "  $0 revert ID    to get the command that undoes it"
}

cmd_show() {
  local id="${1:-}" b
  [ -n "$id" ] || usage
  split_blocks
  b=$(block_for_id "$id")
  echo
  echo "  transaction $id"
  echo "  when:     $(field Start-Date "$b")"
  echo "  command:  $(field Commandline "$b")"
  echo "  by:       $(field Requested-By "$b" || echo 'root (no user recorded)')"
  local sec
  for sec in Install Upgrade Remove Purge Reinstall; do
    local body; body=$(field "$sec" "$b")
    [ -z "$body" ] && continue
    echo
    echo "  $sec:"
    echo "$body" | tokens | sed 's/^/    /'
  done
  echo
  if grep -qE 'linux-image|linux-modules' "$b"; then
    echo "  NOTE: this touched kernel packages. Do not downgrade those -- reboot and"
    echo "        pick an older kernel from the GRUB menu instead, and check"
    echo "        ./kernel-guard.sh check first."
  fi
}

# Can apt actually obtain this exact version? Answered against the repos first,
# then a cached .deb.
#
# The comparison is LITERAL, deliberately. Debian versions are full of '+', '~'
# and '.', which are regex metacharacters -- an awk `$2 ~ v` test on
# "30.0.2+dfsg-3build1" reads the '+' as a quantifier and never matches the
# string it came from. That produced a confident "NOT AVAILABLE" for a package
# sitting in noble/universe, which would have sent someone looking for a
# snapshot they did not need.
available() {
  local pkg="$1" ver="$2" esc
  apt-cache madison "$pkg" 2>/dev/null |
    awk -F'|' -v v="$ver" '{ gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($2 == v) f = 1 }
                           END { exit !f }' && return 0
  esc=$(printf '%s' "$ver" | sed 's/:/%3a/g')   # epochs are escaped in filenames
  ls /var/cache/apt/archives/"${pkg}"_*.deb 2>/dev/null | grep -qF -- "_${esc}_" && return 0
  return 1
}

cmd_revert() {
  local id="${1:-}" b
  [ -n "$id" ] || usage
  split_blocks
  b=$(block_for_id "$id")

  echo
  echo "  undoing transaction $id — $(field Start-Date "$b")"
  echo "  original: $(field Commandline "$b")"
  echo

  if grep -qE 'linux-image-[0-9]|linux-modules-[0-9]' "$b"; then
    echo "  ** This transaction installed or changed kernel packages. **"
    echo "  Do not revert those with apt. Reboot, pick an older kernel in the GRUB"
    echo "  menu, and confirm with ./kernel-guard.sh check. The 6.17 fallbacks are"
    echo "  held on this machine precisely so that path stays open."
    echo
  fi

  local -a downgrade=() install=() remove=() missing=() kernelpkg=()

  # Kernel packages never go into the generated command. The warning above says
  # not to revert them with apt; printing the command anyway would be worse than
  # saying nothing, and on this machine the obvious target is the *running*
  # kernel. Removing that is how a laptop with no ethernet ends up unbootable
  # and unreachable in the same move.
  is_kernel_pkg() { case "$1" in linux-image*|linux-modules*|linux-headers*|linux-hwe*|linux-generic*) return 0 ;; *) return 1 ;; esac; }

  while read -r tok; do
    [ -z "$tok" ] && continue
    local pkg vers old
    pkg=${tok%%:*}
    vers=$(echo "$tok" | sed -n 's/.*(\(.*\))/\1/p')
    old=$(echo "$vers" | cut -d',' -f1 | xargs)
    if is_kernel_pkg "$pkg"; then kernelpkg+=("$pkg"); continue; fi
    if available "$pkg" "$old"; then downgrade+=("$pkg=$old"); else missing+=("$pkg=$old"); fi
  done < <(field Upgrade "$b" | tokens)

  while read -r tok; do
    [ -z "$tok" ] && continue
    if is_kernel_pkg "${tok%%:*}"; then kernelpkg+=("${tok%%:*}"); continue; fi
    remove+=("${tok%%:*}")
  done < <(field Install "$b" | tokens)

  while read -r tok; do
    [ -z "$tok" ] && continue
    local pkg ver
    pkg=${tok%%:*}
    ver=$(echo "$tok" | sed -n 's/.*(\(.*\))/\1/p' | cut -d',' -f1 | xargs)
    if is_kernel_pkg "$pkg"; then kernelpkg+=("$pkg"); continue; fi
    if available "$pkg" "$ver"; then install+=("$pkg=$ver"); else missing+=("$pkg=$ver"); fi
  done < <( { field Remove "$b"; field Purge "$b"; } | tokens )

  local -a parts=()
  [ "${#downgrade[@]}" -gt 0 ] && parts+=("${downgrade[@]}")
  [ "${#install[@]}" -gt 0 ]   && parts+=("${install[@]}")

  if [ "${#kernelpkg[@]}" -gt 0 ]; then
    echo "  LEFT OUT of the command below — kernel packages, deliberately:"
    printf '    %s\n' "${kernelpkg[@]}" | sort -u
    echo
    echo "  Reverting these with apt is the wrong move, and one of them is very"
    echo "  likely the kernel you are running ($(uname -r)). Use the GRUB menu."
    echo
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "  NOT AVAILABLE — neither cached nor in any configured repo:"
    printf '    %s\n' "${missing[@]}"
    echo "  Those cannot be put back by apt. A snapshot would be the only route."
    echo
  fi

  if [ "${#parts[@]}" -eq 0 ] && [ "${#remove[@]}" -eq 0 ]; then
    echo "  Nothing revertible in this transaction."
    return 0
  fi

  local cmd=""
  [ "${#parts[@]}" -gt 0 ] && cmd="sudo apt-get install --allow-downgrades ${parts[*]}"
  if [ "${#remove[@]}" -gt 0 ]; then
    [ -n "$cmd" ] && cmd="$cmd && "
    cmd="${cmd}sudo apt-get remove ${remove[*]}"
  fi

  echo "  Simulate first — downgrades can drag dependencies with them:"
  echo
  echo "    ${cmd/sudo apt-get install/sudo apt-get -s install}"
  echo
  echo "  Then, if the plan looks sane:"
  echo
  echo "    $cmd"
  echo

  if [ "$RUN" = "1" ]; then
    echo "  --run given. Executing the simulation first:"
    eval "${cmd%% \&\&*}" --simulate 2>&1 | tail -20
    echo
    read -r -p "  Proceed for real? [y/N] " ans
    case "$ans" in [yY]*) eval "$cmd" ;; *) echo "  aborted." ;; esac
  fi
}

args=()
for a in "$@"; do
  case "$a" in --run) RUN=1 ;; *) args+=("$a") ;; esac
done
set -- "${args[@]:-}"

[ -r "$HIST" ] || die "cannot read $HIST"

case "${1:-list}" in
  list)   cmd_list "${2:-}" ;;
  show)   cmd_show "${2:-}" ;;
  revert) cmd_revert "${2:-}" ;;
  *)      usage ;;
esac
