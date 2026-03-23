fn main() -> anyhow::Result<()> {
    let cmd = vibe_cli::build_cli();
    let man = clap_mangen::Man::new(cmd);
    std::fs::create_dir_all("man")?;
    let mut f = std::fs::File::create("man/vibe.1")?;
    man.render(&mut f)?;
    println!("Written: man/vibe.1");
    Ok(())
}
