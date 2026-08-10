#!/usr/bin/env bash
# mba-webcam.sh — FaceTime HD camera enabler for the 2014 MacBook Air
#                 (MacBookAir6,1 / 6,2) on Linux Mint 22.x / Ubuntu 24.04.
#
# THE PROBLEM
#   The camera in these Airs is a Broadcom 1570 [14e4:1570] sitting on the PCIe
#   bus, not a USB device. `uvcvideo` will never enumerate it, which is why a
#   stock install has no /dev/video* at all — nothing is broken, there simply is
#   no in-tree driver. The only one that works is `facetimehd`, an out-of-tree
#   module, and it needs a firmware blob that Apple ships only inside macOS.
#
#   Kernel 7.x removed the vb2_ops wait_prepare/wait_finish callbacks, which
#   broke every facetimehd release before 0.7.0.1. This script pins 0.7.0.2 for
#   exactly that reason — do not "upgrade" the pin to an older tag.
#
# WHAT IT DOES
#   1. Extracts firmware.bin from Apple's CDN. This is a ~2.8MB HTTP *range*
#      request into a 10.11.5 update image, not a full download — deliberate,
#      because this machine has 4GB of RAM and a small SSD.
#   2. Builds the driver under DKMS so a kernel upgrade rebuilds it, the same
#      way broadcom-sta already survives upgrades here. Nothing else on this
#      laptop is touched.
#
# Unlike Wi-Fi, a broken camera cannot strand this machine offline, so this
# script is far less defensive than mba-wifi.sh. `uninstall` is a full undo.
#
# Run `mba-webcam.sh help` for the command list.

set -uo pipefail

# --image: build into a DISK bound for a MacBookAir6,x, from a machine that is
# not one.
#
# The two things that persist -- the extracted firmware and the DKMS driver --
# neither needs the camera present. The firmware is carved out of an Apple driver
# package fetched over the network, not read off the device. What genuinely
# cannot happen here is binding the module to hardware that is absent, so
# preflight and the modprobe are skipped and everything else runs unchanged.
#
# The preflight itself stays exactly as strict for normal use: on a real machine,
# "no [PCI id] device" means this is the wrong script and saying so is the point.
IMAGE=0
for _a in "$@"; do [ "$_a" = "--image" ] && IMAGE=1; done

VERSION="1.0"

DRIVER_VER="0.7.0.2"                 # first tag that builds on kernel 7.x
DRIVER_REPO="https://github.com/patjak/facetimehd.git"
FIRMWARE_REPO="https://github.com/patjak/facetimehd-firmware.git"

PKG="facetimehd"
CAM_PCI_ID="14e4:1570"
MODLOAD="/etc/modules-load.d/facetimehd.conf"
BLACKLIST="/etc/modprobe.d/zz-mba-webcam-blacklist.conf"
TUNE_RULE="/etc/udev/rules.d/99-mba-webcam-tune.rules"

DRY_RUN=0
BUILD_DIR=""
TUNE_ARGS=()
TUNE_PERSIST=1
TUNE_RESET=0

# ---------------------------------------------------------------- output
say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m[ok]\033[0m   %s\n' "$*"; }
warn() { printf '    \033[33m[warn]\033[0m %s\n' "$*"; }
bad()  { printf '    \033[31m[!!]\033[0m   %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Same contract as mba-wifi.sh: every mutating action goes through run(), so
# --dry-run is structurally honest rather than dependent on remembering to
# check a flag at each call site.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    \033[35m[dry]\033[0m  %s\n' "$*"
    return 0
  fi
  "$@"
}

need_root() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  [ "$(id -u)" -eq 0 ] || die "Run with sudo (or pass --dry-run to preview)."
}

cleanup() {
  [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ] && rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- helpers

# The firmware Makefile installs to whichever base dir already exists, so we
# have to resolve it the same way rather than hardcoding /lib/firmware.
firmware_dir() {
  if [ -d /lib/firmware ]; then echo /lib/firmware
  else echo /usr/lib/firmware
  fi
}

firmware_file() { echo "$(firmware_dir)/$PKG/firmware.bin"; }

# NOTE: do not write these as `cmd | grep -q ...`. `grep -q` exits on the first
# match, the upstream command dies of SIGPIPE (141), and `set -o pipefail` turns
# that into a false negative — which made status report "not loaded" for a
# module that was loaded, and would make preflight abort on a machine that does
# have the camera. Both checks below are pipe-free on purpose.
have_camera() {
  local out; out=$(lspci -nn 2>/dev/null) || return 1
  case "${out,,}" in *"${CAM_PCI_ID,,}"*) return 0 ;; *) return 1 ;; esac
}

