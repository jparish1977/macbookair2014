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

# Description only — the name is printed separately, from apport's SignalName
# where it has one, so returning it here too just stutters.
signal_meaning() {
  case "${1:-}" in
    4)  echo "illegal instruction" ;;
    6)  echo "abort, from a failed assertion or another fatal path" ;;
    7)  echo "bad memory alignment or bad hardware access" ;;
    8)  echo "arithmetic fault" ;;
    11) echo "segfault, invalid memory access" ;;
    "") echo "(no Signal field — may not be a crash report)" ;;
    *)  echo "unrecognised signal" ;;
  esac
}

signal_name() {
  case "${1:-}" in
    4) echo SIGILL ;; 6) echo SIGABRT ;; 7) echo SIGBUS ;;
    8) echo SIGFPE ;; 11) echo SIGSEGV ;; *) echo "" ;;
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

# apport keeps ONE report per program: every crash after the first is dropped
# with "already exists and unseen, skipping to avoid disk usage DoS". So a
# .crash file cannot tell you how many times the thing actually crashed — that
# count exists only in apport's own log. It matters. One abort is a curiosity;
# two aborts seven seconds apart is a retry loop, and says the first crash did
# not stop whatever was driving it.
crash_history() {
  local f="$1" exe="$2"
  [ -n "$exe" ] || return 0
  [ -r /var/log/apport.log ] || return 0

  # One glob, and zcat -f, so the rotated .gz and the plain files are read
  # alike. Two globs would double-count apport.log.2.gz.
  local all; all=$(zcat -f /var/log/apport.log* 2>/dev/null || true)
  [ -n "$all" ] || return 0

  # The trailing space keeps this on the path and off the "(command line ...)".
  local seen; seen=$(grep -F "executable: $exe " <<< "$all" || true)
  [ -n "$seen" ] || return 0

  local n; n=$(grep -c . <<< "$seen")
  # Sorted, not head/tail: the glob yields apport.log before apport.log.1, which
  # is newest-first, so the file order is not time order. Lexical sort is right
  # for "YYYY-MM-DD HH:MM:SS".
  local stamps; stamps=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' <<< "$seen" | sort)

  info ""
  if [ "$n" -le 1 ]; then
    info "apport log  1 crash of this program on record ($(head -1 <<< "$stamps"))"
    return 0
  fi
  info "apport log  $n crashes of this program on record,"
  info "            $(head -1 <<< "$stamps")  ..  $(tail -1 <<< "$stamps")"
  # Drops are logged against the report FILENAME, and one program crashing under
  # two users writes two of them — foo.0.crash and foo.1000.crash. Matching this
  # one file would silently miss every crash dropped against the other name,
  # which is exactly the case here: gufw's root abort and yours share a program
  # but not a report. Match the stem, so the count means "crashes of this
  # program that left no report" rather than "...that collided with this file".
  local stem; stem=$(basename "$f"); stem=${stem%.crash}; stem=${stem%.*}
  local dropped; dropped=$(grep -F 'already exists' <<< "$all" | grep -cF "/$stem." || true)
  [ "${dropped:-0}" -gt 0 ] && \
    info "            $dropped of them left no report — apport keeps the first per user"
  return 0
}

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

  # apport encodes the crashing uid in the filename: foo.0.crash is root's,
  # foo.1000.crash is yours. Not a detail — a helper that aborts only under root
  # is usually one hitting a cold cache in an empty /root, which is a different
  # fault from the same helper aborting inside your session.
  local uid; uid=$(basename "$f"); uid=${uid%.crash}; uid=${uid##*.}
  case "$uid" in
    0)      info "crashed as  root (uid 0)" ;;
    [0-9]*) info "crashed as  $(id -nu "$uid" 2>/dev/null || echo "uid $uid")" ;;
  esac

  [ -n "$exe" ]  && info "executable  $exe"
  # Plenty of reports carry no Package field at all, and then the "no longer
  # installed" check below silently does nothing and looks like a pass. Ask dpkg
  # who owns the binary instead.
  if [ -z "$pkg" ] && [ -n "$exe" ]; then
    pkg=$(dpkg -S "$exe" 2>/dev/null | head -1 | cut -d: -f1)
    [ -n "$pkg" ] && pkg="$pkg  (from dpkg -S — the report has no Package field)"
  fi
  [ -n "$pkg" ]  && info "package     $pkg"
  [ -n "$date" ] && info "when        $date"
  # Wrapped, not truncated. In a helper-process crash the decisive clue is
  # usually the TAIL of argv — gst-plugin-scanner's "-l .../WebKitNetworkProcess"
  # named the parent application, and sat past character 100 of a cut -c1-100.
  if [ -n "$cmd" ]; then
    local first=1 line
    while IFS= read -r line; do
      if [ "$first" -eq 1 ]; then info "cmdline     $line"; first=0
      else                        info "            $line"; fi
    done < <(printf '%s\n' "$cmd" | fold -s -w 62)
  fi

  # Pid and parent pid are how you tie the crash back to an application: syslog
  # and dbus-daemon lines carry pids, so grepping these two numbers in
  # /var/log/syslog is usually what names whatever spawned a helper like this.
  local cpid ppid status
  status=$(field_body "$f" ProcStatus)
  cpid=$(awk '$1=="Pid:"{print $2; exit}'  <<< "$status")
  ppid=$(awk '$1=="PPid:"{print $2; exit}' <<< "$status")
  if [ -n "$cpid" ] || [ -n "$ppid" ]; then
    info "pid         ${cpid:-?} (parent ${ppid:-?}) — grep both in /var/log/syslog"
  fi
  # apport usually records SignalName too; prefer it over guessing from the
  # number, and fall back to the table when it is absent.
  local signame; signame=$(field_body "$f" SignalName | head -1)
  [ -n "$signame" ] || signame=$(signal_name "$sig")
  if [ -n "$sig" ]; then
    if [ -n "$signame" ]; then
      info "signal      $sig ($signame) — $(signal_meaning "$sig")"
    else
      info "signal      $sig — $(signal_meaning "$sig")"
    fi
  fi

  # When apport catches the assertion text, it is usually the entire answer —
  # file, line and condition, no retracing required.
  local am; am=$(field_decoded "$f" AssertionMessage)
  if [ -n "$am" ]; then
    info ""
    info "assertion:"
    printf '%s\n' "$am" | head -4 | cut -c1-150 | sed 's/^/      /'
  elif [ "$sig" = "6" ]; then
    # An abort with no AssertionMessage looks like a dead end and is not one --
    # but do not promise it is an assert, because signal 6 only ever means
    # "something reached abort()". This machine has produced both kinds: the
    # gst-plugin-scanner abort WAS a failed assert whose message went to stderr,
    # while the Xorg one was FatalError -> OsAbort -> abort after a fatal signal
    # arrived inside modesetting_drv.so, where re-running it prints nothing.
    info ""
    info "no assertion text. Signal 6 only means something reached abort():"
    info "a failed assert, a fortify or malloc check, an uncaught C++"
    info "exception, a fatal-error handler (Xorg's does this), or a SIGABRT"
    info "sent from outside. If it was an assert, the message went to stderr,"
    info "which apport does not capture from a crashed child — re-running the"
    info "program in a terminal prints it, faster than retracing the core."
  fi

  crash_history "$f" "$exe"

  # Is the crashing package even installed any more? A report for something you
  # have since removed or replaced is not worth reading.
  if [ -n "$pkg" ]; then
    local pkgname; pkgname=${pkg%% *}
    # Captured, not piped: dpkg -l writes a header plus wrapped description
    # text, so grep -q exits early and SIGPIPEs it under pipefail. See lint.sh.
    if ! grep -q '^ii' <<< "$(dpkg -l "$pkgname" 2>/dev/null)"; then
      warn "$pkgname is no longer installed — this report is moot"
    fi
  fi

  local st; st=$(field_decoded "$f" StacktraceTop)
  if [ -n "$st" ]; then
    info ""
    info "stack (top frames):"
    printf '%s\n' "$st" | head -8 | sed 's/^/      /'
  elif grep -qa '^CoreDump:' "$f"; then
    # Not a gap in this script: apport writes the raw core at crash time and
    # only produces a symbolised stack when the report is retraced. An untouched
    # .crash therefore never has one. Say so, rather than printing nothing and
    # looking broken.
    info ""
    info "stack        not present — apport stores only the raw CoreDump until"
    info "             the report is retraced. To symbolise it:"
    info "               sudo apt install apport-retrace"
    info "               sudo apport-retrace -g $f"
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
  elif [ "$(field_body "$f" SourcePackage | head -1)" = "xorg-server" ]; then
    info ""
    info "no XorgLog captured — apport's Xorg hook did not run, so which video"
    info "driver was loaded cannot be recovered from this report."
  fi

  # What kernel it happened under. On a machine that keeps an experimental
  # kernel around, "which kernel" is often the whole answer.
  # "Uname: Linux 7.0.0-28-generic x86_64" — the release is field 2. Field 3 is
  # the architecture, which is not a kernel version and reads as nonsense.
  local un; un=$(field_body "$f" Uname | head -1)
  if [ -n "$un" ]; then
    local kv; kv=$(printf '%s' "$un" | awk '{print $2}')
    case "$kv" in
      *.*)
        if [ "$kv" != "$(uname -r)" ]; then
          info ""
          info "crashed under $kv — not the kernel you are on now ($(uname -r))"
        fi
        ;;
    esac
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
