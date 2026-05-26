# Recovarr

> Web UI for re-triggering Sonarr/Radarr imports on corrupted or missing media files.

Recovarr queues file paths for `recovarr.sh`, streams live script output via Server-Sent Events (SSE), polls Sonarr/Radarr for import completion, and auto-unmonitors episodes/movies once the download lands.

---

## What it does

Given a path to a corrupted or missing media file, Recovarr:

1. Identifies the media in Sonarr (TV) or Radarr (Movies) via the parse API
2. Checks the download queue for a pending import
3. Checks download history to see if the original torrent is still available
4. If available: deletes the file record and triggers an import scan
5. If not available: deletes the file record and triggers an automatic search
6. Polls every 30s until the import completes, then auto-unmonitors

---

## Requirements

- Node.js 18+
- Bash 4+, curl, jq (for `recovarr.sh`)
- No npm dependencies — pure Node.js built-ins only

---

## Install

```bash
git clone https://git.opensourcesolarpunk.com/Circuit-Forge/recovarr
cd recovarr
```

### Config

```bash
mkdir -p ~/.config/media-postprocessor
cat > ~/.config/media-postprocessor/api-keys.conf <<EOF
SONARR_URL=http://your-sonarr-host:8989/sonarr
SONARR_API_KEY=your-sonarr-api-key
RADARR_URL=http://your-radarr-host:7878/radarr
RADARR_API_KEY=your-radarr-api-key
QBIT_USER=admin
QBIT_PASS=adminadmin
EOF
```

---

## Run

```bash
node server.js
# or with overrides:
PORT=8602 ARR_RECOVER_SCRIPT=/path/to/recovarr.sh node server.js
```

Open `http://localhost:8602` in your browser. Paste one or more file paths and click **Recover**.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `PORT` | `8602` | Web UI port |
| `ARR_RECOVER_CONFIG` | `~/.config/media-postprocessor/api-keys.conf` | Config file path |
| `ARR_RECOVER_SCRIPT` | `./recovarr.sh` | Path to the recovarr.sh script |
| `ARR_RECOVER_LOG` | `~/.local/share/recovarr/jobs.log` | Job log path |
| `ARR_RECOVER_QUEUE` | `~/.local/share/recovarr/pending-queue.json` | Pending queue path |

---

## API

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/recover` | Queue file paths `{ paths: ["/path/to/file"] }` |
| `GET` | `/api/jobs` | List all jobs |
| `GET` | `/api/jobs/:id` | Get job detail + log lines |
| `GET` | `/api/jobs/:id/stream` | SSE stream of live log output |
| `POST` | `/api/jobs/:id/retry` | Retry a failed job |
| `DELETE` | `/api/jobs/:id` | Delete a job (`?force=true` to cancel active) |

---

## License

GPL-3.0