module_loaded() { [ -d "/sys/module/$PKG" ]; }

# The camera does NOT reliably land on /dev/video0 — on this machine it comes up
# as video1 (sysfs index 0) because other drivers claim lower minors first.
# Resolve it by asking sysfs which node facetimehd owns, never by guessing.
camera_node() {
  local d n
  for d in /sys/class/video4linux/video*; do
    [ -e "$d" ] || continue
    [ "$(basename "$(readlink -f "$d/device/driver" 2>/dev/null)" 2>/dev/null)" = "$PKG" ] || continue
    n="/dev/$(basename "$d")"
    # Skip metadata/output nodes: only capture nodes can produce frames.
    [ -c "$n" ] && { echo "$n"; return 0; }
  done
  return 1
}

# DKMS keys off PACKAGE_VERSION inside dkms.conf, which upstream does not
# reliably bump in lockstep with the git tag (master still reads 0.7.0.1 while
# 0.7.0.2 is released). Read it from the checkout instead of assuming the tag,
# or `dkms add` fails on a source-tree name mismatch.
dkms_version_from() {
  local conf="$1" v=""
  v=$(grep -oP '^PACKAGE_VERSION=\K.*' "$conf" 2>/dev/null | tr -d '"'"'")
  [ -n "$v" ] && echo "$v" || echo "$DRIVER_VER"
}

# The driver registers exactly these five (fthd_v4l2.c:707-717), all 0-255 with
# a 0x80 default except AWB which is a 0/1 boolean. There is deliberately no
# exposure or gain here: the driver never registers them, so no amount of
# tuning can lengthen sensor integration time.
# The kernel constant is V4L2_CID_AUTO_WHITE_BALANCE, but v4l2-ctl only answers
# to the userspace name `white_balance_automatic` -- passing the kernel spelling
# fails with "unknown control". Accept both and normalise to what the tool takes.
ctrl_canon() {
  case "$1" in
    auto_white_balance|white_balance_automatic) echo white_balance_automatic ;;
    *)                                          echo "$1" ;;
  esac
}

ctrl_max() {
  case "$(ctrl_canon "$1")" in
    white_balance_automatic)            echo 1 ;;
    brightness|contrast|saturation|hue) echo 255 ;;
    *)                                  return 1 ;;
  esac
}

ctrl_default() {
  case "$(ctrl_canon "$1")" in
    white_balance_automatic) echo 1 ;;
    *)                       echo 128 ;;
  esac
}

CTRL_NAMES="brightness contrast saturation hue white_balance_automatic"

installed_dkms_version() {
  dkms status "$PKG" 2>/dev/null | head -1 | sed 's#^'"$PKG"'[/,] *##; s#[,/].*##'
}

# DKMS state is per kernel: a module built under 7.0.0-28 does nothing when you
# boot 6.17.0-41. Registration alone therefore proves nothing about the running
# kernel — booting an older entry from the grub menu leaves the package fully
# registered with no module built for the kernel actually running. Read the
# status line for this kernel specifically.
#
# Process substitution rather than a pipe, for the same reason the other status
# helpers avoid one: `dkms status | grep -q` returns 141 under pipefail when
# grep exits first, which reads as "not built" on a machine where it is.
dkms_built_for() {
  local kver="$1" line
  while IFS= read -r line; do
    case "$line" in
      *", $kver, "*": installed"*) return 0 ;;
    esac
  done < <(dkms status "$PKG" 2>/dev/null)
  return 1
}

