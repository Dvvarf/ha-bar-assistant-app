# Bar Assistant

Bar Assistant (API + Salt Rim web client) bundled with Meilisearch in a single
Home Assistant add-on. Everything is reached on one published port, **2118**:

- `/` — Salt Rim web client
- `/bar/` — Bar Assistant API
- `/search/` — Meilisearch

## First steps

1. Install and open the **Configuration** tab.
2. Set **`MEILI_MASTER_KEY`** to a private value (min 16 bytes). It ships empty,
   so the add-on will not start until you set one.
3. Set **`BASE_URL`** to the address your browser reaches the add-on at, as
   `protocol://host:port` with no path (e.g. `http://homeassistant.local:2118`).
   It is called by the browser, so it must be absolute and reachable from your
   device; the add-on adds the `/bar` and `/search` paths for you.
4. Start the add-on, then open the Web UI and register your first user.

> After changing any option, **restart** the add-on so the new keys/URLs apply.

See the **Documentation** tab for full details on each option, persistence, and
troubleshooting.
