import { createServer } from "node:http";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomUUID } from "node:crypto";

const DATA_FILE = "/data/notes.json";
const PORT = 3000;

// ── persistence ──────────────────────────────────────────────────────────────

function loadNotes() {
  if (!existsSync(DATA_FILE)) return [];
  try {
    return JSON.parse(readFileSync(DATA_FILE, "utf8"));
  } catch {
    return [];
  }
}

function saveNotes(notes) {
  writeFileSync(DATA_FILE, JSON.stringify(notes, null, 2), "utf8");
}

// ── HTML ─────────────────────────────────────────────────────────────────────

const HTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Encrypted Notes</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0 }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #0f0f12;
      color: #e8e8ea;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 2rem 1rem;
    }
    header {
      display: flex;
      align-items: center;
      gap: .6rem;
      margin-bottom: 2rem;
    }
    header h1 { font-size: 1.5rem; font-weight: 700 }
    header .lock { font-size: 1.4rem }
    .badge {
      font-size: .7rem;
      background: #2a2a38;
      border: 1px solid #3a3a50;
      border-radius: 6px;
      padding: .2rem .5rem;
      color: #9a9ab0;
      letter-spacing: .04em;
    }
    .container { width: 100%; max-width: 600px }
    form {
      display: flex;
      gap: .5rem;
      margin-bottom: 1.5rem;
    }
    input[type=text] {
      flex: 1;
      background: #1a1a24;
      border: 1px solid #2e2e42;
      border-radius: 8px;
      padding: .6rem .9rem;
      color: #e8e8ea;
      font-size: .95rem;
      outline: none;
    }
    input[type=text]:focus { border-color: #6060cc }
    button {
      background: #5050bb;
      color: #fff;
      border: none;
      border-radius: 8px;
      padding: .6rem 1.1rem;
      font-size: .95rem;
      cursor: pointer;
      font-weight: 600;
      transition: background .15s;
    }
    button:hover { background: #6060cc }
    .notes { display: flex; flex-direction: column; gap: .6rem }
    .note {
      background: #1a1a24;
      border: 1px solid #2a2a38;
      border-radius: 10px;
      padding: .9rem 1rem;
      display: flex;
      align-items: flex-start;
      gap: .75rem;
    }
    .note-body { flex: 1 }
    .note-text { font-size: .95rem; line-height: 1.5 }
    .note-time { font-size: .75rem; color: #6060a0; margin-top: .25rem }
    .del {
      background: none;
      border: none;
      color: #5050a0;
      cursor: pointer;
      font-size: 1.1rem;
      padding: .1rem .3rem;
      border-radius: 4px;
      line-height: 1;
    }
    .del:hover { color: #e05060; background: #2a1a20 }
    .empty { color: #5050a0; text-align: center; padding: 2rem; font-size: .9rem }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <span class="lock">🔒</span>
      <h1>Encrypted Notes</h1>
      <span class="badge">AES-256-GCM · Argon2id</span>
    </header>

    <form id="form">
      <input id="inp" type="text" placeholder="Write a note…" autocomplete="off" />
      <button type="submit">Add</button>
    </form>

    <div class="notes" id="list"></div>
  </div>

  <script>
    async function load() {
      const res = await fetch("/api/notes");
      const notes = await res.json();
      const list = document.getElementById("list");
      if (notes.length === 0) {
        list.innerHTML = '<p class="empty">No notes yet. Add one above.</p>';
        return;
      }
      list.innerHTML = notes.map(n => \`
        <div class="note" id="n-\${n.id}">
          <div class="note-body">
            <div class="note-text">\${n.text}</div>
            <div class="note-time">\${new Date(n.createdAt).toLocaleString()}</div>
          </div>
          <button class="del" onclick="del('\${n.id}')" title="Delete">✕</button>
        </div>
      \`).join("");
    }

    document.getElementById("form").addEventListener("submit", async e => {
      e.preventDefault();
      const inp = document.getElementById("inp");
      const text = inp.value.trim();
      if (!text) return;
      await fetch("/api/notes", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text }),
      });
      inp.value = "";
      load();
    });

    async function del(id) {
      await fetch("/api/notes/" + id, { method: "DELETE" });
      document.getElementById("n-" + id)?.remove();
      if (!document.querySelector(".note")) load();
    }

    load();
  </script>
</body>
</html>`;

// ── router ────────────────────────────────────────────────────────────────────

function respond(res, status, body, ct = "application/json") {
  const payload = typeof body === "string" ? body : JSON.stringify(body);
  res.writeHead(status, { "content-type": ct, "content-length": Buffer.byteLength(payload) });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let raw = "";
    req.on("data", c => (raw += c));
    req.on("end", () => resolve(raw));
    req.on("error", reject);
  });
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const path = url.pathname;

  if (req.method === "GET" && path === "/") {
    return respond(res, 200, HTML, "text/html; charset=utf-8");
  }

  if (req.method === "GET" && path === "/api/notes") {
    return respond(res, 200, loadNotes());
  }

  if (req.method === "POST" && path === "/api/notes") {
    const body = await readBody(req).catch(() => "{}");
    let text;
    try { text = JSON.parse(body).text?.trim(); } catch { /* ignore */ }
    if (!text) return respond(res, 400, { error: "text required" });
    const notes = loadNotes();
    const note = { id: randomUUID(), text, createdAt: new Date().toISOString() };
    notes.unshift(note);
    saveNotes(notes);
    return respond(res, 201, note);
  }

  if (req.method === "DELETE" && path.startsWith("/api/notes/")) {
    const id = path.slice("/api/notes/".length);
    const notes = loadNotes().filter(n => n.id !== id);
    saveNotes(notes);
    return respond(res, 200, { ok: true });
  }

  return respond(res, 404, { error: "not found" });
});

server.listen(PORT, () => console.log(`Encrypted Notes running on :${PORT}`));
