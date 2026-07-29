#!/usr/bin/env bash
# mba-wifi.sh — Broadcom BCM4360 Wi-Fi survival tool for the 2014 MacBook Air
#               (MacBookAir6,1 / 6,2) on Linux Mint 22.x / Ubuntu 24.04 "noble".
#
# THE PROBLEM
#   These Airs use a BCM4360 [14e4:43a0] on Apple's proprietary connector, so the
#   card cannot be swapped. Its only working driver is `wl`, built by DKMS from
#   broadcom-sta-dkms — a shim wrapped around wlc_hybrid.o_shipped, a prebuilt
#   binary Broadcom froze in 2015. Kernel 7.x breaks it: the DKMS build fails
#   (objtool rejects the blob — Launchpad #2161038), and on at least one machine
#   booting 7.x with the driver enabled panicked until the driver was disabled.
#
#   Because these laptops have no Ethernet port, a broken `wl` means no network
#   at all — including no way to fetch the fix. That asymmetry is why this script
#   exists: it is far cheaper to stay off 7.x than to recover from it.
#
# WHAT IT DOES
#   Two modes in one file:
#     guard  — keep you off 7.x and able to recover        (safe, idempotent)
#     trial  — deliberately test 7.x with a full undo path (risky, opt-in)
#
# Run `mba-wifi.sh help` for the command list.

set -uo pipefail

VERSION="1.0"
STATE_DIR="/var/lib/mba-wifi"
BACKUP_DIR="$STATE_DIR/backup"
TRIAL_STATE="$STATE_DIR/trial.state"
PREF_FILE="/etc/apt/preferences.d/block-kernel-7.pref"
PREF_STASH="$STATE_DIR/block-kernel-7.pref.stashed"
GRUB_DEFAULT="/etc/default/grub"
GRUB_BACKUP="$STATE_DIR/grub.default.bak"
DKMS_CONF="/usr/src/broadcom-sta-6.30.223.271/dkms.conf"
DKMS_BACKUP="$STATE_DIR/dkms.conf.bak"
TRIAL_BLACKLIST="/etc/modprobe.d/zz-mba-trial-blacklist.conf"
ACCEPT_STATE="$STATE_DIR/accepted.state"

DRY_RUN=0

# ---------------------------------------------------------------- output
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[warn]\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m[!!]\033[0m   %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Every mutating action goes through run() so --dry-run is honest rather than
# a flag we remembered to check in some places and not others.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    \033[35m[dry]\033[0m  %s\n' "$*"
    return 0
  fi
  "$@"
}

need_root() {
  # --dry-run changes nothing, so let people preview without sudo.
  [ "$DRY_RUN" -eq 1 ] && { warn "dry-run: not root, showing what would happen"; return 0; }
  [ "$(id -u)" -eq 0 ] || die "'$1' needs root. Re-run with sudo."
}

# ---------------------------------------------------------------- detection
running_kernel()  { uname -r; }
kernel_major()    { uname -r | cut -d. -f1; }

wifi_pci_id() {
  command -v lspci >/dev/null 2>&1 || return 1
  lspci -nn 2>/dev/null | grep -oE '14e4:[0-9a-f]{4}' | grep -v '14e4:1570' | head -1
}

driver_in_use() {
  lspci -k 2>/dev/null | awk '/Network controller/{f=1} f&&/Kernel driver in use/{print $NF; exit}'
}

wl_module_path() { modinfo -n wl 2>/dev/null; }

# dpkg -l's first column is <desired><status>. Held packages read 'hi', not
# 'ii' — so matching '^ii' silently loses everything trial-accept holds, which
# is precisely the 6.x fallback and the driver. Match on the status char.
INSTALLED='^[ih]i'

pkg_installed() {
  [ -n "$(dpkg -l "$1" 2>/dev/null | grep "$INSTALLED")" ]
}

installed_7x_packages() {
  dpkg -l 2>/dev/null | awk '/^[ih]i/ && $2 ~ /^linux-(image|headers|modules|modules-extra|tools|image-unsigned)-7\./ {print $2}'
  dpkg -l 2>/dev/null | awk '/^[ih]i/ && $2 ~ /^linux-(image|headers|generic)-generic-hwe-/ {print $2}'
}

other_kernels() {
  dpkg -l 2>/dev/null | awk '/^[ih]i/ && $2 ~ /^linux-image-[0-9]/ {print $2}' \
    | sed 's/^linux-image-//' | grep -v "^$(running_kernel)$"
}

# Refuse to act on a machine this script was not written for. A friend's setup
# may have drifted; guessing on someone else's only laptop is not worth it.
verify_machine() {
  local strict="${1:-strict}" problems=0

  local id; id="$(wifi_pci_id)"
  case "$id" in
    14e4:43a0)
      ok "BCM4360 [$id] found — wl is the only working driver" ;;
    14e4:43a3)
      warn "This is a BCM4350 [$id], not a 4360."
      info "brcmfmac (in-tree) supports it. You do NOT need broadcom-sta at all,"
      info "and you are NOT affected by the 7.x problem. Nothing here applies."
      problems=$((problems+1)) ;;
    "")
      bad "No Broadcom wireless chip found (is lspci installed?)"
      problems=$((problems+1)) ;;
    *)
      bad "Unrecognised Broadcom wireless chip [$id] — this script targets 14e4:43a0"
      problems=$((problems+1)) ;;
  esac

  local codename=""
  [ -r /etc/os-release ] && codename="$(. /etc/os-release; echo "${UBUNTU_CODENAME:-}")"
  if [ "$codename" = "noble" ]; then
    ok "Ubuntu 24.04 'noble' base detected"
  else
    bad "Expected a noble (24.04) base, found '${codename:-unknown}'"
    problems=$((problems+1))
  fi

  if pkg_installed broadcom-sta-dkms; then
    ok "broadcom-sta-dkms is installed"
  else
    warn "broadcom-sta-dkms is NOT installed — Wi-Fi is presumably already down"
  fi

  if [ "$problems" -gt 0 ] && [ "$strict" = "strict" ]; then
    die "Machine did not verify ($problems problem(s)). Refusing to act.
     Run '$0 status' for detail. Nothing has been changed."
  fi
  return 0
}

