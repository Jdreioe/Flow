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

    property bool activePlaybackState: backend.state === "preparing"
        || backend.state === "playing" || backend.state === "paused"
        || backend.state === "awaitingRoute"

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

        // SystemTrayIcon.geometry is unreliable on Windows once the icon sits
        // in the hidden overflow flyout, so anchor to the cursor instead.
        let screen = trayPanel.screen
        let availableX = screen.virtualX
        let availableY = screen.virtualY
        let availableWidth = screen.desktopAvailableWidth
        let availableHeight = screen.desktopAvailableHeight
        let pos = backend.cursor_position()
        let x = pos.x + 6
        let y = pos.y + 6
        if (x + trayPanel.width > availableX + availableWidth - 8)
            x = pos.x - trayPanel.width - 6
        if (y + trayPanel.height > availableY + availableHeight - 8)
            y = pos.y - trayPanel.height - 6
        trayPanel.x = Math.max(availableX + 4,
            Math.min(x, availableX + availableWidth - trayPanel.width - 4))
        trayPanel.y = Math.max(availableY + 4,
            Math.min(y, availableY + availableHeight - trayPanel.height - 4))
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
        case "altSuperSpace": return qsTr("Alt+Win+Space")
        case "controlAltR": return qsTr("Ctrl+Alt+R")
        default: return qsTr("Alt+Win+R")
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

        function onPlayback_speed_changed() {
            let player = cloudPlayer()
            if (cloudActive && player)
                player.playbackRate = backend.playback_speed
        }

        function onPause_playback() {
            let player = cloudPlayer()
            if (cloudActive && player)
                player.pause()
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
            root.currentWordStart = active ? active.start : -1
            root.currentWordEnd = active ? active.end : -1
        }
    }

    Platform.SystemTrayIcon {
        id: tray
        visible: true
        icon.source: backend.tray_icon_url
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
                    text: qsTr("Check for Updates…")
                    onClicked: {
                        trayPanel.hide()
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
        width: 460
        height: 280
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

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        text: {
                            switch (backend.state) {
                            case "preparing": return qsTr("Preparing playback")
                            case "playing": return qsTr("Reading")
                            case "paused": return qsTr("Paused")
                            case "awaitingRoute": return qsTr("Choose a voice")
                            case "finished": return qsTr("Finished")
                            default: return "Flow"
                            }
                        }
                        font.bold: true
                        Accessible.name: text
                    }
                    Item { Layout.fillWidth: true }
                    ComboBox {
                        id: overridePicker
                        visible: root.activePlaybackState
                        Layout.maximumWidth: 150
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
                    Button {
                        text: qsTr("Stop")
                        Accessible.name: qsTr("Stop reading")
                        Accessible.description: qsTr("Stop reading and close the Flow popup")
                        onClicked: backend.stop()
                    }
                }

                ColumnLayout {
                    visible: (backend.text_language_override !== "" && backend.override_needs_route)
                        || backend.manual_route_needed
                    Layout.fillWidth: true
                    spacing: 8

                    Label {
                        visible: backend.manual_route_needed
                        Layout.fillWidth: true
                        maximumLineCount: 2
                        elide: Text.ElideRight
                        wrapMode: Text.WordWrap
                        text: backend.manual_route_sentence_text
                        Accessible.name: qsTr("Sentence requiring a voice choice")
                    }
                    ComboBox {
                        id: overrideRoutePicker
                        property string chosenRouteId: ""
                        onVisibleChanged: if (!visible) chosenRouteId = ""
                        Layout.maximumWidth: 260
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
                }

                Label {
                    visible: backend.state === "message"
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: backend.message
                }

                Label {
                    visible: backend.state !== "message"
                    Layout.fillWidth: true
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    wrapMode: Text.WordWrap
                    textFormat: settings.wordHighlightingEnabled ? Text.RichText : Text.PlainText
                    text: settings.wordHighlightingEnabled
                        ? root.highlightedText()
                        : root.escapedHtml(backend.playback_text)
                    Accessible.name: qsTr("Selected text being read")
                }

                ScrollView {
                    visible: popup.showLanguages
                        && root.detectedLanguages.length > 0
                        && (backend.state === "playing" || backend.state === "paused"
                            || backend.state === "awaitingRoute")
                    Layout.fillWidth: true
                    Layout.maximumHeight: 180
                    clip: true

                    Column {
                        width: parent.width
                        spacing: 8

                        Repeater {
                            model: root.detectedLanguages

                            RowLayout {
                                required property var modelData
                                width: parent.width

                                Label {
                                    text: root.languageName(modelData)
                                    font.bold: true
                                    font.pixelSize: 12
                                }
                                Item { Layout.fillWidth: true }
                                ComboBox {
                                    id: languageRoutePicker
                                    Layout.maximumWidth: 220
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
                                    Accessible.name: qsTr("Read all %1 sentences as").arg(root.languageName(modelData))
                                }
                            }
                        }
                    }
                }

                Label {
                    visible: backend.state === "awaitingRoute"
                        && (backend.manual_route_needed
                            || (backend.override_needs_route && backend.text_language_override !== ""))
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12
                    opacity: 0.75
                    text: backend.manual_route_needed
                        ? qsTr("Choose how Flow should read this sentence before playback starts.")
                        : qsTr("Choose how Flow should read this selection before playback starts.")
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
                        Layout.preferredWidth: 44
                    }
                }

                Button {
                    visible: backend.state === "playing" || backend.state === "paused"
                    highlighted: true
                    text: backend.state === "paused" ? qsTr("Resume") : qsTr("Pause")
                    Accessible.name: backend.state === "paused"
                        ? qsTr("Resume reading") : qsTr("Pause reading")
                    onClicked: backend.pause_or_resume()
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

        Component.onCompleted: {
            setX(Math.round((Screen.width - width) / 2))
            setY(Math.round((Screen.height - height) / 2))
        }

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
                    title: qsTr("Access")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: qsTr("Global hotkey") }
                            ComboBox {
                                Layout.fillWidth: true
                                model: [
                                    { value: "altSuperR", label: hotKeyTitle() },
                                    { value: "altSuperSpace", label: qsTr("Alt+Win+Space") },
                                    { value: "controlAltR", label: qsTr("Ctrl+Alt+R") }
                                ]
                                textRole: "label"
                                valueRole: "value"
                                currentIndex: model.findIndex(function(item) { return item.value === settings.hotKey })
                                onActivated: backend.update_setting("hotKey", currentValue)
                            }
                        }
                        CheckBox {
                            visible: settings.speechSource === "google"
                            text: qsTr("Highlight spoken words")
                            checked: settings.wordHighlightingEnabled
                            onToggled: backend.update_setting("wordHighlightingEnabled", checked ? "true" : "false")
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: backend.shortcut_status.indexOf("Global shortcut:") === 0
                                ? palette.mid : "red"
                            text: backend.shortcut_status
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: qsTr("Flow reads only the selection that Windows UI Automation exposes when you trigger it.")
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
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: qsTr("Choose a fallback voice, then add languages that need their own voice. Detection stays on this device.")
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
                                id: routeFrame
                                required property var modelData
                                Layout.fillWidth: true
                                property bool expanded: false

                                ColumnLayout {
                                    anchors.fill: parent
                                    Button {
                                        text: root.languageName(routeFrame.modelData.languageTag) + " · " + (
                                            settings.speechSource === "system"
                                                ? (routeFrame.modelData.systemVoiceName || "System default voice")
                                                : settings.speechSource === "azure"
                                                    ? (routeFrame.modelData.azureVoiceName || "Fallback Azure voice")
                                                    : (routeFrame.modelData.googleVoiceName || "Google default voice"))
                                        font.bold: true
                                        flat: true
                                        onClicked: routeFrame.expanded = !routeFrame.expanded
                                    }
                                    ComboBox {
                                        id: systemVoicePicker
                                        visible: routeFrame.expanded && settings.speechSource === "system"
                                        Layout.fillWidth: true
                                        model: ["Desktop default voice"].concat(root.voicesFor(routeFrame.modelData.languageTag))
                                        currentIndex: routeFrame.modelData.systemVoiceName
                                            ? Math.max(0, model.indexOf(routeFrame.modelData.systemVoiceName))
                                            : 0
                                        onActivated: backend.update_route(routeFrame.modelData.id, "systemVoiceName",
                                            currentIndex === 0 ? "" : currentText)
                                    }
                                    ComboBox {
                                        id: routeAzureVoicePicker
                                        visible: routeFrame.expanded && settings.speechSource === "azure"
                                        Layout.fillWidth: true
                                        model: root.azureVoicesFor(routeFrame.modelData.languageTag, false)
                                        currentIndex: Math.max(0, model.indexOf(routeFrame.modelData.azureVoiceName || ""))
                                        displayText: currentText || "Choose an Azure voice"
                                        onActivated: backend.update_route(routeFrame.modelData.id, "azureVoiceName", currentText)
                                    }
                                    ComboBox {
                                        id: routeGoogleVoicePicker
                                        visible: routeFrame.expanded && settings.speechSource === "google"
                                        Layout.fillWidth: true
                                        model: ["Google default voice"].concat(root.googleVoicesFor(routeFrame.modelData.languageTag))
                                        currentIndex: routeFrame.modelData.googleVoiceName
                                            ? Math.max(0, model.indexOf(routeFrame.modelData.googleVoiceName))
                                            : 0
                                        onActivated: backend.update_route(routeFrame.modelData.id, "googleVoiceName",
                                            currentIndex === 0 ? "" : currentText)
                                    }
                                    RowLayout {
                                        visible: routeFrame.expanded
                                        Label { text: qsTr("Speed") }
                                        ComboBox {
                                            id: routeSpeedPicker
                                            Layout.fillWidth: true
                                            property var speeds: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.25, 3.5, 3.75, 4.0]
                                            model: [qsTr("Same as Language Flow")].concat(
                                                speeds.map(function(speed) { return Number(speed.toFixed(2)).toString() + "×" }))
                                            currentIndex: routeFrame.modelData.playbackSpeed !== null
                                                ? 1 + speeds.indexOf(routeFrame.modelData.playbackSpeed)
                                                : 0
                                            onActivated: backend.update_route(routeFrame.modelData.id, "playbackSpeed",
                                                currentIndex === 0 ? "" : String(speeds[currentIndex - 1]))
                                        }
                                    }
                                    Button {
                                        visible: routeFrame.expanded
                                        text: qsTr("Remove language")
                                        onClicked: backend.remove_language(routeFrame.modelData.id)
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
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: qsTr("Reading source") }
                            ComboBox {
                                Layout.fillWidth: true
                                model: [
                                    { value: "system", label: qsTr("System voice") },
                                    { value: "azure", label: qsTr("Azure voice") },
                                    { value: "google", label: qsTr("Google Cloud voice") }
                                ]
                                textRole: "label"
                                valueRole: "value"
                                currentIndex: settings.speechSource === "azure" ? 1
                                    : settings.speechSource === "google" ? 2 : 0
                                onActivated: backend.update_setting("speechSource", currentValue)
                            }
                        }
                        Label {
                            visible: settings.speechSource === "system"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: qsTr("System voices and language detection stay on this PC.")
                        }

                        Label {
                            visible: settings.speechSource === "azure" && !!settings.azureEndpoint
                            text: settings.azureEndpoint ? "Configured for " + settings.azureEndpoint : ""
                        }
                        TextField {
                            id: endpointField
                            visible: settings.speechSource === "azure" && !settings.azureEndpoint
                            Layout.fillWidth: true
                            placeholderText: qsTr("Region or HTTPS endpoint")
                            Accessible.name: placeholderText
                        }
                        TextField {
                            id: keyField
                            visible: settings.speechSource === "azure" && !settings.azureEndpoint
                            Layout.fillWidth: true
                            placeholderText: qsTr("Azure Speech subscription key")
                            echoMode: TextInput.Password
                            Accessible.name: placeholderText
                        }
                        Button {
                            visible: settings.speechSource === "azure" && !settings.azureEndpoint
                            text: qsTr("Save Azure configuration")
                            enabled: endpointField.text.trim().length > 0 && keyField.text.trim().length > 0
                            onClicked: {
                                backend.save_azure_configuration(endpointField.text, keyField.text)
                                keyField.clear()
                            }
                        }
                        RowLayout {
                            visible: settings.speechSource === "azure" && !!settings.azureEndpoint
                            Button {
                                text: qsTr("Refresh Azure voices")
                                onClicked: backend.refresh_azure_voices()
                            }
                            Button {
                                text: qsTr("Remove Azure configuration")
                                onClicked: backend.clear_azure_configuration()
                            }
                        }
                        Label {
                            visible: settings.speechSource === "azure"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: qsTr("Azure sends selected text to your Speech resource to synthesize it. The subscription key stays in Windows Credential Manager.")
                        }
                        Button {
                            visible: settings.speechSource === "azure"
                            flat: true
                            text: qsTr("Open Azure Speech resources")
                            onClicked: Qt.openUrlExternally("https://portal.azure.com/#view/HubsExtension/BrowseResource/resourceType/Microsoft.CognitiveServices%2Faccounts")
                        }

                        Label {
                            visible: settings.speechSource === "google" && settings.googleApiKeyConfigured
                            text: qsTr("Google Cloud API key configured")
                        }
                        TextField {
                            id: googleKeyField
                            visible: settings.speechSource === "google" && !settings.googleApiKeyConfigured
                            Layout.fillWidth: true
                            placeholderText: qsTr("Google Cloud API key")
                            echoMode: TextInput.Password
                            Accessible.name: placeholderText
                        }
                        Button {
                            visible: settings.speechSource === "google" && !settings.googleApiKeyConfigured
                            text: qsTr("Save Google configuration")
                            enabled: googleKeyField.text.trim().length > 0
                            onClicked: {
                                backend.save_google_configuration(googleKeyField.text)
                                googleKeyField.clear()
                            }
                        }
                        RowLayout {
                            visible: settings.speechSource === "google" && settings.googleApiKeyConfigured
                            Button {
                                text: qsTr("Refresh Google voices")
                                onClicked: backend.refresh_google_voices()
                            }
                            Button {
                                text: qsTr("Remove Google configuration")
                                onClicked: backend.clear_google_configuration()
                            }
                        }
                        Label {
                            visible: settings.speechSource === "google"
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            opacity: 0.75
                            text: qsTr("Google receives selected text only when Google Cloud is selected. The API key stays in Windows Credential Manager. Restrict it to the Cloud Text-to-Speech API.")
                        }
                        Button {
                            visible: settings.speechSource === "google"
                            flat: true
                            text: qsTr("Open Google Cloud API credentials")
                            onClicked: Qt.openUrlExternally("https://console.cloud.google.com/apis/credentials")
                        }
                        Button {
                            visible: settings.speechSource === "google"
                            flat: true
                            text: qsTr("Enable Cloud Text-to-Speech API")
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
                    title: qsTr("Playback")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    ColumnLayout {
                        anchors.fill: parent
                        Button {
                            text: qsTr("Play test voice")
                            onClicked: backend.play_test_voice()
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: qsTr("Same selection hotkey") }
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
                        RowLayout {
                            Label { text: qsTr("Popup dismisses after %1 seconds").arg(Math.round(dismissSlider.value)) }
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
                            text: qsTr("Selections longer than about ten minutes are not read.")
                        }
                    }
                }

                Item { Layout.preferredHeight: 6 }

                GroupBox {
                    title: qsTr("Privacy")
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.rightMargin: 20

                    Label {
                        anchors.fill: parent
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        text: qsTr("Flow keeps selected text only while the playback popup is visible. System language detection and voices are on-device. A cloud provider receives text only when that provider is selected.")
                    }
                }
            }
        }
    }
}
