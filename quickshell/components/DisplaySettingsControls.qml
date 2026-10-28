import QtQuick
import "../state/ThemePalette.js" as ThemePalette

Item {
    id: root

    property bool dimmed: false
    property bool paletteOpen: false
    property bool paletteCustom: false
    property var theme: ThemePalette.fallback

    signal dimToggleRequested()
    signal paletteToggleRequested()

    width: 200
    height: 52

    Row {
        anchors.fill: parent
        spacing: 8

        DisplaySettingButton {
            objectName: "dimSettingButton"
            width: 96
            height: parent.height
            label: "SCREEN"
            stateLabel: root.dimmed ? "MINIMUM" : "NORMAL"
            accent: root.theme.magenta
            theme: root.theme
            checked: root.dimmed
            onToggled: root.dimToggleRequested()
        }

        DisplaySettingButton {
            objectName: "paletteSettingButton"
            width: 96
            height: parent.height
            label: "PALETTE"
            stateLabel: root.paletteOpen
                ? "OPEN"
                : root.paletteCustom
                    ? "CUSTOM"
                    : "THEME"
            accent: root.theme.accent
            theme: root.theme
            checked: root.paletteOpen || root.paletteCustom
            onToggled: root.paletteToggleRequested()
        }
    }
}
