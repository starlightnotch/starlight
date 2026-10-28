import AppKit
import AVFoundation
import CoreBluetooth
import EventKit
import SwiftUI

/// Every macOS permission Starlight can use, in one card on the Privacy page: what it's for,
/// whether it's allowed, and one click to allow it (macOS's own prompt, or the right pane of
/// System Settings).
struct PermissionsCard: View {
    @State private var refresh = 0
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        let _ = refresh
        Section(title: "Permissions") {
            ForEach(Array(Permission.all.enumerated()), id: \.element.id) { index, permission in
                PermissionRow(permission: permission, last: index == Permission.all.count - 1) { refresh += 1 }
            }
        }
        .onReceive(timer) { _ in refresh += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh += 1 }
    }
}

struct Permission: Identifiable {
    enum State { case allowed, notAllowed, notAsked, asksWhenUsed }

    let id: String
    let name: String
    let purpose: String
    /// What it does for you, in two or three words, for its bubble: "Microphone · hears you".
    let does: String
    let glyph: Glyph.Kind
    /// The Privacy & Security pane, for when macOS won't prompt again.
    let pane: String
    let state: () -> State
    /// Shows macOS's prompt; nil opens System Settings instead.
    var request: (() -> Void)? = nil

    static let all: [Permission] = ["mic", "accessibility", "audio", "screen", "reminders", "bluetooth", "automation"]
        .compactMap { id in ordered.first { $0.id == id } }

    private static let ordered: [Permission] = [
        Permission(id: "mic", name: "Microphone", purpose: "Dictation and your side of meetings", does: "hears you", glyph: .voice,
                   pane: "Privacy_Microphone",
                   state: {
                       switch AVCaptureDevice.authorizationStatus(for: .audio) {
                       case .authorized: .allowed
                       case .notDetermined: .notAsked
                       default: .notAllowed
                       }
                   },
                   request: { AVCaptureDevice.requestAccess(for: .audio) { _ in } }),
        Permission(id: "audio", name: "System audio", purpose: "Hearing the other side of meetings", does: "hears the call", glyph: .headphones,
                   pane: "Privacy_AudioCapture",
                   state: {
                       if AppSettings.shared.theirAudioProblem != nil { return .notAllowed }
                       return UserDefaults.standard.bool(forKey: SystemAudioPermission.key) ? .allowed : .notAsked
                   },
                   request: { SystemAudioPermission.request() }),
        Permission(id: "accessibility", name: "Accessibility", purpose: "Pasting into text fields and reading the screen", does: "types for you", glyph: .mouse,
                   pane: "Privacy_Accessibility",
                   state: { AXIsProcessTrusted() ? .allowed : .notAllowed },
                   request: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }),
        Permission(id: "screen", name: "Screen Recording", purpose: "Reading apps that draw their own text", does: "reads the screen", glyph: .screen2,
                   pane: "Privacy_ScreenCapture",
                   state: { CGPreflightScreenCaptureAccess() ? .allowed : .notAllowed },
                   request: { _ = CGRequestScreenCaptureAccess() }),
        Permission(id: "automation", name: "Automation", purpose: "Now Playing controls for Spotify and Music", does: "plays your music", glyph: .play,
                   pane: "Privacy_Automation",
                   state: { .asksWhenUsed }),
        Permission(id: "reminders", name: "Reminders", purpose: "Adding reminders when you ask", does: "adds reminders", glyph: .todo,
                   pane: "Privacy_Reminders",
                   state: {
                       switch EKEventStore.authorizationStatus(for: .reminder) {
                       case .fullAccess, .writeOnly: .allowed
                       case .notDetermined: .notAsked
                       default: .notAllowed
                       }
                   },
                   request: { Task { _ = try? await EKEventStore().requestFullAccessToReminders() } }),
        Permission(id: "bluetooth", name: "Bluetooth", purpose: "Headphone and device batteries", does: "shows batteries", glyph: .bluetooth,
                   pane: "Privacy_Bluetooth",
                   state: {
                       switch CBManager.authorization {
                       case .allowedAlways: .allowed
                       case .notDetermined: .notAsked
                       default: .notAllowed
                       }
                   },
                   request: { BluetoothPermission.request() }),
    ]

    /// Allowed, or nothing left to do now ("asks when used").
    var isSettled: Bool { let s = state(); return s == .allowed || s == .asksWhenUsed }

    static func named(_ id: String) -> Permission? { all.first { $0.id == id } }

    /// Asks: macOS's own prompt while it will still show one, otherwise its page in System
    /// Settings. True when that's System Settings (and you turn Starlight on in the list there).
    @discardableResult
    func ask() -> Bool {
        let before = state()
        NSApp.activate(ignoringOtherApps: true)  // so macOS's prompt comes up in front
        request?()
        guard before != .notAsked || request == nil else { return false }
        openSettings()
        return true
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

private struct PermissionRow: View {
    let permission: Permission
    let last: Bool
    let changed: () -> Void
    @State private var hovering = false

    var body: some View {
        let state = permission.state()
        HStack(spacing: 12) {
            GlyphWell(kind: permission.glyph, size: 30, active: hovering)
            Text(permission.name).font(.system(size: 13, weight: .medium))
            Spacer(minLength: 12)
            switch state {
            case .allowed:
                HStack(spacing: 5) {
                    OutcomeBadge(ok: true, size: 14)
                    Text("Allowed").font(.system(size: 12, weight: .medium)).opacity(0.7)
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .asksWhenUsed:
                Text("Asks when used").font(.system(size: 12)).opacity(0.4)
            case .notAsked, .notAllowed:
                GlassButton(title: state == .notAsked ? "Allow" : "Open Settings") {
                    permission.request?()  // also lists Starlight in System Settings
                    if state != .notAsked || permission.request == nil { permission.openSettings() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { changed() }
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .modifier(HoverInfo(title: permission.name, lines: [permission.purpose], glyph: permission.glyph))
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.leading, 42) } }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state == .allowed)
    }
}

/// macOS asks about recording system audio the first time a process tap starts, so allowing it
/// starts one for a moment. A tap that starts is remembered as allowed.
enum SystemAudioPermission {
    static let key = "systemAudioAllowed"
    private static let queue = DispatchQueue(label: "notch.audio-permission")

    static func request() {
        queue.async {
            let capture = SystemAudioCapture()
            do {
                try capture.start()
                capture.stop()
                DispatchQueue.main.async {
                    UserDefaults.standard.set(true, forKey: key)
                    AppSettings.shared.theirAudioProblem = nil
                }
            } catch {
                DispatchQueue.main.async { AppSettings.shared.theirAudioProblem = "Not allowed" }
            }
        }
    }
}

/// macOS asks about Bluetooth when a central manager is first made.
enum BluetoothPermission {
    private static var manager: CBCentralManager?
    static func request() { if manager == nil { manager = CBCentralManager(delegate: nil, queue: nil) } }
}
