#!/bin/bash
# Name what writes a sysfs attribute, instead of guessing from timing.
#
# Generalised out of the keyboard backlight hunt (see kbd-backlight.sh), where
# elimination produced two confident wrong answers before a kernel stack settled
# it in one run. The lesson is the tool: stop correlating and go look.
#
# TWO ANSWERS, BOTH USEFUL
#
#   Events printed -> a userspace process wrote the file. You get pid, comm and
#   the stack, and you are done.
#
#   Nothing printed, but the value changed anyway -> NOBODY IN USERSPACE WROTE
#   IT. That is not a failed run, it is the finding. Stop accusing processes and
#   start looking at the driver: an LED trigger, a timer, a workqueue, a resume
#   path. Use --probe to attach to the driver function and get its stack.
#
# That second case is exactly what happened with the backlight, and recognising
# it an hour earlier would have saved an hour.
#
# READ THE STACK, NOT THE PROCESS NAME
#
# If the write happens in a softirq or interrupt, pid and comm are whatever was
# running on that CPU when it fired -- they mean nothing. The backlight trace
# said "fwupd" and sent this on a bisection of 130 fwupd plugins; the frame that
# mattered was led_timer_function, four lines up in the stack.
#
# Requires bpftrace and root.

set -uo pipefail

ATTR=""
DURATION=20
RUN_CMD=""
declare -a EXTRA_PROBES=()

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: sudo $0 <sysfs-file> [options]

  --seconds N     how long to trace (default $DURATION)
  --run "CMD"     run CMD while tracing, to provoke the write
  --probe FN      also trace kernel function FN with a stack; repeatable.
                  Use this when no userspace writer shows up, to find the
                  kernel path -- e.g. --probe applesmc_brightness_set

examples:
  sudo $0 /sys/class/leds/smc::kbd_backlight/brightness --run 'systemctl restart fwupd'
  sudo $0 /sys/class/leds/smc::kbd_backlight/brightness --probe applesmc_brightness_set \\
       --probe led_set_brightness --run 'systemctl restart fwupd'
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds) DURATION="${2:-}"; shift 2 ;;
    --run)     RUN_CMD="${2:-}"; shift 2 ;;
    --probe)   EXTRA_PROBES+=("${2:-}"); shift 2 ;;
    -h|--help) usage ;;
    -*)        die "unknown option: $1" ;;
    *)         ATTR="$1"; shift ;;
  esac
done

[[ -n "$ATTR" ]] || usage
[[ $EUID -eq 0 ]] || die "must run as root: sudo $0 $*"
command -v bpftrace >/dev/null || die "bpftrace is not installed (apt install bpftrace)"

ATTR=$(readlink -f "$ATTR" 2>/dev/null || echo "$ATTR")
[[ -e "$ATTR" ]] || die "no such file: $ATTR"
case "$ATTR" in /sys/*) ;; *) die "$ATTR is not under /sys" ;; esac

BT=$(mktemp /tmp/who-writes-XXXXXX.bt)
OUT=$(mktemp /tmp/who-writes-XXXXXX.txt)
cleanup() { [[ -n "${BTPID:-}" ]] && kill "$BTPID" 2>/dev/null; rm -f "$BT"; }
trap cleanup EXIT

# kernfs_fop_write_iter is the single funnel every sysfs write goes through, so
# one probe covers any attribute.
#
# Matching is on the dentry name and its parent's name rather than the full
# path: bpftrace 0.20 (what noble ships) has no address-of operator, so
# path(&file->f_path) is a syntax error. Walking f_path.dentry needs no such
# thing. The pair "smc::kbd_backlight/brightness" is specific enough in
# practice, though it would also match an identically named attribute under an
# identically named directory elsewhere.
ATTR_NAME=$(basename "$ATTR")
PARENT_NAME=$(basename "$(dirname "$ATTR")")

{
  cat <<EOF
kprobe:kernfs_fop_write_iter
{
  \$iocb = (struct kiocb *)arg0;
  \$d = \$iocb->ki_filp->f_path.dentry;
  \$name = str(\$d->d_name.name);
  \$parent = str(\$d->d_parent->d_name.name);
  if (\$name == "$ATTR_NAME" && \$parent == "$PARENT_NAME") {
    printf("WRITE  pid=%-6d comm=%-16s uid=%d\n", pid, comm, uid);
    printf("  stack:%s\n", kstack);
  }
}
EOF
  for fn in "${EXTRA_PROBES[@]}"; do
    cat <<EOF
kprobe:$fn
{
  printf("CALL   %-28s pid=%-6d comm=%-16s arg1=%d\n", "$fn", pid, comm, arg1);
  printf("  stack:%s\n", kstack);
}
EOF
  done
} > "$BT"

before=$(cat "$ATTR" 2>/dev/null)
echo "tracing writes to $ATTR for ${DURATION}s"
(( ${#EXTRA_PROBES[@]} )) && echo "extra probes: ${EXTRA_PROBES[*]}"

bpftrace "$BT" > "$OUT" 2>&1 &
BTPID=$!

# Do not start the clock until every probe is attached, or the provoking
# command can run inside the blind spot and the run silently proves nothing.
for _ in $(seq 1 40); do
  sleep 0.5
  grep -q 'Attaching' "$OUT" 2>/dev/null && break
done
if ! grep -q 'Attaching' "$OUT" 2>/dev/null; then
  echo "bpftrace did not attach; its output was:"
  cat "$OUT"
  exit 1
fi
sleep 1

if [[ -n "$RUN_CMD" ]]; then
  echo "running: $RUN_CMD"
  bash -c "$RUN_CMD"
fi

sleep "$DURATION"
kill "$BTPID" 2>/dev/null; wait "$BTPID" 2>/dev/null; BTPID=
after=$(cat "$ATTR" 2>/dev/null)

echo
echo "================================ trace ================================"
grep -v '^Attaching' "$OUT"
echo "======================================================================="
echo "value before: $before"
echo "value after:  $after"
echo

events=$(grep -c '^WRITE' "$OUT" 2>/dev/null || echo 0)
if [[ "$events" -gt 0 ]]; then
  # A busy attribute repeats the same stack many times; the useful shape is who
  # wrote it and how often, which the raw trace buries.
  echo "by writer:"
  grep '^WRITE' "$OUT" |
    sed -E 's/.*pid=([0-9]+)[[:space:]]+comm=([^[:space:]]+).*/\2 (pid \1)/' |
    sort | uniq -c | sort -rn | sed 's/^/  /'
  echo
  echo "$events userspace write(s) seen. Read the stack, not comm -- if the top"
  echo "frames are softirq/timer/interrupt, the pid is just whatever was"
  echo "interrupted and means nothing."
elif [[ "$before" != "$after" ]]; then
  echo "THE VALUE CHANGED WITH NO USERSPACE WRITE."
  echo "This is the answer, not a failed run: no process wrote this file. Look"
  echo "at the driver instead -- an LED trigger, a timer, a workqueue, a resume"
  echo "path. Re-run with --probe on the driver's setter to get its stack, e.g."
  echo "  grep -i '<driver>' /proc/kallsyms | grep -iE 'set|store'"
else
  echo "No writes, and the value did not change -- nothing was provoked."
  echo "If the fault is real, it was not reproduced during this window."
fi
