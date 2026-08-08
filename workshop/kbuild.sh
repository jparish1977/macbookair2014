#!/bin/bash
# Build an installable kernel for one of the target machines. Runs ON the
# workshop host (iteration8), never on the vintage machine.
#
#   ./kbuild.sh --target mba --ref v7.0
#   ./kbuild.sh --target mba --ref v6.17 --full
#   ./kbuild.sh --target mba --ref HEAD --here      # whatever is checked out
#
# Produces .deb packages under builds/, and prints how to install them.
#
# Four things this handles that catch everyone building a distro config in a
# mainline tree, all of them written down in README.md as well:
#
#   1. CONFIG_SYSTEM_TRUSTED_KEYS and CONFIG_SYSTEM_REVOCATION_KEYS point at
#      Canonical certificates that do not exist here. Left alone, the build
#      dies partway through with a confusing certificate error.
#   2. CONFIG_DEBUG_INFO_BTF makes builds far slower and needs a pahole that
#      matches. Off by default here; --keep-debug puts it back.
#   3. Module signing is disabled. The targets have Secure Boot off, and
#      signing only costs time.
#   4. LOCALVERSION marks the kernel with the target name, so it is obvious in
#      GRUB and in uname which build you are running.

set -uo pipefail

WS="${WORKSHOP_DIR:-/srv/kernel-workshop}"
TREE="$WS/linux"
TARGET=""
REF=""
TRIM=1
HERE=0
JOBS=$(nproc)
KEEP_DEBUG=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: $0 --target NAME --ref REF [options]

  --target NAME   a profile under $WS/targets/
  --ref REF       git ref to build: a tag (v7.0), branch, or commit sha
  --here          build whatever is already checked out (for git bisect)
  --full          keep the whole distro config; slow but safest
  --trim          strip to modules the target actually loads (default)
  --jobs N        parallel jobs (default $JOBS)
  --keep-debug    keep debug info and BTF

available targets:
$(ls "$WS/targets" 2>/dev/null | sed 's/^/  /' || echo "  (none -- run capture-target.sh on a machine first)")
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --ref)    REF="${2:-}"; shift 2 ;;
    --here)   HERE=1; shift ;;
    --full)   TRIM=0; shift ;;
    --trim)   TRIM=1; shift ;;
    --jobs)   JOBS="${2:-}"; shift 2 ;;
    --keep-debug) KEEP_DEBUG=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$TARGET" ]] || usage
[[ -d "$TREE" ]] || die "no kernel tree at $TREE"
PROFILE="$WS/targets/$TARGET"
[[ -d "$PROFILE" ]] || die "no target profile at $PROFILE (run capture-target.sh on that machine)"
[[ -f "$PROFILE/config" ]] || die "$PROFILE/config missing"
[[ "$HERE" == "1" || -n "$REF" ]] || die "need --ref, or --here to build what is checked out"

# Decide ARCH from the target's own uname -m. 32-bit x86 is the same toolchain
# with -m32 (needs gcc-multilib, which provision.sh installs), so it just works.
# Anything else needs a cross toolchain and a different install path, which this
# script does not do -- refuse loudly rather than build something wrong.
TARGET_ARCH=$(cat "$PROFILE/arch" 2>/dev/null || awk '/^arch:/{print $2}' "$PROFILE/facts.txt" 2>/dev/null)
MAKEARGS=()
case "${TARGET_ARCH:-$(uname -m)}" in
  x86_64) ;;
  i386|i486|i586|i686)
    MAKEARGS=(ARCH=i386)
    echo "target is 32-bit x86 -> ARCH=i386"
    ;;
  arm*|aarch64|ppc*|powerpc*)
    die "target arch '$TARGET_ARCH' needs cross-compilation, which this script does not do yet.
       Pis and the Jetson also need a different kernel tree and a non-deb install path --
       see the ARM section of $WS/README.md before starting."
    ;;
  *) die "unrecognised target arch '$TARGET_ARCH'" ;;
esac

export CCACHE_DIR="${CCACHE_DIR:-$WS/.ccache}"
ccache -M 25G >/dev/null 2>&1

cd "$TREE" || die "cannot enter $TREE"

