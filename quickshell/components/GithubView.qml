import QtQuick
import "../state/ThemePalette.js" as ThemePalette

// GitHub dashboard: open pull requests across the followed organization plus a
// strip of unread notifications. It renders the daemon's snapshot and asks to
// open items by id; URLs and tokens never reach the portal.
Item {
    id: root

    property var github: ({"available": false})
    property var theme: ThemePalette.fallback

    signal openRequested(string itemId)
    signal interacted()

    readonly property bool available: github !== null
        && github !== undefined && github.available === true
    readonly property var pullRequests: available ? github.pull_requests : []
    readonly property var notifications: available ? github.notifications : []
    readonly property real stripWidth: 470
    readonly property color accent: theme.orange
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

    function ago(seconds) {
        var minutes = Math.max(0, Math.floor((root.nowMs / 1000 - Number(seconds)) / 60))
        if (minutes < 60)
            return minutes + "M"
        if (minutes < 60 * 24)
            return Math.floor(minutes / 60) + "H"
        return Math.floor(minutes / (60 * 24)) + "D"
    }

    function kindLabel(kind) {
        switch (kind) {
        case "pr":
            return "PR"
        case "issue":
            return "ISSUE"
        case "release":
            return "RELEASE"
        case "commit":
            return "COMMIT"
        case "ci":
            return "CI"
        case "discussion":
            return "TALK"
        default:
            return "UPDATE"
        }
    }

    function kindColor(kind) {
        switch (kind) {
        case "pr":
            return theme.green
        case "issue":
            return theme.blue
        case "ci":
            return theme.red
        case "release":
            return theme.magenta
        default:
            return theme.accent
        }
    }

    function openItem(itemId) {
        interacted()
        openRequested(String(itemId))
    }

    Text {
        id: feedTitle

        objectName: "githubFeedTitle"
        anchors {
            left: parent.left
            top: parent.top
        }
        height: 40
        verticalAlignment: Text.AlignVCenter
        visible: root.available
        text: String(root.github.organization || "").toUpperCase()
            + "  //  " + (root.available ? root.github.open_pull_requests : 0)
            + " OPEN PULL REQUESTS"
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
        id: feedCard

        objectName: "githubFeed"
        anchors {
            left: parent.left
            right: strip.left
            top: feedTitle.bottom
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

            objectName: "githubPullRequests"
            anchors {
                fill: parent
                margins: 16
            }
            clip: true
            spacing: 4
            model: root.pullRequests
            boundsBehavior: Flickable.StopAtBounds

            // A refresh replaces the model, which would jump back to the top.
            property real keptOffset: 0
            onMovementEnded: keptOffset = contentY - originY
            onModelChanged: Qt.callLater(function() {
                feed.contentY = feed.originY + Math.min(
                    feed.keptOffset,
                    Math.max(0, feed.contentHeight - feed.height)
                )
            })

            delegate: Rectangle {
                id: pull

                required property var modelData
                required property int index

                objectName: "githubPullRequest_" + index
                width: feed.width
                height: 52
                radius: 10
                color: pullTap.pressed ? root.theme.surfacePressed : "transparent"

                function activate() {
                    if (!root.enabled)
                        return false
                    root.openItem(modelData.id)
                    return true
                }

                Rectangle {
                    id: repoPill

                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: 8
                    }
                    width: 180
                    height: 26
                    radius: 13
                    color: ThemePalette.mixColors(
                        String(root.theme.surface),
                        String(root.accent),
                        0.12
                    )
                    border.width: 1
                    border.color: Qt.alpha(root.accent, 0.55)

                    Text {
                        anchors {
                            fill: parent
                            leftMargin: 12
                            rightMargin: 12
                        }
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: String(pull.modelData.repo)
                        textFormat: Text.PlainText
                        color: root.readableAccent
                        elide: Text.ElideRight
                        font {
                            family: "monospace"
                            pixelSize: 11
                            weight: Font.DemiBold
                        }
                    }
                }

                Text {
                    id: meta

                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        rightMargin: 10
                    }
                    text: [pull.modelData.author]
                        .concat(pull.modelData.draft ? ["DRAFT"] : [])
                        .concat(pull.modelData.comments > 0
                            ? [pull.modelData.comments
                                + (pull.modelData.comments === 1 ? " COMMENT" : " COMMENTS")]
                            : [])
                        .concat([root.ago(pull.modelData.at)])
                        .join("  ·  ").toUpperCase()
                    textFormat: Text.PlainText
                    color: root.readableMuted
                    font {
                        family: "monospace"
                        pixelSize: 11
                        letterSpacing: 0.4
                    }
                }

                Text {
                    anchors {
                        left: repoPill.right
                        right: meta.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: 16
                        rightMargin: 16
                    }
                    text: "#" + pull.modelData.number + "  " + String(pull.modelData.title)
                    textFormat: Text.PlainText
                    color: pull.modelData.draft ? root.readableMuted : root.readablePrimary
                    elide: Text.ElideRight
                    font {
                        family: "monospace"
                        pixelSize: 15
                        weight: Font.DemiBold
                    }
                }

                Accessible.role: Accessible.Button
                Accessible.name: "Open pull request " + pull.modelData.number
                    + " in " + String(pull.modelData.repo)
                Accessible.onPressAction: activate()

                TapHandler {
                    id: pullTap
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: pull.activate()
                }
            }
        }

        Text {
            anchors.centerIn: parent
            visible: root.pullRequests.length === 0
            text: "NO OPEN PULL REQUESTS"
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

    // Unread notifications strip.
    Rectangle {
        id: strip

        objectName: "githubInbox"
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

            objectName: "githubInboxTitle"
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 20
            }
            text: "GITHUB  //  " + root.notifications.length + " UNREAD"
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
                model: root.notifications

                Rectangle {
                    id: row

                    required property var modelData
                    required property int index
                    readonly property color kindColor: root.kindColor(modelData.kind)

                    objectName: "githubNotification_" + index
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
                            text: root.kindLabel(row.modelData.kind)
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
                        text: [row.modelData.repo,
                               String(row.modelData.reason).replace(/_/g, " "),
                               root.ago(row.modelData.at)].join("  ·  ").toUpperCase()
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

        Text {
            anchors.centerIn: parent
            visible: root.notifications.length === 0
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
        objectName: "githubOffline"
        anchors.centerIn: parent
        spacing: 14
        visible: !root.available

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "GITHUB  //  OFFLINE"
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
            text: "Sign in with `gh auth login` and set [github] in dashboards.toml."
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
