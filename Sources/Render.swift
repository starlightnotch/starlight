import SwiftUI

/// `Starlight --render <dir>` writes a PNG of each state, then exits.
/// Lets the shape be checked without screen-recording permission.
@MainActor
enum Render {
    nonisolated(unsafe) static var isRendering = false

    static func run(to dir: URL) {
        isRendering = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notch = CGSize(width: 185, height: 33.5)  // this Mac's physical notch

        let cases: [(String, NotchState, Bool, Bool)] = [
            ("closed", .closed, false, false), ("hover", .closed, true, false),
            ("press", .closed, true, true), ("open", .open, false, false),
        ]
        for (name, state, hovering, pressing) in cases {
            let model = NotchModel()
            model.notchSize = notch
            model.state = state
            model.hovering = hovering
            model.pressing = pressing
            let view = ZStack(alignment: .top) {
                Wallpaper()
                NotchView(model: model).offset(y: -1)
            }
            .frame(width: 900, height: 250)
            save(view, dir.appendingPathComponent("state-\(name).png"))
        }
        // Starting up: the mark and "Ready".
        do {
            let model = NotchModel()
            model.notchSize = notch
            model.launching = true
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 120),
                 dir.appendingPathComponent("state-launch.png"))
        }
        // An update waiting, top-left of the open notch.
        do {
            let model = NotchModel()
            model.notchSize = notch
            model.state = .open
            Updater.shared.preview("1.1")
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 250),
                 dir.appendingPathComponent("state-open-update.png"))
            Updater.shared.preview(nil)
        }

        // The voice model installing: the tour's line and bubble, the notch's own bubble outside
        // the tour, and the note when the polish model is in.
        let installs: [(String, String, NotchBubble?)] = [
            ("install-progress", "Installing my voice.", NotchBubble(label: "Local voice", sub: "440 MB · about 40 seconds left", action: .progress(0.32))),
            ("install-almost", "Installing my voice.", NotchBubble(label: "Local voice", sub: "almost ready", action: .progress(0.78))),
            ("install-done", "Installed. It runs on your Mac.", NotchBubble(label: "Local voice", action: .check)),
            ("install-outside", "", NotchBubble(label: "Loading voice model", action: .progress(0.12))),
            ("install-failed", "Installing my voice.", NotchBubble(label: "Couldn’t download it", sub: "check your internet", action: .button("Try again"), quiet: "Skip")),
            ("install-polish", "", nil),
            ("tour-mic", "Let me hear you.", NotchBubble(label: "Microphone", sub: "hears you", action: .button("Allow"))),
            ("tour-talk-download", "Press, and talk.", NotchBubble(label: "Getting my voice ready", sub: "440 MB", action: .progress(0.32))),
            ("tour-talk", "Press, and talk.", NotchBubble(label: "Press again when you're done", action: .keys("Control + Space", hold: false))),
            ("tour-ai", "Want to ask me questions?", NotchBubble(label: "Connect an AI provider", action: .button("Set up"), quiet: "Not now")),
        ]
        for (name, line, bubble) in installs {
            let model = NotchModel()
            model.notchSize = notch
            // The tour's steps: the download bar under the line until the practice step.
            let download: Double? = name == "tour-mic" ? 0.42 : nil
            if !line.isEmpty {
                model.tutorial = .init(title: line, detail: "", progress: name.hasPrefix("tour-talk") ? 3 : name == "tour-ai" ? 4 : 1, steps: 7,
                                       download: download, keys: name.hasPrefix("tour-talk") ? "Control + Space" : nil)
            }
            if bubble == nil { model.toast = .init(icon: .check, title: "Installed", detail: "Polish model") }
            let view = ZStack(alignment: .top) {
                Wallpaper()
                NotchView(model: model).offset(y: -1)
                if let bubble { BubbleView(bubble: bubble).foregroundStyle(.white).padding(.top, model.size.height + 8) }
            }
            .frame(width: 900, height: 250)
            save(view, dir.appendingPathComponent("state-\(name).png"))
        }

        // Notes states.
        let items = [
            NoteItem(time: 12, text: "Can we move the launch to the second week of March?", isQuestion: true),
            NoteItem(time: 41, text: "I think the onboarding flow needs one more pass.", isQuestion: false),
            NoteItem(time: 75, text: "Who owns the pricing page update?", isQuestion: true),
            NoteItem(time: 102, text: "I'll send the revised deck by Thursday.", isQuestion: false),
        ]
        var result = NoteSession(id: "preview", started: Date(), duration: 754,
                                 items: items + [NoteItem(time: 130, text: "Dana can take the pricing page after the launch.", isQuestion: false,
                                                          speaker: .them, speakerID: "1")])
        result.answers = [.init(question: "Who owns the pricing page update?", answer: "Dana, after the launch.", time: 77)]
        result.speakerNames = ["1": "Dana"]
        let notesCases: [(String, NotesPhase, Bool)] = [
            ("notes-compact", .listening, false), ("notes-live", .listening, true),
            ("notes-finishing", .finishing, false), ("notes-done", .done(result), false),
        ]
        for (name, phase, expanded) in notesCases {
            let model = NotchModel()
            model.notchSize = notch
            model.notes = phase
            model.drawsBarsInSwiftUI = true
            model.notesExpanded = expanded
            model.noteItems = items
            model.notesLevels = [20, 45, 70, 90, 60, 80, 40, 65, 30, 15]
            model.notesStart = Date().addingTimeInterval(-754)
            let view = ZStack(alignment: .top) {
                Wallpaper()
                NotchView(model: model).offset(y: -1)
            }
            .frame(width: 900, height: 320)
            save(view, dir.appendingPathComponent("\(name).png"))
        }
        // The welcome tour, teaching from the notch.
        do {
            let model = NotchModel()
            model.notchSize = notch
            model.tutorial = .init(title: "Hover me", detail: "", invite: true)
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 120),
                 dir.appendingPathComponent("tutorial.png"))
            model.tutorial = .init(title: "Nice.", detail: "", invite: true, learned: true)
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 120),
                 dir.appendingPathComponent("tutorial-learned.png"))
            model.tutorial = .init(title: "You're all set", detail: "Hover me any time.")
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 200),
                 dir.appendingPathComponent("tutorial-done.png"))
        }
        // The corner list, closed and open.
        let taskSample = TaskStore(preview: [
            .init(text: "Call the dentist at 4:30", due: Calendar.current.date(bySettingHour: 16, minute: 30, second: 0, of: Date())),
            .init(text: "Send Dana the pricing deck by Friday", due: TaskStore.dueDate(in: "by Friday")),
            .init(text: "Dana: review the onboarding draft"),
            .init(text: "Brasília became the capital in 1960, replacing Rio de Janeiro.", kind: .answer),
            .init(text: "Book the venue for the March launch", done: true),
        ])
        let closedState = TaskCorner.CornerState()
        save(ZStack(alignment: .bottomTrailing) { Wallpaper(); TaskCornerView(store: taskSample, state: closedState, onExpand: { _ in }).padding(20) }
                .frame(width: 400, height: 140), dir.appendingPathComponent("tasks-tab.png"))
        let openState = TaskCorner.CornerState()
        openState.expanded = true
        save(ZStack(alignment: .bottomTrailing) { Wallpaper(); TaskCornerView(store: taskSample, state: openState, onExpand: { _ in }).padding(20) }
                .frame(width: 430, height: 560), dir.appendingPathComponent("tasks-open.png"))
        let doneState = TaskCorner.CornerState()
        doneState.celebrating = true
        save(ZStack(alignment: .bottomTrailing) { Wallpaper(); TaskCornerView(store: taskSample, state: doneState, onExpand: { _ in }).padding(20) }
                .frame(width: 400, height: 140), dir.appendingPathComponent("tasks-done.png"))

        // Live answers under the compact notch.
        let answers: [(String, LiveAnswer)] = [
            ("answer-thinking", LiveAnswer(question: "What's 15 times 23 plus 7?", status: "Calculating", statusGlyph: .calc)),
            ("answer-streaming", LiveAnswer(question: "What's the fastest mile ever run?", text: "3:43.13 by Hicham El Guerrouj, in Rome in", status: nil)),
            ("answer-tool", LiveAnswer(question: "What's 15 times 23 plus 7?", text: "352.", status: nil,
                                       toolLine: (.calc, "15 × 23 + 7 = 352"), finished: true)),
            ("answer-memory", LiveAnswer(question: "Who owns the pricing page update?", text: "Dana. On Oct 12 you said she'd take the pricing page after the launch.",
                                         status: nil, toolLine: (.memory, "Found 3 in memory"), finished: true)),
        ]
        // A picture for the headline case, fetched the way the app does (synchronously here).
        let baku: NSImage? = {
            guard let data = try? Data(contentsOf: URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/Baku")!),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumb = (json["thumbnail"] as? [String: Any])?["source"] as? String,
                  let imageData = try? Data(contentsOf: URL(string: thumb)!) else { return nil }
            return NSImage(data: imageData)
        }()
        let allAnswers = answers + [
            ("answer-headline", LiveAnswer(question: "How much is 1000 US dollars in Swiss francs?", text: "1,000 USD is about 850 CHF. At today's rate of 0.85.",
                                           status: nil, finished: true)),
            ("answer-image", LiveAnswer(question: "What's the capital of Azerbaijan?", text: "Baku. It sits on the Caspian Sea. [[image: Baku]]",
                                        status: nil, finished: true, image: baku)),
            ("answer-done", LiveAnswer(question: "Add buy milk to my to-do list", status: nil, finished: true,
                                       outcome: .item("Added to Reminders", "Buy milk", icon: "/System/Applications/Reminders.app"))),
            ("answer-opened", LiveAnswer(question: "Open Reminders", status: nil, finished: true,
                                         outcome: .item("Opened", "Reminders", icon: "/System/Applications/Reminders.app"))),
            ("answer-saved", LiveAnswer(question: "Save a groceries note", status: nil, finished: true,
                                        outcome: .item("Saved and opened", "groceries.txt", icon: "/System/Applications/TextEdit.app"))),
            ("answer-cancelled", LiveAnswer(question: "Delete the old screenshots on my desktop", status: nil, finished: true,
                                            outcome: .failed("Cancelled"))),
            ("answer-link", LiveAnswer(question: "What did Dana say about pricing last week?", text: "Dana wants the pricing page live before launch, at $12 a seat. She said it Tuesday.",
                                       status: nil, finished: true, link: MeetingMoment(sessionID: "x", time: 751))),
            ("answer-code", LiveAnswer(question: "Write a palindrome check", text: "Compare the string with its reverse, ignoring case and spaces:\n\n```python\ndef is_palindrome(s: str) -> bool:\n    cleaned = ''.join(c.lower() for c in s if c.isalnum())\n    return cleaned == cleaned[::-1]\n```\n\nIt runs in **O(n)** time and O(n) space. For very long strings, compare from both ends with two indexes instead, which needs no copy.",
                                       status: nil, finished: true)),
            ("answer-ran", LiveAnswer(question: "How much disk space do I have?", text: "**212 GB free** of 494 GB.", status: nil, finished: true,
                                      outcome: .done("Ran df -h /", ends: false))),
        ]
        do {
            let model = NotchModel()
            model.notchSize = notch
            model.notes = .listening
            model.drawsBarsInSwiftUI = true
            model.approval = Approval(title: "Move to Trash", detail: "~/Desktop", action: "Move to Trash", glyph: .trash,
                                      subject: "Screenshot 2026-10-12.png", icon: "/System/Applications/Preview.app")
            model.notesLevels = [20, 45, 70, 90, 60, 80, 40, 65, 30, 15]
            model.notesStart = Date().addingTimeInterval(-754)
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 250),
                 dir.appendingPathComponent("approval.png"))
        }
        for (name, card) in allAnswers {
            let model = NotchModel()
            model.notchSize = notch
            model.notes = .listening
            model.drawsBarsInSwiftUI = true
            model.liveAnswer = card
            model.notesLevels = [20, 45, 70, 90, 60, 80, 40, 65, 30, 15]
            model.notesStart = Date().addingTimeInterval(-754)
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 250),
                 dir.appendingPathComponent("\(name).png"))
        }
        // Long text: wraps inside the notch and scrolls, fading at the top.
        let longAnswer = "On Oct 12 you said Dana would take the pricing page after the launch, and that the onboarding flow needs one more pass before the beta goes out to fifty people next week."
        let longCases: [(String, (NotchModel) -> Void)] = [
            ("long-caption", { $0.liveCaption = "So I was thinking that if we move the launch to the second week of March we would need the pricing page and the onboarding flow finished by the end of February at the latest" }),
            ("long-answer", { $0.liveAnswer = LiveAnswer(question: "Who owns the pricing page update?", text: longAnswer, status: nil, finished: false) }),
        ]
        for (name, setup) in longCases {
            let model = NotchModel()
            model.notchSize = notch
            model.notes = .listening
            model.drawsBarsInSwiftUI = true
            model.notesLevels = [20, 45, 70, 90, 60, 80, 40, 65, 30, 15]
            model.notesStart = Date().addingTimeInterval(-754)
            setup(model)
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 250),
                 dir.appendingPathComponent("\(name).png"))
        }
        let dictation = NotchModel()
        dictation.notchSize = notch
        dictation.voice = .result("So the notch should feel instant, living right inside the notch, with the voice lines animating as I talk, and the result should wrap neatly instead of getting cut off at the curved corners of the notch.")
        dictation.drawsBarsInSwiftUI = true
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: dictation).offset(y: -1) }.frame(width: 900, height: 250),
             dir.appendingPathComponent("long-result.png"))

        // An answer, hovered: Copy, Keep and Close in the corner.
        do {
            LiveAnswerCard.previewHover = true
            let model = NotchModel()
            model.notchSize = notch
            model.voice = .answer
            model.liveAnswer = LiveAnswer(question: "Who is Magnus Carlsen?", text: "Magnus Carlsen. A Norwegian chess grandmaster, world champion from 2013 to 2023, and the highest-rated player in history.", status: nil, finished: true)
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 250),
                 dir.appendingPathComponent("answer-hover.png"))
            LiveAnswerCard.previewHover = false
        }
        // Hold to ask: thinking after you let go, then the answer in the dictation notch.
        let askCases: [(String, (NotchModel) -> Void)] = [
            ("ask-thinking", { $0.voice = .processing; $0.processingLabel = "Thinking"; $0.levels = (0..<VoiceLayout.barCount).map { 34 + Int(24 * sin(Double($0) * 0.42)) } }),
            ("ask-answer", { $0.voice = .answer; $0.liveAnswer = LiveAnswer(question: "Who is Magnus Carlsen?", text: "Magnus Carlsen. A Norwegian chess grandmaster, world champion from 2013 to 2023, and the highest-rated player in history.", status: nil, finished: true) }),
            ("ask-opened", { $0.voice = .answer; $0.liveAnswer = LiveAnswer(question: "Open my weather", text: "", status: nil, finished: true, outcome: .item("Opened", "Weather", icon: "/System/Applications/Weather.app")) }),
        ]
        for (name, setup) in askCases {
            let model = NotchModel()
            model.notchSize = notch
            model.drawsBarsInSwiftUI = true
            setup(model)
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 250),
                 dir.appendingPathComponent("\(name).png"))
        }

        let prompt = NotchModel()
        prompt.notchSize = notch
        prompt.meetingPrompt = MeetingApp(bundleID: "us.zoom.xos", name: "Zoom")
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: prompt).offset(y: -1) }.frame(width: 900, height: 160),
             dir.appendingPathComponent("meeting-prompt.png"))

        // Now Playing: beside the closed notch, and the open notch's media row; a headphones note.
        let sample = NowPlaying.Track(source: .spotify, title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                      isPlaying: true, artwork: nil)
        let music = NotchModel()
        music.notchSize = notch
        music.nowPlaying = sample
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: music).offset(y: -1) }.frame(width: 900, height: 120),
             dir.appendingPathComponent("music-closed.png"))
        let musicHover = NotchModel()
        musicHover.notchSize = notch
        musicHover.nowPlaying = sample
        musicHover.hovering = true
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: musicHover).offset(y: -1) }.frame(width: 900, height: 160),
             dir.appendingPathComponent("music-hover.png"))
        // Monitor mode: nothing at rest, not even the music; hovering where it would be brings it back.
        for (name, hovering) in [("hidden", false), ("hidden-hover", true)] {
            let model = NotchModel()
            model.notchSize = notch
            model.hidesIdle = true
            model.nowPlaying = hovering ? nil : sample
            model.hovering = hovering
            save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 120),
                 dir.appendingPathComponent("monitor-\(name).png"))
        }
        // The open notch at each text size: the layout must fit the shape at all four.
        do {
            let saved = TextScale.factor
            for size in AppSettings.TextSize.allCases {
                TextScale.factor = size.factor
                let model = NotchModel()
                model.notchSize = notch
                model.state = .open
                model.headphonesBattery = .init(name: "AirPods Pro", percent: 84)
                save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: model).offset(y: -1) }.frame(width: 900, height: 260),
                     dir.appendingPathComponent("open-\(size.rawValue).png"))
            }
            TextScale.factor = saved
        }
        let musicOpen = NotchModel()
        musicOpen.notchSize = notch
        musicOpen.state = .open
        musicOpen.headphonesBattery = .init(name: "AirPods Pro", percent: 84)
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: musicOpen).offset(y: -1) }.frame(width: 900, height: 300),
             dir.appendingPathComponent("music-open.png"))
        let toast = NotchModel()
        toast.notchSize = notch
        toast.toast = .init(icon: .headphones, title: "AirPods Pro", battery: 84)
        let keyboard = NotchModel()
        keyboard.notchSize = notch
        keyboard.toast = .init(icon: .keycap, title: "Magic Keyboard", battery: 12)
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: keyboard).offset(y: -1) }.frame(width: 900, height: 120),
             dir.appendingPathComponent("keyboard-toast.png"))
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: toast).offset(y: -1) }.frame(width: 900, height: 120),
             dir.appendingPathComponent("headphones-toast.png"))

        let openModel = NotchModel()
        openModel.notchSize = notch
        openModel.state = .open
        save(ZStack(alignment: .top) { Wallpaper(); NotchView(model: openModel).offset(y: -1) }.frame(width: 900, height: 250),
             dir.appendingPathComponent("open-start-notes.png"))

        // Dictation states, with a fake mid-sentence level frame.
        let speech = (0..<VoiceLayout.barCount).map { i in Int(55 + 40 * sin(Double(i) * 0.9) * cos(Double(i) * 0.31)) }
        let voiceCases: [(String, VoicePhase, String)] = [
            ("voice-recording", .recording, ""),
            ("voice-recording-live", .recording, "so the notch should feel instant and"),
            ("voice-recording-long", .recording, "so the notch should feel instant and living right inside the notch with the voice lines animating as I talk and the words wrapping"),
            ("voice-processing", .processing, ""),
            ("voice-done", .done(copied: true), ""),
            ("voice-result", .result("So the notch should feel instant, living right inside the notch with the voice lines animating as I talk."), ""),
        ]
        for (name, phase, partial) in voiceCases {
            let model = NotchModel()
            model.notchSize = notch
            model.voice = phase
            model.drawsBarsInSwiftUI = true
            model.partial = partial
            model.levels = phase == .processing ? (0..<VoiceLayout.barCount).map { Int(34 + 24 * sin(1.3 - Double($0) * 0.42)) } : speech
            model.recordingStart = Date().addingTimeInterval(-7)
            let view = ZStack(alignment: .top) {
                Wallpaper()
                NotchView(model: model).offset(y: -1)
            }
            .frame(width: 900, height: 250)
            save(view, dir.appendingPathComponent("\(name).png"))
        }
    }

    /// Pages of the Starlight window. AppKit-backed controls (switches, pickers) don't draw here.
    static func renderWindow(to dir: URL) {
        isRendering = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The welcome tour, each step.
        for step in OnboardingState.Step.allCases {
            let state = OnboardingState()
            state.step = step
            state.dictationAtStart = DictationHistory.shared.entries.first?.id
            save(OnboardingView(state: state, model: NotchModel(), finish: {}).frame(width: 860, height: 640), dir.appendingPathComponent("welcome-\(step.rawValue).png"))
        }
        // Try it, while the voice model is still downloading.
        do {
            let state = OnboardingState()
            state.step = .tryIt
            let model = NotchModel()
            model.engineStatus = .loading("Downloading voice model", 0.64)
            save(OnboardingView(state: state, model: model, finish: {}).frame(width: 860, height: 640), dir.appendingPathComponent("welcome-downloading.png"))
        }
        // Trying it: the words as they're heard.
        do {
            let state = OnboardingState()
            state.step = .tryIt
            state.dictationAtStart = DictationHistory.shared.entries.first?.id
            let model = NotchModel()
            model.voice = .recording
            model.partial = "So this is what it looks like when I talk to my Mac"
            save(OnboardingView(state: state, model: model, finish: {}).frame(width: 860, height: 640), dir.appendingPathComponent("welcome-trying.png"))
        }
        // Trying it: just pressed, nothing said yet (the keys down and lit, the bars).
        do {
            let state = OnboardingState()
            state.step = .tryIt
            state.dictationAtStart = DictationHistory.shared.entries.first?.id
            let model = NotchModel()
            model.voice = .recording
            model.levels = (0..<VoiceLayout.barCount).map { 20 + Int(30 * abs(sin(Double($0) * 0.5))) }
            save(OnboardingView(state: state, model: model, finish: {}).frame(width: 860, height: 640), dir.appendingPathComponent("welcome-listening.png"))
        }
        // Learning your voice, in each state.
        for (name, phase, progress, level) in [("ready", VoiceEnrollment.Phase.ready, 0.0, 0.0), ("listening", .listening, 0.45, 0.7),
                                               ("learning", .finishing, 1.0, 0.0), ("done", .done, 1.0, 0.0)] {
            let panel = VoiceEnrollView(enrollment: VoiceEnrollment(preview: phase, progress: progress, level: level))
                .padding(28).frame(width: 640, height: 230)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white.opacity(0.06)))
                .padding(30).background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
            save(panel, dir.appendingPathComponent("voice-\(name).png"))
        }
        let pages: [(String, CompanionState.Page)] = [("general", .general), ("history", .history), ("dictation", .dictation), ("meetings", .meetings), ("notes-settings", .notes), ("live", .live),
                                                      ("answers", .ai), ("shortcuts", .shortcuts), ("privacy", .permissions), ("account", .account), ("about", .about), ("tasks", .tasks), ("memory", .memory)]
            + (NotesStore.shared.sessions.first.map { [("session", CompanionState.Page.session($0.id))] } ?? [])
        let kinds: [Glyph.Kind] = [.voice, .note, .noteLive, .noteAnswered, .history, .sliders, .screen, .spring, .keycap,
                                   .spark, .check, .alert, .folder, .trash, .rewind, .close, .external, .key, .search, .calc, .memory, .puzzle, .globe, .posts, .agent, .battery, .headphones, .play, .pause, .next, .previous, .screen2, .export, .copy, .mouse, .bluetooth]
        let sheet = VStack(alignment: .leading, spacing: 18) {
            ForEach([false, true], id: \.self) { active in
                HStack(spacing: 18) {
                    ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in Glyph(kind: kind, size: 36, active: active) }
                }
            }
            HStack(spacing: 14) {
                ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in Glyph(kind: kind, size: 15) }
            }
            HStack(spacing: 12) {
                GlyphWell(kind: .voice); GlyphWell(kind: .noteLive); GlyphWell(kind: .noteAnswered, active: true); GlyphWell(kind: .sliders, size: 26)
            }
        }
        .padding(24).foregroundStyle(.white).background(Color.black)
        save(sheet, dir.appendingPathComponent("glyphs.png"))

        // The live transcript overlay, mid-meeting.
        let live = NotchModel()
        live.notes = .listening
        live.notesStart = Date().addingTimeInterval(-312)
        live.noteItems = [
            NoteItem(time: 3, text: "Hi, thanks for joining the call.", isQuestion: false, speaker: .them),
            NoteItem(time: 6, text: "Quick question for you, what is the population of Australia right now?", isQuestion: true, speaker: .them),
            NoteItem(time: 14, text: "Sure. And what's 15% of 240?", isQuestion: true, speaker: .me),
            NoteItem(time: 22, text: "Also, could you send me the deck after this?", isQuestion: true, speaker: .them),
            NoteItem(time: 26, text: "Yeah, I'll send it over tonight.", isQuestion: false, speaker: .me),
            NoteItem(time: 31, text: "What's the difference between ARR and MRR again?", isQuestion: true, speaker: .them),
        ]
        live.agentReplies = [
            AgentReply(time: 9, text: "About 28 million, as of October 2026."),
            AgentReply(time: 16, text: "36."),
            AgentReply(time: 33, text: "ARR is annual recurring revenue; MRR is monthly. ARR = MRR × 12."),
            AgentReply(time: 45, text: "", streaming: true),
            AgentReply(time: 40, text: "```python\nnumbers = list(map(int, input().split()))\ntotal = sum(numbers)\nprint(total - max(numbers), total - min(numbers))\n```\nSubtract the largest for the **minimum** sum and the smallest for the **maximum**. O(n) time."),
        ]
        live.liveCaption = "So if we move the launch to March we'd need"
        live.thinkingCount = 1
        save(TranscriptView(model: live, onClose: {}).frame(width: 600, height: 760).padding(30).background(Wallpaper()),
             dir.appendingPathComponent("transcript.png"))
        // A meeting with speakers and a timeline.
        var meeting = NoteSession(id: "render-meeting", started: Date().addingTimeInterval(-3600), duration: 1520, items: [
            NoteItem(time: 4, text: "Thanks everyone for joining. Let's start with the Q2 launch.", isQuestion: false, speaker: .them, speakerID: "1"),
            NoteItem(time: 21, text: "Are we still on track for the second week of April?", isQuestion: true, speaker: .them, speakerID: "1"),
            NoteItem(time: 38, text: "Mostly. The pricing page still needs a final review.", isQuestion: false, speaker: .me),
            NoteItem(time: 402, text: "On pricing, I'd like to test a usage-based tier.", isQuestion: false, speaker: .them, speakerID: "2"),
            NoteItem(time: 430, text: "What would that do to churn?", isQuestion: true, speaker: .me),
            NoteItem(time: 455, text: "Short term it might go up, but expansion revenue should cover it.", isQuestion: false, speaker: .them, speakerID: "2"),
            NoteItem(time: 1180, text: "Okay, Dana takes the pricing review, mockups by Friday.", isQuestion: false, speaker: .them, speakerID: "1"),
        ])
        meeting.speakerNames = ["1": "Dana"]
        meeting.chapters = [
            .init(start: 0, title: "Q2 launch timing", summary: "Dana checked the April date; launch is on track pending the pricing page."),
            .init(start: 395, title: "Usage-based pricing tier", summary: "Speaker 2 proposed a usage tier; you asked about churn."),
            .init(start: 840, title: "Onboarding flow fixes", summary: "Walked through the three drop-off points in the signup flow."),
            .init(start: 1160, title: "Owners and next steps", summary: "Dana owns the pricing review, mockups due Friday."),
        ]
        save(SessionDetail(session: meeting, state: CompanionState()).padding(32).frame(width: 680, height: 1180, alignment: .top)
                .foregroundStyle(.white).background(Color.black).preferredColorScheme(.dark),
             dir.appendingPathComponent("window-meeting.png"))

        for (name, page) in pages {
            let state = CompanionState()
            state.page = page
            state.unfolded = [page]  // "More settings" open, to see everything
            save(CompanionView(state: state, settings: .shared, store: .shared).frame(width: 900, height: 1500),
                 dir.appendingPathComponent("window-\(name).png"))
        }
    }

    static func save(_ view: some View, _ url: URL) {
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let img = r.cgImage else { print("render failed \(url.lastPathComponent)"); return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}

/// A soft desktop behind the notch in renders.
struct Wallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.62, green: 0.72, blue: 0.95), Color(red: 0.95, green: 0.7, blue: 0.62)],
                       startPoint: .top, endPoint: .bottom)
    }
}
