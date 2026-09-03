# Pterodactyl + Blueprint CI Build

This repository moves the expensive frontend build from shared hosting to GitHub Actions.

## What GitHub Actions does

1. Downloads the official Pterodactyl Panel release.
2. Downloads the latest Blueprint release archive.
3. Installs Yarn dependencies.
4. Runs the production Webpack build on a GitHub runner.
5. Removes `node_modules` and server-specific files.
6. Creates `pterodactyl-blueprint-build.tar.gz`.

The package is designed so your shared hosting does **not** need to run Webpack or Terser.

## Important limitation

Blueprint's complete installation state can depend on its installer, database migrations, symlinks and server capabilities. This CI pipeline intentionally does not fake the `is_installed` marker. The package contains the built Blueprint source/assets, while database/server finalization remains on the target server.

This is safer than creating `is_installed` manually.

## Build

1. Push this repository to GitHub.
2. Open **Actions**.
3. Select **Build Pterodactyl + Blueprint**.
4. Click **Run workflow**.
5. Wait for the build to finish.
6. Download the artifact named `pterodactyl-blueprint-build`.

You can rename the downloaded file to:

```text
pterodactyl-blueprint-build.tar.gz
```

## Deploy on your shared hosting

Your target directory should already contain a working `.env`.

Example:

```bash
cd /home/rntteamx/domains/ptr2.rnt-team.me
```

Copy these files into that directory:

- `pterodactyl-blueprint-build.tar.gz`
- `scripts/deploy.sh`

Then:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script:

- backs up `.env`
- backs up `storage`
- extracts into a staging directory
- preserves `.env`
- preserves persistent storage/uploads
- switches application files
- runs `php artisan migrate --force`
- clears/rebuilds Laravel caches

It never runs Yarn, npm, Webpack or Terser.

## Environment variables

You can override the PHP binary:

```bash
PHP_BIN=/opt/alt/php82/usr/bin/php ./deploy.sh
```

For your hosting, this may be useful if the default CLI PHP is different.

## First installation

For a completely new panel:

1. Deploy the package.
2. Create/configure `.env`.
3. Generate/configure `APP_KEY`.
4. Configure the database.
5. Run migrations.
6. Run Blueprint's official installer/finalization as supported by the server.

## Updating later

Run the GitHub workflow again, download the new artifact, and run:

```bash
PHP_BIN=/opt/alt/php82/usr/bin/php ./deploy.sh
```

Always keep the automatically created `.deploy-backups` until you confirm the panel works.

## Security

Never commit `.env`, database credentials, API keys, or panel secrets to this repository.


## OpenSSL legacy compatibility

The workflow explicitly sets:

```text
NODE_OPTIONS=--openssl-legacy-provider
```

during the production build because the current panel dependency tree still contains packages that use legacy OpenSSL hashing APIs. This affects the build runner only; it does not require changing your shared-hosting PHP configuration.
