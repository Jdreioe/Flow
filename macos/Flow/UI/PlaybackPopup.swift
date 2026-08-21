import AppKit
import SwiftUI

final class PlaybackPopupController {
    private let panel: NSPanel

    init(model: FlowModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false,
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: PlaybackPopupView(model: model))
    }

    func show() {
        let cursor = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: cursor.x - 230, y: cursor.y - 240))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct PlaybackPopupView: View {
    @ObservedObject var model: FlowModel
    @State private var showsLanguages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if showsLanguageOverride {
                    Picker("Read in", selection: Binding(
                        get: { model.textLanguageOverride ?? "" },
                        set: { model.setTextLanguageOverride($0.isEmpty ? nil : $0) },
                    )) {
                        Text("Auto").tag("")
                        ForEach(SupportedLanguage.all) { language in
                            Text(language.title).tag(language.tag)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    .accessibilityLabel("Language override")
                }
                if showsLanguageButton {
                    Button(showsLanguages ? "Hide languages" : "Language…") {
                        showsLanguages.toggle()
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.detectedLanguages.isEmpty)
                }
                Button("Stop", action: model.stop)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Stop reading")
            }
            if model.textLanguageOverride != nil, model.overrideNeedsRoute {
                Picker("Read as", selection: Binding<UUID?>(
                    get: { nil },
                    set: { if let routeID = $0 { model.applyOverrideRoute(routeID) } },
                )) {
                    Text("Read as…").tag(nil as UUID?)
                    ForEach(model.settings.allLanguageRoutes) { route in
                        Text(route.displayName).tag(route.id as UUID?)
                    }
                }
                .accessibilityLabel("Read the overridden language as")
            }
            if case let .message(message) = model.state {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(model.selectedText)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .accessibilityLabel("Selected text being read")
            }
            if showsLanguages, !model.detectedLanguages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.detectedLanguages, id: \.self) { tag in
                        LanguageRouteRow(model: model, languageTag: tag)
                    }
                }
            }
            if showsAwaitingRouteNotice {
                Text("Pick a voice for \(languageName(model.textLanguageOverride ?? "")) to start reading.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.state == .playing || model.state == .paused {
                Button(model.state == .paused ? "Resume" : "Pause", action: model.pauseOrResume)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(model.state == .paused ? "Resume reading" : "Pause reading")
            }
        }
        .padding(20)
    }

    private var showsLanguageOverride: Bool {
        switch model.state {
        case .preparing, .playing, .paused, .awaitingRoute: true
        default: false
        }
    }

    private var showsLanguageButton: Bool {
        switch model.state {
        case .playing, .paused: true
        default: false
        }
    }

    private var showsAwaitingRouteNotice: Bool {
        model.state == .awaitingRoute && model.overrideNeedsRoute
    }

    private func languageName(_ tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    private var title: String {
        switch model.state {
        case .preparing: "Preparing playback"
        case .playing: "Reading"
        case .paused: "Paused"
        case .awaitingRoute: "Choose a voice"
        case .finished: "Finished"
        case .message: "Flow"
        case .hidden: "Flow"
        }
    }
}

private struct LanguageRouteRow: View {
    @ObservedObject var model: FlowModel
    let languageTag: String

    var body: some View {
        HStack {
            Text(Locale.current.localizedString(forIdentifier: languageTag) ?? languageTag)
                .font(.caption.bold())
            Spacer()
            Picker("Read as", selection: Binding<UUID?>(
                get: { currentRouteID },
                set: { if let routeID = $0 { model.setRoute(routeID, forAllDetectedLanguage: languageTag) } },
            )) {
                ForEach(model.settings.allLanguageRoutes) { route in
                    Text(route.displayName).tag(route.id as UUID?)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityLabel("Read all \(languageTag) sentences as")
        }
    }

    private var currentRouteID: UUID? {
        model.languagePlan?.sentences.first { $0.detectedLanguageTag == languageTag }?.route.id
    }
}
