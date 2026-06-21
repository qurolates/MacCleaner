# MacCleaner — Ideas & Roadmap

## 🟢 Quick wins

### Safety / UX
- [ ] **Confirm-dialog before `--execute`** — sheet "Delete 8.8 GB in 141 items?" with top-10 largest files preview
- [ ] **Move to Trash instead of `rm -rf`** — add `--trash` flag to Rust core; much safer default
- [ ] **Checkbox file selection** — let user uncheck items before deleting
- [ ] **Sort list** by size / name / date + name filter
- [ ] **Drag & drop `.app`** into App Uninstaller instead of the "Choose…" button

### Informational
- [ ] **Real-time progress bar** — stream NDJSON from Rust (one JSON line per file), Swift parses via `Pipe.readabilityHandler`
- [ ] **Top-10 largest** summary card above the file list
- [ ] **History / Undo log** — what was deleted, restore from Trash

---

## 🟡 Medium features

### New cleaner categories
- [ ] **Xcode junk** — `~/Library/Developer/Xcode/DerivedData`, Archives, iOS simulators, Xcode caches (often 20–100 GB)
- [ ] **Docker** — `~/Library/Containers/com.docker.docker/Data/vms` (easily 50+ GB)
- [ ] **node_modules scanner** — find all `node_modules` older than N days
- [ ] **Browser caches** — Chrome, Safari, Firefox, Arc, Brave (each has a different path)
- [ ] **Duplicate files** — sha256 hash files in Downloads/Documents, group by hash
- [ ] **Large files** — everything >100 MB under `$HOME`, reveal in Finder
- [ ] **Broken symlinks** and `.DS_Store` sweep
- [ ] **Old installers** — `.dmg`, `.pkg` in `~/Downloads` older than 30 days

### System
- [ ] **LaunchAgents / LoginItems** — list startup items, toggle disable
- [ ] **Disk analyzer** — recursive TreeMap visualization (à la DaisyDisk / GrandPerspective)
- [ ] **Privacy reset** — clear camera/mic/disk permissions for an app via `tccutil`
- [ ] **App finder via Spotlight** — `mdfind "kMDItemContentType == 'com.apple.application-bundle'"` to list all apps

---

## 🔴 Big features

- [ ] **Scheduled cleanup** — `launchd` background agent, menubar shows "X GB freed this week"
- [ ] **Menu-bar app** — disk usage icon + quick Clean without opening main window
- [ ] **Smart Recommendations** — "Xcode hasn't run in 60 days, delete DerivedData (8 GB)?"
- [ ] **Plugin system** — cleaner categories as TOML manifests
- [ ] **Notarized .dmg** for distribution — Developer ID + `notarytool` via CI
- [ ] **Sandboxed Mac App Store version**

---

## 💡 Architectural improvements

- [ ] **Rust unit tests** — `tempfile` crate for fake `$HOME`, test scanner + uninstall logic
- [ ] **`--json-stream` mode** — NDJSON per-file event stream for real-time progress in Swift
- [ ] **Privileged helper** — SMJobBless service for deleting `/Library/...` system caches
- [ ] **Cross-platform** — Rust core already is; swap SwiftUI for Tauri for Linux/Windows

---

## ✅ Recommended order (priority)

1. **Confirm-dialog before delete** — critical safety, ~30 min
2. **Move to Trash instead of `rm -rf`** — safe-by-default, ~1 h
3. **Xcode DerivedData category** — biggest junk on a dev machine, ~1 h
4. **Checkbox file selection** — transforms UX, ~half a day
5. **Large files finder** — best value/effort ratio, ~1 day
