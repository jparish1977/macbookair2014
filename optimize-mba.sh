#!/usr/bin/env bash
# Optimize MacBookAir6,1 (4GB Haswell) under Linux Mint 22.3
# Deliberately DOES NOT touch: power management (TLP/ASPM/PPD),
# Apache/MySQL/PHP as installed services, or any XFCE component.
#
#   ./optimize-mba.sh                 everything, in order, then verify
#   ./optimize-mba.sh services        just that section
#   ./optimize-mba.sh 7               same thing by number
#   ./optimize-mba.sh zram sysctl     several, always in canonical order
#   ./optimize-mba.sh --list          what the sections are
#
# Piecemeal because most of this is one-time and irreversible-ish -- clearing
# the apt cache, deleting snapshots, purging kernels -- while a couple of steps
# are worth re-running on their own after a package update puts something back.
# Running the whole script to reach one section means paying for all the others.
set -uo pipefail

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[32m[ok]\033[0m %s\n' "$*"; }

# Canonical order. Selection never reorders these: zram has to be configured
# before the sysctls that assume it, so "sysctl zram" still runs zram first.
SECTIONS=(disk timeshift zram sysctl earlyoom noatime services mysql)
DESCRIBE=(
  "reclaim disk: apt cache, journal cap, obsolete kernels (asks)"
  "delete Timeshift snapshots and disable its schedules"
  "enable zram  <-- the big one for 4GB"
  "VM sysctls tuned for zram (high swappiness, page-cluster 0)"
  "install earlyoom so 4GB does not hard-freeze"
  "noatime on root, to cut SSD writes"
  "disable absent hardware: ModemManager, casper, gstreamer msdk"
  "shrink the MySQL 8 memory footprint"
)

# ---------------------------------------------------------------- 1. DISK
sec_disk() {
say "1/8  Reclaiming disk space"
apt-get clean
ok "apt cache cleared (~4.8G)"

journalctl --vacuum-size=200M >/dev/null 2>&1
if ! grep -q '^SystemMaxUse=200M' /etc/systemd/journald.conf 2>/dev/null; then
  sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
  grep -q '^SystemMaxUse=' /etc/systemd/journald.conf || echo 'SystemMaxUse=200M' >> /etc/systemd/journald.conf
fi
ok "journal vacuumed and capped at 200M"

# Old kernels are never purged automatically: on a machine whose only network
# card depends on a DKMS module, the previous kernel is the recovery path.
# Candidates exclude the running kernel and the newest installed one.
RUNNING=$(uname -r | sed 's/-generic$//')
mapfile -t INSTALLED < <(
  dpkg-query -W -f='${Package} ${Status}\n' 'linux-image-*-generic' 2>/dev/null \
    | awk '$NF=="installed"{print $1}' \
    | sed 's/^linux-image-//; s/-generic$//' \
    | sort -V
)
CANDIDATES=()
NEWEST=""
[ "${#INSTALLED[@]}" -gt 0 ] && NEWEST="${INSTALLED[-1]}"
for k in "${INSTALLED[@]:-}"; do
  [ -n "$k" ] || continue
  [ "$k" = "$RUNNING" ] && continue
  [ "$k" = "$NEWEST" ] && continue
  CANDIDATES+=("$k")
done

if [ "${#CANDIDATES[@]}" -eq 0 ]; then
  ok "no obsolete kernels (running $RUNNING, newest $NEWEST)"
elif [ ! -t 0 ] && [ ! -r /dev/tty ]; then
  # Never guess when nobody can answer -- see the Timeshift prompt further down.
  ok "${#CANDIDATES[@]} old kernel(s) present; skipped (no terminal to ask on)"
else
  echo "    Running: $RUNNING   Newest: $NEWEST   (both always kept)"
  echo "    Removable kernels:"
  for i in "${!CANDIDATES[@]}"; do
    printf '      %2d) %s  (%s)\n' "$((i+1))" "${CANDIDATES[$i]}" \
      "$(du -shc /boot/*"${CANDIDATES[$i]}"* /lib/modules/"${CANDIDATES[$i]}"-generic 2>/dev/null \
         | awk 'END{print $1}')"
  done
  printf '    Purge which? [numbers/all/none, default none]: '
  read -r REPLY < /dev/tty || REPLY=""
  SELECTED=()
  case "${REPLY,,}" in
    all)          SELECTED=("${CANDIDATES[@]}") ;;
    ''|none|n|no) SELECTED=() ;;
    *)  # commas or spaces; unquoted expansion is word-split only, never eval'd
        for n in ${REPLY//,/ }; do
          case "$n" in
            [0-9]*) [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#CANDIDATES[@]}" ] || continue
                    k="${CANDIDATES[$((n-1))]}"
                    [[ " ${SELECTED[*]:-} " == *" $k "* ]] || SELECTED+=("$k") ;;
          esac
        done ;;
  esac
  if [ "${#SELECTED[@]}" -eq 0 ]; then
    ok "kept all kernels"
  else
    for k in "${SELECTED[@]}"; do
      apt-get purge -y "linux-image-$k-generic" "linux-headers-$k" \
                       "linux-headers-$k-generic" "linux-modules-$k-generic" \
                       "linux-modules-extra-$k-generic" >/dev/null 2>&1
      ok "removed obsolete kernel $k"
    done
    update-grub >/dev/null 2>&1
  fi
fi
}

