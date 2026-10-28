import QtQuick
import "../state/ThemePalette.js" as ThemePalette

// Basecamp dashboard: one configured card table as lanes, plus a Hey! inbox
// strip. It renders the daemon's snapshot and asks to open items by id; the
// URLs never reach the portal.
Item {
    id: root

    property var basecamp: ({"available": false})
    property var theme: ThemePalette.fallback
    property int boardIndex: 0

    signal openRequested(string itemId)
    signal interacted()

    readonly property bool available: basecamp !== null
        && basecamp !== undefined && basecamp.available === true
    readonly property var boards: available ? basecamp.boards : []
    readonly property var board: boards.length > 0
        ? boards[Math.min(boardIndex, boards.length - 1)]
        : null
    readonly property var lanes: board !== null && board.available
        ? board.lanes
        : []
    readonly property real stripWidth: 470
    readonly property real cardHeight: 92
    readonly property real cardSpacing: 10
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

    function roleColor(role) {
        return theme[role] || theme.accent
    }

    function readable(color, background) {
        return ThemePalette.ensureContrast(String(color), String(background), 4.5)
    }

    function ago(iso) {
        var at = Date.parse(String(iso || ""))
        if (!isFinite(at))
            return ""
        var minutes = Math.max(0, Math.floor((Date.now() - at) / 60000))
        if (minutes < 60)
            return minutes + "M"
        if (minutes < 60 * 24)
            return Math.floor(minutes / 60) + "H"
        return Math.floor(minutes / (60 * 24)) + "D"
    }

    function kindLabel(kind) {
        switch (kind) {
        case "comment":
            return "COMMENT"
        case "announcement":
            return "NEWS"
        case "done":
            return "DONE"
        case "boost":
            return "BOOST"
        default:
            return "UPDATE"
        }
    }

    function kindRole(kind) {
        switch (kind) {
        case "comment":
            return "blue"
        case "announcement":
            return "accent"
        case "done":
            return "green"
        case "boost":
            return "magenta"
        default:
            return "accent"
        }
    }

    function cardMeta(card) {
        var parts = []
        if (card.assignees.length > 0)
            parts.push(card.assignees.map(function(name) {
                return String(name).split(" ")[0]
            }).join(", "))
        if (card.due_on)
            parts.push("DUE " + card.due_on)
        if (card.comments > 0)
            parts.push(card.comments + (card.comments === 1 ? " COMMENT" : " COMMENTS"))
        return parts.join("  ·  ")
    }

    function openItem(itemId) {
        interacted()
        openRequested(String(itemId))
    }

    // Board switcher and parked counts.
    Item {
        id: boardBar

        anchors {
            left: parent.left
            right: strip.left
            top: parent.top
            rightMargin: 20
        }
        height: 40
        visible: root.available

        Row {
            id: boardTabs

            spacing: 10
            anchors.verticalCenter: parent.verticalCenter

            Repeater {
                model: root.boards.length > 1 ? root.boards : []

                Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool selected: index === root.boardIndex

                    objectName: "basecampBoardTab_" + index
                    width: tabText.implicitWidth + 32
                    height: 34
                    radius: 10
                    color: tabTap.pressed
                        ? root.theme.surfacePressed
                        : root.theme.surfaceRaised
                    border.width: 1
                    border.color: selected ? root.theme.accent : root.theme.border

                    Text {
                        id: tabText
                        anchors.centerIn: parent
                        text: String(modelData.label).toUpperCase()
                        textFormat: Text.PlainText
                        color: selected ? root.readablePrimary : root.readableMuted
                        font {
                            family: "monospace"
                            pixelSize: 11
                            weight: Font.DemiBold
                            letterSpacing: 0.5
                        }
                    }

                    function activate() {
                        root.interacted()
                        root.boardIndex = index
                        return true
                    }

                    Accessible.role: Accessible.Button
                    Accessible.name: "Show card table " + String(modelData.label)
                    Accessible.onPressAction: activate()

                    TapHandler {
                        id: tabTap
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: parent.activate()
                    }
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.boards.length === 1
                text: root.board !== null
                    ? String(root.board.label).toUpperCase() + "  //  CARD TABLE"
                    : ""
                textFormat: Text.PlainText
                color: root.readableMuted
                font {
                    family: "monospace"
                    pixelSize: 13
                    weight: Font.DemiBold
                    letterSpacing: 0.8
                }
            }
        }

        Text {
            objectName: "basecampParked"
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            visible: root.board !== null && root.board.available
            text: root.board === null
                ? ""
                : "NOT NOW // " + root.board.not_now + "    DONE // " + root.board.done
            textFormat: Text.PlainText
            color: root.readableMuted
            font {
                family: "monospace"
                pixelSize: 12
                weight: Font.DemiBold
                letterSpacing: 0.7
            }
        }
    }

    Row {
        id: laneRow

        objectName: "basecampLanes"
        anchors {
            left: parent.left
            right: strip.left
            top: boardBar.bottom
            bottom: parent.bottom
            topMargin: 10
            rightMargin: 20
        }
        spacing: 16
        visible: root.available && root.lanes.length > 0

        readonly property real laneWidth: (
            width - spacing * (root.lanes.length - 1)
        ) / Math.max(1, root.lanes.length)

        Repeater {
            model: root.lanes

            Item {
                id: lane

                required property var modelData
                required property int index
                readonly property color accent: root.roleColor(modelData.color)
                readonly property int fits: Math.max(
                    1,
                    Math.floor(
                        (height - laneHeader.height - 30 + root.cardSpacing)
                            / (root.cardHeight + root.cardSpacing)
                    )
                )
                readonly property int shown: Math.min(fits, modelData.cards.length)

                objectName: "basecampLane_" + index
                width: laneRow.laneWidth
                height: laneRow.height

                Row {
                    id: laneHeader

                    height: 26
                    spacing: 10

                    Rectangle {
                        width: 10
                        height: 10
                        radius: 5
                        anchors.verticalCenter: parent.verticalCenter
                        color: lane.accent
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: lane.width - 20
                        text: String(lane.modelData.title).toUpperCase()
                            + "  //  " + lane.modelData.total
                        textFormat: Text.PlainText
                        color: root.readableMuted
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 12
                            weight: Font.DemiBold
                            letterSpacing: 0.7
                        }
                    }
                }

                Column {
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: laneHeader.bottom
                        topMargin: 8
                    }
                    spacing: root.cardSpacing

                    Repeater {
                        model: lane.shown

                        Rectangle {
                            id: card

                            required property int index
                            readonly property var entry: lane.modelData.cards[index]

                            objectName: "basecampCard_" + lane.index + "_" + index
                            width: parent.width
                            height: root.cardHeight
                            radius: 14
                            color: cardTap.pressed
                                ? root.theme.surfacePressed
                                : root.theme.surface
                            border.width: 1
                            border.color: Qt.alpha(lane.accent, 0.5)

                            Rectangle {
                                anchors {
                                    left: parent.left
                                    top: parent.top
                                    bottom: parent.bottom
                                    margins: 12
                                }
                                width: 3
                                radius: 1.5
                                color: lane.accent
                            }

                            Text {
                                id: cardTitle

                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    top: parent.top
                                    leftMargin: 26
                                    rightMargin: 16
                                    topMargin: 12
                                }
                                text: String(card.entry.title)
                                textFormat: Text.PlainText
                                color: root.readablePrimary
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 15
                                    weight: Font.Bold
                                }
                            }

                            Text {
                                anchors {
                                    left: cardTitle.left
                                    right: cardTitle.right
                                    bottom: parent.bottom
                                    bottomMargin: 11
                                }
                                text: root.cardMeta(card.entry).toUpperCase()
                                textFormat: Text.PlainText
                                color: root.readableMuted
                                elide: Text.ElideRight
                                font {
                                    family: "monospace"
                                    pixelSize: 10
                                    weight: Font.DemiBold
                                    letterSpacing: 0.5
                                }
                            }

                            function activate() {
                                if (!root.enabled)
                                    return false
                                root.openItem(card.entry.id)
                                return true
                            }

                            Accessible.role: Accessible.Button
                            Accessible.name: "Open card " + String(card.entry.title)
                            Accessible.onPressAction: activate()

                            TapHandler {
                                id: cardTap
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: card.activate()
                            }
                        }
                    }

                    Text {
                        visible: lane.modelData.total > lane.shown
                        text: "+" + (lane.modelData.total - lane.shown) + " MORE"
                        textFormat: Text.PlainText
                        color: root.readableMuted
                        font {
                            family: "monospace"
                            pixelSize: 11
                            weight: Font.DemiBold
                            letterSpacing: 0.7
                        }
                    }
                }
            }
        }
    }

    Text {
        anchors.centerIn: laneRow
        visible: root.available && root.lanes.length === 0
        text: root.boards.length === 0
            ? "NO CARD TABLE CONFIGURED"
            : root.board !== null && !root.board.available
                ? "CARD TABLE UNAVAILABLE"
                : "NO OPEN COLUMNS"
        textFormat: Text.PlainText
        color: root.readableMuted
        font {
            family: "monospace"
            pixelSize: 15
            weight: Font.DemiBold
            letterSpacing: 0.8
        }
    }

    // Hey! inbox strip.
    Rectangle {
        id: strip

        objectName: "basecampInbox"
        anchors {
            right: parent.right
            top: parent.top
            bottom: parent.bottom
        }
        width: root.available ? root.stripWidth : 0
        visible: root.available
        radius: 18
        color: root.theme.surface
        border.width: 1
        border.color: Qt.alpha(root.theme.accent, 0.42)

        Text {
            id: stripTitle

            objectName: "basecampUnread"
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 20
            }
            text: "HEY!  //  "
                + (root.available ? root.basecamp.unread_count : 0)
                + (root.available && root.basecamp.unreads_capped ? "+" : "")
                + " UNREAD"
            textFormat: Text.PlainText
            color: root.readablePrimary
            font {
                family: "monospace"
                pixelSize: 18
                weight: Font.Bold
                letterSpacing: 1
            }
        }

        Column {
            anchors {
                left: parent.left
                right: parent.right
                top: stripTitle.bottom
                bottom: parent.bottom
                leftMargin: 14
                rightMargin: 14
                topMargin: 14
                bottomMargin: 14
            }
            spacing: 6
            clip: true

            Repeater {
                model: root.available ? root.basecamp.notifications : []

                Rectangle {
                    id: row

                    required property var modelData
                    required property int index
                    readonly property color kindColor:
                        root.roleColor(root.kindRole(modelData.kind))

                    objectName: "basecampNotification_" + index
                    width: parent.width
                    height: 54
                    radius: 10
                    color: rowTap.pressed ? root.theme.surfacePressed : "transparent"

                    Rectangle {
                        id: kindPill

                        anchors {
                            left: parent.left
                            top: parent.top
                            leftMargin: 6
                            topMargin: 8
                        }
                        width: 78
                        height: 20
                        radius: 10
                        color: ThemePalette.mixColors(
                            String(root.theme.surface),
                            String(row.kindColor),
                            0.14
                        )
                        border.width: 1
                        border.color: Qt.alpha(row.kindColor, 0.6)

                        Text {
                            anchors.centerIn: parent
                            text: root.kindLabel(row.modelData.kind)
                            textFormat: Text.PlainText
                            color: root.readable(row.kindColor, root.theme.surface)
                            font {
                                family: "monospace"
                                pixelSize: 9
                                weight: Font.DemiBold
                                letterSpacing: 0.6
                            }
                        }
                    }

                    Text {
                        anchors {
                            left: kindPill.right
                            right: parent.right
                            verticalCenter: kindPill.verticalCenter
                            leftMargin: 10
                            rightMargin: 6
                        }
                        text: String(row.modelData.title)
                        textFormat: Text.PlainText
                        color: root.readablePrimary
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 13
                            weight: Font.DemiBold
                        }
                    }

                    Text {
                        anchors {
                            left: parent.left
                            right: parent.right
                            bottom: parent.bottom
                            leftMargin: 6
                            rightMargin: 6
                            bottomMargin: 6
                        }
                        text: [
                            row.modelData.project,
                            row.modelData.creator,
                            root.ago(row.modelData.unread_at)
                        ].filter(function(part) { return String(part) !== "" })
                            .join("  ·  ").toUpperCase()
                        textFormat: Text.PlainText
                        color: root.readableMuted
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 10
                            letterSpacing: 0.4
                        }
                    }

                    function activate() {
                        if (!root.enabled)
                            return false
                        root.openItem(row.modelData.id)
                        return true
                    }

                    Accessible.role: Accessible.Button
                    Accessible.name: "Open " + String(row.modelData.title)
                    Accessible.onPressAction: activate()

                    TapHandler {
                        id: rowTap
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: row.activate()
                    }
                }
            }
        }
    }

    Column {
        objectName: "basecampOffline"
        anchors.centerIn: parent
        spacing: 14
        visible: !root.available

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "BASECAMP  //  OFFLINE"
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
            text: "Sign in with `basecamp login` on this computer."
            textFormat: Text.PlainText
            color: root.readableMuted
            font {
                family: "monospace"
                pixelSize: 15
                letterSpacing: 0.4
            }
        }
    }
}
