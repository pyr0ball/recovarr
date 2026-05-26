#!/usr/bin/env node
//
// server.js - Recovarr web UI backend
// Relative Path: ./projects/recovarr/server.js
//
// Purpose: Minimal HTTP server (no npm deps) that queues file paths for
// recovarr.sh, streams live output via SSE, polls Sonarr/Radarr for
// import completion, and auto-unmonitors when done.
//
// License: GPL-3.0

'use strict';

const http = require('http');
const https = require('https');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const PORT = parseInt(process.env.PORT || '8602', 10);
const SCRIPT = process.env.ARR_RECOVER_SCRIPT
    || path.resolve(__dirname, '../../scripts/recovarr.sh');
const PUBLIC_DIR = path.join(__dirname, 'public');
const CONFIG_PATH = process.env.ARR_RECOVER_CONFIG
    || path.join(os.homedir(), '.config/media-postprocessor/api-keys.conf');
const LOG_PATH = process.env.ARR_RECOVER_LOG
    || path.join(os.homedir(), '.local/share/recovarr/jobs.log');
const QUEUE_PATH = process.env.ARR_RECOVER_QUEUE
    || path.join(os.homedir(), '.local/share/recovarr/pending-queue.json');
const LOG_MAX_ENTRIES = 200;

const POLL_INTERVAL_MS = 30_000;   // check Sonarr/Radarr every 30s
const WATCH_TIMEOUT_MS = 24 * 60 * 60 * 1000; // give up after 24h

function loadConfig() {
    try {
        const lines = fs.readFileSync(CONFIG_PATH, 'utf8').split('\n');
        const cfg = {};
        for (const line of lines) {
            const m = line.match(/^([A-Z_]+)=(.+)$/);
            if (m) cfg[m[1]] = m[2].trim();
        }
        return cfg;
    } catch {
        console.warn(`Config not found at ${CONFIG_PATH} — watcher disabled`);
        return {};
    }
}

let cfg = loadConfig();

// ---------------------------------------------------------------------------
// Pending queue — survive restarts by persisting queued/watching jobs
// ---------------------------------------------------------------------------
function savePendingQueue() {
    try {
        const dir = path.dirname(QUEUE_PATH);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        const pending = [...jobs.values()]
            .filter(j => !j.archived && (j.status === 'queued' || j.status === 'running' || j.status === 'watching'))
            .map(j => ({ id: j.id, filepath: j.filepath, createdAt: j.createdAt }));
        fs.writeFileSync(QUEUE_PATH, JSON.stringify(pending, null, 2));
    } catch (err) {
        console.warn('Failed to save pending queue:', err.message);
    }
}

function loadPendingQueue() {
    try {
        if (!fs.existsSync(QUEUE_PATH)) return;
        const pending = JSON.parse(fs.readFileSync(QUEUE_PATH, 'utf8'));
        if (!Array.isArray(pending) || pending.length === 0) return;
        let restored = 0;
        for (const entry of pending) {
            if (!entry.filepath || jobs.has(entry.id)) continue;
            // Re-create as queued — the script will re-run full recovery logic
            const job = {
                id:         entry.id,
                filepath:   entry.filepath,
                status:     'queued',
                lines:      [{ text: '[recovarr] Re-queued after server restart', ts: Date.now() }],
                exitCode:   null,
                createdAt:  entry.createdAt || Date.now(),
                watchData:  null,
                sseClients: new Set(),
            };
            jobs.set(job.id, job);
            restored++;
        }
        if (restored) console.log(`Restored ${restored} pending job(s) from queue`);
    } catch (err) {
        console.warn('Failed to load pending queue:', err.message);
    }
}

// ---------------------------------------------------------------------------
// Job log — persist finished jobs to ~/.local/share/recovarr/jobs.log
// ---------------------------------------------------------------------------
function appendJobLog(job) {
    try {
        const dir = path.dirname(LOG_PATH);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        const record = JSON.stringify({
            id:         job.id,
            filepath:   job.filepath,
            status:     job.status,
            exitCode:   job.exitCode,
            createdAt:  job.createdAt,
            finishedAt: Date.now(),
            watchData:  job.watchData,
            lines:      job.lines,
        });
        fs.appendFileSync(LOG_PATH, record + '\n');
    } catch (err) {
        console.warn('Failed to write job log:', err.message);
    }
}

