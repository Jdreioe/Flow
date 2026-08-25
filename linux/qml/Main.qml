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
    property int currentWordStart: -1
    property int currentWordEnd: -1

    component MenuItemButton: Button {
        id: menuItem
        flat: true
        contentItem: Text {
            text: menuItem.text
            font: menuItem.font
            color: menuItem.enabled ? menuItem.palette.buttonText : menuItem.palette.mid
            horizontalAlignment: Text.AlignLeft
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            implicitHeight: 28
            radius: 6
            color: menuItem.hovered && menuItem.enabled ? menuItem.palette.midlight : "transparent"
        }
    }

    component PiperVoiceCombo: ComboBox {
        id: piperCombo
        property var options: []
        property string chosenKey: ""
        property string placeholder: ""
        model: options
        textRole: "label"
        valueRole: "key"
        currentIndex: options.findIndex(function(option) { return option.key === chosenKey })
        displayText: currentIndex >= 0 && options[currentIndex]
            ? root.piperOptionLabel(options[currentIndex]) : placeholder
        delegate: ItemDelegate {
            id: voiceRow
            required property var modelData
            required property int index
            width: piperCombo.width
            height: 48
            contentItem: RowLayout {
                spacing: 8
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label {
                        text: voiceRow.modelData.name + " · " + voiceRow.modelData.quality
                        font.bold: voiceRow.modelData.key === piperCombo.chosenKey
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    Label {
                        visible: !voiceRow.modelData.installed
                        text: qsTr("Not downloaded yet")
                        font.pixelSize: 11
                        color: palette.mid
                    }
                }
                Button {
                    text: qsTr("Preview")
                    flat: true
                    enabled: voiceRow.modelData.installed
                    Accessible.name: qsTr("Preview the %1 voice").arg(voiceRow.modelData.name)
                    onClicked: backend.preview_piper_voice(voiceRow.modelData.key)
                }
            }
            background: Rectangle {
                color: voiceRow.hovered ? palette.midlight : "transparent"
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width - 16
                    height: 1
                    color: palette.mid
                    opacity: 0.25
                    visible: voiceRow.index < piperCombo.count - 1
                }
            }
            highlighted: piperCombo.highlightedIndex === voiceRow.index
        }
    }

    function escapedHtml(value) {
        return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    function highlightedText() {
        const text = backend.playback_text
        if (currentWordStart < 0 || currentWordEnd > text.length)
            return escapedHtml(text)
        const nominalStart = Math.max(0, currentWordStart - 24)
        // Once playback crosses a paragraph break, drop the completed paragraph
        // so the active word remains in the forward-looking part of the popup.
        const paragraphStart = text.lastIndexOf("\n", currentWordStart - 1) + 1
        const visibleStart = Math.max(nominalStart, paragraphStart)
        const visibleEnd = Math.min(text.length, currentWordEnd + 220)
        return "<span style='color:#888'>" + escapedHtml(text.slice(visibleStart, currentWordStart))
            + "</span><b>" + escapedHtml(text.slice(currentWordStart, currentWordEnd))
            + "</b>" + escapedHtml(text.slice(currentWordEnd, visibleEnd))
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

    function hotKeyTitle() {
        switch (settings.hotKey) {
        case "altSuperSpace": return qsTr("Alt+Super+Space")
        case "controlAltR": return qsTr("Ctrl+Alt+R")
        default: return qsTr("Alt+Super+R")
        }
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
            googleSpeechRate: settings.googleSpeechRate,
            piperVoiceName: settings.piperVoiceName
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

    function piperOptionsFor(languageTag) {
        let base = languageTag.split("-")[0].toLowerCase()
        return snapshot.piperVoices.filter(function(voice) {
            return voice.languageCode.split("_")[0].toLowerCase() === base
        }).map(function(voice) {
            return {
                key: voice.key,
                name: voice.name,
                quality: voice.quality,
                installed: voice.installed
            }
        })
    }

    function piperOptionLabel(option) {
        return option.name + " · " + option.quality
            + (option.installed ? "" : " · " + qsTr("not downloaded"))
    }

    function piperVoiceInstalled(key) {
        for (let voice of snapshot.piperVoices)
            if (voice.key === key) return voice.installed
        return false
    }

    FlowBackend {
        id: backend
    }

    Component.onCompleted: {
        console.warn("[shot] root onCompleted")
        backend.start()
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
            root.currentWordStart = -1
            root.currentWordEnd = -1
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
            previewPlayer.stop()
            previewPlayer.source = ""
        }

        function onPlay_preview(url) {
            previewPlayer.stop()
            previewPlayer.source = url
            previewPlayer.play()
        }

        function onShow_settings() {
            settingsWindow.show()
            settingsWindow.raise()
            settingsWindow.requestActivate()
        }
    }

    MediaPlayer {
        id: previewPlayer
        audioOutput: AudioOutput {}
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
            root.currentWordStart = active ? active.start : -1
            root.currentWordEnd = active ? active.end : -1
        }
    }

    Platform.SystemTrayIcon {
        id: tray
        visible: true
        icon.name: "io.github.jdreioe.flow"
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
        width: 240
        height: trayColumn.implicitHeight + 20
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
                id: trayColumn
                anchors.fill: parent
                anchors.margins: 10
                spacing: 2

                MenuItemButton {
                    Layout.fillWidth: true
                    text: qsTr("Read selected text")
                    onClicked: {
                        trayPanel.hide()
                        backend.read_selection()
                    }
                }
                Label {
                    Layout.fillWidth: true
                    Layout.leftMargin: 12
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12
                    color: backend.shortcut_status.indexOf("Global shortcut:") === 0
                        ? palette.mid : "red"
                    text: backend.shortcut_status === "Registering global shortcut…"
                        ? hotKeyTitle()
                        : backend.shortcut_status
                }
                MenuSeparator {
                    Layout.fillWidth: true
                }
                MenuItemButton {
                    Layout.fillWidth: true
                    text: qsTr("Settings…")
                    onClicked: {
                        trayPanel.hide()
                        backend.open_settings()
                    }
                }
                MenuItemButton {
                    Layout.fillWidth: true
                    text: qsTr("What's New…")
                    onClicked: {
                        trayPanel.hide()
                        Qt.openUrlExternally("https://github.com/jdreioe/flow/releases/latest")
                    }
                }
                MenuItemButton {
                    Layout.fillWidth: true
                    text: backend.update_ready_version.length > 0
                          ? qsTr("Restart to Update…") : qsTr("Check for Updates…")
                    onClicked: {
                        trayPanel.hide()
                        if (backend.update_ready_version.length > 0)
                            backend.restart_to_update()
                        else
                            backend.check_for_updates()
                    }
                }
                MenuSeparator {
                    Layout.fillWidth: true
                }
                MenuItemButton {
                    Layout.fillWidth: true
                    text: qsTr("Quit Flow")
                    onClicked: Qt.quit()
                }
            }
        }
    }

    Window {
        id: popup
        visible: backend.popup_visible
        width: 520
        height: 250
        minimumWidth: 420
        color: "transparent"
        title: "Flow playback"
        flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
            | Qt.WindowDoesNotAcceptFocus

        property bool showLanguages: false

        // Screen is only valid once the window is mapped, so bind the
        // position to visibility instead of evaluating it up front.
        onVisibleChanged: {
            if (!visible)
                return
            x = Screen.virtualX + Math.round((Screen.desktopAvailableWidth - width) / 2)
            y = Screen.virtualY + Math.round((Screen.desktopAvailableHeight - height) / 2)
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
                    visible: backend.state === "playing" || backend.state === "paused"
                    Layout.fillWidth: true
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    wrapMode: Text.WordWrap
                    textFormat: Text.RichText
                    text: root.highlightedText()
                    Accessible.name: "Selected text being read"
                }

                RowLayout {
                    visible: (backend.state === "playing" || backend.state === "paused")
                        && root.cloudActive
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
        width: 680
        height: 720
        minimumWidth: 560
        minimumHeight: 480
        title: "Flow Settings"

        Component.onCompleted: {
            setX(Math.round((Screen.width - width) / 2))
            setY(Math.round((Screen.height - height) / 2))
        }

        onClosing: function(close) {
            close.accepted = false
            hide()
        }

        component SettingRow: RowLayout {
            id: rowRoot
            property string label: ""
            default property alias content: rowRoot.data
            spacing: 12
            Layout.fillWidth: true
            Label {
                text: rowRoot.label
                Layout.preferredWidth: 150
                wrapMode: Text.WordWrap
                color: palette.mid
                verticalAlignment: Text.AlignVCenter
            }
        }

        component HintLabel: Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            font.pixelSize: 12
            opacity: 0.75
        }

        function routeVoiceSummary(route) {
            switch (settings.speechSource) {
            case "azure": return route.azureVoiceName || qsTr("Fallback Azure voice")
            case "google": return route.googleVoiceName || qsTr("Google default voice")
            case "piper":
                let options = root.piperOptionsFor(route.languageTag)
                for (let option of options)
                    if (option.key === route.piperVoiceName) return option.label
                return qsTr("No Piper voice chosen")
            default: return route.systemVoiceName || qsTr("Desktop default voice")
            }
        }

        ScrollView {
            anchors.fill: parent
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: 16

                GroupBox {
                    title: qsTr("Access")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 10

                        SettingRow {
                            label: qsTr("Global hotkey")
                            ComboBox {
                                Layout.fillWidth: true
                                model: [
                                    { value: "altSuperR", label: hotKeyTitle() },
                                    { value: "altSuperSpace", label: qsTr("Alt+Super+Space") },
                                    { value: "controlAltR", label: qsTr("Ctrl+Alt+R") }
                                ]
                                textRole: "label"
                                valueRole: "value"
                                currentIndex: model.findIndex(function(item) { return item.value === settings.hotKey })
                                onActivated: backend.update_setting("hotKey", currentValue)
                            }
                        }
                        SettingRow {
                            visible: settings.speechSource === "google"
                            label: qsTr("Highlighting")
                            CheckBox {
                                Layout.fillWidth: true
                                text: qsTr("Highlight spoken words")
                                checked: settings.wordHighlightingEnabled
                                onToggled: backend.update_setting("wordHighlightingEnabled", checked ? "true" : "false")
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            font.pixelSize: 12
                            color: backend.shortcut_status.indexOf("Global shortcut:") === 0
                                ? palette.mid : "red"
                            text: backend.shortcut_status
                        }
                        HintLabel {
                            text: qsTr("Flow reads highlighted text through Linux accessibility or the desktop's primary selection. It never replaces your normal clipboard.")
                        }
                    }
                }

                GroupBox {
                    title: qsTr("Language Flow")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 10

                        HintLabel {
                            text: qsTr("Flow detects each sentence's language on this device and reads it with the voice configured for that language. The fallback voice handles everything else.")
                        }
                        SettingRow {
                            label: qsTr("Playback speed")
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
                        SettingRow {
                            label: qsTr("Fallback voice")
                            visible: settings.speechSource === "system"
                            ComboBox {
                                Layout.fillWidth: true
                                model: ["Desktop default voice"].concat(root.voicesFor(settings.defaultLanguageTag))
                                currentIndex: settings.systemVoiceName
                                    ? Math.max(0, model.indexOf(settings.systemVoiceName))
                                    : 0
                                onActivated: backend.update_setting("systemVoiceName",
                                    currentIndex === 0 ? "" : currentText)
                            }
                        }
                        SettingRow {
                            label: qsTr("Fallback voice")
                            visible: settings.speechSource === "azure" && !!settings.azureEndpoint
                            ComboBox {
                                Layout.fillWidth: true
                                model: snapshot.azureVoices.map(function(voice) { return voice.shortName })
                                currentIndex: Math.max(0, model.indexOf(settings.azureVoiceName))
                                displayText: currentText || qsTr("Choose a fallback Azure voice")
                                onActivated: backend.update_setting("azureVoiceName", currentText)
                            }
                        }
                        SettingRow {
                            label: qsTr("Fallback voice")
                            visible: settings.speechSource === "google" && settings.googleApiKeyConfigured
                            ComboBox {
                                Layout.fillWidth: true
                                model: ["Google default voice"].concat(snapshot.googleVoices.map(function(voice) { return voice.name }))
                                currentIndex: settings.googleVoiceName
                                    ? Math.max(0, model.indexOf(settings.googleVoiceName))
                                    : 0
                                onActivated: backend.update_setting("googleVoiceName",
                                    currentIndex === 0 ? "" : currentText)
                            }
                        }
                        SettingRow {
                            label: qsTr("Fallback voice")
                            visible: settings.speechSource === "piper"
                            PiperVoiceCombo {
                                Layout.fillWidth: true
                                options: root.piperOptionsFor(settings.defaultLanguageTag)
                                chosenKey: settings.piperVoiceName
                                placeholder: qsTr("Choose a fallback Piper voice")
                                onActivated: backend.update_setting("piperVoiceName", currentValue)
                            }
                            Button {
                                visible: !!settings.piperVoiceName
                                text: root.piperVoiceInstalled(settings.piperVoiceName)
                                    ? qsTr("Remove voice") : qsTr("Download…")
                                flat: root.piperVoiceInstalled(settings.piperVoiceName)
                                onClicked: {
                                    if (root.piperVoiceInstalled(settings.piperVoiceName))
                                        backend.delete_piper_voice(settings.piperVoiceName)
                                    else
                                        backend.download_piper_voice(settings.piperVoiceName)
                                }
                            }
                        }

                        Label {
                            visible: settings.speechSource === "piper" && backend.piper_status.length > 0
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: backend.piper_status
                        }

                        Repeater {
                            model: settings.languageRoutes

                            Frame {
                                id: routeCard
                                required property var modelData
                                Layout.fillWidth: true
                                property bool expanded: false
                                leftPadding: 8
                                rightPadding: 8
                                topPadding: 4
                                bottomPadding: 4

                                ColumnLayout {
                                    anchors.fill: parent
                                    spacing: 8

                                    ItemDelegate {
                                        Layout.fillWidth: true
                                        contentItem: RowLayout {
                                            spacing: 8
                                            Label {
                                                text: root.languageName(routeCard.modelData.languageTag)
                                                font.bold: true
                                            }
                                            Label {
                                                text: "· " + root.routeVoiceSummary(routeCard.modelData)
                                                color: palette.mid
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                            Label {
                                                text: routeCard.expanded ? "▾" : "▸"
                                                color: palette.mid
                                            }
                                        }
                                        background: Rectangle {
                                            radius: 6
                                            color: parent.hovered ? palette.midlight : "transparent"
                                        }
                                        onClicked: routeCard.expanded = !routeCard.expanded
                                    }

                                    ColumnLayout {
                                        visible: routeCard.expanded
                                        Layout.fillWidth: true
                                        Layout.leftMargin: 12
                                        spacing: 8

                                        SettingRow {
                                            visible: settings.speechSource === "system"
                                            label: qsTr("Voice")
                                            ComboBox {
                                                Layout.fillWidth: true
                                                model: ["Desktop default voice"].concat(root.voicesFor(routeCard.modelData.languageTag))
                                                currentIndex: routeCard.modelData.systemVoiceName
                                                    ? Math.max(0, model.indexOf(routeCard.modelData.systemVoiceName))
                                                    : 0
                                                onActivated: backend.update_route(routeCard.modelData.id, "systemVoiceName",
                                                    currentIndex === 0 ? "" : currentText)
                                            }
                                        }
                                        SettingRow {
                                            visible: settings.speechSource === "azure"
                                            label: qsTr("Azure voice")
                                            ComboBox {
                                                Layout.fillWidth: true
                                                model: root.azureVoicesFor(routeCard.modelData.languageTag, false)
                                                currentIndex: Math.max(0, model.indexOf(routeCard.modelData.azureVoiceName || ""))
                                                displayText: currentText || qsTr("Choose an Azure voice")
                                                onActivated: backend.update_route(routeCard.modelData.id, "azureVoiceName", currentText)
                                            }
                                        }
                                        SettingRow {
                                            visible: settings.speechSource === "google"
                                            label: qsTr("Google voice")
                                            ComboBox {
                                                Layout.fillWidth: true
                                                model: ["Google default voice"].concat(root.googleVoicesFor(routeCard.modelData.languageTag))
                                                currentIndex: routeCard.modelData.googleVoiceName
                                                    ? Math.max(0, model.indexOf(routeCard.modelData.googleVoiceName))
                                                    : 0
                                                onActivated: backend.update_route(routeCard.modelData.id, "googleVoiceName",
                                                    currentIndex === 0 ? "" : currentText)
                                            }
                                        }
                                        SettingRow {
                                            visible: settings.speechSource === "piper"
                                            label: qsTr("Piper voice")
                                            PiperVoiceCombo {
                                                Layout.fillWidth: true
                                                options: root.piperOptionsFor(routeCard.modelData.languageTag)
                                                chosenKey: routeCard.modelData.piperVoiceName
                                                placeholder: qsTr("Choose a Piper voice")
                                                onActivated: backend.update_route(routeCard.modelData.id, "piperVoiceName", currentValue)
                                            }
                                            Button {
                                                visible: !!routeCard.modelData.piperVoiceName
                                                text: root.piperVoiceInstalled(routeCard.modelData.piperVoiceName)
                                                    ? qsTr("Remove voice") : qsTr("Download…")
                                                flat: root.piperVoiceInstalled(routeCard.modelData.piperVoiceName)
                                                onClicked: {
                                                    if (root.piperVoiceInstalled(routeCard.modelData.piperVoiceName))
                                                        backend.delete_piper_voice(routeCard.modelData.piperVoiceName)
                                                    else
                                                        backend.download_piper_voice(routeCard.modelData.piperVoiceName)
                                                }
                                            }
                                        }
                                        SettingRow {
                                            label: qsTr("Speed")
                                            ComboBox {
                                                Layout.fillWidth: true
                                                property var speeds: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.25, 3.5, 3.75, 4.0]
                                                model: [qsTr("Same as Language Flow")].concat(
                                                    speeds.map(function(speed) { return Number(speed.toFixed(2)).toString() + "×" }))
                                                currentIndex: routeCard.modelData.playbackSpeed !== null
                                                    ? 1 + speeds.indexOf(routeCard.modelData.playbackSpeed)
                                                    : 0
                                                onActivated: backend.update_route(routeCard.modelData.id, "playbackSpeed",
                                                    currentIndex === 0 ? "" : String(speeds[currentIndex - 1]))
                                            }
                                        }
                                        Button {
                                            Layout.alignment: Qt.AlignLeft
                                            flat: true
                                            text: qsTr("Remove language")
                                            onClicked: backend.remove_language(routeCard.modelData.id)
                                        }
                                    }
                                }
                            }
                        }

                        RowLayout {
                            spacing: 8
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
                                displayText: currentIndex >= 0 ? model[currentIndex][1] : qsTr("All supported languages are enabled")
                            }
                            Button {
                                text: qsTr("Add language")
                                enabled: languageToAdd.currentIndex >= 0
                                onClicked: backend.add_language(languageToAdd.model[languageToAdd.currentIndex][0])
                            }
                        }
                    }
                }

                GroupBox {
                    title: qsTr("Speech")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 10

                        SettingRow {
                            label: qsTr("Reading source")
                            ComboBox {
                                Layout.fillWidth: true
                                model: [
                                    { value: "system", label: qsTr("System voice") },
                                    { value: "azure", label: qsTr("Azure voice") },
                                    { value: "google", label: qsTr("Google Cloud voice") },
                                    { value: "piper", label: qsTr("Piper voice (offline)") }
                                ]
                                textRole: "label"
                                valueRole: "value"
                                currentIndex: settings.speechSource === "azure" ? 1
                                    : settings.speechSource === "google" ? 2
                                    : settings.speechSource === "piper" ? 3 : 0
                                onActivated: backend.update_setting("speechSource", currentValue)
                            }
                        }

                        // Azure
                        ColumnLayout {
                            visible: settings.speechSource === "azure"
                            Layout.fillWidth: true
                            spacing: 10

                            SettingRow {
                                visible: !!settings.azureEndpoint
                                label: qsTr("Endpoint")
                                Label {
                                    Layout.fillWidth: true
                                    text: settings.azureEndpoint || ""
                                    elide: Text.ElideMiddle
                                }
                            }
                            ColumnLayout {
                                visible: !settings.azureEndpoint
                                Layout.fillWidth: true
                                spacing: 8
                                TextField {
                                    id: endpointField
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("Region or HTTPS endpoint")
                                    Accessible.name: placeholderText
                                }
                                TextField {
                                    id: keyField
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("Azure Speech subscription key")
                                    echoMode: TextInput.Password
                                    Accessible.name: placeholderText
                                }
                                Button {
                                    text: qsTr("Save Azure configuration")
                                    enabled: endpointField.text.trim().length > 0 && keyField.text.trim().length > 0
                                    onClicked: {
                                        backend.save_azure_configuration(endpointField.text, keyField.text)
                                        keyField.clear()
                                    }
                                }
                            }
                            RowLayout {
                                visible: !!settings.azureEndpoint
                                spacing: 8
                                Button {
                                    text: qsTr("Refresh voices")
                                    onClicked: backend.refresh_azure_voices()
                                }
                                Button {
                                    flat: true
                                    text: qsTr("Remove configuration")
                                    onClicked: backend.clear_azure_configuration()
                                }
                            }
                            HintLabel {
                                text: qsTr("Azure receives selected text only while Azure is the reading source. The subscription key is stored in your desktop keyring.")
                            }
                            Button {
                                flat: true
                                text: qsTr("Open Azure Speech resources")
                                onClicked: Qt.openUrlExternally("https://portal.azure.com/#view/HubsExtension/BrowseResource/resourceType/Microsoft.CognitiveServices%2Faccounts")
                            }
                        }

                        // Google
                        ColumnLayout {
                            visible: settings.speechSource === "google"
                            Layout.fillWidth: true
                            spacing: 10

                            ColumnLayout {
                                visible: !settings.googleApiKeyConfigured
                                Layout.fillWidth: true
                                spacing: 8
                                TextField {
                                    id: googleKeyField
                                    Layout.fillWidth: true
                                    placeholderText: qsTr("Google Cloud API key")
                                    echoMode: TextInput.Password
                                    Accessible.name: placeholderText
                                }
                                Button {
                                    text: qsTr("Save Google configuration")
                                    enabled: googleKeyField.text.trim().length > 0
                                    onClicked: {
                                        backend.save_google_configuration(googleKeyField.text)
                                        googleKeyField.clear()
                                    }
                                }
                            }
                            RowLayout {
                                visible: settings.googleApiKeyConfigured
                                spacing: 8
                                Label {
                                    text: qsTr("API key configured")
                                    color: palette.mid
                                }
                                Item { Layout.fillWidth: true }
                                Button {
                                    text: qsTr("Refresh voices")
                                    onClicked: backend.refresh_google_voices()
                                }
                                Button {
                                    flat: true
                                    text: qsTr("Remove configuration")
                                    onClicked: backend.clear_google_configuration()
                                }
                            }
                            HintLabel {
                                text: qsTr("Google receives selected text only while Google Cloud is the reading source. The API key is stored in your desktop keyring. Restrict it to the Cloud Text-to-Speech API.")
                            }
                            RowLayout {
                                spacing: 8
                                Button {
                                    flat: true
                                    text: qsTr("API credentials")
                                    onClicked: Qt.openUrlExternally("https://console.cloud.google.com/apis/credentials")
                                }
                                Button {
                                    flat: true
                                    text: qsTr("Enable Cloud Text-to-Speech API")
                                    onClicked: Qt.openUrlExternally("https://console.cloud.google.com/apis/library/texttospeech.googleapis.com")
                                }
                            }
                        }

                        // Piper
                        ColumnLayout {
                            visible: settings.speechSource === "piper"
                            Layout.fillWidth: true
                            spacing: 10

                            HintLabel {
                                text: qsTr("Piper runs entirely on this device. Voice models download once from Hugging Face and stay in your Flow data folder. Choose voices per language under Language Flow.")
                            }
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
                    title: qsTr("Playback")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 10

                        SettingRow {
                            label: qsTr("Test")
                            Button {
                                Layout.fillWidth: true
                                text: qsTr("Play test voice")
                                onClicked: backend.play_test_voice()
                            }
                        }
                        SettingRow {
                            label: qsTr("Same selection")
                            ComboBox {
                                Layout.fillWidth: true
                                model: [
                                    { value: "pauseResume", label: qsTr("Pause or resume") },
                                    { value: "restart", label: qsTr("Restart reading") }
                                ]
                                textRole: "label"
                                valueRole: "value"
                                currentIndex: settings.sameSelectionAction === "restart" ? 1 : 0
                                onActivated: backend.update_setting("sameSelectionAction", currentValue)
                            }
                        }
                        SettingRow {
                            label: qsTr("Popup dismisses")
                            Slider {
                                id: dismissSlider
                                Layout.fillWidth: true
                                from: 3
                                to: 30
                                stepSize: 1
                                value: settings.popupDismissSeconds
                                onMoved: backend.update_setting("popupDismissSeconds", value.toString())
                            }
                            Label {
                                text: Math.round(dismissSlider.value) + " s"
                                horizontalAlignment: Text.AlignRight
                                Layout.preferredWidth: 40
                            }
                        }
                        HintLabel {
                            text: qsTr("Selections longer than about ten minutes are not read.")
                        }
                    }
                }

                GroupBox {
                    title: qsTr("Privacy")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    Label {
                        anchors.fill: parent
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        text: qsTr("Flow keeps selected text only while the playback popup is visible. System language detection, system voices, and Piper voices are on-device. A cloud provider receives text only when that provider is selected.")
                    }
                }
            }
        }
    }
}
