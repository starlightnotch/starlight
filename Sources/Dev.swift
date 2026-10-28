import Foundation

/// Development builds only: the STARLIGHT_* settings (test audio, tour previews, dry runs…) and
/// the command-line tools (renders, tests). `./build.sh` turns them on with a key in Info.plist;
/// releases (scripts/release.sh) leave it out, and the signature covers Info.plist, so nothing on
/// someone's Mac can switch a test mode on.
enum Dev {
    static let isEnabled = Bundle.main.object(forInfoDictionaryKey: "StarlightDevTools") as? Bool == true

    /// A STARLIGHT_* setting from the environment, in development builds; nil in releases.
    static func env(_ name: String) -> String? {
        isEnabled ? ProcessInfo.processInfo.environment[name] : nil
    }
}
