#!/bin/bash
# Circuit.app launcher — SOURCE OF TRUTH (installed as Circuit.app/Contents/MacOS/Circuit).
# Picks a repo (one-click from recents), starts the Circuit server, opens the 3D UI
# in a chromeless Chrome window, and ties the server's lifetime to this app.
set -u

# GUI apps don't inherit a shell PATH; put Homebrew/node on it explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
RES="$(cd "$(dirname "$0")/../Resources" 2>/dev/null && pwd)"

# Prefer the Node runtime shipped inside the app; fall back to a system Node only
# if the bundled one is somehow missing.
NODE="$RES/node/node"
[ -x "$NODE" ] || NODE="/opt/homebrew/bin/node"
[ -x "$NODE" ] || NODE="$(command -v node)"

# Server code ships inside the bundle; fall back to ~/Circuit only if it's missing.
BUNDLE_APP="$RES/app"
if [ -n "$BUNDLE_APP" ] && [ -f "$BUNDLE_APP/server.js" ]; then
  CIRCUIT="$BUNDLE_APP/server.js"
else
  CIRCUIT="$HOME/Circuit/server.js"
fi

fail() { osascript -e "display alert \"Circuit\" message \"$1\"" >/dev/null 2>&1; exit 1; }
[ -x "$NODE" ]    || fail "Node runtime missing from the app bundle."
[ -f "$CIRCUIT" ] || fail "Circuit server code is missing from the app bundle."

# ── Repo choice: one click for the common case ────────────────────────────────
# Recents live one-per-line, most recent first, in ~/.circuit-recent-repos.
# (~/.circuit-last-repo is kept updated for backward compatibility.)
RECENTS="$HOME/.circuit-recent-repos"
LEGACY="$HOME/.circuit-last-repo"
# Seed recents from the legacy single-entry file once.
if [ ! -f "$RECENTS" ] && [ -f "$LEGACY" ]; then cp "$LEGACY" "$RECENTS" 2>/dev/null; fi

# Existing dirs only, deduped, max 8.
CLEAN=()
if [ -f "$RECENTS" ]; then
  while IFS= read -r line; do
    [ -d "$line" ] || continue
    dup=0; for c in "${CLEAN[@]:-}"; do [ "$c" = "$line" ] && dup=1 && break; done
    [ $dup -eq 0 ] && CLEAN+=("$line")
    [ "${#CLEAN[@]}" -ge 8 ] && break
  done < "$RECENTS"
fi

pick_folder() {
  local def="${1:-}"
  if [ -n "$def" ] && [ -d "$def" ]; then
    osascript -e "POSIX path of (choose folder with prompt \"Choose a repo for Circuit to grade\" default location (POSIX file \"$def\"))" 2>/dev/null
  else
    osascript -e "POSIX path of (choose folder with prompt \"Choose a repo for Circuit to grade\")" 2>/dev/null
  fi
}

REPO=""
if [ "${#CLEAN[@]:-0}" -gt 0 ]; then
  # Build the one-click list: recents (shown with ~ shorthand) + "Choose another folder…".
  OTHER="Choose another folder…"
  ITEMS=""
  for c in "${CLEAN[@]}"; do
    disp="${c/#$HOME/~}"; disp="${disp%/}"
    ITEMS="$ITEMS, \"$disp\""
  done
  ITEMS="${ITEMS#, }"
  CHOICE=$(osascript -e "choose from list {$ITEMS, \"$OTHER\"} with prompt \"Grade which repo?\" default items {\"${CLEAN[0]/#$HOME/~}\"} with title \"Circuit\"" 2>/dev/null)
  [ "$CHOICE" = "false" ] || [ -z "$CHOICE" ] && exit 0     # user cancelled
  if [ "$CHOICE" = "$OTHER" ]; then
    REPO=$(pick_folder "${CLEAN[0]}")
  else
    REPO="${CHOICE/#\~/$HOME}"
  fi
else
  REPO=$(pick_folder "$([ -f "$LEGACY" ] && cat "$LEGACY" 2>/dev/null)")
fi
[ -z "$REPO" ] && exit 0                 # user cancelled the picker
REPO="${REPO%/}"

# Update recents (front, dedupe, cap 8) + the legacy file.
{ printf '%s\n' "$REPO"; for c in "${CLEAN[@]:-}"; do [ "$c" = "$REPO" ] || printf '%s\n' "$c"; done; } | head -8 > "$RECENTS"
printf '%s' "$REPO" > "$LEGACY"

LOG="$(mktemp -t circuit)"

# Background watcher: wait for the server to announce its real URL (the port can
# climb past 8923 if it's busy), then open a standalone Chrome app window.
(
  URL=""
  for _ in $(seq 1 60); do
    URL=$(grep -Eo 'http://localhost:[0-9]+' "$LOG" 2>/dev/null | head -1)
    [ -n "$URL" ] && break
    sleep 0.2
  done
  [ -z "$URL" ] && URL="http://localhost:8923"
  if [ -d "/Applications/Google Chrome.app" ]; then
    open -na "Google Chrome" --args --app="$URL" --new-window
  else
    open "$URL"
  fi
) &

# Run the server in the foreground: the app stays "running" in the Dock while it
# lives, and quitting the app (or Cmd-Q) sends SIGTERM and kills the server.
exec "$NODE" "$CIRCUIT" "$REPO" > "$LOG" 2>&1
