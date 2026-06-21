//! `delete-paths` subcommand: delete an explicit list of paths.
//!
//! This is used when the SwiftUI side has a checkbox-filtered subset of paths
//! that must be deleted without running a fresh scan. Each path is passed as
//! a separate positional argument.

use std::path::Path;

use crate::model::{CliError, CliResponse};
use crate::scanner::delete_path;
use crate::streaming;

pub fn run(paths: &[String], stream: bool) -> CliResponse {
    let mut response = CliResponse::new("delete-paths", true);

    for raw in paths {
        let p = Path::new(raw);
        let size = size_of(p, &mut response.errors);
        let is_dir = p.is_dir();

        match delete_path(p) {
            Ok(()) => {
                let file = crate::model::FileEntry {
                    path: raw.clone(),
                    size_bytes: size,
                    is_dir,
                    deleted: true,
                };
                if stream { streaming::emit_file(&file); }
                response.files.push(file);
            }
            Err(err) => response.errors.push(CliError {
                path: raw.clone(),
                message: err.to_string(),
            }),
        }
    }

    let finalized = response.finalize();
    if stream { streaming::emit_done(finalized.files.len(), finalized.total_bytes); }
    finalized
}

/// Best-effort size of a path before deletion.
fn size_of(path: &Path, errors: &mut Vec<CliError>) -> u64 {
    match std::fs::symlink_metadata(path) {
        Err(_) => 0,
        Ok(md) if md.is_dir() => crate::scanner::directory_size(path, errors),
        Ok(md) => md.len(),
    }
}
