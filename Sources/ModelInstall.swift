import Combine
import SwiftUI

/// The models installing outside the welcome tour, which shows them itself (NotchTour.install):
/// - the voice model, in a bubble under the notch while it downloads (switching to 25
///   languages, or the tour left early), with its size and time left, then a check;
/// - a short note beside the camera when the polish model (Clean and Polished) is in.
/// Loading a model that's already on the Mac says nothing.
@MainActor
final class ModelInstall: BubbleOwner {
    static let shared = ModelInstall()

    private weak var model: NotchModel?
    private let host = BubbleHost.shared
    private var watchers: Set<AnyCancellable> = []
    /// The voice model is coming down (not just loading from disk).
    private var installing = false
    private var polishWasDownloading = false

    func start(_ model: NotchModel) {
        self.model = model
        model.$engineStatus.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.voice($0) }.store(in: &watchers)
        model.$cleanupState.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] in self?.polish($0) }.store(in: &watchers)
    }

    private func voice(_ status: EngineStatus) {
        switch status {
        case .loading(let label, let fraction):
            if !installing {
                // Starting: only worth a word when the files have to come down.
                guard !ParakeetModel.isDownloaded || label == ParakeetModel.downloadingLabel else { return }
                installing = true
            }
            show(NotchBubble(label: "Loading voice model", action: .progress(fraction.map { ($0 * 100).rounded() / 100 })))
        case .ready:
            guard installing else { return }
            installing = false
            show(NotchBubble(label: "Voice model loaded", action: .check))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
                guard let self, self.host.bubble(of: self)?.action == .check else { return }
                self.host.hide(self)
            }
        case .failed:
            guard installing || !ParakeetModel.isDownloaded else { return }
            installing = false
            show(NotchBubble(label: "Voice didn’t download", sub: "check your internet", action: .button("Try again"), quiet: "Later"))
        case .idle:
            break
        }
    }

    private func polish(_ state: CleanupModel.State) {
        switch state {
        case .downloading:
            polishWasDownloading = true
        case .ready where polishWasDownloading:
            polishWasDownloading = false
            model?.flash(NotchModel.Toast(icon: .check, title: "Installed", detail: "Polish model"), for: 2.6)
        default:
            break
        }
    }

    /// Shown only when nothing else has the bubble: the tour (which shows the voice itself) or a
    /// permission being asked for come first.
    private func show(_ bubble: NotchBubble) {
        guard !NotchTour.shared.isRunning, host.bubble == nil || host.bubble(of: self) != nil else { return }
        host.show(bubble, key: "model-install", owner: self)
    }

    func tap(quiet: Bool, provider: StarlightAccount.Provider?) {
        host.hide(self)
        guard !quiet else { return }
        ParakeetModel.shared.prepare()
    }

    func hold(_ down: Bool) {}
}
