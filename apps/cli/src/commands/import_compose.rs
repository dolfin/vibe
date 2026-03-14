use anyhow::Result;
use colored::Colorize;

pub fn run() -> Result<()> {
    println!("{} Compose import coming soon", "i".blue().bold());
    println!(
        "  This command will convert a {} into a {}.",
        "docker-compose.yml".cyan(),
        "vibe.yaml".cyan()
    );
    Ok(())
}
