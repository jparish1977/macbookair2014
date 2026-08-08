#!/bin/bash
# Build a kernel workshop from nothing, on any Debian/Ubuntu host.
#
#   ./provision.sh                      # here
#   ssh somehost 'bash -s' < provision.sh   # there
#
# The point of this script is that the workshop is not a machine, it is a
# recipe. Right now the recipe runs on iteration8 because that is where the 32
# cores are. If it should later run in a VM, a container, or on a different box
# entirely, that is this script plus somewhere to run it -- not an afternoon of
# remembering what was installed by hand.
#
# Idempotent: safe to re-run. It will not re-clone an existing tree, and apt
# will skip what is already installed.
#
# Options:
#   --dir PATH     where the workshop lives (default /srv/kernel-workshop)
#   --no-clone     set everything up but skip the ~5GB kernel clone
#   --ccache N     ccache size, default 25G

set -uo pipefail

WS=/srv/kernel-workshop
CLONE=1
CCACHE_SIZE=25G
MIRROR=https://github.com/torvalds/linux.git   # a mirror of git.kernel.org, usually faster

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      WS="${2:-}"; shift 2 ;;
    --no-clone) CLONE=0; shift ;;
    --ccache)   CCACHE_SIZE="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
command -v apt-get >/dev/null || die "this expects a Debian/Ubuntu host"

SUDO=""
if [[ $EUID -ne 0 ]]; then
  sudo -n true 2>/dev/null || die "needs root or passwordless sudo"
  SUDO="sudo -n"
fi

echo "=== packages ==="
$SUDO DEBIAN_FRONTEND=noninteractive apt-get update -qq
$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  build-essential flex bison libssl-dev libelf-dev bc rsync dwarves \
  debhelper ccache libncurses-dev cpio zstd kmod git curl \
  || die "package install failed"

missing=0
for p in build-essential flex bison libssl-dev libelf-dev bc dwarves debhelper ccache cpio; do
  dpkg -l "$p" 2>/dev/null | grep -q '^ii' || { echo "  MISSING: $p"; missing=1; }
done
[[ "$missing" == "0" ]] && echo "  all present"

echo "=== layout at $WS ==="
$SUDO mkdir -p "$WS"
$SUDO chown "$(id -un):$(id -gn)" "$WS"
mkdir -p "$WS"/{targets,builds,bin}
echo "  targets/  one profile per machine you build for"
echo "  builds/   .deb output, one directory per target+ref"
echo "  bin/      these scripts"
echo "  linux/    the kernel tree"

echo "=== ccache ==="
CCACHE_DIR="$WS/.ccache" ccache -M "$CCACHE_SIZE" >/dev/null 2>&1 &&
  echo "  $WS/.ccache, max $CCACHE_SIZE" || echo "  ccache setup failed (not fatal)"

if [[ "$CLONE" == "1" ]]; then
  if [[ -d "$WS/linux/.git" ]]; then
    echo "=== kernel tree already present, fetching tags ==="
    git -C "$WS/linux" fetch --tags --quiet 2>/dev/null && echo "  fetched" || echo "  fetch failed (offline?)"
  else
    echo "=== cloning the kernel (full history -- git bisect needs it) ==="
    echo "  this is several GB and takes a while"
    git clone --progress "$MIRROR" "$WS/linux" || die "clone failed"
  fi
  echo "  HEAD: $(git -C "$WS/linux" describe --tags --always 2>/dev/null)"
else
  echo "=== skipping clone (--no-clone) ==="
fi

cat <<EOF

=== done ===
Workshop at $WS

Next:
  1. On each machine you want to build for, run capture-target.sh --push
  2. On this host:  $WS/bin/kbuild.sh --target NAME --ref v7.0
  3. Read $WS/README.md before installing a kernel on a machine
     that has no ethernet.
EOF
