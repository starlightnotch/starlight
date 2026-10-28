import AppKit
import CoreBluetooth
import Foundation

/// Your Mac's own switches: dark and light mode, volume, Wi-Fi, Bluetooth, Night Shift,
/// brightness, Low Power Mode, Do Not Disturb, keeping it awake, locking, sleeping the display,
/// hiding and quitting apps, and any System Settings page.
///
/// - One tool, in its own group: its schema is only sent when a question is about one of these
///   (ToolDisclosure), so other questions carry one index line for it, not a schema.
/// - Plain commands ("turn on dark mode", "volume to 30") skip the model entirely
///   (DirectAnswers → `parse`), and are done in milliseconds.
/// - What can be undone at once just happens. Locking, sleeping the display, quitting an app and
///   turning Bluetooth off (your keyboard and mouse may be on it) ask first.
/// - What macOS only allows with your password (Low Power Mode), or doesn't allow at all, opens
///   the right page of System Settings instead, and says so.
///
/// `Starlight --mac-control "turn on night shift"` runs one from the command line, for testing.
struct MacControlsExtension: StarlightExtension {
    let id = "mac-controls"
    let name = "Mac controls"
    let summary = "The Mac's switches: dark mode, volume, Wi-Fi, Bluetooth, Night Shift, brightness, Low Power, Focus, keep awake, lock, quit apps, Settings pages."
    let glyph = Glyph.Kind.sliders

    static let actions = ["dark_mode", "volume", "mute", "wifi", "bluetooth", "night_shift", "brightness", "low_power",
                          "do_not_disturb", "keep_awake", "lock_screen", "sleep_display", "hide_app", "quit_app", "open_settings", "status"]

    func register(_ api: ExtensionAPI) {
        api.registerTool(AgentTool(
            name: "mac_control",
            description: "Change a Mac setting the user just asked to change (only this request's, never an earlier one's), or answer how things are (Wi-Fi on? battery? volume?) with action status. Switches need value on, off or toggle; without one nothing changes. value: on, off or toggle for switches; 0-100, up or down for volume and brightness; minutes (or off) for keep_awake; the app's name for hide_app and quit_app; a page name (wifi, bluetooth, battery, displays, sound, focus, notifications, keyboard, privacy, appearance…) for open_settings.",
            parameters: ["type": "object",
                         "properties": ["action": ["type": "string", "enum": Self.actions],
                                        "value": ["type": "string"]],
                         "required": ["action"]],
            status: "Changing settings", glyph: .sliders,
            keywords: ["dark mode", "light mode", "dark theme", "light theme", "appearance", "volume", "louder", "quieter", "mute", "unmute",
                       "wifi", "wi-fi", "bluetooth", "night shift", "brightness", "brighter", "dimmer", "low power", "power mode",
                       "do not disturb", "focus mode", "keep awake", "stay awake", "caffeinate", "lock my", "lock the screen",
                       "sleep the display", "display to sleep", "system settings", "quit", "battery"],
            run: { args in
                let action = args["action"] as? String ?? ""
                let value = (args["value"] as? String) ?? (args["value"] as? NSNumber)?.stringValue
                return await MacControls.run(action, value)
            }))
        api.markUserOnly("mac_control")
    }
}

enum MacControls {
    // MARK: Running

    @MainActor
    static func run(_ action: String, _ value: String?) async -> ToolResult {
        let v = value?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        // "Is Wi-Fi on?" sent as wifi(status): an answer, not a change.
        if ["status", "check", "get", "state", "query", "current", "read", "?"].contains(v) { return ToolResult(content: status()) }
        // A switch with no value says how it is; it never flips on a guess.
        let switches: Set<String> = ["dark_mode", "mute", "wifi", "bluetooth", "night_shift", "low_power", "do_not_disturb"]
        if switches.contains(action), v.isEmpty { return ToolResult(content: status()) }
        switch action {
        case "dark_mode": return darkMode(v)
        case "volume": return volume(v)
        case "mute": return mute(v)
        case "wifi": return wifi(v)
        case "bluetooth": return await bluetooth(v)
        case "night_shift": return nightShift(v)
        case "brightness": return brightness(v)
        case "low_power": return lowPower(v)
        case "do_not_disturb": return await doNotDisturb(v)
        case "keep_awake": return keepAwake(v)
        case "lock_screen": return await lockScreen()
        case "sleep_display": return await sleepDisplay()
        case "hide_app": return hideApp(value ?? "")
        case "quit_app": return await quitApp(value ?? "")
        case "open_settings": return openSettings(v)
        case "status": return ToolResult(content: status())
        default: return ToolResult(content: "error: unknown action \(action). Actions: \(MacControlsExtension.actions.joined(separator: ", "))")
        }
    }