# ------------------------------------------------------------ 2. TIMESHIFT
sec_timeshift() {
say "2/8  Removing Timeshift snapshots (you said you're not using it)"
if command -v timeshift >/dev/null; then
  # --scripted suppresses interactive prompts; --snapshot-device stops the
  # "Select backup device:" prompt that --yes does not answer. No pipe here:
  # tail buffers until EOF and would hide any prompt that does appear.
  # timeout is a backstop -- timeshift logs "[timeout] Exit application" after
  # 60s but the GTK loop does not actually exit, so it blocks forever.
  # Resolve the snapshot device from timeshift's own config, falling back to
  # the root device, so this is not pinned to one machine's /dev/sda2.
  TS_UUID=$(grep -oP '"backup_device_uuid"\s*:\s*"\K[^"]*' /etc/timeshift/timeshift.json 2>/dev/null)
  TS_DEV=$(blkid -U "$TS_UUID" 2>/dev/null)
  [ -n "$TS_DEV" ] || TS_DEV=$(findmnt -no SOURCE / 2>/dev/null)
  # Captured first: timeshift --list writes a table, and grep -q exiting on the
  # first row SIGPIPEs it under pipefail -- reporting "no snapshots" when there
  # are some, which here would skip a deletion the user asked for. See lint.sh.
  TS_LIST=$(timeout 60 timeshift --list --scripted --snapshot-device "$TS_DEV" 2>/dev/null)
  if grep -q '^[0-9]' <<< "$TS_LIST"; then
    timeout 300 timeshift --delete-all --yes --scripted --snapshot-device "$TS_DEV"
    ok "snapshots deleted"
  else
    ok "no snapshots present, nothing to delete"
  fi
  # turn every schedule off so it stops rebuilding
  sed -i 's/"schedule_\(monthly\|weekly\|daily\|hourly\|boot\)" : "true"/"schedule_\1" : "false"/g' \
      /etc/timeshift/timeshift.json 2>/dev/null
  ok "all schedules disabled (package kept, re-enable any time)"
fi
}

# ----------------------------------------------------------------- 3. ZRAM
sec_zram() {
say "3/8  Enabling zram  <-- the big one for 4GB"
apt-get install -y systemd-zram-generator >/dev/null 2>&1
cat > /etc/systemd/zram-generator.conf <<'EOF'
# Compressed swap in RAM. zstd averages ~3:1, so a 3.8G zram device
# holds roughly 3.8G of pages while occupying ~1.3G of real RAM.
# Priority 100 puts it ahead of /swapfile (-2), which stays as overflow.
[zram0]
zram-size = ram
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service 2>/dev/null
ok "zram0 configured (zstd, size = 100% of RAM)"
}

