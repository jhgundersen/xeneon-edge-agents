import QtQuick
import "../state/ThemePalette.js" as ThemePalette

// Slack dashboard: one watched channel's recent messages plus a strip of
// unread DMs and @-mentions. It renders the daemon's snapshot and asks to open
// items by id; permalinks and the token never reach the portal.
Item {
    id: root

    property var slack: ({"available": false})
    property var theme: ThemePalette.fallback
    // Directory of thumbnails the daemon cached; empty hides images.
    property string imageDirectory: ""
    property int channelIndex: 0

    signal openRequested(string itemId)
    signal interacted()

    readonly property bool available: slack !== null
        && slack !== undefined && slack.available === true
    readonly property var channels: available ? slack.channels : []
    readonly property var channel: channels.length > 0
        ? channels[Math.min(channelIndex, channels.length - 1)]
        : null
    readonly property var messages: channel !== null && channel.available
        ? channel.messages
        : []
    readonly property real stripWidth: 470
    readonly property color accent: theme.magenta
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
    readonly property color readableAccent: ThemePalette.ensureContrast(
        String(accent),
        String(theme.surface),
        4.5
    )

    // Relative times and "today" follow the clock, not only new snapshots.
    property double nowMs: Date.now()

    Timer {
        interval: 60000
        repeat: true
        running: root.visible
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    function clock(seconds) {
        var at = new Date(Number(seconds) * 1000)
        var today = new Date(root.nowMs)
        var time = Qt.formatTime(at, "HH:mm")
        return at.toDateString() === today.toDateString()
            ? time
            : Qt.formatDate(at, "d MMM") + " " + time
    }

    function ago(seconds) {
        var minutes = Math.max(0, Math.floor((root.nowMs / 1000 - Number(seconds)) / 60))
        if (minutes < 60)
            return minutes + "M"
        if (minutes < 60 * 24)
            return Math.floor(minutes / 60) + "H"
        return Math.floor(minutes / (60 * 24)) + "D"
    }

    function openItem(itemId) {
        interacted()
        openRequested(String(itemId))
    }

    Row {
        id: channelTabs

        anchors {
            left: parent.left
            top: parent.top
        }
        height: 40
        spacing: 10
        visible: root.available

        Repeater {
            model: root.channels

            Rectangle {
                id: tab

                required property var modelData
                required property int index
                readonly property bool selected:
                    index === Math.min(root.channelIndex, root.channels.length - 1)

                objectName: "slackChannelTab_" + index
                anchors.verticalCenter: parent.verticalCenter
                width: tabText.implicitWidth + 32
                height: 34
                radius: 10
                color: tabTap.pressed ? root.theme.surfacePressed : root.theme.surfaceRaised
                border.width: 1
                border.color: selected ? root.accent : root.theme.border

                function activate() {
                    root.interacted()
                    root.channelIndex = index
                    return true
                }

                Text {
                    id: tabText
                    anchors.centerIn: parent
                    text: "#" + String(tab.modelData.name).toUpperCase()
                        + (tab.modelData.unread > 0
                            ? "  ·  " + tab.modelData.unread
                                + (tab.modelData.unread_capped ? "+" : "")
                            : "")
                    textFormat: Text.PlainText
                    color: tab.selected ? root.readablePrimary : root.readableMuted
                    font {
                        family: "monospace"
                        pixelSize: 11
                        weight: Font.DemiBold
                        letterSpacing: 0.5
                    }
                }

                Accessible.role: Accessible.Button
                Accessible.name: "Show channel " + String(tab.modelData.name)
                Accessible.onPressAction: activate()

                TapHandler {
                    id: tabTap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: tab.activate()
                }
            }
        }
    }

    Rectangle {
        id: feedCard

        objectName: "slackFeed"
        anchors {
            left: parent.left
            right: strip.left
            top: channelTabs.bottom
            bottom: parent.bottom
            topMargin: 10
            rightMargin: 20
        }
        visible: root.available
        radius: 18
        color: root.theme.surface
        border.width: 1
        border.color: Qt.alpha(root.accent, 0.42)

        ListView {
            id: feed

            objectName: "slackMessages"
            anchors {
                fill: parent
                margins: 18
            }
            clip: true
            spacing: 10
            model: root.messages
            boundsBehavior: Flickable.StopAtBounds
            // Newest at the bottom, like Slack. A refresh replaces the model,
            // which would reset the view: follow new messages only when the
            // reader was already at the bottom, otherwise keep their place.
            property bool followEnd: true
            property real keptOffset: 0
            onMovementEnded: {
                followEnd = atYEnd
                keptOffset = contentY - originY
            }
            onModelChanged: Qt.callLater(function() {
                if (feed.followEnd)
                    feed.positionViewAtEnd()
                else
                    feed.contentY = feed.originY + Math.min(
                        feed.keptOffset,
                        Math.max(0, feed.contentHeight - feed.height)
                    )
            })
            Component.onCompleted: positionViewAtEnd()

            delegate: Rectangle {
                id: message

                required property var modelData
                required property int index

                objectName: "slackMessage_" + index
                width: feed.width
                height: body.implicitHeight + header.height + 22
                    + (thumbnails.visible ? thumbnails.height + 10 : 0)
                    + (reactionRow.visible ? reactionRow.height + 8 : 0)
                radius: 12
                color: messageTap.pressed
                    ? root.theme.surfacePressed
                    : modelData.unread
                        ? Qt.alpha(root.accent, 0.07)
                        : "transparent"

                function activate() {
                    if (!root.enabled)
                        return false
                    root.openItem(modelData.id)
                    return true
                }

                Rectangle {
                    visible: message.modelData.unread
                    anchors {
                        left: parent.left
                        top: parent.top
                        bottom: parent.bottom
                        margins: 8
                    }
                    width: 3
                    radius: 1.5
                    color: root.accent
                }

                Row {
                    id: header

                    anchors {
                        left: parent.left
                        top: parent.top
                        leftMargin: 20
                        topMargin: 8
                    }
                    height: 20
                    spacing: 12

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: String(message.modelData.author)
                        textFormat: Text.PlainText
                        color: root.readableAccent
                        font {
                            family: "monospace"
                            pixelSize: 14
                            weight: Font.Bold
                        }
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.clock(message.modelData.at)
                            + (message.modelData.replies > 0
                                ? "  ·  " + message.modelData.replies
                                    + (message.modelData.replies === 1 ? " REPLY" : " REPLIES")
                                : "")
                        textFormat: Text.PlainText
                        color: root.readableMuted
                        font {
                            family: "monospace"
                            pixelSize: 11
                            letterSpacing: 0.4
                        }
                    }
                }

                Text {
                    id: body

                    anchors {
                        left: parent.left
                        right: parent.right
                        top: header.bottom
                        leftMargin: 20
                        rightMargin: 16
                        topMargin: 4
                    }
                    text: String(message.modelData.text)
                    textFormat: Text.PlainText
                    color: root.readablePrimary
                    wrapMode: Text.Wrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    font {
                        family: "monospace"
                        pixelSize: 14
                    }
                }

                Row {
                    id: thumbnails

                    objectName: "slackThumbnails_" + message.index
                    anchors {
                        left: body.left
                        top: body.bottom
                        topMargin: 10
                    }
                    height: 140
                    spacing: 10
                    visible: root.imageDirectory !== ""
                        && message.modelData.images.length > 0

                    Repeater {
                        model: thumbnails.visible ? message.modelData.images : []

                        Rectangle {
                            required property var modelData

                            width: Math.min(
                                feed.width / 2 - 30,
                                thumbnails.height * modelData.width / modelData.height
                            )
                            height: thumbnails.height
                            radius: 10
                            color: root.theme.surfaceRaised
                            border.width: 1
                            border.color: Qt.alpha(root.accent, 0.3)
                            clip: true

                            Image {
                                anchors {
                                    fill: parent
                                    margins: 1
                                }
                                source: "file://" + root.imageDirectory + "/"
                                    + parent.modelData.file
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                            }
                        }
                    }
                }

                Row {
                    id: reactionRow

                    objectName: "slackReactions_" + message.index
                    anchors {
                        left: body.left
                        top: thumbnails.visible ? thumbnails.bottom : body.bottom
                        topMargin: 8
                    }
                    height: 26
                    spacing: 6
                    visible: message.modelData.reactions.length > 0

                    Repeater {
                        model: message.modelData.reactions

                        Rectangle {
                            required property var modelData

                            width: reactionText.implicitWidth + 18
                            height: reactionRow.height
                            radius: 13
                            color: root.theme.surfaceRaised
                            border.width: 1
                            border.color: Qt.alpha(root.accent, 0.3)

                            Text {
                                id: reactionText
                                anchors.centerIn: parent
                                text: String(parent.modelData.emoji) + " " + parent.modelData.count
                                textFormat: Text.PlainText
                                color: root.readablePrimary
                                font {
                                    family: "monospace"
                                    pixelSize: 12
                                    weight: Font.DemiBold
                                }
                            }
                        }
                    }
                }

                Accessible.role: Accessible.Button
                Accessible.name: "Open message from " + String(message.modelData.author)
                Accessible.onPressAction: activate()

                TapHandler {
                    id: messageTap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: message.activate()
                }
            }
        }

        Text {
            anchors.centerIn: parent
            visible: root.messages.length === 0
            text: root.channels.length === 0
                ? "NO CHANNEL CONFIGURED"
                : root.channel !== null && !root.channel.available
                    ? "#" + String(root.channel.name).toUpperCase() + " UNAVAILABLE"
                    : "NO MESSAGES"
            textFormat: Text.PlainText
            color: root.readableMuted
            font {
                family: "monospace"
                pixelSize: 15
                weight: Font.DemiBold
                letterSpacing: 0.8
            }
        }
    }

    // DMs and @-mentions strip.
    Rectangle {
        id: strip

        objectName: "slackInbox"
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

            objectName: "slackInboxTitle"
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 20
            }
            text: "SLACK  //  " + (root.available ? root.slack.notifications.length : 0)
                + " FOR YOU"
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
                model: root.available ? root.slack.notifications : []

                Rectangle {
                    id: row

                    required property var modelData
                    required property int index
                    readonly property bool direct: modelData.kind === "dm"
                    readonly property color kindColor: direct ? root.theme.blue : root.accent

                    objectName: "slackNotification_" + index
                    width: parent.width
                    height: 54
                    radius: 10
                    color: rowTap.pressed ? root.theme.surfacePressed : "transparent"

                    function activate() {
                        if (!root.enabled)
                            return false
                        root.openItem(modelData.id)
                        return true
                    }

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
                            text: row.direct
                                ? "DM" + (row.modelData.unread > 1 ? " · " + row.modelData.unread : "")
                                : "MENTION"
                            textFormat: Text.PlainText
                            color: ThemePalette.ensureContrast(
                                String(row.kindColor),
                                String(root.theme.surface),
                                4.5
                            )
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
                        text: String(row.modelData.text)
                        textFormat: Text.PlainText
                        color: root.readablePrimary
                        elide: Text.ElideRight
                        maximumLineCount: 1
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
                        text: (row.direct
                            ? [row.modelData.author, root.ago(row.modelData.at)]
                            : [row.modelData.source, row.modelData.author, root.ago(row.modelData.at)])
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

                    Accessible.role: Accessible.Button
                    Accessible.name: (row.direct ? "Open DM from " : "Open mention by ")
                        + String(row.modelData.author)
                    Accessible.onPressAction: activate()

                    TapHandler {
                        id: rowTap
                        gesturePolicy: TapHandler.ReleaseWithinBounds
                        onTapped: row.activate()
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            visible: root.available && root.slack.notifications.length === 0
            text: "ALL CAUGHT UP"
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

    Column {
        objectName: "slackOffline"
        anchors.centerIn: parent
        spacing: 14
        visible: !root.available

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "SLACK  //  OFFLINE"
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
            text: "Put your Slack user token in ~/.config/xeneon-edge-agents/slack.toml (chmod 600)."
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
