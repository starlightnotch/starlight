import AppKit
import ServiceManagement

/// The app was called Notch before it was Starlight. Two things carry over once, on the first
/// launch after the rename:
///
/// - Its data: ~/Library/Application Support/Notch (meetings, dictations, tasks, memory, your
///   voice, the downloaded models) becomes …/Starlight, and Logs/Notch.log becomes Starlight.log.
///   A move on the same disk, so it's instant whatever the size, and nothing is copied or lost.
/// - Its name on disk: an update installs into the old bundle's place (Sparkle keeps the path),
///   so an Applications/Notch.app renames itself Starlight.app and reopens from there.
enum Rebrand {
    /// Before anything reads or writes the data folder.
    static func moveData() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        merge(support.appendingPathComponent("Notch", isDirectory: true), into: support.appendingPathComponent("Starlight", isDirectory: true))
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        let oldLog = logs.appendingPathComponent("Notch.log"), newLog = logs.appendingPathComponent("Starlight.log")
        if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: newLog.path) { try? fm.moveItem(at: oldLog, to: newLog) }
    }

    /// Moves `old` to `new`; where both exist (a build that ran in between made a few files),
    /// moves whatever `new` doesn't have yet, folder by folder, and keeps what's already there.
    private static func merge(_ old: URL, into new: URL) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return }
        if !fm.fileExists(atPath: new.path) {
            do { try fm.moveItem(at: old, to: new) } catch { DebugLog.write("rebrand: couldn't move \(old.path): \(error)") }
            return
        }
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] {
            let from = old.appendingPathComponent(name), to = new.appendingPathComponent(name)
            var fromIsDir: ObjCBool = false, toIsDir: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &fromIsDir)
            if !fm.fileExists(atPath: to.path, isDirectory: &toIsDir) {
                try? fm.moveItem(at: from, to: to)
            } else if fromIsDir.boolValue, toIsDir.boolValue {
                merge(from, into: to)
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: old.path)) ?? ["?"]).filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(at: old)
        }
    }

    private static let reregisterKey = "rebrandReregisterLoginItem"

    /// An installed Notch.app becomes Starlight.app. Returns true when it did and a fresh copy is
    /// opening from the new place (this one then quits). Only in an Applications folder, so a
    /// copy you're running from somewhere else is left alone.
    @MainActor
    static func renameInstalledApp() -> Bool {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent()
        guard bundle.lastPathComponent == "Notch.app", parent.lastPathComponent == "Applications" else {
            reregisterLoginItemIfNeeded()
            return false
        }
        let renamed = parent.appendingPathComponent("Starlight.app")
        guard !fm.fileExists(atPath: renamed.path), fm.isWritableFile(atPath: parent.path) else { return false }
        let wasLoginItem = SMAppService.mainApp.status == .enabled
        do {
            try fm.moveItem(at: bundle, to: renamed)
        } catch {
            DebugLog.write("rebrand: couldn't rename \(bundle.path): \(error)")
            return false
        }
        if wasLoginItem { UserDefaults.standard.set(true, forKey: reregisterKey) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: renamed, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Launch at login pointed at the old name: registered again for the new one.
    private static func reregisterLoginItemIfNeeded() {
        guard UserDefaults.standard.bool(forKey: reregisterKey) else { return }
        UserDefaults.standard.removeObject(forKey: reregisterKey)
        try? SMAppService.mainApp.unregister()
        try? SMAppService.mainApp.register()
    }
}
