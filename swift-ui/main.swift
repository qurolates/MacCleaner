// MacCleaner — SwiftUI wrapper around the mac-cleaner-core Rust binary.
//
// Swift never touches the filesystem directly. All work is delegated to the
// bundled `mac-cleaner-core` executable (Contents/Resources), whose strict-JSON
// stdout is decoded via Codable.
//
// Features:
//  • Junk Cleaner      — ~/Library/Caches, ~/Library/Logs, ~/.Trash
//  • Xcode Cleaner     — DerivedData, Archives, iOS Simulators, Xcode caches
//  • App Uninstaller   — reads CFBundleIdentifier, finds support files
//
// Safety features implemented here:
//  • Confirm-sheet before every destructive operation (tasks 1)
//  • Checkbox selection — only checked items are deleted  (task 4)
//  • Move to Trash flag is passed when --trash supported   (task 2)

import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - Models (mirror Rust's CliResponse)

struct FileEntry: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size_bytes: UInt64
    let is_dir: Bool
    let deleted: Bool
}

struct CliErrorEntry: Codable, Identifiable, Hashable {
    var id: String { path + message }
    let path: String
    let message: String
}

struct CliResponse: Codable {
    let status: String
    let operation: String
    let executed: Bool
    let total_bytes: UInt64
    let freed_bytes: UInt64
    let files: [FileEntry]
    let errors: [CliErrorEntry]
    let message: String?
}

// MARK: - App-wide settings

extension UserDefaults {
    /// When true, deletions go to Trash instead of permanent rm.
    var useTrash: Bool {
        get { object(forKey: "useTrash") == nil ? true : bool(forKey: "useTrash") }
        set { set(newValue, forKey: "useTrash") }
    }
}

// MARK: - Trash helper

/// Move a list of paths to the macOS Trash via FileManager.
/// Returns a fake CliResponse so the UI can reuse the same display logic.
func trashPaths(_ paths: [String]) -> CliResponse {
    var files: [FileEntry] = []
    var errors: [CliErrorEntry] = []

    for raw in paths {
        let url = URL(fileURLWithPath: raw)
        // Size before trashing
        let size = (try? url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize)
            .flatMap { UInt64(exactly: $0) } ?? 0
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            files.append(FileEntry(path: raw, size_bytes: size, is_dir: isDir, deleted: true))
        } catch {
            errors.append(CliErrorEntry(path: raw, message: error.localizedDescription))
        }
    }

    let freed = files.map(\.size_bytes).reduce(0, +)
    let resp = CliResponse(
        status:      errors.isEmpty ? "success" : (files.isEmpty ? "error" : "partial"),
        operation:   "trash",
        executed:    true,
        total_bytes: freed,
        freed_bytes: freed,
        files:       files,
        errors:      errors,
        message:     "Moved \(files.count) item(s) to Trash"
    )

    // Log to history
    if !files.isEmpty {
        let entry = HistoryEntry(
            timestamp: Date(),
            paths: files.map(\.path),
            totalBytes: freed,
            operation: "trash"
        )
        var history: [HistoryEntry] = []
        if let data = UserDefaults.standard.string(forKey: "deleteHistory")?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            history = decoded
        }
        history.insert(entry, at: 0)
        if let data = try? JSONEncoder().encode(history),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: "deleteHistory")
        }
    }

    return resp
}

// MARK: - Core runner

enum CoreRunner {

