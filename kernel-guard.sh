#!/usr/bin/env bash
# kernel-guard.sh — refuse to let a kernel land quietly without its out-of-tree
#                   drivers built for it.
#
# THE PROBLEM
#   This machine has no Ethernet port. Wi-Fi is a BCM4360 that only works with
#   the proprietary `wl` module from broadcom-sta-dkms, so a kernel that
#   installs but whose wl build failed means: reboot, no network, no way to
#   fetch the fix. DKMS does report build failures during `apt upgrade`, but
#   they scroll past in the middle of hundreds of lines and are trivially
#   missed — and the consequence only shows up one reboot later.
#
#   So the check has to happen at upgrade time, loudly, while the machine is
#   still online and the old kernel is still running.
#
#   check         report every installed kernel and its drivers
#   install-hook  run that check automatically after every apt operation
#   remove-hook   undo it
#
# The hook never fails an apt run. A guard that can break package management on
# a machine you cannot easily recover is worse than the problem it guards.

set -uo pipefail

HOOK=/etc/apt/apt.conf.d/99-mba-kernel-guard
SELF_INSTALLED=/usr/local/bin/kernel-guard

# wl is the one that strands the machine. facetimehd is only the camera.
CRITICAL_MOD=broadcom-sta
OPTIONAL_MOD=facetimehd

DRY_RUN=0
QUIET=0
NOTIFY=0

