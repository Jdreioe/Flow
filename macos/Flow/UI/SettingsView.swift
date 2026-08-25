import AVFoundation
import SwiftUI

struct FlowSettingsView: View {
    @ObservedObject var model: FlowModel
    @State private var languageToAdd = "da-DK"

    private var voices: [SystemSpeechEngine.Voice] { SystemSpeechEngine.voices }

    var body: some View {
        Form {
            Section("Access") {
                Picker("Global hotkey", selection: $model.settings.hotKey) {
                    ForEach(HotKeyPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Button("Allow Accessibility access") {
                    model.promptForAccessibilityPermission()
                }
                HStack {
                    Label(
                        model.accessibilityTrusted ? "Accessibility access allowed" : "Accessibility access not allowed",
                        systemImage: model.accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    )
                    .foregroundStyle(model.accessibilityTrusted ? .green : .orange)
                    Spacer()
                    Button("Refresh") { model.refreshAccessibilityPermission() }
                }
                Text("Flow reads only the selection that macOS accessibility exposes when you trigger it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Language Flow") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(model.settings.playbackSpeed) },
                            set: { model.setPlaybackSpeed(Float($0)) },
                        ),
                        in: 0.5...4,
                        step: 0.25,
                    ) {
                        Text("Playback speed")
                    } minimumValueLabel: {
                        Text("0.5×")
                    } maximumValueLabel: {
                        Text("4×")
                    }
                    Text("\(String(format: "%g×", model.settings.playbackSpeed))")
                        .monospacedDigit()
                        .frame(minWidth: 44, alignment: .trailing)
                }
                LanguageRouteEditor(
                    route: Binding(
                        get: { model.settings.defaultLanguageRoute },
                        set: { route in
                            model.settings.voiceIdentifier = route.systemVoiceIdentifier
                            model.settings.speechRate = route.systemSpeechRate
                            model.settings.azureVoiceName = route.azureVoiceName ?? model.settings.azureVoiceName
                            model.settings.azureSpeechRate = route.azureSpeechRate
                            model.settings.googleVoiceName = route.googleVoiceName
                            model.settings.googleSpeechRate = route.googleSpeechRate
                        },
                    ),
                    voices: voices,
                    azureVoices: model.azureVoices,
                    googleVoices: model.googleVoices,
                    showSystemRoute: model.settings.speechSource == .system,
                    showAzureRoute: model.settings.speechSource == .azure,
                    showGoogleRoute: model.settings.speechSource == .google,
                    isDefault: true,
                    remove: {},
                    onTestGoogleVoice: previewGoogleVoice,
                )
                ForEach($model.settings.languageRoutes) { $route in
                        CollapsibleLanguageRouteEditor(
                            route: $route,
                            voices: voices,
                            azureVoices: model.azureVoices,
                            googleVoices: model.googleVoices,
                            showSystemRoute: model.settings.speechSource == .system,
                            showAzureRoute: model.settings.speechSource == .azure,
                            showGoogleRoute: model.settings.speechSource == .google,
                            remove: {
                                model.settings.languageRoutes.removeAll { $0.id == route.id }
                            },
                            onTestGoogleVoice: previewGoogleVoice,
                    )
                }
                HStack {
                    Picker("Language", selection: $languageToAdd) {
                        ForEach(SupportedLanguage.all.filter { option in
                            option.tag != model.settings.defaultLanguageTag &&
                                !model.settings.languageRoutes.contains(where: { $0.languageTag == option.tag })
                        }) { language in
                            Text(language.title).tag(language.tag)
                        }
                    }
                    Button("Add language") {
                        addLanguage(languageToAdd)
                    }
                }
            }
            Section("Speech") {
                SpeechConfigurationView(model: model)
            }
            Section("Playback") {
                Button("Play test voice") { model.playTestVoice() }
                Picker("Same selection hotkey", selection: $model.settings.sameSelectionAction) {
                    ForEach(FlowSettings.SameSelectionAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                if model.settings.speechSource != .azure {
                    Toggle("Highlight spoken words", isOn: $model.settings.wordHighlightingEnabled)
                }
                Stepper(
                    "Popup dismisses after \(Int(model.settings.popupDismissSeconds)) seconds",
                    value: $model.settings.popupDismissSeconds,
                    in: 3...30,
                )
                Text("Selections longer than about ten minutes are not read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text("Flow keeps selected text only while the playback popup is visible. System language detection and voices are on-device. A cloud provider receives text only when that provider is selected.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func previewGoogleVoice(_ voice: GoogleVoiceCatalog.Voice) {
        model.previewGoogleVoice(named: voice.name, languageTag: voice.languageCodes.first ?? model.settings.defaultLanguageTag)
    }

    private func addLanguage(_ languageTag: String) {
        let azureVoice = model.azureVoices.first { $0.supports(languageTag: languageTag) }?.shortName
        let googleVoice = model.googleVoices.first { $0.supports(languageTag: languageTag) }?.name
        model.settings.languageRoutes.append(.init(
            languageTag: languageTag,
            systemVoiceIdentifier: SystemSpeechEngine.defaultVoice(for: languageTag)?.identifier,
            azureVoiceName: azureVoice ?? model.settings.azureVoiceName,
            azureSpeechRate: model.settings.azureSpeechRate,
            googleVoiceName: googleVoice,
            googleSpeechRate: model.settings.googleSpeechRate,
        ))
    }
}

private struct GoogleVoiceMenu: View {
    let voices: [GoogleVoiceCatalog.Voice]
    @Binding var selection: String?
    var onTest: ((GoogleVoiceCatalog.Voice) -> Void)?
    @State private var showsContents = false

    private var groups: [(family: GoogleVoiceCatalog.Voice.ModelFamily, voices: [GoogleVoiceCatalog.Voice])] {
        GoogleVoiceCatalog.groupedByModelFamily(voices)
    }

    private var selectionTitle: String {
        guard let name = selection else { return "Google default voice" }
        return voices.first { $0.name == name }?.displayName ?? name
    }

    var body: some View {
        Button {
            showsContents = true
        } label: {
            HStack(spacing: 6) {
                Text(selectionTitle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .popover(isPresented: $showsContents, arrowEdge: .bottom) {
            GoogleVoiceList(groups: groups, selection: $selection, onTest: onTest)
        }
    }
}

private struct GoogleVoiceList: View {
    let groups: [(family: GoogleVoiceCatalog.Voice.ModelFamily, voices: [GoogleVoiceCatalog.Voice])]
    @Binding var selection: String?
    var onTest: ((GoogleVoiceCatalog.Voice) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                row(title: "Google default voice", isSelected: selection == nil) {
                    selection = nil
                    dismiss()
                }
                ForEach(groups, id: \.family) { group in
                    Text(group.family.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
                    ForEach(group.voices) { voice in
                        HStack(spacing: 4) {
                            row(title: voice.displayName, isSelected: selection == voice.name) {
                                selection = voice.name
                                dismiss()
                            }
                            if let onTest {
                                Button {
                                    onTest(voice)
                                } label: {
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(.tint)
                                }
                                .buttonStyle(.borderless)
                                .help("Test voice")
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 300)
        .frame(maxHeight: 440)
    }

    private func row(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        VoiceRow(title: title, isSelected: isSelected, action: action)
    }
}

private struct VoiceRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "checkmark")
                .opacity(isSelected ? 1 : 0)
                .font(.caption)
                .frame(width: 16)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isHovered ? Color.accentColor.opacity(0.15) : .clear)
        .cornerRadius(4)
        .onHover { isHovered = $0 }
    }
}

private struct LanguageRouteEditor: View {
    @Binding var route: FlowSettings.LanguageRoute
    let voices: [SystemSpeechEngine.Voice]
    let azureVoices: [AzureVoiceCatalog.Voice]
    let googleVoices: [GoogleVoiceCatalog.Voice]
    let showSystemRoute: Bool
    let showAzureRoute: Bool
    let showGoogleRoute: Bool
    let isDefault: Bool
    let remove: () -> Void
    var onTestGoogleVoice: ((GoogleVoiceCatalog.Voice) -> Void)?
    var showsHeader = true

    private var matchingVoices: [SystemSpeechEngine.Voice] {
        let base = route.languageTag.split(separator: "-").first?.lowercased()
        return voices.filter { $0.language.split(separator: "-").first?.lowercased() == base }
    }

    private var matchingAzureVoices: [AzureVoiceCatalog.Voice] {
        azureVoices.filter { $0.supports(languageTag: route.languageTag) }
    }

    private var matchingGoogleVoices: [GoogleVoiceCatalog.Voice] {
        googleVoices.filter { $0.supports(languageTag: route.languageTag) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack {
                    Text(isDefault ? "Fallback voice" : route.displayName)
                        .font(.headline)
                    Spacer()
                    if !isDefault {
                        Button("Remove", role: .destructive, action: remove)
                    }
                }
            }
            if showSystemRoute {
                Picker("Voice", selection: $route.systemVoiceIdentifier) {
                    ForEach(matchingVoices) { voice in
                        Text(voice.name).tag(String?.some(voice.id))
                    }
                }
            }
            if showAzureRoute {
                Picker("Azure voice", selection: Binding(
                    get: { route.azureVoiceName ?? "" },
                    set: { route.azureVoiceName = $0 },
                )) {
                    ForEach(matchingAzureVoices) { voice in
                        Text(voice.shortName).tag(voice.shortName)
                    }
                }
                if matchingAzureVoices.isEmpty {
                    Text("No Azure voices support \(route.displayName) in this resource's region.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if showGoogleRoute {
                LabeledContent("Google voice") {
                    GoogleVoiceMenu(voices: matchingGoogleVoices, selection: $route.googleVoiceName, onTest: onTestGoogleVoice)
                }
                if matchingGoogleVoices.isEmpty {
                    Text("No Google voices were loaded for \(route.displayName). The default voice may still be available.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if showSystemRoute && matchingVoices.isEmpty {
                Text("No installed \(route.displayName) voice was found.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Link("Open macOS voice downloads", destination: URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!)
            }
            if !isDefault {
                Picker("Speed", selection: Binding(
                    get: { route.playbackSpeed },
                    set: { route.playbackSpeed = $0 },
                )) {
                    Text("Same as Language Flow").tag(Float?.none)
                    ForEach(Self.speedSteps, id: \.self) { speed in
                        Text("\(String(format: "%g×", speed))").tag(Float?.some(speed))
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    static let speedSteps: [Float] = (2...16).map { Float($0) / 4 }
}

private struct CollapsibleLanguageRouteEditor: View {
    @Binding var route: FlowSettings.LanguageRoute
    let voices: [SystemSpeechEngine.Voice]
    let azureVoices: [AzureVoiceCatalog.Voice]
    let googleVoices: [GoogleVoiceCatalog.Voice]
    let showSystemRoute: Bool
    let showAzureRoute: Bool
    let showGoogleRoute: Bool
    let remove: () -> Void
    var onTestGoogleVoice: ((GoogleVoiceCatalog.Voice) -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    expanded.toggle()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.displayName)
                        Text(voiceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Remove", role: .destructive, action: remove)
            }
            if expanded {
                LanguageRouteEditor(
                    route: $route,
                    voices: voices,
                    azureVoices: azureVoices,
                    googleVoices: googleVoices,
                    showSystemRoute: showSystemRoute,
                    showAzureRoute: showAzureRoute,
                    showGoogleRoute: showGoogleRoute,
                    isDefault: false,
                    remove: {},
                    onTestGoogleVoice: onTestGoogleVoice,
                    showsHeader: false,
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var voiceSummary: String {
        if showSystemRoute {
            return route.systemVoiceIdentifier ?? "System default voice"
        }
        if showAzureRoute {
            return route.azureVoiceName ?? "Fallback Azure voice"
        }
        return route.googleVoiceName ?? "Google default voice"
    }
}

private struct SpeechConfigurationView: View {
    @ObservedObject var model: FlowModel
    @State private var endpoint = ""
    @State private var subscriptionKey = ""
    @State private var googleAPIKey = ""
    @State private var azureError: String?
    @State private var googleError: String?

    private var defaultGoogleVoices: [GoogleVoiceCatalog.Voice] {
        model.googleVoices.filter { $0.supports(languageTag: model.settings.defaultLanguageTag) }
    }

    var body: some View {
        Picker("Reading source", selection: $model.settings.speechSource) {
            ForEach(FlowSettings.SpeechSource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        if model.settings.speechSource == .system {
            Text("System voices and language detection stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.settings.speechSource == .azure {
            if let configuredEndpoint = model.azureEndpoint {
                Text("Configured for \(configuredEndpoint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.azureVoices.isEmpty {
                    Text(model.azureVoiceLoadError ?? "Loading Azure voices…")
                        .font(.caption)
                        .foregroundStyle(model.azureVoiceLoadError == nil ? Color.secondary : Color.orange)
                } else {
                    Picker("Fallback Azure voice", selection: $model.settings.azureVoiceName) {
                        ForEach(model.azureVoices) { voice in
                            Text(voice.shortName).tag(voice.shortName)
                        }
                    }
                }
                Button("Refresh Azure voices") { model.refreshAzureVoices() }
                Link("View your Azure Speech resources", destination: AzurePortalURLs.speechResources)
                Button("Remove Azure configuration", role: .destructive) {
                    model.clearAzureConfiguration()
                }
            } else {
                Text("Azure sends selected text to your Speech resource to synthesize it. The subscription key stays in this Mac's Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Create a free Azure Speech resource", destination: AzurePortalURLs.createSpeechResource)
                Link("View your Azure Speech resources", destination: AzurePortalURLs.speechResources)
                TextField("Region or HTTPS endpoint", text: $endpoint)
                SecureField("Azure Speech subscription key", text: $subscriptionKey)
                if let azureError {
                    Text(azureError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Save Azure configuration") {
                    do {
                        try model.saveAzureConfiguration(endpoint: endpoint, subscriptionKey: subscriptionKey)
                        subscriptionKey = ""
                        azureError = nil
                    } catch {
                        azureError = error.localizedDescription
                    }
                }
                .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subscriptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } else if model.googleConfigured {
            Text("Google Cloud API key configured")
                .font(.caption)
                .foregroundStyle(.secondary)
            if defaultGoogleVoices.isEmpty {
                if let message = model.googleVoiceLoadError {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Loading Google voices…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Google voice") {
                    GoogleVoiceMenu(
                        voices: defaultGoogleVoices,
                        selection: $model.settings.googleVoiceName,
                        onTest: { voice in
                            model.previewGoogleVoice(named: voice.name, languageTag: voice.languageCodes.first ?? model.settings.defaultLanguageTag)
                        },
                    )
                }
            }
            Button("Refresh Google voices") { model.refreshGoogleVoices() }
            Button("Remove Google configuration", role: .destructive) {
                model.clearGoogleConfiguration()
            }
            Text("Google receives selected text only when Google Cloud is selected. The API key stays in this Mac's Keychain. Restrict it to the Cloud Text-to-Speech API.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Open Google Cloud API credentials", destination: GoogleCloudURLs.credentials)
            Link("Enable Cloud Text-to-Speech API", destination: GoogleCloudURLs.textToSpeechAPI)
        } else {
            Text("Enable Cloud Text-to-Speech in a Google Cloud project, create an API key restricted to that API, then add it here. Selected text is sent only for playback.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("Enable Cloud Text-to-Speech API", destination: GoogleCloudURLs.textToSpeechAPI)
            Link("Create or restrict an API key", destination: GoogleCloudURLs.credentials)
            SecureField("Google Cloud API key", text: $googleAPIKey)
            if let googleError {
                Text(googleError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Save Google configuration") {
                do {
                    try model.saveGoogleConfiguration(apiKey: googleAPIKey)
                    googleAPIKey = ""
                    googleError = nil
                } catch {
                    googleError = error.localizedDescription
                }
            }
            .disabled(googleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
