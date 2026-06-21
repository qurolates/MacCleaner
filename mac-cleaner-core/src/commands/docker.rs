//! `docker-clean` subcommand: scan Docker VM disk images in
//! `~/Library/Containers/com.docker.docker/Data/vms`.

use crate::model::{CliError, CliResponse};
use crate::scanner::{delete_path, home_subdir, list_top_level};
use crate::streaming;

pub fn run(execute: bool, stream: bool) -> CliResponse {
    let operation = if execute { "docker-clean" } else { "docker-scan" };
    let mut response = CliResponse::new(operation, execute);

    let vms = match home_subdir("Library/Containers/com.docker.docker/Data/vms") {
        Some(p) => p,
        None => {
            response.errors.push(CliError {
                path: "~/Library/Containers/com.docker.docker/Data/vms".into(),
                message: "Could not resolve $HOME".into(),
            });
            return response.finalize();
        }
    };

    let prev_len = response.files.len();
    list_top_level(&vms, &mut response.files, &mut response.errors);
    if stream {
        for file in &response.files[prev_len..] {
            streaming::emit_file(file);
        }
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
