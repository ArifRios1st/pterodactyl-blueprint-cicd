# Blueprint extensions

Every `*.blueprint` file in this directory is installed into the panel by the
CI build, using Blueprint's own installer (`bash blueprint.sh -bash -install`),
after `composer install` / `yarn install` and before the production frontend
build, so extension React components and CSS end up in the built assets.

Pushing a change to this directory triggers a build automatically.

## Included extensions

| File | Extension | Version | Blueprint target | License |
| --- | --- | --- | --- | --- |
| `minecraftplayermanager.blueprint` | Minecraft Player Manager | 1.3.0 | beta-2024-08 | none shipped |
| `modrinthbrowser.blueprint` | Modrinth Browser | 1.2.2 | beta-2026-01 | GPL-3.0 |
| `motdmaker.blueprint` | MOTD Maker | 1.1.0 | beta-2026-01 | none shipped |
| `snowflakes.blueprint` | Snowflakes | 1.0 | alpha-NLM | MIT |
| `versionchanger.blueprint` | Minecraft Version Changer | 1.1.0 | beta-2024-07 | none shipped |

A target older than the installed Blueprint version only produces a warning
during install; the extension still installs.

## Nebula (not in this repository)

Nebula is paid software. Its EULA forbids redistribution, including uploading
it to any platform, so `nebula.blueprint` is git-ignored and must never be
committed here while this repository is public. Note that the published release
tarball would contain Nebula's installed files as well, so downloading it in
CI does not avoid the redistribution question either.

To include Nebula in the build, either:

- make this repository private, then commit `nebula.blueprint` here (remove
  the gitignore guard), or
- set the `NEBULA_BLUEPRINT_URL` repository secret to a private download URL
  for `nebula.blueprint`. CI downloads it for that build only. The resulting
  release artifact is still published from this repository, so prefer the
  private-repository option.

## Adding an extension

1. Drop the `*.blueprint` file in this directory and push. The filename must
   match the extension identifier in its `conf.yml`.
2. The build installs it and fails if any extension fails to install.
3. Deploy with `scripts/deploy.sh` as usual. Extension migrations run with
   the normal `artisan migrate` step, and the extension registry is merged
   (not wiped) during deployment.

To remove an extension, delete its file and push. The next deploy removes its
files and prunes its registry entry.

## Rules

- Never install extensions manually on the server with the `blueprint` CLI.
  The next deploy overlays the panel with the CI build and removes anything
  that did not come from CI.
- Extension `install.sh` hooks run in CI (as root, via `sudo`), not on the
  server. Read a hook before adding an extension that ships one.
- Do not commit paid extensions to this public repository. If in doubt, check
  the extension's license first.
