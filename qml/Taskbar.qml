// 底部任务栏 —— "像 Windows 那样"最直观的一笔
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: bar
    property var theme
    signal ledgerClicked()

    color: theme.surface

    Rectangle {
        anchors.top: parent.top
        width: parent.width; height: 1
        color: theme.border
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 4

        // ── 开始按钮 ──────────────────────────────────────
        Rectangle {
            Layout.preferredWidth: 44
            Layout.preferredHeight: 30
            radius: 4
            color: startArea.containsMouse ? theme.surfaceHi : "transparent"

            Text {
                anchors.centerIn: parent
                text: "氵"
                color: theme.text
                font.pixelSize: 17
            }

            MouseArea {
                id: startArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: startMenu.visible = !startMenu.visible
            }
        }

        Rectangle { width: 1; height: 20; color: theme.border; Layout.leftMargin: 4; Layout.rightMargin: 4 }

        // ── 已打开的程序（v0.1 只有 AI 界面）──────────────
        Rectangle {
            Layout.preferredWidth: 40
            Layout.preferredHeight: 30
            radius: 4
            color: theme.surfaceHi
            border.color: theme.textFaint
            border.width: 1

            Text {
                anchors.centerIn: parent
                text: "❯"
                color: theme.text
                font.pixelSize: 13
            }
        }

        Item { Layout.fillWidth: true }

        // ── 右侧状态区 ────────────────────────────────────

        // 账本
        Rectangle {
            Layout.preferredWidth: 64
            Layout.preferredHeight: 30
            radius: 4
            color: ledgerArea.containsMouse ? theme.surfaceHi : "transparent"

            Row {
                anchors.centerIn: parent
                spacing: 5
                Text { text: "账本"; color: theme.textDim; font.pixelSize: 11 }
            }

            MouseArea {
                id: ledgerArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: bar.ledgerClicked()
            }
        }

        // 垃圾桶
        Rectangle {
            Layout.preferredWidth: 64
            Layout.preferredHeight: 30
            radius: 4
            color: trashArea.containsMouse ? theme.surfaceHi : "transparent"

            Text {
                anchors.centerIn: parent
                text: "垃圾桶"
                color: theme.textDim
                font.pixelSize: 11
            }

            MouseArea {
                id: trashArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    const raw = Shuios.trashList();
                    trashPopup.items = JSON.parse(raw);
                    trashPopup.visible = !trashPopup.visible;
                }
            }
        }

        Rectangle { width: 1; height: 20; color: theme.border; Layout.leftMargin: 4; Layout.rightMargin: 4 }

        // ── 时钟 ──────────────────────────────────────────
        Text {
            id: clock
            color: theme.textDim
            font.pixelSize: 12
            font.family: theme.mono
            text: Qt.formatDateTime(new Date(), "hh:mm")

            Timer {
                interval: 10000
                running: true
                repeat: true
                onTriggered: clock.text = Qt.formatDateTime(new Date(), "hh:mm")
            }
        }
    }

    // ── 开始菜单 ──────────────────────────────────────────
    Rectangle {
        id: startMenu
        visible: false
        anchors.left: parent.left
        anchors.bottom: parent.top
        anchors.bottomMargin: 8
        anchors.leftMargin: 12
        width: 260
        height: menuCol.implicitHeight + 24
        color: theme.surface
        radius: theme.radius
        border.color: theme.border
        border.width: 1

        Column {
            id: menuCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: 12
            spacing: 2

            Text {
                text: "氵系统 v0.1"
                color: theme.textFaint
                font.pixelSize: 11
                font.family: theme.mono
                leftPadding: 12
                topPadding: 4
                bottomPadding: 8
            }

            Repeater {
                model: [
                    { label: "审计账本", action: "ledger" },
                    { label: "垃圾桶",   action: "trash" },
                    { label: "能力凭据", action: "caps" },
                ]

                delegate: Rectangle {
                    width: parent.width
                    height: 36
                    radius: 4
                    color: itemArea.containsMouse ? theme.surfaceHi : "transparent"

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        x: 12
                        text: modelData.label
                        color: theme.text
                        font.pixelSize: 13
                    }

                    MouseArea {
                        id: itemArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            startMenu.visible = false;
                            if (modelData.action === "ledger") bar.ledgerClicked();
                            else if (modelData.action === "trash") {
                                trashPopup.items = JSON.parse(Shuios.trashList());
                                trashPopup.visible = true;
                            } else {
                                capsPopup.visible = true;
                            }
                        }
                    }
                }
            }
        }
    }

    // ── 垃圾桶弹层 ────────────────────────────────────────
    Rectangle {
        id: trashPopup
        property var items: []
        visible: false
        anchors.right: parent.right
        anchors.bottom: parent.top
        anchors.bottomMargin: 8
        anchors.rightMargin: 12
        width: 320
        height: Math.min(items.length * 44 + 60, 360)
        color: theme.surface
        radius: theme.radius
        border.color: theme.border
        border.width: 1

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 6

            Text {
                text: "垃圾桶（可恢复）"
                color: theme.text
                font.pixelSize: 13
            }

            Text {
                visible: trashPopup.items.length === 0
                text: "空的"
                color: theme.textFaint
                font.pixelSize: 12
            }

            Repeater {
                model: trashPopup.items
                delegate: Column {
                    width: parent.width
                    spacing: 2
                    Text {
                        width: parent.width
                        text: modelData.original || modelData.id
                        color: theme.textDim
                        font.pixelSize: 11
                        font.family: theme.mono
                        elide: Text.ElideMiddle
                    }
                }
            }
        }
    }

    // ── 能力凭据弹层 ──────────────────────────────────────
    Rectangle {
        id: capsPopup
        visible: false
        anchors.right: parent.right
        anchors.bottom: parent.top
        anchors.bottomMargin: 8
        anchors.rightMargin: 12
        width: 400
        height: 300
        color: theme.surface
        radius: theme.radius
        border.color: theme.border
        border.width: 1

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8

            Text {
                text: "能力凭据（当前会话）"
                color: theme.text
                font.pixelSize: 13
            }

            Text {
                text: "每一枚凭据都是限时、限范围、限次数的。\nAI 无法持有长期权限。"
                color: theme.textFaint
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                width: parent.width
            }

            ScrollView {
                width: parent.width
                height: parent.height - 70
                clip: true
                TextArea {
                    readOnly: true
                    text: capsPopup.visible
                          ? JSON.stringify(JSON.parse(Shuios.capabilityList()), null, 1)
                          : ""
                    color: theme.textDim
                    font.family: theme.mono
                    font.pixelSize: 10
                    wrapMode: TextArea.WrapAnywhere
                    background: Rectangle { color: theme.bg; radius: 4 }
                }
            }
        }
    }
}