# ---------------------------------------------------------------- preflight
preflight() {
  say "Preflight"

  if have_camera; then
    ok "FaceTime HD camera present  ($(lspci -nn | grep -i "$CAM_PCI_ID" | cut -c1-60))"
  else
    bad "No [$CAM_PCI_ID] device on the PCI bus."
    info "This script is only for the Broadcom PCIe FaceTime HD camera."
    info "A USB webcam needs no driver work — it would already show as /dev/video0."
    die "Camera not found."
  fi

  local kver missing=()
  kver=$(uname -r)
  if [ -d "/lib/modules/$kver/build" ]; then
    ok "kernel headers present for $kver"
  else
    bad "No kernel headers for $kver — DKMS cannot build."
    info "Fix:  sudo apt install linux-headers-$kver"
    die "Missing kernel headers."
  fi

  # curl/xzcat/cpio are the firmware extractor's own declared prerequisites.
  for c in git make gcc dkms curl xzcat cpio lspci; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    bad "Missing tools: ${missing[*]}"
    info "Fix:  sudo apt install git build-essential dkms curl xz-utils cpio pciutils"
    die "Unmet build dependencies."
  fi
  ok "build toolchain complete (git, make, gcc, dkms, curl, xzcat, cpio)"

  case "$kver" in
    [1-3].*) warn "kernel $kver is older than 4.4; facetimehd will not work" ;;
  esac
}

# ---------------------------------------------------------------- firmware
install_firmware() {
  say "1/3  Firmware"

  local fw; fw=$(firmware_file)
  if [ -s "$fw" ]; then
    ok "already present: $fw ($(du -h "$fw" 2>/dev/null | cut -f1))"
    return 0
  fi

  # A local copy first, if one has been vaulted.
  #
  # WHY: the fetch below is a byte-range request into a 2016 macOS update image
  # on Apple's CDN. The failure text a few lines down already says what usually
  # goes wrong -- "Apple rotating the CDN URL baked into the Makefile" -- so this
  # is a known-perishable dependency, not a hypothetical one. Same reasoning as
  # vaulting the u810 recovery media: what gets lost is never the part you
  # thought was hard.
  #
  # THE CHECKSUM IS THE POINT, not the copy. An unverified cache is a way to
  # install a wrong or tampered blob everywhere at once, quietly -- so a cache
  # that does not match is IGNORED rather than trusted, and the network fetch
  # still happens. Set MBA_FW_SHA256 to pin a different blob deliberately.
  #
  # MBA_FW_CACHE takes a path or a URL. Deliberately NOT defaulted to anything:
  # this repo is public, the blob is Apple's, and a default pointing at somebody
  # else's host would be inviting exactly the redistribution problem that makes
  # upstream ship an extractor instead of the firmware.
  local want="${MBA_FW_SHA256:-e3e6034a67dfdaa27672dd547698bbc5b33f47f1fc7f5572a2fb68ea09d32d3d}"
  if [ -n "${MBA_FW_CACHE:-}" ]; then
    say "1/3  Firmware (cache)"
    local tmp; tmp=$(mktemp /tmp/mba-fw.XXXXXX)
    local got=""
    case "$MBA_FW_CACHE" in
      http://*|https://*) curl -fsS --max-time 60 -o "$tmp" "$MBA_FW_CACHE" 2>/dev/null || true ;;
      *)                  cp "$MBA_FW_CACHE" "$tmp" 2>/dev/null || true ;;
    esac
    [ -s "$tmp" ] && got=$(sha256sum "$tmp" | cut -d' ' -f1)
    if [ -n "$got" ] && [ "$got" = "$want" ]; then
      run install -d "$(firmware_dir)/$PKG"
      run install -m 0644 "$tmp" "$fw"
      rm -f "$tmp"
      ok "installed from cache, sha256 verified"
      info "no network needed for the firmware -- $MBA_FW_CACHE"
      return 0
    fi
    rm -f "$tmp"
    if [ -n "$got" ]; then
      warn "cache checksum MISMATCH -- ignoring it and fetching from Apple"
      info "  wanted $want"
      info "  got    $got"
    else
      warn "cache unreadable ($MBA_FW_CACHE) -- falling back to the network"
    fi
  fi

  info "Fetching ~2.8MB byte range from Apple's CDN (not the whole image)..."
  BUILD_DIR=$(mktemp -d /tmp/mba-webcam.XXXXXX) || die "Cannot create temp dir."

  if [ "$DRY_RUN" -eq 1 ]; then
    run git clone --depth 1 "$FIRMWARE_REPO" "$BUILD_DIR/firmware"
    run make -C "$BUILD_DIR/firmware"
    run make -C "$BUILD_DIR/firmware" install
    return 0
  fi

  git clone --depth 1 "$FIRMWARE_REPO" "$BUILD_DIR/firmware" >/dev/null 2>&1 \
    || die "Could not clone the firmware repo — check network access."

  if ! make -C "$BUILD_DIR/firmware" >/dev/null 2>&1; then
    bad "Firmware extraction failed."
    info "The usual cause is Apple rotating the CDN URL baked into the Makefile."
    info "Check upstream:  https://github.com/patjak/facetimehd-firmware/issues"
    info "Alternative: extract from any macOS install/recovery image on hand —"
    info "the blob lives in AppleCameraInterface inside the kext cache."
    die "Cannot obtain firmware.bin."
  fi

  make -C "$BUILD_DIR/firmware" install >/dev/null 2>&1 \
    || die "Firmware built but could not be installed to $(firmware_dir)."

  [ -s "$fw" ] || die "Firmware install reported success but $fw is missing."
  ok "installed $fw ($(du -h "$fw" | cut -f1))"
}

