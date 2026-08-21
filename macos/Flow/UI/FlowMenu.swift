import AppKit
import SwiftUI

struct FlowMenu: View {
    @ObservedObject var model: FlowModel

    var body: some View {
        Button("Read selected text") { model.readSelectionFromMenu() }
        Text(model.settings.hotKey.title)
            .foregroundStyle(.secondary)
        if let error = model.hotKeyError {
            Text(error)
                .foregroundStyle(.red)
        }
        Divider()
        Button("Settings…") { model.openSettings() }
        Button("Check for Updates…") { model.checkForUpdates() }
        Button("Quit Flow") { NSApplication.shared.terminate(nil) }
    }
}
