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

    fs::create_dir_all(project_dir.join("assets"))
        .with_context(|| "Failed to create assets directory")?;

    let manifest_content = format!(
        r#"kind: vibe.app/v1
id: com.example.{name}
name: {display_name}
version: 0.1.0

runtime:
  mode: native

services:
  - name: app
    image: alpine:latest
    command:
      - echo
      - "Hello from {display_name}!"
    ports:
      - container: 8080
"#,
        name = name.replace('-', "."),
        display_name = name
    );

    fs::write(project_dir.join("vibe.yaml"), manifest_content)
        .with_context(|| "Failed to write vibe.yaml")?;

    println!(
        "{} Created new Vibe project '{}'",
        "✓".green().bold(),
        name.cyan()
    );
    println!("  {} {}/vibe.yaml", "→".dimmed(), name);
    println!("  {} {}/assets/", "→".dimmed(), name);
    println!();
    println!(
        "Next steps: edit {} and run {}",
        format!("{}/vibe.yaml", name).cyan(),
        "vibe validate".cyan()
    );

    Ok(())
}
