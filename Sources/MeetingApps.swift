import AppKit

/// Apps that count as meetings, and the helper processes that use the microphone on their behalf
/// (browsers record from a helper, Zoom from its conference process, FaceTime from avconferenced).
/// The list follows the meeting apps Granola recognises.
struct MeetingApp: Equatable, Hashable {
    let bundleID: String
    let name: String

    /// "Call detected" for phone-style apps, "Huddle detected" for Slack, like Granola.
    var detectedTitle: String {
        switch name {
        case "FaceTime", "WhatsApp": "Call detected"
        case "Slack": "Huddle detected"
        default: "Meeting detected"
        }
    }

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static let known: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.apple.FaceTime": "FaceTime",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.hnc.Discord": "Discord",
        "app.tuple.app": "Tuple",
        "com.gather.Gather": "Gather",
        "com.gather.GatherV2": "Gather",
        "com.electron.dialpad": "Dialpad",
        "com.electron.uberconference": "Dialpad Meetings",
        "io.aircall.phone": "Aircall",
        "com.electron.8x8---virtual-office": "8x8 Work",
        "com.tencent.tencentmeeting": "VooV Meeting",
        "com.clickup.desktop-app": "ClickUp",
        "com.larksuite.larkApp": "Lark",
        "com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan": "Google Meet",
        // Browsers, for meetings on the web.
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.beta": "Chrome Beta",
        "org.mozilla.firefox": "Firefox",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "com.operasoftware.Opera": "Opera",
        "app.zen-browser.zen": "Zen Browser",
        "net.imput.helium": "Helium",
        "ai.perplexity.comet": "Comet",
        "com.openai.atlas": "ChatGPT Atlas",
    ]

    /// Helper process → the app it belongs to.
    static let helpers: [String: String] = [
        "com.google.Chrome.helper": "com.google.Chrome",
        "com.google.Chrome.beta.helper": "com.google.Chrome.beta",
        "us.zoom.ZoomHybridConf": "us.zoom.xos",
        "us.zoom.ZoomPhone": "us.zoom.xos",
        "com.tinyspeck.slackmacgap.helper": "com.tinyspeck.slackmacgap",
        "company.thebrowser.browser.helper": "company.thebrowser.Browser",
        "company.thebrowser.dia.helper": "company.thebrowser.dia",
        "Cisco-Systems.Spark": "com.cisco.webexmeetingsapp",
        "com.microsoft.teams2.modulehost": "com.microsoft.teams2",
        "com.apple.WebKit.GPU": "com.apple.Safari",
        "io.aircall.phone.helper": "io.aircall.phone",
        "io.aircall.workspace.helper": "io.aircall.phone",
        "com.apple.avconferenced": "com.apple.FaceTime",
        "com.microsoft.edgemac.helper": "com.microsoft.edgemac",
        "com.brave.Browser.helper": "com.brave.Browser",
        "net.imput.helium.helper": "net.imput.helium",
        "ai.perplexity.comet.helper": "ai.perplexity.comet",
        "com.hnc.Discord.helper.Renderer": "com.hnc.Discord",
        "com.vivaldi.Vivaldi.helper": "com.vivaldi.Vivaldi",
        "com.openai.atlas.web.helper": "com.openai.atlas",
        "com.electron.dialpad.helper": "com.electron.dialpad",
        "com.electron.uberconference.helper": "com.electron.uberconference",
        "com.gather.Gather.helper": "com.gather.Gather",
        "com.gather.GatherV2.helper": "com.gather.GatherV2",
        "com.operasoftware.Opera.helper": "com.operasoftware.Opera",
        "com.clickup.desktop-app.helper": "com.clickup.desktop-app",
        "com.larksuite.larkApp.helper": "com.larksuite.larkApp",
    ]

    /// The meeting app behind a process's bundle ID, or nil if it isn't one.
    static func from(processBundleID id: String) -> MeetingApp? {
        let app = helpers[id] ?? id
        guard let name = known[app] else { return nil }
        return MeetingApp(bundleID: app, name: name)
    }
}
