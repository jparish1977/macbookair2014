#!/bin/bash
# Test a one-file kernel module patch on the machine that actually has the
# hardware -- with a control condition, and a restore that always runs.
#
# Generalised from applesmc-patch-test.sh, which proved a one-line fix to
# drivers/hwmon/applesmc.c. The workflow turns out to be the common shape for
# vintage-hardware driver bugs: the fault is in a module, the module is one .c
# file, and the only machine that can judge the fix is the broken one.
#
# WHY A CONTROL CONDITION IS THE WHOLE POINT
#
# A workaround usually exists by the time you have a patch -- a udev rule, a
# modprobe option, something in userspace. Those reach the same end state
# whether or not the patch does anything, so "I applied the patch and it works"
# proves nothing while one is in place. This loads the STOCK module first and
# insists the fault reproduces. If it does not, the run aborts instead of
# reporting a success it has not earned.
#
# WHY srcversion IS CHECKED FIRST
#
# srcversion is a hash over a module's source. Building the untouched upstream
# file and comparing against the running module answers two questions at once:
# whether your distro patches this driver (if so, you would not be testing
# upstream code), and whether the module really is a single .c file (if it is
# not, your source set is incomplete and the hash will not match). Either way a
# mismatch means stop.
#
# EXAMPLE -- the applesmc backlight fix this came from:
#
#   sudo ./module-patch-test.sh \
#     --module applesmc \
#     --sed '/\.default_trigger[[:space:]]*=[[:space:]]*"nand-disk",/d' \
#     --setup  'mv /etc/udev/rules.d/60-applesmc-kbd-backlight.rules /root/rule.off; udevadm control --reload-rules' \
#     --teardown 'mv /root/rule.off /etc/udev/rules.d/60-applesmc-kbd-backlight.rules; udevadm control --reload-rules; sleep 1; echo 204 > /sys/class/leds/smc::kbd_backlight/brightness' \
#     --provoke 'systemctl restart fwupd' --settle 8 \
#     --check 'test "$(cat /sys/class/leds/smc::kbd_backlight/brightness)" = 204' \
#     --prepare 'echo 204 > /sys/class/leds/smc::kbd_backlight/brightness'
#
# Two things that example is doing deliberately:
#
#   --setup moves the existing workaround out of the way. Without that the
#   control condition passes, the run aborts, and rightly so.
#
#   --teardown puts back more than it disabled. Reloading a module resets
#   whatever state it owned -- here the LED drops to 0 -- and this script cannot
#   know which of that state you cared about. Restoring it is your job, in
#   --teardown, which runs before the stock module is loaded again.

set -uo pipefail

MODULE=""
PATCHFILE=""
SEDEXPR=""
SRCFILE=""
CHECK=""
PROVOKE=""
PREPARE=""
SETUP=""
TEARDOWN=""
SETTLE=3
KEEP=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: sudo $0 --module NAME (--patch FILE | --sed EXPR) --check CMD [options]

  --module NAME    module to patch, e.g. applesmc
  --patch FILE     unified diff against the kernel tree (applied with -p1)
  --sed EXPR       or a sed expression, for one-line changes
  --check CMD      the verdict. Exit 0 means the DESIRED behaviour is present.
                   Must fail on the stock module and pass on the patched one.

  --source FILE    use this .c instead of fetching upstream (e.g. distro source)
  --prepare CMD    run before each check, to set up the observable
  --provoke CMD    run before each check, to trigger the fault
  --settle N       seconds to wait after --provoke (default $SETTLE)
  --setup CMD      run once at the start -- use it to disable any existing
                   workaround, or the control condition is worthless
  --teardown CMD   run once during restore, to undo --setup
  --keep           keep the build directory and print its path

