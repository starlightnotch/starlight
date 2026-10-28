import AppKit
import Carbon.HIToolbox

/// Live mode's key: a shortcut (Option Space) or a key on its own (Fn, or a right-side
/// modifier, which nothing else uses alone), pressed or held (AppSettings.liveKeyMode).
enum AskKey: Codable, Equatable {
    case lone(LoneKey)
    case combo(HotKey.Combo)

    static let standard = AskKey.combo(.live)

    /// "Fn", "Right Option", "Option + Shift + Space".
    var display: String {
        switch self {
        case .lone(let key): key.name
        case .combo(let combo): combo.display
        }
    }

    /// "fn", "Right ⌥", "⌥⇧Space", for tight spots.
    var symbols: String {
        switch self {
        case .lone(let key): key.symbol
        case .combo(let combo): combo.symbols
        }
    }

    var combo: HotKey.Combo? { if case .combo(let combo) = self { combo } else { nil } }
}

/// Keys that can be held on their own: they're never typed, and holding one alone does nothing
/// else (left-side modifiers start too many shortcuts).
enum LoneKey: String, Codable, CaseIterable {
    case fn, rightOption, rightCommand, rightControl

    var keyCode: UInt16 {
        switch self {
        case .fn: UInt16(kVK_Function)
        case .rightOption: UInt16(kVK_RightOption)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .rightControl: UInt16(kVK_RightControl)
        }
    }

    var name: String {
        switch self {
        case .fn: "Fn"
        case .rightOption: "Right Option"
        case .rightCommand: "Right Command"
        case .rightControl: "Right Control"
        }
    }

    var symbol: String {
        switch self {
        case .fn: "fn"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        }
    }

    static func from(keyCode: UInt16) -> LoneKey? { allCases.first { $0.keyCode == keyCode } }

    /// Whether this key is down in a flagsChanged event. The right-side keys are told apart from
    /// the left by their device bits (NX_DEVICER…KEYMASK).
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .fn: flags.contains(.function)
        case .rightOption: flags.rawValue & 0x40 != 0
        case .rightCommand: flags.rawValue & 0x10 != 0
        case .rightControl: flags.rawValue & 0x2000 != 0
        }
    }

    /// macOS's "Press 🌐 key to" setting: anything but Do Nothing (0) also fires when you let go
    /// of Fn (the emoji picker, a new input source, Apple's dictation).
    static var fnDoesSomethingElse: Bool {
        let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) as? Int
        return (value ?? 1) != 0
    }
}

/// Watches one key held on its own, from any app. Global key monitors need Accessibility,
/// which pasting already asks for; without it this stays quiet.
///
/// - Down: the key went down with nothing else held.
/// - Up: it came back up with nothing typed in between.
/// - Cancel: another key or modifier joined (Fn + Delete, Right ⌘ + Tab): it's a shortcut, not a hold.
final class LoneKeyMonitor {
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    var onCancel: (() -> Void)?
    private let key: LoneKey
    private var monitors: [Any] = []
    private var held = false

    init(_ key: LoneKey) {
        self.key = key
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) { monitors.append(m) }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if held { held = false; onCancel?() }
            return
        }
        let others = event.modifierFlags.intersection([.control, .option, .shift, .command, .function])
        if event.keyCode == key.keyCode {
            let down = key.isDown(event.modifierFlags)
            if down, !held {
                // Only on its own: Shift held first, then Fn, is someone's shortcut.
                let alone: Bool = switch key {
                case .fn: others == .function
                case .rightOption: others == .option
                case .rightCommand: others == .command
                case .rightControl: others == .control
                }
                guard alone else { return }
                held = true
                onDown?()
            } else if !down, held {
                held = false
                onUp?()
            }
        } else if held {
            held = false
            onCancel?()
        }
    }
}
