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
installed_kernels() {
  dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-*-generic' 2>/dev/null \
    | awk '$2 ~ /^.i/ {print $1}' \
    | sed 's/^linux-image-//' \
    | sort -V
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
    # Size the box from its longest line. The kernel version is interpolated and
    # its length varies, so any hardcoded width misaligns as soon as a version
    # string grows — which is exactly when this box is being read in a panic.
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
  [ -f "$SELF_INSTALLED" ] || {
    info "installing $SELF_INSTALLED"
    run install -m 755 "$0" "$SELF_INSTALLED" || die "could not install to $SELF_INSTALLED"
  }

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
DPkg::Post-Invoke { "if [ -x $SELF_INSTALLED ]; then $SELF_INSTALLED check --quiet-ok || true; fi"; };
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

usage() {
  cat <<EOF

kernel-guard.sh — do not let a kernel land without its drivers

  $0 check           report every installed kernel and its drivers
  $0 check --quiet-ok  print nothing when everything is fine (used by the hook)
  sudo $0 install-hook run that check after every apt operation
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
      -h|--help|help) usage; exit 0 ;;
      *) args+=("$a") ;;
    esac
  done

  case "${args[0]:-check}" in
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
