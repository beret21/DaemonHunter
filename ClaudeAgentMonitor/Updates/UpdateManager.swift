import Foundation
import Sparkle

@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var updaterController: SPUStandardUpdaterController?

    static let shared = UpdateManager()

    private override init() {
        super.init()
        // Sparkle initializes with the SUFeedURL from Info.plist
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }
}
