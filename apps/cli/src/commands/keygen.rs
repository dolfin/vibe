use std::fs;
use std::path::Path;

use anyhow::{Context, Result};
use colored::Colorize;

use vibe_signing::{generate_keypair, signing_key_to_bytes, verifying_key_to_bytes};

pub fn run(output: &str) -> Result<()> {
    let (signing_key, verifying_key) = generate_keypair();

    let sk_bytes = signing_key_to_bytes(&signing_key);
    let vk_bytes = verifying_key_to_bytes(&verifying_key);

    let key_path = format!("{}.key", output);
    let pub_path = format!("{}.pub", output);

    // Don't overwrite existing keys
    if Path::new(&key_path).exists() {
        anyhow::bail!("Key file '{}' already exists", key_path);
    }
    if Path::new(&pub_path).exists() {
        anyhow::bail!("Public key file '{}' already exists", pub_path);
    }

    fs::write(&key_path, sk_bytes)
        .with_context(|| format!("Failed to write signing key to '{}'", key_path))?;
    fs::write(&pub_path, vk_bytes)
        .with_context(|| format!("Failed to write verifying key to '{}'", pub_path))?;

    // Print public key hex to stdout
    let pub_hex: String = vk_bytes.iter().map(|b| format!("{:02x}", b)).collect();

    println!("{} Keypair generated!", "✓".green().bold());
    println!("  {} {}", "Signing key:".dimmed(), key_path);
    println!("  {} {}", "Public key:".dimmed(), pub_path);
    println!("  {} {}", "Public key hex:".dimmed(), pub_hex.cyan());

    Ok(())
}
