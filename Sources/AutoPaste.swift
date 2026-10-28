import AppKit
import ApplicationServices

/// Settings → Dictation → Paste into text fields: when your cursor is in a text box, the
/// dictation goes straight in (⌘V on your behalf). Anywhere else it's only copied, as before.
/// macOS has to allow Starlight under Privacy & Security → Accessibility, to see where the cursor
/// is and to press ⌘V.
enum AutoPaste {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's Accessibility prompt (it opens System Settings; you switch Starlight on).
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Chat and editor apps built on Electron or Chromium (Claude, ChatGPT, Slack, Discord, Notion,
    /// VS Code…), and browsers, only describe their text boxes once asked to, or not at all; if they
    /// don't say, the cursor in them is almost always in a text box, so they're pasted into anyway.
    static let typingApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "notion.id",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.linear", "md.obsidian", "com.figma.Desktop",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.microsoft.teams2", "us.zoom.xos",
        // Browsers: Chrome tells nothing about rich editors in pages (claude.ai's box reports no
        // focused element at all), and ⌘V on a page with no text box does nothing.
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.mozilla.firefox", "com.apple.Safari", "com.kagi.kagimacOS",
    ]

    /// The cursor is in something you can type into (a text field, a text view, a web editor).
    static func cursorInTextField() -> Bool {
        guard isAllowed, let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps keep their accessibility off until something asks for it.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let known = typingApps.contains(app.bundleIdentifier ?? "")
        var focused: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        if result != .success {
            let system = AXUIElementCreateSystemWide()
            result = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        }
        guard result == .success, let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return known }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let role = role as? String, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success { return true }
        // A web editor (contenteditable) inside a page, or an app that won't say: trust the app.
        if let role = role as? String, ["AXWebArea", "AXGroup", "AXUnknown"].contains(role), known { return true }
        return known
    }

    /// Types `text` in with ⌘V. With "Copy to clipboard" off, whatever was on the clipboard
    /// before is put back afterwards.
    /// What was on the clipboard before the first of quick pastes, and the restore that's waiting.
    /// A second paste before the restore reuses it, so your own clipboard always comes back.
    private static var pendingRestore: (saved: [[NSPasteboard.PasteboardType: Data]], work: DispatchWorkItem)?

    static func paste(_ text: String, keepOnClipboard: Bool) {
        let board = NSPasteboard.general
        var saved: [[NSPasteboard.PasteboardType: Data]] = []
        if let pending = pendingRestore {
            pending.work.cancel()
            saved = pending.saved
            pendingRestore = nil
        } else if !keepOnClipboard {
            saved = (board.pasteboardItems ?? []).map { item in
                Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
            }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DebugLog.write("dictation: pasted \(text.count) characters")
        guard !keepOnClipboard else { return }
        // Put back what was there, once the paste has surely landed (slow apps take a moment),
        // and only if nothing else was copied meanwhile.
        let work = DispatchWorkItem {
            pendingRestore = nil
            guard board.changeCount == ours else { return }
            board.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                board.writeObjects([item])
            }
        }
        pendingRestore = (saved, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
