<div align="center">

# 🔁 Recovarr

**Re-trigger Sonarr and Radarr imports for corrupted or missing media — with a live log and auto-unmonitor.**

[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![Node.js](https://img.shields.io/badge/node-%3E%3D18-brightgreen.svg)](https://nodejs.org/)
[![No npm deps](https://img.shields.io/badge/npm%20deps-none-lightgrey.svg)](#install)

</div>

---

Recovarr is a minimal Node.js web UI that queues corrupted or missing file paths for recovery, streams the live recovery log to your browser, polls Sonarr or Radarr until the import completes, and then automatically unmonitors the episode or movie so your curation stays clean.

No npm packages. No config files to edit by hand. Just Node.js, Bash, curl, and jq.

---

## What happens when you recover a file

1. Identify the media in Sonarr (TV) or Radarr (Movies) via the parse API
2. Check the download queue for a pending import
3. Check download history to see if the original torrent is still seeding
4. **If still available:** delete the file record and trigger an import scan
5. **If not available:** delete the file record and trigger an automatic search
6. Poll every 30 seconds until the download lands
7. Auto-unmonitor the episode or movie once the import confirms

---

## Quick start

```bash
git clone https://git.opensourcesolarpunk.com/Circuit-Forge/recovarr
cd recovarr

# Set up your API keys
mkdir -p ~/.config/media-postprocessor
cat > ~/.config/media-postprocessor/api-keys.conf <<EOF
SONARR_URL=http://your-sonarr-host:8989/sonarr
SONARR_API_KEY=your-sonarr-api-key
RADARR_URL=http://your-radarr-host:7878/radarr
RADARR_API_KEY=your-radarr-api-key
QBIT_USER=admin
QBIT_PASS=your-password
EOF

# Run
node server.js
```

Open `http://localhost:8602`, paste one or more file paths, and click **Recover**.

---

## Install

```bash
git clone https://git.opensourcesolarpunk.com/Circuit-Forge/recovarr
cd recovarr
```

Requirements: Node.js 18+, Bash 4+, curl, jq.

---

## Config

All config lives in `~/.config/media-postprocessor/api-keys.conf`. Every key can also be set as an environment variable.

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8602` | Web UI port |
| `ARR_RECOVER_CONFIG` | `~/.config/media-postprocessor/api-keys.conf` | Config file path |
| `ARR_RECOVER_SCRIPT` | `./recovarr.sh` | Path to the recovery script |
| `ARR_RECOVER_LOG` | `~/.local/share/recovarr/jobs.log` | Job log path |
| `ARR_RECOVER_QUEUE` | `~/.local/share/recovarr/pending-queue.json` | Pending queue path |

---

## CLI usage

`recovarr.sh` can also be run directly without the web UI:

```bash
# Recover a single file
./recovarr.sh /path/to/corrupted/file.mkv

# Dry run — show what would happen without making changes
./recovarr.sh /path/to/file.mkv --dry-run

# Force Sonarr or Radarr (override path detection)
./recovarr.sh /path/to/file.mkv --sonarr
./recovarr.sh /path/to/file.mkv --radarr

# Batch recover from a file list (one path per line)
./recovarr.sh --batch paths.txt

# Verbose API output
./recovarr.sh /path/to/file.mkv --verbose

# Skip availability check and go straight to triggering a search
./recovarr.sh /path/to/file.mkv --search-only
```

---

## API

The web UI communicates with this API. Useful for scripting or integration with other tools.

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/recover` | Queue paths: `{ "paths": ["/path/to/file.mkv"] }` |
| `GET` | `/api/jobs` | List all jobs |
| `GET` | `/api/jobs/:id` | Job detail + full log |
| `GET` | `/api/jobs/:id/stream` | SSE stream of live log output |
| `POST` | `/api/jobs/:id/retry` | Retry a failed job |
| `DELETE` | `/api/jobs/:id` | Delete job (`?force=true` cancels active jobs) |

---

## Related

- [**Discarr**](https://git.opensourcesolarpunk.com/Circuit-Forge/discarr) — scan disc rips, map to Sonarr/Radarr, queue HEVC encodes

---

## Contributing

Issues and PRs welcome. Please open an issue before starting a large change.

## License

GPL-3.0 — see [LICENSE](LICENSE).
