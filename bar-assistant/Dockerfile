# syntax=docker/dockerfile:1
###############################################################################
# Home Assistant add-on: Bar Assistant stack
# (Meilisearch + Bar Assistant API + Salt Rim, all supervised by s6-overlay)
#
# Everything is served on a single published port via the Salt Rim nginx:
#   :2118/         -> salt-rim (web client)        <- published
#   :2118/bar/     -> bar-assistant API  (proxy -> 127.0.0.1:8081, internal)
#   :2118/search/  -> meilisearch        (proxy -> 127.0.0.1:7700, internal)
# Only :2118 is exposed; the API and Meilisearch are reached through subfolders.
#
# All persistent data lives under /data (the HA-persistent volume):
#   /data/meilisearch                 Meilisearch DB
#   /data/bar-assistant/              Bar Assistant DB + uploads/exports/temp
#
# Base image: the Alpine HA base can't host the Debian/PHP Bar Assistant stack,
# so we build on the Bar Assistant image (which already ships s6-overlay) via
# the ARG BUILD_FROM default below.
###############################################################################

# BUILD_FROM must be declared before the first FROM so it is a global build
# arg usable in a FROM line (HA's builder passes it in; the default is used
# when building standalone). Declared after a FROM it would be stage-scoped
# and resolve blank in `FROM ${BUILD_FROM}`.
#
# Upstreams are pinned to their MINOR tag (server:5.15, salt-rim:4.15,
# meilisearch:v1.15), not the floating major (:v5 / :v4). This still tracks
# patch releases automatically, but fixes the major.minor at build time so the
# add-on version can honestly mirror it -- the add-on version is
# <BA_major>.<BA_minor>.<SR_major>.<SR_minor>.<pkg> (see "Versioning" in CLAUDE.md).
# When either upstream's major/minor moves, bump the matching tag here AND the
# matching field in the version.
ARG BUILD_FROM=barassistant/server:5.15

FROM getmeili/meilisearch:v1.48 AS meili
FROM barassistant/salt-rim:4.15 AS saltrim

FROM ${BUILD_FROM}

# Run as root so the add-on can manage /data and write the s6 container
# environment; individual services drop to www-data where appropriate.
USER root

# php-fpm refuses to run its workers as root: when the master runs as root it
# REQUIRES each pool to name a non-root `user`/`group`. serversideup's image is
# built to run rootless (master == www-data), so its pool config
# (docker-php-serversideup-pool.conf, the `[www]` pool) omits those directives --
# unnecessary while unprivileged. Forcing `USER root` (above) makes the master
# root, so the missing directives now fail hard at boot:
#   ALERT: [pool www] user has not been defined
#   ERROR: failed to post process the configuration
#   ERROR: FPM initialization failed
# Pin the workers to www-data (the upstream-intended runtime user) so php-fpm
# initializes. Leading newline guards against the file lacking a trailing one.
# See serversideup/docker-php discussion #533.
RUN printf '\nuser = www-data\ngroup = www-data\n' \
        >> /usr/local/etc/php-fpm.d/docker-php-serversideup-pool.conf

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl gettext-base jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Meilisearch binary (internal only). DB path lives under /data.
#
# The official meilisearch image is Alpine, so its binary is musl-linked
# (interpreter /lib/ld-musl-*.so.1) while this base is Debian/glibc. Copying
# the binary alone fails to exec ("No such file or directory" = missing musl
# loader). We bring its two musl runtime deps along: the loader (also musl
# libc) and the musl build of libgcc_s. They sit at musl-specific paths and
# do not collide with glibc (whose libgcc lives under /lib/<triplet>/), so the
# Debian PHP/nginx stack is unaffected. The ld-musl-* glob keeps it multi-arch.
# ---------------------------------------------------------------------------
COPY --from=meili /bin/meilisearch       /usr/local/bin/meilisearch
COPY --from=meili /lib/ld-musl-*.so.1    /lib/
COPY --from=meili /usr/lib/libgcc_s.so.1 /usr/lib/libgcc_s.so.1

# ---------------------------------------------------------------------------
# Salt Rim static SPA + its own nginx config (served on :2118). The
# /meilisearch/ proxy lets the browser reach Meilisearch without publishing it.
# ---------------------------------------------------------------------------
COPY --from=saltrim /var/www/html       /var/www/salt-rim
COPY --from=saltrim /var/www/config.js  /var/www/salt-rim/config.tmpl.js
RUN chown -R www-data:www-data /var/www/salt-rim

