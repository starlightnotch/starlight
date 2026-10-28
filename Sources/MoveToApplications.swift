import AppKit

/// Opened straight from the disk image (or from Downloads, where macOS runs a quarantined app
/// from a hidden read-only copy), Starlight can't update itself and is gone once the disk image
/// is ejected. So, like a well-behaved Mac app:
/// - with the same or a newer Starlight already installed, it opens that one instead and quits;
/// - otherwise it offers to move itself to Applications (or to your own Applications folder when
///   that one isn't writable) and opens from there;
/// - and the copy that opens ejects the disk image it came from, which closes its window (also
///   after dragging it to Applications by hand).
enum MoveToApplications {
    /// The disk image to eject once the moved copy is running (set by the copy on it).
    private static let ejectKey = "ejectAfterMove"

    /// This copy is the download (on the disk image, or translocated).
    static var isDownload: Bool { downloadLocation(of: Bundle.main.bundleURL) != nil }

    /// True when another copy is opening (this one then quits). A download that stays running
    /// quits the other copies itself, since Main left them alone.
    @MainActor
    static func offerIfNeeded() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard let download = downloadLocation(of: bundle) else {
            ejectDiskImageLeftBehind()
            return false
        }
        // Opened the download again with Starlight already installed: open that one.
        if let installed = installedCopy(), build(of: installed) >= build(of: bundle) {
            DebugLog.write("move to Applications: already installed at \(installed.path); opening it")
            rememberDiskImage(of: download)
            open(installed, fresh: false)  // already running: it comes forward, no restart
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Starlight to Applications?"
        alert.informativeText = "It's running from the download. In Applications it keeps itself up to date, and the download can go."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Main.quitOtherCopies()  // staying on the disk image: still one Starlight at a time
            return false
        }

        Main.quitOtherCopies()  // the copy being replaced
        let fm = FileManager.default
        let target = applicationsFolder().appendingPathComponent("Starlight.app")
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // An older copy goes to the Trash (not deleted), so nothing is lost.
            if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
            try fm.copyItem(at: bundle, to: target)
        } catch {
            DebugLog.write("move to Applications: \(error)")
            let failed = NSAlert()
            failed.messageText = "Starlight couldn't move itself."
            failed.informativeText = "Drag Starlight from the download into your Applications folder, then open it from there."
            failed.runModal()
            return false
        }
        // macOS already checked this copy; without the download flag, the moved one opens as
        // itself instead of from another hidden copy.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "-r", "com.apple.quarantine", target.path]
        try? xattr.run()
        xattr.waitUntilExit()

        DebugLog.write("move to Applications: moved to \(target.path)")
        rememberDiskImage(of: download)
        open(target, fresh: true)
        return true
    }

    // MARK: Where things are

    /// Where this copy really is, when it's a download: on a disk image, or anywhere macOS runs it
    /// from a hidden copy ("App Translocation"). Nil when it's installed.
    private static func downloadLocation(of bundle: URL) -> URL? {
        if bundle.path.hasPrefix("/Volumes/") { return bundle }
        guard bundle.path.contains("/AppTranslocation/") else { return nil }
        return originalLocation(of: bundle) ?? bundle
    }

    /// The real location behind a translocated copy, from Security's (unpublished, long-stable)
    /// SecTranslocateCreateOriginalPathForURL, as Sparkle and LetsMove use it.
    private static func originalLocation(of url: URL) -> URL? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        return unsafeBitCast(symbol, to: Original.self)(url as CFURL, nil)?.takeRetainedValue() as URL?
    }

    /// Applications, or ~/Applications on an account that can't write to it.
    private static func applicationsFolder() -> URL {
        let shared = URL(fileURLWithPath: "/Applications")
        if FileManager.default.isWritableFile(atPath: shared.path) { return shared }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    private static func installedCopy() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return [URL(fileURLWithPath: "/Applications"), home].map { $0.appendingPathComponent("Starlight.app") }
            .first { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier }
    }

    /// The build number (CFBundleVersion), which only goes up.
    private static func build(of app: URL) -> Int {
        Int(Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    private static func open(_ app: URL, fresh: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = fresh
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            if let error { DebugLog.write("move to Applications: couldn't open \(app.path): \(error)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Ejecting the disk image

    /// The disk image this copy is on, for the copy that opens next to eject.
    private static func rememberDiskImage(of download: URL) {
        guard let volume = (try? download.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              volume.path.hasPrefix("/Volumes/"),
              (try? volume.resourceValues(forKeys: [.volumeIsEjectableKey]))?.volumeIsEjectable == true else { return }
        UserDefaults.standard.set(volume.path, forKey: ejectKey)
    }

    /// Once the copy on the disk image has quit (Main.quitOtherCopies waits for it), eject it.
    /// Opened from Applications after dragging it there by hand, the same: any Starlight disk
    /// image still mounted is ejected.
    private static func ejectDiskImageLeftBehind() {
        var volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        if let remembered = UserDefaults.standard.string(forKey: ejectKey) {
            UserDefaults.standard.removeObject(forKey: ejectKey)
            volumes.append(URL(fileURLWithPath: remembered))
        }
        let installers = Set(volumes.map(\.standardizedFileURL).filter(isInstaller))
        guard !installers.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for volume in installers {
                for attempt in 1...10 {
                    do {
                        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                        DebugLog.write("move to Applications: ejected the disk image")
                        break
                    } catch {
                        // The copy on it may still be closing its files.
                        if attempt == 10 { DebugLog.write("move to Applications: couldn't eject the disk image: \(error)") }
                        Thread.sleep(forTimeInterval: 1)
                    }
                }
            }
        }
    }

    /// Starlight's own disk image, and nothing else: on /Volumes, holding just Starlight (this
    /// app, by its bundle ID) and the Applications shortcut, and not where this copy runs from.
    private static func isInstaller(_ volume: URL) -> Bool {
        let fm = FileManager.default
        guard volume.path.hasPrefix("/Volumes/"), !Bundle.main.bundleURL.path.hasPrefix(volume.path + "/"),
              Bundle(url: volume.appendingPathComponent("Starlight.app"))?.bundleIdentifier == Bundle.main.bundleIdentifier,
              (try? fm.destinationOfSymbolicLink(atPath: volume.appendingPathComponent("Applications").path)) == "/Applications",
              (try? volume.resourceValues(forKeys: [.volumeIsEjectableKey]))?.volumeIsEjectable == true else { return false }
        return true
    }
}
