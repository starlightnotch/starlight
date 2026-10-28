import AppKit
import SwiftUI

/// The Starlight window: past notes and settings. Opens from the notch ("Open notes", "Answer",
/// the gear in the opened notch). Black and white, like the notch.
final class CompanionState: ObservableObject {
    enum Page: Hashable {
        case session(String)
        case meetings
        case history
        case general, motion, dictation, notes, live, shortcuts, ai, memory, tasks, extensions, permissions, usage, about, account
    }

    @Published var page: Page = .general
    /// Pages whose "More settings" are open.
    @Published var unfolded: Set<Page> = []
    /// The group a search result points at: scrolled to, and lit for a moment.
    @Published var highlight: String?
    @Published var scrollTarget: String?

    /// Opens a search result: its page, its "More settings" if it's in there, its group.
    func go(to entry: SettingsIndex.Entry) {
        page = entry.page
        if entry.more { unfolded.insert(entry.page) }
        highlight = entry.group
        scrollTarget = entry.group
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.highlight == entry.group { withAnimation(.easeOut(duration: 0.5)) { self?.highlight = nil } }
        }
    }

    /// A moment to show in a meeting's transcript ("Open at 12:31"), highlighted.
    @Published var focus: MeetingMoment?
    @Published var answering: Set<String> = []
    @Published var errors: [String: String] = [:]

    /// Sends the session's notes to the selected AI service and saves the answers and summary.
    func answer(_ id: String) {
        guard !answering.contains(id), let session = NotesStore.shared.session(id) else { return }
        let settings = AppSettings.shared
        guard settings.hasAnswerKey else {
            errors[id] = OpenRouter.Failure.noKey.errorDescription
            return
        }
        answering.insert(id)
        errors[id] = nil
        Task { @MainActor in
            defer { answering.remove(id) }
            do {
                let key = await settings.loadAnswerKey()
                let reply = try await OpenRouter.answer(session, key: key)
                var updated = NotesStore.shared.session(id) ?? session
                updated.summary = reply.summary
                updated.answers = reply.answers
                updated.answerModel = [reply.model ?? AppSettings.model, reply.provider].compactMap { $0 }.joined(separator: " on ")
                NotesStore.shared.save(updated)
            } catch {
                errors[id] = error.localizedDescription
            }
        }
    }
}

final class CompanionWindow: NSObject, NSWindowDelegate {
    static let shared = CompanionWindow()
    let state = CompanionState()
    /// Hands focus back to the app you were in when the window closes.
    var onClose: (() -> Void)?
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    /// A meeting, scrolled to the moment `time` seconds in.
    func show(_ page: CompanionState.Page, at time: TimeInterval) {
        if case .session(let id) = page { state.focus = MeetingMoment(sessionID: id, time: time) }
        show(page)
    }

    func show(_ page: CompanionState.Page, answer: Bool = false) {
        NotesStore.shared.reload()
        state.page = page
        if window == nil { makeWindow() }
        // Clicks on the notch don't activate the app (its panel is non-activating), so a plain
        // activate() request can be declined; take focus explicitly so typing goes here.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DockIcon.shared.update()
        if answer, case .session(let id) = page { state.answer(id) }
    }

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 720, height: 460)
        window.isReleasedWhenClosed = false
        window.delegate = self
        DockIcon.mark(window)

        window.isOpaque = true
        window.backgroundColor = .black
        window.center()
        // Reopens where you left it. The size comes back before the page is laid out, so the
        // page starts at its top rather than wherever the resize left the scroll.
        window.setFrameAutosaveName("StarlightWindow")
        window.contentView = NSHostingView(rootView: CompanionView(state: state, settings: .shared, store: .shared))
        self.window = window
        CaptureVisibility.apply()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
