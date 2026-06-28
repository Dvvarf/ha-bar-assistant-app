# Bar Assistant stack — Home Assistant add-on (handoff for Claude Code)

This is a **Home Assistant add-on** that bundles three upstream services into a
single Docker image, supervised by **s6-overlay**:

- **Meilisearch** (search engine) — internal only
- **Bar Assistant API** (`barassistant/server`, Laravel/PHP on serversideup) — internal only
- **Salt Rim** (`barassistant/salt-rim`, Vue 3 / Vite static SPA on nginx) — the public face

Everything is reached on **one published port, `2118`**, served by the Salt Rim
nginx as a reverse proxy:

```
:2118/         -> Salt Rim SPA (static files in this image)
:2118/bar/     -> Bar Assistant API   (proxy -> 127.0.0.1:8081, prefix stripped)
:2118/search/  -> Meilisearch         (proxy -> 127.0.0.1:7700, prefix stripped)
```

This matches the official "subfolders" reverse-proxy layout documented at
<https://docs.barassistant.app/setup/#reverse-proxy-configuration>.

---

## Repository layout

This add-on lives in the **`bar-assistant/`** subfolder of a standard HA add-on
*repository*. The repo root holds `repository.yaml` (store manifest), a root
`README.md`, the publish/CI tooling (`.github/workflows/`, `scripts/`,
`renovate.json`), and `LICENSE`.

| File (this folder) | Purpose |
| --- | --- |
| `Dockerfile` | Builds the combined image. Multi-stage (pulls Meilisearch binary + Salt Rim assets), then layers everything onto the Bar Assistant server image. |
| `config.yaml` | HA add-on manifest (ports, options/schema, webui, version, **`image:` for prebuilt GHCR pulls**). |
| `CLAUDE.md` | This file — handoff notes + verified facts. Loaded into Claude Code's context each session. |
| `apparmor.txt` | AppArmor profile (profile name `bar-assistant`, matching the slug). Enabled via `apparmor: true` in `config.yaml`. Keep in sync with Dockerfile changes — see "Things to verify" item 8. |
| `README.md` / `DOCS.md` / `CHANGELOG.md` | Store listing, Documentation tab, and update notes. |
| `icon.png` / `logo.png` | Store icon (256×256, the navy glass mark) and brand banner (1360×500), both derived from the upstream Bar Assistant API logo. Auto-detected by filename. |
| `tests/smoke.sh` | Boot smoke test (build the image, run this) — also the CI gate. |

Repo-root tooling: `scripts/check-version-sync.sh` (asserts `config.yaml`
`version:`, the Dockerfile `io.hass.version` LABEL, and the upstream `FROM`/
`BUILD_FROM` tags all agree), and `.github/workflows/` (`lint.yaml`, `ci.yaml`
build+smoke, `publish.yaml` → GHCR on a release tag).

**Intentionally absent** (removed during development, do not re-add without reason):

- `run.sh` — not used; s6 supervises all three services directly.
- `build.yaml` — obsolete since Supervisor 2026.04.0 (the legacy builder no longer
  reads it). The base image is pinned via `ARG BUILD_FROM=barassistant/server:5.15`
  in the Dockerfile instead (minor tag — see "Versioning" below).

`translations/en.yaml` — localizes the option **names/descriptions** (and the
published port) shown in the add-on Configuration tab. Keys mirror `config.yaml`
`schema:`; nested groups (`ai`, `redis`) translate their sub-keys under a
`fields:` block. Add a key here whenever you add an option to the schema.

---

## Versioning

The add-on version (kept in sync in **`config.yaml` `version:`** and the Dockerfile
**`io.hass.version`** LABEL — both must match) is a **5-part** string that embeds
both upstreams' `major.minor` directly:

