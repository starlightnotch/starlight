import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Click, press the keys, done. While you hold keys it shows them ("Control + Option + …");
/// a combo that's already taken (by another Starlight shortcut, by macOS, or by another app) is
/// refused with a short reason and a shake, and the old one stays. Esc or a second click cancels.
/// Starlight's own shortcuts pause while recording, so pressing one records it instead of firing it.
struct ShortcutRecorder: View {
    @Binding var combo: HotKey.Combo
    /// What a reset puts back; shows a small reset button when the shortcut differs.
    var defaultCombo: HotKey.Combo? = nil
    @State private var recording = false
    @State private var held: NSEvent.ModifierFlags = []
    @State private var problem: String?
    @State private var shake: CGFloat = 0
    @State private var monitor: Any?
    @State private var resign: [Any] = []
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let defaultCombo, !Self.same(defaultCombo, combo), hovering, !recording {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { combo = defaultCombo } } label: {
                    Glyph(kind: .rewind, size: 12).frame(width: 26, height: 26)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(PressableStyle())
                .help("Reset to \(defaultCombo.display)")
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            Button { recording ? stop() : start() } label: {
                RecorderFace(text: label, keys: recording || problem != nil ? nil : combo.display, prefix: nil,
                             recording: recording, dim: recording && held.isEmpty && problem == nil, hovering: hovering)
            }
            .buttonStyle(PressableStyle())
            .modifier(Shake(amount: shake))
        }
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
        .animation(.easeOut(duration: 0.12), value: label)
        .onDisappear { stop() }
    }

    private var label: String {
        if let problem { return problem }
        guard recording else { return combo.display }
        let names = Self.names(held)
        return names.isEmpty ? "Press keys" : (names + ["…"]).joined(separator: " + ")
    }

    /// The recorder that's listening right now; starting another stops it first.
    private static var active: (() -> Void)?

    private func start() {
        Self.active?()
        Self.active = { stop() }
        AppSettings.shared.recordingShortcut = true
        problem = nil
        held = NSEvent.modifierFlags.intersection([.control, .option, .shift, .command])
        recording = true
        // Switching to another app or closing the window ends it: Starlight's shortcuts never stay off.
        let center = NotificationCenter.default
        resign = [center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in stop() },
                  center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in stop() }]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                held = event.modifierFlags.intersection([.control, .option, .shift, .command])
                return event
            }
            if event.keyCode == UInt16(kVK_Escape), held.isEmpty { stop(); return nil }
            guard let new = HotKey.Combo.from(event) else {
                refuse("Add Control, Option or Command")
                return nil
            }
            if Self.same(new, combo) { stop(); return nil }
            if let reason = Self.taken(new, except: combo) { refuse(reason); return nil }
            combo = new
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resign.forEach { NotificationCenter.default.removeObserver($0) }
        resign = []
        guard recording else { return }
        Self.active = nil
        recording = false
        held = []
        AppSettings.shared.recordingShortcut = false
    }

    /// Says why, shakes, and keeps listening for another try.
    private func refuse(_ reason: String) {
        NSSound.beep()
        problem = reason
        withAnimation(.linear(duration: 0.4)) { shake += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if problem == reason { problem = nil } }
    }

    // MARK: Checks

    static func same(_ a: HotKey.Combo, _ b: HotKey.Combo) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }

    /// Why this combo can't be used, or nil when it's free.
    static func taken(_ new: HotKey.Combo, except current: HotKey.Combo) -> String? {
        let settings = AppSettings.shared
        let ours: [(String, HotKey.Combo)] = [
            ("Dictation", settings.dictationShortcut), ("Notes", settings.notesShortcut), ("Transcript", settings.transcriptShortcut),
            ("Silent mode", settings.silentShortcut),
        ] + (settings.askKey.combo.map { [("Live mode", $0)] } ?? [])
        if let clash = ours.first(where: { same($0.1, new) && !same($0.1, current) }) { return "Already used for \(clash.0)" }
        if reserved.contains(where: { same($0, new) }) { return "macOS uses this one" }
        // Starlight's keys are paused while recording, so a failed test registration means another app holds it.
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(new.keyCode, new.modifiers, EventHotKeyID(signature: OSType(0x4E54_5354), id: 9999),
                                         GetEventDispatcherTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        if status != noErr { return "Another app uses this one" }
        // Shift alone (or Shift + Option) on a letter would fire while you type.
        let typing = new.modifiers & UInt32(controlKey | cmdKey) == 0
        if typing, new.keyCode != UInt32(kVK_Space), new.modifiers & UInt32(optionKey) == 0 { return "Add Control, Option or Command" }
        return nil
    }

    /// Shortcuts macOS and every app rely on.
    private static let reserved: [HotKey.Combo] = {
        let cmd = UInt32(cmdKey), shift = UInt32(shiftKey), ctrl = UInt32(controlKey), opt = UInt32(optionKey)
        let keys: [(Int, UInt32)] = [
            (kVK_Space, cmd), (kVK_Space, cmd | opt), (kVK_Tab, cmd), (kVK_Tab, cmd | shift), (kVK_ANSI_Q, cmd), (kVK_ANSI_W, cmd),
            (kVK_ANSI_C, cmd), (kVK_ANSI_V, cmd), (kVK_ANSI_X, cmd), (kVK_ANSI_Z, cmd), (kVK_ANSI_A, cmd), (kVK_ANSI_S, cmd),
            (kVK_ANSI_H, cmd), (kVK_ANSI_M, cmd), (kVK_ANSI_N, cmd), (kVK_ANSI_O, cmd), (kVK_ANSI_P, cmd), (kVK_ANSI_F, cmd),
            (kVK_ANSI_T, cmd), (kVK_ANSI_Comma, cmd), (kVK_ANSI_Grave, cmd), (kVK_ANSI_Q, cmd | ctrl), (kVK_Escape, cmd | opt),
            (kVK_ANSI_3, cmd | shift), (kVK_ANSI_4, cmd | shift), (kVK_ANSI_5, cmd | shift), (kVK_ANSI_Z, cmd | shift),
            (kVK_Space, ctrl | cmd),  // the emoji picker
        ]
        return keys.map { HotKey.Combo(keyCode: UInt32($0.0), modifiers: $0.1) }
    }()

    static func names(_ flags: NSEvent.ModifierFlags) -> [String] {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        return parts
    }
}

