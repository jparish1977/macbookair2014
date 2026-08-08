#!/bin/bash
# Watch any sysfs attribute and record every time its value changes.
#
# Generalised out of the keyboard backlight hunt (see kbd-backlight.sh). The
# problem there was that the value changed during *login*, and anything started
# by the session is already too late to see it. So this does two things the
# obvious one-liner does not:
#
#   --detach   survives logout. logind's KillUserProcesses defaults to no, so a
#              setsid'd process outlives the session that started it.
#   --at-boot  installs a @reboot crontab entry, which starts before the display
#              manager hands over. That is the only way to have a watcher
#              already running when the login itself is the suspect.
#
# On every change it dumps the newest processes on the machine. That does not
# name the writer -- it names the neighbourhood, which is usually enough to say
# what to reach for next. When it is not, use who-writes.sh, which does name it.
#
# Same family as wifi-snapshot.sh: some faults only exist while they are
# happening, and a post-mortem log read comes back empty.

set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SELF=$(readlink -f "$0")
ATTR=""
SECONDS_TO_RUN=600
INTERVAL=0.05
LOG=""
DETACH=0
AT_BOOT=""
AT_BOOT_OFF=0
CRON_TAG="# sysfs-watch"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: $0 <sysfs-file> [options]
       $0 --at-boot-off <sysfs-file>

  --seconds N    how long to watch (default $SECONDS_TO_RUN)
  --interval S   poll interval in seconds (default $INTERVAL)
  --log PATH     where to write (default ~/sysfs-watch/<name>.log)
  --detach       run in the background, surviving logout
  --at-boot N    install a @reboot crontab entry watching for N seconds,
                 for faults that happen during boot or login
  --at-boot-off  remove that entry again

examples:
  $0 /sys/class/leds/smc::kbd_backlight/brightness --detach
  $0 /sys/class/power_supply/BAT0/status --seconds 3600 --detach
  $0 /sys/class/leds/smc::kbd_backlight/brightness --at-boot 600
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --seconds)      SECONDS_TO_RUN="${2:-}"; shift 2 ;;
    --interval)     INTERVAL="${2:-}"; shift 2 ;;
    --log)          LOG="${2:-}"; shift 2 ;;
    --detach)       DETACH=1; shift ;;
    --at-boot)      AT_BOOT="${2:-}"; shift 2 ;;
    --at-boot-off)  AT_BOOT_OFF=1; shift ;;
    -h|--help)      usage ;;
    -*)             die "unknown option: $1" ;;
    *)              ATTR="$1"; shift ;;
  esac
done

[[ -n "$ATTR" ]] || usage
ATTR=$(readlink -f "$ATTR" 2>/dev/null || echo "$ATTR")
[[ -r "$ATTR" ]] || die "cannot read $ATTR"
[[ -f "$ATTR" ]] || die "$ATTR is not a file"

if [[ -z "$LOG" ]]; then
  # /sys/class/leds/smc::kbd_backlight/brightness -> sys_class_leds_smc__kbd_backlight_brightness
  slug=$(echo "${ATTR#/}" | tr '/:' '__')
  LOG="$HOME/sysfs-watch/$slug.log"
fi
mkdir -p "$(dirname "$LOG")"

# --- crontab management -------------------------------------------------
#
# Rewrite the crontab through a filter rather than replacing it: this machine
# already has a rescue-status entry that must not be lost.
#
# Note the trap that bit during development: `pkill -f sysfs-watch` also matches
# the shell running that very command, so it kills itself. Match on something
# narrower, or use the pid.

cron_line() { echo "@reboot $SELF '$ATTR' --seconds $1 $CRON_TAG $ATTR"; }

if [[ $AT_BOOT_OFF -eq 1 ]]; then
  crontab -l 2>/dev/null | grep -vF "$CRON_TAG $ATTR" | crontab -
  echo "removed the @reboot watcher for $ATTR"
  crontab -l 2>/dev/null | grep -F "$CRON_TAG" || echo "(no sysfs-watch entries remain)"
  exit 0
fi

if [[ -n "$AT_BOOT" ]]; then
  { crontab -l 2>/dev/null | grep -vF "$CRON_TAG $ATTR"; cron_line "$AT_BOOT"; } | crontab -
  echo "installed a @reboot watcher for $ATTR (${AT_BOOT}s per boot)"
  echo "log: $LOG"
  echo
  echo "This is a debugging aid, not something to leave installed. Remove it with:"
  echo "  $0 '$ATTR' --at-boot-off"
  exit 0
fi

# --- the watcher itself -------------------------------------------------

if [[ $DETACH -eq 1 ]]; then
  # Re-exec detached. setsid so it is not in the session's process group, and
  # so it survives logout.
  DETACH=0
  setsid nohup "$SELF" "$ATTR" --seconds "$SECONDS_TO_RUN" \
    --interval "$INTERVAL" --log "$LOG" >/dev/null 2>&1 </dev/null &
  sleep 1
  echo "watching $ATTR for ${SECONDS_TO_RUN}s, detached"
  echo "log: $LOG"
  exit 0
fi

stamp() { date '+%H:%M:%S.%3N'; }

{
  echo
  echo "================================================================"
  echo "watch started $(date -Is)  pid=$$"
  echo "attribute: $ATTR"
  echo "duration ${SECONDS_TO_RUN}s, poll ${INTERVAL}s, uptime at start $(cut -d' ' -f1 /proc/uptime)s"
  echo "$(stamp) initial value = $(cat "$ATTR" 2>/dev/null)"
  echo "================================================================"
} >> "$LOG"

last=$(cat "$ATTR" 2>/dev/null)
end=$((SECONDS + SECONDS_TO_RUN))
while (( SECONDS < end )); do
  v=$(cat "$ATTR" 2>/dev/null) || break
  if [[ "$v" != "$last" ]]; then
    {
      printf '\n%s CHANGED  %s -> %s   (uptime %ss)\n' \
        "$(stamp)" "$last" "$v" "$(cut -d' ' -f1 /proc/uptime)"
      echo "  sessions: $(loginctl list-sessions --no-legend 2>/dev/null | tr -s ' ' | tr '\n' ';')"
      echo "  --- 20 most recently started processes ---"
      # Truncated: full command lines can run to hundreds of characters and
      # bury the one line that matters.
      ps -eo etimes,pid,user,args --sort=etimes 2>/dev/null |
        head -21 | cut -c1-160 | sed 's/^/  /'
      echo
    } >> "$LOG"
    last=$v
  fi
  sleep "$INTERVAL"
done

echo "$(stamp) watch ended, final value = $(cat "$ATTR" 2>/dev/null)" >> "$LOG"
