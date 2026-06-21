//! `uninstall <path-to-app>` subcommand.
//!
//! Reads `Contents/Info.plist` of the given `.app` bundle, extracts the
//! `CFBundleIdentifier`, and searches three well-known directories for
//! support / cache / preference files that belong to that identifier.

use std::path::{Path, PathBuf};

use plist::Value;

use crate::model::{CliError, CliResponse, FileEntry};
use crate::scanner::{delete_path, directory_size, home_subdir};
use crate::streaming;

const SEARCH_DIRS: &[&str] = &[
    "Library/Application Support",
    "Library/Caches",
    "Library/Preferences",
];

pub fn run(app_path: &str, execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "uninstall-clean" } else { "uninstall-scan" };
    let mut response = CliResponse::new(operation, execute);

    let app = Path::new(app_path);
    if !app.exists() {
        response.errors.push(CliError {
            path: app_path.to_string(),
            message: "App bundle does not exist".into(),
        });
        response.message = Some("App bundle not found".into());
        return response.finalize();
    }

    let bundle_id = match read_bundle_identifier(app) {
        Ok(id) => id,
        Err(err) => {
            response.errors.push(CliError {
                path: app_path.to_string(),
                message: format!("Failed to read Info.plist: {err}"),
            });
            return response.finalize();
        }
    };

    response.message = Some(format!("Bundle identifier: {bundle_id}"));

    push_entry(app.to_path_buf(), &mut response.files, &mut response.errors);
    if stream && !response.files.is_empty() {
        streaming::emit_file(response.files.last().unwrap());
    }

    for rel in SEARCH_DIRS {
        let search_root = match home_subdir(rel) {
            Some(p) => p,
            None => continue,
        };
        let prev_len = response.files.len();
        scan_for_identifier(&search_root, &bundle_id, &mut response.files, &mut response.errors);
        if stream {
            for file in &response.files[prev_len..] {
                streaming::emit_file(file);
            }
        }
    }

    if execute {
        for entry in response.files.iter_mut() {
            match delete_path(Path::new(&entry.path)) {
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

fn read_bundle_identifier(app: &Path) -> Result<String, String> {
    let info_plist = app.join("Contents").join("Info.plist");
    let value = Value::from_file(&info_plist).map_err(|e| e.to_string())?;
    let dict = value
        .as_dictionary()
        .ok_or_else(|| "Info.plist is not a dictionary".to_string())?;
    let id = dict
        .get("CFBundleIdentifier")
        .and_then(Value::as_string)
        .ok_or_else(|| "CFBundleIdentifier not found".to_string())?;
    Ok(id.to_string())
}

/// Treat a child of `root` as a match if either:
///   * its file name contains the full bundle identifier, or
///   * its file name contains the "main" segment of the identifier
///     (e.g. `com.apple.Safari` → `Safari`).
fn scan_for_identifier(
    root: &Path,
    bundle_id: &str,
    files: &mut Vec<FileEntry>,
    errors: &mut Vec<CliError>,
) {
    if !root.exists() {
        return;
    }

    let last_segment = bundle_id.rsplit('.').next().unwrap_or(bundle_id);

    let rd = match std::fs::read_dir(root) {
        Ok(rd) => rd,
        Err(err) => {
            errors.push(CliError {
                path: root.display().to_string(),
                message: err.to_string(),
            });
            return;
        }
    };

    for entry in rd {
        let entry = match entry {
            Ok(e) => e,
            Err(err) => {
                errors.push(CliError {
                    path: root.display().to_string(),
                    message: err.to_string(),
                });
                continue;
            }
        };
        let path = entry.path();
        let name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or_default();

        let matches = name.contains(bundle_id)
            || (last_segment.len() >= 3 && name.contains(last_segment));

        if matches {
            push_entry(path, files, errors);
        }
    }
}

fn push_entry(path: PathBuf, files: &mut Vec<FileEntry>, errors: &mut Vec<CliError>) {
    let metadata = match std::fs::symlink_metadata(&path) {
        Ok(md) => md,
        Err(err) => {
            errors.push(CliError {
                path: path.display().to_string(),
                message: err.to_string(),
            });
            return;
        }
    };
    let is_dir = metadata.is_dir();
    let size = if is_dir {
        directory_size(&path, errors)
    } else {
        metadata.len()
    };
    files.push(FileEntry {
        path: path.display().to_string(),
        size_bytes: size,
        is_dir,
        deleted: false,
    });
}
