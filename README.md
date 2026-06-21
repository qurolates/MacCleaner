# MacCleaner

A lightweight, open-source macOS cleaning utility built with **Rust** and **SwiftUI**.

```
./build.sh && open MacCleaner.app
```

---

## Features

| Tab | Description |
|-----|-------------|
| **Junk** | Scans `~/Library/Caches`, `~/Library/Logs`, `~/.Trash` |
| **Xcode** | DerivedData, Archives, iOS Simulators, Xcode caches |
| **Large Files** | Configurable size threshold (50 MB – 1 GB), depth limit |
| **Uninstaller** | Remove apps and support files via drag-and-drop or file picker |
| **Installers** | Find `.dmg` and `.pkg` in `~/Downloads` older than N days |
| **Sweep** | Broken symlinks and `.DS_Store` files |
| **Docker** | VM disk images in `~/Library/Containers/.../vms` |
| **Login Items** | LaunchAgents and LaunchDaemons (disable by renaming to `.disabled`) |
| **History** | Log of past deletions with restore info |

### Safety

- Every destructive operation goes through a **confirm dialog** with top-5 largest items preview
- **Checkbox selection** — only checked items are deleted
- **Move to Trash** (default) — uses `FileManager.trashItem()`, no permanent deletion
- **Dry-run mode** — scan first, delete only when you confirm

### Real-time Progress

- Streaming NDJSON mode — each file is emitted as it's discovered
- Live counter shows items found and total bytes during scan

---

## Quick Start

### Prerequisites

- **Full Xcode** (not Command-Line Tools only)
  ```bash
  xcode-select -p
  # Must show: /Applications/Xcode.app/Contents/Developer
  ```
- **Rust** via [rustup](https://rustup.rs/)
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  ```

### Build & Run

```bash
./build.sh          # builds Rust core + Swift UI → MacCleaner.app
open MacCleaner.app
```

### Test Rust Core Directly

```bash
cd mac-cleaner-core

# Scan junk
cargo run --release -- junk-clean --dry-run

# Scan large files (50 MB+, depth 6)
cargo run --release -- large-files --min-bytes 52428800 --max-depth 6 --dry-run

# Find old installers
cargo run --release -- old-installers --max-age-days 7 --dry-run

# Sweep broken symlinks + .DS_Store
cargo run --release -- sweep --dry-run

# Run tests
cargo test
```

---

## Architecture

Two-process model. **Swift never touches the filesystem.**

```
┌─────────────────────────────┐              ┌─────────────────────────────┐
│  SwiftUI                    │   Process    │  Rust Core                  │
│  ├ JunkCleanerView          │ ──────────▶  │  mac-cleaner-core           │
│  ├ XcodeCleanerView         │              │  (subcommands)              │
│  ├ LargeFilesView           │ ◀────────── │                             │
│  ├ AppUninstallerView       │   JSON       │  stdout = CliResponse       │
│  ├ OldInstallersView        │              │  + NDJSON stream (optional) │
│  ├ SweepView                │              └─────────────────────────────┘
│  ├ DockerCleanerView        │
│  ├ LoginItemsView           │
│  └ HistoryView              │
└─────────────────────────────┘
```

- **`mac-cleaner-core/`** — Rust CLI binary. All scan/delete logic lives here.
- **`swift-ui/main.swift`** — Single-file SwiftUI frontend (~1800 lines).
- **IPC**: Rust emits one `CliResponse` JSON object on stdout. With `--stream`, also emits per-file NDJSON lines for real-time progress.
- **Rust binary** lives in `Contents/Resources/` (not `MacOS/`). Located at runtime via `Bundle.main.url(forResource:)`.

### JSON Contract

The `CliResponse` struct must match on both sides:
- Rust: `mac-cleaner-core/src/model.rs`
- Swift: `FileEntry`, `CliErrorEntry`, `CliResponse` Codable structs in `swift-ui/main.swift`

### Rust CLI Conventions

- Each subcommand = a module under `mac-cleaner-core/src/commands/` with `pub fn run(...)`.
- Every command follows: create `CliResponse` → scan → optionally delete (`--execute`) → `response.finalize()`.
- Errors are non-fatal: pushed to `Vec<CliError>`, scan continues.
- Dependencies: `clap`, `serde`, `serde_json`, `plist`, `dirs`, `walkdir`

### Swift UI Conventions

- Single file: `swift-ui/main.swift`.
- Shared subviews: `FileListView`, `SummaryBar`, `ConfirmDeleteSheet`, `SortFilterBar` — reuse, don't duplicate.
- Every destructive op goes through `ConfirmDeleteSheet`. "Move to Trash" uses `FileManager.trashItem()`.
- Streaming via `CoreRunner.runStreaming()` with `Pipe.readabilityHandler`.

### Build Artifact Layout

```
MacCleaner.app/
└─ Contents/
   ├─ Info.plist
   ├─ MacOS/
   │  └─ MacCleaner              ← swiftc-built executable
   └─ Resources/
      └─ mac-cleaner-core        ← Rust release binary (~600 KB)
```

Total bundle: **~1 MB**.

---

## Project Structure

```
mac-cleaner-dev/
├── build.sh                    # Build script (no Xcode project)
├── build-assets/
│   └── Info.plist              # macOS app bundle metadata
├── mac-cleaner-core/           # Rust CLI backend
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs             # CLI entrypoint (clap)
│       ├── model.rs            # CliResponse, FileEntry, CliError
│       ├── scanner.rs          # directory_size, list_top_level, delete_path
│       ├── streaming.rs        # NDJSON emit_file, emit_done
│       └── commands/
│           ├── junk.rs         # ~/Library/Caches, Logs, Trash
│           ├── xcode.rs        # DerivedData, Archives, Simulators
│           ├── large_files.rs  # Files above size threshold
│           ├── uninstall.rs    # App uninstaller
│           ├── old_installers.rs # .dmg/.pkg in Downloads
│           ├── sweep.rs        # Broken symlinks + .DS_Store
│           ├── docker.rs       # Docker VM images
│           ├── browser_caches.rs # Browser cache dirs
│           ├── node_modules.rs # node_modules finder
│           ├── login_items.rs  # LaunchAgents/Daemons
│           └── delete_paths.rs # Explicit path deletion
├── swift-ui/
│   └── main.swift              # Complete SwiftUI frontend
└── MacCleaner.app/             # Built application bundle
```

---

## Don'ts

- Don't add an Xcode project or use `xcodebuild` — build is `swiftc` + `build.sh`.
- Don't add async Rust — intentionally synchronous for x86_64 compatibility.
- Don't add linting/formatting tooling unless asked — none exists today.

---

## Authors

- **MiMo** (Xiaomi MiMo Team) — AI coding agent, Rust backend, Swift frontend, architecture
- **Claude** (Anthropic) — AI coding assistant, code review, feature implementation

---

## License

MIT
