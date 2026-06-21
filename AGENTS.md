# AGENTS.md — MacCleaner

## Build & Run

```bash
./build.sh          # builds Rust core + Swift UI → MacCleaner.app
open MacCleaner.app
```

Requires **full Xcode** (not CLT only) + **Rust** via `rustup`.
`xcode-select -p` must point at `/Applications/Xcode.app/Contents/Developer`.

## Architecture

Two-process model. **Swift never touches the filesystem.**

- `mac-cleaner-core/` — Rust CLI binary. All scan/delete logic lives here.
- `swift-ui/main.swift` — Single-file SwiftUI frontend (917 lines).
- IPC: Rust emits one `CliResponse` JSON object on stdout → Swift decodes via `JSONDecoder`.
- Rust binary lives in `Contents/Resources/` (not `MacOS/`). Located at runtime via `Bundle.main.url(forResource:)`.

## JSON Contract

The `CliResponse` struct must match on both sides:
- Rust: `mac-cleaner-core/src/model.rs`
- Swift: `FileEntry`, `CliErrorEntry`, `CliResponse` Codable structs in `swift-ui/main.swift`

Changes to one side must be mirrored on the other.

## Rust CLI Conventions

- Each subcommand = a module under `mac-cleaner-core/src/commands/` with `pub fn run(...)`.
- Every command follows: create `CliResponse` → scan → optionally delete (`--execute`) → `response.finalize()`.
- Errors are non-fatal: pushed to `Vec<CliError>`, scan continues.
- Test the core directly: `cd mac-cleaner-core && cargo run --release -- <subcommand> --dry-run`.

## Swift UI Conventions

- Single file: `swift-ui/main.swift`.
- Shared subviews: `FileListView`, `SummaryBar`, `ConfirmDeleteSheet` — reuse, don't duplicate.
- Every destructive op goes through `ConfirmDeleteSheet`. "Move to Trash" uses `FileManager.trashItem()`.

## Don'ts

- Don't add an Xcode project or use `xcodebuild` — build is `swiftc` + `build.sh`.
- Don't add async Rust — intentionally synchronous for x86_64 compatibility.
- Don't add linting/formatting tooling unless asked — none exists today.
