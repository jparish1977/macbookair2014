#!/bin/bash
# Test an update before this machine takes it, in one command.
#
# WHAT THIS IS FOR
#
# The pieces already exist and each has to be driven separately, in the right
# order, across two machines. This is the wrapper: snapshot the laptop, push it
# offsite, rebuild it in a VM on iteration8, run the update there, and come back
# with a verdict and the exact next steps.
#
#     ./preflight.sh
#
# Roughly an hour, mostly unattended. It asks for your sudo password once, near
# the start, and nothing after that.
#
# THE SNAPSHOT IS DOING TWO JOBS, AND THAT IS THE POINT
#
# It is the input to the test -- the VM is rebuilt from it, so what gets tested
# is THIS machine as it stands, not an approximation. And it is the rollback
# point if the update turns out badly on the metal. One artefact, both jobs, and
# the second is why the order matters: the snapshot has to be taken before
# anything is applied here.
#
# WHAT A PASS DOES AND DOES NOT MEAN
#
# A pass means the update installs, the DKMS modules build for the new kernel,
# the machine boots it, and every fix this project installs still holds. It does
# NOT mean Wi-Fi associates, the camera captures, or the backlight lights -- a VM
# has no BCM4360, no FaceTime HD and no Apple SMC. That last mile is one boot on
# the metal, and this prints the exact commands for it.
#
# WHY IT RUNS FROM THE LAPTOP
#
# Only the laptop can snapshot itself, and only the laptop knows whether it is on
# mains. Everything expensive happens on iteration8 over the tailnet.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REMOTE="${MBA_PREFLIGHT_HOST:-iteration8.tail51fded.ts.net}"
REMOTE_DIR="${MBA_PREFLIGHT_DIR:-/srv/mba-vmtest}"
DRY=0
UNHOLD="--unhold"
SKIP_PUSH=0
CONFIRM=0

say()  { echo; echo -e "\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m[ok]\033[0m   $*"; }
warn() { echo -e "    \033[33m[warn]\033[0m $*"; }
bad()  { echo -e "    \033[31m[!!]\033[0m   $*"; }
info() { echo "    $*"; }
die()  { echo; echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }

usage() {
  cat <<EOF

preflight.sh -- test an update before this machine takes it

  $0                 snapshot, push, rebuild in a VM, run the update, report
  $0 --keep-holds    do not lift the kernel holds in the test VM
  $0 --skip-push     reuse the offsite copy as it is (no new snapshot)
  $0 --confirm-good  after applying the update and rebooting: check this machine
                     really is good, then make it the new rollback point
  $0 --dry-run       print every step and change nothing
  $0 --help

Runs from the laptop; the expensive work happens on $REMOTE.
Asks for sudo once, to take the snapshot. Allow about an hour.

EOF
  exit 1
}

for a in "$@"; do
  case "$a" in
    --dry-run)    DRY=1 ;;
    --keep-holds) UNHOLD="" ;;
    --skip-push)  SKIP_PUSH=1 ;;
    --confirm-good) CONFIRM=1 ;;
    -h|--help)    usage ;;
    *)            die "unknown option: $a" ;;
  esac
done

run() {   # short remote step, streaming output
  if [ "$DRY" = 1 ]; then echo "    would run on $REMOTE:  $*"; return 0; fi
  ssh -o BatchMode=yes "$REMOTE" "cd $REMOTE_DIR && $*"
}

