'use strict';

const http = require('http');
const { Pool } = require('pg');

const pool = new Pool({
  host: '127.0.0.1',
  port: 5432,
  user: 'postgres',
  database: 'bookmarks',
});

function escape(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function faviconUrl(url) {
  try {
    const u = new URL(url);
    return `https://www.google.com/s2/favicons?sz=32&domain=${encodeURIComponent(u.hostname)}`;
  } catch {
    return 'https://www.google.com/s2/favicons?sz=32&domain=example.com';
  }
}

function formatDate(ts) {
  const d = new Date(ts);
  return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
}

async function setup() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS bookmarks (
      id SERIAL PRIMARY KEY,
      url TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      tags TEXT[] NOT NULL DEFAULT '{}',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
  console.log('[bookmarks] Database table ready.');
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function sendHtml(res, html) {
  res.writeHead(200, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(html),
  });
  res.end(html);
}

function renderHtml(bookmarks) {
  const count = bookmarks.length;

  const cards = bookmarks.length === 0
    ? `<div class="empty-state">
        <div class="empty-icon">🔖</div>
        <p>No bookmarks yet. Add your first one above!</p>
      </div>`
    : bookmarks.map((b) => {
        const hostname = (() => {
          try { return new URL(b.url).hostname; } catch { return ''; }
        })();
        const favicon = faviconUrl(b.url);
        const tags = (b.tags || []).map((t) =>
          `<span class="tag">${escape(t)}</span>`
        ).join('');
        const desc = b.description
          ? `<p class="card-desc">${escape(b.description)}</p>`
          : '';
        return `
        <div class="card">
          <div class="card-header">
            <img class="favicon" src="${escape(favicon)}" alt="" width="32" height="32" onerror="this.style.display='none'">
            <div class="card-title-wrap">
              <a class="card-title" href="${escape(b.url)}" target="_blank" rel="noopener noreferrer">${escape(b.title)}</a>
              <span class="card-host">${escape(hostname)}</span>
            </div>
            <button class="delete-btn" onclick="deleteBookmark(${b.id})" title="Delete bookmark">&#10005;</button>
          </div>
          ${desc}
          <div class="card-footer">
            <div class="tags">${tags}</div>
            <span class="card-date">${formatDate(b.created_at)}</span>
          </div>
        </div>`;
      }).join('\n');

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Bookmarks</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #f5f5f7;
      color: #1d1d1f;
      min-height: 100vh;
    }

    header {
      background: #fff;
      border-bottom: 1px solid #e5e7eb;
      padding: 0 24px;
      height: 60px;
      display: flex;
      align-items: center;
      gap: 12px;
      position: sticky;
      top: 0;
      z-index: 10;
      box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    }

    header h1 {
      font-size: 1.25rem;
      font-weight: 700;
      color: #1d1d1f;
      display: flex;
      align-items: center;
      gap: 8px;
    }

    .count-badge {
      background: #4f46e5;
      color: #fff;
      font-size: 0.75rem;
      font-weight: 600;
      border-radius: 999px;
      padding: 2px 8px;
      line-height: 1.4;
    }

    main {
      max-width: 900px;
      margin: 0 auto;
      padding: 32px 20px;
    }

    .add-form {
      background: #fff;
      border-radius: 14px;
      box-shadow: 0 1px 4px rgba(0,0,0,0.08), 0 0 0 1px rgba(0,0,0,0.04);
      padding: 24px;
      margin-bottom: 32px;
    }

    .add-form h2 {
      font-size: 1rem;
      font-weight: 600;
      color: #374151;
      margin-bottom: 16px;
    }

    .form-row {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 12px;
      margin-bottom: 12px;
    }

    @media (max-width: 600px) {
      .form-row { grid-template-columns: 1fr; }
    }

    .form-field {
      display: flex;
      flex-direction: column;
      gap: 4px;
    }

    .form-field label {
      font-size: 0.8rem;
      font-weight: 500;
      color: #6b7280;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

    .form-field input,
    .form-field textarea {
      border: 1.5px solid #e5e7eb;
      border-radius: 8px;
      padding: 9px 12px;
      font-size: 0.9rem;
      font-family: inherit;
      color: #1d1d1f;
      background: #fafafa;
      transition: border-color 0.15s, box-shadow 0.15s;
      outline: none;
      resize: none;
    }

    .form-field input:focus,
    .form-field textarea:focus {
      border-color: #4f46e5;
      box-shadow: 0 0 0 3px rgba(79,70,229,0.12);
      background: #fff;
    }

    .form-actions {
      display: flex;
      justify-content: flex-end;
      margin-top: 4px;
    }

    .btn-add {
      background: #4f46e5;
      color: #fff;
      border: none;
      border-radius: 8px;
      padding: 10px 22px;
      font-size: 0.9rem;
      font-weight: 600;
      cursor: pointer;
      transition: background 0.15s, transform 0.1s;
      display: flex;
      align-items: center;
      gap: 6px;
    }

    .btn-add:hover { background: #4338ca; }
    .btn-add:active { transform: scale(0.97); }

    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
      gap: 16px;
    }

    .card {
      background: #fff;
      border-radius: 12px;
      box-shadow: 0 1px 4px rgba(0,0,0,0.07), 0 0 0 1px rgba(0,0,0,0.04);
      padding: 16px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      transition: box-shadow 0.15s, transform 0.15s;
    }

    .card:hover {
      box-shadow: 0 4px 16px rgba(0,0,0,0.1), 0 0 0 1px rgba(79,70,229,0.08);
      transform: translateY(-1px);
    }

    .card-header {
      display: flex;
      align-items: flex-start;
      gap: 10px;
    }

    .favicon {
      width: 32px;
      height: 32px;
      border-radius: 6px;
      flex-shrink: 0;
      object-fit: contain;
      background: #f3f4f6;
      padding: 2px;
    }

    .card-title-wrap {
      flex: 1;
      min-width: 0;
    }

    .card-title {
      display: block;
      font-size: 0.95rem;
      font-weight: 600;
      color: #1d1d1f;
      text-decoration: none;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      line-height: 1.3;
    }

    .card-title:hover { color: #4f46e5; text-decoration: underline; }

    .card-host {
      font-size: 0.75rem;
      color: #9ca3af;
      display: block;
      margin-top: 2px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }

    .delete-btn {
      background: none;
      border: none;
      color: #d1d5db;
      cursor: pointer;
      font-size: 0.9rem;
      padding: 2px 4px;
      border-radius: 4px;
      line-height: 1;
      transition: color 0.15s, background 0.15s;
      flex-shrink: 0;
    }

    .delete-btn:hover { color: #ef4444; background: #fef2f2; }

    .card-desc {
      font-size: 0.85rem;
      color: #6b7280;
      line-height: 1.5;
      display: -webkit-box;
      -webkit-line-clamp: 2;
      -webkit-box-orient: vertical;
      overflow: hidden;
    }

    .card-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      margin-top: auto;
    }

    .tags {
      display: flex;
      flex-wrap: wrap;
      gap: 4px;
      flex: 1;
      min-width: 0;
    }

    .tag {
      background: #eef2ff;
      color: #4f46e5;
      font-size: 0.72rem;
      font-weight: 500;
      border-radius: 999px;
      padding: 2px 8px;
      white-space: nowrap;
    }

    .card-date {
      font-size: 0.75rem;
      color: #9ca3af;
      white-space: nowrap;
      flex-shrink: 0;
    }

    .empty-state {
      grid-column: 1 / -1;
      text-align: center;
      padding: 64px 24px;
      color: #9ca3af;
    }

    .empty-icon { font-size: 3rem; margin-bottom: 12px; }

    .empty-state p { font-size: 1rem; }

    .section-title {
      font-size: 0.85rem;
      font-weight: 600;
      color: #6b7280;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 14px;
    }
  </style>
</head>
<body>
  <header>
    <h1>🔖 Bookmarks</h1>
    <span class="count-badge">${count}</span>
  </header>
  <main>
    <div class="add-form">
      <h2>Add Bookmark</h2>
      <form id="add-form" onsubmit="addBookmark(event)">
        <div class="form-row">
          <div class="form-field">
            <label for="url">URL</label>
            <input id="url" type="text" placeholder="https://example.com" required autocomplete="off">
          </div>
          <div class="form-field">
            <label for="title">Title</label>
            <input id="title" type="text" placeholder="Page title" required autocomplete="off">
          </div>
        </div>
        <div class="form-row">
          <div class="form-field">
            <label for="description">Description <span style="font-weight:400;text-transform:none">(optional)</span></label>
            <textarea id="description" rows="2" placeholder="A brief note about this link..."></textarea>
          </div>
          <div class="form-field">
            <label for="tags">Tags <span style="font-weight:400;text-transform:none">(comma-separated)</span></label>
            <input id="tags" type="text" placeholder="tech, reading, tools" autocomplete="off">
          </div>
        </div>
        <div class="form-actions">
          <button type="submit" class="btn-add">&#43; Add Bookmark</button>
        </div>
      </form>
    </div>
    <div class="section-title">${count === 0 ? 'Your bookmarks' : count === 1 ? '1 bookmark' : count + ' bookmarks'}</div>
    <div class="grid">
      ${cards}
    </div>
  </main>
  <script>
    async function addBookmark(e) {
      e.preventDefault();
      let url = document.getElementById('url').value.trim();
      const title = document.getElementById('title').value.trim();
      const description = document.getElementById('description').value.trim();
      const tags = document.getElementById('tags').value.trim();

      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://' + url;
      }

      const btn = e.target.querySelector('.btn-add');
      btn.disabled = true;
      btn.textContent = 'Adding...';

      try {
        const res = await fetch('/api/bookmarks', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ url, title, description, tags }),
        });
        if (!res.ok) throw new Error('Failed to add');
        document.getElementById('url').value = '';
        document.getElementById('title').value = '';
        document.getElementById('description').value = '';
        document.getElementById('tags').value = '';
        window.location.reload();
      } catch (err) {
        alert('Error adding bookmark: ' + err.message);
        btn.disabled = false;
        btn.textContent = '+ Add Bookmark';
      }
    }

    async function deleteBookmark(id) {
      if (!confirm('Delete this bookmark?')) return;
      try {
        const res = await fetch('/api/bookmarks/' + id, { method: 'DELETE' });
        if (!res.ok) throw new Error('Failed to delete');
        window.location.reload();
      } catch (err) {
        alert('Error deleting bookmark: ' + err.message);
      }
    }
  </script>
