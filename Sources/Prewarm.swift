import AppKit
import SwiftUI

/// The first time each kind of notch content appears it's built from nothing (fonts, glyphs,
/// text layout, SwiftUI's own type caches), which cost the first open two frames and the first
/// dictation three. A few seconds after launch, with nothing else going on, each one is drawn
/// once offscreen with made-up content, one per turn of the run loop so nothing waits long.
@MainActor
enum Prewarm {
    static func run(notchSize: CGSize) {
        guard !Render.isRendering, Dev.env("STARLIGHT_NO_PREWARM") == nil else { return }
        let states: [(NotchModel) -> Void] = [
            { $0.state = .open },
            { $0.voice = .recording; $0.partial = "So the launch is moving to the second week of March"; $0.recordingStart = Date() },
            { $0.voice = .processing; $0.processingLabel = "Thinking" },
            { $0.voice = .result("So the launch is moving to the second week of March.") },
            { $0.voice = .answer; $0.liveAnswer = LiveAnswer(question: "?", text: "Rome. The capital since 1871.", finished: true) },
            { $0.notes = .listening; $0.notesStart = Date() },
            { $0.notes = .listening; $0.liveCaption = "Are we still on for March" },
            { $0.toast = .init(icon: .headphones, title: "AirPods Pro", battery: 84) },
        ]
        func step(_ i: Int) {
            guard i < states.count else { return }
            let model = NotchModel()
            model.notchSize = notchSize
            states[i](model)
            let renderer = ImageRenderer(content: NotchView(model: model).frame(width: 640, height: 320, alignment: .top))
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            _ = renderer.nsImage
            DispatchQueue.main.async { step(i + 1) }
        }
        step(0)
    }
}
