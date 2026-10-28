import QtQuick
import "../state/ThemePalette.js" as ThemePalette

// Header clock. Digits roll into place when they change and a hairline sweeps
// across the card over each minute; both are driven by Qt animations rather
// than per-second steps, so motion stays smooth. Reduced motion jumps.
Rectangle {
    id: root

    property var theme: ThemePalette.fallback
    property bool reducedMotion: false
    property date now: new Date()

    readonly property string time: Qt.formatTime(now, "HH:mm")
    readonly property color accent: theme.accent
    readonly property color readablePrimary: ThemePalette.ensureContrast(
        String(theme.textPrimary),
        String(theme.surfaceRaised),
        7
    )
    readonly property color readableMuted: ThemePalette.ensureContrast(
        String(theme.textMuted),
        String(theme.surfaceRaised),
        4.5
    )
    // 0 at the start of the minute, 1 at its end.
    property real minuteProgress: 0

    radius: 14
    color: theme.surfaceRaised
    border.width: 1
    border.color: Qt.alpha(accent, 0.42)

    Accessible.role: Accessible.StaticText
    Accessible.name: "Time " + time + ", " + Qt.formatDate(now, "dddd d MMMM")

    function syncMinute() {
        var current = new Date()
        var elapsed = current.getSeconds() * 1000 + current.getMilliseconds()
        sweep.stop()
        minuteProgress = elapsed / 60000
        if (!reducedMotion) {
            sweep.from = minuteProgress
            sweep.duration = Math.max(1, 60000 - elapsed)
            sweep.start()
        }
    }

    // The displayed minute only needs a coarse tick; the sweep animates
    // continuously between ticks and is re-anchored when the minute turns.
    Timer {
        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.now = new Date()
    }

    onTimeChanged: syncMinute()
    onReducedMotionChanged: syncMinute()
    Component.onCompleted: syncMinute()

    NumberAnimation {
        id: sweep

        target: root
        property: "minuteProgress"
        to: 1
        easing.type: Easing.Linear
    }

    Row {
        id: digits

        objectName: "clockTime"
        anchors {
            left: parent.left
            verticalCenter: parent.verticalCenter
            leftMargin: 20
            verticalCenterOffset: -2
        }
        spacing: 1

        RollingDigit { digit: root.time.charAt(0); textColor: root.readablePrimary; reduced: root.reducedMotion }
        RollingDigit { digit: root.time.charAt(1); textColor: root.readablePrimary; reduced: root.reducedMotion }

        Text {
            id: colon

            width: 14
            height: parent.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: ":"
            textFormat: Text.PlainText
            color: root.accent
            font {
                family: "monospace"
                pixelSize: 30
                weight: Font.Bold
            }

            // A slow breath rather than a blink.
            SequentialAnimation on opacity {
                running: !root.reducedMotion
                loops: Animation.Infinite
                NumberAnimation {
                    from: 1
                    to: 0.35
                    duration: 1000
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    from: 0.35
                    to: 1
                    duration: 1000
                    easing.type: Easing.InOutSine
                }
            }
        }

        RollingDigit { digit: root.time.charAt(3); textColor: root.readablePrimary; reduced: root.reducedMotion }
        RollingDigit { digit: root.time.charAt(4); textColor: root.readablePrimary; reduced: root.reducedMotion }
    }

    Column {
        anchors {
            right: parent.right
            verticalCenter: parent.verticalCenter
            rightMargin: 20
            verticalCenterOffset: -2
        }
        spacing: 2

        Text {
            objectName: "clockWeekday"
            anchors.right: parent.right
            text: Qt.formatDate(root.now, "dddd").toUpperCase()
            textFormat: Text.PlainText
            color: root.accent
            font {
                family: "monospace"
                pixelSize: 12
                weight: Font.Bold
                letterSpacing: 1.2
            }
        }

        Text {
            objectName: "clockDate"
            anchors.right: parent.right
            text: Qt.formatDate(root.now, "d MMM yyyy").toUpperCase()
            textFormat: Text.PlainText
            color: root.readableMuted
            font {
                family: "monospace"
                pixelSize: 11
                weight: Font.DemiBold
                letterSpacing: 0.8
            }
        }
    }

    // Minute sweep: a faint track with a bright, softly fading head.
    Item {
        id: sweepTrack

        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            leftMargin: 16
            rightMargin: 16
            bottomMargin: 7
        }
        height: 2

        Rectangle {
            anchors.fill: parent
            radius: 1
            color: Qt.alpha(root.accent, 0.14)
        }

        Rectangle {
            objectName: "clockSweep"
            width: sweepTrack.width * root.minuteProgress
            height: parent.height
            radius: 1
            color: Qt.alpha(root.accent, 0.55)
        }

        Rectangle {
            x: sweepTrack.width * root.minuteProgress - width / 2
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: root.accent
            visible: root.minuteProgress > 0
        }
    }

    // One digit that rolls up to its new value: the old glyph slides out the
    // top while the new one slides in from below.
    component RollingDigit: Item {
        id: digitItem

        property string digit: "0"
        property color textColor: "white"
        property bool reduced: false
        property string shown: digit
        property string leaving: ""

        width: glyph.implicitWidth
        height: glyph.implicitHeight
        clip: true

        onDigitChanged: {
            if (digit === shown)
                return
            leaving = shown
            shown = digit
            if (reduced)
                return
            roll.restart()
        }

        Text {
            id: glyph

            text: digitItem.shown
            textFormat: Text.PlainText
            color: digitItem.textColor
            font {
                family: "monospace"
                pixelSize: 30
                weight: Font.Bold
            }
        }

        Text {
            id: outgoing

            y: -digitItem.height
            text: digitItem.leaving
            textFormat: Text.PlainText
            color: digitItem.textColor
            font: glyph.font
        }

        ParallelAnimation {
            id: roll

            NumberAnimation {
                target: glyph
                property: "y"
                from: digitItem.height
                to: 0
                duration: 650
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: outgoing
                property: "y"
                from: 0
                to: -digitItem.height
                duration: 650
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: glyph
                property: "opacity"
                from: 0
                to: 1
                duration: 650
                easing.type: Easing.OutQuad
            }
        }
    }
}