</body>
</html>`;
}

async function handleRequest(req, res) {
  const url = req.url;
  const method = req.method;

  if (method === 'GET' && url === '/') {
    const result = await pool.query('SELECT * FROM bookmarks ORDER BY created_at DESC');
    sendHtml(res, renderHtml(result.rows));
    return;
  }

  if (method === 'GET' && url === '/api/bookmarks') {
    const result = await pool.query('SELECT * FROM bookmarks ORDER BY created_at DESC');
    sendJson(res, 200, result.rows);
    return;
  }

  if (method === 'POST' && url === '/api/bookmarks') {
    const body = await readBody(req);
    let data;
    try {
      data = JSON.parse(body);
    } catch {
      sendJson(res, 400, { error: 'Invalid JSON' });
      return;
    }
    const { url: bookmarkUrl, title, description = '', tags = '' } = data;
    if (!bookmarkUrl || !title) {
      sendJson(res, 400, { error: 'url and title are required' });
      return;
    }
    const tagsArray = typeof tags === 'string'
      ? tags.split(',').map((t) => t.trim()).filter(Boolean)
      : Array.isArray(tags) ? tags : [];

    const result = await pool.query(
      'INSERT INTO bookmarks (url, title, description, tags) VALUES ($1, $2, $3, $4) RETURNING *',
      [bookmarkUrl, title, description, tagsArray]
    );
    sendJson(res, 201, result.rows[0]);
    return;
  }

  const deleteMatch = url.match(/^\/api\/bookmarks\/(\d+)$/);
  if (method === 'DELETE' && deleteMatch) {
    const id = parseInt(deleteMatch[1], 10);
    await pool.query('DELETE FROM bookmarks WHERE id = $1', [id]);
    res.writeHead(204);
    res.end();
    return;
  }

  sendJson(res, 404, { error: 'Not found' });
}

async function connectWithRetry(retries = 10, delayMs = 2000) {
  for (let i = 1; i <= retries; i++) {
    try {
      const client = await pool.connect();
      client.release();
      console.log('[bookmarks] Connected to PostgreSQL.');
      return;
    } catch (err) {
      console.log(`[bookmarks] Waiting for PostgreSQL (attempt ${i}/${retries})...`);
      if (i === retries) throw new Error('Could not connect to PostgreSQL: ' + err.message);
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
}

async function main() {
  await connectWithRetry();
  await setup();

  const server = http.createServer(async (req, res) => {
    try {
      await handleRequest(req, res);
    } catch (err) {
      console.error('[bookmarks] Request error:', err);
      if (!res.headersSent) {
        sendJson(res, 500, { error: 'Internal server error' });
      }
    }
  });

  server.listen(3000, () => {
    console.log('[bookmarks] Web server listening on http://localhost:3000');
  });
}

main().catch((err) => {
  console.error('[bookmarks] Fatal error:', err);
  process.exit(1);
});