if [[ "$HERE" != "1" ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    die "the tree has local changes; commit, stash or 'git checkout -- .' first"
  fi
  echo "checking out $REF ..."
  git checkout -q "$REF" 2>/dev/null || die "no such ref: $REF (try: git fetch --tags)"
fi

DESC=$(git describe --tags --always 2>/dev/null)
SLUG=$(echo "${REF:-$DESC}" | tr '/ ' '__')
echo "building $DESC for target '$TARGET'"

cp "$PROFILE/config" .config

# --- the four fixes ---------------------------------------------------------
scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --disable MODULE_SIG
scripts/config --set-str LOCALVERSION "-$TARGET"
scripts/config --disable LOCALVERSION_AUTO
if [[ "$KEEP_DEBUG" != "1" ]]; then
  scripts/config --disable DEBUG_INFO_BTF
  scripts/config --disable DEBUG_INFO_DWARF5
  scripts/config --disable DEBUG_INFO_DWARF4
  scripts/config --enable  DEBUG_INFO_NONE
fi

echo "resolving config ..."
make "${MAKEARGS[@]}" olddefconfig >/dev/null || die "olddefconfig failed"

if [[ "$TRIM" == "1" ]]; then
  [[ -f "$PROFILE/lsmod" ]] || die "--trim needs $PROFILE/lsmod"
  echo "trimming to the $(($(wc -l < "$PROFILE/lsmod") - 1)) modules '$TARGET' actually loads ..."
  yes '' 2>/dev/null | make "${MAKEARGS[@]}" LSMOD="$PROFILE/lsmod" localmodconfig >/dev/null 2>&1
  # localmodconfig can quietly re-enable the certificate options
  scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
  scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
  make "${MAKEARGS[@]}" olddefconfig >/dev/null
fi

OUTDIR="$WS/builds/$TARGET-$SLUG"
mkdir -p "$OUTDIR"
cp .config "$OUTDIR/config-used"

echo "building with $JOBS jobs (ccache on) ..."
echo "  full log: $OUTDIR/build.log"
start=$SECONDS
# tee, not tail: a failed kernel build is diagnosed from the hundred lines
# before the error, and piping straight to tail throws exactly those away.
if ! make -j"$JOBS" "${MAKEARGS[@]}" CC="ccache gcc" KDEB_PKGVERSION=1 bindeb-pkg 2>&1 \
     | tee "$OUTDIR/build.log" | tail -25; then
  echo
  echo "build failed. The full log is at $OUTDIR/build.log" >&2
  echo "First error:" >&2
  grep -m3 -nE 'Error [0-9]|error:|No rule to make' "$OUTDIR/build.log" >&2
  exit 1
fi
elapsed=$((SECONDS - start))

mv "$WS"/linux-image-*.deb "$WS"/linux-headers-*.deb "$WS"/linux-libc-dev*.deb "$OUTDIR/" 2>/dev/null
mv "$WS"/*.buildinfo "$WS"/*.changes "$OUTDIR/" 2>/dev/null

# An address the target can actually reach. `hostname` is wrong here often
# enough to matter: this host's own name resolves only on its LAN, so a printed
# `scp iteration8:...` fails from anywhere else -- which is exactly where you
# are when fetching a kernel for a laptop you carried somewhere.
HOSTHINT=$(tailscale ip -4 2>/dev/null | head -1)
[[ -z "$HOSTHINT" ]] && HOSTHINT=$(hostname)

echo
echo "================================================================"
echo "  built $DESC for '$TARGET' in $((elapsed / 60))m $((elapsed % 60))s"
echo "  $OUTDIR"
ls -1sh "$OUTDIR"/*.deb 2>/dev/null | sed 's/^/    /'
cat <<EOF

  Install on the target -- READ README.md FIRST if that machine has no
  ethernet, because a self-built kernel will not have its DKMS modules:

    scp $HOSTHINT:$OUTDIR/linux-image-*.deb .
    sudo dpkg -i linux-image-*.deb
    sudo update-grub
    # reboot AT THE KEYBOARD and pick the new entry; the old kernels stay
================================================================
EOF
