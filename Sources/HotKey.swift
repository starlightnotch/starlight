import AppKit
import Carbon.HIToolbox

/// A global hotkey registered with Carbon's RegisterEventHotKey, which works from any app
/// without extra permissions. Gets press and release.
final class HotKey {
    struct Combo: Codable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32  // Carbon modifier flags (controlKey, optionKey, ...)
        /// The key's label as typed when it was recorded (letters, digits, punctuation).
        var keyName: String? = nil

        /// "Control + Option + Space": the keys by name, in the order macOS menus use.
        var display: String {
            var parts: [String] = []
            if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
            if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
            if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
            if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
            return (parts + [Self.words[Int(keyCode)] ?? Self.names[Int(keyCode)] ?? keyName ?? "Key \(keyCode)"]).joined(separator: " + ")
        }

        /// "⌃⌥Space", for tight spots.
        var symbols: String {
            var s = ""
            if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
            return s + (Self.names[Int(keyCode)] ?? keyName ?? "Key \(keyCode)")
        }

        private static let words: [Int: String] = [
            kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc", kVK_Delete: "Delete",
            kVK_LeftArrow: "Left Arrow", kVK_RightArrow: "Right Arrow", kVK_UpArrow: "Up Arrow", kVK_DownArrow: "Down Arrow",
        ]

        private static let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "Esc", kVK_Delete: "⌫",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]

        /// Builds a combo from a key press in the settings window.
        static func from(_ event: NSEvent) -> Combo? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            let isFunctionKey = (Int(kVK_F1)...Int(kVK_F12)).contains(Int(event.keyCode)) || [kVK_F13, kVK_F14, kVK_F15].contains(Int(event.keyCode))
            guard carbon != 0 || isFunctionKey else { return nil }  // a bare key would fire while typing
            let name = event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
            return Combo(keyCode: UInt32(event.keyCode), modifiers: carbon, keyName: name?.isEmpty == false ? name : nil)
        }

        /// Dictation: Control-Space.
        static let toggleRecording = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))  // ⌃Space
        /// Live mode has ⌥Space; hold Control-Shift-Space to talk.
        static let pushToTalk = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey))  // ⌃⇧Space
        static let live = Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))                   // ⌥Space
        static let cancel = Combo(keyCode: UInt32(kVK_Escape), modifiers: 0)                           // Esc
    }

    /// Weak, so dropping a HotKey (setting it to nil) unregisters it: a strong table kept every
    /// shortcut ever made alive, including a bare Esc taken from every other app.
    private struct Weak { weak var key: HotKey? }
    private static var handlers: [UInt32: Weak] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    let id: UInt32
    let onPress: () -> Void
    let onRelease: (() -> Void)?
    private var ref: EventHotKeyRef?
    /// noErr when registered; another app holding the same combo shows up here.
    private(set) var status: OSStatus = noErr

    init(_ combo: Combo, onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1
        self.onPress = onPress
        self.onRelease = onRelease
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E54_4348), id: id)  // 'NTCH'
        status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr { Self.handlers[id] = Weak(key: self) }
    }

    deinit { unregister() }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.handlers[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async {
                guard let hotKey = HotKey.handlers[hotKeyID.id]?.key else { return }
                if pressed { hotKey.onPress() } else { hotKey.onRelease?() }
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}
