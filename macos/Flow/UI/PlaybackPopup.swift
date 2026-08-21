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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.state == .languageCheck {
                LanguageCheckView(model: model)
            } else {
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
                            ForEach(FlowLanguageOption.allCases) { option in
                                Text(option.title).tag(option.tag)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 150)
                        .accessibilityLabel("Language override")
                    }
                    Button("Stop", action: model.stop)
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityLabel("Stop reading")
                }
                if model.textLanguageOverride != nil, model.overrideNeedsRoute,
                   let firstRouteID = currentPlan?.sentences.first?.route.id {
                    Picker("Read as", selection: Binding(
                        get: { firstRouteID },
                        set: { model.applyOverrideRoute($0) },
                    )) {
                        ForEach(model.settings.allLanguageRoutes) { route in
                            Text(route.displayName).tag(route.id)
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
                if model.state == .playing || model.state == .paused {
                    Button(model.state == .paused ? "Resume" : "Pause", action: model.pauseOrResume)
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(model.state == .paused ? "Resume reading" : "Pause reading")
                }
            }
        }
        .padding(20)
    }

    private var showsLanguageOverride: Bool {
        switch model.state {
        case .preparing, .playing, .paused, .languageCheck: true
        default: false
        }
    }

    private var currentPlan: LanguageFlow.Plan? {
        model.state == .languageCheck ? model.pendingLanguagePlan : model.languagePlan
    }

    private var title: String {
        switch model.state {
        case .preparing: "Preparing playback"
        case .playing: "Reading"
        case .paused: "Paused"
        case .languageCheck: "Language check"
        case .finished: "Finished"
        case .message: "Flow"
        case .hidden: "Flow"
        }
    }
}

private struct LanguageCheckView: View {
    @ObservedObject var model: FlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Language check")
                .font(.headline)
            Text("Choose how Flow should read these sentences before playback starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.pendingLanguagePlan?.sentences.filter(\.needsReview) ?? []) { sentence in
                VStack(alignment: .leading, spacing: 6) {
                    Text(sentence.text)
                        .lineLimit(2)
                    if sentence.detectedButUnconfigured, let tag = sentence.detectedLanguageTag {
                        Text("Flow detected \(Locale.current.localizedString(forIdentifier: tag) ?? tag), but it is not enabled.")
                            .font(.caption)
                        Button("Enable \(Locale.current.localizedString(forIdentifier: tag) ?? tag) in Settings") {
                            model.enableDetectedLanguage(for: sentence.id)
                        }
                    }
                    Picker("Read as", selection: Binding(
                        get: { sentence.route.id },
                        set: { model.chooseLanguageRoute($0, for: sentence.id) },
                    )) {
                        ForEach(model.settings.allLanguageRoutes) { route in
                            Text(route.displayName).tag(route.id)
                        }
                    }
                    if let tag = sentence.detectedLanguageTag {
                        Button("Use this choice for all \(Locale.current.localizedString(forIdentifier: tag) ?? tag) sentences") {
                            model.chooseLanguageRoute(sentence.route.id, forAllDetectedLanguage: tag)
                        }
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button("Cancel", action: model.stop)
                Spacer()
                Button("Start reading", action: model.confirmLanguageCheck)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