    enum RunError: Error, LocalizedError {
        case binaryMissing
        case launchFailed(String)
        case nonZeroExit(Int32, String)
        case invalidJSON(String, String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "mac-cleaner-core not found in app Resources."
            case .launchFailed(let m):
                return "Failed to launch core: \(m)"
            case .nonZeroExit(let c, let s):
                return "Core exited with code \(c). stderr: \(s)"
            case .invalidJSON(let e, let raw):
                return "Could not parse core JSON: \(e)\n---\n\(raw)"
            }
        }
    }

    static func coreURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "mac-cleaner-core", withExtension: nil) {
            return bundled
        }
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("mac-cleaner-core")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    /// Non-streaming: runs the core and returns the final CliResponse.
    static func run(arguments: [String]) async throws -> CliResponse {
        guard let url = coreURL() else { throw RunError.binaryMissing }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = url
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do { try process.run() } catch {
                    cont.resume(throwing: RunError.launchFailed(error.localizedDescription))
                    return
                }

                process.waitUntilExit()

                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errStr  = String(data: errData, encoding: .utf8) ?? ""

                if process.terminationStatus != 0 && outData.isEmpty {
                    cont.resume(throwing: RunError.nonZeroExit(process.terminationStatus, errStr))
                    return
                }

                do {
                    let resp = try JSONDecoder().decode(CliResponse.self, from: outData)
                    cont.resume(returning: resp)
                } catch {
                    let raw = String(data: outData, encoding: .utf8) ?? "<binary>"
                    cont.resume(throwing: RunError.invalidJSON(error.localizedDescription, raw))
                }
            }
        }
    }

    /// Streaming: emits NDJSON lines in real-time, calls onFile for each file,
    /// returns the final CliResponse.
    static func runStreaming(
        arguments: [String],
        onFile: @escaping @Sendable (Int, UInt64) -> Void
    ) async throws -> CliResponse {
        guard let url = coreURL() else { throw RunError.binaryMissing }

        return try await withCheckedThrowingContinuation { cont in
            let state = StreamingState(onFile: onFile)

            let process = Process()
            process.executableURL = url
            process.arguments = arguments + ["--stream"]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                state.append(data)
            }

            do { try process.run() } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: RunError.launchFailed(error.localizedDescription))
                return
            }

            process.waitUntilExit()
            stdout.fileHandleForReading.readabilityHandler = nil

            // Read any remaining data that the handler didn't capture
            let remaining = stdout.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty {
                state.append(remaining)
            }

            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr  = String(data: errData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 && state.allOutput.isEmpty {
                cont.resume(throwing: RunError.nonZeroExit(process.terminationStatus, errStr))
                return
            }

            // Find the last line that looks like a CliResponse (has "status" field)
            let outStr = state.allOutput
            let lines = outStr.components(separatedBy: "\n")
            var responseLine: String?
            for line in lines.reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("{\"status\"") {
                    responseLine = trimmed
                    break
                }
            }

            guard let jsonStr = responseLine,
                  let jsonData = jsonStr.data(using: .utf8)
            else {
                // No CliResponse found — return a synthetic one from stream data
                let resp = CliResponse(
                    status: "success",
                    operation: "scan",
                    executed: false,
                    total_bytes: state.totalBytes,
                    freed_bytes: 0,
                    files: [],
                    errors: [],
                    message: "\(state.fileCount) files found via stream"
                )
                cont.resume(returning: resp)
                return
            }

            do {
                let resp = try JSONDecoder().decode(CliResponse.self, from: jsonData)
                cont.resume(returning: resp)
            } catch {
                cont.resume(throwing: RunError.invalidJSON(error.localizedDescription, outStr))
            }
        }
    }
}

private class StreamingState: @unchecked Sendable {
    private let lock = NSLock()
    private var lineBuffer = ""
    private(set) var fileCount = 0
    private(set) var totalBytes: UInt64 = 0
    private let onFile: @Sendable (Int, UInt64) -> Void
    var allOutput: String = ""

    init(onFile: @escaping @Sendable (Int, UInt64) -> Void) {
        self.onFile = onFile
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let chunk = String(data: data, encoding: .utf8) ?? ""
        allOutput += chunk
        lineBuffer += chunk
        let lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.last ?? ""

        for line in lines.dropLast() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            if type == "file" {
                fileCount += 1
                if let size = obj["size_bytes"] as? UInt64 {
                    totalBytes += size
                }
                let count = fileCount
                let bytes = totalBytes
                DispatchQueue.main.async {
                    self.onFile(count, bytes)
                }
            }
        }
    }
}

// MARK: - Helpers

func formatBytes(_ bytes: UInt64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useAll]
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bitPattern: bytes))
}

// MARK: - Shared sub-views

/// Reusable file list with optional checkboxes.
struct FileListView: View {
    let files: [FileEntry]
    @Binding var selection: Set<String>