RUN cat > /etc/nginx-salt-rim.conf <<'SRCONF'
worker_processes auto;
daemon off;
pid /tmp/sr-nginx/sr-nginx.pid;
# Use the literal `stderr` target (the already-open fd 2), not /dev/stderr:
# this nginx runs as www-data, which cannot reopen root's /dev/stderr.
error_log stderr error;
events {}
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;

    client_body_temp_path /tmp/sr-nginx/body;
    proxy_temp_path       /tmp/sr-nginx/proxy;
    fastcgi_temp_path     /tmp/sr-nginx/fastcgi;
    uwsgi_temp_path       /tmp/sr-nginx/uwsgi;
    scgi_temp_path        /tmp/sr-nginx/scgi;
    client_max_body_size  100M;

    server {
        listen 2118 default_server;
        listen [::]:2118 default_server;
        server_name _;
        root /var/www/salt-rim;

        # config.js carries the runtime API_URL/MEILISEARCH_URL that ba-prep +
        # envsubst bake from the user's add-on options on every boot. Served as a
        # plain static file the browser would cache it indefinitely, so after a
        # user changes an option (e.g. MEILISEARCH_URL's host) the page keeps
        # replaying the stale value from the cached copy. Cap the cache at one day
        # so an option change propagates within a day (or immediately on a hard
        # reload) without re-fetching it on every single page load.
        location = /config.js {
            add_header Cache-Control "public, max-age=86400" always;
            expires 1d;
            try_files $uri =404;
        }

        # Salt Rim web client (static SPA shipped in this image). The SPA shell
        # (index.html) must not be cached either, or a stale shell keeps pointing
        # at old hashed assets / config; hashed assets under it stay cacheable.
        location / {
            try_files $uri $uri/ /index.html;
        }

        location = /index.html {
            add_header Cache-Control "no-store, no-cache, must-revalidate" always;
            expires -1;
        }

        # Bar Assistant API under /bar/. The trailing slash on proxy_pass
        # strips the /bar prefix (/bar/api/... -> /api/...), as the Bar
        # Assistant docs require. ba-prep derives API_URL=APP_URL=BASE_URL/bar.
        location = /bar { return 301 /bar/; }
        location /bar/ {
            proxy_pass http://127.0.0.1:8081/;
            proxy_http_version 1.1;
            proxy_set_header Host              $host;
            proxy_set_header X-Real-IP         $remote_addr;
            proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # Meilisearch under /search/ (prefix stripped the same way).
        # The browser talks to it here; it is never published directly.
        # ba-prep derives MEILISEARCH_URL=BASE_URL/search.
        location /search/ {
            proxy_pass http://127.0.0.1:7700/;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
        }
    }
}
SRCONF

# ---------------------------------------------------------------------------
# Move the Bar Assistant nginx vhost off the base default :8080 to :8081, so it
# stays clearly separated from Salt Rim (which serves the published :2118) and
# is only reachable internally. The base (serversideup/php) renders its nginx
# config from .template files at boot, with the listen port taken from
# ${NGINX_HTTP_PORT} (default 8080) -- so editing the rendered /etc/nginx files
# at build time is undone on
# every start. Setting the env var is the supported knob; the base's own nginx
# healthcheck reads the same var, so it follows to 8081 too.
# ---------------------------------------------------------------------------
ENV NGINX_HTTP_PORT=8081

# ---------------------------------------------------------------------------
# Configuration defaults. These are BUILD-TIME defaults only; the actual
# runtime values are resolved by ba-prep from the HA add-on options (see below).
#
# Important: the base sets S6_KEEP_ENV=1, so `with-contenv` is a pass-through
# that never imports /run/s6/container_environment -- services inherit the
# Docker ENV instead, and Laravel's dotenv won't override an already-set env
# var. So the user-overridable keys the API consumes (MEILISEARCH_KEY, APP_URL,
# ALLOW_REGISTRATION, the AI/LLM keys, and the cache/session drivers) are
# deliberately NOT set as ENV here: that lets ba-prep write them into Laravel's
# .env where they take effect. CACHE_DRIVER/SESSION_DRIVER in particular MUST be
# resolved by ba-prep -- the base image's bundled .env defaults them to `redis`
# (upstream ships a Redis container), and this image has none, so ba-prep forces
# `file` unless the user points at an external Redis. The remaining keys are
# internal/fixed (or only consumed by our own meilisearch/salt-rim services,
# which source ba-prep's resolved env file directly).
# ---------------------------------------------------------------------------
# No MEILI_MASTER_KEY default here on purpose. resolve() falls back to this ENV
# when the add-on option is blank, so a placeholder here would let the add-on
# boot on a public key. Leaving it unset means a blank option stays blank, and
# Meilisearch (MEILI_ENV=production) refuses to start without a real key.
ENV MEILI_DB_PATH=/data/meilisearch \
    MEILI_HTTP_ADDR=127.0.0.1:7700 \
    MEILI_NO_ANALYTICS=true \
    MEILI_ENV=production