/// The key you hold to ask. Click, then either tap a key that works on its own (Fn, or Right
/// Option, Command or Control) or press a shortcut. Esc cancels.
struct AskKeyRecorder: View {
    @Binding var key: AskKey
    @State private var recording = false
    @State private var held: NSEvent.ModifierFlags = []
    /// A lone key went down and nothing else has been pressed since: on release, it's the one.
    @State private var candidate: LoneKey?
    @State private var problem: String?
    @State private var shake: CGFloat = 0
    @State private var monitor: Any?
    @State private var resign: [Any] = []
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if key != .standard, hovering, !recording {
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { key = .standard } } label: {
                    Glyph(kind: .rewind, size: 12).frame(width: 26, height: 26)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(PressableStyle())
                .help("Reset to Fn")
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            Button { recording ? stop() : start() } label: {
                RecorderFace(text: label, keys: recording || problem != nil ? nil : key.display, prefix: nil,
                             recording: recording, dim: recording && held.isEmpty && problem == nil, hovering: hovering)
            }
            .buttonStyle(PressableStyle())
            .modifier(Shake(amount: shake))
        }
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
        .animation(.easeOut(duration: 0.12), value: label)
        .onDisappear { stop() }
    }

    private var label: String {
        if let problem { return problem }
        guard recording else { return key.display }
        if let candidate { return candidate.name + " …" }
        let names = ShortcutRecorder.names(held)
        return names.isEmpty ? "Press keys" : (names + ["…"]).joined(separator: " + ")
    }

    private func start() {
        AppSettings.shared.recordingShortcut = true
        problem = nil
        candidate = nil
        held = NSEvent.modifierFlags.intersection([.control, .option, .shift, .command])
        recording = true
        let center = NotificationCenter.default
        resign = [center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in stop() },
                  center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in stop() }]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                held = event.modifierFlags.intersection([.control, .option, .shift, .command])
                if let lone = LoneKey.from(keyCode: event.keyCode) {
                    if lone.isDown(event.modifierFlags) {
                        candidate = held.subtracting(lone == .fn ? [] : flag(lone)).isEmpty ? lone : nil
                    } else if candidate == lone {
                        record(.lone(lone))
                    }
                } else if let candidate, candidate.isDown(event.modifierFlags) {
                    self.candidate = nil  // another modifier joined: it'll be a shortcut
                } else if held.isEmpty, [UInt16(kVK_Option), UInt16(kVK_Command), UInt16(kVK_Control), UInt16(kVK_Shift)].contains(event.keyCode) {
                    refuse("Use Fn or a right-side key")
                }
                return nil
            }
            candidate = nil
            if event.keyCode == UInt16(kVK_Escape), held.isEmpty { stop(); return nil }
            guard let new = HotKey.Combo.from(event) else {
                refuse("Add Control, Option or Command")
                return nil
            }
            if let current = key.combo, ShortcutRecorder.same(new, current) { stop(); return nil }
            if let reason = ShortcutRecorder.taken(new, except: key.combo ?? HotKey.Combo(keyCode: UInt32.max, modifiers: 0)) { refuse(reason); return nil }
            record(.combo(new))
            return nil
        }
    }

    private func flag(_ key: LoneKey) -> NSEvent.ModifierFlags {
        switch key {
        case .fn: []
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        }
    }

    private func record(_ new: AskKey) {
        key = new
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resign.forEach { NotificationCenter.default.removeObserver($0) }
        resign = []
        guard recording else { return }
        recording = false
        held = []
        candidate = nil
        AppSettings.shared.recordingShortcut = false
    }

    private func refuse(_ reason: String) {
        NSSound.beep()
        problem = reason
        withAnimation(.linear(duration: 0.4)) { shake += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if problem == reason { problem = nil } }
    }
}

/// A quick side-to-side "no".
private struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 6 * sin(amount * .pi * 6), y: 0))
    }
}

/// What a recorder shows: the shortcut as keycaps, or while recording, what it's hearing.
private struct RecorderFace: View {
    let text: String
    /// "Control + Space", drawn as keys; nil shows `text` instead.
    let keys: String?
    var prefix: String?
    let recording: Bool
    let dim: Bool
    let hovering: Bool

    var body: some View {
        Group {
            if let keys {
                HStack(spacing: 6) {
                    if let prefix { Text(prefix).font(.system(size: 12.5)).opacity(0.55) }
                    Keycaps(keys)
                }
                .opacity(hovering ? 1 : 0.9)
                .frame(minWidth: 150, minHeight: 28, alignment: .trailing)
            } else {
                Text(text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .opacity(dim ? 0.6 : 1)
                    .contentTransition(.opacity)
                    .frame(minWidth: 150, minHeight: 28)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Color.white.opacity(recording ? 0.16 : 0.07)))
                    .overlay(Capsule().strokeBorder(.white.opacity(recording ? 0.55 : 0), lineWidth: 1))
            }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
