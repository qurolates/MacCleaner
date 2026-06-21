//! `xcode-clean` subcommand: scans (and optionally deletes) Xcode build
//! artifacts — DerivedData, Archives, iOS Simulators, and Xcode caches.

use std::path::PathBuf;

use crate::model::{CliError, CliResponse};
use crate::scanner::{delete_path, home_subdir, list_top_level};
use crate::streaming;

/// Top-level directories that Xcode uses for build artifacts.
/// Each is listed as `relative/to/home`.
const XCODE_DIRS: &[&str] = &[
    "Library/Developer/Xcode/DerivedData",
    "Library/Developer/Xcode/Archives",
    "Library/Developer/CoreSimulator/Devices",
    "Library/Caches/com.apple.dt.Xcode",
];

pub fn run(execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "xcode-clean" } else { "xcode-scan" };
    let mut response = CliResponse::new(operation, execute);

    for rel in XCODE_DIRS {
        let dir: PathBuf = match home_subdir(rel) {
            Some(p) => p,
            None => {
                response.errors.push(CliError {
                    path: (*rel).to_string(),
                    message: "Could not resolve $HOME".into(),
                });
                continue;
            }
        };
        let prev_len = response.files.len();
        list_top_level(&dir, &mut response.files, &mut response.errors);
        if stream {
            for file in &response.files[prev_len..] {
                streaming::emit_file(file);
            }
        }
    }

    if execute {
        for entry in response.files.iter_mut() {
            match delete_path(std::path::Path::new(&entry.path)) {
                Ok(()) => {
                    entry.deleted = true;
                    if stream { streaming::emit_file(entry); }
                }
                Err(err) => response.errors.push(CliError {
                    path: entry.path.clone(),
                    message: err.to_string(),
                }),
            }
        }
    }

    let finalized = response.finalize();
    if stream { streaming::emit_done(finalized.files.len(), finalized.total_bytes); }
    finalized
}