```
<BA_major>.<BA_minor>.<SR_major>.<SR_minor>.<pkg>
   |          |          |          |          |
   |          |          |          |          +-- packaging revision: this image's
   |          |          |          |              own changes (Dockerfile, s6,
   |          |          |          |              config) AND upstream PATCH bumps.
   |          |          |          |              Reset to 0 when any field to its
   |          |          |          |              left changes.
   |          |          |          +-- Salt Rim (frontend) MINOR — `salt-rim:<M>.<m>`.
   |          |          +-- Salt Rim (frontend) MAJOR.
   |          +-- Bar Assistant (backend) MINOR — `server:<M>.<m>`.
   +-- Bar Assistant (backend) MAJOR.
```

So `5.15.4.15.0` reads as: backend 5.15, frontend 4.15, packaging rev 0 — both
upstreams legible straight off the version, no private counter or lookup table.

**Why dots, not a `~` packaging suffix.** HA Supervisor compares add-on versions
with **AwesomeVersion**, not Debian dpkg. Its strategies (`RE_SIMPLE` =
`[vV]?((\d+)(\.\d+)+)`, etc.) accept only `.`, `-`, `_`, `+` as separators — there is
**no `~`**. A tilde would fall out of the SIMPLE strategy and break the "update
available" comparison. A plain 5th dot matches `RE_SIMPLE` and compares section by
section left-to-right, so ordering stays monotonic
(`5.15.4.15.0` < `5.15.4.15.1` < `5.15.4.16.0` < `5.16.0.0.0.0`). This is **not**
strict 3-part semver — that's fine; AwesomeVersion handles arbitrary dotted lengths.

**Why the upstreams are pinned to MINOR tags** (`server:5.15`, `salt-rim:4.15`,
`meilisearch:v1.48`) rather than floating majors: the embedded `major.minor` fields
can only honestly mirror the upstreams if they're fixed at build time. Minor tags
still float on *patch*, so security/patch updates still flow in automatically — they
just land as a `<pkg>` bump here.

**Bump rules** (always update `config.yaml` + the LABEL together; repoint the
matching FROM/`BUILD_FROM` tag in the Dockerfile):

| What changed | Action |
| --- | --- |
| BA backend **major** (`server:6.x`) | `6.0.<SR_maj>.<SR_min>.0` |
| BA backend **minor** (`server:5.16`) | `5.16.<SR_maj>.<SR_min>.0` |
| Salt Rim **major** (`salt-rim:5.x`) | `5.15.5.0.0` |
| Salt Rim **minor** (`salt-rim:4.16`) | `5.15.4.16.0` |
| Upstream **patch** (server `5.15.2→3`, salt-rim, meilisearch) | bump `<pkg>`: `…​.1` (tags float on patch, so often just a rebuild). |
| This image only (Dockerfile / s6 / config.yaml) | bump `<pkg>`: `…​.1` |

Current `5.15.4.15.1` = server 5.15 + salt-rim 4.15; `.0` was the first packaged
release, `.1` added the optional AI/Redis/general add-on options (config + ba-prep
only, no upstream move).

---

## How it runs (architecture)

- **Base image:** `barassistant/server:5.15` (Debian/glibc + serversideup PHP-FPM +
  nginx + s6-overlay v3). **Do not** try to rebase on the Alpine HA base
  (`ghcr.io/home-assistant/base`) — it's musl and cannot run this Debian/PHP stack.
- **s6 supervises all three services:**
  - Bar Assistant (php-fpm + nginx) runs via the base image's own s6 services.
  - `meilisearch` and `salt-rim` are added as **s6 longrun** services under
    `/etc/s6-overlay/s6-rc.d/`, registered in the `user` bundle.
  - A **`prep` oneshot** runs `ba-prep.sh`; `meilisearch` and `salt-rim` declare a
    dependency on it (`dependencies.d/prep`).
  - A **`meili-reindex` oneshot** (ordered after `99-bass`) repopulates the
    Meilisearch index from SQLite **after a DB purge** — see "Meilisearch version
    jumps" below. Its `up` backgrounds the reindex so it never gates bring-up.
  - `ENTRYPOINT` is left as the base image's `/init`. No `CMD`. `config.yaml` sets
    `init: false` (required for s6-overlay v3 add-ons).
- **Runs as `USER root`** so it can manage `/data` and write the s6 container
  environment. `meilisearch` and `salt-rim` drop to `www-data` via
  `s6-setuidgid www-data`; Bar Assistant's own services run as `www-data` (serversideup).
