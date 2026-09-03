import AppKit
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
    private var applicationObservers: [NSObjectProtocol] = []
    private let accessibilityPreparer = AccessibilityPreparationCoordinator()

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
        model.onWhatsNewRequested = { [weak self] in
            self?.showWhatsNew()
        }
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        applicationObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [accessibilityPreparer] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            let pid = pid_t(application.processIdentifier)
            Task { await accessibilityPreparer.prepare(pid: pid) }
        })
        applicationObservers.append(workspaceNotifications.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [accessibilityPreparer] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
            let pid = pid_t(application.processIdentifier)
            Task { await accessibilityPreparer.prepare(pid: pid) }
        })
        if let application = NSWorkspace.shared.frontmostApplication {
            let pid = pid_t(application.processIdentifier)
            Task { await accessibilityPreparer.prepare(pid: pid) }
        }
        installHotKey(model.settings.hotKey)
        ChangelogWindowController.presentAfterUpdate()
        updater.checkForUpdatesAtLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in applicationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func showWhatsNew() {
        ChangelogWindowController.showAll()
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
            model.hotKeyError = L10n.format(
                "%@ is already in use. Choose another Flow shortcut.",
                preset.title
            )
        }
    }
}

private actor AccessibilityPreparationCoordinator {
    private static let attempts = 20
    private static let retryDelay = Duration.milliseconds(100)
    private var pendingPIDs: Set<pid_t> = []

    func prepare(pid: pid_t) async {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard pendingPIDs.insert(pid).inserted else { return }
        defer { pendingPIDs.remove(pid) }

        for attempt in 0..<Self.attempts {
            guard let application = NSRunningApplication(processIdentifier: pid),
                  !application.isTerminated else { return }
            if AccessibilitySelectionReader.prepare(pid: pid) {
                return
            }
            guard attempt + 1 < Self.attempts else { return }
            try? await Task.sleep(for: Self.retryDelay)
        }
    }
}

// Word-level progress changes many times per second during playback. Keeping
// it out of FlowModel stops the settings window from re-rendering on every
// highlight tick while only the playback popup observes this object.
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var wordRange: Range<Int>?
    @Published var readingOffset: Double?
}

@MainActor
final class FlowModel: ObservableObject {
    enum PlaybackState: Equatable {
        case hidden
        case preparing
        case playing
        case paused
        case awaitingRoute
        case finished
        case message(String)
    }

    @Published private(set) var state: PlaybackState = .hidden
    @Published private(set) var selectedText = ""
    let progress = PlaybackProgress()
    var playbackSpeed: Float { settings.playbackSpeed }
    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var azureEndpoint: String?
    @Published private(set) var azureVoices: [AzureVoiceCatalog.Voice] = []
    @Published private(set) var azureVoiceLoadError: String?
    @Published private(set) var googleConfigured: Bool
    @Published private(set) var googleVoices: [GoogleVoiceCatalog.Voice] = []
    @Published private(set) var googleVoiceLoadError: String?
    @Published private(set) var languagePlan: LanguageFlow.Plan?
    @Published private(set) var textLanguageOverride: String?
    @Published private(set) var overrideNeedsRoute = false
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
    var onWhatsNewRequested: (() -> Void)?

