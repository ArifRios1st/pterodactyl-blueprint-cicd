#!/usr/bin/env bash
# Deploy a pre-built Pterodactyl + Blueprint package on shared hosting.
# Run this from the directory containing this repository.
set -Eeuo pipefail

PANEL_DIR="${PANEL_DIR:-$(pwd)}"
PACKAGE="${PACKAGE:-$PANEL_DIR/pterodactyl-blueprint-build.tar.gz}"
BACKUP_DIR="${BACKUP_DIR:-$PANEL_DIR/.deploy-backups}"
PHP_BIN="${PHP_BIN:-php}"

if [ ! -f "$PACKAGE" ]; then
  echo "ERROR: Build package not found: $PACKAGE"
  echo "Download pterodactyl-blueprint-build.tar.gz from GitHub Actions first."
  exit 1
fi

if [ ! -f "$PANEL_DIR/.env" ]; then
  echo "ERROR: Existing .env not found."
  echo "For safety, deploy into an already configured Pterodactyl directory."
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
STAGE="$PANEL_DIR/.deploy-stage-$STAMP"
mkdir -p "$STAGE" "$BACKUP_DIR"

echo "[1/8] Backing up deployment-critical files..."
cp "$PANEL_DIR/.env" "$BACKUP_DIR/.env.$STAMP"
[ -d "$PANEL_DIR/storage" ] && tar -czf "$BACKUP_DIR/storage.$STAMP.tar.gz" -C "$PANEL_DIR" storage || true
[ -d "$PANEL_DIR/public/uploads" ] && tar -czf "$BACKUP_DIR/uploads.$STAMP.tar.gz" -C "$PANEL_DIR" public/uploads || true

echo "[2/8] Extracting build into staging..."
tar -xzf "$PACKAGE" -C "$STAGE"

echo "[3/8] Preserving server-specific data..."
cp "$PANEL_DIR/.env" "$STAGE/.env"
mkdir -p "$STAGE/storage" "$STAGE/bootstrap/cache"

if [ -d "$PANEL_DIR/storage" ]; then
  rsync -a \
    --exclude='framework/cache/*' \
    --exclude='framework/sessions/*' \
    --exclude='framework/views/*' \
    --exclude='logs/*' \
    "$PANEL_DIR/storage/" "$STAGE/storage/"
fi

if [ -d "$PANEL_DIR/public/uploads" ]; then
  mkdir -p "$STAGE/public/uploads"
  rsync -a "$PANEL_DIR/public/uploads/" "$STAGE/public/uploads/"
fi

echo "[4/8] Switching application files..."
rsync -a --delete \
  --exclude='.env' \
  --exclude='storage/' \
  --exclude='.deploy-stage-*' \
  --exclude='.deploy-backups/' \
  "$STAGE/" "$PANEL_DIR/"

echo "[5/8] Restoring .env and permissions..."
cp "$BACKUP_DIR/.env.$STAMP" "$PANEL_DIR/.env"
chmod 755 "$PANEL_DIR" "$PANEL_DIR/public" "$PANEL_DIR/storage" "$PANEL_DIR/bootstrap/cache" 2>/dev/null || true

echo "[6/8] Running database migrations..."
cd "$PANEL_DIR"
"$PHP_BIN" artisan migrate --force

echo "[7/8] Clearing/rebuilding Laravel caches..."
"$PHP_BIN" artisan optimize:clear
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan route:cache || true

echo "[8/8] Checking Blueprint installation state..."
if [ -f ".blueprint/extensions/blueprint/private/db/is_installed" ]; then
  echo "Blueprint marker: present"
else
  echo "WARNING: Blueprint is packaged, but the is_installed marker is absent."
  echo "This package does not mark Blueprint installed automatically because that state"
  echo "depends on Blueprint's installer and database/server environment."
fi

rm -rf "$STAGE"
"$PHP_BIN" artisan up || true

echo
echo "Deployment finished."
echo "If this is a new Pterodactyl installation, configure .env and database first."
