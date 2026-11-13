# Pterodactyl + Blueprint CI/CD for Shared Hosting

This repository builds Pterodactyl + Blueprint entirely on GitHub Actions and publishes a ready-to-deploy release. The shared-hosting server downloads the completed build and performs only the PHP/runtime steps that cannot be completed in CI because they depend on the target panel's `.env` and database.

## What CI does

1. Downloads the selected official Pterodactyl Panel release.
2. Downloads the latest Blueprint release.
3. Installs production PHP dependencies.
4. Installs Node dependencies.
5. Installs every Blueprint extension from `extensions/` with Blueprint's own installer, before the frontend build.
6. Builds production frontend assets on GitHub.
7. Normalizes Blueprint's runtime directory to `.blueprint/`.
8. Verifies that `extensionfs.php` and every installed extension are included in the release package.
9. Publishes `pterodactyl-blueprint-build.tar.gz` as the latest GitHub Release asset.

Pushing a change under `extensions/` (or to the workflow file) triggers a build automatically.

## Extensions

See [`extensions/README.md`](extensions/README.md). The build currently ships Minecraft Player Manager, Modrinth Browser, MOTD Maker, Snowflakes, and Minecraft Version Changer. Nebula is intentionally excluded: it is paid software whose EULA forbids redistribution, so it is never committed to this public repository.

Do not install extensions manually on the server. The next deploy overlays the panel with the CI build and removes anything that did not come from CI.

## What deployment does

v8 intentionally follows the relevant order and behavior of Blueprint's original `blueprint.sh` installer while skipping the Node build on the shared host:

1. Preserves `.env`, `storage/`, uploads, and persistent Blueprint DB-state files.
2. Downloads and overlays the CI release.
3. Initializes Blueprint version placeholders and `db/version`.
4. Creates Blueprint's runtime symlinks:
   - `.blueprint/extensions/blueprint/public` -> `public/extensions/blueprint`
   - `.blueprint/extensions/blueprint/assets` -> `public/assets/extensions/blueprint`
   - `scripts/libraries` -> `.blueprint/lib`
5. Copies Blueprint's emblem into the Blueprint extension logo when the upstream emblem exists.
6. Runs Laravel migrations.
7. Runs `BlueprintSeeder` on the first Blueprint installation.
8. Rebuilds the same Laravel/Blueprint caches used by the original installer.
9. Restarts the queue and writes the `is_installed` marker.

The production JavaScript/CSS build remains a GitHub Actions responsibility, avoiding the Node/Terser memory problem on shared hosting.

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

## Existing installation / upgrade

Use the same command:

```bash
cd ~/pterodactyl-blueprint-cicd
git pull

PANEL_DIR=/path/to/panel \
PHP_BIN=/usr/local/bin/php \
bash scripts/deploy.sh
```

Deployment preserves:

- `.env`
- `storage/`
- `public/uploads/`
- Blueprint's persistent files under `.blueprint/extensions/blueprint/private/db/`

The CI release supplies Blueprint runtime files such as:

```text
.blueprint/extensions/blueprint/private/extensionfs.php
```

## v8 fixes

v8 fixes the runtime behavior that v7 still skipped.

In particular, the original Blueprint installer creates public symlinks for extension assets. Without this link:

```text
.blueprint/extensions/blueprint/assets/logo.jpg
```

is not reachable through:

```text
/assets/extensions/blueprint/logo.jpg
```

v8 creates that symlink during deployment, so Blueprint logos and other extension assets are served from their expected public URL.

v8 also performs the original installer's version-placeholder, initial-seeding, Blueprint cache, and queue-finalization steps instead of only touching `is_installed`.

## Security

Do not commit `.env`, database credentials, API tokens, hosting usernames, hosting domains, or personal absolute paths to GitHub.
