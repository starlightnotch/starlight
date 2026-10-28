import AppKit
import Sparkle
import SwiftUI

/// Auto-updates through Sparkle: checks once a day in the background. Every update is checked
/// against the EdDSA key and Apple's notarization before it's installed.
///
/// - Automatic (Settings → About → "Install updates automatically", on by default): the update
///   downloads silently and installs the next time Starlight is idle: no dictation, meeting, Live
///   session or open notch, and you away from the keyboard for a couple of minutes (or the screen
///   locked). It restarts in about two seconds and says "Updated" beside the camera.
/// - Off: a quiet "Update" button appears in the top-left of the open notch (and in the menu bar
///   menu); clicking it shows what's new and installs.
///
/// Off in builds made without a feed (`STARLIGHT_FEED_URL` in build.sh), like local test builds.
final class Updater: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// The version waiting to be installed, when there is one.
    @Published private(set) var available: String?

    /// Starlight is in the middle of something (set at launch): never restart for an update then.
    var isBusy: () -> Bool = { false }
    /// Shown after an automatic update restarted the app ("Updated to 1.0.2").
    var onUpdated: (String) -> Void = { _ in }

    /// A downloaded update waiting for an idle moment, and how to install it right away.
    private var pendingInstall: (() -> Void)?
    private var pendingVersion: String?
    private var idleTimer: Timer?
    /// How long you've been away from the keyboard and mouse before it restarts.
    /// `defaults write com.starlightnotch.app updateIdleSeconds 0` for testing.
    private var idleNeeded: TimeInterval {
        UserDefaults.standard.object(forKey: "updateIdleSeconds") as? TimeInterval ?? 120
    }
    private static let updatedKey = "updatedAutomaticallyTo"

    /// For renders: pretend a version is waiting.
    func preview(_ version: String?) { available = version }

    /// There's somewhere to check for updates in this build.
    var isAvailable: Bool { controller != nil }

    func start() {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Just restarted by an automatic update: say so once.
        if let version = UserDefaults.standard.string(forKey: Self.updatedKey) {
            UserDefaults.standard.removeObject(forKey: Self.updatedKey)
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            if version == current {
                DebugLog.write("updates: now running \(version)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.onUpdated(version) }
            }
        }
    }

    /// Install updates on their own (download silently, install when idle). On by default.
    var installsAutomatically: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyDownloadsUpdates = newValue
            // Turning it on also turns checking on: there's nothing to install without a check.
            if newValue { controller?.updater.automaticallyChecksForUpdates = true }
        }
    }

    /// Shows the update (or checks for one) in Sparkle's window.
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastChecked: Date? { controller?.updater.lastUpdateCheckDate }

    // MARK: What happened, in the debug log (an update that never arrives can be traced)

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DebugLog.write("updates: \(item.displayVersionString) (build \(item.versionString)) is available")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DebugLog.write("updates: up to date")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        DebugLog.write("updates: downloaded \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        DebugLog.write("updates: installing \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // "You're up to date" also arrives here; it's already logged above.
        guard (error as NSError).code != Int(SUError.noUpdateError.rawValue) else { return }
        DebugLog.write("updates: stopped: \(error.localizedDescription)")
    }

    // MARK: Installing when idle

    /// An automatic update is downloaded and ready. Instead of waiting for Starlight to quit (it
    /// rarely does), it's installed at the first idle moment.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        DebugLog.write("updates: \(item.displayVersionString) is ready; installing when Starlight is idle")
        DispatchQueue.main.async {
            self.pendingInstall = immediateInstallationBlock
            self.pendingVersion = item.displayVersionString
            self.idleTimer?.invalidate()
            self.idleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.installIfIdle() }
            self.installIfIdle()
        }
        return true
    }

    private func installIfIdle() {
        guard let install = pendingInstall, let version = pendingVersion else { return }
        guard !isBusy() else { return }
        let away = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        guard locked || away >= idleNeeded else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        pendingInstall = nil
        DebugLog.write(String(format: "updates: idle (%@), installing %@ now", locked ? "screen locked" : "away \(Int(away)) s", version))
        UserDefaults.standard.set(version, forKey: Self.updatedKey)
        install()
    }

    // MARK: Gentle reminders: our button instead of Sparkle's window.

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A background check found something: only show Sparkle's window if Starlight is in front anyway.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        DispatchQueue.main.async { withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { self.available = update.displayVersionString } }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        DispatchQueue.main.async { self.available = nil }
    }

    func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async { self.available = nil }
    }
}

/// "Update", top-left of the open notch, when a new version is ready.
struct UpdateButton: View {
    @ObservedObject var updater = Updater.shared
    @State private var hovering = false

    var body: some View {
        if let version = updater.available {
            Button { updater.checkNow() } label: {
                HStack(spacing: 5) {
                    Circle().fill(.black).frame(width: 5, height: 5)
                    Text("Update").font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 9).frame(height: 20)
                .background(Capsule().fill(.white.opacity(hovering ? 1 : 0.9)))
            }
            .buttonStyle(PressableStyle())
            .onHover { hovering = $0 }
            .help("Starlight \(version) is ready to install")
            .transition(.scale(scale: 0.6, anchor: .leading).combined(with: .opacity))
        }
    }
}
