# Changelog

All notable changes to this add-on are documented here. Versions follow the
5-part `<BA_maj>.<BA_min>.<SR_maj>.<SR_min>.<pkg>` scheme described in `CLAUDE.md`.

## 5.15.4.15.3

- Update bundled Meilisearch from v1.15 to v1.48, and make Meilisearch version
  jumps safe. Meilisearch refuses to boot when a newer engine opens a database
  created by an older one, which would crash-loop the add-on after a version
  bump. Since Bar Assistant's SQLite database is the source of truth and the
  search index is a rebuildable secondary store, `ba-prep` now purges the
  Meilisearch data dir in the `prep` oneshot (before the engine starts) when the
  on-disk version doesn't match the engine, so it boots clean; a new
  `meili-reindex` oneshot then repopulates the index from the database in the
  background (`bar:setup-meilisearch -f` + `bar:refresh-search --clear`). The
  reindex is detached so it never delays the container reaching `healthy` —
  search results fill in progressively after boot. The upgrade path is covered
  by the boot smoke test, which seeds an older on-disk Meilisearch version and
  asserts the add-on still comes up healthy.
- After a Meilisearch rebuild, force browser sessions to re-login so search keeps
  working. A rebuild gives Meilisearch new scoped-key UIDs, so each browser's
  cached search token becomes stale and searches fail with "invalid API key"
  until the client re-fetches it (which Salt Rim only does on login). The
  `meili-reindex` step now invalidates the login sessions (Sanctum tokens with an
  expiry) after regenerating the keys, so users are prompted to log back in and
  pick up the fresh token. Permanent API tokens (created without an expiry, e.g.
  for integrations) are left untouched.

- Fix php-fpm failing to start (`ALERT: [pool www] user has not been defined` ->
  `FPM initialization failed`). The add-on runs the serversideup base as `root`
  (to manage `/data` and the s6 environment), but php-fpm refuses to run workers
  as root and then requires the pool to name a non-root `user`/`group`.
  serversideup's pool config omits those directives because it is built to run
  rootless, so forcing `root` made php-fpm abort at boot. The Dockerfile now
  appends `user = www-data` / `group = www-data` to the serversideup pool config.

- Apply the `LOG_LEVEL` option to Meilisearch as well. Meilisearch logs on its
  own `MEILI_LOG_LEVEL` scale and previously ignored the add-on option, so it
  always emitted `INFO`-level chatter (e.g. `actix_server: Actix runtime
  found...`) even with the default `warning` level. The option is now mapped onto
  Meilisearch's scale (`OFF`/`ERROR`/`WARN`/`INFO`/`DEBUG`/`TRACE`) and applied at
  startup, so `warning` (the default) keeps Meilisearch quiet. Note: the one-time
  `Routes cached`/`Events cached` lines at boot are artisan console output from
  the base image's optimization step, not application logs, and are unaffected by
  `LOG_LEVEL`.

## 5.15.4.15.2

- Replace the `API_URL` and `MEILISEARCH_URL` options with a single `BASE_URL`.
  Both old options shared the same `protocol://host:port` origin and only
  differed by a fixed suffix (`/bar` and `/search`) imposed by the reverse-proxy
  layout, so configuring them separately was redundant and made it possible to
  set mismatched hosts or omit a suffix. Now you set one address with no path;
  the add-on derives both URLs internally (`BASE_URL/bar`, `BASE_URL/search`),
  tolerating a trailing slash. **Breaking:** upgrading from a release that had
  the `API_URL`/`MEILISEARCH_URL` options, set `BASE_URL` and restart the add-on.

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
- Ship `MEILI_MASTER_KEY` empty and drop its build-time fallback default. The
  add-on now fails closed: with no key set, Meilisearch (`MEILI_ENV=production`)
  refuses to start, instead of silently booting on a public placeholder key. Set
  a private value of at least 16 bytes before starting.

## 5.15.4.15.1

- Add optional add-on options (hidden until enabled): general toggles
  (`APP_NAME`, `LOG_LEVEL`, `ENABLE_PASSWORD_LOGIN`, `ENABLE_FEEDS`,
  `SESSION_LIFETIME`), an `ai` group for a single LLM provider (key/URL routed to
  the chosen provider), and a `redis` group to use an external Redis for
  cache/sessions. No change to existing installs that leave them unset.

## 5.15.4.15.0

- First packaged release: Bar Assistant API 5.15 + Salt Rim 4.15 + Meilisearch
  v1.15, all in one s6-supervised image served on port 2118.
- Pre-built multi-arch images (amd64, aarch64) published to GHCR; Home Assistant
  pulls them instead of building locally.
