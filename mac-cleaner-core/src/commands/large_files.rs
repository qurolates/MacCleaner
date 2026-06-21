//! `large-files` subcommand: recursively find all files under `$HOME`
//! that exceed a given size threshold (default 100 MB) and report them
//! sorted largest-first.
//!
//! Only regular files are reported (no directories). Unreadable paths are
//! non-fatal and go to `errors`.

use std::path::Path;

use walkdir::WalkDir;

use crate::model::{CliError, CliResponse, FileEntry};
use crate::scanner::home_subdir;
use crate::streaming;

/// Default threshold: 100 MB
const DEFAULT_MIN_BYTES: u64 = 100 * 1024 * 1024;

/// Max depth to prevent scanning into deeply nested dirs (e.g. node_modules)
const MAX_DEPTH: usize = 8;

/// Directories to skip entirely — they are either huge, covered by other
/// scanners, or not user data.
const SKIP_PREFIXES: &[&str] = &[
    ".Trash",
    "Library/Developer/Xcode",
    "Library/Containers/com.docker.docker/Data/vms",
    "Library/Caches",
    "Library/Application Support/Code",
    "Library/Application Support/Slack",
    "Library/Application Support/Google",
    "Library/Application Support/Firefox",
    "node_modules",
    ".git",
    "Library/Application Support/Chrome",
    ".Trash",
];

pub fn run(min_bytes: u64, max_depth: usize, execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "large-files-delete" } else { "large-files-scan" };
    let mut response = CliResponse::new(operation, execute);

    let home = match home_subdir("") {
        Some(p) => p,
        None => {
            response.errors.push(CliError {
                path: "~".into(),
                message: "Could not resolve $HOME".into(),
            });
            return response.finalize();
        }
    };

    scan_large_files(&home, min_bytes, max_depth, &mut response.files, &mut response.errors, stream);

    response.files.sort_by(|a, b| b.size_bytes.cmp(&a.size_bytes));

    if execute {
        for entry in response.files.iter_mut() {
            match std::fs::remove_file(Path::new(&entry.path)) {
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

fn scan_large_files(root: &Path, min_bytes: u64, max_depth: usize, files: &mut Vec<FileEntry>, errors: &mut Vec<CliError>, stream: bool) {
    let home = match home_subdir("") {
        Some(p) => p,
        None => return,
    };

    for entry in WalkDir::new(root)
        .follow_links(false)
        .max_depth(max_depth)
        .into_iter()
        .filter_entry(|e| {
            // Skip known huge or irrelevant directories
            if let Ok(rel) = e.path().strip_prefix(&home) {
                let s = rel.to_string_lossy();
                return !SKIP_PREFIXES.iter().any(|p| s.starts_with(p));
            }
            true
        })
    {
        match entry {
            Err(err) => errors.push(CliError {
                path: err.path().map(|p| p.display().to_string())
                    .unwrap_or_else(|| root.display().to_string()),
                message: err.to_string(),
            }),
            Ok(e) if e.file_type().is_file() => {
                match e.metadata() {
                    Err(err) => errors.push(CliError {
                        path: e.path().display().to_string(),
                        message: err.to_string(),
                    }),
                    Ok(md) if md.len() >= min_bytes => {
                        let file = FileEntry {
                            path: e.path().display().to_string(),
                            size_bytes: md.len(),
                            is_dir: false,
                            deleted: false,
                        };
                        if stream { streaming::emit_file(&file); }
                        files.push(file);
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
}

pub fn default_min_bytes() -> u64 { DEFAULT_MIN_BYTES }
pub fn default_max_depth() -> usize { MAX_DEPTH }
