use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;

pub fn run(name: &str) -> Result<()> {
    let project_dir = Path::new(name);

    if project_dir.exists() {
        anyhow::bail!("Directory '{}' already exists", name);
    }

    fs::create_dir_all(project_dir)
        .with_context(|| format!("Failed to create directory '{}'", name))?;

    let manifest_content = format!(
        r#"kind: vibe.app/v1
id: com.example.{id}
name: {display_name}
version: 0.1.0

services:
  - name: web
    image: nginx:alpine
    command: ["sh", "-c", "cp -r /app/. /usr/share/nginx/html && nginx -g 'daemon off;'"]
    ports:
      - container: 80
"#,
        id = name.replace('-', "."),
        display_name = name
    );

    let index_html = format!(
        r#"<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>{name}</title>
  <style>
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}

    body {{
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      background: #0f0f11;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: #e8e8ed;
    }}

    .card {{
      text-align: center;
      padding: 3rem 4rem;
      background: #1c1c1e;
      border: 1px solid #2c2c2e;
      border-radius: 20px;
      box-shadow: 0 24px 64px rgba(0, 0, 0, 0.5);
      max-width: 480px;
      width: 90%;
    }}

    .badge {{
      display: inline-block;
      font-size: 0.7rem;
      font-weight: 600;
      letter-spacing: 0.12em;
      text-transform: uppercase;
      color: #636366;
      margin-bottom: 1.5rem;
    }}

    h1 {{
      font-size: 2.25rem;
      font-weight: 700;
      letter-spacing: -0.02em;
      margin-bottom: 0.75rem;
      background: linear-gradient(135deg, #ffffff 0%, #adadb8 100%);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
    }}

    p {{
      font-size: 1rem;
      color: #8e8e93;
      line-height: 1.6;
      margin-bottom: 2rem;
    }}

    .pill {{
      display: inline-flex;
      align-items: center;
      gap: 0.4rem;
      padding: 0.4rem 0.9rem;
      background: #2c2c2e;
      border: 1px solid #3a3a3c;
      border-radius: 100px;
      font-size: 0.8rem;
      color: #8e8e93;
    }}

    .dot {{
      width: 6px;
      height: 6px;
      border-radius: 50%;
      background: #30d158;
      box-shadow: 0 0 6px #30d158;
      animation: pulse 2s ease-in-out infinite;
    }}

    @keyframes pulse {{
      0%, 100% {{ opacity: 1; }}
      50% {{ opacity: 0.4; }}
    }}
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">Vibe App</div>
    <h1>{name}</h1>
    <p>Your app is running. Edit <code>index.html</code> to get started.</p>
    <div class="pill">
      <span class="dot"></span>
      Running on Vibe
    </div>
  </div>
</body>
</html>
"#,
        name = name
    );

    let vibeignore_content = r#"# .vibeignore — files and directories excluded from .vibeapp packages.
#
# Syntax: one pattern per line.
# - A pattern without '/' matches any file or directory with that name at any depth.
# - A pattern with '/' is matched against the path relative to this directory.
# - * matches any sequence of characters; ? matches any single character.
# - Lines starting with # are comments.
#
# node_modules/ and target/ are always excluded by default (no entry needed).

# Build outputs — uncomment if you don't want these bundled:
# dist/
# build/
# out/

# Python
__pycache__/
*.pyc

# Logs
*.log
"#;

    fs::write(project_dir.join("vibe.yaml"), manifest_content)
        .with_context(|| "Failed to write vibe.yaml")?;
    fs::write(project_dir.join("index.html"), index_html)
        .with_context(|| "Failed to write index.html")?;
    fs::write(project_dir.join(".vibeignore"), vibeignore_content)
        .with_context(|| "Failed to write .vibeignore")?;

    println!(
        "{} Created new Vibe project '{}'",
        "✓".green().bold(),
        name.cyan()
    );
    println!("  {} {}/vibe.yaml", "→".dimmed(), name);
    println!("  {} {}/index.html", "→".dimmed(), name);
    println!("  {} {}/.vibeignore", "→".dimmed(), name);
    println!();
    println!(
        "Next steps: edit {} and run {}",
        format!("{}/index.html", name).cyan(),
        format!("vibe package {}/vibe.yaml", name).cyan()
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use tempfile::tempdir;

    static CWD_LOCK: Mutex<()> = Mutex::new(());

    fn run_in_dir<F: FnOnce()>(dir: &std::path::Path, f: F) {
        let _guard = CWD_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let orig = std::env::current_dir().unwrap();
        std::env::set_current_dir(dir).unwrap();
        f();
        std::env::set_current_dir(orig).unwrap();
    }

    #[test]
    fn creates_three_files() {
        let dir = tempdir().unwrap();
        run_in_dir(dir.path(), || {
            super::run("myapp").unwrap();
            assert!(dir.path().join("myapp/vibe.yaml").exists());
            assert!(dir.path().join("myapp/index.html").exists());
            assert!(dir.path().join("myapp/.vibeignore").exists());
        });
    }

    #[test]
    fn vibe_yaml_contains_id() {
        let dir = tempdir().unwrap();
        run_in_dir(dir.path(), || {
            super::run("my-app").unwrap();
            let yaml = std::fs::read_to_string(dir.path().join("my-app/vibe.yaml")).unwrap();
            assert!(yaml.contains("id: com.example.my.app"), "got: {yaml}");
        });
    }

    #[test]
    fn vibe_yaml_contains_name() {
        let dir = tempdir().unwrap();
        run_in_dir(dir.path(), || {
            super::run("coolapp").unwrap();
            let yaml = std::fs::read_to_string(dir.path().join("coolapp/vibe.yaml")).unwrap();
            assert!(yaml.contains("name: coolapp"), "got: {yaml}");
        });
    }

    #[test]
    fn index_html_contains_name() {
        let dir = tempdir().unwrap();
        run_in_dir(dir.path(), || {
            super::run("helloworld").unwrap();
            let html = std::fs::read_to_string(dir.path().join("helloworld/index.html")).unwrap();
            assert!(html.contains("<title>helloworld</title>"), "got: {html}");
            assert!(html.contains(">helloworld<"), "got: {html}");
        });
    }

    #[test]
    fn vibeignore_has_comment_header() {
        let dir = tempdir().unwrap();
        run_in_dir(dir.path(), || {
            super::run("testapp").unwrap();
            let content = std::fs::read_to_string(dir.path().join("testapp/.vibeignore")).unwrap();
            assert!(content.starts_with("# .vibeignore"), "got: {content}");
        });
    }

    #[test]
    fn fails_if_directory_exists() {
        let dir = tempdir().unwrap();
        run_in_dir(dir.path(), || {
            std::fs::create_dir(dir.path().join("existing")).unwrap();
            let result = super::run("existing");
            assert!(result.is_err());
            let msg = format!("{}", result.unwrap_err());
            assert!(msg.contains("already exists"), "got: {msg}");
        });
    }

    #[test]
    fn multi_hyphen_conversion() {
        let dir = tempdir().unwrap();
        run_in_dir(dir.path(), || {
            super::run("my-cool-app").unwrap();
            let yaml = std::fs::read_to_string(dir.path().join("my-cool-app/vibe.yaml")).unwrap();
            assert!(yaml.contains("id: com.example.my.cool.app"), "got: {yaml}");
        });
    }
}
