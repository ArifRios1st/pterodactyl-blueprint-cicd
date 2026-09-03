#!/usr/bin/env bash
# Deploy a pre-built Pterodactyl + Blueprint release on shared hosting.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PANEL_DIR="${PANEL_DIR:-}"
PHP_BIN="${PHP_BIN:-php}"
BACKUP_ROOT="${BACKUP_ROOT:-}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

if [ -z "$PANEL_DIR" ]; then
  echo "PANEL_DIR is required. Example:"
  echo "  PANEL_DIR=/home/USER/domains/example.com PHP_BIN=/opt/alt/php82/usr/bin/php bash scripts/deploy.sh"
  exit 2
fi
PANEL_DIR="$(cd "$PANEL_DIR" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$PANEL_DIR/.deploy-backups}"

if [ ! -f "$PANEL_DIR/.env" ]; then
  echo "ERROR: $PANEL_DIR/.env was not found."
  echo "For first deployment, configure the Pterodactyl .env before running deploy.sh."
  exit 2
fi
if [ ! -x "$PHP_BIN" ] && ! command -v "$PHP_BIN" >/dev/null 2>&1; then
  echo "ERROR: PHP binary not executable/found: $PHP_BIN"
  exit 2
fi

REPO_SLUG="${GITHUB_REPOSITORY:-}"
if [ -z "$REPO_SLUG" ] && git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
  URL="$(git -C "$REPO_DIR" remote get-url origin)"
  REPO_SLUG="$(printf '%s' "$URL" | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
fi
if [ -z "$REPO_SLUG" ]; then
  echo "ERROR: Cannot determine GitHub repository. Set GITHUB_REPOSITORY=owner/repo."
  exit 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$(mktemp -d "$PANEL_DIR/.deploy-stage.XXXXXX")"
PACKAGE="$STAGE/package.tar.gz"
BACKUP="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP_ROOT" "$BACKUP"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ROLLBACK_REQUIRED=0
rollback() {
  if [ "$ROLLBACK_REQUIRED" = 1 ] && [ -f "$BACKUP/panel-backup.tar.gz" ]; then
    echo "ERROR: Deployment failed. Restoring file backup..."
    tar -xzf "$BACKUP/panel-backup.tar.gz" -C "$PANEL_DIR" || true
    cp -f "$BACKUP/.env" "$PANEL_DIR/.env" || true
  fi
}
trap rollback ERR

ASSET_URL="https://github.com/$REPO_SLUG/releases/latest/download/pterodactyl-blueprint-build.tar.gz"
echo "[1/9] Downloading latest build from $REPO_SLUG..."
curl -fL --retry 3 --connect-timeout 20 "$ASSET_URL" -o "$PACKAGE"
tar -tzf "$PACKAGE" >/dev/null

echo "[2/9] Creating rollback backup..."
cp -a "$PANEL_DIR/.env" "$BACKUP/.env"
# rsync is commonly unavailable on shared hosting. Use tar, which is already
# required for extracting the CI package.
tar -czf "$BACKUP/panel-backup.tar.gz" \
  --exclude='./.deploy-backups' \
  --exclude='./.deploy-stage.*' \
  -C "$PANEL_DIR" .

ROLLBACK_REQUIRED=1

echo "[3/9] Extracting release..."
mkdir -p "$STAGE/release"
tar -xzf "$PACKAGE" -C "$STAGE/release"
RELEASE_DIR="$STAGE/release"

# Some packaging tools wrap the archive in one directory; normalize it.
TOP_COUNT="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [ "$TOP_COUNT" = "1" ] && [ -d "$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)" ]; then
  CANDIDATE="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -f "$CANDIDATE/artisan" ] && RELEASE_DIR="$CANDIDATE"
fi
[ -f "$RELEASE_DIR/artisan" ] || { echo "ERROR: Invalid release package (artisan missing)."; exit 1; }

echo "[4/9] Preserving environment and persistent storage..."
cp -a "$PANEL_DIR/.env" "$STAGE/.env"
if [ -d "$PANEL_DIR/storage" ]; then cp -a "$PANEL_DIR/storage" "$STAGE/storage"; fi
if [ -d "$PANEL_DIR/public/uploads" ]; then mkdir -p "$STAGE/public"; cp -a "$PANEL_DIR/public/uploads" "$STAGE/public/uploads"; fi

# Never deploy these from CI.
rm -f "$RELEASE_DIR/.env"
rm -rf "$RELEASE_DIR/storage" "$RELEASE_DIR/public/uploads"

echo "[5/9] Overlaying release files..."
# Use tar instead of rsync for shared-hosting compatibility. This safely
# overlays all release files while the persistent paths below remain excluded.
tar -C "$RELEASE_DIR" \
  --exclude='./.env' \
  --exclude='./storage' \
  --exclude='./public/uploads' \
  -cf - . | tar -C "$PANEL_DIR" -xf -
cp -a "$STAGE/.env" "$PANEL_DIR/.env"
[ -d "$STAGE/storage" ] && { rm -rf "$PANEL_DIR/storage"; cp -a "$STAGE/storage" "$PANEL_DIR/storage"; }
[ -d "$STAGE/public/uploads" ] && { mkdir -p "$PANEL_DIR/public"; rm -rf "$PANEL_DIR/public/uploads"; cp -a "$STAGE/public/uploads" "$PANEL_DIR/public/uploads"; }

echo "[6/9] Preparing Laravel permissions..."
mkdir -p "$PANEL_DIR/storage/framework/cache" "$PANEL_DIR/storage/framework/sessions" "$PANEL_DIR/storage/framework/views" "$PANEL_DIR/storage/logs" "$PANEL_DIR/bootstrap/cache"
chmod -R u+rwX "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" || true

cd "$PANEL_DIR"
echo "[7/9] Running database migrations..."
"$PHP_BIN" artisan down || true
"$PHP_BIN" artisan migrate --force

echo "[8/9] Refreshing Laravel caches..."
"$PHP_BIN" artisan optimize:clear
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan view:cache
"$PHP_BIN" artisan route:cache || true

# Blueprint's installer can fail on shared hosting after doing all useful work because
# the host disables exec(). Do not rerun webpack here. If Blueprint source is present
# and its marker is absent, create the marker only after migrations/cache steps succeed.
echo "[9/9] Finalizing Blueprint state..."
MARKER="$PANEL_DIR/.blueprint/extensions/blueprint/private/db/is_installed"
if [ -d "$(dirname "$MARKER")" ]; then
  if [ ! -f "$MARKER" ]; then
    touch "$MARKER"
    echo "Created Blueprint installation marker after successful deployment finalization."
  else
    echo "Blueprint installation marker already present."
  fi
else
  echo "WARNING: Blueprint private database directory was not found."
fi

"$PHP_BIN" artisan up || true
ROLLBACK_REQUIRED=0

# Retain only the newest backups.
if [ "$KEEP_BACKUPS" -gt 0 ] 2>/dev/null; then
  ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -rf
fi

echo
echo "Deployment completed successfully."
echo "Backup retained at: $BACKUP"
