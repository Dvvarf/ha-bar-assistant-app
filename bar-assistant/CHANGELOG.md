# Changelog

All notable changes to this add-on are documented here. Versions follow the
5-part `<BA_maj>.<BA_min>.<SR_maj>.<SR_min>.<pkg>` scheme described in `CLAUDE.md`.

## 5.15.4.15.2

- Make Home Assistant's add-on state detection reliable. Previously HA only
  tracked the container's s6 `/init` process, which stays alive even when an
  inner service (php-fpm/the API, Salt Rim's nginx, or Meilisearch) hangs, so a
  wedged add-on still showed as "Started". Added a Docker `HEALTHCHECK` that
  probes all three inner services independently, so any one failing flips the
  container to "unhealthy" in the HA UI. Modern Supervisor drives its add-on
  watchdog off this status, so it also auto-restarts the add-on on failure when
  the Watchdog toggle on the add-on page is enabled. (The older config.yaml
  `watchdog:` key is rejected as obsolete by the add-on linter in favour of the
  HEALTHCHECK, which additionally covers Meilisearch.)
- Cap browser caching of Salt Rim's `config.js` at one day, and serve the
  `index.html` SPA shell with no-cache headers. `config.js` holds the runtime
  `API_URL`/`MEILISEARCH_URL` baked from the add-on options at boot; browsers
  previously cached it indefinitely, so changing an option (e.g.
  `MEILISEARCH_URL`'s host) kept resolving to the stale value. The cap means an
  option change now propagates within a day (or immediately on a hard reload).
  Hashed assets stay cacheable.
- Remove the `ENABLE_PASSWORD_LOGIN` add-on option. It only makes sense when an
  alternative SSO login is configured, which this add-on does not set up, so the
  toggle could never be used in practice. The upstream default (password login
  enabled) is left in place.

## 5.15.4.15.1

- Add optional add-on options (hidden until enabled): general toggles
  (`APP_NAME`, `LOG_LEVEL`, `ENABLE_FEEDS`,
  `SESSION_LIFETIME`), an `ai` group for a single LLM provider (key/URL routed to
  the chosen provider), and a `redis` group to use an external Redis for
  cache/sessions. No change to existing installs that leave them unset.

## 5.15.4.15.0

- First packaged release: Bar Assistant API 5.15 + Salt Rim 4.15 + Meilisearch
  v1.15, all in one s6-supervised image served on port 2118.
- Pre-built multi-arch images (amd64, aarch64) published to GHCR; Home Assistant
  pulls them instead of building locally.
