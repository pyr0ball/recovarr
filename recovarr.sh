#!/usr/bin/env bash
#
# recovarr.sh - Recover a corrupted media file via Sonarr/Radarr
# Relative Path: ./scripts/recovarr.sh
#
# Purpose and usage:
#   Given a file path to a corrupted video, this script:
#     1. Identifies the media in Sonarr (TV) or Radarr (Movies) via the parse API
#     2. Checks the download queue for a pending import of this item
#     3. Checks download history + qBittorrent to see if the original torrent is still seeding
#     4. If original is available: deletes the corrupted file record and triggers an import scan
#     5. If not available: deletes the file record and triggers an automatic search
#
# Usage:
#   ./recovarr.sh <file_path> [options]
#   ./recovarr.sh --batch <file_list.txt> [options]
#
# Options:
#   --dry-run     Show what would happen without making changes
#   --verbose     Show detailed API responses
#   --search-only Skip availability check, go straight to triggering a search
#   --sonarr      Force Sonarr (override path-based detection)
#   --radarr      Force Radarr (override path-based detection)
#
# Config file: ~/.config/media-postprocessor/api-keys.conf
#   SONARR_URL=http://your-sonarr-host:8989
#   SONARR_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#   RADARR_URL=http://your-radarr-host:7878
#   RADARR_API_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#   QBIT_USER=admin
#   QBIT_PASS=adminadmin
#
# Author: CircuitForge
# Created: 2026-03-26
#
# Requirements:
#   - curl: API calls
#   - jq: JSON parsing
#
# License: GPL-3.0

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors / output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status() {
    local level="$1"; shift
    case "$level" in
        info)    echo -e "${BLUE}[INFO]${NC} $*" >&2 ;;
        success) echo -e "${GREEN}[OK]${NC}   $*" >&2 ;;
        warning) echo -e "${YELLOW}[WARN]${NC} $*" >&2 ;;
        error)   echo -e "${RED}[ERR]${NC}  $*" >&2 ;;
        debug)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${PURPLE}[DBG]${NC}  $*" >&2 ;;
        step)    echo -e "${CYAN}[-->]${NC}  $*" >&2 ;;
    esac
}

command_exists() { command -v "$1" &>/dev/null; }

# ---------------------------------------------------------------------------
# Defaults / config
# ---------------------------------------------------------------------------
CONFIG_FILE="${ARR_RECOVER_CONFIG:-${HOME}/.config/media-postprocessor/api-keys.conf}"

SONARR_URL="${SONARR_URL:-}"
RADARR_URL="${RADARR_URL:-}"
SONARR_API_KEY=""
RADARR_API_KEY=""
QBIT_INSTANCES=()
QBIT_USER="${QBIT_USER:-admin}"
QBIT_PASS="${QBIT_PASS:-adminadmin}"

DRY_RUN=false
VERBOSE=false
SEARCH_ONLY=false
FORCE_TYPE=""
BATCH_MODE=false
BATCH_FILE=""

# Load config if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <file_path> [--dry-run] [--verbose] [--search-only] [--sonarr|--radarr]"
    echo "       $0 --batch <file_list.txt> [options]"
    echo ""
    echo "  --dry-run     Show what would happen without making changes"
    echo "  --verbose     Show detailed API responses"
    echo "  --search-only Skip availability check, trigger search immediately"
    echo "  --sonarr      Force Sonarr (override path detection)"
    echo "  --radarr      Force Radarr (override path detection)"
    echo "  --batch FILE  Process multiple paths from a text file (one per line)"
    echo ""
    echo "  Config file: $CONFIG_FILE"
    exit 1
}

UNMONITOR_EPISODE_ID=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)             DRY_RUN=true ;;
        --verbose)             VERBOSE=true ;;
        --search-only)         SEARCH_ONLY=true ;;
        --sonarr)              FORCE_TYPE="sonarr" ;;
        --radarr)              FORCE_TYPE="radarr" ;;
        --batch)               BATCH_MODE=true; BATCH_FILE="$2"; shift ;;
        --unmonitor-episode)   UNMONITOR_EPISODE_ID="$2"; shift ;;
        -h|--help)             usage ;;
        *)                     POSITIONAL+=("$1") ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in curl jq; do
    if ! command_exists "$cmd"; then
        print_status error "Required command '$cmd' not found — install it first"
        exit 2
    fi
done

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
arr_get() {
    local base_url="$1"
    local api_key="$2"
    local endpoint="$3"
    local url="${base_url}/api/v3/${endpoint}"
    print_status debug "GET $url"
    curl -sf --max-time 15 \
        -H "X-Api-Key: $api_key" \
        -H "Accept: application/json" \
        "$url"
}

