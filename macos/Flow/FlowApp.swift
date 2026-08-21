import AppKit
import ApplicationServices
import AVFoundation
import Carbon
import SwiftUI

@main
struct FlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Flow", systemImage: "text.bubble") {
            FlowMenu(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = FlowModel()
    private let updater = UpdateManager()
    private var hotKey: GlobalHotKey?
    private var popup: PlaybackPopupController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popup = PlaybackPopupController(model: model)
        settingsWindow = SettingsWindowController(model: model)
        model.onPopupVisibilityChanged = { [weak self] isVisible in
            guard let self else { return }
            if isVisible {
                self.popup?.show()
            } else {
                self.popup?.hide()
            }
        }
        model.onHotKeyChanged = { [weak self] preset in
            self?.installHotKey(preset)
        }
        model.onSettingsRequested = { [weak self] in
            self?.settingsWindow?.show()
        }
        model.onUpdatesRequested = { [weak self] in
            self?.updater.checkForUpdates()
        }
        installHotKey(model.settings.hotKey)
    }

    private func installHotKey(_ preset: HotKeyPreset) {
        hotKey?.invalidate()
        hotKey = GlobalHotKey(preset: preset) { [weak model] in
            Task { @MainActor in
                model?.readSelectionFromHotKey()
            }
        }
        do {
            try hotKey?.register()
            model.hotKeyError = nil
        } catch {
            model.hotKeyError = "\(preset.title) is already in use. Choose another Flow shortcut."
        }
    }

}

@MainActor
final class FlowModel: ObservableObject {
    enum PlaybackState: Equatable {
        case hidden
        case preparing
        case playing
        case paused
        case languageCheck
        case finished
        case message(String)
    }

    @Published private(set) var state: PlaybackState = .hidden
    @Published private(set) var selectedText = ""
    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var azureEndpoint: String?
    @Published private(set) var azureVoices: [AzureVoiceCatalog.Voice] = []
    @Published private(set) var azureVoiceLoadError: String?
    @Published private(set) var googleConfigured: Bool
    @Published private(set) var googleVoices: [GoogleVoiceCatalog.Voice] = []
    @Published private(set) var googleVoiceLoadError: String?
    @Published private(set) var languagePlan: LanguageFlow.Plan?
    @Published private(set) var pendingLanguagePlan: LanguageFlow.Plan?
    @Published private(set) var textLanguageOverride: String?
    @Published var settings: FlowSettings {
        didSet {
            saveSettings()
            if oldValue.hotKey != settings.hotKey {
                onHotKeyChanged?(settings.hotKey)
            }
        }
    }
    @Published var hotKeyError: String?

    var onPopupVisibilityChanged: ((Bool) -> Void)?
    var onHotKeyChanged: ((HotKeyPreset) -> Void)?
    var onSettingsRequested: (() -> Void)?
    var onUpdatesRequested: (() -> Void)?

    private let systemSpeech = SystemSpeechEngine()
    private let azureSpeech = AzureSpeechEngine()
    private let googleSpeech = GoogleSpeechEngine()
    private var activeSpeech: FlowSpeechEngine?
    private var dismissTask: Task<Void, Never>?

