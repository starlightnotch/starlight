import AppKit
import SwiftUI

/// The voice bars: thin rounded bars across the notch, tallest in the middle and tapering to
/// the edges (a raised-cosine envelope), brighter the taller they are. Each new set of levels
/// animates in over a few frames, so the motion reads as smooth.
final class VoiceBarsNSView: NSView {
    var levels: [Int] = [] { didSet { updateBars(animated: true) } }
    var maxHeight: CGFloat = VoiceLayout.barMaxHeight
    private var bars: [CALayer] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateBars(animated: false)
    }

    private func ensureBars(_ count: Int) {
        guard bars.count != count, let root = layer else { return }
        bars.forEach { $0.removeFromSuperlayer() }
        bars = (0..<count).map { _ in
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = VoiceLayout.barWidth / 2
            root.addSublayer(bar)
            return bar
        }
    }

    private func updateBars(animated: Bool) {
        let n = levels.count
        ensureBars(n)
        guard n > 0 else { return }
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.09)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        let total = CGFloat(n) * VoiceLayout.barPitch
        let startX = (bounds.width - total) / 2 + (VoiceLayout.barPitch - VoiceLayout.barWidth) / 2
        for (i, bar) in bars.enumerated() {
            let (h, opacity) = VoiceLayout.bar(i, of: n, level: levels[i], maxHeight: maxHeight)
            bar.frame = CGRect(x: startX + CGFloat(i) * VoiceLayout.barPitch, y: bounds.midY - h / 2,
                               width: VoiceLayout.barWidth, height: h)
            bar.opacity = Float(opacity)
        }
        CATransaction.commit()
    }
}

/// The same bars drawn in SwiftUI, for the PNG renderer.
struct VoiceBarsCanvas: View {
    var levels: [Int]
    var body: some View {
        Canvas { ctx, size in
            let n = levels.count
            let total = CGFloat(n) * VoiceLayout.barPitch
            let startX = (size.width - total) / 2 + (VoiceLayout.barPitch - VoiceLayout.barWidth) / 2
            for i in 0..<n {
                let (h, opacity) = VoiceLayout.bar(i, of: n, level: levels[i], maxHeight: VoiceLayout.barMaxHeight)
                let rect = CGRect(x: startX + CGFloat(i) * VoiceLayout.barPitch, y: size.height / 2 - h / 2,
                                  width: VoiceLayout.barWidth, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: VoiceLayout.barWidth / 2),
                         with: .color(.white.opacity(opacity)))
            }
        }
    }
}

struct VoiceBars: NSViewRepresentable {
    var levels: [Int]
    func makeNSView(context: Context) -> VoiceBarsNSView { VoiceBarsNSView() }
    func updateNSView(_ view: VoiceBarsNSView, context: Context) { view.levels = levels }
}

/// What the notch shows while dictating. The top row sits beside the physical notch (the "wings");
/// the bars and text sit below it.
///
/// `phase` is passed in rather than read from the model: when dictation ends, this view stays
/// on screen for its closing animation, and reading the model's (already idle) phase made it
/// relayout at the closed notch's width mid-animation, so the text slid off to the right while
/// the black shape was still shrinking. Passed in, it keeps its last phase and shrinks whole.
struct VoiceContent: View {
    @ObservedObject var model: NotchModel
    let phase: VoicePhase
    var onStop: (() -> Void)?

    var body: some View {
        let size = model.voiceSize(phase, partial: model.partial)
        let wingWidth = (size.width - model.closedSize.width) / 2 - 16
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing.frame(width: max(wingWidth, 0), alignment: .leading)
                Spacer(minLength: model.closedSize.width)
                rightWing.frame(width: max(wingWidth, 0), alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: model.notchSize.height)

            body(for: phase)
                .id(phase.key)
                .transition(.notchContent(slowMotion: model.slowMotion))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(.white)
    }