# ---------------------------------------------------------------- status
cmd_status() {
  say "mba-wifi.sh v$VERSION — status"

  local kver; kver="$(running_kernel)"
  local kmaj; kmaj="$(kernel_major)"
  info "Kernel:        $kver"
  if [ "$kmaj" -ge 7 ]; then
    bad "You are running a 7.x kernel. This is the configuration known to break."
  else
    ok "Kernel major $kmaj — the supported range for this driver"
  fi

  say "Hardware"
  verify_machine lenient

  say "Driver"
  local drv; drv="$(driver_in_use)"
  if [ "$drv" = "wl" ]; then
    ok "wl is bound to the wireless card"
  elif [ -n "$drv" ]; then
    warn "Card is bound to '$drv', not wl"
  else
    bad "No driver bound to the wireless card"
  fi

  local mp; mp="$(wl_module_path)"
  if [ -n "$mp" ]; then
    ok "module present: $mp"
  else
    bad "no wl module built for $kver"
  fi

  # NB: piping into `grep -q` under `set -o pipefail` reports failure even on a
  # match, because grep exits early and the producer dies of SIGPIPE. Capture
  # the output instead. Same pattern applies everywhere below.
  if [ -n "$(lsmod 2>/dev/null | grep '^wl ')" ]; then
    ok "wl is loaded"
  else
    warn "wl is not currently loaded"
  fi

  if command -v dkms >/dev/null 2>&1; then
    local ds; ds="$(dkms status 2>/dev/null | grep broadcom-sta)"
    [ -n "$ds" ] && printf '%s\n' "$ds" | sed 's/^/    /' || warn "dkms knows nothing about broadcom-sta"
  fi

  say "7.x block"
  if [ -f "$PREF_FILE" ]; then
    ok "pin present: $PREF_FILE"
    if command -v apt-cache >/dev/null 2>&1; then
      # Prove it, rather than trusting the file's existence.
      local cand
      cand="$(apt-cache policy linux-image-generic-hwe-24.04 2>/dev/null | awk '/Candidate:/{print $2}')"
      if [ -n "$cand" ] && [ "$cand" != "(none)" ]; then
        local abi; abi="$(printf '%s' "$cand" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)\..*/\1/')"
        case "$abi" in
          7.*)
            local pol
            pol="$(apt-cache policy "linux-image-${abi}-generic" 2>/dev/null | awk '/Candidate:/{print $2}')"
            if [ "$pol" = "(none)" ]; then
              ok "verified: linux-image-${abi}-generic is not installable"
            else
              bad "pin exists but linux-image-${abi}-generic is still installable ($pol)"
            fi ;;
          *) info "current hwe candidate is $abi (not 7.x)" ;;
        esac
      fi
    fi
  else
    bad "NO pin — a routine apt upgrade can pull in a 7.x kernel"
  fi

  local holds; holds="$(apt-mark showhold 2>/dev/null)"
  if [ -n "$holds" ]; then
    info "apt holds: $(printf '%s' "$holds" | tr '\n' ' ')"
  else
    info "apt holds: none (note: holds do not survive purging the held package)"
  fi

  say "Recovery readiness"
  local others; others="$(other_kernels)"
  if [ -n "$others" ]; then
    ok "fallback kernel(s) installed: $(printf '%s' "$others" | tr '\n' ' ')"
  else
    bad "NO other kernel installed — you have nothing to fall back to"
  fi

  local style timeout
  style="$(awk -F= '/^GRUB_TIMEOUT_STYLE=/{print $2}' "$GRUB_DEFAULT" 2>/dev/null)"
  timeout="$(awk -F= '/^GRUB_TIMEOUT=/{print $2}' "$GRUB_DEFAULT" 2>/dev/null)"
  if [ "$style" = "menu" ] && [ "${timeout:-0}" -gt 0 ] 2>/dev/null; then
    ok "GRUB menu shows for ${timeout}s — you can pick the old kernel"
  else
    warn "GRUB menu is hidden (style=${style:-unset}, timeout=${timeout:-unset})"
    info "You would have to hold Shift/Esc at boot. Run 'protect' to fix."
  fi

  local nbackups=0
  [ -d "$BACKUP_DIR" ] && nbackups="$(find "$BACKUP_DIR" -name 'wl.ko*' 2>/dev/null | wc -l)"
  if [ "$nbackups" -gt 0 ]; then
    ok "$nbackups backed-up wl module(s) in $BACKUP_DIR"
  else
    warn "no module backup — run 'protect' while Wi-Fi still works"
  fi

  local tether=0
  for m in cdc_ncm rndis_host cdc_ether ipheth; do
    [ -n "$(find "/lib/modules/$kver" -name "$m.ko*" 2>/dev/null)" ] && tether=$((tether+1))
  done
  if [ "$tether" -ge 2 ]; then
    ok "$tether/4 USB tethering drivers present (in-tree — work on any kernel)"
  else
    warn "USB tethering drivers look incomplete; phone tethering may not save you"
  fi

  say "dkms.conf integrity"
  if [ -f "$DKMS_CONF" ]; then
    if grep -q 'objtool=/bin/true' "$DKMS_CONF" 2>/dev/null; then
      bad "objtool bypass is ACTIVE in dkms.conf"
      info "This affects EVERY future build, including working 6.x kernels."
      info "Run 'trial-revert' to undo it."
    else
      ok "no objtool bypass — builds are validated normally"
    fi
  else
    info "dkms.conf not found (driver source not installed)"
  fi

  if [ -f "$TRIAL_STATE" ]; then
    say "Trial in progress"
    sed 's/^/    /' "$TRIAL_STATE"
    info "Run 'trial-revert' to return to a known-good state."
  fi

  if [ -f "$ACCEPT_STATE" ]; then
    say "7.x accepted"
    sed 's/^/    /' "$ACCEPT_STATE"
    info "This machine is deliberately off the 6.x pin. The objtool bypass is"
    info "permanent and 7.x upgrades arrive unattended."
    info "Boot a 6.x kernel and run 'trial-revert' to undo all of it."
  fi

  # The pin, the bypass and the holds are all meant to be temporary. This block
  # exists so "has Ubuntu fixed it yet, and what do I type?" is a question the
  # script answers, rather than something to reconstruct from memory a year on.
  say "Official broadcom-sta fix"
  check_for_fix "$kmaj" "$kver"

  echo
}

