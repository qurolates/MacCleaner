//! mac-cleaner-core — Rust CLI backend for MacCleaner.app
//!
//! All output is strict JSON on stdout, consumed by the SwiftUI wrapper.

mod commands;
mod model;
mod scanner;
mod streaming;

use clap::{Parser, Subcommand};

use crate::commands::{browser_caches, delete_paths, docker, junk, large_files, login_items, node_modules, old_installers, sweep, uninstall, xcode};
use crate::model::CliResponse;

#[derive(Parser, Debug)]
#[command(
    name = "mac-cleaner-core",
    version,
    about = "Rust core for the MacCleaner macOS utility",
    long_about = None
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,

    /// Stream each file as NDJSON as it's discovered (for real-time progress)
    #[arg(long, global = true, default_value_t = false)]
    stream: bool,
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Scan or clean ~/Library/Caches, ~/Library/Logs and ~/.Trash
    JunkClean {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Scan or clean Xcode build artifacts (DerivedData, Archives, Simulators, caches)
    XcodeClean {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Find and optionally remove browser cache directories
    BrowserCaches {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Find all node_modules directories under $HOME
    NodeModules {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Find files larger than a threshold under $HOME (default 100 MB)
    LargeFiles {
        #[arg(long, default_value_t = large_files::default_min_bytes())]
        min_bytes: u64,
        #[arg(long, default_value_t = large_files::default_max_depth())]
        max_depth: usize,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Uninstall the given .app bundle and associated support files
    Uninstall {
        path: String,
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Delete an explicit list of paths (used by SwiftUI checkbox selection)
    DeletePaths {
        paths: Vec<String>,
    },

    /// Find old .dmg/.pkg installers in ~/Downloads
    OldInstallers {
        #[arg(long, default_value_t = old_installers::default_max_age_days())]
        max_age_days: u64,
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Find broken symlinks and .DS_Store files under $HOME
    Sweep {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// Scan Docker VM disk images
    DockerClean {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },

    /// List LaunchAgents and LaunchDaemons
    LoginItems {
        #[arg(long, default_value_t = true)]
        dry_run: bool,
        #[arg(long, default_value_t = false)]
        execute: bool,
    },
}

fn main() {
    let cli = Cli::parse();
    let stream = cli.stream;

    let response: CliResponse = match cli.command {
        Commands::JunkClean    { execute, .. }       => junk::run(execute, stream),
        Commands::XcodeClean   { execute, .. }       => xcode::run(execute, stream),
        Commands::BrowserCaches { execute, .. }      => browser_caches::run(execute, stream),
        Commands::NodeModules  { execute, .. }       => node_modules::run(execute, stream),
        Commands::LargeFiles   { min_bytes, max_depth, execute } => large_files::run(min_bytes, max_depth, execute, stream),
        Commands::Uninstall    { path, execute, .. } => uninstall::run(&path, execute, stream),
        Commands::DeletePaths  { paths }             => delete_paths::run(&paths, stream),
        Commands::OldInstallers { max_age_days, execute, .. } => old_installers::run(max_age_days, execute, stream),
        Commands::Sweep        { execute, .. }       => sweep::run(execute, stream),
        Commands::DockerClean  { execute, .. }       => docker::run(execute, stream),
        Commands::LoginItems   { execute, .. }       => login_items::run(execute, stream),
    };

    match serde_json::to_string(&response) {
        Ok(s) => println!("{s}"),
        Err(e) => println!(
            "{{\"status\":\"error\",\"operation\":\"serialize\",\"message\":\"{}\"}}",
            e.to_string().replace('"', "'")
        ),
    }
}
