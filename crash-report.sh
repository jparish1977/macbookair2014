#!/usr/bin/env bash
# crash-report.sh — read the crash reports Mint keeps nagging you about.
#
# Mint's mintreport-tray pops up whenever an unprocessed .crash file is sitting
# in /var/crash. The files are apport format: mostly RFC822-ish headers, but the
# big fields (CoreDump, and often the Xorg log) are base64-gzipped, so `less` on
# one gives you megabytes of noise and no answer. This pulls out the parts that
# tell you what actually happened.
#
#   crash-report.sh                 list what is queued
#   crash-report.sh show            summarise every queued report
#   crash-report.sh show <file>     summarise one
#   crash-report.sh clear           delete them (asks first) — stops the popup
#
# Reading other users' reports needs root; run with sudo to see everything.

set -uo pipefail

CRASH_DIR=/var/crash
DRY_RUN=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[warn]\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m[!!]\033[0m   %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    \033[35m[dry]\033[0m  %s\n' "$*"
    return 0
  fi
  "$@"
}

signal_meaning() {
  case "${1:-}" in
    4)  echo "SIGILL — illegal instruction" ;;
    6)  echo "SIGABRT — abort, usually a failed internal assertion" ;;
    7)  echo "SIGBUS — bad memory alignment or bad hardware access" ;;
    8)  echo "SIGFPE — arithmetic fault" ;;
    11) echo "SIGSEGV — segfault, invalid memory access" ;;
    "") echo "(no Signal field — may not be a crash report)" ;;
    *)  echo "signal $1" ;;
  esac
}

# apport folds long values onto continuation lines that begin with a space, and
# base64-encodes anything binary or large. Pull one field's plain-text body, and
# say so rather than printing base64 soup when that is what it is.
field_body() {
  local file="$1" name="$2"
  awk -v want="$name" '
    $0 ~ "^" want ":" { found=1
      sub("^" want ":[ ]?", ""); if (length($0)) print
      next }
    found && /^[ \t]/ { sub(/^[ \t]/, ""); print; next }
    found { exit }
  ' "$file" 2>/dev/null
}

# apport stores large values as a literal "base64" marker followed by
# base64-encoded gzip. That is why opening a .crash in a pager is useless: the
# part you want — the Xorg log, the dmesg tail — is the part that is encoded.
# Decode it rather than reporting "binary, not shown".
field_decoded() {
  local file="$1" name="$2" body
  body=$(field_body "$file" "$name")
  [ -n "$body" ] || return 0

  if [ "$(printf '%s\n' "$body" | head -1 | tr -d '[:space:]')" != "base64" ]; then
    printf '%s\n' "$body"
    return 0
  fi

  local raw; raw=$(printf '%s\n' "$body" | tail -n +2 | tr -d ' \t\r')
  # Multi-member gzip is normal here, so decompress tolerantly: gzip returns
  # nonzero on trailing garbage while still having emitted good output.
  printf '%s' "$raw" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null \
    || printf '%s' "$raw" | base64 -d 2>/dev/null | zcat -f 2>/dev/null \
    || return 0
}

readable() { [ -r "$1" ]; }