    static var isDryRun: Bool { Dev.env("STARLIGHT_DRY_RUN") != nil }

    /// on / off / toggle from what was said; nil when it's none of them.
    static func onOff(_ v: String, current: Bool?) -> Bool? {
        if ["on", "true", "yes", "enable", "1", "start"].contains(v) { return true }
        if ["off", "false", "no", "disable", "0", "stop"].contains(v) { return false }
        if v == "toggle" { return current.map { !$0 } }
        return nil
    }

    private static let settingsApp = "/System/Applications/System Settings.app"

    private static func done(_ verb: String, _ subject: String, _ content: String) -> ToolResult {
        ToolResult(content: content, outcome: .item(verb, subject, icon: settingsApp))
    }

    private static func failed(_ text: String) -> ToolResult {
        ToolResult(content: "error: \(text)", outcome: .failed(text))
    }

    // MARK: Appearance

    /// SkyLight changes it directly (no prompt); System Events (one Automation prompt) if that's gone.
    static var isDark: Bool {
        if let get: @convention(c) () -> Bool = symbol("SkyLight", "SLSGetAppearanceThemeLegacy") { return get() }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    @MainActor
    static func darkMode(_ v: String) -> ToolResult {
        let now = isDark
        guard let on = onOff(v, current: now) else { return failed("Say on, off or toggle") }
        if on == now { return done(on ? "Already in" : "Already in", on ? "Dark mode" : "Light mode", "It was already \(on ? "dark" : "light").") }
        if !isDryRun {
            if let set: @convention(c) (Bool) -> Void = symbol("SkyLight", "SLSSetAppearanceThemeLegacy") {
                set(on)
            } else if !appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)") {
                openPane("appearance")
                return done("Opened in System Settings", "Appearance", "Couldn't switch it directly; opened Appearance settings so they can.")
            }
        }
        return done("Switched to", on ? "Dark mode" : "Light mode", "Switched to \(on ? "dark" : "light") mode.")
    }

    // MARK: Sound

    static func currentVolume() -> (level: Int, muted: Bool)? {
        var error: NSDictionary?
        guard let result = AppleScript.run("set s to get volume settings\nreturn {output volume of s, output muted of s}", error: &error),
              result.numberOfItems == 2 else { return nil }
        return (Int(result.atIndex(1)?.int32Value ?? 0), result.atIndex(2)?.booleanValue ?? false)
    }

    @MainActor
    static func volume(_ v: String) -> ToolResult {
        let now = currentVolume()?.level ?? 50
        let target: Int
        switch v {
        case "up", "louder", "higher": target = min(100, now + 12)
        case "down", "quieter", "lower", "softer": target = max(0, now - 12)
        case "max", "maximum", "full", "all the way up": target = 100
        case "off", "min", "minimum", "zero": target = 0
        case "half": target = 50
        default:
            guard let n = number(v) else { return failed("Say a level from 0 to 100, up or down") }
            target = max(0, min(100, n))
        }
        if !isDryRun { _ = appleScript("set volume output volume \(target) without output muted") }
        return done("Volume", "\(target)%", "Volume set to \(target)%.")
    }

    @MainActor
    static func mute(_ v: String) -> ToolResult {
        let muted = currentVolume()?.muted ?? false
        guard let on = onOff(v, current: muted) else { return failed("Say on or off") }
        if !isDryRun { _ = appleScript("set volume output muted \(on)") }
        return done(on ? "Muted" : "Unmuted", "Sound", on ? "Muted." : "Unmuted, at \(currentVolume()?.level ?? 0)%.")
    }

    // MARK: Wi-Fi and Bluetooth

    /// The Wi-Fi device ("en0"), from networksetup's list of ports.
    static var wifiDevice: String? {
        let out = shell("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = out.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }), i + 1 < lines.count else { return nil }
        return lines[i + 1].components(separatedBy: "Device: ").last?.trimmingCharacters(in: .whitespaces)
    }

    static var wifiOn: Bool? {
        guard let device = wifiDevice else { return nil }
        return shell("/usr/sbin/networksetup", ["-getairportpower", device]).hasSuffix("On\n")
    }

    @MainActor
    static func wifi(_ v: String) -> ToolResult {
        guard let device = wifiDevice else { return failed("This Mac has no Wi-Fi") }
        let now = wifiOn
        guard let on = onOff(v, current: now) else { return failed("Say on, off or toggle") }
        if on == now { return done("Already", "Wi-Fi \(on ? "on" : "off")", "Wi-Fi was already \(on ? "on" : "off").") }
        if !isDryRun {
            _ = shell("/usr/sbin/networksetup", ["-setairportpower", device, on ? "on" : "off"])
            if wifiOn != on {
                openPane("wifi")
                return done("Opened in System Settings", "Wi-Fi", "Couldn't switch Wi-Fi directly; opened Wi-Fi settings.")
            }
        }
        return done(on ? "Turned on" : "Turned off", "Wi-Fi", "Wi-Fi is \(on ? "on" : "off").")
    }

    /// Bluetooth calls are only made with Starlight's Bluetooth permission: without it, macOS ends
    /// the app on the spot rather than saying no.
    static var bluetoothAllowed: Bool { CBManager.authorization == .allowedAlways }

    static var bluetoothOn: Bool? {
        guard bluetoothAllowed, let get: @convention(c) () -> Int32 = symbol("IOBluetooth", "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return get() != 0
    }

    @MainActor
    static func bluetooth(_ v: String) async -> ToolResult {
        guard bluetoothAllowed else {
            openPane("bluetooth")
            return done("Opened in System Settings", "Bluetooth", "Starlight doesn't have Bluetooth permission, so Bluetooth settings is open: they can switch it there.")
        }
        let now = bluetoothOn
        guard let on = onOff(v, current: now) else { return failed("Say on, off or toggle") }
        if on == now { return done("Already", "Bluetooth \(on ? "on" : "off")", "Bluetooth was already \(on ? "on" : "off").") }
        guard let set: @convention(c) (Int32) -> Void = symbol("IOBluetooth", "IOBluetoothPreferenceSetControllerPowerState") else {
            openPane("bluetooth")
            return done("Opened in System Settings", "Bluetooth", "Couldn't switch Bluetooth directly; opened Bluetooth settings.")
        }
        // Off disconnects a Bluetooth keyboard, mouse or headphones: ask first.
        if !on {
            let approved = await Approvals.shared.ask(Approval(title: "Turn off Bluetooth", detail: "Bluetooth keyboards, mice and headphones disconnect.",
                                                               action: "Turn off", glyph: .bluetooth, subject: "Bluetooth", icon: settingsApp))
            guard approved else { return ToolResult(content: "The user cancelled.", outcome: .failed("Cancelled")) }
        }
        if !isDryRun {
            set(on ? 1 : 0)
            try? await Task.sleep(nanoseconds: 600_000_000)
            if bluetoothOn != on {
                openPane("bluetooth")
                return done("Opened in System Settings", "Bluetooth", "Bluetooth didn't switch; opened Bluetooth settings.")
            }
        }
        return done(on ? "Turned on" : "Turned off", "Bluetooth", "Bluetooth is \(on ? "on" : "off").")
    }

    // MARK: Display

    /// CoreBrightness's Night Shift client, the one System Settings uses.
    private static var blueLight: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    static var nightShiftOn: Bool? {
        guard let client = blueLight, let cls = object_getClass(client) else { return nil }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard client.responds(to: sel), let imp = class_getMethodImplementation(cls, sel) else { return nil }
        typealias Get = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        // { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; … }: room to spare.
        var status = [UInt8](repeating: 0, count: 64)
        let ok = status.withUnsafeMutableBytes { unsafeBitCast(imp, to: Get.self)(client, sel, $0.baseAddress!) }
        return ok ? status[1] != 0 : nil
    }

    @MainActor
    static func nightShift(_ v: String) -> ToolResult {
        let now = nightShiftOn
        guard let on = onOff(v, current: now) else { return failed("Say on, off or toggle") }
        if on == now { return done("Already", "Night Shift \(on ? "on" : "off")", "Night Shift was already \(on ? "on" : "off").") }
        guard let client = blueLight, let cls = object_getClass(client), client.responds(to: NSSelectorFromString("setEnabled:")),
              let imp = class_getMethodImplementation(cls, NSSelectorFromString("setEnabled:")) else {
            openPane("displays")
            return done("Opened in System Settings", "Night Shift", "Night Shift can't be switched directly here; opened Displays settings, where its button is.")
        }
        if !isDryRun {
            typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Bool
            _ = unsafeBitCast(imp, to: Set.self)(client, NSSelectorFromString("setEnabled:"), on)
            if nightShiftOn != on {
                openPane("displays")
                return done("Opened in System Settings", "Night Shift", "Night Shift didn't switch; opened Displays settings, where its button is.")
            }
        }
        return done(on ? "Turned on" : "Turned off", "Night Shift", "Night Shift is \(on ? "on" : "off").")
    }

    /// The built-in display's brightness, 0…1 (DisplayServices; external displays aren't covered).
    static var brightnessLevel: Float? {
        guard let get: @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32 = symbol("DisplayServices", "DisplayServicesGetBrightness") else { return nil }
        var level: Float = -1
        return get(builtInDisplay, &level) == 0 && level >= 0 ? level : nil
    }

    private static var builtInDisplay: UInt32 {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    @MainActor
    static func brightness(_ v: String) -> ToolResult {
        guard let now = brightnessLevel,
              let set: @convention(c) (UInt32, Float) -> Int32 = symbol("DisplayServices", "DisplayServicesSetBrightness") else {
            openPane("displays")
            return done("Opened in System Settings", "Brightness", "Brightness can't be set directly on this display; opened Displays settings.")
        }
        let percent = Int((now * 100).rounded())
        let target: Int
        switch v {
        case "up", "brighter", "higher": target = min(100, percent + 15)
        case "down", "dimmer", "lower", "dim": target = max(5, percent - 15)
        case "max", "maximum", "full": target = 100
        case "min", "minimum", "lowest": target = 5
        case "half": target = 50
        default:
            guard let n = number(v) else { return failed("Say a level from 0 to 100, up or down") }
            target = max(1, min(100, n))
        }
        if !isDryRun { _ = set(builtInDisplay, Float(target) / 100) }
        return done("Brightness", "\(target)%", "Brightness set to \(target)%.")
    }

    // MARK: Power

    static var lowPowerOn: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// macOS only switches it with your password, so it opens Battery settings, where it's one click.
    @MainActor
    static func lowPower(_ v: String) -> ToolResult {
        let now = lowPowerOn
        guard let on = onOff(v, current: now) else { return failed("Say on, off or toggle") }
        if on == now { return done("Already", "Low Power Mode \(on ? "on" : "off")", "Low Power Mode was already \(on ? "on" : "off").") }
        openPane("battery")
        return done("Opened in System Settings", "Low Power Mode",
                    "macOS only changes Low Power Mode with the user's password, so Battery settings is open: they can switch it \(on ? "on" : "off") there.")
    }

    /// The caffeinate keeping the Mac awake, if any; it also ends when Starlight quits.
    private static var awake: Process?

    @MainActor
    static func keepAwake(_ v: String) -> ToolResult {
        if ["off", "stop", "no", "false", "0"].contains(v) {
            guard let running = awake, running.isRunning else { return done("Already", "Sleeping normally", "The Mac wasn't being kept awake.") }
            running.terminate()
            awake = nil
            return done("Stopped", "Keeping awake", "The Mac can sleep normally again.")
        }
        let minutes = number(v)
        awake?.terminate()
        var arguments = ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if let minutes, minutes > 0 { arguments += ["-t", String(minutes * 60)] }
        if !isDryRun {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            process.arguments = arguments
            guard (try? process.run()) != nil else { return failed("Couldn't keep it awake") }
            awake = process
        }
        let span = minutes.map { $0 % 60 == 0 ? "For \($0 / 60) hour\($0 == 60 ? "" : "s")" : "For \($0) minutes" } ?? "Until you say"
        return done("Keeping awake", span, "Keeping the Mac and its display awake \(span.lowercased()).")
    }

    static var keepingAwake: Bool { awake?.isRunning == true }

    // MARK: Focus

    /// There's no public switch for Focus. A Shortcut can do it: one named like "Do Not Disturb
    /// On" / "Turn Off Do Not Disturb" runs if you have it; otherwise Focus settings opens.
    @MainActor
    static func doNotDisturb(_ v: String) async -> ToolResult {
        guard let on = onOff(v, current: nil) else { return failed("Say on or off") }
        let names = shell("/usr/bin/shortcuts", ["list"]).components(separatedBy: "\n")
        let match = names.first { name in
            let n = name.lowercased()
            guard n.contains("do not disturb") || n.contains("dnd") || n.contains("focus") else { return false }
            return on ? (n.contains(" on") || n.hasSuffix("on") || n.contains("enable") || n.contains("turn on"))
                      : (n.contains("off") || n.contains("disable"))
        }
        if let match, !isDryRun {
            _ = shell("/usr/bin/shortcuts", ["run", match])
            return done(on ? "Turned on" : "Turned off", "Do Not Disturb", "Ran their Shortcut to turn Do Not Disturb \(on ? "on" : "off").")
        }
        openPane("focus")
        return done("Opened in System Settings", "Focus",
                    "macOS has no direct switch for Focus, so Focus settings is open. A Shortcut named \"Do Not Disturb \(on ? "On" : "Off")\" (using Set Focus) would let Starlight do it next time.")
    }

    // MARK: Asked first

    @MainActor
    static func lockScreen() async -> ToolResult {
        guard await Approvals.shared.ask(Approval(title: "Lock the screen", detail: "", action: "Lock", glyph: .key, subject: "Lock screen", icon: settingsApp)) else {
            return ToolResult(content: "The user cancelled.", outcome: .failed("Cancelled"))
        }
        if !isDryRun {
            if let lock: @convention(c) () -> Void = symbol("login", "SACLockScreenImmediate") { lock() }
            else { _ = shell("/usr/bin/pmset", ["displaysleepnow"]) }
        }
        return done("Locked", "Screen", "Locked the screen.")
    }

    @MainActor
    static func sleepDisplay() async -> ToolResult {
        guard await Approvals.shared.ask(Approval(title: "Sleep the display", detail: "", action: "Sleep", glyph: .screen, subject: "Display", icon: settingsApp)) else {
            return ToolResult(content: "The user cancelled.", outcome: .failed("Cancelled"))
        }
        if !isDryRun { _ = shell("/usr/bin/pmset", ["displaysleepnow"]) }
        return done("Put to sleep", "Display", "The display is asleep.")
    }

    @MainActor
    static func runningApp(_ name: String) -> NSRunningApplication? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespaces)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { ($0.localizedName ?? "").lowercased() == wanted }
            ?? apps.first { ($0.localizedName ?? "").lowercased().hasPrefix(wanted) }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(wanted) && wanted.count >= 3 }
    }

    @MainActor
    static func hideApp(_ name: String) -> ToolResult {
        guard let app = runningApp(name) else { return failed("\(name.isEmpty ? "That app" : name.capitalized) isn't open") }
        let title = app.localizedName ?? name
        if !isDryRun { app.hide() }
        return ToolResult(content: "Hid \(title).", outcome: .item("Hid", title, icon: app.bundleURL?.path))
    }

    /// Quits like ⌘Q: the app still asks to save anything unsaved. Asked first all the same.
    @MainActor
    static func quitApp(_ name: String) async -> ToolResult {
        guard let app = runningApp(name), app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return failed("\(name.isEmpty ? "That app" : name.capitalized) isn't open")
        }
        let title = app.localizedName ?? name
        guard await Approvals.shared.ask(Approval(title: "Quit \(title)", detail: "It asks to save anything unsaved.", action: "Quit",
                                                  glyph: .close, subject: title, icon: app.bundleURL?.path)) else {
            return ToolResult(content: "The user cancelled.", outcome: .failed("Cancelled"))
        }
        if !isDryRun { app.terminate() }
        return ToolResult(content: "Quit \(title).", outcome: .item("Quit", title, icon: app.bundleURL?.path))
    }

    // MARK: System Settings

    static let panes: [(names: [String], id: String, title: String)] = [
        (["wifi", "wi-fi", "wireless"], "com.apple.wifi-settings-extension", "Wi-Fi"),
        (["bluetooth"], "com.apple.BluetoothSettings", "Bluetooth"),
        (["network", "vpn", "internet"], "com.apple.Network-Settings.extension", "Network"),
        (["battery", "low power", "power", "energy"], "com.apple.Battery-Settings.extension", "Battery"),
        (["display", "displays", "night shift", "brightness", "resolution", "monitor"], "com.apple.Displays-Settings.extension", "Displays"),
        (["sound", "volume", "audio", "output", "input", "microphone level"], "com.apple.Sound-Settings.extension", "Sound"),
        (["focus", "do not disturb", "dnd"], "com.apple.Focus-Settings.extension", "Focus"),
        (["notifications", "notification"], "com.apple.Notifications-Settings.extension", "Notifications"),
        (["appearance", "dark mode", "light mode", "accent", "theme"], "com.apple.Appearance-Settings.extension", "Appearance"),
        (["keyboard", "shortcuts", "fn", "globe key"], "com.apple.Keyboard-Settings.extension", "Keyboard"),
        (["trackpad"], "com.apple.Trackpad-Settings.extension", "Trackpad"),
        (["mouse"], "com.apple.Mouse-Settings.extension", "Mouse"),
        (["privacy", "security", "permissions", "accessibility permission", "microphone", "screen recording"], "com.apple.settings.PrivacySecurity.extension", "Privacy & Security"),
        (["accessibility"], "com.apple.Accessibility-Settings.extension", "Accessibility"),
        (["control center", "menu bar"], "com.apple.ControlCenter-Settings.extension", "Control Center"),
        (["desktop", "dock", "stage manager", "hot corners"], "com.apple.Desktop-Settings.extension", "Desktop & Dock"),
        (["wallpaper", "background"], "com.apple.Wallpaper-Settings.extension", "Wallpaper"),
        (["screen saver"], "com.apple.ScreenSaver-Settings.extension", "Screen Saver"),
        (["lock screen", "password", "login"], "com.apple.Lock-Screen-Settings.extension", "Lock Screen"),
        (["storage", "disk space"], "com.apple.settings.Storage", "Storage"),
        (["software update", "update", "updates", "macos"], "com.apple.Software-Update-Settings.extension", "Software Update"),
        (["general", "about", "about this mac"], "com.apple.SystemProfiler.AboutExtension", "About"),
        (["users", "accounts", "apple id", "icloud"], "com.apple.systempreferences.AppleIDSettings", "Apple Account"),
        (["date", "time", "clock"], "com.apple.Date-Time-Settings.extension", "Date & Time"),
        (["language", "region"], "com.apple.Localization-Settings.extension", "Language & Region"),
        (["printers", "printer", "scanners"], "com.apple.Print-Scan-Settings.extension", "Printers & Scanners"),
        (["siri", "apple intelligence"], "com.apple.Siri-Settings.extension", "Apple Intelligence & Siri"),
        (["screen time"], "com.apple.Screen-Time-Settings.extension", "Screen Time"),
    ]

    static func pane(_ name: String) -> (id: String, title: String)? {
        let n = name.lowercased().replacingOccurrences(of: " settings", with: "").trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return ("", "System Settings") }
        if let exact = panes.first(where: { $0.names.contains(n) }) { return (exact.id, exact.title) }
        return panes.first { $0.names.contains { n.contains($0) } }.map { ($0.id, $0.title) }
    }

    @discardableResult
    static func openPane(_ name: String) -> Bool {
        guard !isDryRun, let found = pane(name) else { return pane(name) != nil }
        let url = URL(string: found.id.isEmpty ? "x-apple.systempreferences:" : "x-apple.systempreferences:\(found.id)")
            ?? URL(fileURLWithPath: settingsApp)
        return NSWorkspace.shared.open(url)
    }

    @MainActor
    static func openSettings(_ v: String) -> ToolResult {
        guard let found = pane(v) else {
            openPane("")
            return done("Opened", "System Settings", "There's no page called \(v); opened System Settings.")
        }
        openPane(v)
        if found.id.isEmpty { return done("Opened", "System Settings", "Opened System Settings.") }
        return done("Opened in System Settings", found.title, "Opened \(found.title) settings.")
    }

    // MARK: Status

    static func status() -> String {
        var lines: [String] = []
        lines.append("Appearance: \(isDark ? "dark" : "light")")
        if let sound = currentVolume() { lines.append("Volume: \(sound.level)%\(sound.muted ? ", muted" : "")") }
        if let level = brightnessLevel { lines.append("Brightness: \(Int((level * 100).rounded()))%") }
        if let on = nightShiftOn { lines.append("Night Shift: \(on ? "on" : "off")") }
        if let on = wifiOn { lines.append("Wi-Fi: \(on ? "on" : "off")") }
        if let on = bluetoothOn { lines.append("Bluetooth: \(on ? "on" : "off")") }
        else { lines.append("Bluetooth: unknown (Starlight has no Bluetooth permission)") }
        let battery = shell("/usr/bin/pmset", ["-g", "batt"])
        if let percent = battery.range(of: #"\d+%"#, options: .regularExpression) {
            let charging = battery.contains("AC Power") ? ", plugged in" : battery.contains("discharging") ? ", on battery" : ""
            lines.append("Battery: \(battery[percent])\(charging)")
        }
        lines.append("Low Power Mode: \(lowPowerOn ? "on" : "off")")
        lines.append("Kept awake by Starlight: \(keepingAwake ? "yes" : "no")")
        return lines.joined(separator: "\n")
    }

    // MARK: Plain questions

    /// "Is Wi-Fi on?", "what's my battery at", "is Night Shift on right now": answered from the
    /// Mac itself, at once. Nil for anything else.
    static func answer(_ text: String) -> String? {
        let t = " " + text.lowercased().replacingOccurrences(of: #"[?.!,]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + " "
        guard text.count < 80 else { return nil }
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        guard has(#"^ (hey notch |notch )?(is|are|what's|whats|what is|how much|how's|hows|check|do i have)\b"#) else { return nil }
        func onOff(_ on: Bool?, _ name: String) -> String? { on.map { "\(name) is \($0 ? "on" : "off")." } }
        if has(#"\bnight ?shift\b"#) { return onOff(nightShiftOn, "Night Shift") ?? "Couldn't read Night Shift here." }
        if has(#"\b(wi-?fi|wireless)\b"#) && !has(#"password|network name|called|speed"#) { return onOff(wifiOn, "Wi-Fi") ?? "This Mac has no Wi-Fi." }
        if has(#"\bbluetooth\b"#) { return onOff(bluetoothOn, "Bluetooth") ?? "Starlight needs Bluetooth permission to see that." }
        if has(#"\b(dark|light) mode\b"#) { return isDark ? "Dark mode is on." : "Light mode is on." }
        if has(#"\blow ?power\b"#) { return "Low Power Mode is \(lowPowerOn ? "on" : "off")." }
        if has(#"\b(kept|keeping|staying) awake\b"#) { return keepingAwake ? "Yes, Starlight is keeping it awake." : "No, it sleeps as usual." }
        if has(#"\bbattery\b"#) || has(#"\bhow much (charge|juice)\b"#) {
            let battery = shell("/usr/bin/pmset", ["-g", "batt"])
            guard let r = battery.range(of: #"\d+%"#, options: .regularExpression) else { return "This Mac has no battery." }
            let state = battery.contains("AC Power") ? (battery.contains("charged") ? ", charged" : ", charging") : ", on battery"
            let left = battery.range(of: #"\d+:\d+ remaining"#, options: .regularExpression).map { ", \(battery[$0].replacingOccurrences(of: " remaining", with: "")) left" } ?? ""
            return "\(battery[r])\(state)\(state == ", on battery" ? left : "")."
        }
        if has(#"\b(volume|sound) (at|level|on|up|set)?\b"#) && has(#"\b(volume|muted)\b"#), let sound = currentVolume() {
            return sound.muted ? "Muted, at \(sound.level)%." : "Volume is at \(sound.level)%."
        }
        if has(#"\bbrightness\b"#), let level = brightnessLevel { return "Brightness is at \(Int((level * 100).rounded()))%." }
        return nil
    }

    // MARK: Parsing plain commands

    /// "Turn on dark mode", "volume to 30", "keep my Mac awake for an hour": the action and its
    /// value, for doing it without the model. Nil for anything less plain (questions included).
    static func parse(_ text: String) -> (action: String, value: String)? {
        var t = " " + text.lowercased()
            .replacingOccurrences(of: #"[.!,]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) + " "
        guard !text.contains("?"), text.count < 90 else { return nil }
        // Asking about it, not asking for it.
        if t.range(of: #"^ (what|why|how|is|are|does|do|which|when|where|who)\b"#, options: .regularExpression) != nil { return nil }
        t = t.replacingOccurrences(of: #"^ (hey |ok |okay )?(notch )?(please |can you |could you |would you |go ahead and |just )*"#, with: " ", options: .regularExpression)
        func has(_ pattern: String) -> Bool { t.range(of: pattern, options: .regularExpression) != nil }
        let off = has(#"\b(off|disable|deactivate|stop|kill|no more)\b"#)
        let on = has(#"\b(on|enable|activate|start)\b"#)
        let toggle = has(#"\btoggle\b"#)
        let state = off ? "off" : on ? "on" : toggle ? "toggle" : ""
        // A command, not a remark about it: it starts like one ("turn on…", "switch to…"), or it's
        // short enough to be nothing else ("dark mode", "night shift off", "louder").
        let commanding = has(#"^ (turn|switch|set|go|enable|disable|toggle|put|make|use|activate|deactivate|start|stop|change|bring|give me|i want|i'd like|raise|lower|increase|decrease|crank)\b"#)
            || t.split(separator: " ").count <= 4
        guard commanding || has(#"^ (keep|lock|hide|quit|close|open|show|pull up|mute|unmute|let|don't let|caffeinate)\b"#) else { return nil }
        // Commands that name their target first: "open sound settings" is a page, not the volume.
        if has(#"^ lock (my |the )?(mac|screen|computer|laptop)\b"#) { return ("lock_screen", "") }
        if has(#"\b(sleep|turn off) (the |my )?(display|screen|monitor)\b"#) || has(#"\b(display|screen) to sleep\b"#) { return ("sleep_display", "") }
        if let app = capture(#"^ hide (.{2,30}?) $"#, t), !["it", "this", "that", "everything"].contains(app) { return ("hide_app", app) }
        if let app = capture(#"^ (?:quit|close) (?:the app |app )?(.{2,30}?) $"#, t), !app.contains("window"), !app.contains("tab"),
           !["it", "this", "that", "everything", "all"].contains(app) { return ("quit_app", app) }
        if let page = capture(#"^ (?:open|show|go to|bring up|pull up) (?:the |my )?(.{2,30}?) settings $"#, t) { return ("open_settings", page) }
        if has(#"^ (open|show|go to) (system settings|settings|system preferences) $"#) { return ("open_settings", "") }

        if has(#"\b(dark|light) (mode|theme|appearance)\b"#) || has(#"\b(go|switch|change|set|make it) (to )?(dark|light)\b"#) {
            let light = has(#"\blight\b"#) && !has(#"\bdark\b"#)
            if toggle { return ("dark_mode", "toggle") }
            return ("dark_mode", light != off ? "off" : "on")
        }
        if has(#"\bnight ?shift\b"#) { return ("night_shift", state.isEmpty ? "on" : state) }
        if has(#"\blow ?power\b"#) { return ("low_power", state.isEmpty ? "on" : state) }
        if has(#"\b(do not disturb|don't disturb|dnd|focus mode)\b"#) { return ("do_not_disturb", state.isEmpty ? "on" : state) }
        if has(#"\b(wi-?fi|wireless)\b"#), !state.isEmpty { return ("wifi", state) }
        if has(#"\bbluetooth\b"#), !state.isEmpty { return ("bluetooth", state) }
        if has(#"\bunmute\b"#) { return ("mute", "off") }
        if has(#"^ mute $"#) || has(#"^ mute (the |my )?(sound|audio|volume|mac|computer|it|everything) $"#) { return ("mute", "on") }

        let level = t.range(of: #"\b(\d{1,3}) ?(%|percent)?"#, options: .regularExpression).map { String(t[$0]).filter(\.isNumber) }
        if has(#"\b(volume|sound)\b"#) || has(#"\b(louder|quieter|softer)\b"#) {
            if let level, has(#"\b(to|at|set)\b"#) || has(#"%|percent"#) { return ("volume", level) }
            if has(#"\b(max|maximum|all the way up|full)\b"#) { return ("volume", "max") }
            if has(#"\b(up|louder|higher|raise|increase)\b"#) { return ("volume", "up") }
            if has(#"\b(down|quieter|softer|lower|decrease)\b"#) { return ("volume", "down") }
            return nil
        }
        if has(#"\b(brightness|brighter|dimmer|dim the|dim my)\b"#) {
            if let level, has(#"\b(to|at|set)\b"#) || has(#"%|percent"#) { return ("brightness", level) }
            if has(#"\b(max|maximum|full|all the way up)\b"#) { return ("brightness", "max") }
            if has(#"\b(up|brighter|raise|increase|higher)\b"#) { return ("brightness", "up") }
            if has(#"\b(down|dimmer|dim|lower|decrease)\b"#) { return ("brightness", "down") }
            return nil
        }
        if has(#"\b(keep|keeping|stay|staying)\b.*\bawake\b"#) || has(#"\bdon't let (it|my mac|the mac|my computer) sleep\b"#) || has(#"\bcaffeinate\b"#) {
            if has(#"\b(stop|don't|no longer|quit)\b.*\bawake\b"#) && !has(#"don't let"#) { return ("keep_awake", "off") }
            if let n = t.range(of: #"\b(\d+|an|one|a|two|three|half an) (hour|hours|minute|minutes|min|mins)\b"#, options: .regularExpression) {
                let words = t[n].split(separator: " ")
                let count: Double = switch words[0] { case "an", "one", "a": 1; case "two": 2; case "three": 3; case "half": 0.5; default: Double(words[0]) ?? 1 }
                let unit = words.last.map(String.init) ?? ""
                return ("keep_awake", String(Int(unit.hasPrefix("hour") ? count * 60 : (words[0] == "half" ? 30 : count))))
            }
            return ("keep_awake", "")
        }
        if has(#"\blet (it|my mac|the mac|my computer) sleep\b"#) { return ("keep_awake", "off") }
        return nil
    }

    // MARK: Plumbing

    /// A C function from a system framework, nil when this macOS doesn't have it.
    static func symbol<T>(_ framework: String, _ name: String) -> T? {
        let paths = ["/System/Library/PrivateFrameworks/\(framework).framework/\(framework)",
                     "/System/Library/Frameworks/\(framework).framework/\(framework)",
                     "/System/Library/PrivateFrameworks/\(framework).framework/Versions/Current/\(framework)"]
        for path in paths {
            if let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, name) { return unsafeBitCast(sym, to: T.self) }
        }
        return nil
    }

    @discardableResult
    static func appleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        AppleScript.run(source, error: &error)
        if let error { DebugLog.write("mac control: script failed: \(error)") }
        return error == nil
    }

    static func shell(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func number(_ v: String) -> Int? {
        let digits = v.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}
