import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Window
import QtMultimedia
import Qt.labs.platform as Platform
import Flow 1.0

ApplicationWindow {
    id: root
    visible: false
    width: 1
    height: 1
    title: "Flow"

    property var snapshot: JSON.parse(backend.snapshot_json)
    property var settings: snapshot.settings
    property var detectedLanguages: JSON.parse(backend.detected_languages_json)
    property bool cloudActive: false
    property var wordTimings: []

    // Matches the Windows popup: preparing, playing, paused, and the language
    // check all count as active playback.
    property bool activePlaybackState: backend.state === "preparing"
        || backend.state === "playing" || backend.state === "paused"
        || backend.state === "awaitingRoute"

    function escapedHtml(value) {
        return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    function highlightedText() {
        const text = backend.playback_text
        const start = backend.current_word_start
        const end = backend.current_word_end
        if (start < 0 || end > text.length)
            return escapedHtml(text)
        const nominalStart = Math.max(0, start - 24)
        // Once playback crosses a paragraph break, drop the completed paragraph
        // so the active word remains in the forward-looking part of the popup.
        const paragraphStart = text.lastIndexOf("\n", start - 1) + 1
        const visibleStart = Math.max(nominalStart, paragraphStart)
        const visibleEnd = Math.min(text.length, end + 220)
        return "<span style='color:#888'>" + escapedHtml(text.slice(visibleStart, start))
            + "</span><b>" + escapedHtml(text.slice(start, end))
            + "</b>" + escapedHtml(text.slice(end, visibleEnd))
    }

    function cloudPlayer() {
        return cloudPlayerLoader.item ? cloudPlayerLoader.item.player : null
    }

    function stopCloudPlayback() {
        let player = cloudPlayer()
        if (player) {
            player.stop()
            player.source = ""
        }
        cloudActive = false
        cloudPlayerLoader.active = false
    }

    function toggleTrayPanel() {
        if (trayPanel.visible) {
            trayPanel.hide()
            return
        }

        let screen = trayPanel.screen
        let availableX = screen.virtualX
        let availableY = screen.virtualY
        let availableWidth = screen.desktopAvailableWidth
        let availableHeight = screen.desktopAvailableHeight
        let icon = tray.geometry
        if (icon.width > 0 && icon.height > 0) {
            trayPanel.x = Math.max(availableX + 8,
                Math.min(icon.x + Math.round((icon.width - trayPanel.width) / 2),
                    availableX + availableWidth - trayPanel.width - 8))
            trayPanel.y = icon.y > availableY + availableHeight / 2
                ? icon.y - trayPanel.height - 8
                : icon.y + icon.height + 8
        } else {
            trayPanel.x = availableX + availableWidth - trayPanel.width - 16
            trayPanel.y = availableY + availableHeight - trayPanel.height - 48
        }
        trayPanel.show()
        trayPanel.raise()
    }

    function languageName(tag) {
        for (let entry of snapshot.supportedLanguages) {
            if (entry[0] === tag)
                return entry[1]
        }
        return tag
    }

    function allRoutes() {
        let defaultRoute = {
            id: "00000000-0000-0000-0000-000000000001",
            languageTag: settings.defaultLanguageTag,
            systemVoiceName: settings.systemVoiceName,
            systemSpeechRate: settings.systemSpeechRate,
            azureVoiceName: settings.azureVoiceName,
            azureSpeechRate: settings.azureSpeechRate,
            googleVoiceName: settings.googleVoiceName,
            googleSpeechRate: settings.googleSpeechRate
        }
        return [defaultRoute].concat(settings.languageRoutes)
    }

    function voicesFor(languageTag) {
        let base = languageTag.split("-")[0].toLowerCase()
        return snapshot.systemVoices.filter(function(voice) {
            return voice.languageTag.split("-")[0].toLowerCase() === base
        }).map(function(voice) { return voice.name })
    }

    function azureVoicesFor(languageTag, multilingualOnly) {
        let base = languageTag.split("-")[0].toLowerCase()
        return snapshot.azureVoices.filter(function(voice) {
            let locales = [voice.locale].concat(voice.secondaryLocales)
            let supports = locales.some(function(locale) {
                return locale.split("-")[0].toLowerCase() === base
            })
            let multilingual = voice.shortName.toLowerCase().includes("multilingual")
                || voice.secondaryLocales.length > 0
            return supports && (!multilingualOnly || multilingual)
        }).map(function(voice) { return voice.shortName })
    }

    function googleVoicesFor(languageTag) {
        let base = languageTag.split("-")[0].toLowerCase()
        return snapshot.googleVoices.filter(function(voice) {
            return voice.languageCodes.some(function(languageCode) {
                return languageCode.split("-")[0].toLowerCase() === base
            })
        }).map(function(voice) { return voice.name })
    }

    FlowBackend {
        id: backend
    }

    Component.onCompleted: backend.start()

    Connections {
        target: backend
        function onPopup_visible_changed() {
            popup.syncVisibility()
        }
    }

    Shortcut {
        sequences: [StandardKey.Cancel]
        enabled: popup.visible && backend.state !== "hidden"
        onActivated: backend.stop()
    }

    Connections {
        target: backend

        function onPlay_cloud(fileUrl, wordTimingsJson, rate) {
            cloudPlayerLoader.active = true
            let player = cloudPlayer()
            if (!player) {
                backend.playback_failed("Flow could not initialize audio playback.")
                return
            }
            player.source = fileUrl
            player.playbackRate = rate
            root.wordTimings = JSON.parse(wordTimingsJson)
            backend.report_word_range(-1, -1)
            cloudActive = true
            player.play()
        }

        function onSegment_rate(rate) {
            let player = cloudPlayer()
            if (cloudActive && player)
                player.playbackRate = rate
        }

        function onPause_playback() {
            let player = cloudPlayer()
            if (cloudActive && player)
                player.pause()
        }

        function onPlayback_speed_changed() {
            let player = cloudPlayer()
            if (cloudActive && player)
                player.playbackRate = backend.playback_speed
        }

        function onResume_playback() {
            let player = cloudPlayer()
            if (cloudActive && player)
                player.play()
        }

        function onStop_audio() {
            stopCloudPlayback()
        }

        function onShow_settings() {
            settingsWindow.show()
            settingsWindow.raise()
            settingsWindow.requestActivate()
        }
    }

    Loader {
        id: cloudPlayerLoader
        active: false
        sourceComponent: Item {
            property alias player: player

            AudioOutput {
                id: cloudOutput
            }

            MediaPlayer {
                id: player
                audioOutput: cloudOutput

                onMediaStatusChanged: {
                    if (root.cloudActive && mediaStatus === MediaPlayer.EndOfMedia) {
                        root.stopCloudPlayback()
                        backend.playback_finished()
                    } else if (root.cloudActive && mediaStatus === MediaPlayer.InvalidMedia) {
                        backend.playback_failed("The cloud speech service returned audio that Flow could not play.")
                        Qt.callLater(root.stopCloudPlayback)
                    }
                }
                onErrorOccurred: function(error, errorString) {
                    if (root.cloudActive) {
                        backend.playback_failed(errorString || "Cloud speech playback ended unexpectedly.")
                        Qt.callLater(root.stopCloudPlayback)
                    }
                }
            }
        }
    }

    Timer {
        interval: 30
        repeat: true
        running: root.cloudActive
        onTriggered: {
            const player = root.cloudPlayer()
            if (!player) return
            const seconds = player.position / 1000
            let active = null
            for (let index = 0; index < root.wordTimings.length; ++index) {
                if (root.wordTimings[index].timeSeconds <= seconds) active = root.wordTimings[index]
                else break
            }
            backend.report_word_range(active ? active.start : -1, active ? active.end : -1)
        }
    }

    Platform.SystemTrayIcon {
        id: tray
        visible: true
        icon.name: "accessories-text-editor"
        tooltip: "Flow"

        onActivated: function(reason) {
            if (reason === Platform.SystemTrayIcon.Trigger
                    || reason === Platform.SystemTrayIcon.Context)
                root.toggleTrayPanel()
        }
    }

    Window {
        id: trayPanel
        visible: false
        width: 220
        height: 156
        color: "transparent"
        title: "Flow"
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
            | Qt.WindowDoesNotAcceptFocus

        Rectangle {
            anchors.fill: parent
            radius: 12
            color: palette.window
            border.color: palette.mid
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 6

                Button {
                    Layout.fillWidth: true
                    text: "Read selected text"
                    onClicked: {
                        trayPanel.hide()
                        backend.read_selection()
                    }
                }
                Button {
                    Layout.fillWidth: true
                    text: "Settings"
                    onClicked: {
                        trayPanel.hide()
                        backend.open_settings()
                    }
                }
                Button {
                    Layout.fillWidth: true
                    text: "Quit Flow"
                    onClicked: Qt.quit()
                }
            }
        }
    }

    Window {
        id: popup
        visible: false
        width: 520
        height: 250
        minimumWidth: 420
        color: "transparent"
        title: "Flow playback"
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
            | Qt.WindowDoesNotAcceptFocus

        property bool showLanguages: false

        // Imperative show/hide keeps the window manager from breaking the
        // visibility binding, and lets the popup re-center on every appearance.
        function syncVisibility() {
            if (backend.popup_visible) {
                x = Screen.virtualX + Math.round((Screen.desktopAvailableWidth - width) / 2)
                y = Screen.virtualY + Math.round((Screen.desktopAvailableHeight - height) / 2)
                show()
            } else {
                hide()
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: 16
            color: palette.window
            border.color: palette.mid
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                Label {
                    Layout.fillWidth: true
                    text: {
                        switch (backend.state) {
                        case "preparing": return "Preparing playback"
                        case "playing": return "Reading"
                        case "paused": return "Paused"
                        case "awaitingRoute": return "Choose a voice"
                        case "finished": return "Finished"
                        default: return "Flow"
                        }
                    }
                    font.pixelSize: 20
                    font.bold: true
                    Accessible.name: text
                }

                Label {
                    visible: backend.state === "awaitingRoute"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: backend.manual_route_needed
                        ? qsTr("Choose how Flow should read this sentence before playback starts.")
                        : qsTr("Pick a voice for %1 to start reading.").arg(root.languageName(backend.text_language_override))
                }

                Label {
                    visible: backend.manual_route_needed
                    Layout.fillWidth: true
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    wrapMode: Text.WordWrap
                    text: backend.manual_route_sentence_text
                    Accessible.name: qsTr("Sentence requiring a voice choice")
                }

                Label {
                    visible: backend.state === "message"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: backend.message
                }

                Label {
                    visible: backend.state === "preparing"
                    Layout.fillWidth: true
                    text: "Preparing speech…"
                }

                Label {
                    visible: backend.state !== "message" && backend.playback_text.length > 0
                    Layout.fillWidth: true
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    wrapMode: Text.WordWrap
                    textFormat: settings.wordHighlightingEnabled ? Text.RichText : Text.PlainText
                    text: settings.wordHighlightingEnabled
                        ? root.highlightedText()
                        : root.escapedHtml(backend.playback_text)
                    Accessible.name: "Selected text being read"
                }

                RowLayout {
                    visible: root.activePlaybackState
                    Layout.fillWidth: true
                    spacing: 10

                    Label {
                        text: qsTr("Speed")
                        color: palette.mid
                    }
                    Slider {
                        id: speedSlider
                        Layout.fillWidth: true
                        from: 0.5
                        to: 4.0
                        stepSize: 0.25
                        value: backend.playback_speed
                        Binding on value {
                            when: !speedSlider.pressed
                            value: backend.playback_speed
                            restoreMode: Binding.RestoreBindingOrValue
                        }
                        onPressedChanged: {
                            if (!pressed)
                                backend.set_playback_speed(speedSlider.value)
                        }
                        Accessible.name: qsTr("Playback speed")
                    }
                    Label {
                        text: Number(backend.playback_speed.toFixed(2)).toString() + "×"
                        horizontalAlignment: Text.AlignRight
                        Layout.preferredWidth: 48
                    }
                }

                ComboBox {
                    id: overrideRoutePicker
                    visible: (backend.text_language_override !== "" && backend.override_needs_route)
                        || backend.manual_route_needed
                    property string chosenRouteId: ""
                    onVisibleChanged: if (!visible) chosenRouteId = ""
                    Layout.preferredWidth: 260
                    model: root.allRoutes()
                    textRole: "languageTag"
                    valueRole: "id"
                    displayText: {
                        let routes = model
                        for (let index = 0; index < routes.length; ++index) {
                            if (routes[index].id === chosenRouteId)
                                return qsTr("Read as ") + root.languageName(routes[index].languageTag)
                        }
                        return qsTr("Read as…")
                    }
                    delegate: ItemDelegate {
                        required property var modelData
                        width: overrideRoutePicker.width
                        text: root.languageName(modelData.languageTag)
                    }
                    onActivated: {
                        chosenRouteId = currentValue
                        backend.set_override_route(currentValue)
                    }
                    Accessible.name: backend.manual_route_needed
                        ? qsTr("Read this sentence as")
                        : qsTr("Read the overridden language as")
                }

                ScrollView {
                    visible: popup.showLanguages
                        && root.detectedLanguages.length > 0
                        && (backend.state === "playing" || backend.state === "paused"
                            || backend.state === "awaitingRoute")
                    Layout.fillWidth: true
                    Layout.maximumHeight: 220
                    clip: true

                    Column {
                        width: parent.width
                        spacing: 12

                        Repeater {
                            model: root.detectedLanguages

                            Frame {
                                required property var modelData
                                width: parent.width

                                ColumnLayout {
                                    anchors.fill: parent
                                    spacing: 8

                                    Label {
                                        Layout.fillWidth: true
                                        text: root.languageName(modelData)
                                        font.bold: true
                                    }
                                    ComboBox {
                                        id: languageRoutePicker
                                        Layout.fillWidth: true
                                        model: root.allRoutes()
                                        textRole: "languageTag"
                                        valueRole: "id"
                                        displayText: qsTr("Read as ") + root.languageName(modelData)
                                        delegate: ItemDelegate {
                                            required property var modelData
                                            width: languageRoutePicker.width
                                            text: root.languageName(modelData.languageTag)
                                        }
                                        onActivated: backend.set_route_for_language(modelData, currentValue)
                                    }
                                }
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    visible: backend.state === "preparing"
                        || backend.state === "playing"
                        || backend.state === "paused"
                        || backend.state === "awaitingRoute"

                    Button {
                        text: "Stop"
                        Accessible.description: "Stop reading and close the Flow popup"
                        onClicked: backend.stop()
                    }
                    ComboBox {
                        id: overridePicker
                        visible: backend.state === "preparing"
                            || backend.state === "playing"
                            || backend.state === "paused"
                            || backend.state === "awaitingRoute"
                        Layout.preferredWidth: 180
                        textRole: "text"
                        valueRole: "value"
                        model: {
                            let items = [{ value: "", text: qsTr("Auto") }]
                            for (let entry of root.snapshot.supportedLanguages)
                                items.push({ value: entry[0], text: entry[1] })
                            return items
                        }
                        currentIndex: {
                            let items = model
                            for (let index = 0; index < items.length; ++index) {
                                if (items[index].value === backend.text_language_override)
                                    return index
                            }
                            return 0
                        }
                        onActivated: backend.set_text_language_override(currentValue)
                        Accessible.name: qsTr("Language override")
                    }
                    Button {
                        visible: backend.state === "playing" || backend.state === "paused"
                        flat: true
                        text: popup.showLanguages ? qsTr("Hide languages") : qsTr("Language…")
                        enabled: root.detectedLanguages.length > 0
                        onClicked: popup.showLanguages = !popup.showLanguages
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        visible: backend.state === "playing" || backend.state === "paused"
                        text: backend.state === "paused" ? "Resume" : "Pause"
                        onClicked: backend.pause_or_resume()
                    }
                }
            }
        }
    }

    ApplicationWindow {
        id: settingsWindow
        visible: false
        width: 720
        height: 760
        minimumWidth: 580
        minimumHeight: 520
        title: "Flow Settings"

        onClosing: function(close) {
            close.accepted = false
            hide()
        }

        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: 14

                Label {
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20
                    Layout.topMargin: 20
                    text: "Flow Settings"
                    font.pixelSize: 26
                    font.bold: true
                }

                GroupBox {
                    title: "Access"
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        ComboBox {
                            Layout.fillWidth: true
                            model: [
                                { value: "altSuperR", label: "Alt-Super-R" },
                                { value: "altSuperSpace", label: "Alt-Super-Space" },
                                { value: "controlAltR", label: "Control-Alt-R" }
                            ]
                            textRole: "label"
                            valueRole: "value"
                            currentIndex: model.findIndex(function(item) { return item.value === settings.hotKey })
                            onActivated: backend.update_setting("hotKey", currentValue)
                        }
                        CheckBox {
                            text: "Highlight spoken words"
                            checked: settings.wordHighlightingEnabled
                            onToggled: backend.update_setting("wordHighlightingEnabled", checked ? "true" : "false")
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: backend.shortcut_status
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: "Flow reads highlighted text through Linux accessibility or the desktop's primary selection. It never replaces your normal clipboard."
                        }
                    }
                }

                GroupBox {
                    title: "Language Flow"
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: "Choose a fallback voice, then add languages that need their own voice. Detection stays on this device."
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: qsTr("Playback speed") }
                            Slider {
                                id: flowSpeedSlider
                                Layout.fillWidth: true
                                from: 0.5
                                to: 4.0
                                stepSize: 0.25
                                value: settings.playbackSpeed
                                onMoved: backend.update_setting("playbackSpeed", value.toString())
                            }
                            Label {
                                text: Number(flowSpeedSlider.value.toFixed(2)).toString() + "×"
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: 48
                            }
                        }
                        ComboBox {
                            visible: settings.speechSource === "system"
                            Layout.fillWidth: true
                            model: ["Desktop default voice"].concat(root.voicesFor(settings.defaultLanguageTag))
                            currentIndex: settings.systemVoiceName
                                ? Math.max(0, model.indexOf(settings.systemVoiceName))
                                : 0
                            displayText: currentIndex === 0 ? "Fallback voice: Desktop default voice"
                                : "Fallback voice: " + currentText
                            onActivated: backend.update_setting("systemVoiceName",
                                currentIndex === 0 ? "" : currentText)
                        }
                        ComboBox {
                            visible: settings.speechSource === "azure" && !!settings.azureEndpoint
                            Layout.fillWidth: true
                            model: snapshot.azureVoices.map(function(voice) { return voice.shortName })
                            currentIndex: Math.max(0, model.indexOf(settings.azureVoiceName))
                            displayText: currentText || "Choose a fallback Azure voice"
                            onActivated: backend.update_setting("azureVoiceName", currentText)
                        }
                        ComboBox {
                            visible: settings.speechSource === "google" && settings.googleApiKeyConfigured
                            Layout.fillWidth: true
                            model: ["Google default voice"].concat(snapshot.googleVoices.map(function(voice) { return voice.name }))
                            currentIndex: settings.googleVoiceName
                                ? Math.max(0, model.indexOf(settings.googleVoiceName))
                                : 0
                            onActivated: backend.update_setting("googleVoiceName",
                                currentIndex === 0 ? "" : currentText)
                        }

                        Repeater {
                            model: settings.languageRoutes

                            Frame {
                                required property var modelData
                                Layout.fillWidth: true
                                property bool expanded: false

                                ColumnLayout {
                                    anchors.fill: parent
                                    Button {
                                        text: root.languageName(modelData.languageTag) + " · " + (
                                            settings.speechSource === "system"
                                                ? (modelData.systemVoiceName || "System default voice")
                                                : settings.speechSource === "azure"
                                                    ? (modelData.azureVoiceName || "Fallback Azure voice")
                                                    : (modelData.googleVoiceName || "Google default voice"))
                                        font.bold: true
                                        flat: true
                                        onClicked: parent.parent.expanded = !parent.parent.expanded
                                    }
                                    ComboBox {
                                        id: systemVoicePicker
                                        visible: parent.parent.expanded && settings.speechSource === "system"
                                        Layout.fillWidth: true
                                        model: ["Desktop default voice"].concat(root.voicesFor(modelData.languageTag))
                                        currentIndex: modelData.systemVoiceName
                                            ? Math.max(0, model.indexOf(modelData.systemVoiceName))
                                            : 0
                                        onActivated: backend.update_route(modelData.id, "systemVoiceName",
                                            currentIndex === 0 ? "" : currentText)
                                    }
                                    ComboBox {
                                        id: routeAzureVoicePicker
                                        visible: parent.parent.expanded && settings.speechSource === "azure"
                                        Layout.fillWidth: true
                                        model: root.azureVoicesFor(modelData.languageTag, false)
                                        currentIndex: Math.max(0, model.indexOf(modelData.azureVoiceName || ""))
                                        displayText: currentText || "Choose an Azure voice"
                                        onActivated: backend.update_route(modelData.id, "azureVoiceName", currentText)
                                    }
                                    ComboBox {
                                        id: routeGoogleVoicePicker
                                        visible: parent.parent.expanded && settings.speechSource === "google"
                                        Layout.fillWidth: true
                                        model: ["Google default voice"].concat(root.googleVoicesFor(modelData.languageTag))
                                        currentIndex: modelData.googleVoiceName
                                            ? Math.max(0, model.indexOf(modelData.googleVoiceName))
                                            : 0
                                        onActivated: backend.update_route(modelData.id, "googleVoiceName",
                                            currentIndex === 0 ? "" : currentText)
                                    }
                                    RowLayout {
                                        visible: parent.parent.expanded
                                        Label { text: qsTr("Speed") }
                                        ComboBox {
                                            id: routeSpeedPicker
                                            Layout.fillWidth: true
                                            property var speeds: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.25, 3.5, 3.75, 4.0]
                                            model: [qsTr("Same as Language Flow")].concat(
                                                speeds.map(function(speed) { return Number(speed.toFixed(2)).toString() + "×" }))
                                            currentIndex: modelData.playbackSpeed !== null
                                                ? 1 + speeds.indexOf(modelData.playbackSpeed)
                                                : 0
                                            onActivated: backend.update_route(modelData.id, "playbackSpeed",
                                                currentIndex === 0 ? "" : String(speeds[currentIndex - 1]))
                                        }
                                    }
                                    Button {
                                        visible: parent.parent.expanded
                                        text: "Remove language"
                                        onClicked: backend.remove_language(modelData.id)
                                    }
                                }
                            }
                        }

                        RowLayout {
                            ComboBox {
                                id: languageToAdd
                                Layout.fillWidth: true
                                model: snapshot.supportedLanguages.filter(function(entry) {
                                    return !root.allRoutes().some(function(route) {
                                        return route.languageTag.split("-")[0] === entry[0].split("-")[0]
                                    })
                                })
                                delegate: ItemDelegate {
                                    required property var modelData
                                    width: languageToAdd.width
                                    text: modelData[1]
                                }
                                displayText: currentIndex >= 0 ? model[currentIndex][1] : "All supported languages are enabled"
                            }
                            Button {
                                text: "Add language"
                                enabled: languageToAdd.currentIndex >= 0
                                onClicked: backend.add_language(languageToAdd.model[languageToAdd.currentIndex][0])
                            }
                        }
                    }
                }

                GroupBox {
                    title: "Speech"
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        ComboBox {
                            Layout.fillWidth: true
                            model: [
                                { value: "system", label: "System voice" },
                                { value: "azure", label: "Azure voice" },
                                { value: "google", label: "Google Cloud voice" }
                            ]
                            textRole: "label"
                            valueRole: "value"
                            currentIndex: settings.speechSource === "azure" ? 1
                                : settings.speechSource === "google" ? 2 : 0
                            onActivated: backend.update_setting("speechSource", currentValue)
                        }

                        Label {
                            visible: settings.speechSource === "azure" && !!settings.azureEndpoint
                            text: settings.azureEndpoint ? "Configured for " + settings.azureEndpoint : ""
                        }
                        TextField {
                            id: endpointField
                            visible: settings.speechSource === "azure" && !settings.azureEndpoint
                            Layout.fillWidth: true
                            placeholderText: "Region or HTTPS endpoint"
                            Accessible.name: placeholderText
                        }
                        TextField {
                            id: keyField
                            visible: settings.speechSource === "azure" && !settings.azureEndpoint
                            Layout.fillWidth: true
                            placeholderText: "Azure Speech subscription key"
                            echoMode: TextInput.Password
                            Accessible.name: placeholderText
                        }
                        Button {
                            visible: settings.speechSource === "azure" && !settings.azureEndpoint
                            text: "Save Azure configuration"
                            enabled: endpointField.text.trim().length > 0 && keyField.text.trim().length > 0
                            onClicked: {
                                backend.save_azure_configuration(endpointField.text, keyField.text)
                                keyField.clear()
                            }
                        }
                        RowLayout {
                            visible: settings.speechSource === "azure" && !!settings.azureEndpoint
                            Button {
                                text: "Refresh Azure voices"
                                onClicked: backend.refresh_azure_voices()
                            }
                            Button {
                                text: "Remove Azure configuration"
                                onClicked: backend.clear_azure_configuration()
                            }
                        }
                        Label {
                            visible: settings.speechSource === "azure"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: "Azure receives selected text only when Azure is selected. The subscription key is stored in your desktop keyring."
                        }
                        Button {
                            visible: settings.speechSource === "azure"
                            flat: true
                            text: "Open Azure Speech resources"
                            onClicked: Qt.openUrlExternally("https://portal.azure.com/#view/HubsExtension/BrowseResource/resourceType/Microsoft.CognitiveServices%2Faccounts")
                        }

                        Label {
                            visible: settings.speechSource === "google" && settings.googleApiKeyConfigured
                            text: "Google Cloud API key configured"
                        }
                        TextField {
                            id: googleKeyField
                            visible: settings.speechSource === "google" && !settings.googleApiKeyConfigured
                            Layout.fillWidth: true
                            placeholderText: "Google Cloud API key"
                            echoMode: TextInput.Password
                            Accessible.name: placeholderText
                        }
                        Button {
                            visible: settings.speechSource === "google" && !settings.googleApiKeyConfigured
                            text: "Save Google configuration"
                            enabled: googleKeyField.text.trim().length > 0
                            onClicked: {
                                backend.save_google_configuration(googleKeyField.text)
                                googleKeyField.clear()
                            }
                        }
                        RowLayout {
                            visible: settings.speechSource === "google" && settings.googleApiKeyConfigured
                            Button {
                                text: "Refresh Google voices"
                                onClicked: backend.refresh_google_voices()
                            }
                            Button {
                                text: "Remove Google configuration"
                                onClicked: backend.clear_google_configuration()
                            }
                        }
                        Label {
                            visible: settings.speechSource === "google"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: "Google receives selected text only when Google Cloud is selected. The API key is stored in your desktop keyring. Restrict it to the Cloud Text-to-Speech API."
                        }
                        Button {
                            visible: settings.speechSource === "google"
                            flat: true
                            text: "Open Google Cloud API credentials"
                            onClicked: Qt.openUrlExternally("https://console.cloud.google.com/apis/credentials")
                        }
                        Button {
                            visible: settings.speechSource === "google"
                            flat: true
                            text: "Enable Cloud Text-to-Speech API"
                            onClicked: Qt.openUrlExternally("https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")
                        }

                        Label {
                            visible: backend.configuration_error.length > 0
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: palette.accent
                            text: backend.configuration_error
                        }
                    }
                }

                GroupBox {
                    title: "Playback"
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        Button {
                            text: "Play test voice"
                            onClicked: backend.play_test_voice()
                        }
                        ComboBox {
                            Layout.fillWidth: true
                            model: [
                                { value: "pauseResume", label: "Same selection: pause or resume" },
                                { value: "restart", label: "Same selection: restart reading" }
                            ]
                            textRole: "label"
                            valueRole: "value"
                            currentIndex: settings.sameSelectionAction === "restart" ? 1 : 0
                            onActivated: backend.update_setting("sameSelectionAction", currentValue)
                        }
                        RowLayout {
                            Label { text: "Popup dismisses after " + Math.round(dismissSlider.value) + " seconds" }
                            Slider {
                                id: dismissSlider
                                Layout.fillWidth: true
                                from: 3
                                to: 30
                                stepSize: 1
                                value: settings.popupDismissSeconds
                                onMoved: backend.update_setting("popupDismissSeconds", value.toString())
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: "Selections longer than about ten minutes are not read. Flow keeps selected text only while its playback popup is visible."
                        }
                    }
                }

                Item { Layout.preferredHeight: 6 }
            }
        }
    }
}
