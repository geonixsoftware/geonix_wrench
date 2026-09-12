#!/usr/bin/env bash
#
# Pushes this backend checkout to the server with rsync.
#
# Dry run unless you pass --apply. Read the file list it prints; that is the
# whole point of the default.
#
#   export GEONIX_REMOTE=daniel@your-server
#   ./deploy.sh                    # show what would change
#   ./deploy.sh --apply            # do it
#   ./deploy.sh --apply --restart  # ...and restart the service, then health check
#
# ── what is deliberately never sent ──────────────────────────────────────
# The deployed directory is not only code. With the default settings in
# config.py these all live inside it, on the server:
#
#   geonix_wrench.db     DB_PATH             the database. Job cards, users.
#   storage/logos/       LOGO_STORAGE_DIR    every shop's uploaded logo.
#   .env                                     the server's secrets.
#   firebase-service-account.json            the server's credentials.
#   venv/                                    what the systemd unit executes.
#
# This Mac has its own versions of the first four, and they are development
# junk. Sending them would overwrite production data with a dev database, swap
# the live Stripe and Firebase keys for test ones, and replace a Linux venv
# with a macOS one that cannot run. Each is excluded below, and --delete leaves
# excluded paths alone on the receiving side, so none of them is removed
# either.
#
set -euo pipefail

REMOTE="${GEONIX_REMOTE:-}"
REMOTE_DIR="${GEONIX_REMOTE_DIR:-/var/www/geonix_wrench/geonix_wrench_backend}"
SSH_PORT="${GEONIX_SSH_PORT:-22}"
# The only host in ~/.ssh/known_hosts listens on 70 rather than 22, so the port
# is configurable and threaded through both rsync and ssh.
SSH_CMD="ssh -p $SSH_PORT"
SERVICE="${GEONIX_SERVICE:-geonix-backend}"
HEALTH_URL="${GEONIX_HEALTH_URL:-https://api.geonix.site/health}"
LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APPLY=0
RESTART=0
for arg in "$@"; do
  case "$arg" in
    --apply)   APPLY=1 ;;
    --restart) RESTART=1 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$REMOTE" ]]; then
  echo "error: set GEONIX_REMOTE first, e.g. export GEONIX_REMOTE=daniel@203.0.113.10" >&2
  exit 2
fi

EXCLUDES=(
  # Runtime state and secrets — see the header.
  --exclude='.env'
  --exclude='.env.*'
  --exclude='firebase-service-account.json'
  --exclude='*.db'
  --exclude='*.db-wal'
  --exclude='*.db-shm'
  --exclude='*.sqlite3'
  --exclude='storage/'
  --exclude='venv/'
  # Build and editor noise.
  --exclude='__pycache__/'
  --exclude='*.pyc'
  --exclude='.pytest_cache/'
  --exclude='.git/'
  --exclude='.claude/'
  --exclude='.DS_Store'
  # Belt and braces: `protect` rules survive even --delete-excluded, which the
  # exclusions above would not.
  --filter='P .env'
  --filter='P firebase-service-account.json'
  --filter='P *.db*'
  --filter='P storage/**'
  --filter='P venv/**'
)

RSYNC=(
  rsync -avz
  -e "$SSH_CMD"
  --delete                # a .py deleted here should go on the server too
  # Compare by content, not by size-and-timestamp. rsync's default quick check
  # skips a file whose size and mtime both match, and the server's main.py was
  # hand-edited during debugging — an edit that changed no bytes in length
  # would survive a deploy invisibly. The tree is a dozen source files, so
  # hashing them costs nothing.
  --checksum
  --human-readable
  --itemize-changes
  "${EXCLUDES[@]}"
  "$LOCAL_DIR/" "$REMOTE:$REMOTE_DIR/"
)

if [[ $APPLY -eq 0 ]]; then
  echo "DRY RUN — nothing will be written. Re-run with --apply to deploy."
  echo
  "${RSYNC[@]}" --dry-run
  echo
  echo "Legend: '<f' = sent to server, '*deleting' = removed on server."
  echo "Check that no line mentions .env, a .db, storage/ or venv/ before applying."
  exit 0
fi

echo "Deploying $LOCAL_DIR -> $REMOTE:$REMOTE_DIR"
"${RSYNC[@]}"

if [[ $RESTART -eq 1 ]]; then
  echo
  echo "Installing dependencies and restarting $SERVICE..."
  # requirements are installed before the restart so the new code never starts
  # against an older dependency set.
  ssh -p "$SSH_PORT" "$REMOTE" "
    set -e
    cd '$REMOTE_DIR'
    ./venv/bin/pip install --quiet --requirement requirements.txt
    sudo systemctl restart '$SERVICE'
  "
  echo "Waiting for the service to come back..."
  for i in $(seq 1 15); do
    if curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
      echo "healthy: $HEALTH_URL"
      # Proves auth is enforced, not just that the process is up. 401 is the
      # correct answer here; a 200 would mean the debugging bypass is still live.
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${HEALTH_URL%/health}/api/auth/me" || true)"
      if [[ "$code" == "401" ]]; then
        echo "auth enforced: /api/auth/me -> 401"
      else
        echo "WARNING: /api/auth/me returned $code, expected 401." >&2
        echo "         A 200 means token validation is still bypassed on the server." >&2
        exit 1
      fi
      exit 0
    fi
    sleep 2
  done
  echo "ERROR: $HEALTH_URL did not come back within 30s." >&2
  echo "       ssh -p $SSH_PORT $REMOTE 'journalctl -u $SERVICE -n 50 --no-pager'" >&2
  exit 1
fi

echo
echo "Done. Not restarted — the service is still running the old code."
echo "Restart with:  ./deploy.sh --apply --restart"
