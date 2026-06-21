//! `old-installers` subcommand: find `.dmg` and `.pkg` files in `~/Downloads`
//! older than a configurable age (default 30 days).

use std::time::{SystemTime, UNIX_EPOCH};

use walkdir::WalkDir;

use crate::model::{CliError, CliResponse, FileEntry};
use crate::scanner::{delete_path, home_subdir};
use crate::streaming;

const DEFAULT_MAX_AGE_DAYS: u64 = 7;

pub fn run(max_age_days: u64, execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "old-installers-clean" } else { "old-installers-scan" };
    let mut response = CliResponse::new(operation, execute);

    let downloads = match home_subdir("Downloads") {
        Some(p) => p,
        None => {
            response.errors.push(CliError {
                path: "~/Downloads".into(),
                message: "Could not resolve $HOME".into(),
            });
            return response.finalize();
        }
    };

    if !downloads.exists() {
        return response.finalize();
    }

    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    for entry in WalkDir::new(&downloads)
        .follow_links(false)
        .max_depth(1)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        if !entry.file_type().is_file() { continue; }

        let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext != "dmg" && ext != "pkg" { continue; }

        let metadata = match entry.metadata() {
            Ok(m) => m,
            Err(err) => {
                response.errors.push(CliError {
                    path: path.display().to_string(),
                    message: err.to_string(),
                });
                continue;
            }
        };

        let modified_ms = metadata
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);

        let age_days = now_ms.saturating_sub(modified_ms) / (24 * 60 * 60 * 1000);
        if age_days < max_age_days { continue; }

        let file = FileEntry {
            path: path.display().to_string(),
            size_bytes: metadata.len(),
            is_dir: false,
            deleted: false,
        };
        if stream { streaming::emit_file(&file); }
        response.files.push(file);
    }

    response.files.sort_by(|a, b| b.size_bytes.cmp(&a.size_bytes));

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

pub fn default_max_age_days() -> u64 {
    DEFAULT_MAX_AGE_DAYS
}
