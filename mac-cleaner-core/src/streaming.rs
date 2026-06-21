//! NDJSON streaming support. When `--stream` is passed, each discovered file
//! is emitted as a single JSON line on stdout as it's found. The final
//! `CliResponse` is still emitted at the end for compatibility.

use std::io::Write;

use crate::model::FileEntry;

/// Emit a single FileEntry as an NDJSON line.
/// Format: `{"type":"file","path":"...","size_bytes":123,"is_dir":false,"deleted":false}`
pub fn emit_file(file: &FileEntry) {
    let obj = serde_json::json!({
        "type": "file",
        "path": file.path,
        "size_bytes": file.size_bytes,
        "is_dir": file.is_dir,
        "deleted": file.deleted,
    });
    if let Ok(line) = serde_json::to_string(&obj) {
        let mut stdout = std::io::stdout();
        let _ = writeln!(stdout, "{line}");
        let _ = stdout.flush();
    }
}

/// Emit a done event as NDJSON.
/// Format: `{"type":"done","file_count":10,"total_bytes":123456}`
pub fn emit_done(file_count: usize, total_bytes: u64) {
    let obj = serde_json::json!({
        "type": "done",
        "file_count": file_count,
        "total_bytes": total_bytes,
    });
    if let Ok(line) = serde_json::to_string(&obj) {
        let mut stdout = std::io::stdout();
        let _ = writeln!(stdout, "{line}");
        let _ = stdout.flush();
    }
}
