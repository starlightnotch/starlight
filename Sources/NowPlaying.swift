import AppKit
import Combine
import IOKit.ps

/// What Spotify or Apple Music is playing, for the notch. Both apps announce every play, pause
/// and track change with a distributed notification (com.spotify.client.PlaybackStateChanged,
/// com.apple.Music.playerInfo), so there's no polling. Artwork and the controls go through the
/// apps' AppleScript, and only while the app is already running, so Starlight never launches one.
/// macOS asks once per app before Starlight may control it.
final class NowPlaying: ObservableObject {
    enum Source: String {
        case spotify = "Spotify", music = "Music"
        /// Other media: YouTube in a browser, QuickTime, VLC, Podcasts… (MediaWatcher).
        case other = "Other"
        var bundleID: String { self == .spotify ? "com.spotify.client" : self == .music ? "com.apple.Music" : "" }
        var isRunning: Bool { self != .other && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    struct Track: Equatable {
        var source: Source
        var title: String
        var artist: String
        var album: String
        var isPlaying: Bool
        var artwork: NSImage?
        /// The app it's playing in, as shown in the notch ("Spotify", "YouTube", "QuickTime Player").
        var app: String = ""

        static func == (a: Track, b: Track) -> Bool {
            a.source == b.source && a.title == b.title && a.artist == b.artist && a.isPlaying == b.isPlaying
                && (a.artwork == nil) == (b.artwork == nil)
        }
    }

    static let shared = NowPlaying()
    @Published private(set) var track: Track?
    private var observers: [Any] = []
    private var artworkKey = ""

    private init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
            self?.update(from: note.userInfo, source: .spotify)
        })
        observers.append(center.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            self?.update(from: note.userInfo, source: .music)
        })
        // Something already playing when Starlight starts.
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.refresh() }
    }

    var isPlaying: Bool { track?.isPlaying == true }

    // MARK: Controls

    func playPause() { track?.source == .other ? MediaKeys.press(.playPause) : send("playpause") }
    func next() { track?.source == .other ? MediaKeys.press(.next) : send("next track") }
    func previous() { track?.source == .other ? MediaKeys.press(.previous) : send("previous track") }

    /// From MediaWatcher: what's playing outside Spotify and Music (nil: nothing). Spotify or
    /// Music playing wins; otherwise this shows.
    func setOther(_ other: Track?) {
        if let current = track, current.source != .other, current.isPlaying, current.source.isRunning { return }
        if let other {
            if track?.source == .other, track?.title == other.title, track?.artwork != nil, other.artwork == nil {
                var kept = other
                kept.artwork = track?.artwork
                track = kept
            } else {
                track = other
            }
        } else if track?.source == .other {
            track = nil
        }
    }

    private func send(_ command: String) {
        guard let source = track?.source, source.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run("tell application \"\(source.rawValue)\" to \(command)")
        }
    }

    // MARK: State

    private func update(from info: [AnyHashable: Any]?, source: Source) {
        guard let info else { return }
        let state = info["Player State"] as? String ?? ""
        if state == "Stopped" || info["Name"] == nil {
            if track?.source == source { track = nil }
            return
        }
        let next = Track(source: source,
                         title: info["Name"] as? String ?? "",
                         artist: info["Artist"] as? String ?? "",
                         album: info["Album"] as? String ?? "",
                         isPlaying: state == "Playing",
                         artwork: sameSong(info, source) ? track?.artwork : nil,
                         app: source == .spotify ? "Spotify" : "Music")
        track = next
        loadArtwork(for: next)
    }

    private func sameSong(_ info: [AnyHashable: Any], _ source: Source) -> Bool {
        track?.source == source && track?.title == info["Name"] as? String && track?.artist == info["Artist"] as? String
    }

    /// Asks a running player what it's doing (at launch, before any notification arrives).
    private func refresh() {
        for source in [Source.spotify, .music] where source.isRunning {
            let script = """
            tell application "\(source.rawValue)"
                if player state is playing or player state is paused then
                    return (player state as text) & "\\n" & (name of current track) & "\\n" & (artist of current track) & "\\n" & (album of current track)
                end if
            end tell
            """
            guard let reply = Self.run(script) else { continue }
            let parts = reply.components(separatedBy: "\n")
            guard parts.count >= 4 else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.update(from: ["Player State": parts[0] == "playing" ? "Playing" : "Paused",
                                    "Name": parts[1], "Artist": parts[2], "Album": parts[3]], source: source)
            }
            return
        }
    }

    private func loadArtwork(for track: Track) {
        let key = "\(track.source.rawValue)|\(track.title)|\(track.artist)"
        guard track.source != .other, track.artwork == nil, key != artworkKey else { return }
        artworkKey = key
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var image: NSImage?
            switch track.source {
            case .spotify:
                if let url = Self.run("tell application \"Spotify\" to artwork url of current track").flatMap(URL.init(string:)),
                   let data = try? Data(contentsOf: url) { image = NSImage(data: data) }
            case .other:
                return
            case .music:
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("notch-artwork.dat")
                let script = """
                tell application "Music"
                    try
                        set artData to raw data of artwork 1 of current track
                        set f to open for access POSIX file "\(file.path)" with write permission
                        set eof of f to 0
                        write artData to f
                        close access f
                        return "ok"
                    end try
                end tell
                """
                if Self.run(script) == "ok", let data = try? Data(contentsOf: file) { image = NSImage(data: data) }
            }
            guard let image else { return }
            DispatchQueue.main.async {
                guard let self, var current = self.track, current.title == track.title, current.source == track.source else { return }
                current.artwork = image
                self.track = current
            }
        }
    }

    @discardableResult
    /// Where the song is: seconds in, and its length. Off the main thread; nil for players that
    /// don't say (browsers, other apps).
    func progress(_ done: @escaping ((position: Double, duration: Double)?) -> Void) {
        guard let source = track?.source, source != .other, source.isRunning else { return done(nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            // Spotify gives the length in milliseconds, Music in seconds.
            let script = "tell application \"\(source.rawValue)\" to (player position as text) & \"|\" & (duration of current track as text)"
            let parts = Self.run(script)?.replacingOccurrences(of: ",", with: ".").components(separatedBy: "|").compactMap(Double.init) ?? []
            var result: (Double, Double)?
            if parts.count == 2 {
                let length = source == .spotify ? parts[1] / 1000 : parts[1]
                if length > 0 { result = (parts[0], length) }
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = AppleScript.run(source, error: &error)
        if let error { DebugLog.write("now playing: \(error[NSAppleScript.errorMessage] ?? error)") }
        return result?.stringValue
    }
}

/// NSAppleScript isn't safe to run on several threads at once, and Now Playing, the browser tabs
/// and the agent's Mac controls all use it from their own: every script goes through this one
/// queue, one at a time. (Never call it from a script already running on it.)
enum AppleScript {
    private static let queue = DispatchQueue(label: "starlight.applescript", qos: .userInitiated)

    @discardableResult
    static func run(_ source: String, error: inout NSDictionary?) -> NSAppleEventDescriptor? {
        var failure: NSDictionary?
        let result = queue.sync { NSAppleScript(source: source)?.executeAndReturnError(&failure) }
        error = failure
        return result
    }
}

/// The Mac's battery, for the open notch.
enum Battery {
    struct Status: Equatable {
        let percent: Int
        let charging: Bool
    }

    static func current() -> Status? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let charging = (description[kIOPSIsChargingKey] as? Bool) == true
                || (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return Status(percent: Int((Double(capacity) / Double(max) * 100).rounded()), charging: charging)
        }
        return nil
    }
}