ENV MEILISEARCH_HOST=http://127.0.0.1:7700 \
    DB_CONNECTION=sqlite \
    DB_DATABASE=/data/bar-assistant/database.ba3.sqlite
# Single browser-facing origin (protocol://host:port, no suffix). ba-prep
# appends the fixed /bar and /search suffixes to derive API_URL and
# MEILISEARCH_URL -- see the resolve/derive block in ba-prep below.
ENV BASE_URL=http://homeassistant.local:2118 \
    DEFAULT_LOCALE=en-US \
    MAILS_ENABLED=false

# ---------------------------------------------------------------------------
# Shared prep script: create /data layout, relocate Bar Assistant storage into
# /data, and resolve HA add-on options into the places each consumer reads.
#
# Because S6_KEEP_ENV=1 makes /run/s6/container_environment a dead end, options
# are propagated two ways: (1) a sourceable /run/bar-assistant.env that our own
# meilisearch + salt-rim services read, and (2) Laravel's .env, which the base's
# `config:cache` bakes into the API's effective config.
# ---------------------------------------------------------------------------
RUN cat > /usr/local/bin/ba-prep.sh <<'PREP'
#!/usr/bin/env bash
set -u
mkdir -p /data/meilisearch \
         /data/bar-assistant/uploads \
         /data/bar-assistant/exports \
         /data/bar-assistant/temp
chown -R www-data:www-data /data/meilisearch /data/bar-assistant 2>/dev/null || true

# The storage path is an inherited Docker VOLUME (can't be replaced wholesale),
# so symlink the data-bearing subdirs into /data instead. The DB itself is
# relocated via DB_DATABASE. Symlinks are recreated every boot (idempotent).
STORE=/var/www/cocktails/storage/bar-assistant
mkdir -p "$STORE" 2>/dev/null || true
for sub in uploads exports temp; do
    link="$STORE/$sub"
    if [ ! -L "$link" ]; then
        if [ -d "$link" ] && [ -n "$(ls -A "$link" 2>/dev/null)" ] \
           && [ -z "$(ls -A "/data/bar-assistant/$sub" 2>/dev/null)" ]; then
            cp -a "$link/." "/data/bar-assistant/$sub/" 2>/dev/null || true
        fi
        rm -rf "$link" 2>/dev/null || true
        ln -sfn "/data/bar-assistant/$sub" "$link"
    fi
done
chown -h www-data:www-data "$STORE/uploads" "$STORE/exports" "$STORE/temp" 2>/dev/null || true

# Uploaded images are served as static files by the Bar Assistant nginx, whose
# workers run as the `nginx` user (compile-time default, uid 997) -- NOT as the
# www-data owner of the files. The base image ships storage/bar-assistant as
# 0700 www-data, so the nginx user cannot traverse it to follow the public
# `uploads` symlink -> open() EACCES -> HTTP 403 on every image. The uploads are
# public web assets, so make the dir traversable. (The sensitive DB lives in
# /data, not here, and nothing under it is web-exposed except the uploads link.)
chmod 0755 "$STORE" 2>/dev/null || true

