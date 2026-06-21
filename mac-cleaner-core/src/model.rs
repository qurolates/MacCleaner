//! Shared serializable types used for the JSON CLI output.

use serde::Serialize;

/// One discovered filesystem entry.
#[derive(Debug, Serialize, Clone)]
pub struct FileEntry {
    pub path: String,
    pub size_bytes: u64,
    /// `true` if the entry is a directory (size is the recursive sum).
    pub is_dir: bool,
    /// `true` if the entry was actually removed in this run.
    pub deleted: bool,
}

/// A non-fatal problem we ran into while scanning or deleting.
#[derive(Debug, Serialize, Clone)]
pub struct CliError {
    pub path: String,
    pub message: String,
}

/// Top-level CLI response. Every CLI invocation returns exactly one of these
/// as a single JSON object on stdout.
#[derive(Debug, Serialize)]
pub struct CliResponse {
    /// "success" | "partial" | "error"
    pub status: &'static str,
    /// e.g. "scan", "clean", "uninstall-scan", "uninstall-clean".
    pub operation: &'static str,
    /// `true` if `--execute` was passed and we actually deleted files.
    pub executed: bool,
    /// Sum of the sizes of all returned `files`.
    pub total_bytes: u64,
    /// Bytes actually freed in this run (0 when `executed == false`).
    pub freed_bytes: u64,
    /// The discovered (and optionally deleted) files.
    pub files: Vec<FileEntry>,
    /// Non-fatal errors (e.g. permission denied on a single file).
    pub errors: Vec<CliError>,
    /// Optional free-form message for the wrapper UI.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

impl CliResponse {
    pub fn new(operation: &'static str, executed: bool) -> Self {
        Self {
            status: "success",
            operation,
            executed,
            total_bytes: 0,
            freed_bytes: 0,
            files: Vec::new(),
            errors: Vec::new(),
            message: None,
        }
    }

    pub fn finalize(mut self) -> Self {
        self.total_bytes = self.files.iter().map(|f| f.size_bytes).sum();
        self.freed_bytes = self
            .files
            .iter()
            .filter(|f| f.deleted)
            .map(|f| f.size_bytes)
            .sum();
        self.status = if self.errors.is_empty() {
            "success"
        } else if self.files.is_empty() {
            "error"
        } else {
            "partial"
        };
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_file(path: &str, size: u64, deleted: bool) -> FileEntry {
        FileEntry {
            path: path.to_string(),
            size_bytes: size,
            is_dir: false,
            deleted,
        }
    }

    #[test]
    fn finalize_empty() {
        let resp = CliResponse::new("scan", false).finalize();
        assert_eq!(resp.status, "success");
        assert_eq!(resp.total_bytes, 0);
        assert_eq!(resp.freed_bytes, 0);
        assert!(!resp.executed);
    }

    #[test]
    fn finalize_with_files_no_errors() {
        let mut resp = CliResponse::new("scan", false);
        resp.files.push(make_file("/a", 100, false));
        resp.files.push(make_file("/b", 200, false));
        let resp = resp.finalize();
        assert_eq!(resp.status, "success");
        assert_eq!(resp.total_bytes, 300);
        assert_eq!(resp.freed_bytes, 0);
    }

    #[test]
    fn finalize_with_deletions() {
        let mut resp = CliResponse::new("clean", true);
        resp.files.push(make_file("/a", 100, true));
        resp.files.push(make_file("/b", 200, false));
        let resp = resp.finalize();
        assert_eq!(resp.total_bytes, 300);
        assert_eq!(resp.freed_bytes, 100);
    }

    #[test]
    fn finalize_partial_on_errors() {
        let mut resp = CliResponse::new("scan", false);
        resp.files.push(make_file("/a", 100, false));
        resp.errors.push(CliError {
            path: "/b".into(),
            message: "permission denied".into(),
        });
        let resp = resp.finalize();
        assert_eq!(resp.status, "partial");
    }

    #[test]
    fn finalize_error_when_no_files() {
        let mut resp = CliResponse::new("scan", false);
        resp.errors.push(CliError {
            path: "/x".into(),
            message: "not found".into(),
        });
        let resp = resp.finalize();
        assert_eq!(resp.status, "error");
    }
}