# --------------------------------------------------------------- 4. SYSCTL
sec_sysctl() {
say "4/8  Tuning VM for zram"
cat > /etc/sysctl.d/99-zram-lowmem.conf <<'EOF'
# swappiness is intentionally HIGH with zram: swapping to compressed RAM
# is cheap, so we want the kernel to prefer it over evicting page cache.
vm.swappiness = 180
vm.page-cluster = 0
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.vfs_cache_pressure = 50
EOF
sysctl --system >/dev/null 2>&1
ok "swappiness 60 -> 180, page-cluster 0 (zram is random-access)"
}

# ------------------------------------------------------------- 5. EARLYOOM
sec_earlyoom() {
say "5/8  Installing earlyoom (prevents hard freezes at 4GB)"
apt-get install -y earlyoom >/dev/null 2>&1
cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-r 3600 -m 4 -s 4 --avoid '(^|/)(systemd|Xorg|cinnamon|cinnamon-session|sshd|mysqld|apache2)$' --prefer '(^|/)(chromium|chrome|firefox)$'"
EOF
systemctl enable --now earlyoom >/dev/null 2>&1
ok "earlyoom active; will kill a browser tab before the desktop locks up"
}

# ------------------------------------------------------------ 6. SSD/FSTAB
sec_noatime() {
say "6/8  Reducing SSD writes (noatime)"
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d)
# Find the root entry by its mount point (field 2) rather than by a hardcoded
# UUID, so this works on any machine and with UUID=/LABEL=/device-path fstabs.
# awk only rebuilds the record it modifies; every other line prints byte-for-byte.
awk 'BEGIN{OFS="\t"}
     /^[[:space:]]*#/ {print; next}
     NF>=4 && $2=="/" && $4 !~ /(^|,)noatime(,|$)/ {
       # Drop any conflicting atime option first: mount applies options left to
       # right, so a trailing relatime would silently cancel the noatime.
       n=split($4,o,","); out=""
       for(i=1;i<=n;i++){
         if(o[i]=="relatime"||o[i]=="atime"||o[i]=="strictatime"||o[i]=="diratime") continue
         out=(out==""?o[i]:out","o[i])
       }
       $4=(out==""?"noatime":"noatime," out)
     }
     {print}' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
grep -E '\s/\s' /etc/fstab
mount -o remount,noatime / 2>/dev/null && ok "root remounted noatime (fstab backed up)"
}

# ------------------------------------------------------------- 7. SERVICES
sec_services() {
say "7/8  Disabling hardware you don't have"
systemctl disable --now ModemManager.service >/dev/null 2>&1 && ok "ModemManager off (no cellular modem)"
systemctl mask casper.service casper-md5check.service >/dev/null 2>&1 && ok "casper masked (live-USB leftover; this was your failed unit)"

# GStreamer's Intel Media SDK plugin. libmfx has no Haswell path, so it falls
# through to the legacy i965 VA-API driver, asks for a surface format that
# driver cannot allocate, and i965 answers with assert() instead of an error
# return -- taking the whole plugin scanner process down with it:
#
#   gst-plugin-scanner: i965_drv_video.c:4653: i965_check_alloc_surface_bo:
#     Assertion `subsampling == SUBSAMPLE_YUV420 || ...' failed.
#
# GStreamer itself survives this -- the plugin is blacklisted and the scan
# finishes -- so nothing looks broken. The cost is a 24MB apport report and a
# mintreport popup every time a registry is built from cold, and cold builds are
# not rare: any GUI app run as root starts with an empty /root/.cache. Media SDK
# needs Skylake or newer, so there is nothing here to lose on a Haswell Air.
#
# Diverted rather than deleted, so an upgrade of gstreamer1.0-plugins-bad does
# not quietly put it back. This is the section worth re-running on its own:
# a reinstall of gstreamer1.0-plugins-bad is the one thing that undoes it.
MSDK=/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstmsdk.so
# Captured, not piped: dpkg-divert --list writes a line and grep -q exits on it,
# SIGPIPEing dpkg-divert, which under pipefail reads as "not diverted" and would
# make this step run again on every invocation. See lint.sh.
DIVERTED=$(dpkg-divert --list "$MSDK" 2>/dev/null)
if grep -q . <<< "$DIVERTED"; then
  ok "gstreamer msdk plugin already diverted"
elif [ -e "$MSDK" ]; then
  dpkg-divert --add --rename --divert "$MSDK.disabled" "$MSDK" >/dev/null 2>&1 \
    && ok "gstreamer msdk plugin diverted (aborts the plugin scanner on i965; Media SDK is Skylake+)"
else
  ok "gstreamer msdk plugin not installed, nothing to divert"
fi
}