# ---------------------------------------------------------------- driver
install_driver() {
  say "2/3  Driver (DKMS)"

  local kver; kver=$(uname -r)

  local existing; existing=$(installed_dkms_version)
  if [ -n "$existing" ]; then
    if dkms_built_for "$kver"; then
      ok "$PKG $existing already built for $kver"
      info "Use 'uninstall' first if you want to rebuild from scratch."
      return 0
    fi

    # Registered under a different kernel — the usual case after booting an
    # older entry from grub. The sources are already staged in /usr/src, so
    # there is nothing to re-clone or re-download; build the one module this
    # kernel is missing. AUTOINSTALL only fires on kernel *install*, and the
    # kernel we just booted into was installed before facetimehd existed here.
    info "$PKG $existing is registered but has no module for $kver."
    info "Building against the running kernel (sources already in /usr/src)..."

    # Not run() here: these redirect their own output, and run()'s --dry-run
    # print would be swallowed by that redirect rather than shown.
    if [ "$DRY_RUN" -eq 1 ]; then
      run dkms build -m "$PKG" -v "$existing" -k "$kver"
      run dkms install -m "$PKG" -v "$existing" -k "$kver"
      return 0
    fi

    if ! dkms build -m "$PKG" -v "$existing" -k "$kver" >/dev/null 2>&1; then
      bad "DKMS build failed for $kver."
      info "Full log:  /var/lib/dkms/$PKG/$existing/build/make.log"
      die "Driver did not build."
    fi
    dkms install -m "$PKG" -v "$existing" -k "$kver" >/dev/null 2>&1 \
      || die "DKMS build succeeded but install failed for $kver."
    ok "built and installed for $kver"
    return 0
  fi

  [ -n "$BUILD_DIR" ] || BUILD_DIR=$(mktemp -d /tmp/mba-webcam.XXXXXX) \
    || die "Cannot create temp dir."

  if [ "$DRY_RUN" -eq 1 ]; then
    run git clone --depth 1 --branch "$DRIVER_VER" "$DRIVER_REPO" "$BUILD_DIR/driver"
    run cp -a "$BUILD_DIR/driver" "/usr/src/$PKG-$DRIVER_VER"
    run dkms add -m "$PKG" -v "$DRIVER_VER"
    run dkms build -m "$PKG" -v "$DRIVER_VER"
    run dkms install -m "$PKG" -v "$DRIVER_VER"
    run tee "$BLACKLIST"
    return 0
  fi

  info "Cloning $PKG $DRIVER_VER (pinned: first tag with kernel 7.x support)..."
  git clone --depth 1 --branch "$DRIVER_VER" "$DRIVER_REPO" "$BUILD_DIR/driver" >/dev/null 2>&1 \
    || die "Could not clone $DRIVER_REPO at tag $DRIVER_VER."

  [ -f "$BUILD_DIR/driver/dkms.conf" ] || die "Upstream checkout has no dkms.conf."
  local ver; ver=$(dkms_version_from "$BUILD_DIR/driver/dkms.conf")
  [ "$ver" = "$DRIVER_VER" ] || info "dkms.conf declares $ver (tag is $DRIVER_VER); using $ver"

  local src="/usr/src/$PKG-$ver"
  [ -d "$src" ] && rm -rf "$src"
  cp -a "$BUILD_DIR/driver" "$src" || die "Could not stage sources in $src."
  ok "sources staged in $src"

  dkms add -m "$PKG" -v "$ver" >/dev/null 2>&1 || true   # already-added is fine

  info "Building against $(uname -r) — this takes a minute on this machine..."
  if ! dkms build -m "$PKG" -v "$ver" >/dev/null 2>&1; then
    bad "DKMS build failed."
    info "Full log:  /var/lib/dkms/$PKG/$ver/build/make.log"
    info "If it is a vb2_ops / videobuf2 error, upstream has not yet caught up"
    info "with kernel $(uname -r); check github.com/patjak/facetimehd/issues."
    die "Driver did not build."
  fi
  ok "built for $(uname -r)"

  dkms install -m "$PKG" -v "$ver" >/dev/null 2>&1 \
    || die "DKMS build succeeded but install failed."
  ok "installed; AUTOINSTALL=yes means kernel upgrades rebuild it automatically"

  # dkms.conf already blacklists bdc_pci, but that stub binds the same device
  # and a duplicate blacklist line is harmless — belt and braces, and it gives
  # uninstall a file it owns outright.
  run tee "$BLACKLIST" >/dev/null <<'EOF'
# bdc_pci is a stub that claims the FaceTime HD camera and prevents
# facetimehd from binding to it. Installed by mba-webcam.sh.
blacklist bdc_pci
EOF
  ok "bdc_pci blacklisted"
}