# Long remote step, detached, polled.
#
# The restore and the update each run for 15-20 minutes, and holding one ssh
# connection open that long FROM THIS LAPTOP is asking for trouble: Wi-Fi is the
# only interface and its lockups are a documented open thread (see WIFI.md). A
# dropped connection would abort a run that was otherwise fine and had another
# ten minutes of work banked.
#
# So the work is detached on the far side and this polls for it. The connection
# becoming unavailable now costs a poll, not the run.
run_long() {   # $1 = short label, rest = command
  local label="$1"; shift
  local log="preflight-$label.log" rcf=".preflight-$label.rc"
  if [ "$DRY" = 1 ]; then echo "    would run on $REMOTE (detached):  $*"; return 0; fi

  # The redirections have to apply to the BACKGROUNDED GROUP, not just to the
  # command inside it. Redirect only the inner command and the group still holds
  # the ssh channel open, so ssh never returns -- and then this function blocks
  # on the launch instead of polling, and the caller sees no progress at all
  # while the job runs perfectly well on the far side. That is exactly how it
  # failed the first time it was used for real: the restore ran to completion
  # with the screen showing nothing.
  ssh -o BatchMode=yes -n "$REMOTE" \
    "cd $REMOTE_DIR && rm -f $log $rcf && { setsid sh -c '$* > $log 2>&1; echo \$? > $rcf' & } </dev/null >/dev/null 2>&1" \
    || die "could not start $label on $REMOTE"

  local waited=0 rc="" last="" line
  local timeout="${MBA_PREFLIGHT_TIMEOUT:-9000}"
  while [ "$waited" -lt "$timeout" ]; do
    sleep 20; waited=$((waited + 20))
    rc=$(ssh -o BatchMode=yes -n -o ConnectTimeout=15 "$REMOTE" "cat $REMOTE_DIR/$rcf 2>/dev/null" 2>/dev/null)
    [ -n "$rc" ] && break
    line=$(ssh -o BatchMode=yes -n -o ConnectTimeout=15 "$REMOTE" \
           "grep -E '^  (==|ok|--) ' $REMOTE_DIR/$log 2>/dev/null | tail -1" 2>/dev/null)
    [ -n "$line" ] && [ "$line" != "$last" ] && { last="$line"; info "$(printf '%4sm' $((waited / 60)))  ${line#  }"; }
  done
  # A job that finishes before the first poll printed NOTHING, because the loop
  # only reports lines as they change. The restore skipping in 24ms did exactly
  # that: it completed correctly and the screen showed a heading and silence.
  if [ -z "$last" ]; then
    ssh -o BatchMode=yes -n "$REMOTE" \
      "grep -E '^  (==|ok|--|WARN) ' $REMOTE_DIR/$log 2>/dev/null | tail -4" 2>/dev/null \
      | sed 's/^  /    /'
  fi
  [ -n "$rc" ] || { bad "$label did not finish within $((timeout / 60)) minutes"; return 1; }
  return "$rc"
}

fetch_log() {  # $1 = label -> prints the remote log
  ssh -o BatchMode=yes -n "$REMOTE" "cat $REMOTE_DIR/preflight-$1.log 2>/dev/null" 2>/dev/null
}

local_run() {
  if [ "$DRY" = 1 ]; then echo "    would run here:  $*"; return 0; fi
  "$@"
}

# ------------------------------------------------------------- confirm-good
#
# The other half of the loop, and the reason it is a SEPARATE run: the things a
# VM could not test only become answerable after the update is applied here and
# the machine has actually rebooted. So this is what you run once it is back up.
#
# It checks before it snapshots, deliberately. A snapshot labelled "known good"
# of a machine that is not good is worse than no snapshot at all -- it is a
# rollback point that restores the problem, and you would not find out until the
# day you needed it.
cmd_confirm_good() {
  say "Is this machine actually good?"
  local fail=0 k; k=$(uname -r)
  info "running kernel: $k"

  # wl first. It is the one whose absence strands the machine, and the only
  # interface this laptop has.
  # `lsmod | grep -q` is a trap under `set -o pipefail`: grep -q exits on the
  # first match, lsmod dies of SIGPIPE (141), and the pipeline reports failure on
  # a successful match. It bit here first -- "wl is NOT loaded" printed on a
  # machine that was at that moment talking over Wi-Fi. Capture, then match.
  MODS=$(lsmod)
  if grep -q '^wl ' <<< "$MODS"; then
    ok "wl is loaded"
  else
    bad "wl is NOT loaded -- this machine has no working Wi-Fi driver"
    fail=1
  fi

  if grep -q wlp <<< "$(ip link show 2>/dev/null)"; then
    if grep -q connected <<< "$(nmcli -t -f STATE general 2>/dev/null)"; then
      ok "Wi-Fi is connected"
    else
      warn "NetworkManager does not report a connection"
    fi
  fi

  grep -q '^facetimehd' <<< "$MODS" && ok "facetimehd is loaded" || warn "facetimehd is not loaded (camera)"

  local n; n=$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)
  if [ "$n" = 0 ]; then ok "no failed units"
  else warn "$n failed unit(s): $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"; fi

  if [ -x "$HERE/kernel-guard.sh" ]; then
    "$HERE/kernel-guard.sh" check --quiet-ok >/dev/null 2>&1
    case $? in
      0) ok "kernel-guard: every installed kernel has its drivers" ;;
      1) warn "kernel-guard reports a non-critical gap (camera)" ;;
      *) bad "kernel-guard reports the newest kernel has no wl"; fail=1 ;;
    esac
  fi

  if [ "$fail" = 1 ]; then
    echo
    bad "NOT marking this as known-good"
    info "Fix the above first, or roll back:  ./system-snapshot.sh list"
    exit 1
  fi

  say "Making this the new rollback point"
  info "Your previous snapshot is the PRE-update state -- keep it until you are"
  info "confident, then prune. This adds a post-update known-good beside it."
  local stamp="known good, post-update $k"
  local_run sudo "$HERE/system-snapshot.sh" create "$stamp" || die "the snapshot failed"
  ok "snapshot taken: $stamp"

  if [ "$SKIP_PUSH" = 1 ]; then
    warn "not pushing offsite (--skip-push). The VM baseline stays where it was."
  else
    say "Pushing it offsite, so the next pre-flight tests from HERE"
    info "This is what stops golden.qcow2 drifting behind the real machine."
    local_run sudo "$HERE/snapshot-offsite.sh" push || die "the push failed (the snapshot is still local and valid)"
    ok "offsite copy up to date"
  fi

  echo
  ok "done -- this machine is the new known-good, locally and offsite"
  info "Prune the older ones when you are ready:  sudo ./system-snapshot.sh prune"
  echo
  exit 0
}

