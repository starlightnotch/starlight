import AppKit
import SwiftUI

/// Product shots for the website and the App Store-style gallery: `Starlight --render-marketing <dir>`.
/// Each one is the real interface, drawn by the app itself, larger than life on a calm desktop
/// with one headline. 2880×1800 (a 16:10 Retina screen).
@MainActor
enum Marketing {
    static let canvas = CGSize(width: 1440, height: 900)
    /// How much bigger than life the notch is drawn, so it reads in a picture.
    static let zoom: CGFloat = 1.7
    private static let notch = CGSize(width: 185, height: 33.5)

    static func render(to dir: URL) {
        Render.isRendering = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. The open notch.
        let home = model { $0.state = .open }
        shot(dir, "1-home", title: "Your notch, made useful.",
             detail: "Dictate, ask and take notes, right from the top of your screen.") { NotchView(model: home) }

        // 2. Dictation, words coming in.
        let speech = (0..<VoiceLayout.barCount).map { i in Int(55 + 40 * sin(Double(i) * 0.9) * cos(Double(i) * 0.31)) }
        let dictating = model {
            $0.voice = .recording
            $0.levels = speech
            $0.partial = "Hey Sam, the deck is ready. I moved pricing to the end and tightened the intro"
            $0.recordingStart = Date().addingTimeInterval(-9)
        }
        shot(dir, "2-dictate", title: "Talk. It types.",
             detail: "On-device dictation, cleaned up and pasted wherever you're writing.") { NotchView(model: dictating) }

        // 3. An answer, the moment you finish asking.
        let baku = picture("Baku")
        let answer = model {
            $0.notes = .listening
            $0.sessionKind = .live
            $0.notesLevels = [20, 45, 70, 90, 60, 80, 40, 65, 30, 15]
            $0.notesStart = Date().addingTimeInterval(-94)
            $0.liveAnswer = LiveAnswer(question: "What's the capital of Azerbaijan?", text: "Baku. It sits on the Caspian Sea. [[image: Baku]]",
                                       status: nil, finished: true, image: baku)
        }
        shot(dir, "3-ask", title: "Ask out loud.",
             detail: "Answers appear in the notch the moment you finish speaking.") { NotchView(model: answer) }

        // 4. A plain fact, big.
        let fact = model {
            $0.notes = .listening
            $0.sessionKind = .live
            $0.notesLevels = [20, 45, 70, 90, 60, 80, 40, 65, 30, 15]
            $0.notesStart = Date().addingTimeInterval(-41)
            $0.liveAnswer = LiveAnswer(question: "How much is 1000 US dollars in Swiss francs?",
                                       text: "1,000 USD is about 850 CHF. At today's rate of 0.85.", status: nil, finished: true)
        }
        shot(dir, "4-answers", title: "Big, clear answers.",
             detail: "Numbers, facts and conversions, with nothing in the way.") { NotchView(model: fact) }

        // 5. A meeting: the notch and the transcript window.
        let meeting = meetingModel()
        shot(dir, "5-meetings", title: "Every meeting,\nwritten down.",
             detail: "Both sides of the call, with answers as questions come up. Saved on your Mac.",
             textLeading: true) {
            NotchView(model: meeting)
        } extra: {
            TranscriptView(model: meeting, onClose: {})
                .frame(width: 520, height: 620)
                .shadow(color: .black.opacity(0.35), radius: 40, y: 20)
                .padding(.trailing, 90)
                .padding(.top, 150)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }

        // 6. Tasks in the corner.
        let tasks = TaskStore(preview: [
            .init(text: "Send Sam the final deck", due: TaskStore.dueDate(in: "tomorrow at 5pm")),
            .init(text: "Book the venue for the March launch", due: TaskStore.dueDate(in: "by Friday")),
            .init(text: "Review the onboarding draft"),
            .init(text: "Call the dentist", due: TaskStore.dueDate(in: "next Monday at 10am")),
        ])
        let open = TaskCorner.CornerState()
        open.expanded = true
        shot(dir, "6-tasks", title: "Your tasks,\nin the corner.",
             detail: "Filled in from what you say. Tick them off when they're done.", textLeading: true) {
            NotchView(model: model { _ in })
        } extra: {
            TaskCornerView(store: tasks, state: open, onExpand: { _ in })
                .scaleEffect(1.35, anchor: .bottomTrailing)
                .padding(.trailing, 70).padding(.bottom, 70)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }

        // 7. Now Playing.
        let music = model {
            $0.nowPlaying = NowPlaying.Track(source: .spotify, title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                             isPlaying: true, artwork: nil)
            $0.hovering = true
        }
        shot(dir, "7-now-playing", title: "What's playing,\nright there.",
             detail: "Spotify, Music, YouTube, any app. Play, pause and skip from the notch.") { NotchView(model: music) }

        // 8. Hello.
        shot(dir, "8-hello", title: "", detail: "") {
            NotchView(model: model { $0.tutorial = .init(title: "This is Starlight", detail: "Hover me any time.") })
        } extra: {
            VStack(spacing: 26) {
                HelloWriting().frame(width: 560, height: 220).colorMultiply(.black)
                Text("Private by design. Your voice never leaves your Mac.")
                    .font(.system(size: 26, weight: .medium)).foregroundStyle(.black.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 120)
        }
    }

    // MARK: Building blocks

    private static func model(_ setup: (NotchModel) -> Void) -> NotchModel {
        let model = NotchModel()
        model.notchSize = notch
        model.drawsBarsInSwiftUI = true
        setup(model)
        return model
    }

    private static func meetingModel() -> NotchModel {
        model {
            $0.notes = .listening
            $0.notesLevels = [20, 45, 70, 90, 60, 80, 40, 65, 30, 15]
            $0.notesStart = Date().addingTimeInterval(-1312)
            $0.noteItems = [
                NoteItem(time: 4, text: "Thanks for making time. Let's go through the launch plan.", isQuestion: false, speaker: .them, speakerID: "1"),
                NoteItem(time: 19, text: "Are we still on track for the second week of March?", isQuestion: true, speaker: .them, speakerID: "1"),
                NoteItem(time: 31, text: "Mostly. The pricing page needs one more review.", isQuestion: false, speaker: .me),
                NoteItem(time: 52, text: "What's the difference between ARR and MRR again?", isQuestion: true, speaker: .them, speakerID: "1"),
                NoteItem(time: 70, text: "Okay. I'll send the revised deck by Thursday.", isQuestion: false, speaker: .me),
            ]
            $0.agentReplies = [AgentReply(time: 55, text: "ARR is annual recurring revenue; MRR is monthly. ARR = MRR × 12.")]
            $0.speakerNames = ["1": "Sam"]
        }
    }

    /// A Wikipedia picture, fetched the way the app does.
    private static func picture(_ title: String) -> NSImage? {
        guard let data = try? Data(contentsOf: URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(title)")!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumb = (json["thumbnail"] as? [String: Any])?["source"] as? String,
              let url = URL(string: thumb), let image = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: image)
    }

    private static func shot(_ dir: URL, _ name: String, title: String, detail: String, textLeading: Bool = false,
                             @ViewBuilder notch: () -> some View) {
        shot(dir, name, title: title, detail: detail, textLeading: textLeading, notch: notch) { EmptyView() }
    }

    /// The desktop, the notch hanging from the top (drawn larger), anything else, and the words.
    private static func shot(_ dir: URL, _ name: String, title: String, detail: String, textLeading: Bool = false,
                             @ViewBuilder notch: () -> some View, @ViewBuilder extra: () -> some View) {
        let view = ZStack(alignment: .top) {
            Desktop()
            notch()
                .frame(width: canvas.width / zoom, height: canvas.height / zoom, alignment: .top)
                .offset(y: -1)
                .scaleEffect(zoom, anchor: .top)
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
            extra()
            if !title.isEmpty {
                VStack(alignment: textLeading ? .leading : .center, spacing: 18) {
                    Text(title)
                        .font(.system(size: 76, weight: .bold))
                        .tracking(-1.5)
                        .multilineTextAlignment(textLeading ? .leading : .center)
                    Text(detail)
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.black.opacity(0.55))
                        .multilineTextAlignment(textLeading ? .leading : .center)
                        .frame(maxWidth: textLeading ? 520 : 820, alignment: textLeading ? .leading : .center)
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textLeading ? .bottomLeading : .bottom)
                .padding(.horizontal, 110)
                .padding(.bottom, 120)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
        .environment(\.colorScheme, .light)
        Render.save(view, dir.appendingPathComponent("\(name).png"))
    }
}

/// A calm, bright desktop: soft light from the top, warm toward the bottom, a menu bar.
private struct Desktop: View {
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.93, green: 0.94, blue: 0.97), Color(red: 0.97, green: 0.95, blue: 0.93)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.80, green: 0.85, blue: 0.97).opacity(0.7), .clear],
                           center: .init(x: 0.15, y: 0.1), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [Color(red: 0.99, green: 0.86, blue: 0.80).opacity(0.6), .clear],
                           center: .init(x: 0.9, y: 0.95), startRadius: 0, endRadius: 820)
            // The menu bar: a light translucent strip, as tall as the notch.
            Rectangle().fill(.white.opacity(0.45)).frame(height: 33.5 * Marketing.zoom)
                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.05)).frame(height: 1) }
        }
    }
}
