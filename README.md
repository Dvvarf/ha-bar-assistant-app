# Bar Assistant — Home Assistant add-on repository

A Home Assistant add-on that bundles [Bar Assistant](https://barassistant.app)
(API + the Salt Rim web client) together with its Meilisearch search engine into a
single, s6-supervised image served on one port.

## Installation

1. In Home Assistant go to **Settings → Add-ons → Add-on Store**.
2. Click the **⋮** menu (top right) → **Repositories**.
3. Add this repository URL:

   ```
   https://github.com/dvvarf/home-bar-assistant
   ```

4. Find **Bar Assistant** in the store, install it, then set the
   `API_URL` / `MEILISEARCH_URL` options to your host (see the add-on
   **Documentation** tab) and start it.

[![Open your Home Assistant instance and show the add add-on repository dialog.](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fdvvarf%2Fhome-bar-assistant)

## What's in here

| Path | Purpose |
| --- | --- |
| `repository.yaml` | Add-on store manifest for this repository. |
| `bar-assistant/` | The add-on (Dockerfile, config, docs). |
| `.github/workflows/` | Lint, CI build + smoke test, and GHCR publish. |
| `renovate.json` | Automated upstream/dependency update PRs. |

Pre-built images are published to GHCR
(`ghcr.io/dvvarf/ha-bar-assistant-app-{arch}`) on each release tag, so Home
Assistant pulls a ready-made image instead of building locally.

## Development

```bash
# Build + boot smoke test (matches what CI runs)
cd bar-assistant && docker build -t ha-bar-assistant:test .
IMAGE=ha-bar-assistant:test ./tests/smoke.sh

# Verify the version coupling (config.yaml / Dockerfile LABEL / upstream tags)
bash scripts/check-version-sync.sh
```

Releasing: bump `version:` in `bar-assistant/config.yaml` and `io.hass.version`
in the Dockerfile (they must match — see versioning notes in
`bar-assistant/CLAUDE.md`), then push a matching git tag
(`git tag 5.15.4.15.0 && git push origin 5.15.4.15.0`) to trigger the publish
workflow.
