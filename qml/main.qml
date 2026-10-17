// ═══════════════════════════════════════════════════════════
//  氵系统 — 主界面
//  黑白简约 · 中文 · 底部任务栏
// ═══════════════════════════════════════════════════════════

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Shuios 1.0

ApplicationWindow {
    id: root
    width: 1280
    height: 720
    visible: true
    title: "氵系统"
    color: Theme.bg

    // ── 配色：黑白灰三色 ──────────────────────────────────
    QtObject {
        id: Theme
        readonly property color bg:        "#0d0d0d"
        readonly property color surface:   "#161616"
        readonly property color surfaceHi: "#1f1f1f"
        readonly property color border:    "#2a2a2a"
        readonly property color text:      "#f0f0f0"
        readonly property color textDim:    "#8a8a8a"
        readonly property color textFaint:  "#555555"
        readonly property color accent:    "#ffffff"
        readonly property color danger:    "#e8e8e8"

        readonly property int radius: 6
        readonly property int pad: 16
        readonly property string mono: "monospace"
    }

    // ══ 主布局 ════════════════════════════════════════════
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── 顶栏 ──────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            color: Theme.surface

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: Theme.border
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.pad
                anchors.rightMargin: Theme.pad
                spacing: 12

                // 标识
                Text {
                    text: "氵"
                    color: Theme.text
                    font.pixelSize: 22
                    font.weight: Font.Bold
                }
                Text {
                    text: "shuios"
                    color: Theme.textDim
                    font.pixelSize: 13
                    font.family: Theme.mono
                }

                Item { Layout.fillWidth: true }

                // 大脑状态指示
                Row {
                    spacing: 6
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Shuios.brainReady() ? "#4ade80" : "#e05252"
                    }
                    Text {
                        text: Shuios.brainReady()
                              ? ("大脑 " + Shuios.brainName())
                              : "大脑未配置"
                        color: Shuios.brainReady() ? Theme.textDim : "#e05252"
                        font.pixelSize: 12
                    }
                }
            }
        }

        // ── 对话区 ────────────────────────────────────────
        ConversationView {
            id: conversation
            Layout.fillWidth: true
            Layout.fillHeight: true
            theme: Theme
            onPlanRequested: (input) => root.handlePlan(input)
        }

        // ── 底部任务栏 ────────────────────────────────────
        Taskbar {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            theme: Theme
            onLedgerClicked: root.ledgerOpen = !root.ledgerOpen
        }
    }

    // ── 计划确认弹层 ──────────────────────────────────────
    PlanConfirmDialog {
        id: planDialog
        anchors.fill: parent
        theme: Theme
        visible: false
    }

    // ── 审计账本侧栏 ──────────────────────────────────────
    property bool ledgerOpen: false

    Rectangle {
        id: ledgerPanel
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: ledgerOpen ? Math.min(520, parent.width * 0.45) : 0
        color: Theme.surface
        clip: true
        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.left: parent.left
            width: 1; height: parent.height
            color: Theme.border
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.pad
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "审计账本"
                    color: Theme.text
                    font.pixelSize: 14
                    font.weight: Font.Medium
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: "✕"
                    color: Theme.textDim
                    font.pixelSize: 16
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.ledgerOpen = false
                    }
                }
            }

            Text {
                text: "系统做过的每件事、AI 申请过的每次权限，都在这里。不可篡改。"
                color: Theme.textFaint
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                TextArea {
                    id: ledgerText
                    readOnly: true
                    color: Theme.textDim
                    font.family: Theme.mono
                    font.pixelSize: 11
                    wrapMode: TextArea.WrapAnywhere
                    text: root.ledgerOpen ? Shuios.ledgerTail(60) : ""
                    background: Rectangle { color: Theme.bg; radius: 4 }
                }
            }

            Button {
                Layout.fillWidth: true
                text: "刷新"
                onClicked: ledgerText.text = Shuios.ledgerTail(60)
                background: Rectangle {
                    color: parent.hovered ? Theme.surfaceHi : Theme.bg
                    radius: 4
                    border.color: Theme.border
                }
                contentItem: Text {
                    text: parent.text
                    color: Theme.textDim
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
            }
        }
    }

    // ══ 逻辑 ══════════════════════════════════════════════

    function handlePlan(input) {
        const json = Shuios.planFor(input);

        let plan;
        try {
            plan = JSON.parse(json);
        } catch (e) {
            conversation.addSystem("无法解析你的输入。");
            return;
        }

        if (!plan.valid) {
            // 【关键】看不懂就明说，绝不猜
            let msg = "这条指令我无法确信理解。\n";
            if (plan.warnings && plan.warnings.length > 0)
                msg += plan.warnings[0];
            conversation.addSystem(msg);
            return;
        }

        // 有具体计划 → 让用户审阅
        planDialog.showPlan(plan, json);
    }

    Connections {
        target: Shuios

        function onDeltaReceived(delta) {
            conversation.appendToLast(delta);
        }
        function onResponseCompleted(full) {
            Shuios.appendAssistant(full);
            conversation.finishStreaming();
        }
        function onResponseFailed(error) {
            conversation.addSystem("⚠ " + error);
        }
    }
}