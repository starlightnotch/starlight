import AppKit
import CoreAudio

/// What's playing outside Spotify and Music, read from Core Audio's process list (which apps are
/// sending audio out right now). Only real media counts, so a website's click sounds or a game
/// never show up as "now playing":
/// - in a browser, YouTube and YouTube Music only (the tab gives the title and a thumbnail).
///   Chrome, Brave and Edge also say in their tab strip which tab is making sound, so a paused
///   video isn't shown as playing while another site makes noise;
/// - other apps only when they're media players (QuickTime, VLC, Podcasts, or any app that files
///   itself under Music or Video).
/// Controls go through the keyboard's media keys, which every player answers to.
///
/// Checked every two seconds while Now Playing is on. A player that stops making sound stays
/// as paused for a couple of minutes, so you can resume it from the notch.
final class MediaWatcher {
    static let shared = MediaWatcher()
    private var timer: Timer?
    private var last: NowPlaying.Track?
    private var silentSince: Date?
    /// What each app making sound was, last time we looked (nil: nothing to show), and when.
    private var lookups: [String: (at: Date, track: NowPlaying.Track?)] = [:]
    private var players: [String: Bool] = [:]
    private let queue = DispatchQueue(label: "notch.media", qos: .utility)

    static let pausedFor: TimeInterval = 120