# Resolve each value: HA option if set, else the image ENV default.
OPT=/data/options.json
opt() {  # opt KEY -> option value (or empty). `has()` so boolean false survives,
         # unlike `.[k] // empty`, which jq treats false as empty.
    [ -r "$OPT" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r --arg k "$1" 'if has($k) then .[$k] else empty end' "$OPT" 2>/dev/null
}
resolve() { v="$(opt "$1")"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

# Nested getter for the `ai`/`redis` option groups: optp GROUP KEY -> value at
# .GROUP.KEY when present, else empty. Same has()-based test as opt() so a
# boolean false is not swallowed.
optp() {
    [ -r "$OPT" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0
    jq -r --arg g "$1" --arg k "$2" \
      'if (has($g) and (.[$g]|type=="object") and (.[$g]|has($k))) then .[$g][$k] else empty end' \
      "$OPT" 2>/dev/null
}

MASTER_KEY="$(resolve MEILI_MASTER_KEY "${MEILI_MASTER_KEY:-}")"
# Single configurable origin -> the two browser-facing URLs. The /bar and
# /search suffixes are fixed by the reverse-proxy layout (nginx strips them
# before forwarding), so they are appended here rather than exposed as options.
# Tolerate a trailing slash on BASE_URL so we never emit a doubled `//bar`.
BASE="$(resolve BASE_URL "${BASE_URL:-}")"
BASE="${BASE%/}"
API="${BASE}/bar"
SEARCH_URL="${BASE}/search"
REG="$(resolve ALLOW_REGISTRATION true)"

# Meilisearch logs at its OWN MEILI_LOG_LEVEL (scale OFF/ERROR/WARN/INFO/DEBUG/
# TRACE, built-in default INFO) -- it does NOT read Laravel's LOG_LEVEL, so
# without this it always emits INFO noise (e.g. "actix_server: Actix runtime
# found...") no matter what the add-on option says. Map the add-on's Monolog-style
# LOG_LEVEL onto Meilisearch's coarser scale; default to the add-on's documented
# `warning` (-> WARN) so Meilisearch is quiet by default, matching the API.
LL="$(opt LOG_LEVEL)"
case "${LL:-warning}" in
    debug)                          MEILI_LL=DEBUG ;;
    info|notice)                    MEILI_LL=INFO ;;
    warning)                        MEILI_LL=WARN ;;
    error|critical|alert|emergency) MEILI_LL=ERROR ;;
    *)                              MEILI_LL=WARN ;;
esac

# (1) Sourceable env for our own services (meilisearch, salt-rim). MEILISEARCH_KEY
# must equal Meilisearch's master key for the API<->search handshake to work.
cat > /run/bar-assistant.env <<EOF
export MEILI_MASTER_KEY='${MASTER_KEY}'
export MEILISEARCH_KEY='${MASTER_KEY}'
export MEILI_LOG_LEVEL='${MEILI_LL}'
export API_URL='${API}'
export APP_URL='${API}'
export MEILISEARCH_URL='${SEARCH_URL}'
export ALLOW_REGISTRATION='${REG}'
export DEFAULT_LOCALE='${DEFAULT_LOCALE:-en-US}'
export MAILS_ENABLED='${MAILS_ENABLED:-false}'
EOF

# (2) Laravel .env for the API (baked by `php artisan config:cache`). Upsert the
# user-resolved values; these keys are intentionally unset as image ENV so .env
# is not shadowed.
ENVFILE=/var/www/cocktails/.env
set_env() {
    [ -f "$ENVFILE" ] || return 0
    if grep -qE "^${1}=" "$ENVFILE"; then
        sed -i "s|^${1}=.*|${1}=${2}|" "$ENVFILE"
    else
        printf '%s=%s\n' "$1" "$2" >> "$ENVFILE"
    fi
}
set_env APP_URL "${API}"
set_env MEILISEARCH_KEY "${MASTER_KEY}"
set_env MEILISEARCH_HOST "${MEILISEARCH_HOST:-http://127.0.0.1:7700}"
set_env ALLOW_REGISTRATION "${REG}"

# --- General optional toggles. Written only when the user actually set them;
# left absent otherwise so the upstream config defaults apply. APP_NAME is quoted
# because it may contain spaces. ---
APP_NAME_VAL="$(opt APP_NAME)"
[ -n "$APP_NAME_VAL" ] && set_env APP_NAME "\"${APP_NAME_VAL}\""
for k in LOG_LEVEL ENABLE_FEEDS SESSION_LIFETIME; do
    v="$(opt "$k")"
    [ -n "$v" ] && set_env "$k" "$v"
done

# --- AI / LLM. The `ai.provider` dropdown picks a Prism provider; the single
# generic api_key/base_url is routed to that provider's own *_API_KEY / *_URL
# (the uppercased provider name matches every Prism provider, e.g.
# anthropic -> ANTHROPIC_API_KEY / ANTHROPIC_URL). Ollama needs no key. ---
AI_PROVIDER="$(optp ai provider)"
if [ -n "$AI_PROVIDER" ]; then
    set_env GEN_AI_PROVIDER "$AI_PROVIDER"
    v="$(optp ai model)";   [ -n "$v" ] && set_env GEN_AI_MODEL "$v"
    v="$(optp ai timeout)"; [ -n "$v" ] && set_env GEN_AI_TIMEOUT "$v"
    PFX="$(printf '%s' "$AI_PROVIDER" | tr '[:lower:]' '[:upper:]')"
    v="$(optp ai api_key)";  [ -n "$v" ] && set_env "${PFX}_API_KEY" "$v"
    v="$(optp ai base_url)"; [ -n "$v" ] && set_env "${PFX}_URL" "$v"
