# Blueprint extensions

Every `*.blueprint` file in this directory is installed into the panel by the
CI build, using Blueprint's own installer (`bash blueprint.sh -bash -install`),
after `composer install` / `yarn install` and before the production frontend
build, so extension React components and CSS end up in the built assets.

Pushing a change to this directory triggers a build automatically.