# ---------------------------------------------------------------- pre-flight

# Refuse to run as root, rather than half-working and blaming the network.
#
# Under sudo, ssh reads /root/.ssh/known_hosts -- which has never seen
# iteration8 -- and BatchMode cannot prompt, so it fails with "cannot reach" and
# sends you at the network when the network is fine. This repo has already lost
# time to exactly that once (see snapshot-offsite.sh). rsync would go as
# root@iteration8, and anything created here would come out root-owned.
#
# The one step that genuinely needs root calls sudo itself, and so does the push
# -- which reads SUDO_USER to find YOUR ssh key rather than root's. That only
# works when this script is started as you.
if [ "$(id -u)" = 0 ]; then
  bad "do not run this with sudo"
  info "Under sudo, ssh uses root's known_hosts and keys, and this fails as a"
  info "network error that is not a network error. The steps that need root ask"
  info "for it themselves -- and the push needs SUDO_USER set to find your key."
  die "run it as yourself:  ./preflight.sh"
fi

say "Checks before anything is changed"

[ -x "$HERE/system-snapshot.sh" ]  || die "system-snapshot.sh is not next to this script"
[ -x "$HERE/snapshot-offsite.sh" ] || die "snapshot-offsite.sh is not next to this script"
[ -x "$HERE/vm-restore-test.sh" ]  || die "vm-restore-test.sh is not next to this script"
ok "the scripts this drives are all here"

# Mains, not battery. A snapshot plus a push is tens of minutes of sustained
# disk and Wi-Fi on a machine whose battery is eleven years old, and logrotate
# on this laptop already refuses to run on battery for the same reason.
if [ -r /sys/class/power_supply/ADP1/online ] && [ "$(cat /sys/class/power_supply/ADP1/online)" != 1 ]; then
  bad "this machine is on battery"
  die "plug it in first -- the snapshot and push run for tens of minutes"
fi
ok "on mains"

# Reachable BY TAILNET NAME. The bare `iteration8` alias resolves to a .local
# address and works only at home, which is a confusing way to fail when away.
# --confirm-good --skip-push touches nothing remote, so do not fail it for a
# network it does not need. Everything else does need iteration8.
if [ "$CONFIRM" = 1 ] && [ "$SKIP_PUSH" = 1 ]; then
  info "$REMOTE not needed (--confirm-good --skip-push)"
elif [ "$DRY" = 0 ]; then
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$REMOTE" true 2>/dev/null \
    || die "cannot reach $REMOTE over ssh. On the tailnet? 'tailscale status'"
  ok "$REMOTE reachable"
else
  ok "$REMOTE reachable"
fi

if [ "$DRY" = 0 ]; then
  free_gb=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
  [ "${free_gb:-0}" -ge 25 ] || die "only ${free_gb}G free on / -- a snapshot needs ~20G headroom"
  ok "${free_gb}G free on /"
fi

# Only now. cmd_confirm_good takes a snapshot -- minutes of sustained disk I/O --
# so it needs the mains and free-space checks every bit as much as a full run
# does. Dispatching it earlier skipped both, which is how it came to be runnable
# on battery in a car.
[ "$CONFIRM" = 1 ] && cmd_confirm_good

# What is even pending? If nothing is, the whole run would end in "the upgrade
# changed nothing" an hour from now, and it is much kinder to say so up front.
say "What this machine has waiting"
pending_pkgs=$(apt list --upgradable 2>/dev/null | grep 'upgradable from' | cut -d/ -f1 | tr '\n' ' ')
pending=$(echo "$pending_pkgs" | wc -w)
held=$(apt-mark showhold 2>/dev/null | tr '\n' ' ')
info "$pending package(s) upgradable: ${pending_pkgs:-none}"
[ -n "$held" ] && info "held: $held"
if [ "$pending" = 0 ]; then
  warn "nothing is pending, so there is nothing to pre-flight"
  info "Run it anyway to re-prove the rig, or stop here."