    @ViewBuilder private var leftWing: some View {
        switch phase {
        case .recording:
            HStack(spacing: 6) {
                LiveDot(color: .white)
                Text(timerInterval: model.recordingStart...Date.distantFuture, countsDown: false)
                    .font(.notch(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1).fixedSize()
            }
        case .processing:
            Glyph(kind: .voice, size: 15, active: true)
        case .result, .done:
            Glyph(kind: .check, size: 15)
        case .error:
            Glyph(kind: .alert, size: 15)
        case .answer:
            Glyph(kind: .agent, size: 15, active: model.liveAnswer.map { !$0.finished && !$0.failed } ?? true)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var rightWing: some View {
        switch phase {
        case .recording:
            StopButton(level: model.levels.isEmpty ? 0 : Double(model.levels.reduce(0, +)) / Double(model.levels.count * 100)) {
                onStop?()
            }
        case .processing:
            Text(model.processingLabel)
                .font(.notch(size: 12, weight: .medium)).lineLimit(1).fixedSize().opacity(0.6)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: model.processingLabel)
        case .done(let copied):
            Text(model.dictationPasted ? "Pasted" : copied ? "Copied" : "Done").font(.notch(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
        case .result:
            // Your text is on the clipboard: say so where the stop button was.
            Text("Copied").font(.notch(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                .transition(.opacity)
        case .error:
            CountdownRing(timer: model.resultTimer)
        case .answer, .idle:
            EmptyView()
        }
    }

    @ViewBuilder private func body(for phase: VoicePhase) -> some View {
        switch phase {
        case .recording, .processing:
            VStack(spacing: 0) {
                Group {
                    if model.drawsBarsInSwiftUI { VoiceBarsCanvas(levels: model.levels) } else { VoiceBars(levels: model.levels) }
                }
                .frame(height: VoiceLayout.barsBand)
                if phase == .recording, !model.partial.isEmpty {
                    let width = model.closedSize.width + 2 * VoiceLayout.wing - 2 * NotchText.inset
                    TeleprompterText(text: AttributedString(model.partial), plain: model.partial, font: VoiceLayout.liveFont,
                                     width: width, maxLines: VoiceLayout.liveMaxLines, animateWords: true)
                        .opacity(0.8)
                        .padding(.top, 4)
                        .transition(.opacity)
                } else if phase == .recording, let status = model.statusLine {
                    LiveLine(text: status)
                        .opacity(0.45)
                        .padding(.horizontal, NotchText.inset)
                        .frame(height: VoiceLayout.textLine)
                        .transition(.opacity)
                }
            }
        case .result(let text):
            TeleprompterText(text: AttributedString(text), plain: text, font: VoiceLayout.resultFont,
                             width: VoiceLayout.resultWidth - 2 * VoiceLayout.resultTextInset, maxLines: VoiceLayout.resultMaxLines)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VoiceLayout.resultTextInset)
                .padding(.top, 6)
        case .error(let message):
            Text(message).font(.notch(size: 12)).opacity(0.75).frame(height: VoiceLayout.textLine)
        case .answer:
            if let approval = model.approval {
                ApprovalCard(approval: approval).id("approval-\(approval.id)").transition(.notchContent(slowMotion: model.slowMotion))
            } else if let card = model.liveAnswer {
                LiveAnswerCard(card: card, timer: model.liveAnswerTimer).id("answer-\(card.id)").transition(.notchContent(slowMotion: model.slowMotion))
            }
        case .idle, .done:
            EmptyView()
        }
    }
}

/// Stop control in the right wing: a white rounded square breathing inside a ring. The ring
/// brightens on hover and swells slightly with your voice.
struct StopButton: View {
    var level: Double
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(hovering ? 0.6 : 0.28), lineWidth: 1.5)
                Circle()
                    .stroke(.white.opacity(min(0.15 + level * 1.6, 0.7)), lineWidth: 1.5)
                    .scaleEffect(1 + min(level * 0.5, 0.18))
                    .animation(.easeOut(duration: 0.12), value: level)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .phaseAnimator([1.0, 0.72]) { square, scale in
                        square.scaleEffect(scale).opacity(0.65 + 0.35 * scale)
                    } animation: { _ in .easeInOut(duration: 0.75) }
            }
            .frame(width: 20, height: 20)
            .scaleEffect(hovering ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The live transcript line. Short text is centred; once it's too long, the newest words stay
/// at the right edge and older ones fade out on the left (instead of a hard "…").
struct LiveLine: View {
    let text: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(text).font(.notch(size: 12)).lineLimit(1).fixedSize()
            Text(text).font(.notch(size: 12)).lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .clipped()
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)],
                                     startPoint: .leading, endPoint: .trailing))
        }
    }
}

/// Drains while the result counts down to hiding; refills and holds while the pointer is over
/// the notch. Click the notch to dismiss right away.
struct CountdownRing: View {
    let timer: ResultTimer?
    @State private var remaining: CGFloat = 1

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.15), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: remaining)
                .stroke(.white.opacity(timer == nil ? 0.9 : 0.6), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
        .onAppear { run(timer) }
        .onChange(of: timer) { _, new in run(new) }
    }

    private func run(_ timer: ResultTimer?) {
        guard let timer else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { remaining = 1 }
            return
        }
        // A new countdown always starts from full: on first show, or after a hold refilled it.
        var full = Transaction()
        full.disablesAnimations = true
        withTransaction(full) { remaining = 1 }
        DispatchQueue.main.async { withAnimation(.linear(duration: timer.duration)) { remaining = 0 } }
    }
}