# Read-only. Called from status; safe to run as a normal user.
check_for_fix() {
  local kmaj="$1" kver="$2"

  command -v apt-cache >/dev/null 2>&1 || { info "apt-cache unavailable — cannot check."; return 0; }

  # A stale package list is the main way this check quietly lies to you.
  local stamp="/var/lib/apt/periodic/update-success-stamp"
  [ -e "$stamp" ] || stamp="/var/lib/apt/lists"
  if [ -e "$stamp" ]; then
    local now mtime age
    now="$(date +%s)"
    mtime="$(stat -c %Y "$stamp" 2>/dev/null || echo "$now")"
    age=$(( (now - mtime) / 86400 ))
    if [ "$age" -le 7 ]; then
      ok "package lists are ${age}d old"
    else
      warn "package lists are ${age}d old — run 'sudo apt update' first or this check is meaningless"
    fi
  fi

  local inst cand
  inst="$(dpkg-query -W -f='${Version}' broadcom-sta-dkms 2>/dev/null)"
  cand="$(apt-cache policy broadcom-sta-dkms 2>/dev/null | awk '/Candidate:/{print $2}')"
  info "broadcom-sta-dkms installed: ${inst:-none}"
  info "broadcom-sta-dkms published: ${cand:-unknown}"

  local held=""
  [ -n "$(apt-mark showhold 2>/dev/null | grep '^broadcom-sta-dkms$')" ] && held=1
  if [ -n "$held" ]; then
    warn "broadcom-sta-dkms is HELD. 'apt upgrade' will file it under 'kept back'"
    info "rather than announcing a fix. That is expected — trial-accept set the hold."
  fi

  if [ -z "$inst" ] || [ -z "$cand" ] || [ "$cand" = "(none)" ]; then
    warn "cannot compare versions — check by hand with 'apt-cache policy broadcom-sta-dkms'"
    return 0
  fi

  if ! dpkg --compare-versions "$cand" gt "$inst" 2>/dev/null; then
    ok "no newer broadcom-sta-dkms than $inst has been published"
    info "Re-run '$0 status' after each 'sudo apt update' to check again."
    info "A fix could also arrive as a NEW 7.x kernel rather than a driver update,"
    info "so a fresh 7.x point release is worth a retrial even if this never moves."
    return 0
  fi

  bad "A NEWER broadcom-sta-dkms EXISTS: $inst -> $cand"
  info "This MIGHT be the 7.x fix, or it might be unrelated packaging. Confirm first:"
  info "    apt changelog broadcom-sta-dkms | head -40"
  info "Look for 7.x, objtool, or LP #2161038. If none of those appear, it is not"
  info "the fix and nothing below is urgent."
  echo

  if [ "$kmaj" -ge 7 ]; then
    info "YOU ARE ON 7.x AND IT IS WORKING. Do NOT run trial-revert — it would purge"
    info "this kernel and re-pin you. Take the update in place, one line at a time:"
    info "  1. sudo apt-mark unhold broadcom-sta-dkms"
    info "  2. sudo apt update && sudo apt upgrade"
    info "  3. grep MAKE /usr/src/broadcom-sta-*/dkms.conf"
    info "     (expect NO objtool=/bin/true — the package update should replace it)"
    info "  4. sudo dkms autoinstall -k $kver --force"
    info "     (rebuilds wl with validation back on)"
    info "  5. sudo reboot"
    echo
    info "After the reboot, Wi-Fi should associate on its own. If it does, run"
    info "'$0 status' again and confirm the bypass is gone."
    warn "If it does NOT come back: pick a 6.x kernel in GRUB, then '$0 trial-revert'."
    info "Leave the kernel holds in place either way — you still want a fallback."
  else
    info "YOU ARE ON 6.x WITH THE PIN IN PLACE. The fix cannot reach 7.x until you"
    info "lift the block, and a new kernel earns the full trial cycle, not a shortcut:"
    info "  1. sudo apt-mark unhold broadcom-sta-dkms"
    info "  2. sudo apt update && sudo apt upgrade"
    info "     (the driver fix lands on your 6.x kernel here — harmless)"
    info "  3. sudo $0 trial-prepare"
    info "     (backs up the working module and checks you have a way back online)"
    info "  4. sudo $0 trial-arm"
    info "     (lifts the pin, installs 7.x, blacklists wl for the first boot)"
    info "  5. sudo reboot, then choose the 7.x kernel in the GRUB menu"
    info "  6. sudo $0 trial-test"
    info "     (loads wl by hand — a panic would happen HERE, and is survivable)"
    info "  7. sudo $0 trial-accept"
    info "     (ONLY if step 6 worked. Then reboot once more to prove auto-load.)"
    echo
    warn "Do not skip trial-prepare. It is what makes the rest recoverable."
  fi
}