- **Ports:** Salt Rim nginx listens on `2118` (the only `EXPOSE`d / published port).
  Bar Assistant's nginx vhost is moved off the serversideup base default `8080` to
  **`8081`** via `ENV NGINX_HTTP_PORT=8081` (the base renders its nginx config from
  `.template` files at boot, so a build-time `sed` over `/etc/nginx` would be undone
  on every start — the env var is the supported knob, and the base's own nginx
  healthcheck follows it). It stays bound inside the container (`127.0.0.1:8081`).
  Meilisearch listens on `127.0.0.1:7700`.

### `ba-prep.sh` (`/usr/local/bin/ba-prep.sh`)

Idempotent; invoked two ways so ordering is guaranteed for every consumer:

1. From `/etc/entrypoint.d/00-bar-stack.sh` — runs early in Bar Assistant's own
   serversideup init, **before** its `99-*` setup script.
2. From the `prep` s6 oneshot — `meilisearch`/`salt-rim` depend on it.

It does three things:

1. Creates `/data/meilisearch` and `/data/bar-assistant/{uploads,exports,temp}`,
   `chown`ed to `www-data`.
2. Relocates Bar Assistant storage into `/data` (see persistence note below).
3. Maps HA add-on options (`/data/options.json`) into the **s6 container
   environment** (`/run/s6/container_environment/<VAR>`) so each `with-contenv`
   service picks them up. HA options do **not** auto-map to env, hence this step.
4. **Meilisearch version guard** (see below): purges `/data/meilisearch` when the
   on-disk DB version doesn't match the engine, so a version bump can't crash-loop
   the engine.

---

## Meilisearch version jumps (rebuild, don't migrate)

Meilisearch ties its **on-disk DB** to the engine version that created it. A newer
engine opening an older DB **refuses to boot** (`database version X is incompatible
with engine version Y`) and exits — which would crash-loop the `meilisearch`
longrun and wedge the add-on after a tag bump. Note this is a **DB-format** concern
only: Meilisearch's HTTP API is stable across `v1.x` (Laravel Scout `^10.4` +
`meilisearch-php ^1.0` stay compatible), and the on-disk format is explicitly
exempted from that guarantee (it can break on a MINOR bump).

We don't migrate the DB (the dumpless upgrade is experimental and risky across a
large jump). Instead we treat Meilisearch as a **rebuildable secondary index** —
**SQLite is the source of truth** — and rebuild it from scratch on a mismatch:

1. **Purge in `prep`** (`ba-prep.sh`, before the `meilisearch` longrun starts):
   compare `/data/meilisearch/VERSION` (Meilisearch's own file) major.minor against
   `meilisearch --version`; if they differ, `rm -rf` the data dir. An empty dir is
   always compatible, so the engine boots clean and `meili-ready`/HEALTHCHECK come
   up normally. **The purge must live in `prep`** — by the time the engine starts,
   the incompatible DB is already gone, so the engine never sees it.
2. **Reindex in the `meili-reindex` oneshot** (after `99-bass`, which recreated the
   indexes/settings/keys): `bar:setup-meilisearch -f` (regenerate the scoped search
   keys a wipe destroyed, so each bar's stored token matches) then
   `bar:refresh-search --clear` (flush + reimport all searchable models). The
   queued `RefreshSearchIndex` job runs **inline** because `QUEUE_CONNECTION=sync`
   (no worker). The `up` **backgrounds** this so a long/failed reindex never gates
   bring-up or health — the container reports `healthy` immediately and search
   results fill in progressively. A `/run/bar-assistant.meili-rebuild` marker
   (set by the purge) gates it, so a normal boot does no work.

**Coupling/brittleness:** this depends on the `bar:setup-meilisearch` /
`bar:refresh-search` command names (Bar Assistant CLI) and the `VERSION` file
layout (Meilisearch). All calls are best-effort (`|| true`) and fail-safe — a
drifted contract leaves search empty but never wedges boot. The smoke test
exercising a seeded-old-`VERSION` upgrade is the guard against silent drift.

**Why the on-disk `VERSION` is a reliable trigger:** Meilisearch writes its own
version into `$MEILI_DB_PATH/VERSION` when it creates/opens the DB, and that value
**persists on the HA volume across restarts** until an engine actually rewrites it.
On an upgrade boot, `prep` runs *before* the engine, so it reads the version the
*previous* (older) engine recorded, sees the mismatch, and purges — only *then*
does the new engine boot and write the new version. So there is no special "force"
flag: the genuine version recorded by the prior engine is the signal. The CI smoke
test validates this by seeding an older `VERSION` while the container is stopped
and asserting it still comes up `healthy`.

---

## Persistence (`/data`)

`/data` is the only HA-persistent volume, so all state must live there.

- **Meilisearch DB:** `MEILI_DB_PATH=/data/meilisearch`.
- **Bar Assistant SQLite DB:** `DB_DATABASE=/data/bar-assistant/database.ba3.sqlite`
  (env-overridable in `config/database.php`; we set it directly).
- **Bar Assistant uploads/exports/temp:** these paths are **not** env-configurable
  (hardcoded to `storage_path('bar-assistant/...')` in `config/filesystems.php`),
  AND `storage/bar-assistant` is an **inherited Docker `VOLUME`** from the base
  image, so it cannot be replaced wholesale (Docker mounts an anonymous volume
  over it → "device busy" if you try to symlink the whole dir). Solution:
  `ba-prep.sh` symlinks the *subdirs* (`uploads`, `exports`, `temp`) into
  `/data/bar-assistant/*` on every boot (creating symlinks **inside** the mounted
  volume is allowed). Existing content is migrated once if present.

**Known gap:** `bar:full-backup` zips land in the storage-volume *root*
(ephemeral), not `/data`. The DB and uploads (the important data) are persisted.

---

## Configuration / environment variables

The required knobs are minimal: one key (`MEILI_MASTER_KEY`) and one address
(`BASE_URL`). All app-specific URLs/aliases are derived internally so users don't
set them twice (and can't set them inconsistently). Beyond
those, `config.yaml` exposes **optional** options (hidden in the UI until used):
top-level general toggles (`APP_NAME`, `LOG_LEVEL`, `ENABLE_FEEDS`,
`SESSION_LIFETIME`) and two nested groups, `ai` (single LLM
provider; ba-prep routes the generic `api_key`/`base_url` to the chosen provider's
`<PROVIDER>_API_KEY`/`_URL`) and `redis` (external Redis for cache/sessions). The
nested groups must stay present as empty dicts in `options:` — Supervisor rejects
an omitted optional dict (home-assistant/supervisor#4606). ba-prep reads them via
`optp GROUP KEY` and writes only what the user set.

| Var | Value / default | Notes |
| --- | --- | --- |
| `MEILI_MASTER_KEY` | _(empty)_ | User option. **Required.** Ships blank with no ENV fallback, so a blank option stays blank and Meilisearch (`MEILI_ENV=production`) refuses to start — the add-on fails closed instead of booting on a public placeholder. |
| `MEILISEARCH_KEY` | = `MEILI_MASTER_KEY` | Derived alias; what Bar Assistant reads. |
| `MEILISEARCH_HOST` | `http://127.0.0.1:7700` | Server-side connection (internal). |
| `MEILI_HTTP_ADDR` | `127.0.0.1:7700` | Meilisearch bind addr. |
| `MEILI_DB_PATH` | `/data/meilisearch` | |
| `MEILI_ENV` | `production` | |
| `BASE_URL` | `http://homeassistant.local:2118` | User option. Browser-facing origin (`protocol://host:port`, **no path**). The only configurable part of the two URLs below. ba-prep strips any trailing slash. |
| `API_URL` | = `BASE_URL` + `/bar` | Derived in ba-prep. Browser-facing API base; the `/bar` suffix is fixed by the proxy layout. |
| `APP_URL` | = `API_URL` | Derived alias; Laravel uses it to build absolute URLs (images/pagination). |
| `MEILISEARCH_URL` | = `BASE_URL` + `/search` | Derived in ba-prep. Browser-facing search base; the `/search` suffix is fixed by the proxy layout. |
| `DB_CONNECTION` / `DB_DATABASE` | `sqlite` / `/data/bar-assistant/database.ba3.sqlite` | Redis omitted. |
| `CACHE_DRIVER` / `SESSION_DRIVER` | `file` (or `redis`) | Resolved by ba-prep into `.env`, **not** Docker ENV — the base image's bundled `.env` defaults these to `redis`, so ba-prep must force `file` unless the `redis` option group has a host (then both switch to `redis`; queue stays `sync`, no worker). |
| `ALLOW_REGISTRATION` | `true` | User option. |
| `DEFAULT_LOCALE` | `en-US` | Salt Rim. |
| `MAILS_ENABLED` | `false` | Salt Rim. |

**Critical:** the derived `API_URL` and `MEILISEARCH_URL` are consumed **by the
browser** (Salt Rim calls the API and Meilisearch directly via JS). They must be
absolute, browser-reachable URLs. Because we proxy under subfolders they are
same-origin, which also avoids CORS. `homeassistant.local:2118` is a placeholder
— the deployer sets the real host and effective port via the single `BASE_URL`
option; the `/bar` and `/search` suffixes are fixed by the proxy layout and
appended by ba-prep, so they are **not** exposed as options (having two URL
options that only ever differed by a fixed suffix was redundant and let the hosts
drift apart). Salt Rim appends `/api/...` to `API_URL` and `/indexes/...` to
`MEILISEARCH_URL`; the trailing-slash `proxy_pass` strips the `/bar` and `/search`
prefixes before forwarding.

`config.yaml` exposes `BASE_URL` as a `url`-typed option (alongside
`MEILI_MASTER_KEY` `password` and `ALLOW_REGISTRATION` `bool`). HA options reach
the services through `ba-prep.sh` (see above), not automatically.

---

## Build & test (for Claude Code)

The build **is proven** as of 2026-06-19: it builds, boots cleanly under s6, and
all routes + image serving were verified end-to-end on `aarch64` (Apple Silicon).
See "Fixes applied & verified" below for the bugs that were found and fixed getting
there. amd64 was **not** cross-built — the musl-lib copy uses arch-agnostic
globs/paths designed for both, but verify on a real amd64 build.

Local Docker smoke test (HA injects `/data` and `options.json`). The steps below
are automated in `tests/smoke.sh` (`IMAGE=ha-bar-assistant:test ./tests/smoke.sh`),
which CI also runs; the raw sequence is kept here for reference. Build from inside
this `bar-assistant/` folder:

```bash
docker build -t ha-bar-assistant:test .

# IMPORTANT: use a NAMED VOLUME, not a Mac bind mount. On Docker Desktop
# (virtiofs) an in-container `chown` to www-data does not stick on a bind mount,
# so Meilisearch hits "Permission denied (os error 13)" on /data/meilisearch —
# a TEST ARTIFACT that does NOT happen on a real HA volume. A named volume has
# correct chown semantics and matches HA.
docker volume rm ba-data 2>/dev/null; docker volume create ba-data
# Seed options.json the way HA would (write it INTO the volume):
docker run --rm -v ba-data:/data alpine:3.20 sh -c 'printf "%s" "$1" > /data/options.json' _ \
  '{"MEILI_MASTER_KEY":"super-secret-key-987654321","BASE_URL":"http://localhost:2118","ALLOW_REGISTRATION":true}'
docker run -d --name ba-test -p 2118:2118 -v ba-data:/data ha-bar-assistant:test

# "Bar Assistant API ready" in the log == fully booted (~4s after image cache warm).
# then check (all should be 200):
#   http://localhost:2118/                       -> Salt Rim UI
#   http://localhost:2118/config.js              -> reflects API_URL/MEILISEARCH_URL derived from BASE_URL
#   http://localhost:2118/bar/api/server/version -> JSON
#   http://localhost:2118/search/health          -> {"status":"available"}
# image test (seed a file as www-data, fetch WITHOUT a token like an <img> tag):
#   docker exec -u 0 ba-test sh -c 'mkdir -p /data/bar-assistant/uploads/cocktails/1 && printf JPEG > /data/bar-assistant/uploads/cocktails/1/x.jpg && chown -R www-data:www-data /data/bar-assistant/uploads'
#   curl http://localhost:2118/bar/uploads/cocktails/1/x.jpg   -> 200
```

As an HA add-on: drop this folder into `/addons/<name>/` (or a repo), then
Settings → Add-ons → install/build. Watch the Bar Assistant log for
"Application ready" (first boot can take a minute+).

---

## Fixes applied & verified (2026-06-19) — don't regress these

Each is encoded in the Dockerfile with an inline comment; this is the index of
*why*, so they aren't accidentally "simplified" back into bugs.

1. **`ARG BUILD_FROM` must precede the first `FROM`.** Declared after the
   `meili`/`saltrim` stages it is stage-scoped and resolves blank → build error
   `base name (${BUILD_FROM}) should not be blank`. It's a global build arg now.
2. **Meilisearch is a musl (Alpine) binary on a glibc (Debian) base.** Copying
   just the binary fails to exec with `No such file or directory` (missing musl
   loader). Fix: also copy its two musl deps — `/lib/ld-musl-*.so.1` (loader +
   libc) and `/usr/lib/libgcc_s.so.1`. They sit at musl-specific paths and do not
   collide with glibc (whose libgcc is under `/lib/<triplet>/`). Verified the base
   PHP/nginx stack is unaffected. (See the Alpine decision below for why we did
   NOT rebuild the server on Alpine instead.)
3. **Meilisearch needs a writable CWD.** s6 launches services from `/` (not
   writable by www-data) → `Permission denied (os error 13)`. Its run script
   `cd`s into `$MEILI_DB_PATH` first.
4. **`S6_KEEP_ENV=1` makes `with-contenv` a no-op.** It does NOT import
   `/run/s6/container_environment`, so the documented HA-option→env path is dead.
   Options are instead propagated by ba-prep into (a) a sourceable
   `/run/bar-assistant.env` that our meilisearch + salt-rim run scripts `.`-source,
   and (b) Laravel's `.env`, which the base's `config:cache` bakes into the API.
   Without this, every user option (incl. the master key + registration flag) is
   silently ignored and the public default key stays active.
5. **jq option parsing must use `has($k)`, not `.[$k] // empty`.** The latter
   treats a boolean `false` as empty, so `ALLOW_REGISTRATION:false` would be
   dropped.
6. **`99-bass` races Meilisearch.** The base's `99-bass` runs
   `scout:sync-index-settings` under `set -e`; if Meilisearch isn't serving yet it
   exits 2 and s6 aborts the whole container. Fix: a `meili-ready` oneshot polls
   `/health` (bounded), and `99-bass` is given a dependency on it; `prep` is also
   ordered before `50-laravel-automations`.
7. **Image uploads 403 (NOT an auth issue).** The Bar Assistant nginx serves
   static uploads as the **`nginx` user** (uid 997, compile-time default — confirm
   with `nginx -V`, there is no `user` directive), but the base ships
   `storage/bar-assistant` as **0700 www-data**, so the nginx user can't traverse
   it to follow the public `uploads` symlink → `open() EACCES` → 403 on every
   image, with or without a token (`<img>` tags send no token anyway). Fix:
   ba-prep `chmod 0755` on that dir (uploads are public web assets; the DB lives in
   `/data`, not here). A 403→404 transition when testing means the traversal is
   fixed and the file is just absent.

## The Alpine question (decided: stay on Debian)

It is tempting to rebuild the server on Alpine so the musl Meilisearch binary runs
natively. **Don't.** The upstream server Dockerfile is thin (FROM
`serversideup/php:8.4-fpm-nginx` + `install-php-extensions` + composer), and
serversideup *does* publish an Alpine variant — so it's mechanically feasible — but:
(a) the only problem Alpine uniquely solves (musl Meilisearch) is already solved in
3 lines; (b) there is no published `barassistant/server` Alpine tag, so it means
maintaining a **from-source fork** instead of consuming the prebuilt image that
updates via a tag bump; (c) most workarounds above (`NGINX_HTTP_PORT`, the
`S6_KEEP_ENV` env handling, the `99-bass` ordering) come from serversideup +
bar-assistant's own scripts and would persist on Alpine anyway. Net: a permanent
fork to delete three lines. Revisit only if upstream stops publishing the Debian
image or the musl-lib copy starts breaking across Meilisearch upgrades.

---

## Things to verify / open risks

1. **serversideup running as root.** We set `USER root`; serversideup is normally
   rootless. php-fpm runs workers as `www-data` and nginx workers as the `nginx`
   user (uid 997). **Caveat (fixed):** php-fpm refuses to run workers as root and,
   when its master is root, requires each pool to name a non-root `user`/`group`.
   serversideup's pool config omits those (unneeded while rootless), so `USER root`
   made php-fpm abort with `[pool www] user has not been defined` ->
   `FPM initialization failed`. The Dockerfile appends `user = www-data` /
   `group = www-data` to `docker-php-serversideup-pool.conf` to fix this (see
   serversideup/docker-php #533). This can resurface if a base **patch** bump (the
   `server:5.15` tag floats on patch) renames/relocates that pool file — the smoke
   test's API health check is the guard.
2. **Meilisearch on aarch64.** VERIFIED on `meilisearch 1.15.2`: the copied binary
   execs and serves on aarch64 and amd64 with its musl deps (fix #2 above).
   **Re-verify after the v1.48 bump** — the musl-lib copy paths (`/bin/meilisearch`,
   `/lib/ld-musl-*.so.1`, `/usr/lib/libgcc_s.so.1`) are unverified across that span;
   a real build + smoke on both arches is the check.
3. **First-boot options timing.** Bar Assistant's one-time setup may run before
   option-derived env is fully in place. **After changing add-on options, restart
   the add-on** so keys/URLs line up. (Mitigated by fix #6's ordering, but the s6
   oneshots only run once per boot.)
4. **`X-Ingress-Path` / true HA ingress is intentionally NOT used.** Salt Rim is a
   root-path Vite SPA (absolute asset URLs) + a Laravel API needing a fixed
   absolute `APP_URL`; both break under ingress's dynamic token path. The
   single-port `webui` + `ports` approach is the deliberate choice. (Real ingress
   would require rebuilding Salt Rim from source with a relative Vite `base`.)
5. **`webui` port is a literal** (`[PORT:2118]`). If the published port is remapped
   in the HA Network tab, HA substitutes the effective port for the button — fine.
   But the `BASE_URL` option is not auto-derived; update it to match the real
   host/port.
6. **Ports are not configurable via options + `host_network: true` intentionally.**
   Current design: fixed internal ports, single published `2118`, remappable
   via the Network tab. Don't reintroduce `host_network` without intent.
7. **Health monitoring (don't remove).** Because s6's `/init` stays alive even
   when an inner service hangs, HA would otherwise report a wedged add-on as
   "Started". The Dockerfile `HEALTHCHECK` fixes this: it probes all three inner
   services (`127.0.0.1:2118/`, `:8081/api/server/version`, `:7700/health`), so
   any one failing flips the container to "unhealthy". Modern HA Supervisor
   drives its add-on watchdog off this HEALTHCHECK status, so the single
   directive gives both the UI health indicator and the auto-restart (when the
   user's **Watchdog toggle** is on). **Do NOT add a `watchdog:` key to
   config.yaml** — the official add-on linter (`frenck/action-addon-linter`,
   run in CI) rejects it as obsolete: "Use the native Docker HEALTHCHECK
   directive instead." The smoke test asserts the container reaches `healthy`.
   The 120s `start-period` matches first-boot migrations/index-sync — don't
   shorten it.
8. **AppArmor profile (`apparmor.txt`) must be kept in sync with Dockerfile
   changes.** The profile grants capabilities, exec rights, and file access
   tuned to the current stack. Changes that require updates:
   - **New binaries or scripts** added to the image need a matching `ix` rule
     if they're not already under a covered glob (e.g. `/usr/local/bin/**`).
   - **New capabilities** needed by ba-prep.sh or s6 scripts (e.g. adding
     `mount` operations) must be added as `capability` lines.
   - **New shared libraries** copied from other images (like the musl libs for
     Meilisearch) need `mr` rules if not already under `/lib/**` or `/usr/lib/**`.
   - **New data paths outside `/data/`** need explicit rules; everything under
     `/data/` and on the Docker VOLUME is already covered by `file,` +
     `attach_disconnected`.
   - **Upgrading Meilisearch to a glibc build** (if upstream ever switches)
     would let you drop the `/lib/ld-musl-*.so.1 mr` and
     `/usr/lib/libgcc_s.so.1 mr` lines.
   If the add-on starts failing to start or behaves strangely after a profile
   change, add `complain` to the flags line temporarily
   (`flags=(attach_disconnected,mediate_deleted,complain)`) and inspect denials
   with `journalctl _TRANSPORT=audit -g 'apparmor="ALLOWED"'` on the HA host,
   then remove `complain` once the profile is complete.

---

## Verified upstream facts (so you don't have to re-research)

- **Bar Assistant image** = `FROM serversideup/php:8.4-fpm-nginx`. App at
  `/var/www/cocktails`, webroot `/public`, default listen `:8080` (override via the
  `NGINX_HTTP_PORT` env var — the vhost is rendered from `.template` files at boot,
  so editing the rendered nginx `listen` at build time does not stick; this image
  sets `NGINX_HTTP_PORT=8081`). serversideup runs `/etc/entrypoint.d/*.sh` in
  order during s6 init; Bar Assistant's own is `99-bass.sh` (migrations, app key,
  Meilisearch index setup). Declares `VOLUME ["/var/www/cocktails/storage/bar-assistant"]`.
- **Bar Assistant config:** SQLite; `DB_DATABASE` overridable (default
  `storage_path('bar-assistant/database.ba3.sqlite')`). Uploads disk root =
  `storage_path('bar-assistant/uploads')` (NOT env-configurable); upload URL =
  `env('APP_URL') . '/uploads'`. Reads `MEILISEARCH_KEY`, `MEILISEARCH_HOST`,
  `APP_URL`. Real env vars override the baked `.env`.
- **Salt Rim image** = `FROM nginxinc/nginx-unprivileged`. Static SPA at
  `/var/www/html`; runtime config template at `/var/www/config.js` (the upstream
  entrypoint runs `envsubst` on it). In this image we copy it to
  `config.tmpl.js` and the `salt-rim` s6 run script does the `envsubst` →
  `config.js`. Browser talks to the API (`API_URL`) and Meilisearch
  (`MEILISEARCH_URL`) directly. Salt Rim is served at root `/`, so its absolute
  asset paths are fine in this single-port layout.
- **Bar Assistant subfolder requirements** (from the setup doc):
  `API_URL = <host>/bar`, `APP_URL = API_URL`, `MEILISEARCH_URL = <host>/search`;
  reverse proxy must strip the prefix (nginx trailing-slash `proxy_pass` does this
  automatically). Test endpoints: `/bar` ("This is your Bar Assistant instance."),
  `/bar/docs` (Swagger), `/bar/api/server/version` (JSON).
- **HA add-on rules:** `init: false` required for s6-overlay v3; ingress allows only
  `172.30.32.2`; `version` is required in `config.yaml`; `build.yaml` deprecated
  (use `FROM`/`ARG`/`LABEL` in the Dockerfile). `schema` port type exists but an
  option can't drive HA's static port-mapping table (would need `host_network`).

## Reference links

- Bar Assistant setup / reverse proxy: <https://docs.barassistant.app/setup/>
- HA add-on config reference: <https://developers.home-assistant.io/docs/apps/configuration>
- HA add-on presentation / ingress: <https://developers.home-assistant.io/docs/apps/presentation>
- Upstream compose (source of truth for service wiring): <https://github.com/bar-assistant/docker>