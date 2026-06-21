//! `login-items` subcommand: list LaunchAgents and LaunchDaemons,
//! and optionally disable them by renaming the .plist file.

use crate::model::{CliError, CliResponse, FileEntry};
use crate::scanner::home_subdir;
use crate::streaming;

const LAUNCH_AGENTS: &[&str] = &[
    "Library/LaunchAgents",
];
const SYSTEM_AGENTS: &[&str] = &[
    "/Library/LaunchAgents",
    "/Library/LaunchDaemons",
];

pub fn run(execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "login-items-disable" } else { "login-items-scan" };
    let mut response = CliResponse::new(operation, execute);

    for rel in LAUNCH_AGENTS {
        if let Some(dir) = home_subdir(rel) {
            collect_plists(&dir, &mut response.files, &mut response.errors, stream);
        }
    }

    for path_str in SYSTEM_AGENTS {
        let dir = std::path::PathBuf::from(path_str);
        collect_plists(&dir, &mut response.files, &mut response.errors, stream);
    }

    if execute {
        for entry in response.files.iter_mut() {
            let original = std::path::Path::new(&entry.path);
            let disabled = format!("{}.disabled", entry.path);
            let disabled_path = std::path::Path::new(&disabled);
            match std::fs::rename(original, disabled_path) {
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

fn collect_plists(
    dir: &std::path::Path,
    files: &mut Vec<FileEntry>,
    errors: &mut Vec<CliError>,
    stream: bool,
) {
    if !dir.exists() {
        return;
    }

    let read_dir = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(err) => {
            errors.push(CliError {
                path: dir.display().to_string(),
                message: err.to_string(),
            });
            return;
        }
    };

    for entry in read_dir {
        let entry = match entry {
            Ok(e) => e,
            Err(err) => {
                errors.push(CliError {
                    path: dir.display().to_string(),
                    message: err.to_string(),
                });
                continue;
            }
        };

        let path = entry.path();
        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");

        if ext == "plist" && !path.to_string_lossy().ends_with(".plist.disabled") {
            let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
            let file = FileEntry {
                path: path.display().to_string(),
                size_bytes: size,
                is_dir: false,
                deleted: false,
            };
            if stream { streaming::emit_file(&file); }
            files.push(file);
        }
    }
}
