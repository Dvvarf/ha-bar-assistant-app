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

### Optional options

Everything below is **optional** and hidden until you expand **Show unused
optional configuration options** in the add-on Configuration tab. Leave them
untouched to keep Bar Assistant's defaults.

**General**

| Option | Default | Notes |
| --- | --- | --- |
| `APP_NAME` | `Bar Assistant` | Display name used by the API. |
| `LOG_LEVEL` | `warning` | `debug`/`info`/`notice`/`warning`/`error`/`critical`/`alert`/`emergency`. |
| `ENABLE_PASSWORD_LOGIN` | `true` | Set `false` if you only use SSO (not configured by this add-on). |
| `ENABLE_FEEDS` | `false` | Enable activity feeds. |
| `SESSION_LIFETIME` | `120` | Session length in minutes. |

**AI / LLM** (`ai` group)

Pick one provider; the single API key/URL is routed to it automatically.

| Option | Notes |
| --- | --- |
| `provider` | `openai`, `anthropic`, `ollama`, `mistral`, `groq`, `xai`, `gemini`, `deepseek`, `openrouter`, `elevenlabs`, `voyageai`. |
| `model` | Model id for the chosen provider. |
| `api_key` | API key for the chosen provider (not needed for `ollama`). |
| `base_url` | Optional custom endpoint (e.g. your Ollama URL, an OpenAI-compatible gateway). |
| `timeout` | Request timeout in seconds (default 60). |
| `image_provider` / `image_model` | Optional separate provider/model for image generation. If it differs from `provider`, it reuses the same `api_key`. |
| `mcp_server` | Enable the built-in MCP server. |

**Redis** (`redis` group)

This image ships **no** Redis. Point these at an *external* Redis (e.g. a
separate add-on) to move cache + sessions off the local filesystem. When `host`
is set, cache and session drivers switch to Redis; the job queue stays `sync`
(this add-on runs no queue worker).

| Option | Default | Notes |
| --- | --- | --- |
| `host` | — | External Redis host. Setting this enables Redis. |
| `port` | `6379` | |
| `password` | — | Optional. |

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