# ---------------------------------------------------------------- load
load_module() {
  say "3/3  Loading"

  run modprobe -r bdc_pci 2>/dev/null || true

  if [ "$DRY_RUN" -eq 0 ]; then
    if ! modprobe facetimehd 2>/dev/null; then
      bad "modprobe facetimehd failed."
      info "Recent kernel messages:"
      dmesg 2>/dev/null | tail -15 | sed 's/^/      /'
      die "Module would not load."
    fi
  else
    run modprobe facetimehd
  fi
  ok "facetimehd loaded"

  run tee "$MODLOAD" >/dev/null <<'EOF'
# Load the FaceTime HD camera driver at boot. Installed by mba-webcam.sh.
facetimehd
EOF
  ok "will load at boot ($MODLOAD)"

  [ "$DRY_RUN" -eq 1 ] && return 0

  # The firmware handshake is asynchronous; the node can lag the modprobe.
  local i node=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    node=$(camera_node) && break
    sleep 0.5
  done

  if [ -n "$node" ]; then
    ok "video node present: $node  ($(cat /sys/class/video4linux/"$(basename "$node")"/name 2>/dev/null))"
  else
    warn "Module loaded but no capture node appeared."
    info "Almost always a firmware problem. Check:  dmesg | grep -i facetimehd"
  fi
}

# ---------------------------------------------------------------- commands
cmd_install() {
  need_root
  if [ "$IMAGE" = 1 ]; then
    say "Preflight (--image)"
    info "Skipping the camera check: this is a build host, not the target."
    info "The firmware comes from Apple's package over the network, not from the"
    info "device, so both persistent halves can be built here. The module cannot"
    info "be LOADED with no camera on the bus -- that is the target's first boot."
  else
    preflight
  fi
  install_firmware
  install_driver
  [ "$IMAGE" = 1 ] || load_module

  say "Done"
  [ "$IMAGE" = 1 ] || cmd_status
  echo
  info "Test it with any of:  cheese  /  guvcview  /  a video call in the browser"
  info "If the picture is dark or washed out, that is this driver's known-weak"
  info "auto-exposure, not a broken install."
}

cmd_uninstall() {
  need_root
  say "Removing facetimehd"

  run modprobe -r facetimehd 2>/dev/null || true
  ok "module unloaded (if it was loaded)"

  local ver; ver=$(installed_dkms_version)
  if [ -n "$ver" ]; then
    run dkms remove -m "$PKG" -v "$ver" --all >/dev/null 2>&1
    ok "DKMS entry $PKG/$ver removed"
    run rm -rf "/usr/src/$PKG-$ver"
    ok "sources removed from /usr/src"
  else
    ok "no DKMS entry to remove"
  fi

  if [ -e "$TUNE_RULE" ]; then
    run rm -f "$TUNE_RULE"
    run udevadm control --reload-rules
    ok "removed $TUNE_RULE"
  fi

  for f in "$MODLOAD" "$BLACKLIST"; do
    if [ -e "$f" ]; then run rm -f "$f"; ok "removed $f"; fi
  done

  local fw; fw=$(firmware_file)
  if [ -e "$fw" ]; then
    run rm -f "$fw"
    run rmdir "$(dirname "$fw")" 2>/dev/null || true
    ok "firmware removed (re-extracting it later is a 2.8MB download)"
  fi

  say "Uninstalled — the machine is back to its stock no-camera state."
}