    /// Browsers whose tabs can be read (with macOS's one-time Automation prompt).
    static let browsers: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.apple.Safari": "Safari", "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave Browser", "com.microsoft.edgemac": "Microsoft Edge", "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
    ]

    /// Chrome-based browsers with Chrome's own tab strip, which labels the tab making sound
    /// ("… - Audio playing") for Accessibility.
    static let labelledTabStrips: Set<String> = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac"]

    /// Media players that don't file themselves under Music or Video.
    static let knownPlayers: Set<String> = ["com.apple.QuickTimePlayerX", "com.apple.TV", "com.apple.podcasts", "com.apple.iBooksX",
                                            "org.videolan.vlc", "com.colliderli.iina"]

    /// Never shown as "now playing": Starlight itself, system sounds, call apps (a meeting isn't media).
    static let ignored: Set<String> = [
        Bundle.main.bundleIdentifier ?? "com.starlightnotch.app", "com.apple.systemsound", "com.apple.coreaudiod",
        "com.spotify.client", "com.apple.Music", "us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap",
    ]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NowPlaying.shared.setOther(nil)
    }

    private func check() {
        guard AppSettings.shared.showNowPlaying else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let playing = Self.appsPlayingAudio().filter { !Self.ignored.contains($0) }
            // Browsers first (YouTube is the usual case), then media players; anything else isn't media.
            let candidates = playing.filter { Self.browsers[$0] != nil } + playing.filter { Self.browsers[$0] == nil && self.isPlayer($0) }
            var track: NowPlaying.Track?
            for bundleID in candidates {
                // Each app is looked at most every 5 s (AppleScript is slow-ish); in between it keeps its answer.
                if let cached = self.lookups[bundleID], Date().timeIntervalSince(cached.at) < 5 {
                    track = cached.track
                } else {
                    track = Self.describe(bundleID)
                    self.lookups[bundleID] = (Date(), track)
                }
                if track != nil { break }
            }
            self.lookups = self.lookups.filter { candidates.contains($0.key) }
            if track != nil {
                self.silentSince = nil
                track?.isPlaying = true
            } else if var paused = self.last {
                // Went quiet: paused, for a while.
                self.silentSince = self.silentSince ?? Date()
                if Date().timeIntervalSince(self.silentSince!) < Self.pausedFor {
                    paused.isPlaying = false
                    track = paused
                }
            }
            let changed = track != self.last || (track?.artwork == nil) != (self.last?.artwork == nil)
            self.last = track
            if let video = track.flatMap({ Self.youTubeID($0.album) }), track?.artwork == nil { self.loadThumbnail(video, for: track!) }
            guard changed else { return }
            DispatchQueue.main.async { NowPlaying.shared.setOther(track) }
        }
    }

    // MARK: Who's playing

    /// Bundle IDs of the processes sending audio out right now (Core Audio process objects, macOS 14.4+).
    static func appsPlayingAudio() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        var playing: [String] = []
        for object in objects {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle)
            var id = bundle?.takeRetainedValue() as String? ?? ""
            if id.isEmpty {
                // No bundle ID on the audio object: ask the process (helpers, some players).
                var pid: pid_t = 0
                var pidSize = UInt32(MemoryLayout<pid_t>.size)
                var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr {
                    id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                }
            }
            guard !id.isEmpty else { continue }  // command-line tools (afplay, say) aren't media
            // Browser helpers ("com.google.Chrome.helper") count as the browser.
            let owner = browsers.keys.first { id.hasPrefix($0) } ?? id
            // Only real apps (ones with a Dock icon): system services that make sound, like
            // speech recognition ("Apple Core Speech") or alerts, aren't media.
            guard isMediaApp(owner), !playing.contains(owner) else { continue }
            playing.append(owner)
        }
        return playing
    }

    /// A regular app the user opened (not a background service or helper), and not one of
    /// Apple's system components unless it's a player.
    static func isMediaApp(_ bundleID: String) -> Bool {
        let applePlayers: Set<String> = ["com.apple.Safari", "com.apple.QuickTimePlayerX", "com.apple.podcasts", "com.apple.TV",
                                         "com.apple.iBooksX", "com.apple.Music"]
        if bundleID.hasPrefix("com.apple."), !applePlayers.contains(bundleID) { return false }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { $0.activationPolicy == .regular }
    }

    /// A media player: one we know, or an app that files itself under Music or Video in its
    /// Info.plist (Tidal, Plex, Infuse…). Call apps that do (Zoom) are already ignored.
    private func isPlayer(_ bundleID: String) -> Bool {
        if let known = players[bundleID] { return known }
        var player = Self.knownPlayers.contains(bundleID)
        if !player, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String {
            player = category == "public.app-category.music" || category == "public.app-category.video"
        }
        players[bundleID] = player
        return player
    }

    /// What the notch would show for an app making sound, or nil (for --media).
    func preview(_ bundleID: String) -> String? {
        guard !Self.ignored.contains(bundleID), Self.browsers[bundleID] != nil || isPlayer(bundleID),
              let track = Self.describe(bundleID) else { return nil }
        return "\(track.app): \(track.title)"
    }

    // MARK: What it is

    /// The track for an app making sound, or nil when it isn't media we show (a browser with no
    /// YouTube playing).
    private static func describe(_ bundleID: String) -> NowPlaying.Track? {
        let appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? browsers[bundleID] ?? bundleID
        guard let browser = browsers[bundleID] else {
            return NowPlaying.Track(source: .other, title: appName, artist: "Playing", album: "", isPlaying: true, artwork: nil, app: appName)
        }
        guard let tab = playingYouTubeTab(bundleID: bundleID, browser: browser) else { return nil }
        let site = tab.url.contains("music.youtube.com") ? "YouTube Music" : "YouTube"
        var title = tab.title
            .replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[-–]\s*YouTube( Music)?$"#, with: "", options: .regularExpression)
        if title.isEmpty { title = site }
        return NowPlaying.Track(source: .other, title: title, artist: site, album: tab.url, isPlaying: true, artwork: nil, app: site)
    }

    /// The YouTube or YouTube Music tab that's playing. Where the tab strip says which tab is
    /// making sound, only that tab counts; elsewhere (Safari, Arc, other languages), any YouTube
    /// tab does, the front one first.
    private static func playingYouTubeTab(bundleID: String, browser: String) -> (title: String, url: String)? {
        guard let open = youTubeTabs(in: browser, safari: bundleID == "com.apple.Safari"), !open.tabs.isEmpty else { return nil }
        // The tab strip's labels are in the browser's language; we know the English one.
        guard labelledTabStrips.contains(bundleID), Locale.preferredLanguages.first?.hasPrefix("en") == true,
              let strip = tabLabels(of: bundleID), !strip.labels.isEmpty, strip.windows >= open.windows else { return open.tabs.first }
        let audible = strip.labels.filter { $0.contains(" - Audio playing") }
        if let tab = open.tabs.first(where: { tab in audible.contains { $0.hasPrefix(tab.title) } }) { return tab }
        // The title changed between the two reads: with one YouTube tab, it's that one.
        if open.tabs.count == 1, audible.contains(where: { $0.contains("YouTube") }) { return open.tabs[0] }
        return nil
    }

    /// Every YouTube and YouTube Music tab in the browser (each window's front tab first), and how
    /// many windows it has.
    private static func youTubeTabs(in browser: String, safari: Bool) -> (tabs: [(title: String, url: String)], windows: Int)? {
        let name = safari ? "name" : "title", front = safari ? "current tab" : "active tab"
        let script = """
        tell application "\(browser)"
            set out to (count of windows) as text
            repeat with w in windows
                try
                    set f to URL of \(front) of w
                    repeat with t in tabs of w
                        set u to URL of t
                        if u contains "youtube.com/watch" or u contains "youtube.com/shorts/" or u contains "music.youtube.com" or u contains "youtu.be/" then
                            set mark to "0"
                            if u is f then set mark to "1"
                            set out to out & "\\n" & mark & "\\t" & (\(name) of t) & "\\t" & u
                        end if
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        guard let result = AppleScript.run(script, error: &error)?.stringValue else { return nil }
        var lines = result.components(separatedBy: "\n")
        let windows = Int(lines.removeFirst()) ?? 0
        let tabs = lines.map { $0.components(separatedBy: "\t") }.filter { $0.count == 3 }
            .sorted { $0[0] > $1[0] }.map { (title: $0[1], url: $0[2]) }
        return (tabs, windows)
    }

    /// The labels of every tab in a Chrome-style tab strip ("Title - Audio playing - Memory usage
    /// - 120 MB"), read with Accessibility, and how many windows were read. Only the window frame
    /// is walked, never a page's content. Nil without Accessibility.
    private static func tabLabels(of bundleID: String) -> (labels: [String], windows: Int)? {
        guard AXIsProcessTrusted(), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        guard let windows = value(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var labels: [String] = []
        var standard = 0
        for window in windows where value(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole {
            standard += 1
            var level = [window]
            for _ in 0..<10 where !level.isEmpty {
                var next: [AXUIElement] = []
                for element in level {
                    let role = value(element, kAXRoleAttribute) as? String ?? ""
                    if role == kAXTabGroupRole {
                        for tab in value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                            if let title = value(tab, kAXTitleAttribute) as? String { labels.append(title) }
                        }
                    } else if ![kAXScrollAreaRole, "AXWebArea", kAXToolbarRole].contains(role) {
                        next += value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                    }
                }
                level = next
            }
        }
        return (labels, standard)
    }

    static func youTubeID(_ url: String) -> String? {
        guard let components = URLComponents(string: url) else { return nil }
        if components.host?.contains("youtu.be") == true { return components.path.split(separator: "/").first.map(String.init) }
        let path = components.path.split(separator: "/")
        if path.first == "shorts", path.count > 1 { return String(path[1]) }
        return components.queryItems?.first { $0.name == "v" }?.value
    }

    private func loadThumbnail(_ id: String, for track: NowPlaying.Track) {
        guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = NSImage(data: data) else { return }
            self.queue.async {
                guard var current = self.last, current.album == track.album else { return }
                current.artwork = image
                self.last = current
                for (bundleID, entry) in self.lookups where entry.track?.album == track.album { self.lookups[bundleID]?.track?.artwork = image }
                DispatchQueue.main.async { NowPlaying.shared.setOther(current) }
            }
        }.resume()
    }
}

/// The keyboard's play/pause, next and previous keys, pressed for you: every player listens.
enum MediaKeys {
    enum Key: Int32 { case playPause = 16, next = 17, previous = 18 }  // NX_KEYTYPE_PLAY, NEXT, PREVIOUS

    static func press(_ key: Key) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key.rawValue << 16) | (down ? 0xA00 : 0xB00))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