    var body: some View {
        List(files) { f in
            HStack(spacing: 10) {
                Button {
                    if selection.contains(f.path) { selection.remove(f.path) }
                    else { selection.insert(f.path) }
                } label: {
                    Image(systemName: selection.contains(f.path)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selection.contains(f.path) ? Color.accentColor : Color.secondary.opacity(0.5))
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: f.path).lastPathComponent)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)
                    Text(URL(fileURLWithPath: f.path).deletingLastPathComponent().path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                if f.size_bytes > 0 {
                    Text(formatBytes(f.size_bytes))
                        .font(.system(.callout, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if f.deleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.plain)
    }
}

/// Summary bar shown after a scan.
struct SummaryBar: View {
    let resp: CliResponse
    let selectedBytes: UInt64

    var body: some View {
        HStack(spacing: 20) {
            stat("Items", "\(resp.files.count)")
            Divider().frame(height: 20)
            if resp.executed {
                stat("Freed", formatBytes(resp.freed_bytes))
            } else {
                stat("Total", formatBytes(resp.total_bytes))
                if selectedBytes > 0 && selectedBytes != resp.total_bytes {
                    Divider().frame(height: 20)
                    stat("Selected", formatBytes(selectedBytes))
                }
            }
            if resp.errors.count > 0 {
                Divider().frame(height: 20)
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(resp.errors.count)")
                }
                .font(.callout)
            }
            Spacer()
            if resp.status != "success" {
                Text(resp.status.uppercased())
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(statusColor(resp.status).opacity(0.12))
                    .foregroundStyle(statusColor(resp.status))
                    .clipShape(Capsule())
            }
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func stat(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).fontWeight(.medium)
        }
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "success": return .green
        case "partial": return .orange
        default:        return .red
        }
    }
}

// MARK: - Sort / Filter bar

enum SortMode: String, CaseIterable {
    case sizeDesc = "Size ↓"
    case sizeAsc  = "Size ↑"
    case nameAsc  = "Name A–Z"
    case nameDesc = "Name Z–A"
}

struct SortFilterBar: View {
    @Binding var sortMode: SortMode
    @Binding var filterText: String