fi
v="$(optp ai image_provider)"; [ -n "$v" ] && set_env GEN_AI_IMAGE_PROVIDER "$v"
v="$(optp ai image_model)";    [ -n "$v" ] && set_env GEN_AI_IMAGE_MODEL "$v"
v="$(optp ai mcp_server)";     [ -n "$v" ] && set_env ENABLE_MCP_SERVER "$v"

# --- Redis. With a host set, switch cache + session to Redis and point at it.
# QUEUE_CONNECTION stays the upstream `sync` default on purpose: this image runs
# no queue worker, so a redis queue would strand background jobs. With no host,
# force file drivers -- the base image's bundled .env defaults them to redis,
# which would otherwise fail since this image ships no Redis. ---
REDIS_HOST_VAL="$(optp redis host)"
if [ -n "$REDIS_HOST_VAL" ]; then
    set_env REDIS_HOST "$REDIS_HOST_VAL"
    set_env REDIS_PORT "$(optp redis port | grep -E '^[0-9]+$' || printf 6379)"
    v="$(optp redis password)"; [ -n "$v" ] && set_env REDIS_PASSWORD "$v"
    set_env CACHE_DRIVER redis
    set_env SESSION_DRIVER redis
else
    set_env CACHE_DRIVER file
    set_env SESSION_DRIVER file
fi

chown www-data:www-data "$ENVFILE" 2>/dev/null || true
exit 0
PREP
RUN chmod +x /usr/local/bin/ba-prep.sh

# Wait until Meilisearch is actually serving. The base's 99-bass init runs
# `scout:sync-index-settings`, which hard-fails (set -e -> exit 2) if Meilisearch
# isn't reachable yet -- so without this gate 99-bass races the meilisearch
# longrun on boot. Bounded so a genuinely-dead Meilisearch can't hang startup
# forever; we exit 0 regardless so 99-bass proceeds (and surfaces the real
# error itself) rather than failing the whole s6 bring-up here.
RUN cat > /usr/local/bin/meili-wait.sh <<'WAIT'
#!/usr/bin/env bash
addr="${MEILI_HTTP_ADDR:-127.0.0.1:7700}"
for _ in $(seq 1 60); do
    curl -fsS "http://${addr}/health" >/dev/null 2>&1 && exit 0
    sleep 1
done
echo "meili-wait: timed out waiting for meilisearch at ${addr}" >&2
exit 0
WAIT
RUN chmod +x /usr/local/bin/meili-wait.sh

# ---------------------------------------------------------------------------
# s6-overlay services (the base image's /init supervises these alongside
# Bar Assistant's own php-fpm + nginx):
#   prep        oneshot  -> runs ba-prep.sh
#   meilisearch longrun  -> depends on prep
#   meili-ready oneshot  -> depends on meilisearch; blocks until /health is up
#   salt-rim    longrun  -> depends on prep
# The base's 99-bass is made to depend on meili-ready so its index sync only
# runs once Meilisearch is serving.
# ---------------------------------------------------------------------------
RUN set -eux; \
    base=/etc/s6-overlay/s6-rc.d; \
    # prep (oneshot)
    mkdir -p "$base/prep"; \
    printf 'oneshot' > "$base/prep/type"; \
    printf '%s\n' '/command/with-contenv bash /usr/local/bin/ba-prep.sh' > "$base/prep/up"; \
    # meilisearch (longrun)
    mkdir -p "$base/meilisearch/dependencies.d"; \
    printf 'longrun' > "$base/meilisearch/type"; \
    touch "$base/meilisearch/dependencies.d/prep"; \
    # meili-ready (oneshot) -> gate the base init on Meilisearch being up
    mkdir -p "$base/meili-ready/dependencies.d"; \
    printf 'oneshot' > "$base/meili-ready/type"; \
    printf '%s\n' '/command/with-contenv bash /usr/local/bin/meili-wait.sh' > "$base/meili-ready/up"; \
    touch "$base/meili-ready/dependencies.d/meilisearch"; \
    # salt-rim (longrun)
    mkdir -p "$base/salt-rim/dependencies.d"; \
    printf 'longrun' > "$base/salt-rim/type"; \
    touch "$base/salt-rim/dependencies.d/prep"; \
    # make the base's 99-bass init wait for Meilisearch readiness
    printf '%s\n' 'meili-ready' >> "$base/99-bass/dependencies"; \
    # ensure prep (which writes .env) runs before the base bakes config:cache
    printf '%s\n' 'prep' >> "$base/50-laravel-automations/dependencies"; \
    # register our services in the user bundle
    mkdir -p "$base/user/contents.d"; \
    touch "$base/user/contents.d/prep" \
          "$base/user/contents.d/meilisearch" \
          "$base/user/contents.d/meili-ready" \
          "$base/user/contents.d/salt-rim"

