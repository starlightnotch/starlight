import AppKit
import Combine
import SwiftUI

/// The notch's panel never activates the app, so its hosting view accepts the first click
/// itself. Press handling lives here too.
final class AcceptingFirstClickHostingView<Content: View>: NSHostingView<Content> {
    var onPress: ((Bool) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) { onScroll?(event); super.scrollWheel(with: event) }
    /// Right-click the notch: just Quit.
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let quit = menu.addItem(withTitle: "Quit Starlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func mouseDown(with event: NSEvent) { onPress?(true); super.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { onPress?(false); super.mouseUp(with: event) }
}

/// One transparent strip across the top of the screen, above the menu bar, on every Space and
/// beside full-screen apps. It starts 1pt above the screen so the notch meets the bezel. The
/// window never resizes; SwiftUI animates the shape inside it.
final class NotchPanel: NSPanel {
    /// Off by default so clicking the notch never takes keyboard focus from the app you're
    /// typing in. Turn it on only while open content needs to type (a text field).
    var allowsKeyboard = false

    init(screen: NSScreen, model: NotchModel, voice: VoiceController, notes: NotesController,
         onScroll: @escaping (NSEvent) -> Void, onPress: @escaping (Bool) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true  // hover effects inside the notch
        let morph = NotchMorphView.isEnabled
        let host = AcceptingFirstClickHostingView(rootView: NotchView(model: model, onStop: { [weak voice] in voice?.stop() }, voice: voice, notes: notes,
                                                                      drawsShape: !morph))
        host.sizingOptions = []  // the window never resizes to fit SwiftUI; skip that work each frame
        host.onPress = onPress
        host.onScroll = onScroll
        // The shape and its clip run in Core Animation; SwiftUI draws what's inside.
        contentView = morph ? NotchMorphView(host: host, model: model) : host
        place(on: screen)
    }

