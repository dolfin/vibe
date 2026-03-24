pub mod commands;
pub mod crypto;
pub mod hooks;

#[cfg(test)]
pub(crate) mod test_helpers;

use std::path::PathBuf;

use clap::{CommandFactory, Parser, Subcommand};

#[derive(Parser)]
#[command(name = "vibe", about = "Vibe Runtime packaging and development tool", version)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand)]
pub enum Commands {
    /// Initialize a new Vibe application project
    Init { name: String },
    /// Validate a vibe.yaml manifest
    Validate {
        #[arg(default_value = "vibe.yaml")]
        manifest: PathBuf,
    },
    /// Package a Vibe application into a .vibeapp archive
    Package {
        #[arg(default_value = "vibe.yaml")]
        manifest: PathBuf,
        #[arg(short, long)]
        output: Option<PathBuf>,
        /// Directory of pre-populated seed data to embed as initial state.
        /// Each subdirectory becomes a signed _vibe_initial_state/<name>.tar.gz entry.
        #[arg(long)]
        seed_data: Option<PathBuf>,
        /// Encrypt the output package with this password (avoid; visible in shell history)
        #[arg(long)]
        password: Option<String>,
        /// Read encryption password from this file
        #[arg(long)]
        password_file: Option<PathBuf>,
    },
    /// Sign a .vibeapp package
    Sign {
        package: PathBuf,
        #[arg(long)]
        key: PathBuf,
        /// Password for encrypted package (avoid; visible in shell history)
        #[arg(long)]
        password: Option<String>,
        /// Read password from this file
        #[arg(long)]
        password_file: Option<PathBuf>,
    },
    /// Verify a signed .vibeapp package
    Verify {
        package: PathBuf,
        #[arg(long)]
        key: PathBuf,
        /// Password for encrypted package (avoid; visible in shell history)
        #[arg(long)]
        password: Option<String>,
        /// Read password from this file
        #[arg(long)]
        password_file: Option<PathBuf>,
    },
    /// Generate an Ed25519 signing keypair
    Keygen {
        #[arg(short, long, default_value = "vibe-signing")]
        output: String,
    },
    /// Import from Docker Compose (coming soon)
    ImportCompose,
    /// Inspect a .vibeapp package
    Inspect {
        package: PathBuf,
        /// Password for encrypted package (avoid; visible in shell history)
        #[arg(long)]
        password: Option<String>,
        /// Read password from this file
        #[arg(long)]
        password_file: Option<PathBuf>,
    },
    /// Strip saved user state (_vibe_state/*) from a .vibeapp, restoring original signed content
    Revert {
        package: PathBuf,
        /// Password for encrypted package (avoid; visible in shell history)
        #[arg(long)]
        password: Option<String>,
        /// Read password from this file
        #[arg(long)]
        password_file: Option<PathBuf>,
    },
    /// Install AI coding assistant skills for Vibe development (Claude, Codex, Cursor, Copilot)
    InstallHooks {
        #[arg(long, value_enum, default_value_t = commands::install_hooks::Tool::All)]
        tool: commands::install_hooks::Tool,
        #[arg(long, value_enum, default_value_t = commands::install_hooks::Scope::Project)]
        scope: commands::install_hooks::Scope,
        #[arg(long)]
        force: bool,
    },
    /// Print open-source licenses for all bundled dependencies
    Licenses,
}

pub fn build_cli() -> clap::Command {
    Cli::command()
}
