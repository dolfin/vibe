use clap::Parser;
use vibe_cli::{Cli, Commands, commands};

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Init { name } => commands::init::run(&name),
        Commands::Validate { manifest } => commands::validate::run(&manifest),
        Commands::Package {
            manifest,
            output,
            seed_data,
            password,
            password_file,
        } => commands::package::run(
            &manifest,
            output.as_deref(),
            seed_data.as_deref(),
            password.as_deref(),
            password_file.as_deref(),
        ),
        Commands::Keygen { output } => commands::keygen::run(&output),
        Commands::Sign {
            package,
            key,
            password,
            password_file,
        } => commands::sign::run(&package, &key, password.as_deref(), password_file.as_deref()),
        Commands::Verify {
            package,
            key,
            password,
            password_file,
        } => commands::verify::run(&package, &key, password.as_deref(), password_file.as_deref()),
        Commands::ImportCompose => commands::import_compose::run(),
        Commands::Inspect {
            package,
            password,
            password_file,
        } => commands::inspect::run(&package, password.as_deref(), password_file.as_deref()),
        Commands::Revert {
            package,
            password,
            password_file,
        } => commands::revert::run(&package, password.as_deref(), password_file.as_deref()),
        Commands::InstallHooks { tool, scope, force } => {
            commands::install_hooks::run(&tool, &scope, force)
        }
        Commands::Licenses => commands::licenses::run(),
    }
}