    var body: some View {
        HStack(spacing: 12) {
            Picker("Sort", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            TextField("Filter name…", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            if !filterText.isEmpty {
                Button { filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension Array where Element == FileEntry {
    func filtered(sort: SortMode, filter: String) -> [FileEntry] {
        var result = self
        if !filter.isEmpty {
            result = result.filter { $0.path.localizedCaseInsensitiveContains(filter) }
        }
        switch sort {
        case .sizeDesc: result.sort { $0.size_bytes > $1.size_bytes }
        case .sizeAsc:  result.sort { $0.size_bytes < $1.size_bytes }
        case .nameAsc:  result.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        case .nameDesc: result.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedDescending }
        }
        return result
    }
}

// MARK: - Confirm Sheet

struct ConfirmDeleteSheet: View {
    let itemCount: Int
    let totalBytes: UInt64
    let topItems: [FileEntry]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "trash.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete \(itemCount) items")
                        .font(.headline)
                    Text(formatBytes(totalBytes))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !topItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Largest items")
                        .font(.caption).foregroundStyle(.tertiary)
                    ForEach(topItems.prefix(5)) { f in
                        HStack {
                            Text(URL(fileURLWithPath: f.path).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(formatBytes(f.size_bytes))
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { onConfirm() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
    }
}

// MARK: - Junk Cleaner

struct JunkCleanerView: View {
    @AppStorage("useTrash") private var useTrash = true
    @State private var loading   = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var selectedBytes: UInt64 {
        response?.files
            .filter { selection.contains($0.path) }
            .map(\.size_bytes).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Junk Cleaner")
                    .font(.title3.bold())
                Spacer()
                if let resp = response, !resp.executed {
                    Button("All") { selection = Set(resp.files.map(\.path)) }
                        .font(.caption)
                    Button("None") { selection = [] }
                        .font(.caption)
                }
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .help("Scan")

                Button { showConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(loading || selection.isEmpty || (response?.executed ?? false))
                .help("Clean selected")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) items · \(formatBytes(scannedBytes))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: selectedBytes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                FileListView(files: resp.files, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Scan to inspect ~/Library/Caches, ~/Library/Logs and ~/.Trash.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            let top   = items.sorted { $0.size_bytes > $1.size_bytes }
            ConfirmDeleteSheet(
                itemCount:  items.count,
                totalBytes: selectedBytes,
                topItems:   top
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: {
                showConfirm = false
            }
        }
    }

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["junk-clean", "--dry-run"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }

        if useTrash {
            response = trashPaths(paths)
            selection = []
            return
        }

        let args: [String]
        if let resp = response, paths.count == resp.files.count {
            args = ["junk-clean", "--execute"]
        } else {
            args = ["delete-paths"] + paths
        }
        do {
            response = try await CoreRunner.run(arguments: args)
            selection = []
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Xcode Cleaner

struct XcodeCleanerView: View {
    @AppStorage("useTrash") private var useTrash = true
    @State private var loading   = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var selectedBytes: UInt64 {
        response?.files
            .filter { selection.contains($0.path) }
            .map(\.size_bytes).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Xcode Cleaner")
                    .font(.title3.bold())
                Spacer()
                if let resp = response, !resp.executed {
                    Button("All") { selection = Set(resp.files.map(\.path)) }
                        .font(.caption)
                    Button("None") { selection = [] }
                        .font(.caption)
                }
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .help("Scan")

                Button { showConfirm = true } label: {
                    Image(systemName: "hammer")
                }
                .disabled(loading || selection.isEmpty || (response?.executed ?? false))
                .help("Clean selected")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) items · \(formatBytes(scannedBytes))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: selectedBytes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                FileListView(files: resp.files, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Scan to find Xcode build artifacts.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            let top   = items.sorted { $0.size_bytes > $1.size_bytes }
            ConfirmDeleteSheet(
                itemCount:  items.count,
                totalBytes: selectedBytes,
                topItems:   top
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: {
                showConfirm = false
            }
        }
    }

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["xcode-clean", "--dry-run"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }

        if useTrash {
            response = trashPaths(paths)
            selection = []
            return
        }

        let args: [String]
        if let resp = response, paths.count == resp.files.count {
            args = ["xcode-clean", "--execute"]
        } else {
            args = ["delete-paths"] + paths
        }
        do {
            response = try await CoreRunner.run(arguments: args)
            selection = []
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - App Uninstaller

struct AppUninstallerView: View {
    @AppStorage("useTrash") private var useTrash = true
    @State private var appPath   = ""
    @State private var loading   = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var selectedBytes: UInt64 {
        response?.files
            .filter { selection.contains($0.path) }
            .map(\.size_bytes).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with path picker
            HStack(spacing: 8) {
                Text("App Uninstaller")
                    .font(.title3.bold())
                Spacer()
                TextField("/Applications/SomeApp.app", text: $appPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: 260)
                    .onDrop(of: [.applicationBundle, .application, .fileURL],
                            isTargeted: nil) { providers in
                        handleDrop(providers)
                    }
                Button("…") { chooseApp() }
                    .help("Choose app")
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading || appPath.isEmpty)

                Button { showConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(loading || appPath.isEmpty || selection.isEmpty
                          || (response?.executed ?? false))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) items · \(formatBytes(scannedBytes))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: selectedBytes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                FileListView(files: resp.files, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Pick a .app bundle (or drag one here), then scan.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            let top   = items.sorted { $0.size_bytes > $1.size_bytes }
            ConfirmDeleteSheet(
                itemCount:  items.count,
                totalBytes: selectedBytes,
                topItems:   top
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: {
                showConfirm = false
            }
        }
    }

    // MARK: Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url  = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                DispatchQueue.main.async {
                    appPath  = url.path
                    response = nil
                    errorText = nil
                    selection = []
                }
            }
            return true
        }
        return false
    }

    // MARK: Panel

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to inspect"
        panel.message = "Pick a .app bundle"
        panel.prompt = "Choose"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = [.applicationBundle, .application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            appPath   = url.path
            response  = nil
            errorText = nil
            selection = []
        }
    }

    // MARK: Actions

    // MARK: Actions (AppUninstaller)

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["uninstall", appPath, "--dry-run"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }

        if useTrash {
            response = trashPaths(paths)
            selection = []
            return
        }

        let args: [String]
        if let resp = response, paths.count == resp.files.count {
            args = ["uninstall", appPath, "--execute"]
        } else {
            args = ["delete-paths"] + paths
        }
        do {
            response = try await CoreRunner.run(arguments: args)
            selection = []
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Large Files Finder

struct LargeFilesView: View {
    @AppStorage("useTrash") private var useTrash = true
    @AppStorage("largeFilesMinMB") private var minMB = 100
    @State private var maxDepth = 8
    @State private var loading   = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var selectedBytes: UInt64 {
        response?.files.filter { selection.contains($0.path) }
            .map(\.size_bytes).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Large Files")
                    .font(.title3.bold())
                Spacer()
                if let resp = response, !resp.executed {
                    Button("All") { selection = Set(resp.files.map(\.path)) }
                        .font(.caption)
                    Button("None") { selection = [] }
                        .font(.caption)
                }
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)
                .help("Scan")

                Button { showConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(loading || selection.isEmpty || (response?.executed ?? false))
                .help("Delete selected")

                if !selection.isEmpty {
                    Button {
                        if let first = selection.first {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: first)])
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal in Finder")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Options bar
            HStack(spacing: 20) {
                HStack(spacing: 6) {
                    Text("Min:")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $minMB) {
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1024)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .onChange(of: minMB) { _ in response = nil; selection = [] }
                }

                HStack(spacing: 6) {
                    Text("Depth:")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $maxDepth) {
                        Text("4").tag(4)
                        Text("6").tag(6)
                        Text("8").tag(8)
                        Text("12").tag(12)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .onChange(of: maxDepth) { _ in response = nil; selection = [] }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) files · \(formatBytes(scannedBytes))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: selectedBytes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                FileListView(files: resp.files, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Scan to find large files in your home folder.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            ConfirmDeleteSheet(
                itemCount: items.count,
                totalBytes: selectedBytes,
                topItems: items.sorted { $0.size_bytes > $1.size_bytes }
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: {
                showConfirm = false
            }
        }
    }

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        let minBytes = UInt64(minMB) * 1024 * 1024
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["large-files", "--min-bytes", "\(minBytes)", "--max-depth", "\(maxDepth)"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }
        if useTrash {
            response = trashPaths(paths); selection = []; return
        }
        do {
            response = try await CoreRunner.run(arguments: ["delete-paths"] + paths)
            selection = []
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Old Installers

struct OldInstallersView: View {
    @AppStorage("useTrash") private var useTrash = true
    @State private var maxAgeDays = 7
    @State private var loading = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var sortMode: SortMode = .sizeDesc
    @State private var filterText = ""
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var displayedFiles: [FileEntry] {
        (response?.files ?? []).filtered(sort: sortMode, filter: filterText)
    }

    private var selectedBytes: UInt64 {
        response?.files
            .filter { selection.contains($0.path) }
            .map(\.size_bytes).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Old Installers")
                    .font(.title3.bold())
                Spacer()
                if let resp = response, !resp.executed {
                    Button("All") { selection = Set(resp.files.map(\.path)) }
                        .font(.caption)
                    Button("None") { selection = [] }
                        .font(.caption)
                }
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)

                Button { showConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(loading || selection.isEmpty || (response?.executed ?? false))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 12) {
                Text("Older than:")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("", selection: $maxAgeDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                .onChange(of: maxAgeDays) { _ in response = nil; selection = [] }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) items · \(formatBytes(scannedBytes))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: selectedBytes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                SortFilterBar(sortMode: $sortMode, filterText: $filterText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                FileListView(files: displayedFiles, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Scan to find .dmg and .pkg files in ~/Downloads.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            ConfirmDeleteSheet(
                itemCount: items.count,
                totalBytes: selectedBytes,
                topItems: items.sorted { $0.size_bytes > $1.size_bytes }
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: { showConfirm = false }
        }
    }

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["old-installers", "--max-age-days", "\(maxAgeDays)", "--dry-run"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }
        if useTrash { response = trashPaths(paths); selection = []; return }
        let args: [String]
        if let resp = response, paths.count == resp.files.count {
            args = ["old-installers", "--execute"]
        } else {
            args = ["delete-paths"] + paths
        }
        do {
            response = try await CoreRunner.run(arguments: args)
            selection = []
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Sweep

struct SweepView: View {
    @AppStorage("useTrash") private var useTrash = true
    @State private var loading = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var sortMode: SortMode = .nameAsc
    @State private var filterText = ""
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var displayedFiles: [FileEntry] {
        (response?.files ?? []).filtered(sort: sortMode, filter: filterText)
    }

    private var selectedBytes: UInt64 {
        response?.files
            .filter { selection.contains($0.path) }
            .map(\.size_bytes).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sweep")
                    .font(.title3.bold())
                Spacer()
                if let resp = response, !resp.executed {
                    Button("All") { selection = Set(resp.files.map(\.path)) }
                        .font(.caption)
                    Button("None") { selection = [] }
                        .font(.caption)
                }
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)

                Button { showConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(loading || selection.isEmpty || (response?.executed ?? false))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) items found")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: selectedBytes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                SortFilterBar(sortMode: $sortMode, filterText: $filterText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                FileListView(files: displayedFiles, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Scan to find broken symlinks and .DS_Store files.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            ConfirmDeleteSheet(
                itemCount: items.count,
                totalBytes: selectedBytes,
                topItems: []
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: { showConfirm = false }
        }
    }

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["sweep", "--dry-run"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }
        if useTrash { response = trashPaths(paths); selection = []; return }
        let args: [String]
        if let resp = response, paths.count == resp.files.count {
            args = ["sweep", "--execute"]
        } else {
            args = ["delete-paths"] + paths
        }
        do {
            response = try await CoreRunner.run(arguments: args)
            selection = []
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Docker Cleaner

struct DockerCleanerView: View {
    @AppStorage("useTrash") private var useTrash = true
    @State private var loading = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var sortMode: SortMode = .sizeDesc
    @State private var filterText = ""
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var displayedFiles: [FileEntry] {
        (response?.files ?? []).filtered(sort: sortMode, filter: filterText)
    }

    private var selectedBytes: UInt64 {
        response?.files
            .filter { selection.contains($0.path) }
            .map(\.size_bytes).reduce(0, +) ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Docker")
                    .font(.title3.bold())
                Spacer()
                if let resp = response, !resp.executed {
                    Button("All") { selection = Set(resp.files.map(\.path)) }
                        .font(.caption)
                    Button("None") { selection = [] }
                        .font(.caption)
                }
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)

                Button { showConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .disabled(loading || selection.isEmpty || (response?.executed ?? false))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) items · \(formatBytes(scannedBytes))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: selectedBytes)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                SortFilterBar(sortMode: $sortMode, filterText: $filterText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                FileListView(files: displayedFiles, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Scan to inspect Docker VM disk images.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            ConfirmDeleteSheet(
                itemCount: items.count,
                totalBytes: selectedBytes,
                topItems: items.sorted { $0.size_bytes > $1.size_bytes }
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: { showConfirm = false }
        }
    }

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["docker-clean", "--dry-run"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }
        if useTrash { response = trashPaths(paths); selection = []; return }
        let args: [String]
        if let resp = response, paths.count == resp.files.count {
            args = ["docker-clean", "--execute"]
        } else {
            args = ["delete-paths"] + paths
        }
        do {
            response = try await CoreRunner.run(arguments: args)
            selection = []
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Login Items

struct LoginItemsView: View {
    @State private var loading = false
    @State private var executing = false
    @State private var response: CliResponse?
    @State private var errorText: String?
    @State private var selection = Set<String>()
    @State private var showConfirm = false
    @State private var sortMode: SortMode = .nameAsc
    @State private var filterText = ""
    @State private var scannedCount = 0
    @State private var scannedBytes: UInt64 = 0

    private var displayedFiles: [FileEntry] {
        (response?.files ?? []).filtered(sort: sortMode, filter: filterText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Login Items")
                    .font(.title3.bold())
                Spacer()
                if let resp = response, !resp.executed {
                    Button("All") { selection = Set(resp.files.map(\.path)) }
                        .font(.caption)
                    Button("None") { selection = [] }
                        .font(.caption)
                }
                Button { Task { await scan() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(loading)

                Button { showConfirm = true } label: {
                    Image(systemName: "pause.circle")
                }
                .disabled(loading || selection.isEmpty || (response?.executed ?? false))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if loading {
                VStack(spacing: 6) {
                    ProgressView()
                    if scannedCount > 0 {
                        Text("\(scannedCount) items found")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let resp = response {
                SummaryBar(resp: resp, selectedBytes: 0)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                SortFilterBar(sortMode: $sortMode, filterText: $filterText)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                FileListView(files: displayedFiles, selection: $selection)
            } else if let err = errorText {
                Text(err).foregroundStyle(.red).textSelection(.enabled)
                    .padding()
            } else {
                Text("Scan to list LaunchAgents and LaunchDaemons.")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showConfirm) {
            let items = response?.files.filter { selection.contains($0.path) } ?? []
            ConfirmDeleteSheet(
                itemCount: items.count,
                totalBytes: 0,
                topItems: []
            ) {
                showConfirm = false
                Task { await execute(paths: items.map(\.path)) }
            } onCancel: { showConfirm = false }
        }
    }

    private func scan() async {
        loading = true; executing = false; errorText = nil; selection = []
        scannedCount = 0; scannedBytes = 0
        defer { loading = false }
        do {
            response = try await CoreRunner.runStreaming(
                arguments: ["login-items", "--dry-run"]
            ) { count, bytes in
                scannedCount = count
                scannedBytes = bytes
            }
            if let resp = response { selection = Set(resp.files.map(\.path)) }
        } catch {
            response = nil; errorText = error.localizedDescription
        }
    }

    private func execute(paths: [String]) async {
        loading = true; executing = true; errorText = nil
        defer { loading = false; executing = false }
        do {
            response = try await CoreRunner.run(arguments: ["login-items", "--execute"] + paths)
            selection = []
        } catch { errorText = error.localizedDescription }
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable {
    var id: Date { timestamp }
    let timestamp: Date
    let paths: [String]
    let totalBytes: UInt64
    let operation: String
}

struct HistoryView: View {
    @AppStorage("deleteHistory") private var historyData = "[]"
    @State private var history: [HistoryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History").font(.title2).bold()
                Spacer()
                if !history.isEmpty {
                    Button("Clear All") { history = []; saveHistory() }
                        .foregroundStyle(.red)
                }
            }

            Text("Recent deletions. Items in Trash can be restored.")
                .font(.caption).foregroundStyle(.secondary)

            if history.isEmpty {
                Text("No deletion history yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
            } else {
                List(history) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.operation.uppercased())
                                .font(.caption).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.15))
                                .clipShape(Capsule())
                            Text(formatBytes(entry.totalBytes))
                                .font(.headline)
                            Spacer()
                            Text(entry.timestamp, style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(entry.paths.count) item(s)")
                            .font(.callout).foregroundStyle(.secondary)
                        ForEach(entry.paths.prefix(5), id: \.self) { path in
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if entry.paths.count > 5 {
                            Text("… and \(entry.paths.count - 5) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer()
        }
        .padding()
        .onAppear { loadHistory() }
    }

    private func loadHistory() {
        guard let data = historyData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        history = decoded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history),
              let str = String(data: data, encoding: .utf8)
        else { return }
        historyData = str
    }
}

// MARK: - Root / Navigation

enum Tab: String, CaseIterable, Identifiable {
    case junk            = "Junk"
    case xcode           = "Xcode"
    case largeFiles      = "Large Files"
    case uninstaller     = "Uninstaller"
    case oldInstallers   = "Installers"
    case sweep           = "Sweep"
    case docker          = "Docker"
    case loginItems      = "Login Items"
    case history         = "History"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .junk:          return "trash"
        case .xcode:         return "hammer"
        case .largeFiles:    return "doc.zipper"
        case .uninstaller:   return "app.badge.checkmark"
        case .oldInstallers: return "archivebox"
        case .sweep:         return "wand.and.stars"
        case .docker:        return "shippingbox"
        case .loginItems:    return "power"
        case .history:       return "clock.arrow.circlepath"
        }
    }
    var tabDescription: String {
        switch self {
        case .junk:          return "Caches, Logs, Trash"
        case .xcode:         return "DerivedData, Archives, Simulators"
        case .largeFiles:    return "Files over a size threshold"
        case .uninstaller:   return "Remove apps and support files"
        case .oldInstallers: return ".dmg and .pkg in Downloads"
        case .sweep:         return "Broken symlinks and .DS_Store"
        case .docker:        return "VM disk images"
        case .loginItems:    return "LaunchAgents and Daemons"
        case .history:       return "Past deletions"
        }
    }
}

struct RootView: View {
    @State private var selection: Tab = .junk
    @AppStorage("useTrash") private var useTrash = true

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(Tab.allCases, selection: $selection) { tab in
                    NavigationLink(value: tab) {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 14))
                                .frame(width: 20)
                                .foregroundStyle(selection == tab ? .white : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.rawValue)
                                    .font(.callout)
                                Text(tab.tabDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                Toggle(isOn: $useTrash) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.caption)
                        Text("Move to Trash")
                            .font(.caption)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle("MacCleaner")
            .frame(minWidth: 180)
        } detail: {
            switch selection {
            case .junk:          JunkCleanerView()
            case .xcode:         XcodeCleanerView()
            case .largeFiles:    LargeFilesView()
            case .uninstaller:   AppUninstallerView()
            case .oldInstallers: OldInstallersView()
            case .sweep:         SweepView()
            case .docker:        DockerCleanerView()
            case .loginItems:    LoginItemsView()
            case .history:       HistoryView()
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

// MARK: - Entry point

@main
struct MacCleanerApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .windowStyle(.titleBar)
    }
}
