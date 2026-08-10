#!/bin/bash
# Point this machine at a server that server-provision.sh has already set up.
#
#   ./client-setup.sh HOST              # show what it would write, change nothing
#   ./client-setup.sh HOST --write
#
# WHY THIS EXISTS
#
# server-provision.sh made the server side a recipe. The client side was still
# two hand-written config files -- .offsite.conf and .home-backup.conf -- which
# meant somebody had to know the host, the user, the paths and the repo name.
# That is fine for the person who built it and useless for anyone else, and the
# stated goal is that a second machine should be a flip of a switch.
#
# IT ASKS THE SERVER, NOT YOU
#
# server-provision.sh creates a known layout, so this discovers it rather than
# making you recite it: where the snapshot store actually is (following the
# symlink), where restic repos live, and whether the store can hold the xattrs
# that --fake-super depends on. The only thing it needs from you is the host
# name, and it will take the ssh key from wherever ssh already finds one.
#
# WHAT IT WILL NOT DO, DELIBERATELY
#
# Exchange ssh keys, join a tailnet, or set the restic passphrase. Those are
# access decisions and a secret. A setup script that invents them is worse than
# one that names them and stops -- and the passphrase in particular must never
# pass through this project: it belongs to whoever owns the data, and the
# per-user design is what stops two people being able to read each other's
# backups.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST=""; USER_R="$(id -un)"; WRITE=0; FORCE=0

say()  { echo; echo -e "\033[1;36m==> $*\033[0m"; }
ok()   { echo -e "    \033[32m[ok]\033[0m   $*"; }
warn() { echo -e "    \033[33m[warn]\033[0m $*"; }
bad()  { echo -e "    \033[31m[!!]\033[0m   $*"; }
info() { echo "    $*"; }
die()  { echo; echo -e "\033[31mERROR: $*\033[0m" >&2; exit 1; }

usage() {
  cat <<EOF

client-setup.sh -- point this machine at a provisioned server

  $0 HOST                 discover and show; writes nothing
  $0 HOST --write         write .offsite.conf and .home-backup.conf
  $0 HOST --user NAME     remote account (default: $(id -un))
  $0 HOST --force         overwrite configs that already exist

Run server-provision.sh on the server first. Afterwards you still have to:
exchange an ssh key, and set your own restic passphrase.

EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --write) WRITE=1; shift ;;
    --force) FORCE=1; shift ;;
    --user)  USER_R="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1" ;;
    *)  HOST="$1"; shift ;;
  esac
done
[ -n "$HOST" ] || usage

rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$USER_R@$HOST" "$@" 2>/dev/null; }

# ---- reachability ------------------------------------------------------------

say "Reaching $USER_R@$HOST"
if ! rsh true; then
  bad "cannot ssh to $USER_R@$HOST without a password"
  info "That is the one thing this script will not do for you. Give the server"
  info "your public key, then run this again:"
  info ""
  info "  ssh-copy-id $USER_R@$HOST"
  info ""
  info "If you have no key yet:  ssh-keygen -t ed25519"
  exit 1
fi
ok "ssh works without a password"
info "remote: $(rsh 'hostname') running $(rsh '. /etc/os-release 2>/dev/null; echo $PRETTY_NAME')"

# Which key FILE works, because snapshot-offsite.sh passes it to ssh -i and a
# path is the only thing that satisfies that.
#
# Parsing `ssh -v` for it is wrong and looked right: when the key comes from the
# agent, "Offering public key:" prints the key's COMMENT rather than a filename,
# so the first version of this happily wrote
# OFFSITE_KEY=joe@joe-MacBookAir-... into the config. Probing each candidate
# with IdentitiesOnly=yes answers the question that is actually being asked --
# which file authenticates -- rather than inferring it.
KEY=""
for k in "$HOME"/.ssh/id_*; do
  case "$k" in *.pub) continue ;; esac
  [ -f "$k" ] || continue
  if ssh -o BatchMode=yes -o ConnectTimeout=8 -o IdentitiesOnly=yes -i "$k" \
       "$USER_R@$HOST" true 2>/dev/null; then KEY="$k"; break; fi
done
if [ -n "$KEY" ]; then
  ok "ssh key: $KEY"
else
  warn "no key FILE authenticates on its own -- the agent may be holding it"
  info "  snapshot-offsite.sh runs under sudo and passes the key to ssh -i, so"
  info "  it needs a file. Point OFFSITE_KEY at one by hand, or add the key to"
  info "  ~/.ssh/ so root can be told where it is."
fi

# ---- discover the server's layout -------------------------------------------

say "Asking the server where things are"

SNAP_DIR=$(rsh 'readlink -f /srv/mba-snapshots 2>/dev/null || echo ""')
if [ -z "$SNAP_DIR" ]; then
  bad "no snapshot store on $HOST"
  info "Run the server side first:"
  info "  ssh $USER_R@$HOST 'bash -s' < server-provision.sh   # then again with: apply"
  exit 1
fi
ok "snapshot store: $SNAP_DIR"
[ "$SNAP_DIR" = /srv/mba-snapshots ] || info "  (reached as /srv/mba-snapshots, which is a symlink)"

