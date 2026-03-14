const http = require("http");

const todos = [];

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Todo App</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; max-width: 500px; margin: 2rem auto; padding: 0 1rem; color: #333; }
    h1 { color: #0066cc; }
    form { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
    input { flex: 1; padding: 0.5rem; border: 1px solid #ccc; border-radius: 4px; font-size: 1rem; }
    button { padding: 0.5rem 1rem; background: #0066cc; color: white; border: none; border-radius: 4px; cursor: pointer; font-size: 1rem; }
    button:hover { background: #0052a3; }
    ul { list-style: none; padding: 0; }
    li { padding: 0.5rem 0; border-bottom: 1px solid #eee; display: flex; align-items: center; gap: 0.5rem; }
    .done { text-decoration: line-through; color: #999; }
    .toggle { cursor: pointer; font-size: 1.2rem; }
    .badge { background: #e8f4ff; color: #0066cc; padding: 0.2rem 0.5rem; border-radius: 12px; font-size: 0.75rem; }
  </style>
</head>
<body>
  <h1>Todo App <span class="badge">Vibe</span></h1>
  <form onsubmit="addTodo(event)">
    <input id="input" placeholder="What needs to be done?" autofocus>
    <button type="submit">Add</button>
  </form>
  <ul id="list"></ul>
  <script>
    async function load() {
      const res = await fetch("/todos");
      const todos = await res.json();
      const list = document.getElementById("list");
      list.innerHTML = todos.map(t =>
        '<li class="' + (t.done ? "done" : "") + '">' +
        '<span class="toggle" onclick="toggle(' + t.id + ')">' + (t.done ? "\\u2611" : "\\u2610") + '</span> ' +
        t.title + '</li>'
      ).join("");
    }
    async function addTodo(e) {
      e.preventDefault();
      const input = document.getElementById("input");
      if (!input.value.trim()) return;
      await fetch("/todos", { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({title: input.value.trim()}) });
      input.value = "";
      load();
    }
    async function toggle(id) {
      await fetch("/todos/" + id + "/toggle", { method: "PATCH" });
      load();
    }
    load();
  </script>
</body>
</html>`;

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/") {
    res.setHeader("Content-Type", "text/html");
    res.end(HTML);
  } else if (req.method === "GET" && req.url === "/todos") {
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify(todos));
  } else if (req.method === "POST" && req.url === "/todos") {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const todo = JSON.parse(body);
      todo.id = todos.length + 1;
      todo.done = false;
      todos.push(todo);
      res.setHeader("Content-Type", "application/json");
      res.statusCode = 201;
      res.end(JSON.stringify(todo));
    });
  } else if (req.method === "PATCH" && req.url.startsWith("/todos/") && req.url.endsWith("/toggle")) {
    const id = parseInt(req.url.split("/")[2]);
    const todo = todos.find((t) => t.id === id);
    if (todo) {
      todo.done = !todo.done;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify(todo));
    } else {
      res.statusCode = 404;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify({ error: "Not found" }));
    }
  } else {
    res.statusCode = 404;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ error: "Not found" }));
  }
});

server.listen(3000, () => {
  console.log("Todo API running on port 3000");
});
