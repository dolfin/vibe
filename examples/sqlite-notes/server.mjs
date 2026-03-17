import { DatabaseSync } from 'node:sqlite';
import { createServer } from 'node:http';
import { mkdirSync } from 'node:fs';

mkdirSync('/data', { recursive: true });

const db = new DatabaseSync('/data/notes.db');

db.exec(`
  CREATE TABLE IF NOT EXISTS notes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    body TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
  )
`);

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => { data += chunk; });
    req.on('end', () => resolve(data));
    req.on('error', reject);
  });
}

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Notes (SQLite)</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      background: #f2f2f7;
      color: #1c1c1e;
      min-height: 100vh;
    }

    header {
      background: #1c1c1e;
      color: #fff;
      padding: 0 24px;
      height: 56px;
      display: flex;
      align-items: center;
      gap: 12px;
      position: sticky;
      top: 0;
      z-index: 10;
      box-shadow: 0 1px 0 rgba(255,255,255,0.08);
    }

    header h1 {
      font-size: 18px;
      font-weight: 600;
      letter-spacing: -0.3px;
      flex: 1;
    }

    #count-badge {
      background: #007aff;
      color: #fff;
      font-size: 12px;
      font-weight: 600;
      padding: 2px 8px;
      border-radius: 10px;
      min-width: 24px;
      text-align: center;
    }

    main {
      max-width: 1100px;
      margin: 0 auto;
      padding: 28px 20px 48px;
    }

    .form-card {
      background: #fff;
      border-radius: 14px;
      padding: 20px;
      box-shadow: 0 1px 4px rgba(0,0,0,0.08), 0 4px 16px rgba(0,0,0,0.04);
      margin-bottom: 28px;
    }

    .form-card h2 {
      font-size: 14px;
      font-weight: 600;
      color: #6e6e73;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 14px;
    }

    input[type="text"], textarea {
      width: 100%;
      border: 1.5px solid #e5e5ea;
      border-radius: 10px;
      padding: 10px 14px;
      font-size: 15px;
      font-family: inherit;
      color: #1c1c1e;
      background: #fafafa;
      transition: border-color 0.15s, box-shadow 0.15s;
      outline: none;
      resize: vertical;
    }

    input[type="text"]:focus, textarea:focus {
      border-color: #007aff;
      box-shadow: 0 0 0 3px rgba(0,122,255,0.12);
      background: #fff;
    }

    input[type="text"] {
      margin-bottom: 10px;
    }

    textarea {
      min-height: 80px;
      margin-bottom: 14px;
    }

    .form-footer {
      display: flex;
      align-items: center;
      justify-content: space-between;
    }

    .hint {
      font-size: 12px;
      color: #aeaeb2;
    }

    button.primary {
      background: #007aff;
      color: #fff;
      border: none;
      border-radius: 10px;
      padding: 9px 20px;
      font-size: 14px;
      font-weight: 600;
      font-family: inherit;
      cursor: pointer;
      transition: background 0.15s, transform 0.1s;
    }

    button.primary:hover { background: #0066d6; }
    button.primary:active { transform: scale(0.97); }

    .section-title {
      font-size: 13px;
      font-weight: 600;
      color: #6e6e73;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 14px;
    }

    #notes-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
      gap: 16px;
    }

    .note-card {
      background: #fff;
      border-radius: 14px;
      padding: 18px;
      box-shadow: 0 1px 4px rgba(0,0,0,0.08), 0 4px 16px rgba(0,0,0,0.04);
      display: flex;
      flex-direction: column;
      gap: 8px;
      transition: box-shadow 0.15s, transform 0.15s;
    }

    .note-card:hover {
      box-shadow: 0 2px 8px rgba(0,0,0,0.1), 0 8px 24px rgba(0,0,0,0.07);
      transform: translateY(-1px);
    }

    .note-header {
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 8px;
    }

    .note-title {
      font-size: 15px;
      font-weight: 600;
      color: #1c1c1e;
      line-height: 1.35;
      word-break: break-word;
    }

    .note-body {
      font-size: 14px;
      color: #6e6e73;
      line-height: 1.5;
      white-space: pre-wrap;
      word-break: break-word;
      flex: 1;
    }

    .note-date {
      font-size: 12px;
      color: #aeaeb2;
      margin-top: 4px;
    }

    button.delete {
      background: none;
      border: none;
      color: #aeaeb2;
      font-size: 16px;
      cursor: pointer;
      padding: 2px 4px;
      border-radius: 6px;
      line-height: 1;
      flex-shrink: 0;
      transition: color 0.15s, background 0.15s;
    }

    button.delete:hover {
      color: #ff3b30;
      background: rgba(255,59,48,0.08);
    }

    .empty-state {
      grid-column: 1 / -1;
      text-align: center;
      padding: 60px 20px;
      color: #aeaeb2;
    }

    .empty-state .icon {
      font-size: 48px;
      margin-bottom: 12px;
    }

    .empty-state p {
      font-size: 15px;
    }
  </style>
