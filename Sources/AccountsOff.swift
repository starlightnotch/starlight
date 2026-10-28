#if !canImport(ClerkKit)
import AppKit

/// Starlight without accounts: the open-source build, which leaves out Clerk and Convex
/// (`scripts/make-opensource.sh` drops Account.swift and their packages). Dictation on your Mac,
/// and Live mode with your own key or Ollama (see Edition).
/// The same names as Account.swift, so nothing else needs to know which build it is.
@MainActor
final class StarlightAccount: NSObject, ObservableObject {
    static let shared = StarlightAccount()

    struct Plan: Equatable {
        var active: Bool
        var trial: Bool
        var ends: Date?
        var label: String { "Free" }
    }

    @Published private(set) var email: String?
    @Published private(set) var name: String?
    @Published private(set) var avatarURL: URL?
    @Published private(set) var plan: Plan?
    @Published private(set) var signingIn = false
    @Published private(set) var problem: String?
    var isSignedIn: Bool { false }

    static let websiteURL: URL? = nil
    static let serviceURL: URL? = nil
    static var manageURL: URL? { nil }
    nonisolated static var isAvailable: Bool { false }
    nonisolated static var hasService: Bool { false }
    nonisolated static var hasPro: Bool { false }

    func resume() {}
    func start() {}
    func signIn() async {}

    enum Provider: Hashable { case google, apple, email }
    enum SignInOutcome { case done, cancelled, failed }
    var oneTapProviders: [Provider] { [] }
    @discardableResult
    func signIn(with provider: Provider) async -> SignInOutcome { .failed }
    func signOut() {}
    /// Pro is in Starlight from the website, not in this build: the pricing page opens.
    func upgrade() { NSWorkspace.shared.open(Edition.proURL) }
    func accessToken() async -> String? { nil }
    func refreshPlan() async {}

    enum Need { case account, pro, ai }
    func allows(_ need: Need) -> Bool { true }
    nonisolated func check(_ need: Need, on model: NotchModel) -> Bool { true }

    func openAccountSettings() {}
    func openSubscription() {}
}
#endif