# ---------------------------------------------------------------- 8. MYSQL
sec_mysql() {
say "8/8  Tuning MySQL 8 for 4GB (kept running - it's your toolchain)"
cat > /etc/mysql/mysql.conf.d/zz-lowmem.cnf <<'EOF'
[mysqld]
# MySQL 8's performance_schema alone costs 200-400MB of RSS.
# On a dev box that's the single largest avoidable allocation.
performance_schema              = OFF
innodb_buffer_pool_size         = 128M
innodb_buffer_pool_instances    = 1
innodb_log_buffer_size          = 8M
key_buffer_size                 = 8M
tmp_table_size                  = 16M
max_heap_table_size             = 16M
table_open_cache                = 200
max_connections                 = 30
host_cache_size                 = 0
EOF
systemctl restart mysql 2>/dev/null && ok "MySQL restarted with low-memory profile"
}

# --------------------------------------------------------------- VERIFY
sec_verify() {
say "Verification"
echo "--- zram ---";        zramctl 2>/dev/null || echo "  (zramctl unavailable)"
echo "--- swap devices ---"; swapon --show
echo "--- memory ---";       free -h
echo "--- earlyoom ---";     systemctl is-active earlyoom
echo "--- root mount ---";   findmnt -no OPTIONS / | tr ',' '\n' | grep -E 'atime' || true
echo "--- failed units ---"; systemctl --failed --no-pager | head -4
echo
echo "Disk free: $BEFORE_FREE  ->  $(df -h / | awk 'NR==2{print $4}')"
echo
echo "Reboot when convenient so zram and noatime apply from a clean boot."
}

# ---------------------------------------------------------------- DRIVER
list_sections() {
  echo
  echo "  #  name        what it does"
  for i in "${!SECTIONS[@]}"; do
    printf '  %d  %-10s  %s\n' "$((i+1))" "${SECTIONS[$i]}" "${DESCRIBE[$i]}"
  done
  echo
  echo "  With no arguments all eight run in this order, then a verification pass."
  echo
}

usage() {
  cat <<EOF

optimize-mba.sh -- memory and disk tuning for a 4GB MacBookAir6,1

  $0                  everything, then verify
  $0 <name|number>    just that section (repeatable)
  $0 --list           the section table
  $0 --help           this

Selection runs in canonical order regardless of the order you type it, because
zram has to exist before the sysctls that assume it.

EOF
}

# Accept a name or a number, print the canonical name, fail if neither.
resolve() {
  local a="$1" s
  case "$a" in
    [1-8]) printf '%s' "${SECTIONS[$((a-1))]}"; return 0 ;;
  esac
  for s in "${SECTIONS[@]}"; do
    [ "$s" = "$a" ] && { printf '%s' "$s"; return 0; }
  done
  return 1
}

main() {
  local want=() a s
  for a in "$@"; do
    case "$a" in
      -h|--help|help)  usage; exit 0 ;;
      -l|--list|list)  list_sections; exit 0 ;;
      --only)          continue ;;   # so --only services reads naturally too
      *) if s=$(resolve "$a"); then
           want+=("$s")
         else
           echo "Unknown section: $a" >&2; list_sections; exit 1
         fi ;;
    esac
  done

  # Checked after parsing so --list and --help work unprivileged.
  [ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

  BEFORE_FREE=$(df -h / | awk 'NR==2{print $4}')

  if [ "${#want[@]}" -eq 0 ]; then
    for s in "${SECTIONS[@]}"; do "sec_$s"; done
    sec_verify
    return 0
  fi

  # Canonical order, and each section at most once however it was typed.
  local ran=0
  for s in "${SECTIONS[@]}"; do
    [[ " ${want[*]} " == *" $s "* ]] || continue
    "sec_$s"
    ran=$((ran + 1))
  done
  echo
  echo "Ran $ran of ${#SECTIONS[@]} sections; no verification pass (it reports the"
  echo "whole machine's state, which on a partial run says nothing about what ran)."
}

main "$@"
