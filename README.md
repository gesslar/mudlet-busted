# mudlet-busted (build & publish)

This repo holds the **Docker image source and release tooling** for
[`gesslardev/mudlet-busted`](https://hub.docker.com/r/gesslardev/mudlet-busted) —
a Fedora-based image that runs [Busted](https://lunarmodules.github.io/busted/)
tests inside a headless [Mudlet](https://www.mudlet.org/).

> **Using the image** to run tests? That's documented in
> [`OVERVIEW.md`](OVERVIEW.md) (which is also what gets published as the Docker
> Hub overview). This README is for **building and publishing** the image.

## Layout

| Path | What it is |
|---|---|
| `Dockerfile` | The image definition |
| `entrypoint.sh` | Runtime: detects specs, builds the mpackage, runs Busted headlessly |
| `profile/` | Default Mudlet test profile (Busted bootstrap) baked into the image |
| `build-and-push` | Release script — build, tag, push, and sync the Hub overview |
| `OVERVIEW.md` | The Docker Hub overview / end-user docs |
| `*.AppImage` | Mudlet release builds — **git-ignored**, supplied at release time |

## Prerequisites

- **Docker**, logged in to Docker Hub with push rights to `gesslardev/mudlet-busted`:
  ```bash
  docker login
  ```
- **A Mudlet AppImage** for the version you're publishing. Download it from the
  [Mudlet releases](https://www.mudlet.org/download/) — it is *not* committed to
  this repo (the files are ~150–180MB each).
- `curl` (only needed the first time on a machine — see below).

## Releasing a new version

```bash
./build-and-push Mudlet-4.21.0.AppImage
```

The version is parsed straight from the filename (`Mudlet-X.Y.Z.AppImage` →
`X.Y.Z`), so just point it at the AppImage and go. The script will:

1. Ensure the `docker-pushrm` plugin is present (auto-installs it on first run).
2. Stage the AppImage as `Mudlet.AppImage` for the build context.
3. `docker build` and tag as both `:X.Y.Z` and `:latest`.
4. `docker push` both tags.
5. Sync `OVERVIEW.md` into the Docker Hub repo overview via `docker pushrm`.
6. Clean up the staged AppImage.

## The Docker Hub overview

A plain `docker push` only uploads the image — it never touches the repo's
**Overview** text. So step 5 above pushes `OVERVIEW.md` separately using the
[`docker-pushrm`](https://github.com/christian-korneck/docker-pushrm) plugin.

- **First run on a machine:** the script downloads the plugin into
  `~/.docker/cli-plugins/` automatically (Linux/macOS, amd64/arm64). It's
  machine-global, not part of this repo, so each new machine bootstraps once.
- **Auth caveat:** the overview push hits the Docker Hub *web API*, not the
  registry. If your `docker login` used the web/OAuth flow, `pushrm` may reject
  that token. If you hit an auth error, hand it a
  [personal access token](https://hub.docker.com/settings/security) instead:
  ```bash
  export DOCKER_USER=gesslardev
  export DOCKER_PASS=<personal-access-token>
  ./build-and-push Mudlet-4.21.0.AppImage
  ```

To edit the overview without cutting a release, push `OVERVIEW.md` on its own:

```bash
docker pushrm gesslardev/mudlet-busted -f OVERVIEW.md
```

## Notes

- Relative image paths in `OVERVIEW.md` won't resolve on Docker Hub — use
  absolute URLs for any images or badges.
- The `docker-pushrm` version is pinned in `build-and-push` (`ver="v1.9.0"`);
  bump it there if you want a newer release.

## Credits

- [demonnic/test-in-mudlet](https://github.com/demonnic/test-in-mudlet)
- [demonnic/MudletBusted](https://github.com/demonnic/MudletBusted)

Basically, as has been insufficiently stated before, @demonnic is a god and at his altar of code-geniusness should be laid all of our praise and thanks.