cmd_status() {
  say "Status"

  if have_camera; then ok "camera on PCI bus  [$CAM_PCI_ID]"
  else bad "camera NOT on PCI bus"; fi

  local fw; fw=$(firmware_file)
  if [ -s "$fw" ]; then ok "firmware   $fw ($(du -h "$fw" 2>/dev/null | cut -f1))"
  else bad "firmware   missing"; fi

  local ver kver; ver=$(installed_dkms_version); kver=$(uname -r)
  if [ -z "$ver" ]; then
    bad "dkms       not registered"
  elif dkms_built_for "$kver"; then
    ok "dkms       $PKG/$ver, built for $kver"
  else
    # Registered but nothing built for the running kernel: the module cannot
    # load and every check below this line will fail. Worth naming, because it
    # looks identical to a healthy install if you only read the version.
    bad "dkms       $PKG/$ver registered, but NOT built for $kver"
    info "           Fix:  sudo $0 install"
  fi

  if module_loaded; then ok "module     loaded"
  else bad "module     not loaded"; fi

  local node; node=$(camera_node)
  if [ -n "$node" ]; then ok "device     $node"
  else bad "device     no facetimehd capture node"; fi

  if [ -e "$MODLOAD" ]; then ok "at boot    yes"
  else bad "at boot    no"; fi

  if [ -e "$TUNE_RULE" ]; then ok "tuning     persisted ($TUNE_RULE)"
  else info "    tuning     defaults (see: $0 tune)"; fi
}

cmd_test() {
  say "Capture test"

  local node; node=$(camera_node) \
    || die "No facetimehd capture node — run 'install' first, then check 'status'."
  info "Using $node"

  if command -v v4l2-ctl >/dev/null 2>&1; then
    info "Reported formats:"
    v4l2-ctl -d "$node" --list-formats-ext 2>/dev/null | head -20 | sed 's/^/      /'
    info "Controls:"
    v4l2-ctl -d "$node" --list-ctrls 2>/dev/null | sed 's/^/      /'
  else
    info "Install v4l-utils for format and control details:  sudo apt install v4l-utils"
  fi

  if command -v ffmpeg >/dev/null 2>&1; then
    local out="${TMPDIR:-/tmp}/mba-webcam-test.jpg"
    if ffmpeg -hide_banner -loglevel error -f v4l2 -i "$node" \
              -frames:v 1 -y "$out" >/dev/null 2>&1; then
      ok "captured a frame: $out"
    else
      warn "ffmpeg could not capture — see: dmesg | grep -i facetimehd"
    fi
  else
    info "No ffmpeg; try a GUI viewer instead:  cheese  or  guvcview"
  fi
}

cmd_tune() {
  say "Tuning"

  local node; node=$(camera_node) \
    || die "No facetimehd capture node — run 'install' first."
  local v4l2ctl; v4l2ctl=$(command -v v4l2-ctl) \
    || die "v4l2-ctl not found. Fix:  sudo apt install v4l-utils"
  info "Using $node"

  # No arguments and no --reset: just report, change nothing.
  if [ "${#TUNE_ARGS[@]}" -eq 0 ] && [ "$TUNE_RESET" -eq 0 ]; then
    info "Current values:"
    "$v4l2ctl" -d "$node" --list-ctrls 2>/dev/null | sed 's/^/      /'
    echo
    info "Set them like:  sudo $0 tune brightness=160 contrast=140"
    info "Controls: $CTRL_NAMES"
    [ -e "$TUNE_RULE" ] && info "Persisted rule in place: $TUNE_RULE"
    return 0
  fi

  if [ "$TUNE_RESET" -eq 1 ]; then
    TUNE_ARGS=()
    local c
    for c in $CTRL_NAMES; do TUNE_ARGS+=("$c=$(ctrl_default "$c")"); done
    info "Resetting to driver defaults"
  fi

  # Validate the whole request before asking for root or touching the hardware:
  # a typo in the third argument should cost a clear error, not a sudo prompt
  # followed by a half-configured camera.
  local pair key val max settings=""
  for pair in "${TUNE_ARGS[@]}"; do
    case "$pair" in
      *=*) key="${pair%%=*}"; val="${pair#*=}" ;;
      *)   die "Expected key=value, got: $pair  (controls: $CTRL_NAMES)" ;;
    esac
    max=$(ctrl_max "$key") || die "Unknown control: $key  (valid: $CTRL_NAMES)"
    case "$val" in
      ''|*[!0-9]*) die "$key needs a whole number 0-$max, got: $val" ;;
    esac
    [ "$val" -le "$max" ] || die "$key must be 0-$max, got: $val"
    settings="${settings:+$settings,}$(ctrl_canon "$key")=$val"
  done

  need_root

  if run "$v4l2ctl" -d "$node" --set-ctrl="$settings"; then
    ok "applied: $settings"
  else
    die "v4l2-ctl rejected: $settings"
  fi

  if [ "$TUNE_RESET" -eq 1 ] || [ "$TUNE_PERSIST" -eq 0 ]; then
    if [ -e "$TUNE_RULE" ]; then
      run rm -f "$TUNE_RULE"
      run udevadm control --reload-rules
      ok "removed persisted rule $TUNE_RULE"
    fi
    [ "$TUNE_PERSIST" -eq 0 ] && info "Not persisted — resets on reboot."
    return 0
  fi

  # Match on ATTR{name} rather than the node number: this camera does not
  # reliably get video0 (it is video1 on the machine this was written for).
  run tee "$TUNE_RULE" >/dev/null <<EOF
