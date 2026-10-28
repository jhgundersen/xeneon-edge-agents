import QtQuick
import QtQuick.Effects
import "../state/ThemePalette.js" as ThemePalette

// Now-playing dashboard. It renders the daemon's Spotify snapshot and asks
// for one of three typed controls; it never talks to Spotify itself.
Item {
    id: root

    property var spotify: ({"available": false})
    property var theme: ThemePalette.fallback
    property bool reducedMotion: false
    property bool canOpenSpotify: false

    signal playPauseRequested()
    signal nextRequested()
    signal previousRequested()
    signal openRequested()
    signal interacted()

    readonly property bool available: spotify !== null
        && spotify !== undefined && spotify.available === true
    readonly property bool playing: available && spotify.status === "playing"
    readonly property color accent: theme.green
    readonly property color readableAccent: ThemePalette.ensureContrast(
        String(accent),
        String(theme.surface),
        4.5
    )
    readonly property color readablePrimary: ThemePalette.ensureContrast(
        String(theme.textPrimary),
        String(theme.surface),
        7
    )
    readonly property color readableMuted: ThemePalette.ensureContrast(
        String(theme.textMuted),
        String(theme.surface),
        4.5
    )

    // The daemon publishes position only on track, state, or seek changes;
    // between snapshots the bar advances from the last sampled position.
    property double sampledPositionMs: 0
    property double sampledAtMs: Date.now()
    property double nowMs: Date.now()
    readonly property double lengthMs: available ? Number(spotify.length_ms) : 0
    readonly property double positionMs: !available
        ? 0
        : playing
            ? Math.min(lengthMs, sampledPositionMs + nowMs - sampledAtMs)
            : sampledPositionMs
    readonly property real progress: lengthMs > 0 ? positionMs / lengthMs : 0

    onSpotifyChanged: {
        // Read the new value directly: `available` may not have re-evaluated
        // yet when this handler runs.
        var live = spotify !== null && spotify !== undefined
            && spotify.available === true
        sampledPositionMs = live ? Number(spotify.position_ms) : 0
        sampledAtMs = Date.now()
        nowMs = sampledAtMs
    }

    function clock(milliseconds) {
        var totalSeconds = Math.max(0, Math.floor(milliseconds / 1000))
        var minutes = Math.floor(totalSeconds / 60)
        var seconds = totalSeconds % 60
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }

    Timer {
        interval: root.reducedMotion ? 1000 : 250
        repeat: true
        running: root.playing && root.visible
        onTriggered: root.nowMs = Date.now()
    }

    Rectangle {
        id: card

        objectName: "spotifyCard"
        anchors.fill: parent
        radius: 18
        color: root.theme.surface
        border.width: 1
        border.color: Qt.alpha(root.accent, root.available ? 0.58 : 0.3)
    }

    Rectangle {
        anchors {
            fill: parent
            margins: 4
        }
        radius: 15
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(root.accent, 0.12)
    }

    Item {
        id: art

        objectName: "spotifyArt"
        anchors {
            left: parent.left
            top: parent.top
            bottom: parent.bottom
            margins: 28
        }
        width: height
        visible: root.available

        Rectangle {
            anchors.fill: parent
            radius: 14
            color: root.theme.surfaceRaised
            border.width: 1
            border.color: Qt.alpha(root.accent, 0.3)
        }

        Image {
            id: artImage

            anchors.fill: parent
            source: root.available ? String(root.spotify.art_url || "") : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: false
        }

        Rectangle {
            id: artMask

            anchors.fill: parent
            radius: 14
            visible: false
            layer.enabled: true
        }

        MultiEffect {
            anchors.fill: parent
            source: artImage
            maskEnabled: true
            maskSource: artMask
            visible: artImage.status === Image.Ready
        }
    }

    Item {
        id: details

        anchors {
            left: art.right
            right: parent.right
            top: parent.top
            bottom: parent.bottom
            leftMargin: 44
            rightMargin: 44
            topMargin: 34
            bottomMargin: 30
        }
        visible: root.available

        Row {
            id: statusRow

            spacing: 14

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "NOW PLAYING  //  SPOTIFY"
                textFormat: Text.PlainText
                color: root.readableMuted
                font {
                    family: "monospace"
                    pixelSize: 13
                    weight: Font.DemiBold
                    letterSpacing: 0.8
                }
            }

            Rectangle {
                width: statusText.implicitWidth + 24
                height: 28
                radius: 14
                anchors.verticalCenter: parent.verticalCenter
                color: ThemePalette.mixColors(
                    String(root.theme.surface),
                    String(root.accent),
                    0.14
                )
                border.width: 1
                border.color: Qt.alpha(root.accent, 0.62)

                Text {
                    id: statusText

                    objectName: "spotifyStatus"
                    anchors.centerIn: parent
                    text: root.playing
                        ? "PLAYING"
                        : root.available && root.spotify.status === "paused"
                            ? "PAUSED"
                            : "STOPPED"
                    textFormat: Text.PlainText
                    color: root.readableAccent
                    font {
                        family: "monospace"
                        pixelSize: 12
                        weight: Font.DemiBold
                        letterSpacing: 0.8
                    }
                }
            }
        }

        Text {
            id: titleText

            objectName: "spotifyTitle"
            anchors {
                left: parent.left
                right: parent.right
                top: statusRow.bottom
                topMargin: 26
            }
            text: root.available ? String(root.spotify.title || "") : ""
            textFormat: Text.PlainText
            color: root.readablePrimary
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 46
                weight: Font.Bold
            }
        }

        Text {
            id: artistText

            objectName: "spotifyArtist"
            anchors {
                left: parent.left
                right: parent.right
                top: titleText.bottom
                topMargin: 12
            }
            text: root.available ? String(root.spotify.artist || "") : ""
            textFormat: Text.PlainText
            color: root.readableAccent
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 24
                weight: Font.DemiBold
                letterSpacing: 0.5
            }
        }

        Text {
            anchors {
                left: parent.left
                right: parent.right
                top: artistText.bottom
                topMargin: 8
            }
            text: root.available ? String(root.spotify.album || "") : ""
            textFormat: Text.PlainText
            color: root.readableMuted
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 16
                letterSpacing: 0.3
            }
        }

        Item {
            id: progressBlock

            anchors {
                left: parent.left
                right: parent.right
                bottom: controls.top
                bottomMargin: 30
            }
            height: 32

            Rectangle {
                id: track

                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                }
                height: 6
                radius: 3
                color: Qt.alpha(root.accent, 0.16)

                Rectangle {
                    objectName: "spotifyProgressFill"
                    width: track.width * root.progress
                    height: parent.height
                    radius: 3
                    color: root.accent
                }
            }

            Text {
                objectName: "spotifyElapsed"
                anchors {
                    left: parent.left
                    bottom: parent.bottom
                }
                text: root.clock(root.positionMs)
                textFormat: Text.PlainText
                color: root.readableMuted
                font {
                    family: "monospace"
                    pixelSize: 14
                    letterSpacing: 0.5
                }
            }

            Text {
                anchors {
                    right: parent.right
                    bottom: parent.bottom
                }
                text: root.clock(root.lengthMs)
                textFormat: Text.PlainText
                color: root.readableMuted
                font {
                    family: "monospace"
                    pixelSize: 14
                    letterSpacing: 0.5
                }
            }
        }

        Row {
            id: controls

            anchors {
                left: parent.left
                bottom: parent.bottom
            }
            spacing: 14

            DesktopAppButton {
                objectName: "spotifyPrevious"
                width: 180
                height: 64
                label: "PREVIOUS"
                detail: "SPOTIFY"
                accent: root.accent
                theme: root.theme
                enabled: root.available && root.spotify.can_control
                    && root.spotify.can_go_previous
                onInteracted: root.interacted()
                onTriggered: root.previousRequested()
            }

            DesktopAppButton {
                objectName: "spotifyPlayPause"
                width: 240
                height: 64
                label: root.playing ? "PAUSE" : "PLAY"
                detail: "SPOTIFY"
                accent: root.accent
                theme: root.theme
                enabled: root.available && root.spotify.can_control
                onInteracted: root.interacted()
                onTriggered: root.playPauseRequested()
            }

            DesktopAppButton {
                objectName: "spotifyNext"
                width: 180
                height: 64
                label: "NEXT"
                detail: "SPOTIFY"
                accent: root.accent
                theme: root.theme
                enabled: root.available && root.spotify.can_control
                    && root.spotify.can_go_next
                onInteracted: root.interacted()
                onTriggered: root.nextRequested()
            }
        }
    }

    Column {
        objectName: "spotifyOffline"
        anchors.centerIn: parent
        spacing: 14
        visible: !root.available

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "SPOTIFY  //  OFFLINE"
            textFormat: Text.PlainText
            color: root.readablePrimary
            font {
                family: "monospace"
                pixelSize: 30
                weight: Font.Bold
                letterSpacing: 1.2
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Start Spotify on this computer to see what is playing."
            textFormat: Text.PlainText
            color: root.readableMuted
            font {
                family: "monospace"
                pixelSize: 15
                letterSpacing: 0.4
            }
        }

        DesktopAppButton {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 220
            height: 56
            visible: root.canOpenSpotify
            label: "OPEN SPOTIFY"
            accent: root.accent
            theme: root.theme
            onInteracted: root.interacted()
            onTriggered: root.openRequested()
        }
    }
}