The module must be a loadable module, currently unused (refcount 0), and built
from a single .c file. Needs root, gcc, and the running kernel's headers.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)   MODULE="${2:-}"; shift 2 ;;
    --patch)    PATCHFILE="${2:-}"; shift 2 ;;
    --sed)      SEDEXPR="${2:-}"; shift 2 ;;
    --source)   SRCFILE="${2:-}"; shift 2 ;;
    --check)    CHECK="${2:-}"; shift 2 ;;
    --prepare)  PREPARE="${2:-}"; shift 2 ;;
    --provoke)  PROVOKE="${2:-}"; shift 2 ;;
    --settle)   SETTLE="${2:-}"; shift 2 ;;
    --setup)    SETUP="${2:-}"; shift 2 ;;
    --teardown) TEARDOWN="${2:-}"; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    -h|--help)  usage ;;
    *)          die "unknown option: $1" ;;
  esac
done

[[ -n "$MODULE" ]] || usage
[[ -n "$CHECK" ]]  || die "--check is required: without a verdict there is no test"
[[ -n "$PATCHFILE" || -n "$SEDEXPR" ]] || die "need --patch or --sed"
[[ -z "$PATCHFILE" || -f "$PATCHFILE" ]] || die "no such patch file: $PATCHFILE"
[[ $EUID -eq 0 ]] || die "run as root"

# ---- preflight -----------------------------------------------------------

command -v gcc >/dev/null || die "gcc not installed"
KBUILD="/lib/modules/$(uname -r)/build"
[[ -d "$KBUILD" ]] || die "no kernel headers for $(uname -r) (apt install linux-headers-$(uname -r))"

if [[ -e /sys/firmware/efi ]] &&
   od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | grep -qE '1$'; then
  die "Secure Boot is enabled; an unsigned module will not load"
fi

KO=$(modinfo -n "$MODULE" 2>/dev/null) || die "no module named '$MODULE' (built in, rather than a module?)"
echo "module:  $MODULE"
echo "         $KO"