    init() {
        var loadedSettings = FlowSettings.load()
        loadedSettings.ensureExplicitSystemVoices()
        settings = loadedSettings
        accessibilityTrusted = AccessibilitySelectionReader.isTrusted
        azureEndpoint = AzureCredentialsStore.load()?.endpoint
        googleConfigured = GoogleCredentialsStore.load() != nil
        let finished: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.finishedReading()
            }
        }
        systemSpeech.onFinished = finished
        azureSpeech.onFinished = finished
        azureSpeech.onFailure = { [weak self] message in
            Task { @MainActor in self?.showMessage(message) }
        }
        googleSpeech.onFinished = finished
        googleSpeech.onFailure = { [weak self] message in
            Task { @MainActor in self?.showMessage(message) }
        }
        saveSettings()
        refreshAzureVoices()
        refreshGoogleVoices()
    }

    func readSelectionFromMenu() {
        readSelection()
    }

    func readSelectionFromHotKey() {
        readSelection()
    }

    func promptForAccessibilityPermission() {
        AccessibilitySelectionReader.promptForPermission()
        refreshAccessibilityPermission()
    }

    func refreshAccessibilityPermission() {
        accessibilityTrusted = AccessibilitySelectionReader.isTrusted
    }

    func openSettings() {
        onSettingsRequested?()
    }

    func checkForUpdates() {
        onUpdatesRequested?()
    }

    func playTestVoice() {
        dismissTask?.cancel()
        selectedText = "Flow is ready to read selected text."
        let plan = LanguageFlow.singleSentence(selectedText, settings: settings)
        guard let speech = selectedSpeechEngine() else { return }
        activeSpeech?.stop()
        activeSpeech = speech
        languagePlan = plan
        state = .preparing
        onPopupVisibilityChanged?(true)
        speech.read(plan, settings: settings)
        state = .playing
    }

    func pauseOrResume() {
        switch state {
        case .playing:
            activeSpeech?.pause()
            state = .paused
        case .paused:
            activeSpeech?.resume()
            state = .playing
        default:
            break
        }
    }

    func stop() {
        dismissTask?.cancel()
        activeSpeech?.stop()
        selectedText = ""
        languagePlan = nil
        pendingLanguagePlan = nil
        state = .hidden
        onPopupVisibilityChanged?(false)
    }

    private func readSelection() {
        dismissTask?.cancel()
        switch AccessibilitySelectionReader.readFocusedSelection() {
        case .failure(.permissionRequired):
            showMessage("Flow needs Accessibility permission to read selected text.")
        case .failure(.noSelectedText):
            showMessage("Select some text, then press \(settings.hotKey.title).")
        case .failure(.unavailable):
            showMessage("This application does not expose its selected text to macOS.")
        case .success(let text):
            let normalized = Self.normalized(text)
            if normalized.isEmpty {
                showMessage("Select some text, then press \(settings.hotKey.title).")
                return
            }
            if normalized.count > FlowSettings.maximumSelectionCharacters {
                showMessage("This selection is longer than Flow's 10-minute reading limit.")
                return
            }
            if normalized == Self.normalized(selectedText), settings.sameSelectionAction == .pauseResume,
               state == .playing || state == .paused {
                pauseOrResume()
                return
            }
            // The override lasts for the current selection only; a fresh
            // capture always starts from Auto again.
            textLanguageOverride = nil
            let plan = LanguageFlow.plan(text: text, settings: settings)
            if plan.needsLanguageCheck {
                selectedText = text
                pendingLanguagePlan = plan
                state = .languageCheck
                onPopupVisibilityChanged?(true)
                return
            }
            startReading(text: text, plan: plan)
        }
    }

    func chooseLanguageRoute(_ routeID: UUID, for sentenceID: UUID) {
        guard var plan = pendingLanguagePlan,
              let route = settings.allLanguageRoutes.first(where: { $0.id == routeID }),
              let index = plan.sentences.firstIndex(where: { $0.id == sentenceID }) else { return }
        plan.sentences[index].route = route
        plan.sentences[index].needsReview = false
        pendingLanguagePlan = plan
    }

    func chooseLanguageRoute(_ routeID: UUID, forAllDetectedLanguage languageTag: String) {
        guard var plan = pendingLanguagePlan,
              let route = settings.allLanguageRoutes.first(where: { $0.id == routeID }) else { return }
        for index in plan.sentences.indices where plan.sentences[index].detectedLanguageTag == languageTag {
            plan.sentences[index].route = route
            plan.sentences[index].needsReview = false
        }
        pendingLanguagePlan = plan
    }

    func enableDetectedLanguage(for sentenceID: UUID) {
        guard let sentence = pendingLanguagePlan?.sentences.first(where: { $0.id == sentenceID }),
              let languageTag = sentence.detectedLanguageTag,
              !settings.languageRoutes.contains(where: { $0.languageTag == languageTag }) else { return }
        settings.languageRoutes.append(.init(
            languageTag: languageTag,
            systemVoiceIdentifier: SystemSpeechEngine.defaultVoice(for: languageTag)?.identifier,
            azureVoiceName: settings.azureVoiceName,
            azureSpeechRate: settings.azureSpeechRate,
            googleVoiceName: nil,
            googleSpeechRate: settings.googleSpeechRate,
        ))
        openSettings()
    }

    func confirmLanguageCheck() {
        guard let plan = pendingLanguagePlan else { return }
        pendingLanguagePlan = nil
        startReading(text: selectedText, plan: plan)
    }

    func setTextLanguageOverride(_ tag: String?) {
        guard tag != textLanguageOverride else { return }
        textLanguageOverride = tag
        guard state == .preparing || state == .playing || state == .paused,
              !selectedText.isEmpty else { return }
        let plan = LanguageFlow.plan(text: selectedText, settings: settings, overrideTag: tag)
        if plan.needsLanguageCheck {
            // Restoring Auto can surface uncertain or unconfigured sentences,
            // which must go through Language check like any fresh capture.
            activeSpeech?.stop()
            pendingLanguagePlan = plan
            state = .languageCheck
            return
        }
        startReading(text: selectedText, plan: plan)
    }

    private func startReading(text: String, plan: LanguageFlow.Plan) {
        guard let speech = selectedSpeechEngine() else { return }
        activeSpeech?.stop()
        activeSpeech = speech
        selectedText = text
        languagePlan = plan
        state = .preparing
        onPopupVisibilityChanged?(true)
        speech.read(plan, settings: settings)
        state = .playing
    }

    private func showMessage(_ message: String) {
        selectedText = ""
        languagePlan = nil
        pendingLanguagePlan = nil
        state = .message(message)
        onPopupVisibilityChanged?(true)
        dismissAfterDelay()
    }

    private func finishedReading() {
        guard state == .playing || state == .paused else { return }
        state = .finished
        dismissAfterDelay()
    }

    private func dismissAfterDelay() {
        let delay = settings.popupDismissSeconds
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.state = .hidden
            self?.selectedText = ""
            self?.onPopupVisibilityChanged?(false)
        }
    }

    private func saveSettings() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: FlowSettings.storageKey)
    }

    func saveAzureConfiguration(endpoint: String, subscriptionKey: String) throws {
        let credentials = try AzureSpeechCredentials(endpoint: endpoint, subscriptionKey: subscriptionKey)
        try AzureCredentialsStore.save(credentials)
        azureEndpoint = credentials.endpoint
        refreshAzureVoices()
    }

    func clearAzureConfiguration() {
        AzureCredentialsStore.clear()
        azureEndpoint = nil
        azureVoices = []
        azureVoiceLoadError = nil
        if settings.speechSource == .azure { settings.speechSource = .system }
    }

    func refreshAzureVoices() {
        guard let credentials = AzureCredentialsStore.load() else { return }
        azureVoiceLoadError = nil
        Task { [weak self] in
            do {
                let voices = try await AzureVoiceCatalog.list(credentials: credentials)
                guard !Task.isCancelled else { return }
                self?.azureVoices = voices
            } catch {
                guard !Task.isCancelled else { return }
                self?.azureVoiceLoadError = "Flow could not load Azure voices. Check the endpoint and key."
            }
        }
    }

    func saveGoogleConfiguration(apiKey: String) throws {
        let key = try GoogleAPIKey.validate(apiKey)
        try GoogleCredentialsStore.save(key)
        googleConfigured = true
        refreshGoogleVoices()
    }

    func clearGoogleConfiguration() {
        GoogleCredentialsStore.clear()
        googleConfigured = false
        googleVoices = []
        googleVoiceLoadError = nil
        if settings.speechSource == .google { settings.speechSource = .system }
    }

    func refreshGoogleVoices() {
        guard let apiKey = GoogleCredentialsStore.load() else { return }
        googleVoiceLoadError = nil
        Task { [weak self] in
            do {
                let voices = try await GoogleVoiceCatalog.list(apiKey: apiKey)
                guard !Task.isCancelled else { return }
                self?.googleVoices = voices
            } catch {
                guard !Task.isCancelled else { return }
                self?.googleVoiceLoadError = "Flow could not load Google voices. Check the API key and confirm that Cloud Text-to-Speech is enabled."
            }
        }
    }

    private func selectedSpeechEngine() -> FlowSpeechEngine? {
        switch settings.speechSource {
        case .system:
            return systemSpeech
        case .azure:
            guard azureEndpoint != nil else {
                showMessage("Set up Azure Speech before choosing Azure voice.")
                return nil
            }
            return azureSpeech
        case .google:
            guard googleConfigured else {
                showMessage("Set up Google Cloud Text-to-Speech before choosing Google voice.")
                return nil
            }
            return googleSpeech
        }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
