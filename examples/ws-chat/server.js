const http = require("http");
const { WebSocketServer } = require("ws");

const MAX_HISTORY = 50;
const messages = [];
const clients = new Set();

function broadcast(obj) {
  const payload = JSON.stringify(obj);
  for (const ws of clients) {
    if (ws.readyState === 1) ws.send(payload);
  }
}

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Live Chat</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #f0f2f5;
      height: 100dvh;
      display: flex;
      flex-direction: column;
    }
    header {
      background: #fff;
      border-bottom: 1px solid #e0e0e0;
      padding: 0.75rem 1.25rem;
      display: flex;
      align-items: center;
      gap: 0.75rem;
    }
    header h1 { font-size: 1rem; font-weight: 600; color: #1a1a1a; }
    .badge {
      background: #e8f4ff;
      color: #0066cc;
      padding: 0.15rem 0.5rem;
      border-radius: 10px;
      font-size: 0.7rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.03em;
    }
    .status {
      margin-left: auto;
      display: flex;
      align-items: center;
      gap: 0.4rem;
      font-size: 0.8rem;
      color: #666;
    }
    .dot {
      width: 8px; height: 8px;
      border-radius: 50%;
      background: #ccc;
      transition: background 0.3s;
    }
    .dot.connected { background: #22c55e; }
    .dot.error     { background: #ef4444; }

    #messages {
      flex: 1;
      overflow-y: auto;
      padding: 1rem;
      display: flex;
      flex-direction: column;
      gap: 0.5rem;
    }
    .msg {
      max-width: 70%;
      padding: 0.55rem 0.85rem;
      border-radius: 14px;
      font-size: 0.9rem;
      line-height: 1.4;
      word-break: break-word;
    }
    .msg.incoming { background: #fff; border: 1px solid #e8e8e8; align-self: flex-start; }
    .msg.outgoing { background: #0066cc; color: #fff; align-self: flex-end; }
    .msg .meta { font-size: 0.68rem; opacity: 0.55; margin-top: 0.2rem; }

    .notice {
      align-self: center;
      text-align: center;
      color: #888;
      font-size: 0.82rem;
      padding: 0.4rem 0.8rem;
      background: #fff;
      border: 1px solid #e8e8e8;
      border-radius: 999px;
    }

    #gate {
      flex: 1;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 2rem;
    }
    .gate-card {
      background: #fff;
      border-radius: 16px;
      padding: 2rem 2.5rem;
      text-align: center;
      max-width: 380px;
      box-shadow: 0 2px 16px rgba(0,0,0,0.08);
    }
    .gate-icon { font-size: 2.5rem; margin-bottom: 1rem; }
    .gate-card h2 { font-size: 1.1rem; color: #1a1a1a; margin-bottom: 0.5rem; }
    .gate-card p { font-size: 0.85rem; color: #666; line-height: 1.5; }
    .gate-card kbd {
      background: #f0f2f5; border: 1px solid #d0d0d0;
      border-radius: 4px; padding: 0.1rem 0.4rem;
      font-size: 0.8rem; font-family: inherit;
    }

    footer {
      background: #fff;
      border-top: 1px solid #e0e0e0;
      padding: 0.75rem 1rem;
      display: flex;
      gap: 0.5rem;
    }
    footer input {
      flex: 1;
      padding: 0.55rem 0.85rem;
      border: 1px solid #ddd;
      border-radius: 999px;
      font-size: 0.9rem;
      outline: none;
      transition: border-color 0.2s;
    }
    footer input:focus { border-color: #0066cc; }
    footer input:disabled { background: #f5f5f5; color: #aaa; }
    footer button {
      padding: 0.55rem 1.1rem;
      background: #0066cc;
      color: #fff;
      border: none;
      border-radius: 999px;
      font-size: 0.9rem;
      cursor: pointer;
      transition: background 0.2s;
    }
    footer button:hover:not(:disabled) { background: #0052a3; }
    footer button:disabled { background: #ccc; cursor: default; }
  </style>
</head>
<body>
  <header>
    <h1>Live Chat</h1>
    <span class="badge">WebSocket</span>
    <div class="status">
      <div class="dot" id="dot"></div>
      <span id="status-text">—</span>
    </div>
  </header>

  <!-- Shown in internal (vibe-app://) mode where WS isn't available -->
  <div id="gate" style="display:none">
    <div class="gate-card">
      <div class="gate-icon">🔌</div>
      <h2>WebSockets need Expose mode</h2>
      <p>
        Tap <kbd>ⓘ</kbd> in the toolbar and enable
        <strong>Expose to machine</strong>, then open the
        shown URL in your browser.
      </p>
    </div>
  </div>

  <!-- Shown in exposed (http://) mode -->
  <div id="messages" style="display:none"></div>
  <footer id="footer" style="display:none">
    <input id="input" placeholder="Type a message…" maxlength="500" disabled>
    <button id="send" disabled>Send</button>
  </footer>

  <script>
    const isInternal = location.protocol === 'vibe-app:';

    if (isInternal) {
      document.getElementById('gate').style.display = 'flex';
      document.getElementById('status-text').textContent = 'internal mode';
    } else {
      document.getElementById('messages').style.display = 'flex';
      document.getElementById('footer').style.display = 'flex';
      startChat();
    }

    // Deterministic colour from a string (for per-tab user colours)
    function hue(str) {
      let h = 0;
      for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) >>> 0;
      return h % 360;
    }

    // Assign a random user tag once per page load
    const TAG = Math.random().toString(36).slice(2, 6).toUpperCase();

    function startChat() {
      const dot  = document.getElementById('dot');
      const statusText = document.getElementById('status-text');
      const messagesEl = document.getElementById('messages');
      const input = document.getElementById('input');
      const sendBtn = document.getElementById('send');

      let ws;

      function setStatus(state, label) {
        dot.className = 'dot ' + state;
        statusText.textContent = label;
      }

      function addNotice(text) {
        const el = document.createElement('div');
        el.className = 'notice';
        el.textContent = text;
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
      }

      function addMessage(msg, own) {
        const el = document.createElement('div');
        el.className = 'msg ' + (own ? 'outgoing' : 'incoming');
        const time = new Date(msg.time).toLocaleTimeString([], {hour:'2-digit', minute:'2-digit'});
        const color = own ? 'rgba(255,255,255,0.7)' : 'hsl(' + hue(msg.tag) + ',60%,45%)';
        el.innerHTML =
          '<span style="color:' + color + ';font-weight:600;font-size:0.75rem">' + msg.tag + '</span> ' +
          escHtml(msg.text) +
          '<div class="meta">' + time + '</div>';
        messagesEl.appendChild(el);
        messagesEl.scrollTop = messagesEl.scrollHeight;
      }

      function escHtml(s) {
        return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
      }

      function connect() {
        setStatus('', 'connecting…');
        ws = new WebSocket('ws://' + location.host + '/ws');

        ws.onopen = () => {
          setStatus('connected', '1 connected');
          input.disabled = false;
          sendBtn.disabled = false;
          input.focus();
        };

        ws.onmessage = (e) => {
          const msg = JSON.parse(e.data);
          if (msg.type === 'init') {
            for (const m of msg.messages) addMessage(m, m.tag === TAG);
            setStatus('connected', msg.count + ' connected');
          } else if (msg.type === 'chat') {
            addMessage(msg, msg.tag === TAG);
          } else if (msg.type === 'count') {
            setStatus('connected', msg.count + ' connected');
          }
        };

        ws.onclose = () => {
          setStatus('error', 'disconnected');
          input.disabled = true;
          sendBtn.disabled = true;
          addNotice('Disconnected — reconnecting in 3s…');
          setTimeout(connect, 3000);
        };

        ws.onerror = () => {
          setStatus('error', 'error');
        };
      }

      function send() {
        const text = input.value.trim();
        if (!text || ws?.readyState !== 1) return;
        ws.send(JSON.stringify({ type: 'chat', text, tag: TAG }));
        input.value = '';
      }

      sendBtn.onclick = send;
      input.onkeydown = (e) => { if (e.key === 'Enter') send(); };

      connect();
    }
  </script>
</body>
</html>`;

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/") {
    res.setHeader("Content-Type", "text/html");
    res.end(HTML);
  } else {
    res.statusCode = 404;
    res.end();
  }
});

const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (ws) => {
  clients.add(ws);

  ws.send(JSON.stringify({ type: "init", messages, count: clients.size }));
  broadcast({ type: "count", count: clients.size });

  ws.on("message", (data) => {
    try {
      const msg = JSON.parse(data.toString());
      if (msg.type === "chat" && typeof msg.text === "string" && msg.text.trim()) {
        const entry = {
          type: "chat",
          tag: (typeof msg.tag === "string" ? msg.tag.slice(0, 8) : "anon").replace(/[^a-z0-9]/gi, "").toUpperCase() || "ANON",
          text: msg.text.trim().slice(0, 500),
          time: new Date().toISOString(),
        };
        messages.push(entry);
        if (messages.length > MAX_HISTORY) messages.shift();
        broadcast(entry);
      }
    } catch (_) {}
  });

  ws.on("close", () => {
    clients.delete(ws);
    broadcast({ type: "count", count: clients.size });
  });
});

server.listen(3000, () => console.log("Chat server on :3000"));