    private let systemSpeech = SystemSpeechEngine()
    private let azureSpeech = AzureSpeechEngine()
    private let googleSpeech = GoogleSpeechEngine()
    private var activeSpeech: FlowSpeechEngine?
    private var previewPlayer: AVAudioPlayer?
    private var previewTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    init() {
        var loadedSettings = FlowSettings.load()
        loadedSettings.ensureExplicitSystemVoices()
        settings = loadedSettings
        SystemSpeechEngine.reloadVoices()
        accessibilityTrusted = AccessibilitySelectionReader.isTrusted
        azureEndpoint = AzureCredentialsStore.load()?.endpoint
        googleConfigured = GoogleCredentialsStore.load() != nil
        let finished: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.finishedReading()
            }
        }
        let playbackStarted: () -> Void = { [weak self] in
            Task { @MainActor in
                guard self?.state == .preparing else { return }
                self?.state = .playing
            }
        }
        systemSpeech.onPlaybackStarted = playbackStarted
        systemSpeech.onFinished = finished
        systemSpeech.onWordRange = { [weak self] range in
            Task { @MainActor in self?.progress.wordRange = range }
        }
        azureSpeech.onFinished = finished
        azureSpeech.onPlaybackStarted = playbackStarted
        azureSpeech.onFailure = { [weak self] message in
            Task { @MainActor in self?.showMessage(message) }
        }
        googleSpeech.onFinished = finished
        googleSpeech.onPlaybackStarted = playbackStarted
        googleSpeech.onFailure = { [weak self] message in
            Task { @MainActor in self?.showMessage(message) }
        }
        googleSpeech.onWordRange = { [weak self] range in
            Task { @MainActor in self?.progress.wordRange = range }
        }
        googleSpeech.onReadingOffset = { [weak self] offset in
            Task { @MainActor in self?.progress.readingOffset = offset }
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

    func openWhatsNew() {
        onWhatsNewRequested?()
    }

    func playTestVoice() {
        dismissTask?.cancel()
        selectedText = "Flow is ready to read selected text."
        let plan = LanguageFlow.singleSentence(selectedText, settings: settings)
        guard let speech = selectedSpeechEngine() else { return }
        activeSpeech?.stop()
        progress.wordRange = nil
        progress.readingOffset = nil
        activeSpeech = speech
        languagePlan = plan
        state = .preparing
        onPopupVisibilityChanged?(true)
        speech.read(plan, settings: settings)
    }

    func previewGoogleVoice(named voiceName: String?, languageTag: String) {
        guard let apiKey = GoogleCredentialsStore.load() else { return }
        if activeSpeech === googleSpeech { stop() }
        previewTask?.cancel()
        previewPlayer?.stop()
        var route = settings.fallbackRoute
        route.languageTag = languageTag
        route.googleVoiceName = voiceName
        route.playbackSpeed = nil
        let plan = LanguageFlow.Plan(sentences: [LanguageFlow.Sentence(
            text: "Hello, this is what Flow sounds like with this voice.",
            detectedLanguageTag: languageTag,
            route: route,
            detectedButUnconfigured: false,
        )])
        previewTask = Task {
            do {
                let audio = try await GoogleSpeechEngine.synthesize(plan: plan, apiKey: apiKey, includeWordTimings: false)
                try Task.checkCancellation()
                guard let segment = audio.first else { return }
                let player = try AVAudioPlayer(data: segment.data)
                player.enableRate = true
                player.rate = min(max(settings.playbackSpeed, 0.5), 4)
                previewPlayer = player
                player.play()
            } catch is CancellationError {
            } catch {}
        }
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

    func setPlaybackSpeed(_ multiplier: Float) {
        let clamped = min(max(multiplier, 0.5), 4)
        settings.playbackSpeed = clamped
        activeSpeech?.setSpeed(clamped)
    }

    func stop() {
        dismissTask?.cancel()
        activeSpeech?.stop()
        previewTask?.cancel()
        previewPlayer?.stop()
        progress.wordRange = nil
        progress.readingOffset = nil
        selectedText = ""
        languagePlan = nil
        state = .hidden
        onPopupVisibilityChanged?(false)
    }

    private func readSelection() {
        dismissTask?.cancel()
        // The override lasts until the next capture only.
        let hadLanguageOverride = textLanguageOverride != nil
        textLanguageOverride = nil
        overrideNeedsRoute = false
        switch AccessibilitySelectionReader.readFocusedSelection() {
        case .failure(.permissionRequired):
            showMessage(L10n.string("Flow needs Accessibility permission to read selected text."))
        case .failure(.noSelectedText):
            showMessage(L10n.format("Select some text, then press %@.", settings.hotKey.title))
        case .failure(.selectionNeedsRefresh):
            showMessage(L10n.format(
                "Flow couldn't read this selection yet. Select the text again, then press %@.",
                settings.hotKey.title
            ))
        case .failure(.unavailable):
            showMessage(L10n.format(
                "Flow couldn't read the selected text. Select it again, then press %@. If that still doesn't work, this app may not provide its selections to macOS.",
                settings.hotKey.title
            ))
        case .success(let text):
            let normalized = Self.normalized(text)
            if normalized.isEmpty {
                showMessage(L10n.format("Select some text, then press %@.", settings.hotKey.title))
                return
            }
            if normalized.count > FlowSettings.maximumSelectionCharacters {
                showMessage(L10n.string("This selection is longer than Flow's 10-minute reading limit."))
                return
            }
            if normalized == Self.normalized(selectedText), settings.sameSelectionAction == .pauseResume,
               state == .playing || state == .paused, !hadLanguageOverride {
                pauseOrResume()
                return
            }
            // Resetting an override requires a new Auto plan, so replay this
            // selection instead of resuming the old overridden plan.
            let plan = LanguageFlow.plan(text: text, settings: settings)
            startAutoPlan(text: text, plan: plan)
        }
    }

    var detectedLanguages: [String] {
        var tags: [String] = []
        for sentence in languagePlan?.sentences ?? [] {
            if let tag = sentence.detectedLanguageTag, !tags.contains(tag) {
                tags.append(tag)
            }
        }
        return tags
    }

    var missingRouteLanguage: String? {
        languagePlan?.sentences.first(where: \.detectedButUnconfigured)?.detectedLanguageTag
    }

    func addLanguageRoute(_ languageTag: String) {
        guard settings.languageRoute(for: languageTag) == nil else { return }
        settings.languageRoutes.append(suggestedRoute(for: languageTag))
    }

    func fixMissingRoute(_ languageTag: String) {
        addLanguageRoute(languageTag)
        guard let route = settings.languageRoute(for: languageTag), var plan = languagePlan else { return }
        for index in plan.sentences.indices where plan.sentences[index].detectedLanguageTag == languageTag {
            plan.sentences[index].route = route
            plan.sentences[index].detectedButUnconfigured = false
        }
        startReading(text: selectedText, plan: plan)
    }

    private func suggestedRoute(for languageTag: String) -> FlowSettings.LanguageRoute {
        FlowSettings.LanguageRoute(
            languageTag: languageTag,
            systemVoiceIdentifier: SystemSpeechEngine.defaultVoice(for: languageTag)?.identifier,
            azureVoiceName: azureVoices.first { $0.supports(languageTag: languageTag) }?.shortName
                ?? settings.azureVoiceName,
            azureSpeechRate: settings.azureSpeechRate,
            googleVoiceName: googleVoices.first { $0.supports(languageTag: languageTag) }?.name,
            googleSpeechRate: settings.googleSpeechRate
        )
    }

    func setRoute(_ routeID: UUID, forAllDetectedLanguage languageTag: String) {
        guard let route = settings.allLanguageRoutes.first(where: { $0.id == routeID }),
              var plan = languagePlan else { return }
        for index in plan.sentences.indices where plan.sentences[index].detectedLanguageTag == languageTag {
            plan.sentences[index].route = route
        }
        startReading(text: selectedText, plan: plan)
    }

    func setTextLanguageOverride(_ tag: String?) {
        guard tag != textLanguageOverride else { return }
        textLanguageOverride = tag
        overrideNeedsRoute = tag.map { settings.languageRoute(for: $0) == nil } ?? false
        switch state {
        case .preparing, .playing, .paused, .awaitingRoute:
            guard !selectedText.isEmpty else { return }
            if let tag {
                let plan = LanguageFlow.plan(text: selectedText, settings: settings, overrideTag: tag)
                if overrideNeedsRoute {
                    // Never speak with a guessed voice: hold playback until
                    // a route is chosen for this language.
                    activeSpeech?.stop()
                    languagePlan = plan
                    state = .awaitingRoute
                    onPopupVisibilityChanged?(true)
                } else {
                    startReading(text: selectedText, plan: plan)
                }
            } else {
                startAutoPlan(
                    text: selectedText,
                    plan: LanguageFlow.plan(text: selectedText, settings: settings))
            }
        default:
            break
        }
    }

    func applyOverrideRoute(_ routeID: UUID) {
        guard textLanguageOverride != nil,
              let route = settings.allLanguageRoutes.first(where: { $0.id == routeID }),
              var plan = languagePlan else { return }
        if textLanguageOverride != nil {
            for index in plan.sentences.indices {
                plan.sentences[index].route = route
            }
            startReading(text: selectedText, plan: plan)
            return
        }
    }

    private func startAutoPlan(text: String, plan: LanguageFlow.Plan) {
        startReading(text: text, plan: plan)
    }

    private func startReading(text: String, plan: LanguageFlow.Plan) {
        guard let speech = selectedSpeechEngine() else { return }
        activeSpeech?.stop()
        activeSpeech = speech
        selectedText = settings.wordHighlightingEnabled
            ? LanguageFlow.playbackText(for: plan, sourceText: text)
            : text
        progress.wordRange = nil
        progress.readingOffset = nil
        languagePlan = plan
        state = .preparing
        onPopupVisibilityChanged?(true)
        speech.read(plan, settings: settings)
    }

    private func showMessage(_ message: String) {
        selectedText = ""
        progress.wordRange = nil
        progress.readingOffset = nil
        languagePlan = nil
        state = .message(message)
        onPopupVisibilityChanged?(true)
        dismissAfterDelay()
    }

    private func finishedReading() {
        guard state == .playing || state == .paused else { return }
        state = .finished
        progress.wordRange = nil
        progress.readingOffset = nil
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
                self?.azureVoiceLoadError = L10n.string("Flow could not load Azure voices. Check the endpoint and key.")
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
                self?.googleVoiceLoadError = L10n.string("Flow could not load Google voices. Check the API key and confirm that Cloud Text-to-Speech is enabled.")
            }
        }
    }

    private func selectedSpeechEngine() -> FlowSpeechEngine? {
        switch settings.speechSource {
        case .system:
            return systemSpeech
        case .azure:
            guard azureEndpoint != nil else {
                showMessage(L10n.string("Set up Azure Speech before choosing Azure voice."))
                return nil
            }
            return azureSpeech
        case .google:
            guard googleConfigured else {
                showMessage(L10n.string("Set up Google Cloud Text-to-Speech before choosing Google voice."))
                return nil
            }
            return googleSpeech
        }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
