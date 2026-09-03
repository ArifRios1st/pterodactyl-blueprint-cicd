#!/usr/bin/env bash
# Deploy a pre-built Pterodactyl + Blueprint release on shared hosting.
# Supports both a fresh panel directory containing only .env and upgrades.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PANEL_DIR="${PANEL_DIR:-}"
PHP_BIN="${PHP_BIN:-php}"
BACKUP_ROOT="${BACKUP_ROOT:-}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

if [ -z "$PANEL_DIR" ]; then
  echo "PANEL_DIR is required."
  exit 2
fi
mkdir -p "$PANEL_DIR"
PANEL_DIR="$(cd "$PANEL_DIR" && pwd)"
BACKUP_ROOT="${BACKUP_ROOT:-$PANEL_DIR/.deploy-backups}"

if [ ! -f "$PANEL_DIR/.env" ]; then
  echo "ERROR: $PANEL_DIR/.env was not found."
  echo "For a fresh installation, create/configure .env before deployment."
  exit 2
fi
if ! "$PHP_BIN" -v >/dev/null 2>&1; then
  echo "ERROR: PHP binary cannot be executed: $PHP_BIN"
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
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/pterodactyl-deploy.XXXXXX")"
PACKAGE="$STAGE/package.tar.gz"
BACKUP="$BACKUP_ROOT/$STAMP"
mkdir -p "$BACKUP_ROOT" "$BACKUP"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

ROLLBACK_REQUIRED=0
rollback() {
  if [ "$ROLLBACK_REQUIRED" = 1 ] && [ -f "$BACKUP/panel-backup.tar.gz" ]; then
    echo "ERROR: Deployment failed. Restoring previous panel files..."
    # Remove deployed files except the backup root, then restore the snapshot.
    find "$PANEL_DIR" -mindepth 1 -maxdepth 1 ! -name "$(basename "$BACKUP_ROOT")" -exec rm -rf {} + || true
    tar -xzf "$BACKUP/panel-backup.tar.gz" -C "$PANEL_DIR" || true
  fi
}
trap rollback ERR

ASSET_URL="https://github.com/$REPO_SLUG/releases/latest/download/pterodactyl-blueprint-build.tar.gz"
echo "[1/10] Downloading latest build from $REPO_SLUG..."
curl -fL --retry 3 --connect-timeout 20 "$ASSET_URL" -o "$PACKAGE"
tar -tzf "$PACKAGE" >/dev/null

echo "[2/10] Creating rollback backup..."
tar -czf "$BACKUP/panel-backup.tar.gz" \
  --exclude="./$(basename "$BACKUP_ROOT")" \
  -C "$PANEL_DIR" .
ROLLBACK_REQUIRED=1

echo "[3/10] Extracting release..."
mkdir -p "$STAGE/release"
tar -xzf "$PACKAGE" -C "$STAGE/release"
RELEASE_DIR="$STAGE/release"
TOP_COUNT="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [ "$TOP_COUNT" = "1" ]; then
  CANDIDATE="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE/artisan" ] && RELEASE_DIR="$CANDIDATE"
fi
[ -f "$RELEASE_DIR/artisan" ] || { echo "ERROR: Invalid release package (artisan missing)."; exit 1; }

echo "[4/10] Normalizing Blueprint package layout..."
# Older CI packages may contain blueprint/ instead of .blueprint/. Support both.
if [ -d "$RELEASE_DIR/blueprint" ] && [ ! -d "$RELEASE_DIR/.blueprint" ]; then
  mv "$RELEASE_DIR/blueprint" "$RELEASE_DIR/.blueprint"
  echo "Normalized release directory: blueprint/ -> .blueprint/"
elif [ -d "$RELEASE_DIR/blueprint" ] && [ -d "$RELEASE_DIR/.blueprint" ]; then
  echo "ERROR: Release contains both blueprint/ and .blueprint/; refusing ambiguous deployment."
  exit 1
