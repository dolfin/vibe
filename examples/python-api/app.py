"""Simple Python API - Vibe demo."""

import json
import os
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

API_SECRET = os.environ.get("API_SECRET", "dev-secret")

notes = []

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Python API</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 500px; margin: 2rem auto; padding: 0 1rem; color: #333; }
    h1 { color: #306998; }
    form { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
    input { flex: 1; padding: 0.5rem; border: 1px solid #ccc; border-radius: 4px; font-size: 1rem; }
    button { padding: 0.5rem 1rem; background: #306998; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; }
    button:hover { background: #24527b; }
    .note { padding: 0.75rem; margin-bottom: 0.5rem; background: #f8f9fa; border-radius: 6px; border-left: 3px solid #306998; }
    .note .time { font-size: 0.75rem; color: #999; }
    .badge { background: #e8f0fe; color: #306998; padding: 0.2rem 0.5rem; border-radius: 12px; font-size: 0.75rem; }
    .status { padding: 0.5rem; background: #e8f0fe; border-radius: 4px; font-size: 0.85rem; margin-bottom: 1rem; }
  </style>
</head>
<body>
  <h1>Python API <span class="badge">Vibe</span></h1>
  <div class="status" id="status">Loading...</div>
  <form onsubmit="addNote(event)">
    <input id="input" placeholder="Write a note..." autofocus>
    <button type="submit">Save</button>
  </form>
  <div id="notes"></div>
  <script>
    async function loadStatus() {
      const res = await fetch("/api/status");
      const data = await res.json();
      document.getElementById("status").textContent = "Service: " + data.service + " | Notes: " + data.note_count + " | Uptime: " + data.uptime_seconds + "s";
    }
    async function loadNotes() {
      const res = await fetch("/api/notes");
      const data = await res.json();
      document.getElementById("notes").innerHTML = data.map(n =>
        '<div class="note"><div>' + n.text + '</div><div class="time">' + n.created_at + '</div></div>'
      ).join("");
    }
    async function addNote(e) {
      e.preventDefault();
      const input = document.getElementById("input");
      if (!input.value.trim()) return;
      await fetch("/api/notes", { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({text: input.value.trim()}) });
      input.value = "";
      loadNotes();
      loadStatus();
    }
    loadStatus();
    loadNotes();
  </script>
</body>
</html>"""

start_time = time.time()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(HTML.encode())
        elif self.path == "/api/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "status": "ok",
                "service": "python-api",
                "note_count": len(notes),
                "uptime_seconds": int(time.time() - start_time),
            }).encode())
        elif self.path == "/api/notes":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(notes).encode())
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "not found"}).encode())

    def do_POST(self):
        if self.path == "/api/notes":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length)) if length else {}
            note = {
                "id": len(notes) + 1,
                "text": body.get("text", ""),
                "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            }
            notes.append(note)
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(note).encode())
        else:
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": "not found"}).encode())

    def log_message(self, format, *args):
        print(f"[python-api] {args[0]}")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8000), Handler)
    print("Python API running on port 8000")
    server.serve_forever()