function loadJobLog() {
    try {
        if (!fs.existsSync(LOG_PATH)) return;
        const raw = fs.readFileSync(LOG_PATH, 'utf8').split('\n').filter(Boolean);
        const recent = raw.slice(-LOG_MAX_ENTRIES);
        let loaded = 0;
        for (const line of recent) {
            try {
                const r = JSON.parse(line);
                if (!r.id || jobs.has(r.id)) continue;
                jobs.set(r.id, { ...r, archived: true, sseClients: new Set() });
                loaded++;
            } catch { /* skip malformed */ }
        }
        if (loaded) console.log(`Loaded ${loaded} archived job(s) from log`);
    } catch (err) {
        console.warn('Failed to read job log:', err.message);
    }
}

function removeFromLog(id) {
    try {
        if (!fs.existsSync(LOG_PATH)) return;
        const lines = fs.readFileSync(LOG_PATH, 'utf8').split('\n').filter(Boolean);
        const filtered = lines.filter(line => {
            try { return JSON.parse(line).id !== id; }
            catch { return true; }
        });
        fs.writeFileSync(LOG_PATH, filtered.length ? filtered.join('\n') + '\n' : '');
    } catch (err) {
        console.warn('Failed to update job log:', err.message);
    }
}

// ---------------------------------------------------------------------------
// Job model
// ---------------------------------------------------------------------------
// status: queued | running | watching | restored | timeout | done | failed
const jobs = new Map();

function createJob(filepath) {
    const id = crypto.randomBytes(6).toString('hex');
    const job = {
        id,
        filepath,
        status: 'queued',
        lines: [],
        exitCode: null,
        createdAt: Date.now(),
        watchData: null,   // { type, mediaId, unmonitor, title } — set from __WATCH__ line
        sseClients: new Set(),
    };
    jobs.set(id, job);
    savePendingQueue();
    return job;
}

function pushLine(job, line) {
    job.lines.push(line);
    for (const res of job.sseClients) {
        res.write(`data: ${JSON.stringify(line)}\n\n`);
    }
}

function sendEvent(job, event, data) {
    for (const res of job.sseClients) {
        res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
    }
}

function finishJob(job, exitCode) {
    job.exitCode = exitCode;
    if (job.status !== 'restored' && job.status !== 'timeout') {
        job.status = exitCode === 0 ? 'done' : 'failed';
    }
    sendEvent(job, 'done', { exitCode, status: job.status, watchData: job.watchData });
    for (const res of job.sseClients) res.end();
    job.sseClients.clear();
    appendJobLog(job);
    savePendingQueue(); // remove from pending now that it's finished
}

// ---------------------------------------------------------------------------
// Arr API helpers (used by the watcher — plain Node http, no npm)
// ---------------------------------------------------------------------------
function arrRequest(method, baseUrl, apiKey, endpoint, body) {
    return new Promise((resolve, reject) => {
        const url = new URL(`${baseUrl}/api/v3/${endpoint}`);
        const isHttps = url.protocol === 'https:';
        const lib = isHttps ? https : http;

        const payload = body ? JSON.stringify(body) : null;
        const options = {
            hostname: url.hostname,
            port: url.port || (isHttps ? 443 : 80),
            path: url.pathname + (url.search || ''),
            method,
            headers: {
                'X-Api-Key': apiKey,
                'Accept': 'application/json',
                ...(payload ? { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } : {}),
            },
            timeout: 15_000,
        };

        const req = lib.request(options, (res) => {
            const chunks = [];
            res.on('data', c => chunks.push(c));
            res.on('end', () => {
                try { resolve(JSON.parse(Buffer.concat(chunks).toString())); }
                catch { resolve(null); }
            });
        });
        req.on('error', reject);
        req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
        if (payload) req.write(payload);
        req.end();
    });
}

const arrGet  = (url, key, ep)       => arrRequest('GET',  url, key, ep);
const arrPost = (url, key, ep, body) => arrRequest('POST', url, key, ep, body);
const arrPut  = (url, key, ep, body) => arrRequest('PUT',  url, key, ep, body);

