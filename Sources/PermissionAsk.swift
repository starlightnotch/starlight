import AppKit

/// When something needs a macOS permission Starlight doesn't have yet, it asks right there, under
/// the notch, with the same bubble as the welcome tour: "Accessibility · types for you  [Allow]".
/// Allow brings up macOS's own prompt, or its page in System Settings ("Turn on Starlight in the
/// list"); once it's allowed, the bubble checks itself and rises back in. Not now puts it away.
///
/// `blocking`: what you tried can't work without it (dictating without the mic), so it asks
/// every time. Otherwise it only helps (pasting for you), and after Not now it waits a day.
@MainActor
final class PermissionAsk: BubbleOwner {
    static let shared = PermissionAsk()

    private var asking: Permission?
    private var blocking = false
    private var lastState: Permission.State?
    private var poll: Timer?
    private var timeout: DispatchWorkItem?
    private let host = BubbleHost.shared

    /// `prompting`: macOS's own prompt for it is already up, so the bubble waits on it instead of
    /// offering Allow.
    func need(_ id: String, blocking: Bool = true, prompting: Bool = false) {
        guard !Render.isRendering, !NotchTour.shared.isRunning, let permission = Permission.named(id) else { return }
        let forced = Dev.env("STARLIGHT_ASK_PERMISSION") == id
        guard forced || !permission.isSettled else { return }
        if !blocking, !forced, let declined = UserDefaults.standard.object(forKey: Self.declinedKey(id)) as? Date,
           Date().timeIntervalSince(declined) < 24 * 3600 { return }
        if asking?.id == id, host.bubble(of: self) != nil { return }
        stop()
        asking = permission
        self.blocking = blocking
        lastState = permission.state()
        DebugLog.write("permission: asking for \(id)\(blocking ? "" : " (nice to have)")")
        show(prompting ? .working : .button("Allow"))
        poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        wait(prompting ? 60 : 30)
    }

    func tap(quiet: Bool, provider: StarlightAccount.Provider?) {
        guard let permission = asking else { return }
        if quiet {
            if !blocking { UserDefaults.standard.set(Date(), forKey: Self.declinedKey(permission.id)) }
            return dismiss()
        }
        // In System Settings it's one switch; the bubble says which, and waits while you find it.
        let inSettings = permission.ask()
        show(.working, label: inSettings ? "Turn on Starlight in the list" : nil)
        wait(120)
    }

    func hold(_ down: Bool) {}

    // MARK: Pieces

    private func show(_ action: NotchBubble.Action, label: String? = nil) {
        guard let permission = asking else { return }
        let bubble = NotchBubble(label: label ?? permission.name, sub: label == nil ? permission.does : nil, action: action,
                                 quiet: action == .check ? nil : "Not now", duringVoice: true)
        host.show(bubble, key: "permission.\(permission.id)", owner: self)
    }

    /// Allowed: a check, a chime, and it rises back in. Said no to macOS's prompt: Allow again,
    /// which now opens System Settings.
    private func check() {
        guard let permission = asking else { return stop() }
        let state = permission.state()
        defer { lastState = state }
        if permission.isSettled, Dev.env("STARLIGHT_ASK_PERMISSION") != permission.id {
            stopWatching()
            Sounds.playSuccess()
            show(.check)
            later(1.6) { [weak self] in self?.dismiss() }
        } else if lastState == .notAsked, state == .notAllowed {
            show(.button("Allow"))
        }
    }

    /// Unanswered for a while: it goes away by itself, and asks again when it's needed again.
    private func wait(_ seconds: Double) {
        timeout?.cancel()
        later(seconds) { [weak self] in self?.dismiss() }
    }

    private func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        timeout?.cancel()
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func dismiss() {
        host.hide(self)
        stop()
    }

    private func stopWatching() {
        poll?.invalidate()
        poll = nil
    }

    private func stop() {
        stopWatching()
        timeout?.cancel()
        timeout = nil
        asking = nil
    }

    private static func declinedKey(_ id: String) -> String { "permissionDeclined.\(id)" }
}
