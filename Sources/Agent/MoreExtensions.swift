import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

// MARK: - Screen

/// Opt-in: lets the agent read what's on screen ("what does this error mean?"). The text of the
/// window you were in (not Starlight's) comes from macOS Accessibility, selected text first; if
/// that yields little (some apps draw their own text) and screen recording is allowed, it falls
/// back to reading a screenshot of that window with on-device text recognition (Vision).
/// Nothing is read unless the agent calls the tool for a question about the screen.
struct ScreenExtension: StarlightExtension {
    let id = "screen"
    let name = "Read the screen"
    let summary = "The window you're in, when you ask about it."
    let glyph = Glyph.Kind.screen2
    var optIn: Bool { true }

    func register(_ api: ExtensionAPI) {
        api.registerTool(AgentTool(
            name: "read_screen",
            description: "Read the text in the window the user is working in (their frontmost app, with any selected text first). Use when they refer to something on their screen: \"this error\", \"this email\", \"this page\", \"this code\", \"what am I looking at\", \"summarize this\".",
            parameters: ["type": "object", "properties": [String: Any]()],
            status: "Reading the screen", glyph: .screen2,
            keywords: ["screen", "window", "error", "this", "page", "email", "code", "looking", "selected", "highlighted"],
            run: { _ in
                if Dev.env("STARLIGHT_DRY_RUN") != nil { return ToolResult(content: "Window of Xcode:\nerror: Value of optional type 'String?' must be unwrapped to a value of type 'String'", display: "Read Xcode (test)") }
                return await ScreenReader.read()
            }))
    }
}

enum ScreenReader {
    static let limit = 12_000

    static func read() async -> ToolResult {
        guard let app = FocusKeeper.lastApp, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return ToolResult(content: "error: no app window to read.")
        }
        let name = app.localizedName ?? "the app"
        var text = ""
        if AXIsProcessTrusted() {
            text = accessibilityText(pid: app.processIdentifier)
        } else {
            await PermissionAsk.shared.need("accessibility")
        }
        if text.count < 200, CGPreflightScreenCaptureAccess(), let ocr = await recognizedText(pid: app.processIdentifier), ocr.count > text.count {
            text = ocr
        }
        // Allowed, and the app still said nothing: it draws its own text, which takes Screen Recording.
        if text.isEmpty, AXIsProcessTrusted(), !CGPreflightScreenCaptureAccess() { await PermissionAsk.shared.need("screen") }
        guard !text.isEmpty else {
            return ToolResult(content: "error: couldn't read \(name)'s window. Turn on Starlight in System Settings → Privacy & Security → Accessibility (and Screen Recording for apps that draw their own text).",
                              display: "Needs Accessibility permission")
        }
        DebugLog.write("screen: read \(text.count) characters from \(name)")
        return ToolResult(content: "Window of \(name):\n" + String(text.prefix(limit)), display: "Read \(name)")
    }

    /// Selected text, then the window's visible text, from the accessibility tree.
    private static func accessibilityText(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        var parts: [String] = []
        if let focused: AXUIElement = value(app, kAXFocusedUIElementAttribute),
           let selected: String = value(focused, kAXSelectedTextAttribute), !selected.isEmpty {
            parts.append("Selected text:\n" + selected)
        }
        if let window: AXUIElement = value(app, kAXFocusedWindowAttribute) {
            if let title: String = value(window, kAXTitleAttribute), !title.isEmpty { parts.append("Title: " + title) }
            var lines: [String] = []
            var total = 0
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 4_000, total < limit {
                let (element, depth) = queue.removeFirst()
                visited += 1
                let role: String = value(element, kAXRoleAttribute) ?? ""
                if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell"].contains(role) {
                    let text: String = value(element, kAXValueAttribute) ?? value(element, kAXTitleAttribute) ?? ""
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, lines.last != trimmed { lines.append(trimmed); total += trimmed.count }
                }
                guard depth < 40, let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { continue }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
            if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success, let result else { return nil }
        return result as? T
    }

    /// A screenshot of the app's front window, read with Vision.
    private static func recognizedText(pid: pid_t) async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows
                .filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 100 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                      configuration: config) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
