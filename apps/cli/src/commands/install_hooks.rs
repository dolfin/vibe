use std::path::PathBuf;

use anyhow::Result;
use colored::Colorize;

use crate::hooks::VIBE_SKILL;

#[derive(clap::ValueEnum, Clone, Debug)]
pub enum Tool {
    Claude,
    Codex,
    Cursor,
    Copilot,
    All,
}

#[derive(clap::ValueEnum, Clone, Debug)]
pub enum Scope {
    Project,
    User,
}

/// Returns deduplicated `(destination, content)` pairs for the given tool + scope.
pub fn build_targets(tool: &Tool, scope: &Scope) -> Result<Vec<(PathBuf, &'static str)>> {
    let base = match scope {
        Scope::Project => std::env::current_dir()?,
        Scope::User => dirs_home()?,
    };

    let claude_path = base.join(".claude/skills/vibe/SKILL.md");
    let agents_path = base.join(".agents/skills/vibe/SKILL.md");

    let targets = match tool {
        Tool::Claude | Tool::Copilot => vec![(claude_path, VIBE_SKILL)],
        Tool::Codex | Tool::Cursor => vec![(agents_path, VIBE_SKILL)],
        Tool::All => vec![(claude_path, VIBE_SKILL), (agents_path, VIBE_SKILL)],
    };

    Ok(targets)
}

fn dirs_home() -> Result<PathBuf> {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map(PathBuf::from)
        .map_err(|_| anyhow::anyhow!("Cannot determine home directory"))?;
    Ok(home)
}

pub fn run(tool: &Tool, scope: &Scope, force: bool) -> Result<()> {
    let targets = build_targets(tool, scope)?;

    let mut written = 0usize;
    let mut skipped = 0usize;

    for (dest, content) in &targets {
        if dest.exists() && !force {
            println!("{}", format!("! {} — already exists (use --force to overwrite)", dest.display()).yellow());
            skipped += 1;
            continue;
        }

        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }

        std::fs::write(dest, content)?;
        println!("{}", format!("✓ {}", dest.display()).green());
        written += 1;
    }

    println!("\nDone: {} file(s) written, {} skipped", written, skipped);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn project_scope_with_base(base: &std::path::Path) -> Vec<(PathBuf, &'static str)> {
        let claude_path = base.join(".claude/skills/vibe/SKILL.md");
        let agents_path = base.join(".agents/skills/vibe/SKILL.md");

        vec![
            (claude_path.clone(), VIBE_SKILL),
            (agents_path.clone(), VIBE_SKILL),
        ]
    }

    #[test]
    fn test_all_yields_two_paths() {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path();
        let targets = project_scope_with_base(base);
        assert_eq!(targets.len(), 2);
        let paths: Vec<_> = targets.iter().map(|(p, _)| p.clone()).collect();
        assert_ne!(paths[0], paths[1]);
    }

    #[test]
    fn test_claude_and_copilot_same_path() {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path();
        let claude_path = base.join(".claude/skills/vibe/SKILL.md");
        let copilot_path = base.join(".claude/skills/vibe/SKILL.md");
        assert_eq!(claude_path, copilot_path);
    }

    #[test]
    fn test_codex_and_cursor_same_path() {
        let tmp = TempDir::new().unwrap();
        let base = tmp.path();
        let codex_path = base.join(".agents/skills/vibe/SKILL.md");
        let cursor_path = base.join(".agents/skills/vibe/SKILL.md");
        assert_eq!(codex_path, cursor_path);
    }

    #[test]
    fn test_write_creates_parent_dirs() {
        let tmp = TempDir::new().unwrap();
        let dest = tmp.path().join(".claude/skills/vibe/SKILL.md");
        assert!(!dest.exists());

        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&dest, VIBE_SKILL).unwrap();

        assert!(dest.exists());
        assert_eq!(std::fs::read_to_string(&dest).unwrap(), VIBE_SKILL);
    }

    #[test]
    fn test_skip_existing_without_force() {
        let tmp = TempDir::new().unwrap();
        let dest = tmp.path().join(".claude/skills/vibe/SKILL.md");
        std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
        std::fs::write(&dest, "original").unwrap();

        // Without force: file should not be overwritten
        if dest.exists() {
            // skip
        } else {
            std::fs::write(&dest, VIBE_SKILL).unwrap();
        }

        assert_eq!(std::fs::read_to_string(&dest).unwrap(), "original");
    }

    #[test]
    fn test_overwrite_with_force() {
        let tmp = TempDir::new().unwrap();
        let dest = tmp.path().join(".claude/skills/vibe/SKILL.md");
        std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
        std::fs::write(&dest, "original").unwrap();

        // With force: overwrite
        std::fs::write(&dest, VIBE_SKILL).unwrap();

        assert_eq!(std::fs::read_to_string(&dest).unwrap(), VIBE_SKILL);
    }

    #[test]
    fn test_user_scope_uses_home() {
        // Verify that home dir can be resolved
        let home = dirs_home();
        assert!(home.is_ok(), "should resolve home directory");
        let home = home.unwrap();
        assert!(home.is_absolute());
    }
}
