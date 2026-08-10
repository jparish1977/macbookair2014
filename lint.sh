#!/bin/bash
# Check this repo for the traps it has actually been bitten by.
#
#   ./lint.sh            report
#   ./lint.sh --strict   exit non-zero if anything is found (for a hook)
#
# WHY THIS EXISTS
#
# The same bug was reintroduced three times in one day, in three different
# scripts, by the same hands. Documenting it did not stop it; a helper function
# did not stop it, because a helper still has to be remembered. This repo's
# habit elsewhere is to ENCODE a rule rather than rely on recall --
# system-snapshot.sh refuses network targets outright instead of explaining that
# they are wrong -- and this is that habit applied to its own source.
#
# WHY IT IS NARROW ON PURPOSE
#
# There are ~87 pipelines ending in `grep -q` or `head` across this repo and
# most are harmless. A check that flagged all of them would be noise, and a
# check that cries wolf is one nobody reads -- which is the exact criticism this
# project levelled at its own restore-test earlier. So this flags only the shape
# that actually breaks, and says plainly what it is skipping.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
STRICT=0; [ "${1:-}" = "--strict" ] && STRICT=1
FOUND=0

say()  { echo; echo -e "\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m[ok]\033[0m   $*"; }
bad()  { echo -e "    \033[31m[!!]\033[0m   $*"; }
info() { echo "    $*"; }

# Embedded guest scripts are written into heredocs and run elsewhere with
# `set -u` and no pipefail, so the trap does not apply to them. Counting them
# was what turned 18 findings in one file into noise on the first attempt.
# Emits "LINENO:text" for lines that are real code in THIS file: not inside an
# embedded heredoc, and not a comment. Getting this wrong is what made the first
# version report its own documentation as a finding.
code_lines() {
  awk '
    # opening delimiter of any quoted heredoc
    match($0, /<<-?'\''[A-Za-z_][A-Za-z0-9_]*'\''/) {
      if (!inhd) { tag=substr($0, RSTART, RLENGTH); gsub(/[<'\''-]/,"",tag); inhd=1; next }
    }
    inhd && $0 == tag { inhd=0; next }
    inhd { next }
    /^[[:space:]]*#/ { next }
    { print NR":"$0 }
  ' "$1"
}