arr_post() {
    local base_url="$1"
    local api_key="$2"
    local endpoint="$3"
    local body="$4"
    local url="${base_url}/api/v3/${endpoint}"
    print_status debug "POST $url  body=$body"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_status warning "[DRY-RUN] Would POST $url with: $body"
        echo '{"id":0}'
        return 0
    fi
    curl -sf --max-time 15 \
        -X POST \
        -H "X-Api-Key: $api_key" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "$body" \
        "$url"
}

# Set monitored state for a single Sonarr episode
remonitor_episode() {
    local base_url="$1" api_key="$2" episode_id="$3" monitored="$4"
    print_status debug "Setting episode $episode_id monitored=$monitored"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_status warning "[DRY-RUN] Would set episode $episode_id monitored=$monitored"
        return 0
    fi
    # Sonarr v4: episode/monitor is PUT, not POST
    curl -sf --max-time 15 -X PUT \
        -H "X-Api-Key: $api_key" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"episodeIds\": [$episode_id], \"monitored\": $monitored}" \
        "${base_url}/api/v3/episode/monitor" >/dev/null
}

arr_delete() {
    local base_url="$1"
    local api_key="$2"
    local endpoint="$3"
    local url="${base_url}/api/v3/${endpoint}"
    print_status debug "DELETE $url"
    if [[ "$DRY_RUN" == "true" ]]; then
        print_status warning "[DRY-RUN] Would DELETE $url"
        return 0
    fi
    curl -sf --max-time 15 \
        -X DELETE \
        -H "X-Api-Key: $api_key" \
        "$url"
}

# ---------------------------------------------------------------------------
# Scored release selection
# ---------------------------------------------------------------------------
# Stage 1: episode/movie-specific search.
# Stage 2 (Sonarr only): season pack search — triggered when stage 1 finds nothing.
#
# Scoring tiers (lower = better):
#   1: x265 + >=10 seeds  -> sort size asc (smallest wins)
#   2: x265 + 4-9 seeds   -> sort seeds desc
#   3: non-x265 + >=10 seeds (non-remux) -> sort size asc
#   4: non-x265 + 4-9 seeds (non-remux)
#   5: <=3 seeds or remux -> last resort
# Usenet (null seeders) is treated as tier 3 equivalent (reliable, size-sorted).
# Returns 0 on success, 1 on failure — caller should fall back to EpisodeSearch.

