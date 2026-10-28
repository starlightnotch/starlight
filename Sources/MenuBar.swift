import AppKit
import Carbon.HIToolbox
import Combine

/// The menu bar icon: start dictation or notes, jump to
/// recent notes or history, settings, launch at login, quit. Rebuilt each time it opens, so it
/// always shows the current state and shortcuts.
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let voice: VoiceController
    private let notes: NotesController
    private var item: NSStatusItem?
    private var observer: AnyCancellable?

    init(voice: VoiceController, notes: NotesController) {
        self.voice = voice
        self.notes = notes
        super.init()
        update()
        observer = AppSettings.shared.$showMenuBarIcon.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    private func update() {
        if AppSettings.shared.showMenuBarIcon, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Self.icon
            item.button?.toolTip = "Starlight"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !AppSettings.shared.showMenuBarIcon, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    /// The app icon's five voice bars, drawn as a template so they follow the menu bar's colour.
    private static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: true) { _ in
            NSColor.black.setFill()
            let unit: CGFloat = 0.9
            for (i, h) in [5, 10.5, 15, 10.5, 5].enumerated() {
                let height = CGFloat(h) * unit, width = 2 * unit
                let x = 9 - 9 * unit + CGFloat(i) * 4 * unit
                NSBezierPath(roundedRect: NSRect(x: x, y: 7 - height / 2, width: width, height: height),
                             xRadius: width / 2, yRadius: width / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared
        let model = voice.model

        // Only the features that are on (Settings → General).
        let dictating = model.voice == .recording
        if settings.dictationEnabled {
            add(menu, dictating ? "Stop Dictation" : "Start Dictation", icon: .voice, combo: settings.dictationShortcut,
                enabled: model.voice != .processing) { [voice] in voice.toggle() }
        }
        let listening = model.notes == .listening
        let live = listening && model.sessionKind == .live
        if settings.liveEnabled {
            add(menu, live ? "Stop Live Mode" : "Start Live Mode", icon: .agent, combo: settings.liveKeyMode == .toggle ? settings.askKey.combo : nil,
                enabled: model.notes != .finishing) { [notes] in notes.toggleLive() }
        }
        if settings.meetingsEnabled {
            add(menu, listening && !live ? "Stop Meeting" : "Start Meeting", icon: .noteLive, combo: settings.notesShortcut,
                enabled: model.notes != .finishing && !live) { [notes] in notes.toggle() }
        }
        if settings.dictationEnabled || settings.liveEnabled || settings.meetingsEnabled { menu.addItem(.separator()) }

        let open = settings.tasksEnabled ? TaskStore.shared.open.count : 0
        add(menu, open == 0 ? "Tasks" : "Tasks  ·  \(open)", icon: .todo) { CompanionWindow.shared.show(.tasks) }
        let recent = NSMenuItem(title: "Recent Meetings", action: nil, keyEquivalent: "")
        recent.image = Self.image(.note)
        let submenu = NSMenu()
        let sessions = NotesStore.shared.sessions.prefix(6)
        if sessions.isEmpty {
            submenu.addItem(withTitle: "No meetings yet", action: nil, keyEquivalent: "").isEnabled = false
        }
        for session in sessions {
            add(submenu, "\(RelativeDate.string(session.started))  ·  \(session.lengthText)\(session.kind == "live" ? "  ·  Live" : "")") {
                CompanionWindow.shared.show(.session(session.id))
            }
        }
        if !sessions.isEmpty {
            submenu.addItem(.separator())
            add(submenu, "All Meetings…") { CompanionWindow.shared.show(.meetings) }
        }
        recent.submenu = submenu
        menu.addItem(recent)
        add(menu, "Dictation History", icon: .history) { CompanionWindow.shared.show(.history) }
        menu.addItem(.separator())

        if let version = Updater.shared.available {
            add(menu, "Update to Starlight \(version)…") { Updater.shared.checkNow() }
        } else if Updater.shared.isAvailable {
            add(menu, "Check for Updates…") { Updater.shared.checkNow() }
        }
        add(menu, "Welcome Tour…") { MainActor.assumeIsolated { Onboarding.shared.show() } }
        let settingsItem = add(menu, "Settings…", icon: .sliders) { CompanionWindow.shared.show(.general) }
        settingsItem.keyEquivalent = ","
        if settings.tasksEnabled {
            let corner = add(menu, "Tasks in the Corner") { settings.showTasksCorner.toggle() }
            corner.state = settings.showTasksCorner ? .on : .off
        }
        let nowPlaying = add(menu, "Now Playing") { settings.showNowPlaying.toggle() }
        nowPlaying.state = settings.showNowPlaying ? .on : .off
        let login = add(menu, "Launch at Login") { LoginItem.set(!LoginItem.isEnabled) }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(.separator())
        let quit = add(menu, "Quit Starlight") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
    }

    /// Menu icons from the app's glyph set, rendered once.
    private static var images: [Glyph.Kind: NSImage] = [:]
    private static func image(_ kind: Glyph.Kind) -> NSImage? {
        if let cached = images[kind] { return cached }
        let image = MainActor.assumeIsolated { Glyph.menuImage(kind) }
        images[kind] = image
        return image
    }

    // MARK: Items with closures

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, icon: Glyph.Kind? = nil, combo: HotKey.Combo? = nil, enabled: Bool = true,
                     _ action: @escaping () -> Void) -> NSMenuItem {
        let target = Action(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = target
        item.representedObject = target  // keeps the target alive with the item
        item.isEnabled = enabled
        if let icon { item.image = Self.image(icon) }
        if let combo, let key = combo.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = combo.menuModifiers
        }
        menu.addItem(item)
        return item
    }
}

extension HotKey.Combo {
    /// The key as NSMenuItem shows it, so the menu lists the real global shortcut.
    var menuKeyEquivalent: String? {
        if keyCode == UInt32(kVK_Space) { return " " }
        if let keyName, keyName.count == 1 { return keyName.lowercased() }
        return nil
    }

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }
}
