#!/bin/bash
# List what is in the login keyring -- labels and lookup attributes, never the
# secrets themselves.
#
# WHY THIS EXISTS
#
# `secret-tool` can store, lookup and clear, but it cannot ENUMERATE: every
# operation needs the attributes up front, so you have to already know what you
# are looking for. And Seahorse 43 does not reliably show items added by
# secret-tool -- it caches its list and will not pick up anything stored while
# it was open. That combination makes it easy to believe a secret was never
# saved when it is sitting there.
#
# The Secret Service D-Bus API can enumerate, so this asks it directly. Reading
# the Label and Attributes properties does NOT unlock or reveal any secret; the
# only thing that would is GetSecret, which this never calls.
#
# The attributes printed are exactly what you pass back to secret-tool:
#
#     restic joe-MacBookAir   {'restic': 'joe-MacBookAir'}
#     -> secret-tool lookup restic joe-MacBookAir

set -u

# shellcheck source=/dev/null
. "$(dirname "$0")/lib-say.sh" 2>/dev/null || {
  say()  { printf '\n  \033[1;36m== %s\033[0m\n' "$1"; }
  ok()   { printf '  \033[32m[ok]\033[0m   %s\n' "$1"; }
  bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
  info() { printf '  --    %s\n' "$1"; }
}

SECRETS_DEST=org.freedesktop.secrets
SVC_PATH=/org/freedesktop/secrets

command -v gdbus >/dev/null || { bad "gdbus missing (apt install libglib2.0-bin)"; exit 1; }

prop() {   # $1 = object path, $2 = interface, $3 = property
  gdbus call --session --dest "$SECRETS_DEST" --object-path "$1" \
    --method org.freedesktop.DBus.Properties.Get "$2" "$3" 2>/dev/null
}

# Object paths come back as a D-Bus variant holding an array. Pull out the
# paths with grep rather than trying to parse the whole structure -- the label
# text can contain quotes and brackets, and has.
paths_from() { grep -o "$SVC_PATH/collection/[A-Za-z0-9_/]*" ; }

unquote() { sed "s/^(<'\{0,1\}//; s/'\{0,1\}>,)$//"; }

collections=$(prop "$SVC_PATH" org.freedesktop.Secret.Service Collections | paths_from | sort -u)
[ -n "$collections" ] || { bad "no collections -- is gnome-keyring running?"; exit 1; }

total=0
for c in $collections; do
  # The session collection is in-memory and empty by design; skip the noise.
  case "$c" in */session) continue ;; esac

  label=$(prop "$c" org.freedesktop.Secret.Collection Label | unquote)
  locked=$(prop "$c" org.freedesktop.Secret.Collection Locked | grep -c true)

  say "${label:-$(basename "$c")}"
  if [ "$locked" != 0 ]; then
    info "locked -- unlock it by logging in graphically, or run: secret-tool lookup <attr> <value>"
    continue
  fi

  items=$(gdbus call --session --dest "$SECRETS_DEST" --object-path "$c" \
          --method org.freedesktop.Secret.Collection.SearchItems "{}" 2>/dev/null \
          | grep -o "$SVC_PATH/collection/[A-Za-z0-9_/]*")

  for i in $items; do
    # SearchItems echoes the collection path too, and it matches the same grep
    # as its items. Item paths are always DEEPER than the collection, so accept
    # only those -- an equality test alone let the collection through as a
    # phantom "(no label)" row with no attributes.
    case "$i" in "$c"/?*) ;; *) continue ;; esac
    ilabel=$(prop "$i" org.freedesktop.Secret.Item Label | unquote | sed 's/^"//; s/"$//')
    iattr=$(prop "$i" org.freedesktop.Secret.Item Attributes | sed 's/^(<//; s/>,)$//')
    # xdg:schema is boilerplate on every item and drowns the useful attributes.
    iattr=$(echo "$iattr" | sed "s/, *'xdg:schema': *'[^']*'//")
    printf '  %-34s %s\n' "${ilabel:-(no label)}" "$iattr"
    total=$((total + 1))
  done
done

echo
ok "$total item(s). Secrets were not read -- only labels and attributes."
info "Retrieve one with:  secret-tool lookup <attribute> <value>"