    func place(on screen: NSScreen) {
        // Tall enough for the biggest card (finished notes). The empty area is transparent and
        // lets clicks through.
        let height: CGFloat = NotesLayout.windowHeight
        setFrame(NSRect(x: screen.frame.minX, y: screen.frame.maxY - height + 1, width: screen.frame.width, height: height),
                 display: true)
    }

    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
}

/// Gives keyboard focus back to the app you were in.
/// With `allowsKeyboard` off nothing is taken in the first place; this is the safety net.
final class FocusKeeper {
    /// The app you were last in that isn't Starlight (for reading its window).
    nonisolated(unsafe) static var lastApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    private(set) var lastOtherApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication {
        didSet { Self.lastApp = lastOtherApp }
    }
    private var observer: Any?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.lastOtherApp = app }
        }
    }

    func restore(from panel: NSPanel?) {
        // You're using Starlight's window (Settings, the welcome tour): leave focus with it.
        guard !CompanionWindow.shared.isVisible, !DockIcon.windowOpen else { return }
        let tookFocus = NSApp.isActive || panel?.isKeyWindow == true
        guard tookFocus else { return }
        panel?.resignKey()
        lastOtherApp?.activate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotchModel()
    let focus = FocusKeeper()
    lazy var voice = VoiceController(model: model)
    lazy var notes = NotesController(model: model, cleanup: voice.cleanup)
    lazy var ask = AskController(model: model, voice: voice, notes: notes)
    /// See track(): no hover growth right after a dictation closes under the pointer.
    private var restAfterDictation = false
    var panel: NotchPanel?
    var screen: NSScreen!
    var monitors: [Any] = []
    var mouseIgnored = true
    var menuBar: MenuBarItem?
    private let bluetooth = BluetoothDevices()
    private var nowPlayingObserver: AnyCancellable?
    private var mediaObserver: AnyCancellable?
    private var textSizeObserver: AnyCancellable?
    private var monitorModeObserver: AnyCancellable?
    private var toastWork: DispatchWorkItem?
    /// Open on hover: the pending open after the pointer rests on the notch.
    private var hoverOpen: DispatchWorkItem?
    private let hoverOpenDelay: TimeInterval = 0.3
    /// Two-finger swipe distance in the current gesture (positive = fingers moving down).
    private var swipe: CGFloat = 0
    private var swipeHandled = false

    /// Text fields only get ⌘C / ⌘V / ⌘A / ⌘Z from the app's Edit menu, so even without a Dock
    /// icon the app needs a main menu while its window is in front.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Starlight")
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Starlight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    @objc private func showSettings() { CompanionWindow.shared.show(.general) }

    /// Opening Starlight again from Finder or Spotlight while it runs shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { CompanionWindow.shared.show(.general) }
        return true
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Writing to a tool or script that already quit must fail, not end the app.
        signal(SIGPIPE, SIG_IGN)
        // Opened from the download: offers to move itself to Applications first.
        if MoveToApplications.offerIfNeeded() { return }
        // Applications/Notch.app (an update keeps the old name) renames itself and reopens.
        if Rebrand.renameInstalledApp() { return }
        installMainMenu()
        NSApp.setActivationPolicy(.accessory)  // no Dock icon until Settings or the welcome tour is open
        DockIcon.shared.start()
        Updater.shared.start()
        StarlightAccount.shared.resume()  // Clerk and the plan from Convex, only for someone signed in
        screen = Self.notchScreen()
        if let size = NotchModel.physicalNotchSize(for: screen) { model.notchSize = size }
        applyMonitorMode()
        Approvals.shared.model = model
        Onboarding.shared.model = model
        ModelInstall.shared.start(model)  // models installing outside the tour, in the notch
        // Automatic updates wait until nothing's going on, and say so after the restart.
        Updater.shared.isBusy = { [weak model] in
            guard let model else { return true }
            return model.voice.isActive || model.notes.isActive || model.isOpen
        }
        Updater.shared.onUpdated = { [weak model] version in
            model?.flash(NotchModel.Toast(icon: .check, title: "Updated", detail: version), for: 3)
        }
        // A prompt saved with Starlight's added rules inside it (they piled up): cleaned once.
        let saved = AppSettings.shared.agentPrompt
        if !saved.isEmpty, Agent.cleaned(saved) != saved.trimmingCharacters(in: .whitespacesAndNewlines) {
            AppSettings.shared.agentPrompt = Agent.cleaned(saved)
            DebugLog.write("agent: cleaned the saved prompt (\(saved.count) → \(AppSettings.shared.agentPrompt.count) characters)")
        }
        ConfigFile.shared.start()
        TaskCorner.shared.start()
        voice.onClosed = { [weak self] in
            guard let self else { return }
            self.restAfterDictation = true
            self.model.setHovering(false)
            self.model.setPressing(false)
            self.watchClose()
        }

        let panel = NotchPanel(screen: screen, model: model, voice: voice, notes: notes,
                               onScroll: { [weak self] in self?.scrolled($0) }) { [weak self] down in
            self?.notchPressed(down)
        }
        panel.orderFrontRegardless()
        self.panel = panel
        NotchTour.shared.model = model
        NotchTour.shared.voice = voice
        BubbleHost.shared.model = model
        BubbleHost.shared.notchWindow = panel
        CaptureVisibility.apply()

        _ = notes  // registers the notes shortcut
        _ = NotesStore.shared  // saved meetings load in the background now, not on the first open
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Prewarm.run(notchSize: self.model.notchSize)
        }
        _ = ask  // and hold to ask
        menuBar = MenuBarItem(voice: voice, notes: notes)

        // Anything else playing (YouTube in a browser, QuickTime, VLC…), while Now Playing is on.
        // Text size: everything the notch lays out is measured again at the new size.
        textSizeObserver = AppSettings.shared.$textSize.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self?.model.objectWillChange.send() } }
        }
        // Monitor mode: changes apply at once.
        monitorModeObserver = AppSettings.shared.$monitorMode.removeDuplicates().dropFirst().sink { [weak self] mode in
            DispatchQueue.main.async { self?.applyMonitorMode(mode) }
        }
        mediaObserver = AppSettings.shared.$showNowPlaying.removeDuplicates().sink { on in
            if on { MediaWatcher.shared.start() } else { MediaWatcher.shared.stop() }
        }
        // Spotify / Music beside the notch.
        nowPlayingObserver = NowPlaying.shared.$track
            .combineLatest(AppSettings.shared.$showNowPlaying)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track, show in
                guard let self else { return }
                let next = show ? track : nil
                guard next != self.model.nowPlaying else { return }
                withAnimation(self.model.scaled(next == nil ? Motion.close : Motion.open)) {
                    self.model.nowPlaying = next
                }
            }
        // Headphones connecting: their name and battery for a few seconds.
        bluetooth.onConnect = { [weak self] connected in self?.deviceConnected(connected) }
        bluetooth.onDisconnect = { [weak self] name in
            if self?.model.headphonesBattery?.name == name { self?.model.headphonesBattery = nil }
        }
        bluetooth.start()
        CompanionWindow.shared.onClose = { [weak self] in self?.focus.lastOtherApp?.activate() }
        if let problem = voice.hotKeyProblem { NSLog("notch: %@ (quit the other app or change the shortcut)", problem) }
        // A shortcut another app held at launch: try again now and then, so it comes back once
        // that app quits.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !AppSettings.shared.recordingShortcut else { return }
            self.voice.applyShortcuts()
            self.notes.applyShortcut()
            self.ask.apply()
        }

        // Event-driven pointer tracking: reacts on the same frame the mouse moves and costs
        // nothing while the mouse is still. Global covers other apps, local covers our panel.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.track() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.track(); return e }) {
            monitors.append(m)
        }
        // A click anywhere else (say, into the field you're pasting into) puts a dictation
        // result away. Clicks on the notch itself are local events and don't reach this.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self else { return }
            switch self.model.voice {
            // On the next turn of the run loop, not inside the other app's click: closing from
            // here sometimes left the black shape drawn at the result's size.
            case .result, .error, .done, .answer: DispatchQueue.main.async { self.voice.dismiss() }
            default: break
            }
        }) {
            monitors.append(m)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        if Dev.env("STARLIGHT_SELFTEST") != nil { runSelfTest() }
        // STARLIGHT_TEST_NOTES_AUDIO=file.wav STARLIGHT_AUTOSTART_NOTES=1: a notes session from a file at launch.
        // STARLIGHT_AUTODICTATE=1: start dictation at launch and stop 4 s later (timing tests).
        if Dev.env("STARLIGHT_AUTODICTATE") != nil {
            // STARLIGHT_AUTODICTATE_SECONDS: how long to record (default 4).
            let seconds = Dev.env("STARLIGHT_AUTODICTATE_SECONDS").flatMap(Double.init) ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.voice.start() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + seconds) { [weak self] in self?.voice.stop() }
            // STARLIGHT_AUTOCLICK_AFTER=n: a click on the notch n seconds after stopping (closes a result).
            if let after = Dev.env("STARLIGHT_AUTOCLICK_AFTER").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6 + after) { [weak self] in self?.voice.handleClick() }
            }
            if let slow = Dev.env("STARLIGHT_SLOWMO").flatMap(Double.init) { model.slowMotion = slow }
        }
        // STARLIGHT_OPEN_AT_LAUNCH: opens the notch once it's up; it stays open until the pointer has
        // been on it and left.
        if Dev.env("STARLIGHT_OPEN_AT_LAUNCH") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.model.pinned = true
                self?.model.set(.open)
            }
        }
        // The hello: the notch spreads out for a moment and settles. On first launch the welcome
        // tour follows it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.model.playLaunch() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            Onboarding.shared.showIfNeeded()
            // The Ask key and pasting need Accessibility: while it's off, its bubble asks (not
            // again for a day after Not now). STARLIGHT_ASK_PERMISSION=mic: any one's bubble, to look at.
            let id = Dev.env("STARLIGHT_ASK_PERMISSION") ?? "accessibility"
            MainActor.assumeIsolated { PermissionAsk.shared.need(id, blocking: false) }
        }
        // STARLIGHT_TASKS_OPEN: the tasks list opens at launch (checking its window).
        if Dev.env("STARLIGHT_TASKS_OPEN") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { TaskCorner.shared.reveal() }
        }
        if Dev.env("STARLIGHT_AUTOSTART_NOTES") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.notes.start() }
            if Dev.env("STARLIGHT_AUTOTRANSCRIPT") != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.notes.toggleTranscript() }
            }
            if let seconds = Dev.env("STARLIGHT_AUTOSTOP_AFTER").flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + seconds) { [weak self] in self?.notes.stop() }
            }
        }
    }

    /// A Bluetooth device connected: its battery and name beside the camera for a few seconds.
    private func deviceConnected(_ device: BluetoothDevices.Connected) {
        if device.kind == .headphones, let battery = device.battery {
            model.headphonesBattery = .init(name: device.name, percent: battery)
        }
        guard !device.quiet, AppSettings.shared.showHeadphones, model.toast == nil, !model.voice.isActive, !model.notes.isActive, !model.isOpen else { return }
        let icon: Glyph.Kind = switch device.kind {
        case .headphones: .headphones
        case .keyboard: .keycap
        case .mouse: .mouse
        case .trackpad: .screen2
        case .other: .bluetooth
        }
        let toast = NotchModel.Toast(icon: icon, title: device.name, battery: device.battery)
        withAnimation(model.scaled(Motion.open)) { model.toast = toast }
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.toast?.id == toast.id else { return }
            withAnimation(self.model.scaled(Motion.close)) { self.model.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// The built-in notched display if there is one, otherwise the main screen.
    static func notchScreen() -> NSScreen {
        NSScreen.screens.first { NotchModel.physicalNotchSize(for: $0) != nil } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Displays plugged in, unplugged, or resolution changed: move to the notched screen again.
    @objc private func screensChanged() {
        // Mid-reconfiguration there can briefly be no screen at all: wait for the next change.
        guard !NSScreen.screens.isEmpty else { return }
        screen = Self.notchScreen()
        if let size = NotchModel.physicalNotchSize(for: screen) { model.notchSize = size }
        panel?.place(on: screen)
        applyMonitorMode()
        MainActor.assumeIsolated { BubbleHost.shared.place() }
    }

    /// Monitor mode: on a screen without a camera notch (or on every screen, if you chose Hide) the
    /// notch tucks away while nothing's happening. It springs out and back like any other change.
    private func applyMonitorMode(_ mode: AppSettings.MonitorMode = AppSettings.shared.monitorMode) {
        let hides = switch mode {
        case .auto: NotchModel.physicalNotchSize(for: screen) == nil
        case .show: false
        case .hide: true
        }
        guard hides != model.hidesIdle else { return }
        withAnimation(model.scaled(hides ? Motion.close : Motion.open)) { model.hidesIdle = hides }
    }

    /// Starlight rect in screen coordinates for a given size, with slack around it.
    private func rect(for size: CGSize, slack: CGFloat) -> NSRect {
        NSRect(x: screen.frame.midX - size.width / 2 - slack, y: screen.frame.maxY - size.height - slack,
               width: size.width + slack * 2, height: size.height + slack + 1)
    }

    /// Mouse down/up on the notch.
    private func notchPressed(_ down: Bool) {
        if model.voice.isActive {
            if !down { voice.handleClick() }
            return
        }
        if model.notes.isActive { return }  // the notes view handles its own clicks (transcript, buttons)
        if model.meetingPrompt != nil { return }  // its buttons handle clicks
        if let tutorial = model.tutorial, !tutorial.invite { return }  // a tour card: its bubbles take the clicks
        if model.showsMusic && model.hovering && !model.isOpen { return }  // the mini player handles its clicks
        model.setPressing(down)
        if !down && !model.isOpen { model.pinned = false; model.set(.open) }
    }

    /// An answer closed under the pointer: hovering doesn't open the list until you've left once.
    private var listWaitsForExit = false

    private func track() {
        let p = NSEvent.mouseLocation
        if model.notes.isActive && !model.voice.isActive {
            // Notes: hovering the compact indicator expands it; other phases only need clicks.
            let slack: CGFloat = model.notesExpanded ? 12 : 4
            let inside = rect(for: model.size, slack: slack).contains(p)
            if mouseIgnored == inside { mouseIgnored = !inside; panel?.ignoresMouseEvents = mouseIgnored }
            if case .done = model.notes { notes.holdDone(inside) }
            if model.notes == .listening {
                // An answer is showing: hovering holds it instead of expanding the list.
                if model.approval != nil { model.setNotesExpanded(false) }
                else if model.liveAnswer != nil {
                    notes.live.hold(inside)
                    // The answer goes while you're on it: the list waits until you leave and come back.
                    if inside { listWaitsForExit = true }
                } else {
                    if !inside { listWaitsForExit = false }
                    model.setNotesExpanded(inside && !listWaitsForExit)
                }
            }
            return
        }
        if let tutorial = model.tutorial, !tutorial.invite, !model.voice.isActive, !model.notes.isActive {
            let inside = rect(for: model.size, slack: 4).contains(p)
            if mouseIgnored == inside { mouseIgnored = !inside; panel?.ignoresMouseEvents = mouseIgnored }
            return
        }
        if model.meetingPrompt != nil && !model.isOpen && !model.voice.isActive {
            // The meeting prompt: its buttons need clicks; no hover growth.
            let inside = rect(for: model.size, slack: 4).contains(p)
            if mouseIgnored == inside { mouseIgnored = !inside; panel?.ignoresMouseEvents = mouseIgnored }
            return
        }
        if model.voice.isActive {
            // Dictating: the notch only needs clicks, so no hover growth.
            let inside = rect(for: model.size, slack: 4).contains(p)
            voice.pointerMoved(inside: inside)
            if mouseIgnored == inside { mouseIgnored = !inside; panel?.ignoresMouseEvents = mouseIgnored }
            return
        }
        // Hysteresis: you have to come close to enter, and get a bit further away to leave.
        var inside: Bool
        if model.isOpen {
            inside = rect(for: model.openSize, slack: 14).contains(p)
        } else if model.hovering {
            inside = rect(for: model.size, slack: 10).contains(p)
        } else {
            // The resting notch, including the music beside it; tucked away, where it would be.
            inside = rect(for: model.isTucked ? model.closedSize : model.size, slack: 2).contains(p)
        }

        // You just closed a dictation by clicking it: the pointer is still on the notch, but
        // that isn't a hover. The notch stays at rest until you move away and come back.
        if restAfterDictation {
            if inside { inside = false } else { restAfterDictation = false }
        }

        // Only touch the window when the value changes; each set is a WindowServer round trip.
        if mouseIgnored == inside {
            mouseIgnored = !inside
            panel?.ignoresMouseEvents = mouseIgnored
        }

        if model.pinned { if inside { model.pinned = false } else { return } }

        if model.isOpen {
            if !inside { close() }
        } else {
            if inside != model.hovering { scheduleHoverOpen(inside) }
            model.setHovering(inside)
            if !inside { model.setPressing(false) }
        }
    }

    /// After the close spring has had time to finish: if the shape on screen still isn't the
    /// size the notch should be (its animation frames stopped after a click in another app),
    /// redraw it there.
    private func watchClose(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, !self.model.voice.isActive else { return }
            let want = self.model.size, drawn = NotchTrace.lastDrawn
            guard abs(drawn.width - want.width) > 1 || abs(drawn.height - want.height) > 1 else { return }
            DebugLog.write(String(format: "notch: stuck at %.0f×%.0f after closing (want %.0f×%.0f), redrawing",
                                  drawn.width, drawn.height, want.width, want.height))
            var transaction = Transaction()
            transaction.disablesAnimations = attempt > 0
            withTransaction(transaction) { self.model.redraw += 1 }
            self.panel?.contentView?.needsLayout = true
            self.panel?.display()
            if attempt < 2 { self.watchClose(attempt: attempt + 1) }
        }
    }

    /// Open on hover: rest the pointer on the notch and it opens without a click. Not while music
    /// is beside it: hovering then is the mini player, one step at a time, and a click or a
    /// two-finger swipe down opens the notch (up goes back to the player).
    private func scheduleHoverOpen(_ hovering: Bool) {
        hoverOpen?.cancel()
        hoverOpen = nil
        guard hovering, AppSettings.shared.openOnHover, !model.showsMusic else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.hovering, !self.model.isOpen, !self.model.voice.isActive, !self.model.notes.isActive else { return }
            self.model.pinned = false
            self.model.set(.open)
        }
        hoverOpen = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverOpenDelay, execute: work)
    }

    /// Two-finger swipe on the notch: down opens, up closes.
    private func scrolled(_ event: NSEvent) {
        guard !model.voice.isActive, !model.notes.isActive, event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began { swipe = 0; swipeHandled = false }
        guard !swipeHandled, event.phase == .began || event.phase == .changed else { return }
        // With natural scrolling the deltas already follow the fingers.
        swipe += event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        if swipe > 18, !model.isOpen {
            swipeHandled = true
            model.pinned = false
            model.set(.open)
        } else if swipe < -18, model.isOpen {
            swipeHandled = true
            close()
            model.setHovering(true)  // the pointer is still on the notch
        }
    }

    private func close() {
        hoverOpen?.cancel()
        model.setPressing(false)
        model.setHovering(false)
        model.set(.closed)
        focus.restore(from: panel)
    }

    /// STARLIGHT_SELFTEST=all: every animation the notch has, one after another, with made-up content
    /// (no mic, no key), for STARLIGHT_TRACE to measure: hover, press, open, music, dictation, a
    /// result, an answer, a toast, a meeting from start to finish, the tour's invite, the launch.
    private func runAnimationTour() {
        model.pinned = true
        let m = model
        let track = NowPlaying.Track(source: .spotify, title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
                                     isPlaying: true, artwork: NSImage(named: NSImage.applicationIconName), app: "Spotify")
        var items = [NoteItem(time: 12, text: "Can we move the launch to the second week of March?", isQuestion: true),
                     NoteItem(time: 75, text: "Who owns the pricing page update?", isQuestion: true),
                     NoteItem(time: 102, text: "I'll send the revised deck by Thursday.", isQuestion: false)]
        items.append(NoteItem(time: 130, text: "Dana can take the pricing page after the launch.", isQuestion: false, speaker: .them, speakerID: "1"))
        var session = NoteSession(id: "tour", started: Date(), duration: 754, items: items)
        session.answers = [.init(question: "Who owns the pricing page update?", answer: "Dana, after the launch.", time: 77)]
        let answer = LiveAnswer(question: "Who is Magnus Carlsen?", text: "Magnus Carlsen. A Norwegian chess grandmaster, world champion from 2013 to 2023.", finished: true)
        var levels: Timer?
        func talk(_ on: Bool) {
            levels?.invalidate(); levels = nil
            guard on else { return }
            var phase = 0.0
            levels = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { _ in
                phase += 0.3
                m.levels = (0..<VoiceLayout.barCount).map { i in Int(40 + 38 * sin(phase + Double(i) * 0.5) * sin(phase * 0.37)) }
            }
        }
        let steps: [(Double, String, () -> Void)] = [
            (1.0, "hover", { m.setHovering(true) }),
            (2.2, "unhover", { m.setHovering(false) }),
            (3.0, "hover2", { m.setHovering(true) }),
            (3.8, "press", { m.setPressing(true) }),
            (4.2, "open", { m.setPressing(false); m.set(.open) }),
            (6.2, "close", { m.setHovering(false); m.set(.closed) }),
            (7.4, "music-wings", { m.nowPlaying = track }),
            (8.6, "music-hover", { m.setHovering(true) }),
            (10.4, "music-leave", { m.setHovering(false) }),
            (11.4, "music-off", { m.nowPlaying = nil }),
            (12.4, "dictate", { m.recordingStart = Date(); m.partial = ""; m.setVoice(.recording); talk(true) }),
            (13.4, "words-1", { m.setPartial("So the launch is") }),
            (14.0, "words-2", { m.setPartial("So the launch is moving to the second week of March, and") }),
            (14.8, "words-3", { m.setPartial("So the launch is moving to the second week of March, and the pricing page needs one more review before then") }),
            (15.8, "processing", { talk(false); m.processingLabel = "Transcribing"; m.setVoice(.processing) }),
            (16.4, "pasted", { m.dictationPasted = true; m.setVoice(.done(copied: true)) }),
            (17.6, "dictate-close", { m.setVoice(.idle) }),
            (18.6, "result", { m.setVoice(.result("So the launch is moving to the second week of March, and the pricing page needs one more review.")) }),
            (21.0, "result-close", { m.setVoice(.idle) }),
            (22.0, "ask", { m.recordingStart = Date(); m.partial = ""; m.setVoice(.recording); talk(true) }),
            (22.8, "ask-words", { m.setPartial("Who is Magnus Carlsen") }),
            (23.6, "thinking", { talk(false); m.processingLabel = "Thinking"; m.setVoice(.processing) }),
            (24.4, "answer", { m.setLiveAnswer(answer); m.setVoice(.answer) }),
            (27.0, "answer-close", { m.setVoice(.idle); m.setLiveAnswer(nil) }),
            (28.0, "toast", { m.toast = .init(icon: .headphones, title: "AirPods Pro", battery: 84) }),
            (31.0, "toast-close", { m.toast = nil }),
            (32.0, "notes", { m.notesStart = Date(); m.setNotes(.listening) }),
            (33.2, "caption", { m.setCaption("Are we still on for the second week of March") }),
            (34.4, "notes-answer", { m.setCaption(""); m.setLiveAnswer(LiveAnswer(question: "ARR vs MRR?", text: "ARR is MRR × 12: yearly recurring revenue.", finished: true)) }),
            (37.0, "notes-answer-close", { m.setLiveAnswer(nil) }),
            (38.0, "notes-expand", { m.setNotesExpanded(true) }),
            (39.6, "notes-collapse", { m.setNotesExpanded(false) }),
            (40.6, "finishing", { m.setNotes(.finishing) }),
            (41.8, "notes-done", { m.setNotes(.done(session)) }),
            (45.0, "notes-close", { m.setNotes(.idle) }),
            (46.0, "invite", { m.tutorial = .init(title: "Hover me", detail: "", invite: true) }),
            (48.0, "invite-close", { m.tutorial = nil }),
            (49.0, "launch", { m.playLaunch() }),
            (52.0, "END", { exit(0) }),
        ]
        for (t, label, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NotchTrace.mark(label); action() }
        }
    }

    /// A scripted run for checking animations with STARLIGHT_TRACE: hover, press, release to open, leave to close.
    private func runSelfTest() {
        if Dev.env("STARLIGHT_SELFTEST") == "all" { return runAnimationTour() }
        // STARLIGHT_SELFTEST=hittest: which view a click on the closed notch reaches (it must be the
        // hosting view, whose mouseDown opens the notch).
        if Dev.env("STARLIGHT_SELFTEST") == "hittest" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let view = self?.panel?.contentView else { return }
                for (name, dy) in [("centre", 12.0), ("edge", 3.0), ("below", 60.0)] {
                    let point = NSPoint(x: view.bounds.midX, y: view.isFlipped ? dy : view.bounds.height - dy)
                    let hit = view.hitTest(view.convert(point, to: view.superview))
                    print("hittest \(name): \(hit.map { String(describing: type(of: $0)).prefix(40) } ?? "nothing")")
                }
                fflush(stdout)
                exit(0)
            }
            return
        }
        // STARLIGHT_SELFTEST=cards: an answer card comes and goes every 1.2 s, for watching transitions.
        if Dev.env("STARLIGHT_SELFTEST") == "cards" {
            model.pinned = true
            let card = LiveAnswer(question: "?", text: "Magnus Carlsen. A Norwegian chess grandmaster, world champion from 2013 to 2023.", finished: true)
            for i in 0..<16 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 1.2) { [model] in
                    if i % 2 == 0 { model.setLiveAnswer(card); model.setVoice(.answer) } else { model.setVoice(.idle); model.setLiveAnswer(nil) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 22) { exit(0) }
            return
        }
        // STARLIGHT_SELFTEST=loop: open and close over and over for 12 s, to profile animation frames.
        if Dev.env("STARLIGHT_SELFTEST") == "loop" {
            model.pinned = true
            for i in 0..<20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 0.6) { [model] in
                    i % 2 == 0 ? model.set(.open) : model.set(.closed)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
            return
        }
        model.pinned = true
        let steps: [(Double, String, () -> Void)] = [
            (1.0, "HOVER", { self.model.setHovering(true) }),
            (2.5, "PRESS", { self.model.setPressing(true) }),
            (3.3, "CLICK", { self.model.set(.open) }),
            (5.5, "CLOSE", { self.model.setHovering(false); self.model.set(.closed) }),
            (7.5, "END", { exit(0) }),
        ]
        for (t, label, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NotchTrace.mark(label); action() }
        }
    }
}

