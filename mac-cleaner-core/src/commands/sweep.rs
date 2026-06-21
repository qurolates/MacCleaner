//! `sweep` subcommand: find broken symlinks and `.DS_Store` files under `$HOME`.

use walkdir::WalkDir;

use crate::model::{CliError, CliResponse, FileEntry};
use crate::scanner::{delete_path, home_subdir};
use crate::streaming;

const MAX_DEPTH: usize = 10;

pub fn run(execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "sweep-clean" } else { "sweep-scan" };
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

    for entry in WalkDir::new(&home)
        .follow_links(false)
        .max_depth(MAX_DEPTH)
        .into_iter()
        .filter_entry(|e| {
            if let Ok(rel) = e.path().strip_prefix(&home) {
                let s = rel.to_string_lossy();
                return !s.starts_with("Library/Caches")
                    && !s.starts_with("Library/Developer")
                    && !s.starts_with("Library/Containers")
                    && !s.starts_with("node_modules")
                    && !s.starts_with(".git");
            }
            true
        })
        .filter_map(|e| e.ok())
    {
        let path = entry.path();

        if entry.file_type().is_symlink() {
            match std::fs::read_link(path) {
                Ok(target) => {
                    if !target.exists() {
                        let file = FileEntry {
                            path: path.display().to_string(),
                            size_bytes: 0,
                            is_dir: false,
                            deleted: false,
                        };
                        if stream { streaming::emit_file(&file); }
                        response.files.push(file);
                    }
                }
                Err(err) => {
                    response.errors.push(CliError {
                        path: path.display().to_string(),
                        message: err.to_string(),
                    });
                }
            }
            continue;
        }

        if entry.file_type().is_file() {
            if path.file_name().map(|n| n == ".DS_Store").unwrap_or(false) {
                let size = entry.metadata().map(|m| m.len()).unwrap_or(0);
                let file = FileEntry {
                    path: path.display().to_string(),
                    size_bytes: size,
                    is_dir: false,
                    deleted: false,
                };
                if stream { streaming::emit_file(&file); }
                response.files.push(file);
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
