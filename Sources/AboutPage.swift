import AppKit
import SwiftUI

/// About Starlight: the version and updates, and the open-source work Starlight is built on.
/// (What happens to your data is on the Privacy page.)
struct AboutPage: View {
    static let support = "support@starlightnotch.com"
    @State private var autoUpdates = Updater.shared.installsAutomatically

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    var body: some View {
        Page(title: "About") {
            HStack(spacing: 20) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Starlight").font(.system(size: 28, weight: .bold))
                    Text(version).font(.system(size: 13).monospacedDigit()).opacity(0.5)
                    Text("Made for Macs with Apple silicon").font(.system(size: 13)).opacity(0.5)
                }
            }
            .padding(.vertical, 6)

            Rows {
                if Updater.shared.isAvailable {
                    Row(title: "Install updates automatically",
                        value: autoUpdates ? "When Starlight is idle" : "Shows an Update button") {
                        Switch(isOn: $autoUpdates).onChange(of: autoUpdates) { _, on in Updater.shared.installsAutomatically = on }
                    }
                    Row(title: "Check now", value: Updater.shared.lastChecked.map { "Last checked " + $0.formatted(.relative(presentation: .named)) }) {
                        GlassButton(title: "Check for updates", prominent: true) { Updater.shared.checkNow() }
                    }
                } else {
                    Row(title: "Automatic updates", value: "On in released versions") { EmptyView() }
                }
                Row(title: "Welcome tour", info: ["The short tour from the first launch, in the notch."]) {
                    GlassButton(title: "Show") { Onboarding.shared.show() }
                }
                Row(title: "Questions, or something not working?", value: Self.support, last: true) {
                    GlassButton(title: "Email us") {
                        if let url = URL(string: "mailto:\(Self.support)?subject=Starlight%20\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}

