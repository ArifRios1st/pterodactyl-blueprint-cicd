#!/usr/bin/env bash
# Deploy a pre-built Pterodactyl + Blueprint release on shared hosting.
# The frontend is built by GitHub Actions; this script reproduces the server-side
# runtime/finalization steps from Blueprint's original blueprint.sh installer.
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
    find "$PANEL_DIR" -mindepth 1 -maxdepth 1 ! -name "$(basename "$BACKUP_ROOT")" -exec rm -rf {} + || true
    tar -xzf "$BACKUP/panel-backup.tar.gz" -C "$PANEL_DIR" || true
  fi
}
trap rollback ERR

# Blueprint's original installer seeds only during the first installation.
WAS_BLUEPRINT_INSTALLED=0
if [ -f "$PANEL_DIR/.blueprint/extensions/blueprint/private/db/is_installed" ]; then
  WAS_BLUEPRINT_INSTALLED=1
fi

ASSET_URL="https://github.com/$REPO_SLUG/releases/latest/download/pterodactyl-blueprint-build.tar.gz"
echo "[1/12] Downloading latest build from $REPO_SLUG..."
curl -fL --retry 3 --connect-timeout 20 "$ASSET_URL" -o "$PACKAGE"
tar -tzf "$PACKAGE" >/dev/null

echo "[2/12] Creating rollback backup..."
tar -czf "$BACKUP/panel-backup.tar.gz" \
  --exclude="./$(basename "$BACKUP_ROOT")" \
  -C "$PANEL_DIR" .
ROLLBACK_REQUIRED=1

echo "[3/12] Extracting release..."
mkdir -p "$STAGE/release"
tar -xzf "$PACKAGE" -C "$STAGE/release"
RELEASE_DIR="$STAGE/release"
TOP_COUNT="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [ "$TOP_COUNT" = "1" ]; then
  CANDIDATE="$(find "$RELEASE_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [ -n "$CANDIDATE" ] && [ -f "$CANDIDATE/artisan" ] && RELEASE_DIR="$CANDIDATE"
fi
[ -f "$RELEASE_DIR/artisan" ] || { echo "ERROR: Invalid release package (artisan missing)."; exit 1; }

echo "[4/12] Normalizing Blueprint package layout..."
if [ -d "$RELEASE_DIR/blueprint" ] && [ ! -d "$RELEASE_DIR/.blueprint" ]; then
  mv "$RELEASE_DIR/blueprint" "$RELEASE_DIR/.blueprint"
  echo "Normalized release directory: blueprint/ -> .blueprint/"
elif [ -d "$RELEASE_DIR/blueprint" ] && [ -d "$RELEASE_DIR/.blueprint" ]; then
  echo "ERROR: Release contains both blueprint/ and .blueprint/; refusing ambiguous deployment."
  exit 1
fi
[ -f "$RELEASE_DIR/.blueprint/extensions/blueprint/private/extensionfs.php" ] || {
  echo "ERROR: Release does not contain Blueprint extensionfs.php."
  echo "The CI package is incomplete; rebuild the GitHub release before deploying."
  exit 1
}

echo "[5/12] Entering maintenance mode before filesystem changes..."
cd "$PANEL_DIR"
"$PHP_BIN" artisan down || true

echo "[6/12] Preserving environment and persistent panel state..."
cp -a "$PANEL_DIR/.env" "$STAGE/.env"
[ -d "$PANEL_DIR/storage" ] && cp -a "$PANEL_DIR/storage" "$STAGE/storage" || true
[ -d "$PANEL_DIR/public/uploads" ] && { mkdir -p "$STAGE/public"; cp -a "$PANEL_DIR/public/uploads" "$STAGE/public/uploads"; } || true
OLD_BP_DB="$PANEL_DIR/.blueprint/extensions/blueprint/private/db"
if [ -d "$OLD_BP_DB" ]; then
  mkdir -p "$STAGE/blueprint-db"
  cp -a "$OLD_BP_DB/." "$STAGE/blueprint-db/"
fi

rm -f "$RELEASE_DIR/.env"
rm -rf "$RELEASE_DIR/storage" "$RELEASE_DIR/public/uploads"

echo "[7/12] Overlaying release files..."
tar -C "$RELEASE_DIR" -cf - . | tar -C "$PANEL_DIR" -xf -
cp -a "$STAGE/.env" "$PANEL_DIR/.env"
if [ -d "$STAGE/storage" ]; then rm -rf "$PANEL_DIR/storage"; cp -a "$STAGE/storage" "$PANEL_DIR/storage"; fi
if [ -d "$STAGE/public/uploads" ]; then mkdir -p "$PANEL_DIR/public"; rm -rf "$PANEL_DIR/public/uploads"; cp -a "$STAGE/public/uploads" "$PANEL_DIR/public/uploads"; fi
if [ -d "$STAGE/blueprint-db" ]; then
  mkdir -p "$PANEL_DIR/.blueprint/extensions/blueprint/private/db"
  cp -a "$STAGE/blueprint-db/." "$PANEL_DIR/.blueprint/extensions/blueprint/private/db/"
fi

EXTENSIONFS="$PANEL_DIR/.blueprint/extensions/blueprint/private/extensionfs.php"
[ -f "$EXTENSIONFS" ] || { echo "ERROR: extensionfs.php is missing after overlay."; exit 1; }

