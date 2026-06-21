//! `browser-caches` subcommand: find cache directories for popular browsers.
//!
//! Reports each browser's cache dir as a single entry so the user can
//! selectively remove per-browser caches.

use std::path::PathBuf;

use crate::model::{CliError, CliResponse, FileEntry};
use crate::scanner::{delete_path, directory_size, home_subdir};
use crate::streaming;

/// (browser name, relative path from $HOME)
const BROWSER_CACHES: &[(&str, &str)] = &[
    ("Safari",          "Library/Caches/com.apple.Safari"),
    ("Chrome",          "Library/Caches/Google/Chrome"),
    ("Firefox",         "Library/Caches/Firefox"),
    ("Arc",             "Library/Caches/company.thebrowser.Browser"),
    ("Brave",           "Library/Caches/BraveSoftware/Brave-Browser"),
    ("Edge",            "Library/Caches/Microsoft Edge"),
    ("Opera",           "Library/Caches/com.operasoftware.Opera"),
    ("Vivaldi",         "Library/Caches/Vivaldi"),
];

pub fn run(execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "browser-caches-clean" } else { "browser-caches-scan" };
    let mut response = CliResponse::new(operation, execute);

    for (name, rel) in BROWSER_CACHES {
        let dir: PathBuf = match home_subdir(rel) {
            Some(p) => p,
            None => continue,
        };

        if !dir.exists() { continue; }

        let mut size_errors: Vec<CliError> = Vec::new();
        let size = directory_size(&dir, &mut size_errors);
        response.errors.extend(size_errors);

        let file = FileEntry {
            path: dir.display().to_string(),
            size_bytes: size,
            is_dir: true,
            deleted: false,
        };
        if stream { streaming::emit_file(&file); }
        response.files.push(file);

        let _ = name;
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
