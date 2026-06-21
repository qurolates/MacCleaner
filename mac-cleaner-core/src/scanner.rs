//! Filesystem traversal helpers. Everything here is intentionally synchronous
//! and uses only stdlib + walkdir so the resulting binary stays small and
//! runs on older x86_64 macs without trouble.

use std::fs;
use std::path::{Path, PathBuf};

use walkdir::WalkDir;

use crate::model::{CliError, FileEntry};

/// Recursively sum the size of all regular files under `path`.
/// Non-fatal errors are pushed to `errors`.
pub fn directory_size(path: &Path, errors: &mut Vec<CliError>) -> u64 {
    let mut total: u64 = 0;
    for entry in WalkDir::new(path).follow_links(false).into_iter() {
        match entry {
            Ok(e) => {
                if e.file_type().is_file() {
                    match e.metadata() {
                        Ok(md) => total = total.saturating_add(md.len()),
                        Err(err) => errors.push(CliError {
                            path: e.path().display().to_string(),
                            message: err.to_string(),
                        }),
                    }
                }
            }
            Err(err) => errors.push(CliError {
                path: err
                    .path()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|| path.display().to_string()),
                message: err.to_string(),
            }),
        }
    }
    total
}

/// List the immediate children of `root` as `FileEntry` records.
/// If `root` doesn't exist, returns an empty list and a single error entry.
pub fn list_top_level(
    root: &Path,
    files: &mut Vec<FileEntry>,
    errors: &mut Vec<CliError>,
) {
    if !root.exists() {
        // Not an error per-se; the dir simply may not exist on this system.
        return;
    }

    let read_dir = match fs::read_dir(root) {
        Ok(rd) => rd,
        Err(err) => {
            errors.push(CliError {
                path: root.display().to_string(),
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
                    path: root.display().to_string(),
                    message: err.to_string(),
                });
                continue;
            }
        };

        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(md) => md,
            Err(err) => {
                errors.push(CliError {
                    path: path.display().to_string(),
                    message: err.to_string(),
                });
                continue;
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
}

/// Delete the given path. Directories are removed recursively.
/// Returns `Ok(())` on success; the caller is responsible for translating
/// errors into `CliError` entries.
pub fn delete_path(path: &Path) -> std::io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}

/// Convenience: resolve `~/<rel>` to an absolute `PathBuf`.
pub fn home_subdir(rel: &str) -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(rel))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn directory_size_empty() {
        let dir = tempdir().unwrap();
        let mut errors = Vec::new();
        assert_eq!(directory_size(dir.path(), &mut errors), 0);
        assert!(errors.is_empty());
    }

    #[test]
    fn directory_size_with_files() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("a.txt"), b"hello").unwrap();
        fs::write(dir.path().join("b.txt"), b"world!").unwrap();
        let mut errors = Vec::new();
        assert_eq!(directory_size(dir.path(), &mut errors), 11);
    }

    #[test]
    fn directory_size_nested() {
        let dir = tempdir().unwrap();
        let sub = dir.path().join("sub");
        fs::create_dir(&sub).unwrap();
        fs::write(sub.join("file.txt"), b"nested").unwrap();
        let mut errors = Vec::new();
        assert_eq!(directory_size(dir.path(), &mut errors), 6);
    }

    #[test]
    fn list_top_level_empty() {
        let dir = tempdir().unwrap();
        let mut files = Vec::new();
        let mut errors = Vec::new();
        list_top_level(dir.path(), &mut files, &mut errors);
        assert!(files.is_empty());
        assert!(errors.is_empty());
    }

    #[test]
    fn list_top_level_with_entries() {
        let dir = tempdir().unwrap();
        fs::write(dir.path().join("file.txt"), b"data").unwrap();
        fs::create_dir(dir.path().join("subdir")).unwrap();
        let mut files = Vec::new();
        let mut errors = Vec::new();
        list_top_level(dir.path(), &mut files, &mut errors);
        assert_eq!(files.len(), 2);
    }

    #[test]
    fn list_top_level_nonexistent() {
        let mut files = Vec::new();
        let mut errors = Vec::new();
        list_top_level(Path::new("/nonexistent/path/xyz"), &mut files, &mut errors);
        assert!(files.is_empty());
    }

    #[test]
    fn delete_path_file() {
        let dir = tempdir().unwrap();
        let file = dir.path().join("to_delete.txt");
        fs::write(&file, b"bye").unwrap();
        assert!(file.exists());
        delete_path(&file).unwrap();
        assert!(!file.exists());
    }

    #[test]
    fn delete_path_dir() {
        let dir = tempdir().unwrap();
        let sub = dir.path().join("to_delete_dir");
        fs::create_dir(&sub).unwrap();
        fs::write(sub.join("child.txt"), b"child").unwrap();
        assert!(sub.exists());
        delete_path(&sub).unwrap();
        assert!(!sub.exists());
    }

    #[test]
    fn home_subdir_returns_path() {
        let result = home_subdir("Library");
        assert!(result.is_some());
        let p = result.unwrap();
        assert!(p.ends_with("Library"));
    }
}
