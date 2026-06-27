# Bar Assistant add-on — Documentation

This add-on runs three services in one image, supervised by s6-overlay, behind a
single published port (**2118**):

| Path | Service |
| --- | --- |
| `/` | Salt Rim web client (the UI) |
| `/bar/` | Bar Assistant API (Laravel) |
| `/search/` | Meilisearch |

The API and Meilisearch are not published directly; they are reached through the
`/bar/` and `/search/` sub-paths of the same port (same-origin, so no CORS).

## Configuration

| Option | Default | Notes |
| --- | --- | --- |
| `MEILI_MASTER_KEY` | `please-change-me-min-16-bytes` | **Change this.** Min 16 bytes. Also used as the API↔search key internally. |
| `API_URL` | `http://homeassistant.local:2118/bar` | Browser-facing API base. **Must end in `/bar`** and be reachable from your browser. |
| `MEILISEARCH_URL` | `http://homeassistant.local:2118/search` | Browser-facing search base. **Must end in `/search`.** |
| `ALLOW_REGISTRATION` | `true` | Allow new user sign-ups. Set `false` after creating your account. |

`API_URL` and `MEILISEARCH_URL` are consumed **by the browser** (Salt Rim calls
both directly), so they must be absolute URLs that resolve from your device with
the real host and the effective port. If you remap port 2118 in the **Network**
tab, update these options to match.

> **Restart after changing options.** Some values are baked at boot; a restart
> guarantees the API, search key, and URLs line up.

## Persistence

All state lives under `/data` (the HA-persistent volume):

- Meilisearch database: `/data/meilisearch`
- Bar Assistant SQLite database: `/data/bar-assistant/database.ba3.sqlite`
- Uploads / exports / temp: `/data/bar-assistant/{uploads,exports,temp}`

Known gap: `bar:full-backup` zips are written to the (ephemeral) storage volume
root rather than `/data`; the database and uploads — the important data — are
persisted.

## Updating

Pre-built images are published to GHCR per release. When a new add-on version is
available, Home Assistant shows **Update** and pulls the matching image — no local
build on your device.

## Troubleshooting

- **Images don't load / 403:** resolved in this image (uploads dir is made
  traversable for the nginx user). If you see it, restart the add-on.
- **Search not working:** confirm `MEILI_MASTER_KEY` is set and you restarted
  after changing it; check `/search/health` returns `{"status":"available"}`.
- **API unreachable from the browser:** verify `API_URL` is the real host:port and
  ends in `/bar`.

For architecture and maintainer notes, see `CLAUDE.md` in this folder.