# Re-apply FaceTime HD camera settings whenever the device appears.
# Written by mba-webcam.sh tune -- edit via that, not by hand.
ACTION=="add", SUBSYSTEM=="video4linux", ATTR{name}=="Apple Facetime HD", \\
  RUN+="$v4l2ctl -d /dev/%k --set-ctrl=$settings"
EOF
  run udevadm control --reload-rules
  ok "persisted to $TUNE_RULE (re-applied on every boot)"

  echo
  info "Verify after a reboot with:  $0 tune"
  info "If the values did not stick, the ISP re-initialises when streaming"
  info "starts and they must be set with a preview already open."
}

cmd_help() {
  cat <<EOF
mba-webcam.sh $VERSION — FaceTime HD camera for the 2014 MacBook Air

USAGE
  sudo ./mba-webcam.sh [command] [--dry-run]

COMMANDS
  install     Firmware + DKMS driver + load it. Idempotent. (default)
  uninstall   Full undo: module, DKMS entry, sources, firmware, config.
  status      What is and is not in place right now.
  test        List camera formats and grab a single frame.
  tune        Show or set image controls (see below).
  help        This text.

OPTIONS
  --dry-run     Print every mutating action without doing any of it. No sudo needed.
  --no-persist  (tune) Apply now but do not survive a reboot.
  --reset       (tune) Restore driver defaults and drop the persisted rule.

TUNING
  ./mba-webcam.sh tune                            # show current values
  sudo ./mba-webcam.sh tune brightness=160        # set, and persist via udev
  sudo ./mba-webcam.sh tune --reset               # back to defaults

  Controls: $CTRL_NAMES
  Range 0-255 (default 128); auto_white_balance is 0 or 1 (default 1).

  There is no exposure or gain control — the driver never registers one, so
  nothing here lengthens sensor integration time. Raising brightness lifts the
  noise floor along with the image, which is why good lighting still matters.

NOTES
  Driver is pinned to $DRIVER_VER — the first release that builds on kernel 7.x.
  Firmware is a ~2.8MB byte-range fetch from Apple's CDN, not a full image.
  DKMS rebuilds the module on kernel upgrades, like broadcom-sta already does.
EOF
}

# ---------------------------------------------------------------- dispatch
CMD=""
for arg in "$@"; do
  case "$arg" in
    --image)                    IMAGE=1 ;;
    --dry-run)                  DRY_RUN=1 ;;
    --no-persist)               TUNE_PERSIST=0 ;;
    --reset)                    TUNE_RESET=1 ;;
    install|uninstall|status|test|tune|help) CMD="$arg" ;;
    -h|--help)                  CMD="help" ;;
    *=*)                        TUNE_ARGS+=("$arg") ;;
    *) die "Unknown argument: $arg  (try: help)" ;;
  esac
done
[ -n "$CMD" ] || CMD="install"

if [ "$CMD" != "tune" ] && { [ "${#TUNE_ARGS[@]}" -gt 0 ] || [ "$TUNE_RESET" -eq 1 ]; }; then
  die "key=value settings and --reset only apply to the 'tune' command."
fi

[ "$DRY_RUN" -eq 1 ] && say "DRY RUN — nothing will be changed"

case "$CMD" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  test)      cmd_test ;;
  tune)      cmd_tune ;;
  help)      cmd_help ;;
esac