</head>
<body>
  <header>
    <h1>📝 Notes</h1>
    <span id="count-badge">0</span>
  </header>

  <main>
    <div class="form-card">
      <h2>New Note</h2>
      <input type="text" id="title" placeholder="Title" />
      <textarea id="body" placeholder="Write something…"></textarea>
      <div class="form-footer">
        <span class="hint">Cmd+Enter to save</span>
        <button class="primary" onclick="addNote()">Add Note</button>
      </div>
    </div>

    <div class="section-title">All Notes</div>
    <div id="notes-grid"></div>
  </main>

  <script>
    function esc(s) {
      return String(s)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
    }

    function fmtDate(iso) {
      return new Date(iso).toLocaleString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric',
        hour: 'numeric', minute: '2-digit'
      });
    }

    async function load() {
      const res = await fetch('/api/notes');
      const notes = await res.json();
      const grid = document.getElementById('notes-grid');
      const badge = document.getElementById('count-badge');
      badge.textContent = notes.length;

      if (notes.length === 0) {
        grid.innerHTML = \`
          <div class="empty-state">
            <div class="icon">🗒️</div>
            <p>No notes yet. Add your first note above.</p>
          </div>\`;
        return;
      }

      grid.innerHTML = notes.map(n => \`
        <div class="note-card">
          <div class="note-header">
            <div class="note-title">\${esc(n.title)}</div>
            <button class="delete" onclick="del(\${n.id})" title="Delete">✕</button>
          </div>
          \${n.body ? \`<div class="note-body">\${esc(n.body)}</div>\` : ''}
          <div class="note-date">\${fmtDate(n.created_at)}</div>
        </div>\`
      ).join('');
    }

    async function addNote() {
      const title = document.getElementById('title').value.trim();
      const body = document.getElementById('body').value.trim();
      if (!title) {
        document.getElementById('title').focus();
        return;
      }
      await fetch('/api/notes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title, body })
      });
      document.getElementById('title').value = '';
      document.getElementById('body').value = '';
      document.getElementById('title').focus();
      load();
    }

    async function del(id) {
      await fetch(\`/api/notes/\${id}\`, { method: 'DELETE' });
      load();
    }

    document.addEventListener('keydown', e => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') {
        addNote();
      }
    });

    load();
  </script>
</body>
</html>`;

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const { method, pathname } = { method: req.method, pathname: url.pathname };

    if (method === 'GET' && pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(HTML);
      return;
    }

    if (method === 'GET' && pathname === '/api/notes') {
      const stmt = db.prepare('SELECT * FROM notes ORDER BY created_at DESC');
      const notes = stmt.all();
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(notes));
      return;
    }

    if (method === 'POST' && pathname === '/api/notes') {
      const raw = await readBody(req);
      const { title, body } = JSON.parse(raw);
      if (!title || typeof title !== 'string') {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'title is required' }));
        return;
      }
      const stmt = db.prepare(
        'INSERT INTO notes (title, body) VALUES (?, ?) RETURNING *'
      );
      const note = stmt.get(title, body ?? '');
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(note));
      return;
    }

    const deleteMatch = pathname.match(/^\/api\/notes\/(\d+)$/);
    if (method === 'DELETE' && deleteMatch) {
      const id = parseInt(deleteMatch[1], 10);
      const stmt = db.prepare('DELETE FROM notes WHERE id = ?');
      stmt.run(id);
      res.writeHead(204);
      res.end();
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
  } catch (err) {
    console.error(err);
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Internal server error' }));
  }
});

server.listen(3000, () => {
  console.log('Notes server running on http://localhost:3000');
});
