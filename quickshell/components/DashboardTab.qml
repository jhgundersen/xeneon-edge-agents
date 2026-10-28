import QtQuick
import "../state/ThemePalette.js" as ThemePalette

// Header tab for one enabled dashboard: its name plus a short live status.
Rectangle {
    id: root

    property string label: ""
    property string detail: ""
    property bool selected: false
    property var theme: ThemePalette.fallback
    property color accent: theme.accent
    signal triggered()
    signal interacted()

    radius: 14
    color: tapHandler.pressed
        ? theme.surfacePressed
        : selected
            ? ThemePalette.mixColors(String(theme.surfaceRaised), String(accent), 0.12)
            : theme.surfaceRaised
    border.width: selected ? 2 : 1
    border.color: Qt.alpha(accent, selected ? 0.95 : 0.4)
    opacity: enabled ? 1 : 0.42

    function activate() {
        if (!root.enabled)
            return false
        interacted()
        triggered()
        return true
    }

    Accessible.role: Accessible.Button
    Accessible.ignored: !root.enabled
    Accessible.name: label + " dashboard"
    Accessible.description: selected ? "Showing. " + detail : detail
    Accessible.onPressAction: root.activate()

    Column {
        anchors.centerIn: parent
        spacing: 1

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, root.width - 10)
            text: root.label
            textFormat: Text.PlainText
            color: root.selected ? root.theme.textPrimary : root.theme.textMuted
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 15
                weight: Font.Bold
                letterSpacing: 0.6
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, root.width - 10)
            text: root.detail
            textFormat: Text.PlainText
            color: ThemePalette.ensureContrast(
                String(root.accent),
                String(root.theme.surfaceRaised),
                4.5
            )
            elide: Text.ElideRight
            font {
                family: "monospace"
                pixelSize: 9
                weight: Font.DemiBold
                letterSpacing: 0.7
            }
        }
    }

    TapHandler {
        id: tapHandler
        enabled: root.enabled
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.activate()
    }
}