# Shared scoring logic: reads a JSON array from stdin, outputs best candidate as JSON.
_score_releases() {
    jq -r '
        map(
            . as $r |
            ($r.title | test("x265|x\\.265|HEVC|H\\.265|h265|h\\.265"; "i")) as $x265 |
            ($r.seeders // 999) as $seeds |
            ($r.title | test("REMUX"; "i")) as $remux |
            (if   $seeds >= 10 and $x265                         then 1
             elif  $seeds >=  4 and $x265                         then 2
             elif  $seeds >= 10 and ($x265|not) and ($remux|not) then 3
             elif  $seeds >=  4 and ($x265|not) and ($remux|not) then 4
             else  5
             end) as $tier |
            $r + {_tier: $tier, _seeds: $seeds, _x265: $x265}
        ) |
        sort_by([
            ._tier,
            (if ._tier == 1 or ._tier == 3
             then (.size // 99999999999999)
             else  (._seeds * -1)
             end)
        ]) |
        first |
        {guid, indexerId, title, seeders, size: (.size // 0), _tier, _x265}
    '
}

# Set to "true" by pick_best_release when a season pack was selected.
# Caller uses this to delete all season episode files before the grab.
PICKED_SEASON_PACK=false

pick_best_release() {
    local arr_url="$1" arr_key="$2" arr_type="$3" media_id="$4"
    local series_id="${5:-}" season_number="${6:-}"

    # ---- Stage 1: episode / movie search ----
    print_status step "Searching indexers for best available release..."
    print_status info "(Live indexer query — may take up to 60s)"

    local releases_json
    if [[ "$arr_type" == "sonarr" ]]; then
        releases_json=$(curl -sf --max-time 90 \
            -H "X-Api-Key: $arr_key" -H "Accept: application/json" \
            "${arr_url}/api/v3/release?episodeId=${media_id}" 2>/dev/null || echo '[]')
    else
        releases_json=$(curl -sf --max-time 90 \
            -H "X-Api-Key: $arr_key" -H "Accept: application/json" \
            "${arr_url}/api/v3/release?movieId=${media_id}" 2>/dev/null || echo '[]')
    fi

    local total eligible eligible_count rejected_count
    total=$(echo "$releases_json" | jq 'length')
    eligible=$(echo "$releases_json" | jq '[.[] | select(.rejected != true)]')
    eligible_count=$(echo "$eligible" | jq 'length')
    rejected_count=$(( total - eligible_count ))
    print_status info "Episode search: $total result(s), $eligible_count eligible, $rejected_count rejected by quality profile"

    # ---- Stage 2: season pack fallback (Sonarr only) ----
    local is_season_pack=false
    if [[ "${eligible_count:-0}" -eq 0 ]] && \
       [[ "$arr_type" == "sonarr" ]] && \
       [[ -n "$series_id" ]] && [[ -n "$season_number" ]]; then

        local season_label
        season_label=$(printf 'S%02d' "$season_number")
        print_status info "No individual episode releases — searching for season pack ($season_label)..."

        local season_json season_eligible season_count
        season_json=$(curl -sf --max-time 90 \
            -H "X-Api-Key: $arr_key" -H "Accept: application/json" \
            "${arr_url}/api/v3/release?seriesId=${series_id}&seasonNumber=${season_number}" \
            2>/dev/null || echo '[]')
        season_eligible=$(echo "$season_json" | jq '[.[] | select(.rejected != true)]')
        season_count=$(echo "$season_eligible" | jq 'length')
        local season_rejected=$(( $(echo "$season_json" | jq 'length') - season_count ))
        print_status info "Season pack search: $(echo "$season_json" | jq 'length') result(s), $season_count eligible, $season_rejected rejected"

        if [[ "$season_count" -gt 0 ]]; then
            eligible="$season_eligible"
            eligible_count="$season_count"
            is_season_pack=true
            PICKED_SEASON_PACK=true
        fi
    fi

    if [[ "${eligible_count:-0}" -eq 0 ]]; then
        print_status warning "No eligible releases found (episode or season pack) — falling back to automatic search"
        return 1
    fi

    local best
    best=$(echo "$eligible" | _score_releases)

    if [[ -z "$best" ]] || [[ "$best" == "null" ]]; then
        print_status warning "Release scoring produced no result"
        return 1
    fi

    local title seeds size_gb tier
    title=$(echo "$best" | jq -r '.title')
    seeds=$(echo "$best" | jq -r 'if .seeders == 999 then "Usenet" else (.seeders // "?") | tostring end')
    size_gb=$(echo "$best" | jq -r '(.size / 1073741824 * 100 | round) / 100 | tostring + " GB"')
    tier=$(echo "$best" | jq -r '._tier')

    local tier_label
    case "$tier" in
        1) tier_label="x265 + >=10 seeds (size-optimised)" ;;
        2) tier_label="x265 + 4-9 seeds" ;;
        3) tier_label=">=10 seeds, size-optimised" ;;
        4) tier_label="4-9 seeds" ;;
        5) tier_label="fallback (low seeds / remux)" ;;
    esac

    if [[ "$is_season_pack" == "true" ]]; then
        print_status warning "Season pack selected — all episodes in this season will download"
        print_status warning "Other corrupted episodes in the same season are covered by this grab"
    fi
    print_status success "Selected:"
    print_status info "  $title"
    print_status info "  Seeds: $seeds | Size: $size_gb | Tier: $tier_label"

    if [[ "$DRY_RUN" == "true" ]]; then
        print_status warning "[DRY-RUN] Would grab the above release"
        return 0
    fi

    local guid indexer_id
    guid=$(echo "$best" | jq -r '.guid')
    indexer_id=$(echo "$best" | jq -r '.indexerId')

    print_status step "Grabbing selected release..."
    local grab_resp
    grab_resp=$(curl -sf --max-time 30 \
        -X POST \
        -H "X-Api-Key: $arr_key" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"guid\": \"$guid\", \"indexerId\": $indexer_id}" \
        "${arr_url}/api/v3/release" 2>/dev/null || echo '{}')

    if echo "$grab_resp" | jq -e '.rejected == true' &>/dev/null; then
        local reasons
        reasons=$(echo "$grab_resp" | jq -r '[.rejections[]?.reason // empty] | join(", ")')
        print_status warning "Grab rejected: ${reasons:-unknown reason}"
        return 1
    fi

    print_status success "Release grabbed — download queued in ${arr_type^}"
    return 0
}