# Can it hold the metadata --fake-super needs? Without this a copy looks fine
# and restores a system that owns nothing correctly, which is the single worst
# failure mode this project has.
if rsh "command -v setfattr >/dev/null && touch $SNAP_DIR/.cs-probe && setfattr -n user.t -v 1 $SNAP_DIR/.cs-probe" ; then
  ok "the store can hold user xattrs -- --fake-super will work"
  rsh "rm -f $SNAP_DIR/.cs-probe"
else
  if ! rsh 'command -v setfattr >/dev/null'; then
    warn "attr is not installed on the server, so this could not be checked"
    info "  ssh $USER_R@$HOST 'sudo apt install attr'   (server-provision.sh installs it)"
  else
    bad "the store CANNOT hold user xattrs"
    info "Snapshots copied there would lose every owner and mode -- a copy that"
    info "looks complete and restores a system that cannot escalate. Fix the"
    info "filesystem before using this host."
    exit 1
  fi
fi

RESTIC_BASE=$(rsh 'ls -d ~/backups/restic 2>/dev/null || echo ""')
if [ -n "$RESTIC_BASE" ]; then
  ok "restic repos live in: $RESTIC_BASE"
else
  warn "no ~/backups/restic on the server -- run server-provision.sh apply there"
  RESTIC_BASE="/home/$USER_R/backups/restic"
fi

REPO_NAME="$(hostname)"
ok "this machine's repo will be: $RESTIC_BASE/$REPO_NAME"
info "  named per-machine on purpose: separate repos with separate passphrases"
info "  mean nobody can browse anyone else's backup by accident."

# ---- compose -----------------------------------------------------------------

OFFSITE_CONF="$HERE/.offsite.conf"
HOME_CONF="$HERE/.home-backup.conf"

read -r -d '' OFFSITE_BODY <<EOF
# Written by client-setup.sh on $(date -I). Untracked, site-specific.
OFFSITE_HOST=$HOST
OFFSITE_USER=$USER_R
OFFSITE_DIR=/srv/mba-snapshots${KEY:+
OFFSITE_KEY=$KEY}
EOF

read -r -d '' HOME_BODY <<EOF
# Written by client-setup.sh on $(date -I). Untracked, site-specific.
#
# Only the location lives here. What gets backed up, what is excluded and how
# long it is kept are defaults in home-backup.sh -- shared, reviewable, and the
# same on every machine unless somebody deliberately overrides them here.
HOME_BACKUP_HOST=$HOST
HOME_BACKUP_USER=$USER_R
HOME_BACKUP_BASE=$RESTIC_BASE
HOME_BACKUP_NAME=$REPO_NAME
EOF

say "Configs"
echo "  --- $OFFSITE_CONF"; echo "$OFFSITE_BODY" | sed 's/^/      /'
echo "  --- $HOME_CONF";    echo "$HOME_BODY"    | sed 's/^/      /'

if [ "$WRITE" != 1 ]; then
  echo
  info "Nothing written. Re-run with --write to save them."
  echo
  exit 0
fi

# Each file decided SEPARATELY. Refusing to write a missing config because a
# different one already exists is how a half-configured machine stays that way:
# the first version bailed on both because .offsite.conf was present, and left
# .home-backup.conf missing while reporting success at the top.
wrote=0 kept=0
write_one() {   # $1 = path, $2 = body
  if [ -e "$1" ] && [ "$FORCE" != 1 ]; then
    warn "kept existing $(basename "$1") -- --force to replace it"
    kept=$((kept + 1))
    return 0
  fi
  printf '%s\n' "$2" > "$1" && chmod 600 "$1" && ok "wrote $(basename "$1")"
  wrote=$((wrote + 1))
}
write_one "$OFFSITE_CONF" "$OFFSITE_BODY"
write_one "$HOME_CONF"    "$HOME_BODY"
[ "$wrote" -gt 0 ] || info "nothing to do -- both configs were already there"

# ---- verify ------------------------------------------------------------------

say "Checking they actually work"
if [ -x "$HERE/home-backup.sh" ]; then
  "$HERE/home-backup.sh" status 2>&1 | sed -n '/Repo/,/^$/p' | sed 's/^/    /'
fi
info "snapshot-offsite.sh status needs root to read the snapshot tree:"
info "  sudo ./snapshot-offsite.sh status"

# ---- the manual tail ---------------------------------------------------------

say "What is left, and why it is not automated"
info "1. Your restic passphrase. Nobody else should ever hold it, including"
info "   this project -- so you set it, and you write it down somewhere that"
info "   is not this machine:"
info ""
info "     secret-tool store --label=\"restic $REPO_NAME\" restic $REPO_NAME"
info "     ./home-backup.sh init"
info "     ./home-backup.sh backup"
info "     ./home-backup.sh restore-test"
info ""
info "   An encrypted backup you cannot decrypt is a thorough way of losing"
info "   your data, and it fails silently until the day you need it."
info ""
info "2. Snapshots of the system side, if you want them:"
info "     sudo ./system-snapshot.sh configure"
info "     sudo ./system-snapshot.sh create \"first snapshot\""
info "     sudo ./snapshot-offsite.sh push"
echo
