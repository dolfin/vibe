mod commands;

use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "vibe", about = "Vibe Runtime packaging and development tool")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
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
    },
    /// Sign a .vibeapp package
    Sign {
        package: PathBuf,
        #[arg(long)]
        key: PathBuf,
    },
    /// Verify a signed .vibeapp package
    Verify {
        package: PathBuf,
        #[arg(long)]
        key: PathBuf,
    },
    /// Generate an Ed25519 signing keypair
    Keygen {
        #[arg(short, long, default_value = "vibe-signing")]
        output: String,
    },
    /// Import from Docker Compose (coming soon)
    ImportCompose,
    /// Inspect a .vibeapp package
    Inspect { package: PathBuf },
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init { name } => commands::init::run(&name),
        Commands::Validate { manifest } => commands::validate::run(&manifest),
        Commands::Package { manifest, output } => {
            commands::package::run(&manifest, output.as_deref())
        }
        Commands::Keygen { output } => commands::keygen::run(&output),
        Commands::Sign { package, key } => commands::sign::run(&package, &key),
        Commands::Verify { package, key } => commands::verify::run(&package, &key),
        Commands::ImportCompose => commands::import_compose::run(),
        Commands::Inspect { package } => commands::inspect::run(&package),
    }
}
