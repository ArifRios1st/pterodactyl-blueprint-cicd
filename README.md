# Pterodactyl + Blueprint CI/CD for Shared Hosting

This repository builds Pterodactyl + Blueprint entirely on GitHub Actions and publishes a ready-to-deploy release. The shared-hosting server only downloads and deploys the completed build.

## What CI does

1. Downloads the selected official Pterodactyl Panel release.
2. Downloads the latest Blueprint release.
3. Installs production PHP dependencies.
4. Installs Node dependencies.
5. Builds frontend assets on GitHub.
6. Normalizes Blueprint's runtime directory to `.blueprint/`.
7. Verifies that `extensionfs.php` is included in the release package.
8. Publishes `pterodactyl-blueprint-build.tar.gz` as the latest GitHub Release asset.

## Fresh installation

The panel directory may be empty except for a configured `.env` file:

```text
/path/to/panel/
└── .env
```

Clone this repository outside the panel directory:

```bash
cd ~
git clone https://github.com/YOUR_USERNAME/YOUR_REPOSITORY.git pterodactyl-blueprint-cicd
cd pterodactyl-blueprint-cicd
```

Deploy:

```bash
PANEL_DIR=/path/to/panel \
PHP_BIN=/usr/local/bin/php \
bash scripts/deploy.sh
```

## Existing installation

The same command supports upgrades. Deployment preserves:

- `.env`
- `storage/`
- `public/uploads/`
- Blueprint's persistent database state under `.blueprint/.../private/db/`

The new CI release supplies Blueprint runtime files such as:

```text
.blueprint/extensions/blueprint/private/extensionfs.php
```

## v7 compatibility behavior

v7 fixes the Blueprint directory mismatch found in older artifacts.

- New CI builds package `.blueprint/` correctly.
- The deploy script also accepts an older artifact containing `blueprint/` and renames it to `.blueprint/` during staging.
- Fresh installations do not require an existing `extensionfs.php`; it comes from the release package.
- Deployments stop before migrations if the downloaded CI package itself is missing `extensionfs.php`.

## Updating later

After GitHub Actions publishes a new release:

```bash
cd ~/pterodactyl-blueprint-cicd
git pull
PANEL_DIR=/path/to/panel \
PHP_BIN=/usr/local/bin/php \
bash scripts/deploy.sh
```

## Security

Do not commit `.env`, database credentials, API tokens, hosting usernames, hosting domains, or personal absolute paths to GitHub.