// ---------------------------------------------------------------------------
// Watcher — polls for import completion, then unmonitors
// ---------------------------------------------------------------------------
function startWatcher(job) {
    cfg = loadConfig(); // re-read in case config was updated
    const { type, mediaId, unmonitor } = job.watchData;

    if (!mediaId || mediaId === 0 || !Number.isInteger(mediaId)) {
        pushLine(job, `[WATCH] Invalid mediaId (${mediaId}) — cannot watch`);
        finishJob(job, 1);
        return;
    }

    const apiUrl = type === 'sonarr' ? cfg.SONARR_URL : cfg.RADARR_URL;
    const apiKey = type === 'sonarr' ? cfg.SONARR_API_KEY : cfg.RADARR_API_KEY;

    if (!apiUrl || !apiKey) {
        pushLine(job, '[WATCH] API credentials not found in config — cannot auto-watch');
        finishJob(job, 1);
        return;
    }

    const endpoint = type === 'sonarr' ? `episode/${mediaId}` : `movie/${mediaId}`;
    let elapsed = 0;
    pushLine(job, `[WATCH] Polling ${type} every 30s — waiting for download + import to complete`);

    job.watcherTimer = setInterval(async () => {
        elapsed += POLL_INTERVAL_MS;

        if (elapsed > WATCH_TIMEOUT_MS) {
            clearInterval(job.watcherTimer);
            job.status = 'timeout';
            pushLine(job, '[WATCH] Timed out after 24h — no import detected');
            pushLine(job, '[WATCH] Check Sonarr/Radarr activity for errors');
            finishJob(job, 1);
            return;
        }

        try {
            const media = await arrGet(apiUrl, apiKey, endpoint);

            if (media && media.hasFile) {
                clearInterval(job.watcherTimer);
                pushLine(job, '[WATCH] Import confirmed');

                if (unmonitor && type === 'sonarr') {
                    await arrPut(apiUrl, apiKey, 'episode/monitor',
                        { episodeIds: [mediaId], monitored: false });
                    pushLine(job, '[WATCH] Episode unmonitored — curation preserved');
                } else if (unmonitor && type === 'radarr') {
                    const movie = await arrGet(apiUrl, apiKey, `movie/${mediaId}`);
                    if (movie) {
                        movie.monitored = false;
                        await arrPut(apiUrl, apiKey, `movie/${mediaId}`, movie);
                        pushLine(job, '[WATCH] Movie unmonitored — curation preserved');
                    }
                }

                job.status = 'restored';
                finishJob(job, 0);
            } else {
                const mins = Math.floor(elapsed / 60_000);
                pushLine(job, `[WATCH] Still waiting for download... (${mins}m elapsed)`);
                sendEvent(job, 'status', { status: 'watching', elapsed });
            }
        } catch (err) {
            pushLine(job, `[WATCH] Poll error: ${err.message}`);
        }
    }, POLL_INTERVAL_MS);
}

// ---------------------------------------------------------------------------
// Script runner
// ---------------------------------------------------------------------------
function runJob(job) {
    job.status = 'running';

    const proc = spawn('bash', [SCRIPT, job.filepath], {
        stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...process.env, TERM: 'dumb' }, // suppress color codes
    });

    const handleData = (data) => {
        const raw = data.toString();
        // Strip ANSI codes
        const clean = raw.replace(/\x1b\[[0-9;]*m/g, '');
        for (const line of clean.split('\n')) {
            if (!line.trim()) continue;

            // Parse watch signal from script
            if (line.startsWith('__WATCH__|')) {
                const parts = line.split('|');
                // __WATCH__|type|mediaId|unmonitor|title
                job.watchData = {
                    type:      parts[1],
                    mediaId:   parseInt(parts[2], 10),
                    unmonitor: parts[3] === 'true',
                    title:     parts.slice(4).join('|'),
                };
                continue; // don't push this as a visible log line
            }

            pushLine(job, line);
        }
    };

    proc.stdout.on('data', handleData);
    proc.stderr.on('data', handleData);

    proc.on('close', (code) => {
        pushLine(job, `[recovarr] Exited with code ${code ?? 1}`);

        if (code === 0 && job.watchData) {
            job.status = 'watching';
            sendEvent(job, 'watching', { watchData: job.watchData });
            pushLine(job, `[WATCH] Polling ${job.watchData.type} every 30s for import...`);
            startWatcher(job);
        } else {
            finishJob(job, code ?? 1);
        }
    });

    proc.on('error', (err) => {
        pushLine(job, `[recovarr] Failed to start: ${err.message}`);
        finishJob(job, 1);
    });
}

// ---------------------------------------------------------------------------
// Queue — one job at a time
// ---------------------------------------------------------------------------
let running = false;

function processQueue() {
    if (running) return;
    for (const job of jobs.values()) {
        if (job.status === 'queued') {
            running = true;
            runJob(job);
            const poll = setInterval(() => {
                if (job.status !== 'running') {
                    clearInterval(poll);
                    running = false;
                    processQueue();
                }
            }, 300);
            break;
        }
    }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------
function serveFile(res, filePath, contentType) {
    fs.readFile(filePath, (err, data) => {
        if (err) { res.writeHead(404); res.end('Not found'); return; }
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(data);
    });
}

function json(res, status, obj) {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
}

function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data', c => chunks.push(c));
        req.on('end', () => resolve(Buffer.concat(chunks).toString()));
        req.on('error', reject);
    });
}