# Log into a qBittorrent instance.
# Returns cookie jar path, "bypass" if auth is not required, or empty on failure.
qbit_login() {
    local base_url="$1"

    # Try unauthenticated first — works when local bypass is enabled
    local bypass_test
    bypass_test=$(curl -sf --max-time 10 \
        "${base_url}/api/v2/app/version" 2>/dev/null || echo "")
    if [[ -n "$bypass_test" ]]; then
        print_status debug "  qBit auth bypass active at $base_url"
        echo "bypass"
        return 0
    fi

    # Fall back to username/password login
    local jar
    jar=$(mktemp /tmp/qbit_cookie.XXXXXX)
    local result
    result=$(curl -sf --max-time 10 \
        -c "$jar" \
        --data-urlencode "username=$QBIT_USER" \
        --data-urlencode "password=$QBIT_PASS" \
        "${base_url}/api/v2/auth/login" 2>/dev/null || echo "Fails.")
    if [[ "$result" == "Ok." ]]; then
        echo "$jar"
    else
        rm -f "$jar"
        echo ""
    fi
}

# Check if a torrent hash exists in a qBit instance; returns JSON or empty.
# cookie_jar may be a file path or the string "bypass" (no auth needed).
qbit_check_hash() {
    local base_url="$1"
    local cookie_jar="$2"
    local hash="$3"
    if [[ "$cookie_jar" == "bypass" ]]; then
        curl -sf --max-time 10 \
            "${base_url}/api/v2/torrents/info?hashes=${hash}" 2>/dev/null || echo "[]"
    else
        curl -sf --max-time 10 \
            -b "$cookie_jar" \
            "${base_url}/api/v2/torrents/info?hashes=${hash}" 2>/dev/null || echo "[]"
    fi
}