list_crashes() {
  say "Queued crash reports in $CRASH_DIR"
  local found=0 f
  for f in "$CRASH_DIR"/*.crash; do
    [ -e "$f" ] || continue
    found=1
    local size date exe
    size=$(du -h "$f" 2>/dev/null | cut -f1)
    date=$(stat -c %y "$f" 2>/dev/null | cut -d. -f1)
    if readable "$f"; then
      exe=$(field_body "$f" ExecutablePath | head -1)
    else
      exe="(unreadable — run with sudo)"
    fi
    printf '    %-46s %6s  %s\n' "$(basename "$f")" "$size" "$date"
    printf '        %s\n' "${exe:-unknown}"
  done
  if [ "$found" -eq 0 ]; then
    ok "none — nothing for mintreport to nag about"
    return 0
  fi
  info ""
  info "Summarise:  $0 show          Delete all:  $0 clear"
}

summarise_one() {
  local f="$1"
  say "$(basename "$f")"

  if ! readable "$f"; then
    bad "not readable as $(id -un) — re-run with sudo"
    return 1
  fi

  local exe sig pkg date cmd
  exe=$(field_body "$f" ExecutablePath | head -1)
  sig=$(field_body "$f" Signal | head -1)
  pkg=$(field_body "$f" Package | head -1)
  date=$(field_body "$f" Date | head -1)
  cmd=$(field_body "$f" ProcCmdline | head -1)

  [ -n "$exe" ]  && info "executable  $exe"
  [ -n "$pkg" ]  && info "package     $pkg"
  [ -n "$date" ] && info "when        $date"
  [ -n "$cmd" ]  && info "cmdline     $(printf '%s' "$cmd" | cut -c1-100)"
  [ -n "$sig" ]  && info "signal      $sig — $(signal_meaning "$sig")"

  # Is the crashing package even installed any more? A report for something you
  # have since removed or replaced is not worth reading.
  if [ -n "$pkg" ]; then
    local pkgname; pkgname=${pkg%% *}
    if ! dpkg -l "$pkgname" 2>/dev/null | grep -q '^ii'; then
      warn "$pkgname is no longer installed — this report is moot"
    fi
  fi

  local st; st=$(field_decoded "$f" StacktraceTop)
  if [ -n "$st" ]; then
    info ""
    info "stack (top frames):"
    printf '%s\n' "$st" | head -8 | sed 's/^/      /'
  fi

  # An abort usually says why on its way out; a segfault usually does not. The
  # last (EE) lines are where that reason lands.
  local xl; xl=$(field_decoded "$f" XorgLog)
  if [ -n "$xl" ]; then
    local ee; ee=$(printf '%s\n' "$xl" | grep -E '\(EE\)' | tail -8)
    if [ -n "$ee" ]; then
      info ""
      info "Xorg errors (EE):"
      printf '%s\n' "$ee" | cut -c1-150 | sed 's/^/      /'
    fi
    info ""
    info "Xorg log, last lines:"
    printf '%s\n' "$xl" | tail -12 | cut -c1-150 | sed 's/^/      /'
  fi

  # Which video driver was actually in use, as opposed to merely probed.
  if [ -n "$xl" ]; then
    local ddx; ddx=$(printf '%s\n' "$xl" \
      | grep -oE 'Loading /usr/lib/xorg/modules/drivers/[a-z]+_drv\.so' \
      | grep -oE '[a-z]+_drv' | sort -u | tr '\n' ' ')
    [ -n "$ddx" ] && { info ""; info "video drivers loaded: $ddx"; }
  fi
}

cmd_show() {
  local target="${1:-}"
  if [ -n "$target" ]; then
    [ -f "$target" ] || target="$CRASH_DIR/$target"
    [ -f "$target" ] || die "No such crash file: $target"
    summarise_one "$target"
    return
  fi
  local found=0 f
  for f in "$CRASH_DIR"/*.crash; do
    [ -e "$f" ] || continue
    found=1
    summarise_one "$f"
  done
  [ "$found" -eq 1 ] || ok "no crash reports queued"
}

cmd_clear() {
  local files=() f
  for f in "$CRASH_DIR"/*.crash; do [ -e "$f" ] && files+=("$f"); done
  if [ "${#files[@]}" -eq 0 ]; then
    ok "nothing to clear"
    return 0
  fi

  say "About to delete ${#files[@]} crash report(s)"
  for f in "${files[@]}"; do
    printf '    %s  (%s)\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done
  info ""
  info "These are diagnostic data only — deleting them affects nothing except"
  info "stopping the mintreport popup. They cannot be recovered."

  if [ "$DRY_RUN" -eq 0 ]; then
    printf '    Type "yes" to delete: '
    local reply; read -r reply
    [ "$reply" = "yes" ] || { info "aborted, nothing deleted"; return 1; }
  fi

  local failed=0
  for f in "${files[@]}"; do
    run rm -f "$f" || failed=1
  done
  [ "$failed" -eq 0 ] && ok "cleared" || bad "some files could not be removed — try with sudo"
}

usage() {
  cat <<EOF

crash-report.sh — read the crash reports Mint nags about

  $0                  list queued reports
  $0 show             summarise every queued report
  $0 show <file>      summarise one
  $0 clear            delete them all (asks first)

  --dry-run           show what clear would do, change nothing

Run under sudo to read reports owned by other users (Xorg's are root-owned).

EOF
}

main() {
  local args=()
  for a in "$@"; do
    case "$a" in
      --dry-run) DRY_RUN=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *) args+=("$a") ;;
    esac
  done

  [ -d "$CRASH_DIR" ] || die "$CRASH_DIR does not exist."

  case "${args[0]:-list}" in
    list)  list_crashes ;;
    show)  cmd_show "${args[1]:-}" ;;
    clear) cmd_clear ;;
    *)     usage; die "Unknown command: ${args[0]}" ;;
  esac
}

main "$@"