# The source path falls out of where the .ko sits in the module tree:
#   .../kernel/drivers/hwmon/applesmc.ko.zst  ->  drivers/hwmon/applesmc.c
REL=${KO#*/kernel/}
SRCPATH="${REL%%.ko*}.c"
echo "source:  $SRCPATH"

usecount=$(awk -v m="$MODULE" '$1==m {print $3}' /proc/modules 2>/dev/null)
if [[ -n "$usecount" && "$usecount" != "0" ]]; then
  users=$(awk -v m="$MODULE" '$1==m {print $4}' /proc/modules)
  die "$MODULE is in use (refcount $usecount, by: $users) -- unloading it would fail or hurt"
fi

# ---- source --------------------------------------------------------------

B=$(mktemp -d /tmp/module-patch-test-XXXXXX)
mkdir -p "$B/tree/$(dirname "$SRCPATH")"

if [[ -n "$SRCFILE" ]]; then
  cp "$SRCFILE" "$B/tree/$SRCPATH" || die "could not read $SRCFILE"
  echo "using supplied source: $SRCFILE"
else
  TAG="v$(uname -r | cut -d. -f1-2)"
  echo "fetching upstream $TAG $SRCPATH ..."
  curl -fsSL -o "$B/tree/$SRCPATH" \
    "https://raw.githubusercontent.com/torvalds/linux/$TAG/$SRCPATH" \
    || die "could not fetch $SRCPATH at $TAG -- pass --source instead"
fi

BASENAME=$(basename "$SRCPATH" .c)
printf 'obj-m := %s.o\n' "$BASENAME" > "$B/Makefile"
cp "$B/tree/$SRCPATH" "$B/$BASENAME.c"
cp "$B/tree/$SRCPATH" "$B/unpatched.c"

build() { make -C "$KBUILD" M="$B" modules >/dev/null 2>&1; }

# ---- restore, on every exit path -----------------------------------------

restore() {
  echo
  echo "--- restoring ---"
  rmmod "$MODULE" 2>/dev/null
  # Teardown BEFORE the module comes back, not after. Whatever --setup disabled
  # is usually something that acts on the module's own add event -- a udev rule,
  # most likely -- so putting it back afterwards would leave it in place but
  # unapplied, which looks restored and is not.
  if [[ -n "$TEARDOWN" ]]; then
    bash -c "$TEARDOWN" && echo "teardown ran" || echo "TEARDOWN FAILED -- check by hand: $TEARDOWN"
  fi
  modprobe "$MODULE" 2>/dev/null && echo "stock $MODULE reloaded"
  sleep 1
  if [[ "$KEEP" == "1" ]]; then echo "build dir kept: $B"; else rm -rf "$B"; fi
  return 0
}
trap restore EXIT

# ---- 0. integrity --------------------------------------------------------

echo
echo "=== 0. integrity: is this stock upstream source, and one file? ==="
shipped=$(modinfo -F srcversion "$MODULE" 2>/dev/null)
build || die "the unpatched source did not build"
built=$(modinfo -F srcversion "$B/$BASENAME.ko")
echo "  running module: $shipped"
echo "  our build:      $built"
if [[ "$shipped" != "$built" ]]; then
  cat >&2 <<EOF
  MISMATCH. Either your distro patches this driver, or the module is built from
  more than one source file. In both cases this run would not be testing what
  you think. Supply the real source with --source, or stop here.
EOF
  exit 1
fi
echo "  match -- source is stock upstream and complete"
cp "$B/$BASENAME.ko" "$B/stock.ko"

[[ -n "$SETUP" ]] && { echo; echo "running --setup"; bash -c "$SETUP" || die "setup failed"; }

verdict() {
  [[ -n "$PREPARE" ]] && bash -c "$PREPARE" >/dev/null 2>&1
  if [[ -n "$PROVOKE" ]]; then
    bash -c "$PROVOKE" >/dev/null 2>&1
    sleep "$SETTLE"
  fi
  bash -c "$CHECK" >/dev/null 2>&1
}

# ---- 1. control ----------------------------------------------------------

echo
echo "=== 1. control: stock module, workaround disabled ==="
rmmod "$MODULE" 2>/dev/null; sleep 1
insmod "$B/stock.ko" || die "could not load the stock build"
sleep 2
if verdict; then
  cat >&2 <<EOF
  THE CONTROL PASSED, which means the fault did not reproduce.
  A pass on the patched module would therefore prove nothing. Common causes: a
  workaround still in place (--setup should disable it), or --check not actually
  observing the fault.
EOF
  exit 1
fi
echo "  fault reproduced on the stock module -- the control is good"

# ---- 2. patched ----------------------------------------------------------

echo
echo "=== 2. patched module ==="
if [[ -n "$PATCHFILE" ]]; then
  ( cd "$B/tree" && patch -p1 --batch --forward < "$PATCHFILE" ) >/dev/null 2>&1 \
    || die "the patch did not apply cleanly"
  cp "$B/tree/$SRCPATH" "$B/$BASENAME.c"
else
  sed "$SEDEXPR" "$B/unpatched.c" > "$B/$BASENAME.c" || die "sed failed"
fi

if diff -q "$B/unpatched.c" "$B/$BASENAME.c" >/dev/null; then
  die "the patch changed nothing"
fi
echo "  change applied:"
diff -u "$B/unpatched.c" "$B/$BASENAME.c" | sed -n '3,$p' | sed 's/^/    /' | head -40

build || die "the patched source did not build"
echo "  patched srcversion: $(modinfo -F srcversion "$B/$BASENAME.ko")"
cp "$B/$BASENAME.ko" "$B/patched.ko"

rmmod "$MODULE" 2>/dev/null; sleep 1
insmod "$B/patched.ko" || die "the patched module would not load"
sleep 2
if verdict; then
  echo "  PASS -- the patched module produces the desired behaviour"
else
  die "FAIL -- the patch built and loaded, but --check still fails"
fi

echo
echo "================================================================"
echo "  PASS on $(cat /sys/class/dmi/id/product_name 2>/dev/null), $(uname -r)"
echo "    control (stock module): fault reproduced"
echo "    patched module:         desired behaviour"
echo "================================================================"