# ---------------------------------------------------------------------------
# Core recovery logic for a single file
# ---------------------------------------------------------------------------
recover_file() {
    local filepath="$1"

    echo "" >&2
    print_status step "============================================================"
    print_status step "File: $(basename "$filepath")"
    print_status step "Path: $filepath"
    print_status step "============================================================"

    # ------------------------------------------------------------------
    # Phase 1: Identify Sonarr vs Radarr
    # ------------------------------------------------------------------
    local arr_type
    if [[ -n "$FORCE_TYPE" ]]; then
        arr_type="$FORCE_TYPE"
        print_status info "Type forced: $arr_type"
    elif [[ "$filepath" == *"/Series/"* ]] || [[ "$filepath" == *"/TV Shows/"* ]] || [[ "$filepath" == *"/TV/"* ]]; then
        arr_type="sonarr"
    elif [[ "$filepath" == *"/Movies/"* ]] || [[ "$filepath" == *"/Movie/"* ]]; then
        arr_type="radarr"
    else
        print_status error "Cannot determine type from path — use --sonarr or --radarr"
        return 1
    fi

    local arr_url arr_key
    if [[ "$arr_type" == "sonarr" ]]; then
        arr_url="$SONARR_URL"; arr_key="$SONARR_API_KEY"
        print_status info "Type: TV Show → Sonarr ($arr_url)"
    else
        arr_url="$RADARR_URL"; arr_key="$RADARR_API_KEY"
        print_status info "Type: Movie → Radarr ($arr_url)"
    fi

    if [[ -z "$arr_key" ]]; then
        print_status error "API key not configured for $arr_type. Set in $CONFIG_FILE"
        return 1
    fi

    # ------------------------------------------------------------------
    # Phase 2: Parse file path via *arr API
    # ------------------------------------------------------------------
    print_status step "Parsing file path via ${arr_type^} API..."

    # *arr parse API only works reliably with ?title= (the filename stem).
    # The ?path= parameter silently returns empty even for tracked files.
    local filename stem encoded_title
    filename=$(basename "$filepath")
    stem="${filename%.*}"
    encoded_title=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$stem" 2>/dev/null \
        || printf '%s' "$stem" | sed 's/ /+/g')

    local parse_response
    if ! parse_response=$(arr_get "$arr_url" "$arr_key" "parse?title=${encoded_title}"); then
        print_status error "Parse API call failed — check URL and API key"
        print_status info "Endpoint: ${arr_url}/api/v3/parse?title=${stem}"
        return 1
    fi

    print_status debug "Parse response: $parse_response"

    local media_id file_id media_title
    if [[ "$arr_type" == "sonarr" ]]; then
        media_id=$(echo "$parse_response" | jq -r '.episodes[0].id | select(. != null and . != 0) // empty')
        file_id=$(echo "$parse_response" | jq -r '.episodes[0].episodeFileId | select(. != null and . != 0) // empty')
        local series_id season_number episode_monitored
        series_id=$(echo "$parse_response" | jq -r '.series.id // empty')
        season_number=$(echo "$parse_response" | jq -r '.episodes[0].seasonNumber // empty')
        episode_monitored=$(echo "$parse_response" | jq -r '.episodes[0].monitored | tostring')
        media_title=$(echo "$parse_response" | jq -r '
            (.series.title // "Unknown") + " " +
            (.episodes[0].seasonNumber | tostring | "S" + if length == 1 then "0"+. else . end) +
            (.episodes[0].episodeNumber | tostring | "E" + if length == 1 then "0"+. else . end)
        ' 2>/dev/null || echo "Unknown")

        if [[ -z "$media_id" ]]; then
            print_status error "Episode not found in Sonarr — file may not be tracked"
            print_status info "Tip: check that Sonarr's root folder covers $filepath"
            return 1
        fi
        print_status success "Found: $media_title (episodeId=$media_id, fileId=${file_id:-none}, seriesId=$series_id)"
        if [[ "$episode_monitored" == "false" ]]; then
            print_status warning "Episode is unmonitored — will temporarily re-monitor for replacement, then unmonitor again"
        fi
    else
        media_id=$(echo "$parse_response" | jq -r '.movie.id | select(. != null and . != 0) // empty')
        file_id=$(echo "$parse_response" | jq -r '.movie.movieFileId | select(. != null and . != 0) // empty')
        media_title=$(echo "$parse_response" | jq -r '.movie.title // "Unknown"')

        if [[ -z "$media_id" ]]; then
            print_status error "Movie not found in Radarr — file may not be tracked"
            return 1
        fi
        print_status success "Found: $media_title (movieId=$media_id, fileId=${file_id:-none})"
    fi

    # ------------------------------------------------------------------
    # Phase 3: Check download queue for a pending/completed import
    # ------------------------------------------------------------------
    if [[ "$SEARCH_ONLY" != "true" ]]; then
        print_status step "Checking download queue for available import..."

        local queue_response queue_count
        if [[ "$arr_type" == "sonarr" ]]; then
            queue_response=$(arr_get "$arr_url" "$arr_key" "queue?seriesId=${series_id}&includeEpisode=true&pageSize=50" 2>/dev/null || echo '{"records":[]}')
            queue_count=$(echo "$queue_response" | jq '[.records[] | select(.episode.id == '"$media_id"')] | length')
        else
            queue_response=$(arr_get "$arr_url" "$arr_key" "queue?movieId=${media_id}&pageSize=50" 2>/dev/null || echo '{"records":[]}')
            queue_count=$(echo "$queue_response" | jq '[.records[]] | length')
        fi

        print_status debug "Queue entries matching: $queue_count"

        if [[ "${queue_count:-0}" -gt 0 ]]; then
            local queue_status
            queue_status=$(echo "$queue_response" | jq -r '.records[0].status // "unknown"')
            local tracked_state
            tracked_state=$(echo "$queue_response" | jq -r '.records[0].trackedDownloadState // "unknown"')
            print_status success "Found in queue (status=$queue_status, trackedState=$tracked_state)"

            if [[ "$queue_status" == "completed" ]] || [[ "$tracked_state" == "importPending" ]]; then
                print_status step "Original download is ready — triggering import scan..."
                if [[ "$arr_type" == "sonarr" ]]; then
                    arr_post "$arr_url" "$arr_key" "command" \
                        "{\"name\": \"DownloadedEpisodesScan\", \"seriesId\": $series_id}" >/dev/null
                else
                    arr_post "$arr_url" "$arr_key" "command" \
                        "{\"name\": \"DownloadedMoviesScan\"}" >/dev/null
                fi
                print_status success "Import scan triggered — check ${arr_type^} activity feed"
                return 0
            elif [[ "$queue_status" == "downloading" ]] || [[ "$tracked_state" == "downloading" ]]; then
                print_status success "Download already in progress — watching for completion..."
                local should_unmonitor=false
                [[ "$arr_type" == "sonarr" ]] && [[ "${episode_monitored:-true}" == "false" ]] && should_unmonitor=true
                echo "__WATCH__|${arr_type}|${media_id}|${should_unmonitor}|${media_title}"
                return 0
            else
                print_status info "Item in queue but not yet ready (status=$queue_status) — will check history"
            fi
        else
            print_status info "Not found in download queue"
        fi

        # ------------------------------------------------------------------
        # Phase 4: Check history → find torrent hash → check qBittorrent
        # ------------------------------------------------------------------
        print_status step "Checking history for original torrent hash..."

        local history_response history_hashes
        if [[ "$arr_type" == "sonarr" ]]; then
            history_response=$(arr_get "$arr_url" "$arr_key" "history?episodeId=${media_id}&eventType=grabbed&pageSize=10" 2>/dev/null || echo '{"records":[]}')
        else
            history_response=$(arr_get "$arr_url" "$arr_key" "history?movieId=${media_id}&eventType=grabbed&pageSize=10" 2>/dev/null || echo '{"records":[]}')
        fi

        # Extract torrent hashes from history, most recent first
        readarray -t history_hashes < <(echo "$history_response" | jq -r '.records[].downloadId // empty' | tr '[:upper:]' '[:lower:]' | grep -v '^$' || true)

        # Name-based fallback: when there's no grab history, search qBit by series + season.
        # Builds a keyword from the series folder name and the season number extracted from
        # the "Season N" parent directory. Both series title and torrent name are normalised
        # (punctuation → spaces) before matching so "Show.S03.x264" and "Show S03 x264" both hit.
        if [[ ${#history_hashes[@]} -eq 0 ]]; then
            local series_dir_kw season_tag series_dir_keyword
            series_dir_kw=$(basename "$(dirname "$(dirname "$filepath")")" \
                | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]/ /g' | awk '{print $1,$2,$3}')
            local season_num
            season_num=$(basename "$(dirname "$filepath")" | grep -oP '\d+' | head -1)
            season_tag=$(printf 's%02d' "${season_num:-0}")
            series_dir_keyword="${series_dir_kw} ${season_tag}"
            print_status info "No grab history — trying name-based qBittorrent search (keyword: '$series_dir_keyword')..."

            for qbit_url in "${QBIT_INSTANCES[@]}"; do
                local cj all_torrents nm_matches nm_count
                cj=$(qbit_login "$qbit_url")
                [[ -z "$cj" ]] && continue

                if [[ "$cj" == "bypass" ]]; then
                    all_torrents=$(curl -sf --max-time 15 "${qbit_url}/api/v2/torrents/info" 2>/dev/null || echo '[]')
                else
                    all_torrents=$(curl -sf --max-time 15 -b "$cj" "${qbit_url}/api/v2/torrents/info" 2>/dev/null || echo '[]')
                    rm -f "$cj"
                fi

                # Normalise torrent names: punctuation → spaces, lowercase, then substring match.
                # This handles both "Show.S03.x264" and "Show S03 x264" styles.
                nm_matches=$(echo "$all_torrents" | jq --arg kw "$series_dir_keyword" \
                    '[.[] | select(.name | ascii_downcase | gsub("[^a-z0-9]"; " ") | contains($kw))]' \
                    2>/dev/null || echo '[]')
                nm_count=$(echo "$nm_matches" | jq 'length')

                if [[ "${nm_count:-0}" -gt 0 ]]; then
                    local nm_name nm_hash nm_state
                    nm_name=$(echo "$nm_matches" | jq -r '.[0].name')
                    nm_hash=$(echo "$nm_matches" | jq -r '.[0].hash')
                    nm_state=$(echo "$nm_matches" | jq -r '.[0].state // "unknown"')
                    print_status success "Found by name in qBit ($qbit_url): $nm_name (state=$nm_state)"
                    history_hashes=("$nm_hash")
                    break
                fi
            done

            [[ ${#history_hashes[@]} -eq 0 ]] && print_status info "Not found in qBittorrent by name either"
        fi

        if [[ ${#history_hashes[@]} -gt 0 ]]; then
            print_status info "Checking qBittorrent for ${#history_hashes[@]} candidate hash(es)..."

            local found_in_qbit=false
            local found_qbit_url="" found_hash="" found_save_path="" found_torrent_name=""
            local cookie_jar=""

            for qbit_url in "${QBIT_INSTANCES[@]}"; do
                print_status debug "Checking qBit instance: $qbit_url"
                cookie_jar=$(qbit_login "$qbit_url")
                if [[ -z "$cookie_jar" ]]; then
                    print_status debug "  Login failed or not reachable: $qbit_url"
                    continue
                fi

                for hash in "${history_hashes[@]}"; do
                    local torrent_info torrent_count
                    torrent_info=$(qbit_check_hash "$qbit_url" "$cookie_jar" "$hash")
                    torrent_count=$(echo "$torrent_info" | jq 'length' 2>/dev/null || echo 0)

                    if [[ "${torrent_count:-0}" -gt 0 ]]; then
                        local torrent_state torrent_name
                        torrent_state=$(echo "$torrent_info" | jq -r '.[0].state // "unknown"')
                        torrent_name=$(echo "$torrent_info" | jq -r '.[0].name // "unknown"')
                        found_save_path=$(echo "$torrent_info" | jq -r '.[0].save_path // empty')
                        print_status success "Found in qBittorrent! ($qbit_url)"
                        print_status info "  Torrent: $torrent_name"
                        print_status info "  State:   $torrent_state"
                        print_status info "  Path:    ${found_save_path:-unknown}"
                        found_in_qbit=true
                        found_qbit_url="$qbit_url"
                        found_hash="$hash"
                        found_torrent_name="$torrent_name"
                        break 2
                    fi
                done

                [[ "$cookie_jar" != "bypass" ]] && rm -f "$cookie_jar"
            done

            if [[ "$found_in_qbit" == "true" ]]; then
                print_status step "Original torrent still available — deleting corrupted file record..."

                # Re-monitor so Sonarr will accept the import (async — watcher will re-unmonitor)
                if [[ "$arr_type" == "sonarr" ]] && [[ "${episode_monitored:-true}" == "false" ]]; then
                    remonitor_episode "$arr_url" "$arr_key" "$media_id" "true"
                fi

                if [[ -n "$file_id" ]]; then
                    if [[ "$arr_type" == "sonarr" ]]; then
                        arr_delete "$arr_url" "$arr_key" "episodefile/$file_id"
                    else
                        arr_delete "$arr_url" "$arr_key" "moviefile/$file_id"
                    fi
                    print_status success "File record deleted from ${arr_type^}"
                else
                    print_status warning "No file ID found — skipping delete (file may already be untracked)"
                fi

                # Use path-based scan — works even when the qBit instance is not registered
                # as a download client in Sonarr (hash-based scan requires registration).
                local content_path="${found_save_path%/}/${found_torrent_name}"
                print_status step "Triggering path-based import scan: $content_path"
                if [[ "$arr_type" == "sonarr" ]]; then
                    arr_post "$arr_url" "$arr_key" "command" \
                        "{\"name\": \"DownloadedEpisodesScan\", \"path\": \"$content_path\"}" >/dev/null
                else
                    arr_post "$arr_url" "$arr_key" "command" \
                        "{\"name\": \"DownloadedMoviesScan\", \"path\": \"$content_path\"}" >/dev/null
                fi
                print_status success "Import scan triggered — watching for completion..."

                # Signal server to watch for import and auto-unmonitor
                local should_unmonitor=false
                [[ "$arr_type" == "sonarr" ]] && [[ "${episode_monitored:-true}" == "false" ]] && should_unmonitor=true
                echo "__WATCH__|${arr_type}|${media_id}|${should_unmonitor}|${media_title}"

                return 0
            else
                print_status info "Original torrent not found in any qBittorrent instance"
            fi
        fi
    fi

    # ------------------------------------------------------------------
    # Phase 5: Fallback — delete file record and trigger automatic search
    # ------------------------------------------------------------------
    print_status step "Original not available — deleting corrupted file record and triggering search..."

    # Must be monitored for Sonarr to accept the downloaded replacement
    if [[ "$arr_type" == "sonarr" ]] && [[ "${episode_monitored:-true}" == "false" ]]; then
        remonitor_episode "$arr_url" "$arr_key" "$media_id" "true"
    fi

    if [[ -n "$file_id" ]]; then
        if [[ "$arr_type" == "sonarr" ]]; then
            arr_delete "$arr_url" "$arr_key" "episodefile/$file_id"
        else
            arr_delete "$arr_url" "$arr_key" "moviefile/$file_id"
        fi
        print_status success "File record deleted from ${arr_type^}"
    else
        print_status warning "No file ID to delete — item may already be untracked"
    fi

    PICKED_SEASON_PACK=false
    if ! pick_best_release "$arr_url" "$arr_key" "$arr_type" "$media_id" "${series_id:-}" "${season_number:-}"; then
        print_status warning "Scored search failed — falling back to automatic search..."
        local search_result
        if [[ "$arr_type" == "sonarr" ]]; then
            search_result=$(arr_post "$arr_url" "$arr_key" "command" \
                "{\"name\": \"EpisodeSearch\", \"episodeIds\": [$media_id]}")
        else
            search_result=$(arr_post "$arr_url" "$arr_key" "command" \
                "{\"name\": \"MoviesSearch\", \"movieIds\": [$media_id]}")
        fi
        local cmd_id
        cmd_id=$(echo "$search_result" | jq -r '.id // "?"')
        print_status success "Automatic search triggered (command ID: $cmd_id)"
    fi

    # Season pack grabbed — delete all existing episode file records for this season
    # so Sonarr treats every slot as empty and imports all files from the download.
    # Without this, Sonarr only replaces files that score higher in the quality profile.
    if [[ "$PICKED_SEASON_PACK" == "true" ]] && [[ "$arr_type" == "sonarr" ]] \
       && [[ -n "$series_id" ]] && [[ -n "$season_number" ]]; then
        print_status step "Season pack grabbed — clearing all episode file records for S$(printf '%02d' "$season_number")..."

        # Fetch all episodes in this season that have a file
        local season_episodes
        season_episodes=$(curl -sf --max-time 30 \
            -H "X-Api-Key: $arr_key" \
            "${arr_url}/api/v3/episode?seriesId=${series_id}&seasonNumber=${season_number}" \
            2>/dev/null || echo '[]')

        local cleared=0
        while IFS= read -r ep_file_id; do
            [[ -z "$ep_file_id" || "$ep_file_id" == "null" || "$ep_file_id" == "0" ]] && continue
            [[ "$ep_file_id" == "$file_id" ]] && continue  # already deleted above
            arr_delete "$arr_url" "$arr_key" "episodefile/$ep_file_id" && (( cleared++ )) || true
        done < <(echo "$season_episodes" | jq -r '.[] | select(.hasFile == true) | .episodeFileId // empty')

        print_status success "Cleared $cleared additional episode file record(s) — season will be fully replaced"
    fi

    # Signal server to poll for import completion and auto-unmonitor when done
    local should_unmonitor=false
    [[ "$arr_type" == "sonarr" ]] && [[ "${episode_monitored:-true}" == "false" ]] && should_unmonitor=true
    echo "__WATCH__|${arr_type}|${media_id}|${should_unmonitor}|${media_title}"

    return 0
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Manual unmonitor helper (run after replacement has downloaded)
# ---------------------------------------------------------------------------
if [[ -n "$UNMONITOR_EPISODE_ID" ]]; then
    print_status info "=== recovarr.sh: unmonitor episode $UNMONITOR_EPISODE_ID ==="
    if [[ -z "$SONARR_API_KEY" ]]; then
        print_status error "SONARR_API_KEY not configured"
        exit 1
    fi
    remonitor_episode "$SONARR_URL" "$SONARR_API_KEY" "$UNMONITOR_EPISODE_ID" "false"
    print_status success "Episode $UNMONITOR_EPISODE_ID unmonitored — curation restored"
    exit 0
fi

# ---------------------------------------------------------------------------
# Recovery wrapper: catches failures and prints manual fallback instructions
# ---------------------------------------------------------------------------
run_recovery() {
    local filepath="$1"
    if recover_file "$filepath"; then
        return 0
    fi

    echo "" >&2
    print_status error "======================================================"
    print_status error "RECOVERY FAILED — manual intervention required"
    print_status error "======================================================"
    print_status error "File: $filepath"
    echo "" >&2
    print_status info "Manual steps:"
    print_status info "  1. Open Sonarr/Radarr and find the episode/movie"
    print_status info "  2. If the corrupted file is still tracked:"
    print_status info "     - Go to the episode → click the file icon → Delete"
    print_status info "  3. Re-enable monitoring on the episode (temporarily)"
    print_status info "  4. Click the search icon to trigger a manual search"
    print_status info "  5. Once replacement downloads, unmonitor the episode again"
    echo "" >&2
    print_status info "Or re-run with verbose output for more detail:"
    print_status info "  $0 --verbose \"$filepath\""
    return 1
}

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
if [[ "$BATCH_MODE" == "true" ]]; then
    if [[ -z "$BATCH_FILE" ]] || [[ ! -f "$BATCH_FILE" ]]; then
        print_status error "Batch file not found: $BATCH_FILE"
        exit 1
    fi
    print_status info "=== recovarr.sh batch mode: $BATCH_FILE ==="
    [[ "$DRY_RUN" == "true" ]] && print_status warning "DRY-RUN mode — no changes will be made"

    PASS=0; FAIL=0
    FAILED_FILES=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if run_recovery "$line"; then
            ((PASS++)) || true
        else
            ((FAIL++)) || true
            FAILED_FILES+=("$line")
        fi
    done < "$BATCH_FILE"

    echo "" >&2
    print_status info "=== Batch complete: $PASS succeeded, $FAIL failed ==="
    if [[ $FAIL -gt 0 ]]; then
        echo "" >&2
        print_status warning "Files requiring manual attention:"
        for f in "${FAILED_FILES[@]}"; do
            print_status warning "  $f"
        done
        exit 1
    fi
else
    if [[ ${#POSITIONAL[@]} -eq 0 ]]; then
        usage
    fi
    print_status info "=== recovarr.sh ==="
    [[ "$DRY_RUN" == "true" ]] && print_status warning "DRY-RUN mode — no changes will be made"
    run_recovery "${POSITIONAL[0]}"
fi
