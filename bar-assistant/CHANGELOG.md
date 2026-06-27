# Changelog

All notable changes to this add-on are documented here. Versions follow the
5-part `<BA_maj>.<BA_min>.<SR_maj>.<SR_min>.<pkg>` scheme described in `CLAUDE.md`.

## 5.15.4.15.0

- First packaged release: Bar Assistant API 5.15 + Salt Rim 4.15 + Meilisearch
  v1.15, all in one s6-supervised image served on port 2118.
- Pre-built multi-arch images (amd64, aarch64) published to GHCR; Home Assistant
  pulls them instead of building locally.
