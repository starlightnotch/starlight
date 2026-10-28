import CoreAudio
import Foundation

/// Notices when a meeting app starts using the microphone, the way Granola does: poll Core Audio's
/// process list once a second, keep the processes that are running input, map helpers to their
/// app, and keep only known meeting apps. A new app must hold the mic for 2s before it's reported;
/// it counts as gone 2s after it lets go.
final class MeetingDetector {
    /// Called on the main thread with the meeting app using the mic, or nil when none is.
    var onChange: ((MeetingApp?) -> Void)?
    private(set) var current: MeetingApp?

    private var timer: Timer?
    private var candidate: MeetingApp?
    private var candidateSince = Date.distantPast
    private var goneSince: Date?
    private let startDelay: TimeInterval = 2   // Granola: mic_apps_notification_delay_seconds = 2
    private let endGrace: TimeInterval = 2     // Granola waits 2s before publishing "no mic apps"

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let now = Date()
        if let app = Self.meetingAppsUsingMicrophone().first {
            goneSince = nil
            guard app != current else { return }
            if candidate != app {
                candidate = app
                candidateSince = now
            } else if now.timeIntervalSince(candidateSince) >= startDelay {
                current = app
                onChange?(app)
            }
        } else {
            candidate = nil
            guard current != nil else { return }
            if let goneSince {
                if now.timeIntervalSince(goneSince) >= endGrace {
                    current = nil
                    self.goneSince = nil
                    onChange?(nil)
                }
            } else {
                goneSince = now
            }
        }
    }

    // MARK: Core Audio process objects

    /// Meeting apps with a process currently capturing from an input device. Starlight itself
    /// (dictation, meeting notes) is excluded.
    static func meetingAppsUsingMicrophone() -> [MeetingApp] {
        let me = getpid()
        var apps: [MeetingApp] = []
        for process in processObjects() where isRunningInput(process) && pid(of: process) != me {
            if let id = bundleID(of: process), let app = MeetingApp.from(processBundleID: id), !apps.contains(app) {
                apps.append(app)
            }
        }
        return apps
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value)
        return value
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