fi

# ------------------------------------------------------------------ snapshot

if [ "$SKIP_PUSH" = 1 ]; then
  say "Skipping the snapshot and push (--skip-push)"
  warn "using the offsite copy as it stands -- check it is the snapshot you meant"
else
  say "Snapshotting this machine (sudo -- this is the one prompt)"
  info "This is both the input to the test AND your rollback point."
  stamp="preflight $(date +%Y-%m-%d\ %H:%M)"
  local_run sudo "$HERE/system-snapshot.sh" create "$stamp" \
    || die "the snapshot failed -- nothing has been changed"
  ok "snapshot taken: $stamp"

  say "Pushing it to $REMOTE (this is the long part)"
  info "Incremental -- only what changed since the last push crosses Wi-Fi."
  # sudo, because push has to read the snapshot tree and that is root-owned.
  # snapshot-offsite.sh expects this -- it reads SUDO_USER to find the invoking
  # user's ssh key rather than root's.
  local_run sudo "$HERE/snapshot-offsite.sh" push \
    || die "the push failed. The snapshot is still here and still valid."
  ok "offsite copy up to date"
fi

# ------------------------------------------------------- rebuild and test

say "Deploying this repo to $REMOTE"
if [ "$DRY" = 1 ]; then
  echo "    would rsync $HERE/ to $REMOTE:$REMOTE_DIR/"
else
  rsync -a --exclude '.git' --exclude '*.qcow2' --exclude '.offsite.conf' \
    "$HERE/" "$REMOTE:$REMOTE_DIR/" || die "could not deploy the repo"
fi
ok "repo deployed"

say "Rebuilding this machine in a VM from the offsite copy"
info "Usually 15-25 minutes, but it has run to 30. Nothing here is touched."
info "Do not kill it for being slow -- watch the step numbers, not the clock."
run_long restore ./vm-restore-test.sh restore \
  || die "the VM restore failed -- see $REMOTE:$REMOTE_DIR/preflight-restore.log"

say "Adding a serial console so the VM can be asked questions"
run ./vm-restore-test.sh testbase || die "could not build the test image"

say "Running the update in the VM"
info "The upgrade happens in a disposable overlay. The laptop is not involved."
run_long update ./vm-restore-test.sh update-test $UNHOLD
verdict=$?

UPLOG="${TMPDIR:-/tmp}/preflight-update.log"
if [ "$DRY" = 0 ]; then
  fetch_log update > "$UPLOG"
  # Show the part that matters rather than 200 lines of apt.
  sed -n '/what the upgrade did/,/^$/p;/\[pass\]/p;/\[FAIL\]/p;/passed,/p' "$UPLOG" | sed 's/^/    /'
fi

# The exact kernel the VM installed and booted, so the instructions below can
# name it instead of saying <new-version> and making you go and look.
NEWK=$(grep -o 'BOOT-TEST-ARMED: [^ ]*' "$UPLOG" 2>/dev/null | tail -1 | awk '{print $2}')
[ -n "$NEWK" ] || NEWK="<new-version>"

# --------------------------------------------------------------- the verdict