say()  { [ "$QUIET" -eq 1 ] || printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { [ "$QUIET" -eq 1 ] || printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[warn]\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m[!!]\033[0m   %s\n' "$*"; }
info() { [ "$QUIET" -eq 1 ] || printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    \033[35m[dry]\033[0m  %s\n' "$*"
    return 0
  fi
  "$@"
}

# Kernels that are actually installed, newest last. Read from the package
# manager rather than /lib/modules, which keeps stale directories after a purge.
#
# The glob is 'linux-image-*', NOT 'linux-image-*-generic'. That narrower
# pattern was a real hole: a locally built kernel installs as something like
# linux-image-7.0.0-mba, so this function could not see it, and the guard
# cheerfully reported "every installed kernel has wifi" while the kernel GRUB
# was about to boot had no wl at all. Found on 2026-08-08 by installing exactly
# such a kernel -- a guard that is silently blind is worse than no guard,
# because it is believed.
#
# Widening the glob means meta-packages (linux-image-generic-hwe-24.04 and
# friends) come along too, so entries are kept only when a real module tree
# exists for them. That also drops packages whose /lib/modules has been removed,
# which cannot be booted anyway.
installed_kernels() {
  dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-*' 2>/dev/null \
    | awk '$2 ~ /^.i/ {print $1}' \
    | sed 's/^linux-image-//; s/^unsigned-//' \
    | while IFS= read -r rel; do
        [ -d "/lib/modules/$rel/kernel" ] && printf '%s\n' "$rel"
      done \
    | sort -V -u
}

# Process substitution, not a pipe: `dkms status | grep -q` returns 141 under
# pipefail when grep exits first and dkms takes SIGPIPE, which reads as "not
# built" on a machine where it is.
dkms_built_for() {
  local mod="$1" kver="$2" line
  while IFS= read -r line; do
    case "$line" in
      *", $kver, "*": installed"*) return 0 ;;
    esac
  done < <(dkms status "$mod" 2>/dev/null)
  return 1
}

has_headers() { [ -d "/lib/modules/$1/build" ]; }

# On a machine whose updates run through Mint's Update Manager rather than a
# terminal, hook output lands in a details pane nobody opens. A desktop
# notification is the only form the person at the keyboard will actually see.
# Best-effort throughout: never let a failure here affect the exit status.
notify_desktop() {
  [ "$NOTIFY" -eq 1 ] || return 0
  [ "$(id -u)" -eq 0 ] || return 0          # only meaningful when run from the hook
  command -v notify-send >/dev/null 2>&1 || return 0

  local title="$1" body="$2" user uid bus
  # The user owning the graphical session, not necessarily the one who ran sudo.
  user=$(loginctl list-sessions --no-legend 2>/dev/null \
         | awk '{print $3}' | while read -r u; do
             [ -n "$u" ] && [ -S "/run/user/$(id -u "$u" 2>/dev/null)/bus" ] && { echo "$u"; break; }
           done)
  [ -n "$user" ] || user=$(who 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$user" ] || return 0

  uid=$(id -u "$user" 2>/dev/null) || return 0
  bus="/run/user/$uid/bus"
  [ -S "$bus" ] || return 0

  runuser -u "$user" -- env \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      DISPLAY="${DISPLAY:-:0}" \
    notify-send -u critical -i dialog-error "$title" "$body" >/dev/null 2>&1 || true
}

# The banner and the notification, in one place, so that `test-alarm` fires the
# real thing rather than a lookalike. A drill that exercises a copy of the alarm
# proves only that the copy works.
critical_alarm() {
  local newest="$1" tag="${2:-}"
  local lines=(
    "DO NOT REBOOT YET"
    ""
    "The newest kernel has no wl module. This machine has no"
    "Ethernet port, so booting it means no network at all."
    ""
    "Fix it now, while you still have this session:"
    "  sudo dkms autoinstall -k $newest"
    "  sudo apt install --reinstall linux-headers-$newest"
    ""
    "Or boot the older kernel from the GRUB menu instead."
  )
  [ -n "$tag" ] && lines=("$tag" "" "${lines[@]}")

  # Keep every line above ASCII. ${#l} counts characters but printf's %-*s pads
  # by bytes, so one em-dash inside the box silently shortens that row by two
  # columns and the border stops lining up.
  #
  # Size the box from its longest line. The kernel version is interpolated and
  # its length varies, so any hardcoded width misaligns as soon as a version
  # string grows — which is exactly when this box is being read in a panic.
  local inner=0 l
  for l in "${lines[@]}"; do
    [ "${#l}" -gt "$inner" ] && inner="${#l}"
  done
  local rule; rule=$(printf '#%.0s' $(seq 1 $((inner + 6))))

  printf '\n\033[1;31m'
  printf '  %s\n' "$rule"
  for l in "${lines[@]}"; do
    printf '  #  %-*s  #\n' "$inner" "$l"
  done
  printf '  %s\n' "$rule"
  printf '\033[0m\n'

  local ntitle="Do not reboot yet"
  [ -n "$tag" ] && ntitle="[TEST] $ntitle"
  notify_desktop "$ntitle" \
    "The new kernel $newest has no Wi-Fi driver. Rebooting into it will leave this laptop with no network. Ask Joe before restarting."
}

# Fire the alarm deliberately. The alternative — actually removing a module to
# see what happens — means deliberately breaking Wi-Fi on a machine with no
# Ethernet port, which is a poor way to test a guard against losing Wi-Fi.
cmd_test_alarm() {
  local newest
  newest=$(installed_kernels | tail -1)
  [ -n "$newest" ] || newest="$(uname -r)"

  say "Firing the alarm as a drill — nothing is wrong with this machine"
  critical_alarm "$newest" "*** THIS IS A TEST - NOTHING IS ACTUALLY BROKEN ***"
  info "That is exactly what an upgrade would print, plus a desktop"
  info "notification if the hook was installed with --notify."
  info ""
  info "Real state:"
  QUIET=0 NOTIFY=0 cmd_check >/dev/null 2>&1
  case $? in
    0) ok "all kernels have both drivers — nothing to do" ;;
    1) warn "a non-critical gap exists; run '$0 check'" ;;
    2) bad "this machine really does have a missing wl — run '$0 check'" ;;
  esac
  return 0
}

cmd_check() {
  local kernels newest running problems=0 crit=0
  mapfile -t kernels < <(installed_kernels)
  [ "${#kernels[@]}" -gt 0 ] || { warn "no kernel packages found"; return 0; }
  newest="${kernels[-1]}"
  running=$(uname -r)

  say "Kernel driver check"

  local k mark
  for k in "${kernels[@]}"; do
    mark=""
    [ "$k" = "$running" ] && mark=" (running)"
    [ "$k" = "$newest" ] && mark="$mark (newest — next boot default)"

    local wl_ok=0 cam_ok=0
    dkms_built_for "$CRITICAL_MOD" "$k" && wl_ok=1
    dkms_built_for "$OPTIONAL_MOD" "$k" && cam_ok=1

    if [ "$wl_ok" -eq 1 ]; then
      ok "$k$mark — wifi ok$([ "$cam_ok" -eq 1 ] && echo ", camera ok" || echo ", camera MISSING")"
      [ "$cam_ok" -eq 0 ] && problems=$((problems + 1))
    else
      bad "$k$mark — NO wl MODULE"
      problems=$((problems + 1))
      [ "$k" = "$newest" ] && crit=1
      has_headers "$k" || info "        (no kernel headers installed — DKMS cannot build for it)"
    fi
  done

  if [ "$crit" -eq 1 ]; then
    critical_alarm "$newest" ""
    return 2
  fi

  if [ "$problems" -gt 0 ]; then
    info ""
    warn "$problems issue(s) above — none of them strand the machine."
    info "Camera only:  sudo ./mba-webcam.sh install"
    return 1
  fi

  info ""
  ok "every installed kernel has wifi and camera drivers"
  return 0
}

cmd_install_hook() {
  [ "$(id -u)" -eq 0 ] || die "Run with sudo to install the apt hook."
  # A machine updated through Mint's Update Manager rather than a terminal needs
  # the desktop notification, or the warning is written where nobody looks.
  local hook_args="check --quiet-ok"
  [ "$NOTIFY" -eq 1 ] && hook_args="check --quiet-ok --notify"
  # Always refresh, never "install only if absent". A stale copy at
  # $SELF_INSTALLED would accept newer flags like --notify and silently ignore
  # them, leaving a guard that looks installed and quietly does less than you
  # think — the worst failure mode available to a thing whose job is warning you.
  if [ -f "$SELF_INSTALLED" ] && cmp -s "$0" "$SELF_INSTALLED"; then
    ok "$SELF_INSTALLED already current"
  else
    run install -m 755 "$0" "$SELF_INSTALLED" || die "could not install to $SELF_INSTALLED"
    ok "installed $SELF_INSTALLED"
  fi

  say "Installing apt hook"
  # DPkg::Post-Invoke runs after dpkg has finished, so DKMS has already had its
  # chance to build. `|| true` is deliberate and load-bearing: apt aborts the
  # run on a failing hook, and breaking apt on a machine whose recovery path is
  # apt would be a strictly worse failure than the one being guarded against.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    \033[35m[dry]\033[0m  write %s\n' "$HOOK"
  else
    cat > "$HOOK" <<EOF
// Installed by kernel-guard.sh. After any apt operation, report whether every
// installed kernel has its out-of-tree drivers. Never fails the apt run.
DPkg::Post-Invoke { "if [ -x $SELF_INSTALLED ]; then $SELF_INSTALLED $hook_args || true; fi"; };
EOF
  fi
  ok "hook written to $HOOK"
  info "It runs after every apt operation and prints only when something is wrong."
  info "Remove with:  sudo $0 remove-hook"
}

cmd_remove_hook() {
  [ "$(id -u)" -eq 0 ] || die "Run with sudo to remove the apt hook."
  say "Removing apt hook"
  if [ -f "$HOOK" ]; then
    run rm -f "$HOOK" && ok "removed $HOOK"
  else
    ok "no hook installed"
  fi
  if [ -f "$SELF_INSTALLED" ]; then
    run rm -f "$SELF_INSTALLED" && ok "removed $SELF_INSTALLED"
  fi
}

# Boot a kernel ONCE, without making it the default.
#
# `check` proves a kernel's drivers were BUILT. That is not the same claim as
# "this kernel works" -- dkms can report a clean build for something that will
# not bring up the interface. A held fallback you have never booted is a belief.
# This is how one becomes evidence, and it is safe because it is one-shot: if the
# kernel fails, the next boot returns to the default with nothing to undo.
#
# WHY NUMERIC INDICES AND NOT TITLES
#
# `grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 6.17.0-42-generic"`
# was accepted silently, written to grubenv, and CONSUMED by grub at boot -- and
# still booted the default. Verified 2026-08-09: after that boot, grubenv held
# `next_entry=` (empty), so grub had read and cleared it, then failed to resolve
# the title path and fell back to entry 0. Numeric indices ("1>2") worked first
# try. So this builds the numeric path itself rather than trusting titles.
#
# THE CHECK THAT ACTUALLY DIAGNOSES IT
#
# Reading `grub-editenv list` BEFORE rebooting proves only that grub-reboot
# wrote the variable -- it says nothing about whether grub can resolve it. Read
# it AFTER the boot instead:
#
#   empty + you booted the kernel you asked for   -> worked
#   empty + you booted the default                -> grub consumed it and could
#                                                    not resolve it (this bug)
#   still set                                     -> grub never read grubenv at
#                                                    all, a different fault
grub_menu_path() {   # $1 = kernel version -> numeric "submenu>entry", or empty
  local want="$1" cfg=/boot/grub/grub.cfg
  [ -r "$cfg" ] || return 1
  awk -v want="$want" '
    /^[[:space:]]*submenu / { sub_i = top_i; top_i++; in_sub = 1; ent_i = 0; next }
    # Only an UNINDENTED brace closes the submenu. Every inner menuentry ends
    # with an indented "}" too, so matching any closing brace ends the submenu at
    # the first entry -- which silently yields a top-level index for a nested
    # kernel and boots the wrong thing.
    /^}[[:space:]]*$/ { in_sub = 0; next }
    /^[[:space:]]*menuentry / {
      # recovery entries are a different thing; never auto-target one
      if ($0 ~ /recovery mode/) { if (in_sub) ent_i++; else top_i++; next }
      if (in_sub) {
        if ($0 ~ ("Linux " want "(\\047| )")) { print sub_i ">" ent_i; exit }
        ent_i++
      } else {
        if ($0 ~ ("Linux " want "(\\047| )")) { print top_i; exit }
        top_i++
      }
    }
  ' "$cfg"
}

cmd_boot_test() {
  local want="${1:-}"
  if [ -z "$want" ]; then
    say "Kernels you could boot-test"
    local k
    for k in $(installed_kernels); do
      [ "$k" = "$(uname -r)" ] && info "$k  (running now)" || info "$k"
    done
    info ""
    info "Usage: sudo $0 boot-test <version>"
    return 0
  fi

  [ -d "/lib/modules/$want" ] || die "$want is not installed. '$0 check' lists what is."
  [ "$want" = "$(uname -r)" ] && die "$want is already running -- nothing to test."

  # Refusing to boot-test a kernel with no wl is the entire point of this script.
  if ! dkms_built_for broadcom-sta "$want"; then
    bad "$want has no wl module built."
    info "Booting it would leave this machine with no network, and Wi-Fi is the"
    info "only interface. Fix the build first: sudo dkms autoinstall -k $want"
    return 2
  fi

  local path; path=$(grub_menu_path "$want")
  [ -n "$path" ] || die "could not find $want in /boot/grub/grub.cfg (need root to read it?)"

  say "One-shot boot of $want"
  info "grub menu path: $path  (numeric -- titles do not reliably resolve)"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "would run: grub-reboot \"$path\""
    return 0
  fi
  [ "$(id -u)" = 0 ] || die "boot-test needs root. Try: sudo $0 boot-test $want"

  grub-reboot "$path" || die "grub-reboot failed"
  ok "armed: next boot only, then back to the default on its own"
  info ""
  info "  sudo reboot"
  info ""
  info "Afterwards, check BOTH of these -- the second is what diagnoses a miss:"
  info "  uname -r                 want $want"
  info "  grub-editenv list        empty next_entry = grub consumed it"
  info ""
  info "If you land on the default with next_entry empty, grub could not resolve"
  info "the path. If next_entry is still set, grub never read grubenv at all."
}

usage() {
  cat <<EOF

kernel-guard.sh — do not let a kernel land without its drivers

  $0 check           report every installed kernel and its drivers
  $0 check --quiet-ok  print nothing when everything is fine (used by the hook)
  sudo $0 install-hook run that check after every apt operation
  sudo $0 install-hook --notify
                       also raise a desktop notification, for a machine whose
                       updates run through the GUI rather than a terminal
  $0 test-alarm       fire the alarm as a drill, changing nothing
  $0 boot-test        list kernels you could boot-test
  sudo $0 boot-test VERSION
                       boot that kernel ONCE, then back to the default by itself.
                       'check' proves the drivers BUILT; this proves they work.
  sudo $0 remove-hook  undo it

  --dry-run          show what would change, change nothing

Exit: 0 all good, 1 non-critical gap (camera), 2 newest kernel has no wl.

EOF
}

main() {
  local args=()
  for a in "$@"; do
    case "$a" in
      --dry-run)  DRY_RUN=1 ;;
      --quiet-ok) QUIET=1 ;;
      --notify)   NOTIFY=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *) args+=("$a") ;;
    esac
  done

  case "${args[0]:-check}" in
    test-alarm)   cmd_test_alarm ;;
    boot-test)    cmd_boot_test "${args[1]:-}" ;;
    check)
      # --quiet-ok suppresses the ok path but never the warnings: the whole
      # point is that a problem is impossible to miss in apt's output.
      cmd_check ;;
    install-hook) cmd_install_hook ;;
    remove-hook)  cmd_remove_hook ;;
    *) usage; die "Unknown command: ${args[0]}" ;;
  esac
}

main "$@"
