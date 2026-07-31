#!/usr/bin/env bash
# Make Google the default search engine in Linux Mint's Chromium.
#
# Mint ships Chromium with a patched prepopulated engine list containing only
# Yahoo and DuckDuckGo, both carrying Mint referral codes:
#
#   Yahoo!      https://yssads.ddc.com/yhs.php?c=19111&surl=https://intl.linuxmint.com&kw={searchTerms}
#   DuckDuckGo  https://duckduckgo.com/?t=lm&q={searchTerms}
#
# Google is not in that list at all, so it has to be added rather than selected.
# Editing ~/.config/chromium/Default/Preferences by hand does not work either:
# default_search_provider_data is listed under protection.macs, so Chromium
# treats an unsigned edit as tampering and reverts it on the next launch.
#
# An enterprise policy is the one route that survives a restart. The tradeoff is
# that a policy is mandatory: chrome://settings/search shows "managed by your
# organization" and cannot be changed in the UI until this is removed. There is
# no unlocked equivalent -- the DefaultSearchProvider* policies are not
# recommendable, so /etc/chromium/policies/recommended/ is ignored for them.
# If you want the setting to stay switchable, skip this script and add Google
# manually in chrome://settings/searchEngines instead.
set -uo pipefail

POLICY_DIR=/etc/chromium/policies/managed
POLICY_FILE="$POLICY_DIR/google-search.json"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()  { printf '    \033[32m[ok]\033[0m %s\n' "$*"; }
no()  { printf '    \033[33m[--]\033[0m %s\n' "$*"; }

usage() {
  cat <<EOF
Usage: sudo $0 [install|remove|status]

  install   Write $POLICY_FILE (default)
  remove    Delete it and hand the setting back to Chromium
  status    Show whether the policy is present, without changing anything
EOF
}

# Policies are read once at startup, so a running browser keeps the old engine
# until it is fully quit -- every window, not just the last one you looked at.
warn_if_running() {
  if pgrep -x chromium >/dev/null 2>&1 || pgrep -f '/usr/lib/chromium/chromium' >/dev/null 2>&1; then
    no "Chromium is running; quit it completely for this to take effect"
  fi
}

ACTION="${1:-install}"
case "$ACTION" in
  -h|--help|help) usage; exit 0 ;;
  status)
    say "Chromium default search policy"
    if [ -f "$POLICY_FILE" ]; then
      ok "$POLICY_FILE present"
      cat "$POLICY_FILE"
    else
      no "no policy at $POLICY_FILE (Chromium is using Mint's default)"
    fi
    echo
    echo "Confirm what Chromium actually loaded at: chrome://policy"
    exit 0
    ;;
  install|remove) ;;
  *) usage; exit 1 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

if [ "$ACTION" = remove ]; then
  say "Removing the Google search policy"
  if [ -f "$POLICY_FILE" ]; then
    rm -f "$POLICY_FILE"
    ok "deleted $POLICY_FILE"
    # Leave the directory: Chromium reads it whether or not it is empty, and
    # other policy files may live here.
  else
    no "nothing to remove"
  fi
  warn_if_running
  echo
  echo "Chromium falls back to whichever engine it had before, and"
  echo "chrome://settings/search becomes editable again."
  exit 0
fi

say "Setting Google as Chromium's default search engine"

install -d -m 755 "$POLICY_DIR"
ok "$POLICY_DIR ready"

# install(1) writes through a temp file, so Chromium never sees a half-written
# policy if it happens to start mid-run.
install -m 644 /dev/stdin "$POLICY_FILE" <<'EOF'
{
  "DefaultSearchProviderEnabled": true,
  "DefaultSearchProviderName": "Google",
  "DefaultSearchProviderKeyword": "google.com",
  "DefaultSearchProviderSearchURL": "https://www.google.com/search?q={searchTerms}",
  "DefaultSearchProviderSuggestURL": "https://www.google.com/complete/search?output=chrome&q={searchTerms}",
  "DefaultSearchProviderIconURL": "https://www.google.com/favicon.ico",
  "DefaultSearchProviderEncodings": ["UTF-8"]
}
EOF
ok "wrote $POLICY_FILE"

# Chromium silently ignores a policy file it cannot parse, which looks exactly
# like the script having done nothing. Fail loudly instead.
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$POLICY_FILE" 2>/dev/null; then
    ok "valid JSON"
  else
    echo "    [!!] $POLICY_FILE is not valid JSON -- Chromium will ignore it"
    exit 1
  fi
fi

warn_if_running

say "Verification"
echo "--- policy file ---"
cat "$POLICY_FILE"
echo
echo "After a full restart of Chromium:"
echo "  chrome://policy           lists DefaultSearchProvider* as applied"
echo "  chrome://settings/search  shows Google, greyed out as managed"
echo
echo "To undo:  sudo $0 remove"