@main
enum Main {
    static func main() {
        Rebrand.moveData()  // Application Support/Notch → Starlight, once
        // Command-line tools (`Starlight --render dir`, tests), in development builds only.
        if Dev.isEnabled, CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
            return runTool(CommandLine.arguments)
        }
        // A copy opened from the download first decides whether it's staying: it may just bring
        // up the Starlight that's already running (MoveToApplications).
        if !MoveToApplications.isDownload { quitOtherCopies() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// One Starlight at a time. A second copy (a download beside the one you run, two builds, an
    /// update's relaunch) keeps its own idea of your settings and would write it over the other's.
    /// The newest wins: it asks the older one to quit, and waits a moment for it to.
    static func quitOtherCopies() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// The development tool the arguments name.
    private static func runTool(_ args: [String]) {
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            MainActor.assumeIsolated { Render.run(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        if let i = args.firstIndex(of: "--render-window"), i + 1 < args.count {
            MainActor.assumeIsolated { Render.renderWindow(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        // --mac-control "turn on night shift" (or "night_shift=on"): one Mac control, from the
        // command line, for testing. --parse-only shows what it would do without doing it.
        if let i = args.firstIndex(of: "--mac-control"), i + 1 < args.count {
            let text = args[i + 1]
            let parsed = MacControls.parse(text) ?? {
                let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
                return MacControlsExtension.actions.contains(parts[0]) ? (parts[0], parts.count > 1 ? parts[1] : "") : nil
            }()
            guard let parsed else { print("not a Mac control: \(text)"); return }
            print("→ \(parsed.action)(\(parsed.value))")
            if args.contains("--parse-only") { return }
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let result = await MacControls.run(parsed.action, parsed.value)
                let line = (result.outcome.map { "[\($0.ok ? "✓" : "✗")] \($0.text)" } ?? "") + " · " + result.content
                print(line)
                // Launched with `open`, stdout goes nowhere: the log has it too.
                DebugLog.write("mac control test: \(text) → \(parsed.action)(\(parsed.value)) → \(line.replacingOccurrences(of: "\n", with: "; "))")
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            // STARLIGHT_TEST_HOLD=seconds: stay a moment, so what it started (keep awake) can be checked.
            if let hold = Dev.env("STARLIGHT_TEST_HOLD").flatMap(Double.init) { Thread.sleep(forTimeInterval: hold) }
            return
        }
        // --tool-groups "turn on dark mode": which tool groups a question loads (ToolDisclosure),
        // and roughly how many characters of tool schemas it sends.
        if let i = args.firstIndex(of: "--tool-groups"), i + 1 < args.count {
            MainActor.assumeIsolated {
                let api = Extensions.shared.makeAPI()
                let disclosure = ToolDisclosure(api: api, request: AgentRequest(question: args[i + 1], meeting: [], meetingStart: Date()))
                let schemas = disclosure.active.compactMap { try? JSONSerialization.data(withJSONObject: $0.schema) }.reduce(0) { $0 + $1.count }
                print("\(disclosure.loaded.subtracting(ToolDisclosure.core).sorted().joined(separator: ", ")) · \(schemas) chars of tools")
            }
            return
        }
        // --sound-output: what the Mac plays through, and whether Starlight counts it as headphones.
        if args.contains("--sound-output") {
            let line = BluetoothDevices.describeOutput()
            print(line)
            DebugLog.write("sound output test: \(line)")
            return
        }
        // --voice-test learn.wav other.wav …: learns the voice in the first file (as if read aloud in
        // the tour), then says how far each other file's voice is from it, and whether a meeting
        // would count it as someone else. Leaves any voice you'd learned as it was.
        if let i = args.firstIndex(of: "--voice-test"), i + 2 < args.count {
            let files = Array(args[(i + 1)...])
            let saved = VoiceProfile.shared.embedding
            setenv("STARLIGHT_TEST_VOICE_AUDIO", files[0], 1)
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let enrollment = VoiceEnrollment(preview: .ready, progress: 0, level: 0)
                let started = Date()
                enrollment.start()
                while Date().timeIntervalSince(started) < 120 {
                    if enrollment.phase == .done { break }
                    if case .failed(let message) = enrollment.phase { print("learning failed: \(message)"); break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                print(String(format: "learned: %@ in %.1f s (progress %.0f%%)", enrollment.phase == .done ? "yes" : "no", Date().timeIntervalSince(started), enrollment.progress * 100))
                for file in files.dropFirst() {
                    guard let samples = VoiceProfile.load16k(file) else { print("\(file): couldn't read"); continue }
                    let print_ = await SpeakerIdentifier.shared.embedding(samples)
                    let distance = print_.flatMap { VoiceProfile.shared.distance($0) }
                    let someoneElse = await VoiceProfile.shared.isSomeoneElse(samples)
                    print(String(format: "%@: distance %.3f → %@", (file as NSString).lastPathComponent, distance ?? -1, someoneElse ? "someone else" : "you"))
                }
                if let saved { VoiceProfile.shared.save(saved) } else { VoiceProfile.shared.forget() }
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        // --speakers-test a.wav b.wav …: the speaker each clip is given, in order, as in a meeting.
        // --names-test "text": who that line would name.
        // --silent-test "text" …: whether a line switches silent mode, or speaks to Starlight.
        if let i = args.firstIndex(of: "--silent-test"), i + 1 < args.count {
            for line in args[(i + 1)...] {
                let command = SilentMode.command(line).map { $0 ? "silent ON" : "silent OFF" } ?? "–"
                print("\(line) → \(command)\(SilentMode.spokenTo(line) ? " · spoken to Starlight" : "")")
            }
            return
        }
        if let i = args.firstIndex(of: "--names-test"), i + 1 < args.count {
            for line in args[(i + 1)...] { print("\(line) → \(MainActor.assumeIsolated { SpeakerNaming.introduced(line) } ?? "–")") }
            return
        }
        if let i = args.firstIndex(of: "--speakers-test"), i + 1 < args.count {
            let files = Array(args[(i + 1)...])
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                guard await SpeakerIdentifier.shared.waitUntilReady(timeout: 120) else { print("speaker models didn't load"); done.signal(); return }
                SpeakerIdentifier.shared.reset()
                var merges: [String] = []
                await MainActor.run {
                    SpeakerIdentifier.shared.onMerge = { from, into in merges.append("\(from)→\(into)") }
                    SpeakerIdentifier.shared.onRelabel = { time, label in merges.append("clip \(Int(time) + 1) is now \(label)") }
                }
                for (index, file) in files.enumerated() {
                    guard let audio = VoiceProfile.load16k(file) else { print("\(file): unreadable"); continue }
                    let who = await SpeakerIdentifier.shared.identify(audio, at: TimeInterval(index))
                    print("\(index + 1). \((file as NSString).lastPathComponent): speaker \(who ?? "–")")
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                print("changes: \(merges.isEmpty ? "none" : merges.joined(separator: ", "))")
                done.signal()
            }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        // --media: which apps are sending audio out right now, and what the notch would show.
        if args.contains("--media") {
            let playing = MediaWatcher.appsPlayingAudio()
            print("playing audio:", playing)
            for app in playing { print("  \(app): \(MediaWatcher.shared.preview(app) ?? "not shown")") }
            return
        }
        if args.contains("--cleanup-eval") {
            let done = DispatchSemaphore(value: 0)
            Task.detached { await CleanupModel.runEval(); done.signal() }
            done.wait()
            return
        }
        if let i = args.firstIndex(of: "--render-about"), i + 1 < args.count {
            MainActor.assumeIsolated {
                Render.isRendering = true
                Render.save(AboutPage().padding(28).frame(width: 640, height: 1150, alignment: .top).background(.black).foregroundStyle(.white).preferredColorScheme(.dark),
                            URL(fileURLWithPath: args[i + 1]))
            }
            return
        }
        if let i = args.firstIndex(of: "--export-glyphs"), i + 1 < args.count {
            MainActor.assumeIsolated { GlyphExport.export(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        if let i = args.firstIndex(of: "--render-marketing"), i + 1 < args.count {
            MainActor.assumeIsolated { Marketing.render(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            MainActor.assumeIsolated { AppIconRender.write(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        // --due "text" …: when each task would be due, and how it's labelled.
        if let i = args.firstIndex(of: "--due"), i + 1 < args.count {
            for text in args[(i + 1)...] {
                let due = TaskStore.dueDate(in: text)
                print("\(text) → \(due.map { $0.formatted(date: .abbreviated, time: .shortened) + "  [" + TaskStore.dueLabel($0) + "]" } ?? "no due date")")
            }
            return
        }
        if let i = args.firstIndex(of: "--calc"), i + 1 < args.count {
            for expression in args[(i + 1)...] {
                do { print(try Calculator.evaluate(expression).display) } catch { print("\(expression): \(error.localizedDescription)") }
            }
            return
        }
        if let i = args.firstIndex(of: "--agent-test"), i + 1 < args.count {
            return MainActor.assumeIsolated { AgentTest.run(Array(args[(i + 1)...])) }
        }
        if let i = args.firstIndex(of: "--chapters") {
            // `--chapters [session id]`: write the timeline for a session (the longest if none) and print it.
            let store = NotesStore.shared
            let id = i + 1 < args.count ? args[i + 1] : store.sessions.max { $0.items.count < $1.items.count }?.id
            guard let id else { return print("no sessions") }
            let done = DispatchSemaphore(value: 0)
            Task.detached { await Chapters.write(for: id); done.signal() }
            while done.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            NotesStore.shared.reload()
            let session = NotesStore.shared.session(id)
            print("\(id) · \(session?.items.count ?? 0) lines · \(NotesController.timestamp(session?.duration ?? 0))")
            for c in session?.chapters ?? [] { print("\(NotesController.timestamp(c.start))  \(c.title) — \(c.summary)") }
            return
        }
        if args.contains("--polish-test") { return CleanupModel.runSelfTest() }
        if args.contains("--answer-test") { return OpenRouter.runAnswerTest() }
        if args.contains("--key-check") { return OpenRouter.runKeyCheck() }
        print("Not a tool: \(args.dropFirst().joined(separator: " "))")
    }
}

/// Starlight lives in the notch and the menu bar, so it has no Dock icon, except while one of its
/// real windows (Settings, the welcome tour) is open: then it's an app like any other, in the
/// Dock and in Command-Tab, and the icon goes away again when the last one closes.
final class DockIcon {
    static let shared = DockIcon()
    static let identifier = NSUserInterfaceItemIdentifier("notch.dock")
    private var observers: [Any] = []

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.update() })
        }
        observers.append(center.addObserver(forName: NSApplication.didUnhideNotification, object: nil, queue: .main) { [weak self] _ in self?.update() })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            self?.update(closing: note.object as? NSWindow)
        })
    }

    /// Marks a window as one that brings the Dock icon with it.
    static func mark(_ window: NSWindow) { window.identifier = identifier }

    /// One of Starlight's real windows is up (or minimized).
    static var windowOpen: Bool {
        NSApp.windows.contains { $0.identifier == identifier && ($0.isVisible || $0.isMiniaturized) }
    }

    func update(closing: NSWindow? = nil) {
        // Hidden (⌘H, Hide Others): windows aren't "visible", but the app still has them.
        guard !NSApp.isHidden else { return }
        let open = NSApp.windows.contains { $0.identifier == Self.identifier && ($0.isVisible || $0.isMiniaturized) && $0 !== closing }
        let wanted: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        if open { NSApp.activate() }
    }
}
