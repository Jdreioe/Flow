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
                    ) {
                        model.settings.languageRoutes.removeAll { $0.id == route.id }
                    }
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
                Slider(value: $route.systemSpeechRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate) {
                    Text("Speech rate")
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
                Slider(value: $route.azureSpeechRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate) {
                    Text("Azure speech rate")
                }
                if matchingAzureVoices.isEmpty {
                    Text("No Azure voices support \(route.displayName) in this resource's region.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if showGoogleRoute {
                Picker("Google voice", selection: $route.googleVoiceName) {
                    Text("Google default voice").tag(String?.none)
                    ForEach(matchingGoogleVoices) { voice in
                        Text(voice.displayName).tag(String?.some(voice.name))
                    }
                }
                Slider(value: $route.googleSpeechRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate) {
                    Text("Google speech rate")
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
        }
        .padding(.vertical, 4)
    }
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
                    Slider(value: $model.settings.azureSpeechRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate) {
                        Text("Fallback speech rate")
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
                Picker("Google voice", selection: $model.settings.googleVoiceName) {
                    Text("Google default voice").tag(String?.none)
                    ForEach(defaultGoogleVoices) { voice in
                        Text(voice.displayName).tag(String?.some(voice.name))
                    }
                }
            }
            Slider(value: $model.settings.googleSpeechRate, in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate) {
                Text("Google speech rate")
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