# ---- 1. grep -q / head as a CONDITION, under pipefail ------------------------
#
# grep -q exits at the first match and head at its line limit. That closes the
# pipe, the upstream dies of SIGPIPE (141), and `set -o pipefail` reports the
# whole pipeline as FAILED on a successful match. Load-order dependent, so it
# looks absurd rather than like a bug: `lsmod | grep -q '^wl '` once reported wl
# missing on a machine that was talking over Wi-Fi at that moment.
#
# Only matters where the pipeline's exit status is used. Capture first, then
# match with a here-string:  out=$(cmd); grep -q PAT <<< "$out"
say "grep -q / head used as a condition, in a file with pipefail"
for f in *.sh workshop/*.sh; do
  [ -f "$f" ] || continue
  [ "$f" = "lint.sh" ] && continue          # it documents the traps it looks for
  grep -q "set -.*pipefail" "$f" || continue
  # Two exclusions, both because the status cannot be affected:
  #   echo/printf producers -- a builtin writing a small string has finished
  #     before grep -q exits, so there is nothing to SIGPIPE
  #   pipelines inside $( ) -- the pipeline's status is discarded by the
  #     substitution, so pipefail never sees it
  # Without the second, crash-report.sh's `[ "$(field_body ... | head -1)" = x ]`
  # was reported for ever, and a check with one permanent known-false finding
  # teaches you to ignore the whole thing.
  hits=$(code_lines "$f" \
    | grep -E "^[0-9]+: *(if|elif|while|[[:space:]]*!)" \
    | grep -E "\| *(grep -q|head )" \
    | grep -vE "(echo|printf)[^|]*\|" \
    | grep -vE '\$\([^)]*\|[^)]*\)' || true)   # single-quoted: in double quotes
                                              # bash eats the backslash and grep
                                              # reads \$ as an end-of-line anchor
  [ -z "$hits" ] && continue
  echo "  $f"
  echo "$hits" | sed 's/^/      /' | cut -c1-100
  FOUND=$((FOUND + $(echo "$hits" | grep -c .)))
done
[ "$FOUND" = 0 ] && ok "none" || info ""

# ---- 1b. the same trap INSIDE a command substitution -------------------------
#
# Check 1 only looks at lines that BEGIN a conditional, and check 1 excludes
# $( ) outright because the substitution normally discards the pipeline's status.
# Both were right about the cases that prompted them and together they left a
# hole, which was found the honest way -- by writing the bug into
# machine-provision.sh while adding a status line:
#
#   printf '%s' "$(find /lib/modules -name 'wl.ko*' | grep -q . && echo yes || echo NO)"
#
# The line starts with printf, so check 1 never looks at it; it is inside $( ),
# so the exclusion would have skipped it anyway. But the status is NOT discarded
# here -- `&&` consumes it inside the substitution -- so a module that IS there
# prints NO. Report it when a pipeline inside $( ) is followed by && or ||.
say "grep -q / head inside \$( ), with its status consumed by && or ||"
n=0
for f in *.sh workshop/*.sh; do
  [ -f "$f" ] || continue
  [ "$f" = "lint.sh" ] && continue
  grep -q "set -.*pipefail" "$f" || continue
  # The exclusion must test the PRODUCER, which is whatever follows $( -- not
  # whatever the line begins with. Getting that wrong is why the first version of
  # this check reported "none" against the very line that motivated it: the line
  # began with printf, so the borrowed check-1 exclusion skipped it, even though
  # the producer inside the substitution was find.
  hits=$(code_lines "$f" \
    | grep -E '\$\([^)]*\|[^)]*(grep -q|head )[^)]*(&&|\|\|)' \
    | grep -vE '\$\((echo|printf) ' || true)
  [ -z "$hits" ] && continue
  echo "  $f"; echo "$hits" | sed 's/^/      /' | cut -c1-110
  n=$((n + $(echo "$hits" | grep -c .)))
done
[ "$n" = 0 ] && ok "none" || FOUND=$((FOUND + n))

# ---- 2. pgrep patterns that match the script's own command line --------------
#
# `pgrep -f "vm-restore-test.sh restore"` matches the shell running it, because
# the pattern is in its own argv. It once killed the ssh session issuing it.
# Anchor with ^, or break the pattern with a character class: rest[o]re.
say "pgrep -f patterns that could match their own command line"
n=0
for f in *.sh workshop/*.sh; do
  [ -f "$f" ] || continue
  [ "$f" = "lint.sh" ] && continue
  hits=$(code_lines "$f" | grep -E "pgrep -f \"[^^]" | grep -v '\[' || true)
  [ -z "$hits" ] && continue
  echo "  $f"; echo "$hits" | sed 's/^/      /' | cut -c1-100
  n=$((n + $(echo "$hits" | grep -c .)))
done
[ "$n" = 0 ] && ok "none (all anchored or bracketed)" || FOUND=$((FOUND + n))

# ---- 3. pgrep -x with a name longer than 15 characters -----------------------
#
# pgrep -x matches against comm, which the kernel truncates to 15 characters, so
# `pgrep -x qemu-system-x86_64` (19) silently matches nothing. Silently is the
# problem: it looks like "not running".
say "pgrep -x with a name over 15 characters"
hits=$(for f in *.sh workshop/*.sh; do [ "$f" = lint.sh ] && continue
        code_lines "$f" 2>/dev/null | grep -E "pgrep -x [A-Za-z0-9_.-]{16,}" | sed "s|^|$f:|"; done || true)
[ -z "$hits" ] && ok "none" || { echo "$hits" | sed 's/^/      /'; FOUND=$((FOUND + $(echo "$hits" | grep -c .))); }

# ---- 4. rsync -X on a fake-super tree without --fake-super -------------------
#
# rsync deliberately HIDES its own user.rsync.* attributes from -X transfers, so
# copying a fake-super tree with -aHAX silently drops every owner and mode. The
# resulting copy matches on file count, byte count AND hardlinks, and restores a
# system where sudo is not setuid.
say "rsync -X over a snapshot tree without --fake-super"
hits=$(for f in *.sh; do [ "$f" = lint.sh ] && continue
        code_lines "$f" 2>/dev/null | grep -E "rsync[^|]*-[a-zA-Z]*X[a-zA-Z]*[^|]*(snapshot|mba-snap)" \
          | grep -v "fake-super" | sed "s|^|$f:|"; done || true)
[ -z "$hits" ] && ok "none" || { echo "$hits" | sed 's/^/      /' | cut -c1-110; FOUND=$((FOUND + $(echo "$hits" | grep -c .))); }

# ---- what this deliberately does not check ----------------------------------

say "Not checked, deliberately"
info "~87 pipelines end in grep -q or head across this repo and most are"
info "harmless -- the status is discarded, or the producer finishes first."
info "Flagging them all would be noise, and a check nobody reads is worse than"
info "no check. Only conditional uses are reported above."
info ""
info "Also not checked, because no lint can: whether a message TELLS THE TRUTH."
info "Most bugs found in this project were things reporting success they had"
info "not earned -- a copy matching on size and count with no ownership, a green"
info "verdict on an upgrade that did nothing. Those need a control condition,"
info "not a grep."

echo
if [ "$FOUND" = 0 ]; then
  ok "clean"
else
  bad "$FOUND finding(s)"
  [ "$STRICT" = 1 ] && exit 1
fi
echo
exit 0
