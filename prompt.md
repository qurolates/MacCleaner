Act as an expert macOS systems developer specializing in Rust and Swift. Your task is to build a lightweight, open-source macOS cleaning utility. The architecture consists of a Rust CLI core for file-system operations and a SwiftUI frontend that acts as a wrapper.

CRITICAL CONSTRAINT: Do not assume the use of the Xcode IDE. Provide all instructions, build steps, and UI code using standard CLI tools (`swiftc` and bash). Generate a bash build script (`build.sh`) to compile the Swift code, compile the Rust core, and structure the `.app` bundle automatically, placing the compiled Rust binary into the `Contents/Resources` directory.

### Phase 1: Rust CLI Core
Create a Rust command-line tool named `mac-cleaner-core`.
1. Commands using the `clap` crate:
   - `junk-clean`: Scans and calculates the size of `~/Library/Caches`, `~/Library/Logs`, and `~/.Trash`. Include a `--dry-run` flag to list files without deleting, and an `--execute` flag.
   - `uninstall <path-to-app>`: Parses the `Info.plist` of the given `.app` bundle using the `plist` crate to extract the `CFBundleIdentifier`. Scans `~/Library/Application Support`, `~/Library/Caches`, and `~/Library/Preferences` for folders/files matching the identifier. Include `--dry-run` and `--execute` flags.
2. Output Format: All stdout MUST be strictly in JSON format (using `serde_json`). Example: `{"status": "success", "operation": "scan", "total_bytes": 1024500, "files": [...]}`.
3. Error Handling: Catch permissions errors gracefully and format them into the JSON output. Do not crash.
4. Compatibility: Rely on standard Unix/Rust file operations to ensure the code performs flawlessly on older x86_64 hardware.

### Phase 2: SwiftUI Wrapper and Build Process
1. Build Script: Write the `build.sh` script that creates the `MacCleaner.app/Contents` structure, runs `cargo build --release`, copies the binary, compiles `main.swift` using `swiftc`, and generates the `Info.plist`.
2. Backend Integration: Use `Foundation.Process` in Swift to execute the bundled `mac-cleaner-core` binary from the Resources folder. Do not implement any file-system deletion logic natively in Swift.
3. Data Parsing: Parse the JSON output from the Rust CLI using `Codable` structs to update the UI state.
4. UI/UX: Create a minimalist, native SwiftUI interface with two main views: "Junk Cleaner" and "App Uninstaller". Include visual loading states while waiting for the Rust process.

Begin with Phase 1. Scaffold the Rust project, provide the `Cargo.toml` dependencies, and write the core logic for the CLI tool. Let me test the CLI before moving to Phase 2.