# ---------------------------------------------------------------- guard mode
cmd_protect() {
  need_root protect
  say "Protecting this machine from 7.x kernels"
  verify_machine strict

  run mkdir -p "$STATE_DIR" "$BACKUP_DIR"

  # 1. Back up the working module BEFORE touching anything else. If Wi-Fi is
  #    working right now, this file is the cheapest insurance available.
  local mp; mp="$(wl_module_path)"
  if [ -n "$mp" ] && [ -f "$mp" ]; then
    local dest="$BACKUP_DIR/$(basename "$mp").$(running_kernel)"
    if [ -f "$dest" ]; then
      ok "module already backed up: $dest"
    else
      run cp -a "$mp" "$dest" && ok "backed up working module -> $dest"
    fi
  else
    warn "no wl module to back up (nothing built for $(running_kernel))"
  fi

  # 2. The apt pin. Blocking linux-image-7.* also blocks the hwe metapackages
  #    transitively, because their dependency becomes uninstallable.
  if [ -f "$PREF_FILE" ]; then
    ok "7.x pin already present"
  else
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '    \033[35m[dry]\033[0m  write %s\n' "$PREF_FILE"
    else
      cat > "$PREF_FILE" <<'EOF'
# Block all 7.x kernel packages from ever being installed.
#
# The BCM4360 in the 2014 MacBook Air needs the proprietary `wl` module from
# broadcom-sta-dkms, which does not build on 7.x (Launchpad #2161038) and has
# been reported to panic at boot. This machine has no Ethernet port, so a
# broken wl means no network at all.
#
# The hwe metapackages are blocked transitively: they Depend: on one of these.
# Remove this file (or run `mba-wifi.sh unprotect`) to allow 7.x again.
Package: linux-image-7.* linux-headers-7.* linux-modules-7.* linux-modules-extra-7.* linux-image-unsigned-7.* linux-tools-7.* linux-hwe-7.*
Pin: release *
Pin-Priority: -1
EOF
      ok "wrote $PREF_FILE"
    fi
  fi

  # 3. Make the fallback reachable. A pin is useless if a friend still ends up
  #    on 7.x somehow and cannot get back to the old kernel.
  if [ -f "$GRUB_DEFAULT" ]; then
    [ -f "$GRUB_BACKUP" ] || run cp -a "$GRUB_DEFAULT" "$GRUB_BACKUP"
    local changed=0
    if grep -q '^GRUB_TIMEOUT_STYLE=' "$GRUB_DEFAULT"; then
      grep -q '^GRUB_TIMEOUT_STYLE=menu' "$GRUB_DEFAULT" || {
        run sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_DEFAULT"; changed=1; }
    else
      run bash -c "echo 'GRUB_TIMEOUT_STYLE=menu' >> '$GRUB_DEFAULT'"; changed=1
    fi
    local t; t="$(awk -F= '/^GRUB_TIMEOUT=/{print $2}' "$GRUB_DEFAULT")"
    if [ "${t:-0}" -lt 3 ] 2>/dev/null; then
      run sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$GRUB_DEFAULT"; changed=1
    fi
    if [ "$changed" -eq 1 ]; then
      run update-grub >/dev/null 2>&1 && ok "GRUB menu will now show for 5s (backup: $GRUB_BACKUP)"
    else
      ok "GRUB menu already reachable"
    fi
  fi

  say "Done"
  info "Run '$0 status' to confirm, and keep at least two kernels installed."
}

cmd_unprotect() {
  need_root unprotect
  say "Removing the 7.x block"
  if [ -f "$PREF_FILE" ]; then
    run rm -f "$PREF_FILE" && ok "removed $PREF_FILE"
    run apt-get update >/dev/null 2>&1 && ok "apt lists refreshed"
    warn "7.x kernels can now be installed by a routine upgrade."
    warn "On a BCM4360 machine that means losing Wi-Fi with no wired fallback."
  else
    ok "no pin present — nothing to remove"
  fi
}

cmd_restore() {
  need_root restore
  say "Restoring the Broadcom driver for $(running_kernel)"
  verify_machine lenient

  # Preferred path: let DKMS rebuild it properly.
  if pkg_installed broadcom-sta-dkms; then
    info "Rebuilding via DKMS..."
    run dkms autoinstall -k "$(running_kernel)" >/dev/null 2>&1
  else
    info "Reinstalling broadcom-sta-dkms..."
    run apt-get install -y --reinstall broadcom-sta-dkms >/dev/null 2>&1
  fi

  if [ -n "$(wl_module_path)" ]; then
    ok "module built: $(wl_module_path)"
  else
    warn "DKMS did not produce a module — falling back to the backup copy"
    local bk="$BACKUP_DIR/wl.ko.zst.$(running_kernel)"
    [ -f "$bk" ] || bk="$(find "$BACKUP_DIR" -name "wl.ko*.$(running_kernel)" 2>/dev/null | head -1)"
    if [ -n "$bk" ] && [ -f "$bk" ]; then
      run mkdir -p "/lib/modules/$(running_kernel)/updates/dkms"
      run cp -a "$bk" "/lib/modules/$(running_kernel)/updates/dkms/$(basename "${bk%.$(running_kernel)}")"
      run depmod -a && ok "restored module from backup"
    else
      bad "no backup for $(running_kernel) either"
      info "Tether via USB from your phone and run: apt install --reinstall broadcom-sta-dkms"
      return 1
    fi
  fi

  run modprobe wl 2>/dev/null && ok "wl loaded" || warn "modprobe wl failed — check 'dmesg | tail'"
}

# ---------------------------------------------------------------- trial mode
cmd_trial_prepare() {
  need_root trial-prepare
  say "Preparing for a 7.x trial"
  verify_machine strict

  local blockers=0

  [ -z "$(other_kernels)" ] && { bad "No fallback kernel installed."; blockers=$((blockers+1)); }

  cmd_protect   # backs up the module and fixes the GRUB menu; both are prerequisites

  local tether=0
  for m in cdc_ncm rndis_host ipheth; do
    [ -n "$(find "/lib/modules/$(running_kernel)" -name "$m.ko*" 2>/dev/null)" ] && tether=$((tether+1))
  done
  [ "$tether" -lt 2 ] && { warn "USB tethering drivers incomplete — no offline network fallback"; }

  say "Manual checks you must do yourself"
  info "1. Reboot once and confirm you SEE the GRUB menu and can pick the old kernel."
  info "2. Plug your phone in, enable USB tethering, confirm it appears as a network"
  info "   device. That is your only route back online if this goes wrong."
  info "3. Have anything unsaved committed or backed up. Panics are unclean shutdowns."

  if [ "$blockers" -gt 0 ]; then
    die "$blockers blocker(s) — fix them before 'trial-arm'."
  fi
  ok "Prepared. When ready: $0 trial-arm"
}

cmd_trial_arm() {
  need_root trial-arm
  say "Arming a 7.x trial — THIS IS THE RISKY PART"
  verify_machine strict

  [ -d "$BACKUP_DIR" ] || die "Run '$0 trial-prepare' first."
  [ -n "$(find "$BACKUP_DIR" -name 'wl.ko*' 2>/dev/null)" ] \
    || die "No module backup found. Run '$0 trial-prepare' first."

  cat <<'EOF'

    You are about to:
      - lift the 7.x apt block
      - install a 7.x kernel
      - patch dkms.conf with objtool=/bin/true (a GLOBAL change affecting
        every future build, including your working 6.x kernels)
      - blacklist wl at boot so the first 7.x boot cannot auto-load it

    Known risk: the driver may build and then panic the kernel on load.
    The objtool bypass only fixes compilation; it does not fix the panic.

    You can undo all of it with:  mba-wifi.sh trial-revert

EOF
  if [ "$DRY_RUN" -eq 0 ]; then
    printf '    Type exactly "I have a fallback kernel and a way back online": '
    local answer; read -r answer
    [ "$answer" = "I have a fallback kernel and a way back online" ] \
      || die "Not confirmed. Nothing changed."
  fi

  run mkdir -p "$STATE_DIR"
  {
    echo "started_kernel=$(running_kernel)"
    echo "started_at=$(date -Iseconds)"
  } > "$TRIAL_STATE" 2>/dev/null || true

  # 1. Stash the pin rather than deleting it, so revert is exact.
  if [ -f "$PREF_FILE" ]; then
    run cp -a "$PREF_FILE" "$PREF_STASH"
    run rm -f "$PREF_FILE"
    ok "7.x block lifted (stashed at $PREF_STASH)"
  fi
  run apt-get update >/dev/null 2>&1

  # 2. Patch dkms.conf, keeping a pristine copy.
  [ -f "$DKMS_CONF" ] || die "$DKMS_CONF not found — is broadcom-sta-dkms installed?"
  [ -f "$DKMS_BACKUP" ] || run cp -a "$DKMS_CONF" "$DKMS_BACKUP"
  if grep -q 'objtool=/bin/true' "$DKMS_CONF"; then
    ok "objtool bypass already present"
  else
    run sed -i 's|^\(MAKE\[0\]="make KVER=\$kernelver\)"|\1 objtool=/bin/true"|' "$DKMS_CONF"
    grep -q 'objtool=/bin/true' "$DKMS_CONF" \
      && ok "patched dkms.conf (pristine copy at $DKMS_BACKUP)" \
      || warn "could not patch dkms.conf automatically — edit MAKE[0] by hand"
  fi

  # 3. Block wl at boot. The first 7.x boot should prove the KERNEL boots before
  #    we ever let the module near it. Note this also stops wl auto-loading on
  #    6.x — use 'modprobe wl' by hand there, or run trial-revert.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    \033[35m[dry]\033[0m  write %s\n' "$TRIAL_BLACKLIST"
  else
    cat > "$TRIAL_BLACKLIST" <<'EOF'
# Temporary — written by mba-wifi.sh trial-arm.
# Keeps wl from auto-loading so a 7.x boot can be tested before the module is
# introduced. Removed by `mba-wifi.sh trial-revert`.
blacklist wl
EOF
    ok "wl blacklisted at boot (temporary)"
  fi

  # 4. Install the 7.x kernel.
  info "Installing the 7.x HWE kernel..."
  run apt-get install -y linux-image-generic-hwe-24.04 linux-headers-generic-hwe-24.04 >/dev/null 2>&1
  local newk; newk="$(dpkg -l 2>/dev/null | awk '/^[ih]i/ && $2 ~ /^linux-image-7\./ {print $2}' | sed 's/^linux-image-//' | tail -1)"
  if [ -n "$newk" ]; then
    ok "installed kernel $newk"
    echo "installed_kernel=$newk" >> "$TRIAL_STATE" 2>/dev/null || true
  else
    warn "no 7.x kernel appears installed — check apt output manually"
  fi

  run update-initramfs -u -k all >/dev/null 2>&1
  run update-grub >/dev/null 2>&1

  say "Armed"
  info "Reboot and pick the 7.x kernel from the GRUB menu."
  info "It should reach a desktop with NO Wi-Fi (wl is blacklisted)."
  info "Then run:  $0 trial-test"
  warn "If it panics before reaching the desktop, the kernel itself is the problem,"
  warn "not the driver. Reboot, pick $(running_kernel), and run '$0 trial-revert'."
}

cmd_trial_test() {
  need_root trial-test
  say "Testing wl on $(running_kernel)"

  [ "$(kernel_major)" -ge 7 ] \
    || die "You are on $(running_kernel), not a 7.x kernel. Reboot and select 7.x first."

  if [ -z "$(wl_module_path)" ]; then
    bad "No wl module was built for $(running_kernel)."
    info "The objtool bypass did not get the build through. That is the DKMS"
    info "failure, unrelated to the panic. Check:"
    info "  /var/lib/dkms/broadcom-sta/6.30.223.271/$(running_kernel)/x86_64/log/make.log"
    info "Nothing further to test. Run '$0 trial-revert' when you are back on 6.x."
    return 1
  fi
  ok "module exists: $(wl_module_path)"

  cat <<'EOF'

    About to `modprobe wl`. If this is what panics the machine, it will go
    down NOW and take anything unsaved with it. That is the expected way to
    find out, and it is recoverable: reboot, choose the 6.x kernel, run
    `mba-wifi.sh trial-revert`.

EOF
  if [ "$DRY_RUN" -eq 0 ]; then
    printf '    Type "load" to continue: '
    local answer; read -r answer
    [ "$answer" = "load" ] || die "Not confirmed. Nothing loaded."
  fi

  run sync   # flush the journal so any panic leaves as much evidence as possible
  run modprobe wl
  local rc=$?

  if [ "$rc" -eq 0 ] && [ -n "$(lsmod 2>/dev/null | grep '^wl ')" ]; then
    ok "wl loaded WITHOUT panicking on $(running_kernel)"
    info "Check whether it actually works: 'ip link' and 'nmcli device'."
    info "Report this — it would mean the objtool bypass is sufficient here."
    info "If Wi-Fi is genuinely up, '$0 trial-accept' keeps this kernel."
  else
    bad "modprobe wl failed (rc=$rc) but did not panic"
    info "Check 'dmesg | tail -30'."
  fi
}

cmd_trial_accept() {
  need_root trial-accept
  say "Accepting the 7.x trial"

  # Accept from the kernel being accepted. Un-blacklisting wl from 6.x would arm
  # the auto-load path for a 7.x boot that has never been proven.
  [ "$(kernel_major)" -ge 7 ] \
    || die "You are on $(running_kernel). Boot the 7.x kernel you want to keep and
     run this there — accepting from 6.x proves nothing about 7.x."

  # trial-test must actually have passed. A module sitting on disk unloaded is
  # exactly the state that panicked before, so its existence is not evidence.
  local mp; mp="$(wl_module_path)"
  [ -n "$mp" ] || die "No wl module built for $(running_kernel). Run '$0 trial-test' first."
  # Command substitution, not 'grep -q': with pipefail, grep -q exiting early
  # SIGPIPEs lsmod and the pipeline reports failure even on a match.
  if [ -z "$(lsmod 2>/dev/null | grep '^wl ')" ]; then
    die "wl is not loaded. Run '$0 trial-test' first and let it load the module —
     un-blacklisting an untested module just moves the panic to the next boot."
  fi
  ok "wl built and loaded on $(running_kernel): $mp"

  local drv; drv="$(driver_in_use)"
  if [ "$drv" = "wl" ]; then
    ok "wl is bound to the card"
  else
    warn "card reports driver '${drv:-none}' — the module loaded but may not be driving it"
  fi

  cat <<'EOF'

    You are about to keep 7.x. That means:
      - wl un-blacklisted, so the NEXT BOOT auto-loads it. That is the path
        that panicked before; trial-test only proved a manual load is safe.
      - objtool=/bin/true stays in dkms.conf PERMANENTLY, for every kernel
        including the 6.x fallbacks. Builds are no longer validated.
      - the 7.x apt block stays lifted, so future 7.x point releases arrive
        on their own and rebuild wl unattended. Each one is a fresh gamble.

    trial-revert stays available from a 6.x kernel and undoes all of it.

EOF
  if [ "$DRY_RUN" -eq 0 ]; then
    printf '    Type "keep 7.x" to continue: '
    local answer; read -r answer
    [ "$answer" = "keep 7.x" ] || die "Not confirmed. Nothing changed."
  fi

  # 1. Back up the module that just worked, before touching anything. Same
  #    reasoning as 'protect': this file is the cheapest insurance available.
  run mkdir -p "$BACKUP_DIR"
  local dest="$BACKUP_DIR/$(basename "$mp").$(running_kernel)"
  if [ -f "$dest" ]; then
    ok "module already backed up: $dest"
  else
    run cp -a "$mp" "$dest" && ok "backed up working 7.x module -> $dest"
  fi

  # 2. Un-blacklist, then rebuild the initramfs. update-initramfs copies
  #    /etc/modprobe.d into every image, so deleting the file is not enough —
  #    the old images would still block wl at early boot.
  if [ -f "$TRIAL_BLACKLIST" ]; then
    run rm -f "$TRIAL_BLACKLIST" && ok "wl un-blacklisted"
  else
    ok "no trial blacklist present"
  fi
  info "Rebuilding initramfs for all kernels..."
  run update-initramfs -u -k all >/dev/null 2>&1 && ok "initramfs rebuilt"

  # 3. Accepting 7.x is the moment autoremove becomes dangerous: it would
  #    happily take the only kernels this card is known to work with.
  local sixx holds
  sixx="$(dpkg -l 2>/dev/null \
    | awk '/^[ih]i/ && $2 ~ /^linux-(image|headers|modules|modules-extra)-(generic-)?6\./ {print $2}' \
    | tr '\n' ' ')"
  if [ -n "${sixx// /}" ]; then
    info "6.x fallback: $sixx"
  else
    warn "no 6.x kernel packages installed — you have NO fallback. Fix that first."
  fi

  # broadcom-sta-dkms too. Holding the kernels is not enough: a broadcom-sta-dkms
  # update rebuilds wl for EVERY installed kernel, which would quietly replace the
  # clean 6.x fallback modules with ones built through the objtool bypass. The
  # fallback is only worth holding if it stays the module that was known to work.
  holds="$sixx"
  if pkg_installed broadcom-sta-dkms; then
    holds="${holds}broadcom-sta-dkms "
    info "driver source: broadcom-sta-dkms (its updates rebuild wl for every kernel)"
  fi

  if [ -n "${holds// /}" ]; then
    run apt-mark hold $holds >/dev/null 2>&1 \
      && ok "held against autoremove and unattended rebuilds"
  fi

  # 4. The GRUB menu is the escape hatch if the auto-load boot panics.
  if [ -f "$GRUB_DEFAULT" ]; then
    local style t
    style="$(awk -F= '/^GRUB_TIMEOUT_STYLE=/{print $2}' "$GRUB_DEFAULT")"
    t="$(awk -F= '/^GRUB_TIMEOUT=/{print $2}' "$GRUB_DEFAULT")"
    if [ "$style" = "menu" ] && [ "${t:-0}" -ge 3 ] 2>/dev/null; then
      ok "GRUB menu shows for ${t}s — the 6.x fallback stays selectable"
    else
      warn "GRUB menu may not be visible (style='${style:-unset}' timeout='${t:-unset}')"
      info "'$0 protect' fixes it — but note that also reinstates the 7.x apt block."
    fi
  fi

  # 5. Record what was accepted, including the holds, so trial-revert can undo
  #    exactly what this command did. The pin stays stashed rather than deleted
  #    for the same reason.
  if [ "$DRY_RUN" -eq 0 ]; then
    {
      echo "accepted_kernel=$(running_kernel)"
      echo "accepted_at=$(date -Iseconds)"
      echo "objtool_bypass=permanent"
      echo "held=$holds"
    } > "$ACCEPT_STATE" 2>/dev/null || true
  fi
  run rm -f "$TRIAL_STATE"
  ok "trial state cleared"

  say "Accepted — one test left"
  info "Nothing has proven the BOOT-TIME load yet. Reboot now and let the machine"
  info "come up on $(running_kernel) untouched. If Wi-Fi associates on its own,"
  info "the trial is genuinely finished."
  warn "If it panics: hold Shift (or Esc) for the GRUB menu, pick a 6.x kernel, then"
  warn "  $0 trial-revert"
  [ -f "$PREF_STASH" ] && info "The apt pin is still stashed at $PREF_STASH, so revert stays exact."
}

cmd_trial_revert() {
  need_root trial-revert
  say "Reverting everything the trial changed"

  if [ "$(kernel_major)" -ge 7 ]; then
    die "You are running $(running_kernel). Reboot into a 6.x kernel first —
     this command purges 7.x kernels and will not remove the one you are on."
  fi

  # 1. dkms.conf back to pristine. This is the one that matters most: left in
  #    place it silently degrades every future build.
  if [ -f "$DKMS_BACKUP" ]; then
    run cp -a "$DKMS_BACKUP" "$DKMS_CONF" && ok "dkms.conf restored from $DKMS_BACKUP"
  elif [ -f "$DKMS_CONF" ] && grep -q 'objtool=/bin/true' "$DKMS_CONF"; then
    run sed -i 's| objtool=/bin/true||' "$DKMS_CONF" && ok "objtool bypass removed from dkms.conf"
  else
    ok "dkms.conf clean"
  fi

  # 2. Un-blacklist wl.
  if [ -f "$TRIAL_BLACKLIST" ]; then
    run rm -f "$TRIAL_BLACKLIST" && ok "wl un-blacklisted"
  fi

  # 3. Undo trial-accept, if it ran. Only the packages it recorded are unheld —
  #    holds you placed yourself are none of this script's business.
  if [ -f "$ACCEPT_STATE" ]; then
    local held; held="$(awk -F= '/^held=/{sub(/^held=/,""); print}' "$ACCEPT_STATE")"
    if [ -n "${held// /}" ]; then
      run apt-mark unhold $held >/dev/null 2>&1 && ok "released holds placed by trial-accept"
    fi
    run rm -f "$ACCEPT_STATE" && ok "acceptance record cleared"
  fi

  # 4. Purge 7.x kernels.
  local pkgs; pkgs="$(installed_7x_packages | tr '\n' ' ')"
  if [ -n "${pkgs// /}" ]; then
    info "Purging: $pkgs"
    run apt-get purge -y $pkgs >/dev/null 2>&1 && ok "7.x kernel packages purged"
    run apt-get autoremove -y >/dev/null 2>&1
  else
    ok "no 7.x kernel packages installed"
  fi

  # 5. Restore the pin.
  if [ -f "$PREF_STASH" ]; then
    run cp -a "$PREF_STASH" "$PREF_FILE" && ok "7.x block restored"
    run rm -f "$PREF_STASH"
  elif [ ! -f "$PREF_FILE" ]; then
    warn "no pin present — running 'protect' to reinstate it"
    cmd_protect
  else
    ok "7.x block already in place"
  fi

  # 6. Rebuild the driver for the kernel we are actually on.
  cmd_restore

  run update-grub >/dev/null 2>&1
  run rm -f "$TRIAL_STATE"
  run apt-get update >/dev/null 2>&1

  say "Reverted"
  info "Run '$0 status' to confirm you are back to a known-good state."
}

# ---------------------------------------------------------------- help
cmd_help() {
  cat <<EOF
mba-wifi.sh v$VERSION — BCM4360 Wi-Fi survival tool for the 2014 MacBook Air
                        (Linux Mint 22.x / Ubuntu 24.04 noble)

USAGE
  $0 [--dry-run] <command>

GUARD MODE — safe, idempotent, run these
  status        Report chip, driver, kernel, 7.x block, recovery readiness, and
                whether Ubuntu has published a broadcom-sta fix yet — including
                the exact commands to take it. Needs no root. Start here.
  protect       Back up the working wl module, install the 7.x apt block, and
                make the GRUB menu visible so a fallback kernel is selectable.
  restore       Rebuild or restore the driver after it has broken.
  unprotect     Remove the 7.x block. You almost certainly do not want this.

TRIAL MODE — risky, opt-in, for testing whether 7.x can be made to work
  trial-prepare Run every safety check and set up an undo path.
  trial-arm     Lift the block, install 7.x, apply the objtool bypass, and
                blacklist wl so the kernel can be tested before the module is.
  trial-test    (on 7.x) Load wl by hand and see whether it panics.
  trial-accept  (on 7.x, after trial-test passed) Keep 7.x: un-blacklist wl,
                rebuild the initramfs, and hold the 6.x fallback plus
                broadcom-sta-dkms so neither autoremove nor an unattended
                rebuild can spoil it. Makes the objtool bypass permanent.
  trial-revert  (on 6.x) Undo everything: dkms.conf, blacklist, holds, 7.x
                kernels, the block, and the driver itself.

FLAGS
  --dry-run     Print what would change without changing anything.

BACKGROUND
  The BCM4360 [14e4:43a0] is on Apple's proprietary connector and cannot be
  replaced. Its only driver is a shim around a binary Broadcom froze in 2015.
  Kernel 7.x breaks the build (Launchpad #2161038) and has been reported to
  panic at boot. These laptops have no Ethernet, so a broken driver means no
  network at all — keep a USB tether or a mt7921au/mt7612u stick handy.

  State and backups live in $STATE_DIR.
EOF
}

# ---------------------------------------------------------------- dispatch
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

case "${1:-help}" in
  status)        cmd_status ;;
  protect)       cmd_protect ;;
  unprotect)     cmd_unprotect ;;
  restore)       cmd_restore ;;
  trial-prepare) cmd_trial_prepare ;;
  trial-arm)     cmd_trial_arm ;;
  trial-test)    cmd_trial_test ;;
  trial-accept)  cmd_trial_accept ;;
  trial-revert)  cmd_trial_revert ;;
  help|-h|--help) cmd_help ;;
  *) printf 'Unknown command: %s\n\n' "$1"; cmd_help; exit 1 ;;
esac