echo
case "$verdict" in
  0)
    # Was a KERNEL actually installed, or did packages just move?
    #
    # These need different advice and the difference is not cosmetic. A
    # bookkeeping upgrade cannot affect Wi-Fi, the camera, the backlight or
    # sound, because those only break when the kernel changes -- so telling
    # someone to boot-test and re-check four pieces of hardware is telling them
    # to do nothing, slowly. Worse, the boilerplate used to assert "both DKMS
    # modules built for the new kernel, that kernel booted" when there was no
    # new kernel and the boot had graded the one already running.
    # Trim trailing space only. `tr -d " "` would glue a two-kernel list into
    # one nonsense token.
    newk_list=$(echo "$report" | sed -n 's/^NEW-KERNELS: *//p' | tail -1 | sed 's/[[:space:]]*$//')
    unheld=$(echo "$report" | sed -n 's/^UNHELD: //p' | tail -1)
    metas="${pending_pkgs:-<the pending meta-packages>}"

    if [ -z "$newk_list" ] || [ "$newk_list" = "none" ]; then
      say "VERDICT: safe, and it does not touch the kernel"
      echo
      info "Packages upgraded, but no kernel was added or removed. Installed"
      info "before and after:"
      info "  $(echo "$report" | sed -n 's/^KERNELS-AFTER: *//p' | tail -1)"
      echo
      info "That is the important part: the four things a VM cannot test --"
      info "Wi-Fi associating, the camera, sound, the backlight -- are only at"
      info "risk from a KERNEL change. There is not one here, so there is"
      info "nothing for a boot on the metal to prove."
      echo
      echo "  Apply it, and put the holds straight back:"
      echo
      echo "    sudo apt-mark unhold $metas"
      echo "    sudo apt-get install --only-upgrade $metas"
      echo "    sudo apt-mark hold $metas"
      echo
      info "The third line is not optional. Leaving them unheld removes the"
      info "protection that stops a new kernel arriving unannounced, which has"
      info "been the procedure on this machine."
      info ""
      info "No reboot. The running kernel is untouched, so --confirm-good has"
      info "nothing new to confirm either."
      echo
    else
      say "VERDICT: the update looks safe, and it brings a new kernel"
      echo
      info "In the VM, $newk_list installed, broadcom-sta and facetimehd both"
      info "built for it, it booted, and every fix this project installs held."
      echo
      info "What is still unproven, and cannot be proven without the hardware:"
      info "  Wi-Fi associating, the camera capturing, sound coming out of the"
      info "  speakers, and the keyboard backlight physically lighting."
      echo
      echo "  Next, at the keyboard:"
      echo
      echo "    # 1. Let the new kernel in, then put the protection straight"
      echo "    #    back. The versioned holds stay -- those are what you fall"
      echo "    #    back TO if this goes wrong."
      echo "    sudo apt-mark unhold $metas"
      echo "    sudo apt-get install --only-upgrade $metas"
      echo "    sudo apt-mark hold $metas"
      echo
      echo "    # 2. Confirm every kernel still has its drivers BEFORE rebooting."
      echo "    ./kernel-guard.sh check"
      echo
      echo "    # 3. Boot the new kernel ONCE. If it fails, the next boot returns"
      echo "    #    to the current default on its own."
      echo "    sudo ./kernel-guard.sh boot-test $newk_list"
      echo "    sudo reboot"
      echo
      echo "    # 4. After it comes up -- the four things the VM could not test:"
      echo "    uname -r                       # expect $newk_list"
      echo "    ./mba-wifi.sh status           # Wi-Fi actually associated"
      echo "    ./mba-webcam.sh status         # camera"
      echo "    ./kbd-backlight.sh status      # backlight trigger"
      echo
      echo "    # 5. Once it is up and those four all look right, make THIS the"
      echo "    #    new rollback point -- otherwise it stays the pre-update state"
      echo "    #    and golden.qcow2 drifts behind the real machine:"
      echo "    ./preflight.sh --confirm-good"
      echo
      echo "    # If it goes wrong: reboot to the previous kernel from the GRUB"
      echo "    # menu, or roll the whole system back to the snapshot taken above:"
      echo "    ./system-snapshot.sh list"
      echo
    fi
    [ -n "$unheld" ] && info "(The VM lifted these holds in its own overlay only: $(echo "$unheld" | cut -c1-60)...)"
    echo
    ;;
  2)
    say "VERDICT: nothing to test"
    info "The upgrade changed nothing in the VM, so there is no verdict to give."
    info "That usually means this machine is already up to date."
    ;;
  3)
    say "VERDICT: held back, and deliberately"
    info "The kernel packages are on hold -- that is mba-wifi.sh keeping a"
    info "known-good fallback installed, working as intended."
    echo
    info "To find out whether it would be safe to lift them, re-run this without"
    info "--keep-holds. It lifts them in the VM only; this machine is untouched."
    ;;
  4)
    say "VERDICT: inconclusive"
    bad "the VM did not boot the kernel it installed, so the checks graded the old one"
    info "Do not apply this update yet. See $REMOTE:$REMOTE_DIR/update-run.log"
    ;;
  *)
    say "VERDICT: DO NOT APPLY THIS UPDATE"
    bad "something broke in the VM"
    echo
    info "This machine has not been changed, and the snapshot taken above is"
    info "your rollback point if you apply it anyway and regret it."
    echo
    info "The detail is in:  $REMOTE:$REMOTE_DIR/update-run.log"
    info "Look around inside the failed image with:"
    info "  ssh $REMOTE 'cd $REMOTE_DIR && ./vm-restore-test.sh bootdisk candidate.qcow2'"
    info "  ssh $REMOTE 'cd $REMOTE_DIR && ./vm-restore-test.sh sh \"journalctl -p err -b\"'"
    ;;
esac

echo
exit "$verdict"