cd "$PANEL_DIR"

echo "[8/12] Reproducing Blueprint runtime initialization..."
# Blueprint blueprint.sh replaces ::v placeholders and creates db/version before
# installation. Always patch an unexpanded placeholder so upgrades cannot leave
# the new PlaceholderService reporting 'unknown' after its old db/version marker
# has been preserved.
BP_VERSION="$(sed -nE 's/^VERSION="([^"]*)".*/\1/p' blueprint.sh | head -n1 || true)"
if [ -n "$BP_VERSION" ]; then
  PLACEHOLDER_SERVICE="app/BlueprintFramework/Services/PlaceholderService/BlueprintPlaceholderService.php"
  PLACEHOLDER_INDEX=".blueprint/extensions/blueprint/public/index.html"
  if grep -q '::v' "$PLACEHOLDER_SERVICE" 2>/dev/null; then
    sed -E -i "s*::v*$BP_VERSION*g" "$PLACEHOLDER_SERVICE"
  fi
  if [ -f "$PLACEHOLDER_INDEX" ] && grep -q '::v' "$PLACEHOLDER_INDEX"; then
    sed -E -i "s*::v*$BP_VERSION*g" "$PLACEHOLDER_INDEX"
  fi
  mkdir -p .blueprint/extensions/blueprint/private/db
  touch .blueprint/extensions/blueprint/private/db/version
fi

# These are the same links created by the original Blueprint installer:
#   .blueprint/extensions/blueprint/public -> public/extensions/blueprint
#   .blueprint/extensions/blueprint/assets -> public/assets/extensions/blueprint
#   scripts/libraries -> .blueprint/lib
link_runtime_path() {
  local source="$1"
  local destination="$2"
  [ -e "$source" ] || { echo "ERROR: Blueprint link source is missing: $source"; exit 1; }
  mkdir -p "$(dirname "$destination")"
  if [ -L "$destination" ] || [ -e "$destination" ]; then
    rm -rf "$destination"
  fi
  ln -s -r -T "$source" "$destination"
}

link_runtime_path "$PANEL_DIR/.blueprint/extensions/blueprint/public" "$PANEL_DIR/public/extensions/blueprint"
link_runtime_path "$PANEL_DIR/.blueprint/extensions/blueprint/assets" "$PANEL_DIR/public/assets/extensions/blueprint"
link_runtime_path "$PANEL_DIR/scripts/libraries" "$PANEL_DIR/.blueprint/lib"

# Match Blueprint's logo initialization step.
EMBLEM="$PANEL_DIR/.blueprint/assets/Emblem/emblem.jpg"
BP_LOGO="$PANEL_DIR/.blueprint/extensions/blueprint/assets/logo.jpg"
if [ -f "$EMBLEM" ]; then
  cp -f "$EMBLEM" "$BP_LOGO"
fi

# Replacement for `php artisan storage:link`.
# Shared hosting may disable PHP exec(), which causes Laravel\'s Filesystem::link()
# to fail. Create the exact public/storage symlink directly from the shell.
mkdir -p "$PANEL_DIR/storage/app/public"
link_runtime_path "$PANEL_DIR/storage/app/public" "$PANEL_DIR/public/storage"

echo "[9/12] Preparing Laravel permissions..."
mkdir -p storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache
chmod -R u+rwX storage bootstrap/cache || true

echo "[10/12] Running database migrations..."
"$PHP_BIN" artisan migrate --force

if [ "$WAS_BLUEPRINT_INSTALLED" = 0 ]; then
  echo "[11/12] Seeding Blueprint database records (fresh Blueprint install)..."
  "$PHP_BIN" artisan db:seed --class=BlueprintSeeder --force
else
  echo "[11/12] Blueprint was already installed; skipping initial Blueprint seeder..."
fi

echo "[12/12] Rebuilding Laravel/Blueprint caches and restarting queue..."
# Keep the order from Blueprint's original installer.
"$PHP_BIN" artisan view:cache
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan route:clear
"$PHP_BIN" artisan cache:clear
"$PHP_BIN" artisan bp:cache
# The upstream Blueprint command returns a non-zero exit status when the
# latest-version API is temporarily unavailable. The original blueprint.sh
# does not run with `set -e`, so that transient network failure must not abort
# an otherwise successful deployment.
if ! "$PHP_BIN" artisan bp:version:cache; then
  echo "WARNING: Blueprint latest-version cache could not be refreshed. Continuing deployment."
fi
"$PHP_BIN" artisan queue:restart || true

echo "[13/13] Finalizing Blueprint installation state..."
MARKER="$PANEL_DIR/.blueprint/extensions/blueprint/private/db/is_installed"
mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
sed -i 's~NOTINSTALLED~INSTALLED~g' app/BlueprintFramework/Services/PlaceholderService/BlueprintPlaceholderService.php
"$PHP_BIN" artisan up || true
ROLLBACK_REQUIRED=0

if [ "$KEEP_BACKUPS" -gt 0 ] 2>/dev/null; then
  ls -1dt "$BACKUP_ROOT"/* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -rf
fi

echo
echo "Deployment completed successfully."
echo "Backup retained at: $BACKUP"
