'use strict';

const http = require('http');
const Redis = require('ioredis');

const redis = new Redis({ host: '127.0.0.1', port: 6379, lazyConnect: true });

const LEADERBOARD_KEY = 'leaderboard';

// ── Helpers ──────────────────────────────────────────────────────────────────

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => (data += chunk));
    req.on('end', () => {
      try {
        resolve(data ? JSON.parse(data) : {});
      } catch {
        reject(Object.assign(new Error('Invalid JSON'), { status: 400 }));
      }
    });
    req.on('error', reject);
  });
}

function send(res, status, body) {
  const payload = typeof body === 'string' ? body : JSON.stringify(body);
  const ct = typeof body === 'string' ? 'text/html; charset=utf-8' : 'application/json';
  res.writeHead(status, { 'Content-Type': ct, 'Content-Length': Buffer.byteLength(payload) });
  res.end(payload);
}

function escape(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

async function getScores() {
  const raw = await redis.zrevrange(LEADERBOARD_KEY, 0, -1, 'WITHSCORES');
  const entries = [];
  for (let i = 0; i < raw.length; i += 2) {
    entries.push({ name: raw[i], score: parseFloat(raw[i + 1]) });
  }
  return entries.map((e, idx) => ({ rank: idx + 1, name: e.name, score: e.score }));
}

// ── HTML ─────────────────────────────────────────────────────────────────────

function renderHtml(scores) {
  const rankEmoji = r => r === 1 ? '🥇' : r === 2 ? '🥈' : r === 3 ? '🥉' : r;

  const rows = scores.length === 0
    ? `<tr class="empty"><td colspan="4">No players yet. Add someone above.</td></tr>`
    : scores.map(({ rank, name, score }) => {
        const topClass = rank <= 3 ? ` class="top-${rank}"` : '';
        const eName = escape(name);
        const encodedName = encodeURIComponent(name);
        return `
      <tr${topClass}>
        <td class="rank">${rankEmoji(rank)}</td>
        <td class="player-name">${eName}</td>
        <td class="score">${score % 1 === 0 ? score : score.toFixed(2)}</td>
        <td class="actions">
          <button class="btn btn-inc" onclick="increment(${JSON.stringify(encodedName)}, 10)">+10</button>
          <button class="btn btn-dec" onclick="increment(${JSON.stringify(encodedName)}, -10)">−10</button>
          <button class="btn btn-rem" onclick="remove(${JSON.stringify(encodedName)}, ${JSON.stringify(eName)})">Remove</button>
        </td>
      </tr>`;
      }).join('');

  const playerCount = scores.length;
  const playerLabel = playerCount === 1 ? '1 player' : `${playerCount} players`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Leaderboard (Redis)</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #0f0f13;
      color: #e2e8f0;
      min-height: 100vh;
    }

    header {
      background: linear-gradient(135deg, #1a0505 0%, #1f0808 50%, #0f0f13 100%);
      border-bottom: 2px solid #dc2626;
      padding: 1.25rem 2rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      box-shadow: 0 4px 24px rgba(220, 38, 38, 0.2);
    }

    header h1 {
      font-size: 1.75rem;
      font-weight: 800;
      letter-spacing: -0.5px;
      color: #fff;
    }

    .player-count {
      font-size: 0.85rem;
      background: rgba(220, 38, 38, 0.15);
      border: 1px solid rgba(220, 38, 38, 0.4);
      color: #fca5a5;
      padding: 0.3rem 0.8rem;
      border-radius: 999px;
      font-weight: 600;
    }

    main {
      max-width: 780px;
      margin: 2.5rem auto;
      padding: 0 1rem;
    }

    /* Add player card */
    .add-card {
      background: #18181f;
      border: 1px solid #2d2d3a;
      border-radius: 14px;
      padding: 1.5rem;
      margin-bottom: 2rem;
      box-shadow: 0 2px 16px rgba(0,0,0,0.4);
    }

    .add-card h2 {
      font-size: 0.9rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: #94a3b8;
      margin-bottom: 1rem;
    }

    .form-row {
      display: flex;
      gap: 0.75rem;
      flex-wrap: wrap;
    }

    .form-row input {
      background: #0f0f13;
      border: 1px solid #2d2d3a;
      color: #e2e8f0;
      border-radius: 8px;
      padding: 0.6rem 0.9rem;
      font-size: 0.95rem;
      outline: none;
      transition: border-color 0.15s;
    }

    .form-row input:focus {
      border-color: #dc2626;
    }

    .form-row input[name="playerName"] { flex: 1 1 180px; }
    .form-row input[name="startScore"] { width: 110px; flex: 0 0 auto; }

    .btn-add {
      background: #dc2626;
      color: #fff;
      border: none;
      border-radius: 8px;
      padding: 0.6rem 1.4rem;
      font-size: 0.95rem;
      font-weight: 700;
      cursor: pointer;
      transition: background 0.15s, transform 0.1s;
      white-space: nowrap;
    }

    .btn-add:hover { background: #b91c1c; }
    .btn-add:active { transform: scale(0.97); }

    /* Leaderboard table */
    .lb-wrap {
      background: #18181f;
      border: 1px solid #2d2d3a;
      border-radius: 14px;
      overflow: hidden;
      box-shadow: 0 2px 16px rgba(0,0,0,0.4);
    }

    table {
      width: 100%;
      border-collapse: collapse;
    }

    thead tr {
      background: #111118;
      border-bottom: 1px solid #2d2d3a;
    }

    thead th {
      padding: 0.85rem 1rem;
      font-size: 0.78rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: #64748b;
      text-align: left;
    }

    thead th:first-child { width: 60px; text-align: center; }
    thead th:nth-child(3) { text-align: right; }
    thead th:last-child { text-align: right; }

    tbody tr {
      border-bottom: 1px solid #1e1e28;
      transition: background 0.12s;
    }

    tbody tr:last-child { border-bottom: none; }

    tbody tr:hover { background: rgba(255,255,255,0.03); }

    /* Top 3 row highlights */
    tbody tr.top-1 { background: rgba(234, 179, 8, 0.07); }
    tbody tr.top-2 { background: rgba(148, 163, 184, 0.05); }
    tbody tr.top-3 { background: rgba(180, 120, 60, 0.06); }
    tbody tr.top-1:hover { background: rgba(234, 179, 8, 0.11); }
    tbody tr.top-2:hover { background: rgba(148, 163, 184, 0.09); }
    tbody tr.top-3:hover { background: rgba(180, 120, 60, 0.10); }

    td {
      padding: 0.9rem 1rem;
      font-size: 0.95rem;
    }

    td.rank {
      text-align: center;
      font-size: 1.15rem;
      font-weight: 700;
      color: #94a3b8;
      width: 60px;
    }

    td.player-name {
      font-weight: 600;
      color: #f1f5f9;
    }

    tbody tr.top-1 td.player-name,
    tbody tr.top-2 td.player-name,
    tbody tr.top-3 td.player-name {
      font-weight: 800;
    }

    td.score {
      text-align: right;
      font-variant-numeric: tabular-nums;
      font-weight: 700;
      font-size: 1.05rem;
      color: #f8fafc;
    }

    tbody tr.top-1 td.score { color: #fbbf24; }
    tbody tr.top-2 td.score { color: #cbd5e1; }
    tbody tr.top-3 td.score { color: #c97c3a; }

    td.actions {
      text-align: right;
      white-space: nowrap;
    }

    .btn {
      border: none;
      border-radius: 6px;
      padding: 0.3rem 0.65rem;
      font-size: 0.8rem;
      font-weight: 700;
      cursor: pointer;
      transition: background 0.12s, transform 0.1s;
      margin-left: 0.3rem;
    }

    .btn:active { transform: scale(0.95); }

    .btn-inc {
      background: rgba(34, 197, 94, 0.15);
      color: #4ade80;
      border: 1px solid rgba(34, 197, 94, 0.25);
    }
    .btn-inc:hover { background: rgba(34, 197, 94, 0.25); }

    .btn-dec {
      background: rgba(251, 191, 36, 0.12);
      color: #fbbf24;
      border: 1px solid rgba(251, 191, 36, 0.25);
    }
    .btn-dec:hover { background: rgba(251, 191, 36, 0.22); }

    .btn-rem {
      background: rgba(220, 38, 38, 0.12);
      color: #f87171;
      border: 1px solid rgba(220, 38, 38, 0.25);
    }
    .btn-rem:hover { background: rgba(220, 38, 38, 0.22); }

    tr.empty td {
      text-align: center;
      padding: 3rem 1rem;
      color: #475569;
      font-size: 0.95rem;
      font-style: italic;
    }

    .error-banner {
      display: none;
      background: rgba(220,38,38,0.12);
      border: 1px solid rgba(220,38,38,0.4);
      color: #fca5a5;
      border-radius: 8px;
      padding: 0.7rem 1rem;
      margin-bottom: 1rem;
      font-size: 0.9rem;
    }

    .refresh-indicator {
      font-size: 0.75rem;
      color: #334155;
      text-align: right;
      margin-top: 0.6rem;
    }
  </style>
</head>
<body>
  <header>
    <h1>🏆 Leaderboard</h1>
    <span class="player-count" id="playerCount">${playerLabel}</span>
  </header>

  <main>
    <div class="add-card">
      <h2>Add Player</h2>
      <div id="errorBanner" class="error-banner"></div>
      <div class="form-row">
        <input type="text" name="playerName" id="playerName" placeholder="Player name" maxlength="64" autocomplete="off" />
        <input type="number" name="startScore" id="startScore" placeholder="Score" value="0" />
        <button class="btn-add" onclick="addPlayer()">Add Player</button>
      </div>
    </div>

    <div class="lb-wrap">
      <table>
        <thead>
          <tr>
            <th>Rank</th>
            <th>Player</th>
            <th style="text-align:right">Score</th>
            <th style="text-align:right">Actions</th>
          </tr>
        </thead>
        <tbody id="leaderboardBody">
          ${rows}
        </tbody>
      </table>
    </div>
    <p class="refresh-indicator" id="refreshNote">Auto-refreshes every 5s</p>
  </main>

  <script>
    let refreshTimer = null;

    function scheduleRefresh() {
      clearTimeout(refreshTimer);
      refreshTimer = setTimeout(refreshScores, 5000);
    }

    function showError(msg) {
      const banner = document.getElementById('errorBanner');
      banner.textContent = msg;
      banner.style.display = 'block';
      setTimeout(() => { banner.style.display = 'none'; }, 4000);
    }

    function esc(str) {
      return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
    }

    function rankEmoji(r) {
      if (r === 1) return '🥇';
      if (r === 2) return '🥈';
      if (r === 3) return '🥉';
      return r;
    }

    function renderRows(scores) {
      const tbody = document.getElementById('leaderboardBody');
      const count = document.getElementById('playerCount');

      count.textContent = scores.length === 1 ? '1 player' : scores.length + ' players';

      if (scores.length === 0) {
        tbody.innerHTML = '<tr class="empty"><td colspan="4">No players yet. Add someone above.</td></tr>';
        return;
      }

      tbody.innerHTML = scores.map(({ rank, name, score }) => {
        const topClass = rank <= 3 ? ' class="top-' + rank + '"' : '';
        const eName = esc(name);
        const encodedName = encodeURIComponent(name);
        const displayScore = Number.isInteger(score) ? score : score.toFixed(2);
        return \`<tr\${topClass}>
          <td class="rank">\${rankEmoji(rank)}</td>
          <td class="player-name">\${eName}</td>
          <td class="score">\${displayScore}</td>
          <td class="actions">
            <button class="btn btn-inc" onclick="increment(\${JSON.stringify(encodedName)}, 10)">+10</button>
            <button class="btn btn-dec" onclick="increment(\${JSON.stringify(encodedName)}, -10)">−10</button>
            <button class="btn btn-rem" onclick="remove(\${JSON.stringify(encodedName)}, \${JSON.stringify(eName)})">Remove</button>
          </td>
        </tr>\`;
      }).join('');
    }

    async function refreshScores() {
      try {
        const res = await fetch('/api/scores');
        if (!res.ok) throw new Error('HTTP ' + res.status);
        const scores = await res.json();
        renderRows(scores);
        document.getElementById('refreshNote').textContent =
          'Last updated: ' + new Date().toLocaleTimeString();
      } catch (e) {
        console.error('Refresh failed:', e);
      } finally {
        scheduleRefresh();
      }
    }

    async function addPlayer() {
      const nameEl = document.getElementById('playerName');
      const scoreEl = document.getElementById('startScore');
      const name = nameEl.value.trim();
      const score = parseFloat(scoreEl.value) || 0;

      if (!name) { showError('Please enter a player name.'); nameEl.focus(); return; }

      try {
        const res = await fetch('/api/scores', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name, score })
        });
        if (!res.ok) {
          const err = await res.json().catch(() => ({}));
          throw new Error(err.error || 'HTTP ' + res.status);
        }
        nameEl.value = '';
        scoreEl.value = '0';
        await refreshScores();
      } catch (e) {
        showError('Failed to add player: ' + e.message);
      }
    }

    async function increment(encodedName, delta) {
      try {
        const res = await fetch('/api/scores/' + encodedName + '/increment', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ delta })
        });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        await refreshScores();
      } catch (e) {
        showError('Failed to update score: ' + e.message);
      }
    }

    async function remove(encodedName, displayName) {
      if (!confirm('Remove ' + displayName + ' from the leaderboard?')) return;
      try {
        const res = await fetch('/api/scores/' + encodedName, { method: 'DELETE' });
        if (!res.ok) throw new Error('HTTP ' + res.status);
        await refreshScores();
      } catch (e) {
        showError('Failed to remove player: ' + e.message);
      }
    }

    // Enter key on form inputs
    document.addEventListener('DOMContentLoaded', () => {
      ['playerName', 'startScore'].forEach(id => {
        document.getElementById(id).addEventListener('keydown', e => {
          if (e.key === 'Enter') addPlayer();
        });
      });
      scheduleRefresh();
    });
  </script>
</body>
</html>`;
}

// ── Connect with retry ────────────────────────────────────────────────────────

async function connectRedis(maxAttempts = 10, delayMs = 1000) {
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await redis.connect();
      await redis.ping();
      console.log('[leaderboard] Connected to Redis');
      return;
    } catch (err) {
      console.log(`[leaderboard] Redis connect attempt ${attempt}/${maxAttempts} failed: ${err.message}`);
      if (attempt === maxAttempts) throw err;
      await new Promise(r => setTimeout(r, delayMs));
    }
  }
}

// ── Router ────────────────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;

  try {
    // GET /
    if (req.method === 'GET' && path === '/') {
      const scores = await getScores();
      return send(res, 200, renderHtml(scores));
    }

    // GET /api/scores
    if (req.method === 'GET' && path === '/api/scores') {
      const scores = await getScores();
      return send(res, 200, scores);
    }

    // POST /api/scores
    if (req.method === 'POST' && path === '/api/scores') {
      const body = await readBody(req);
      const name = (body.name || '').trim();
      const score = parseFloat(body.score);
      if (!name) return send(res, 400, { error: 'name is required' });
      if (isNaN(score)) return send(res, 400, { error: 'score must be a number' });
      await redis.zadd(LEADERBOARD_KEY, score, name);
      return send(res, 201, { name, score });
    }

    // POST /api/scores/:name/increment
    const incMatch = path.match(/^\/api\/scores\/([^/]+)\/increment$/);
    if (req.method === 'POST' && incMatch) {
      const name = decodeURIComponent(incMatch[1]);
      const body = await readBody(req);
      const delta = parseInt(body.delta, 10);
      if (isNaN(delta)) return send(res, 400, { error: 'delta must be an integer' });

      // ZINCRBY then clamp to 0
      const newScoreStr = await redis.zincrby(LEADERBOARD_KEY, delta, name);
      let newScore = parseFloat(newScoreStr);
      if (newScore < 0) {
        newScore = 0;
        await redis.zadd(LEADERBOARD_KEY, 0, name);
      }
      return send(res, 200, { name, score: newScore });
    }

    // DELETE /api/scores/:name
    const delMatch = path.match(/^\/api\/scores\/([^/]+)$/);
    if (req.method === 'DELETE' && delMatch) {
      const name = decodeURIComponent(delMatch[1]);
      await redis.zrem(LEADERBOARD_KEY, name);
      res.writeHead(204);
      return res.end();
    }

    send(res, 404, { error: 'Not found' });
  } catch (err) {
    console.error('[leaderboard] Request error:', err);
    send(res, 500, { error: 'Internal server error' });
  }
});

// ── Boot ──────────────────────────────────────────────────────────────────────

(async () => {
  await connectRedis();
  server.listen(3000, () => {
    console.log('[leaderboard] Server listening on http://0.0.0.0:3000');
  });
})().catch(err => {
  console.error('[leaderboard] Fatal startup error:', err);
  process.exit(1);
});
