# Pterodactyl + Blueprint CI/CD for Shared Hosting

This repository builds Pterodactyl + Blueprint entirely on GitHub Actions and publishes a ready-to-deploy release. Shared hosting does not run Yarn, Webpack, Terser, Composer, or Blueprint's asset build.

## What CI does

1. Downloads the selected official Pterodactyl Panel release.
2. Downloads the latest Blueprint release.
3. Installs production PHP dependencies.
4. Installs Node dependencies.
5. Builds frontend assets on GitHub with OpenSSL legacy compatibility enabled.
6. Packages `vendor`, Blueprint files, and production assets into `pterodactyl-blueprint-build.tar.gz`.
7. Uploads the package as both a GitHub Actions artifact and the latest GitHub Release asset.

## One-time shared-hosting setup

Clone this repository anywhere outside the panel directory:

```bash
cd ~
git clone https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git pterodactyl-blueprint-cicd
cd pterodactyl-blueprint-cicd
```

Your existing panel is currently at:

```text
/path/to/pterodactyl-panel
```

Deploy with:

```bash
PANEL_DIR=/path/to/pterodactyl-panel \
PHP_BIN=/opt/alt/php82/usr/bin/php \
bash scripts/deploy.sh
```

The deploy script automatically downloads:

```text
https://github.com/OWNER/REPOSITORY/releases/latest/download/pterodactyl-blueprint-build.tar.gz
```

It determines `OWNER/REPOSITORY` from the repository's `origin` remote, or you can explicitly set:

```bash
GITHUB_REPOSITORY=owner/repo PANEL_DIR=/path/to/panel bash scripts/deploy.sh
```

## What deployment preserves

- `.env`
- database (never touched directly)
- `storage/`
- `public/uploads/`

A complete rollback copy is created in:

```text
.deploy-backups/TIMESTAMP/
```

If migration or cache finalization fails, the script restores the previous application files automatically.

## Blueprint on restricted shared hosting

Your PHP CLI has `exec()` and `symlink()` disabled. Blueprint's normal installer can therefore complete most steps but abort before its final marker is written. Since CI already builds the assets and deployment has successfully completed migrations and Laravel cache finalization, this deployer creates Blueprint's `is_installed` marker only as the final deployment step when Blueprint's private database directory exists.

The deployer never runs Webpack or Terser on shared hosting.

## Updating later

After GitHub Actions publishes a new release:

```bash
cd ~/pterodactyl-blueprint-cicd
git pull
PANEL_DIR=/path/to/pterodactyl-panel \
PHP_BIN=/opt/alt/php82/usr/bin/php \
bash scripts/deploy.sh
```

## Important

Keep this repository separate from the Pterodactyl panel directory. Do not clone it into `/path/to/pterodactyl-panel`.


## Shared Hosting Configuration

The deployment script does not require your hosting username or domain to be stored in this repository. Pass your installation path at runtime:

```bash
PANEL_DIR=/path/to/pterodactyl-panel \
PHP_BIN=/usr/local/bin/php \
bash scripts/deploy.sh
```

Replace `/path/to/pterodactyl-panel` with the absolute path to your own Pterodactyl installation.

Do not commit the following to GitHub:

- hosting usernames
- hosting domains
- absolute paths containing personal account names
- `.env` files
- database credentials
- API tokens or deployment secrets
