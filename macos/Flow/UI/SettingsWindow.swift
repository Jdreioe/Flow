import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(model: FlowModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false,
        )
        window.title = L10n.string("Flow Settings")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FlowSettingsView(model: model))
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
