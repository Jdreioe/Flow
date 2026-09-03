import Sparkle

@MainActor
final class UpdateManager {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil,
    )

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func checkForUpdatesAtLaunch() {
        guard controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }
}