RUN cat > /etc/s6-overlay/s6-rc.d/meilisearch/run <<'RUNMEILI'
#!/command/with-contenv sh
# Pick up the user's resolved MEILI_MASTER_KEY and MEILI_LOG_LEVEL (with-contenv
# can't, due to S6_KEEP_ENV=1); prep wrote this before meilisearch starts
# (dependency). MEILI_LOG_LEVEL maps the add-on LOG_LEVEL onto Meilisearch's own
# scale so it isn't stuck at its INFO default.
[ -r /run/bar-assistant.env ] && . /run/bar-assistant.env
# Meilisearch writes into its current working directory at startup, and s6
# launches services from "/" (not writable by www-data) -> "Permission denied
# (os error 13)". cd into the data dir (which prep created and chowned) first.
cd "${MEILI_DB_PATH:-/data/meilisearch}" || exit 1
exec s6-setuidgid www-data meilisearch
RUNMEILI

RUN cat > /etc/s6-overlay/s6-rc.d/salt-rim/run <<'RUNSR'
#!/command/with-contenv sh
# Source the user's resolved config (API_URL, MEILISEARCH_URL, ALLOW_REGISTRATION,
# ...) so envsubst bakes the right values into config.js. with-contenv alone
# can't deliver them here (S6_KEEP_ENV=1); prep wrote this file before we start.
[ -r /run/bar-assistant.env ] && . /run/bar-assistant.env
mkdir -p /tmp/sr-nginx/body /tmp/sr-nginx/proxy /tmp/sr-nginx/fastcgi /tmp/sr-nginx/uwsgi /tmp/sr-nginx/scgi
chown -R www-data:www-data /tmp/sr-nginx
envsubst < /var/www/salt-rim/config.tmpl.js > /var/www/salt-rim/config.js
chown www-data:www-data /var/www/salt-rim/config.js
exec s6-setuidgid www-data /usr/sbin/nginx -c /etc/nginx-salt-rim.conf
RUNSR

RUN chmod +x /etc/s6-overlay/s6-rc.d/meilisearch/run \
             /etc/s6-overlay/s6-rc.d/salt-rim/run

LABEL \
  io.hass.version="5.15.4.15.3" \
  io.hass.type="app" \
  io.hass.arch="aarch64|amd64" \
  io.hass.name="Bar Assistant stack" \
  io.hass.description="Meilisearch + Bar Assistant API + Salt Rim in one add-on"

EXPOSE 2118

# ---------------------------------------------------------------------------
# Container healthcheck. s6's /init stays alive even when one of the three
# inner services hangs (and s6 only restarts a longrun that *exits*, not one
# that wedges), so without this HA/Docker would report the add-on healthy while
# it is not responding. Probe all three independently, inside the container, so
# a failure of ANY one flips the container to "unhealthy". Modern HA Supervisor
# drives its add-on watchdog off this HEALTHCHECK status (the obsolete
# config.yaml `watchdog:` key is rejected by the add-on linter), so this single
# directive gives both the health indicator in the UI and the auto-restart when
# the user's Watchdog toggle is on -- across all three services:
#   salt-rim SPA   http://127.0.0.1:2118/                 (published nginx)
#   API (php-fpm)  http://127.0.0.1:8081/api/server/version (NGINX_HTTP_PORT,
#                  no /bar prefix -- that is only added by the salt-rim proxy)
#   meilisearch    http://127.0.0.1:7700/health
# Long start-period: first boot runs migrations + index sync and can take a
# minute+, so don't mark unhealthy while the stack is still coming up. curl is
# already installed above.
# ---------------------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD curl -fsS http://127.0.0.1:2118/ >/dev/null \
   && curl -fsS http://127.0.0.1:8081/api/server/version >/dev/null \
   && curl -fsS http://127.0.0.1:7700/health >/dev/null \
   || exit 1

# Keep the base image's s6 ENTRYPOINT (/init) -- it now supervises all three.