fi
[ -f "$RELEASE_DIR/.blueprint/extensions/blueprint/private/extensionfs.php" ] || {
  echo "ERROR: Release does not contain Blueprint extensionfs.php."
  echo "The CI package is incomplete; rebuild the GitHub release with v7 workflow."
  exit 1
}

echo "[5/10] Preserving environment and persistent panel state..."
cp -a "$PANEL_DIR/.env" "$STAGE/.env"
[ -d "$PANEL_DIR/storage" ] && cp -a "$PANEL_DIR/storage" "$STAGE/storage" || true
[ -d "$PANEL_DIR/public/uploads" ] && { mkdir -p "$STAGE/public"; cp -a "$PANEL_DIR/public/uploads" "$STAGE/public/uploads"; } || true
# Preserve Blueprint runtime DB state only for upgrades. Fresh installs use the
# complete private directory shipped by CI, including extensionfs.php.
OLD_BP_DB="$PANEL_DIR/.blueprint/extensions/blueprint/private/db"
if [ -d "$OLD_BP_DB" ]; then
  mkdir -p "$STAGE/blueprint-db"
  cp -a "$OLD_BP_DB/." "$STAGE/blueprint-db/"
fi

rm -f "$RELEASE_DIR/.env"
rm -rf "$RELEASE_DIR/storage" "$RELEASE_DIR/public/uploads"

echo "[6/10] Overlaying release files..."
tar -C "$RELEASE_DIR" -cf - . | tar -C "$PANEL_DIR" -xf -
cp -a "$STAGE/.env" "$PANEL_DIR/.env"
if [ -d "$STAGE/storage" ]; then rm -rf "$PANEL_DIR/storage"; cp -a "$STAGE/storage" "$PANEL_DIR/storage"; fi
if [ -d "$STAGE/public/uploads" ]; then mkdir -p "$PANEL_DIR/public"; rm -rf "$PANEL_DIR/public/uploads"; cp -a "$STAGE/public/uploads" "$PANEL_DIR/public/uploads"; fi
# Restore only persistent Blueprint DB state on upgrades; keep extensionfs.php
# and other CI-provided Blueprint runtime files from the new release.
if [ -d "$STAGE/blueprint-db" ]; then
  mkdir -p "$PANEL_DIR/.blueprint/extensions/blueprint/private/db"
  cp -a "$STAGE/blueprint-db/." "$PANEL_DIR/.blueprint/extensions/blueprint/private/db/"
fi

EXTENSIONFS="$PANEL_DIR/.blueprint/extensions/blueprint/private/extensionfs.php"
[ -f "$EXTENSIONFS" ] || { echo "ERROR: extensionfs.php is missing after overlay."; exit 1; }

echo "[7/10] Preparing Laravel permissions..."
mkdir -p "$PANEL_DIR/storage/framework/cache" "$PANEL_DIR/storage/framework/sessions" "$PANEL_DIR/storage/framework/views" "$PANEL_DIR/storage/logs" "$PANEL_DIR/bootstrap/cache"
chmod -R u+rwX "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" || true

cd "$PANEL_DIR"
echo "[8/10] Running database migrations..."
"$PHP_BIN" artisan down || true
"$PHP_BIN" artisan migrate --force

echo "[9/10] Refreshing Laravel caches..."
"$PHP_BIN" artisan optimize:clear
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan view:cache
"$PHP_BIN" artisan route:cache || true

echo "[10/10] Finalizing Blueprint state..."
MARKER="$PANEL_DIR/.blueprint/extensions/blueprint/private/db/is_installed"
mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
"$PHP_BIN" artisan up || true
ROLLBACK_REQUIRED=0

if [ "$KEEP_BACKUPS" -gt 0 ] 2>/dev/null; then
  ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -rf
fi

echo
echo "Deployment completed successfully."
echo "Backup retained at: $BACKUP"
