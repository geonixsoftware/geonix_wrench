#!/usr/bin/env bash
#
# Pulls the deployed backend off the server into a scratch directory and diffs
# it against this checkout. It does NOT write into the working tree.
#
# That is deliberate. The server copy has been hand-edited during debugging —
# at minimum /api/auth/me was changed to bypass token validation — and this
# checkout has changes the server has never seen. rsync'ing one directly over
# the other loses work in whichever direction it is pointed, and pulling an
# auth bypass into the repo is how it reaches production later.
#
# So: fetch, look, then copy across by hand only what is genuinely worth
# keeping.
#
#   export GEONIX_REMOTE=daniel@your-server
#   ./sync_from_server.sh                 # diff every .py
#   ./sync_from_server.sh main.py         # just one file
#
set -euo pipefail

REMOTE="${GEONIX_REMOTE:-}"
REMOTE_DIR="${GEONIX_REMOTE_DIR:-/var/www/geonix_wrench/geonix_wrench_backend}"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_PORT="${GEONIX_SSH_PORT:-22}"
# The only host in ~/.ssh/known_hosts listens on 70 rather than 22, so the port
# is configurable and threaded through both rsync and ssh.
SSH_CMD="ssh -p $SSH_PORT"
SCRATCH="${GEONIX_SCRATCH:-/tmp/geonix-server-snapshot}"

if [[ -z "$REMOTE" ]]; then
  cat >&2 <<'MSG'
error: set GEONIX_REMOTE to the server first, e.g.

    export GEONIX_REMOTE=daniel@203.0.113.10

MSG
  exit 2
fi

echo "Fetching $REMOTE:$REMOTE_DIR -> $SCRATCH"
mkdir -p "$SCRATCH"

# Read-only pull of source only. No venv (huge, and built for the server's
# platform), no .env or service account (secrets that belong on the server and
# nowhere else), no database or uploaded logos (production data — this machine
# has no business holding customer job cards).
rsync -az -e "$SSH_CMD" \
  --include='*/' \
  --include='*.py' \
  --include='requirements*.txt' \
  --include='Dockerfile' \
  --include='Caddyfile' \
  --include='*.md' \
  --exclude='*' \
  "$REMOTE:$REMOTE_DIR/" "$SCRATCH/"

echo
echo "──────────────────────────────────────────────────────────────"
echo " server (left)  vs  this checkout (right)"
echo "──────────────────────────────────────────────────────────────"

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  # Show which files differ at all before dumping any diffs.
  diff -rq "$SCRATCH" "$LOCAL_DIR" 2>/dev/null \
    | grep -vE 'venv|__pycache__|\.pytest_cache|Only in .*: (\.|venv)' || true
  echo
  # Plain while-read rather than `mapfile`, which is bash 4+ and macOS ships 3.2.
  targets=()
  while IFS= read -r line; do
    targets+=("$line")
  done < <(cd "$SCRATCH" && find . -name '*.py' -not -path './venv/*' | sed 's|^\./||')
fi

for f in "${targets[@]}"; do
  [[ -f "$SCRATCH/$f" ]] || { echo "  (not on server: $f)"; continue; }
  if diff -q "$SCRATCH/$f" "$LOCAL_DIR/$f" >/dev/null 2>&1; then
    continue
  fi
  echo
  echo "═══ $f ═══"
  diff -u "$LOCAL_DIR/$f" "$SCRATCH/$f" \
    --label "local/$f" --label "server/$f" || true
done

cat <<MSG

──────────────────────────────────────────────────────────────
Nothing has been written to your working tree.

Read the diff above before copying anything across. In particular, any change
that weakens /api/auth/me should be dropped rather than merged — auth.py in
this checkout already returns 401 {"detail": "Invalid or expired token"} for
every authentication failure, which is what the debugging edit was reaching
for.

To take a file as-is once you have read it:
    cp $SCRATCH/<file> $LOCAL_DIR/<file>
MSG