function jobSummary(job) {
    return {
        id:         job.id,
        filepath:   job.filepath,
        status:     job.status,
        exitCode:   job.exitCode,
        lineCount:  job.lines.length,
        createdAt:  job.createdAt,
        finishedAt: job.finishedAt || null,
        watchData:  job.watchData,
        archived:   job.archived || false,
    };
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const p = url.pathname.replace(/\/+$/, '') || '/';

    res.setHeader('Access-Control-Allow-Origin', '*');

    // Static UI
    if (req.method === 'GET' && p === '/') {
        return serveFile(res, path.join(PUBLIC_DIR, 'index.html'), 'text/html');
    }

    // POST /api/recover
    if (req.method === 'POST' && p === '/api/recover') {
        let body;
        try { body = JSON.parse(await readBody(req)); }
        catch { return json(res, 400, { error: 'Invalid JSON' }); }

        const paths = (body.paths || []).map(s => s.trim()).filter(Boolean);
        if (!paths.length) return json(res, 400, { error: 'No paths provided' });

        const created = paths.map(fp => jobSummary(createJob(fp)));
        processQueue();
        return json(res, 202, { jobs: created });
    }

    // GET /api/jobs
    if (req.method === 'GET' && p === '/api/jobs') {
        return json(res, 200,
            [...jobs.values()].sort((a, b) => b.createdAt - a.createdAt).map(jobSummary));
    }

    // GET /api/jobs/:id
    const jobMatch = p.match(/^\/api\/jobs\/([a-f0-9]+)$/);
    if (req.method === 'GET' && jobMatch) {
        const job = jobs.get(jobMatch[1]);
        if (!job) return json(res, 404, { error: 'Not found' });
        return json(res, 200, { ...jobSummary(job), lines: job.lines });
    }

    // GET /api/jobs/:id/stream  (SSE)
    const streamMatch = p.match(/^\/api\/jobs\/([a-f0-9]+)\/stream$/);
    if (req.method === 'GET' && streamMatch) {
        const job = jobs.get(streamMatch[1]);
        if (!job) return json(res, 404, { error: 'Not found' });

        res.writeHead(200, {
            'Content-Type':      'text/event-stream',
            'Cache-Control':     'no-cache',
            'Connection':        'keep-alive',
            'X-Accel-Buffering': 'no',
        });

        // Replay existing lines
        for (const line of job.lines) {
            res.write(`data: ${JSON.stringify(line)}\n\n`);
        }

        const isActive = job.status === 'running' || job.status === 'watching' || job.status === 'queued';
        if (!isActive) {
            res.write(`event: done\ndata: ${JSON.stringify({ exitCode: job.exitCode, status: job.status, watchData: job.watchData })}\n\n`);
            res.end();
            return;
        }

        if (job.watchData && job.status === 'watching') {
            res.write(`event: watching\ndata: ${JSON.stringify({ watchData: job.watchData })}\n\n`);
        }

        job.sseClients.add(res);
        req.on('close', () => job.sseClients.delete(res));
        return;
    }

    // POST /api/jobs/:id/retry
    const retryMatch = p.match(/^\/api\/jobs\/([a-f0-9]+)\/retry$/);
    if (req.method === 'POST' && retryMatch) {
        const job = jobs.get(retryMatch[1]);
        if (!job) return json(res, 404, { error: 'Not found' });
        if (job.status === 'running' || job.status === 'watching')
            return json(res, 409, { error: 'Job is active' });
        const newJob = createJob(job.filepath);
        processQueue();
        return json(res, 202, jobSummary(newJob));
    }

    // DELETE /api/jobs/:id
    const delMatch = p.match(/^\/api\/jobs\/([a-f0-9]+)$/);
    if (req.method === 'DELETE' && delMatch) {
        const job = jobs.get(delMatch[1]);
        if (!job) return json(res, 404, { error: 'Not found' });
        const force = url.searchParams.get('force') === 'true';
        if ((job.status === 'running' || job.status === 'watching') && !force)
            return json(res, 409, { error: 'Job is active — use ?force=true to cancel' });
        if (job.watcherTimer) clearInterval(job.watcherTimer);
        if (job.archived) removeFromLog(delMatch[1]);
        jobs.delete(delMatch[1]);
        return json(res, 200, { ok: true });
    }

    res.writeHead(404); res.end('Not found');
});

loadJobLog();
loadPendingQueue();
processQueue(); // kick off any restored pending jobs

server.listen(PORT, '0.0.0.0', () => {
    console.log(`Recovarr listening on http://0.0.0.0:${PORT}`);
    console.log(`Script:  ${SCRIPT}`);
    console.log(`Config:  ${CONFIG_PATH}`);
    console.log(`Job log: ${LOG_PATH}`);
    console.log(`Queue:   ${QUEUE_PATH}`);
    if (!fs.existsSync(SCRIPT)) console.warn('WARNING: script not found');
});
