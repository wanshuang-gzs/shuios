// ═══════════════════════════════════════════════════════════
//  计划确认弹层 —— shuios 的核心交互
//
//  这是 AI 系统最该有的诚实：
//    不偷偷做事，把「我打算做什么」摊开给人看，
//    危险的那一步必须人点头。
// ═══════════════════════════════════════════════════════════

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: dialog
    property var theme

    signal executed(string resultJson)

    property var currentPlan: null
    property string currentPlanJson: ""

    function showPlan(plan, json) {
        dialog.currentPlan = plan;
        dialog.currentPlanJson = json;
        dialog.visible = true;
    }

    // ── 半透明遮罩 ────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: "#000000"
        opacity: 0.72
        MouseArea { anchors.fill: parent }   // 吞掉点击
    }

    // ── 对话框 ────────────────────────────────────────────
    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: Math.min(680, parent.width - 64)
        height: Math.min(contentCol.implicitHeight + 48, parent.height - 64)
        color: dialog.theme.surface
        radius: dialog.theme.radius
        border.color: dialog.theme.border
        border.width: 1
        clip: true

        // 危险动作时顶部一条警示线
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 3
            color: dialog.theme.danger
            visible: dialog.currentPlan !== null && dialog.currentPlan.needsHuman
            opacity: 0.7
        }

        ColumnLayout {
            id: contentCol
            anchors.fill: parent
            anchors.margins: 24
            spacing: 16

            // ── 标题 ──────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Text {
                    text: dialog.currentPlan !== null && dialog.currentPlan.needsHuman
                          ? "需要你确认"
                          : "我打算这样做"
                    color: dialog.theme.text
                    font.pixelSize: 16
                    font.weight: Font.Medium
                }

                Item { Layout.fillWidth: true }

                // 等级徽章
                Rectangle {
                    visible: dialog.currentPlan !== null
                    width: lvlText.implicitWidth + 16
                    height: 22
                    radius: 11
                    color: "transparent"
                    border.width: 1
                    border.color: {
                        if (!dialog.currentPlan) return dialog.theme.border;
                        switch (dialog.currentPlan.maxLevel) {
                        case "SAFE":   return dialog.theme.border;
                        case "NORMAL": return dialog.theme.textDim;
                        case "DANGER": return dialog.theme.text;
                        default:       return dialog.theme.text;
                        }
                    }
                    Text {
                        id: lvlText
                        anchors.centerIn: parent
                        text: dialog.currentPlan ? dialog.currentPlan.maxLevel : ""
                        color: dialog.theme.textDim
                        font.pixelSize: 10
                        font.family: dialog.theme.mono
                    }
                }
            }

            // ── 原话回显 ──────────────────────────────────
            Text {
                Layout.fillWidth: true
                text: dialog.currentPlan ? "「" + dialog.currentPlan.rawInput + "」" : ""
                color: dialog.theme.textFaint
                font.pixelSize: 12
                wrapMode: Text.WordWrap
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }

            // ── 步骤清单（核心）───────────────────────────
            ScrollView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(stepCol.implicitHeight + 8, 320)
                clip: true

                Column {
                    id: stepCol
                    width: parent.width
                    spacing: 10

                    Repeater {
                        model: dialog.currentPlan ? dialog.currentPlan.steps : []

                        delegate: RowLayout {
                            width: stepCol.width
                            spacing: 12

                            // 序号
                            Text {
                                text: (index + 1) + "."
                                color: dialog.theme.textFaint
                                font.pixelSize: 13
                                font.family: dialog.theme.mono
                                Layout.alignment: Qt.AlignTop
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 3

                                // 描述
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.description
                                    color: modelData.level === "DANGER"
                                           ? dialog.theme.text
                                           : dialog.theme.text
                                    font.pixelSize: 13
                                    font.weight: modelData.level === "DANGER"
                                                 ? Font.Medium : Font.Normal
                                    wrapMode: Text.WordWrap
                                }

                                // 作用域
                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.scope
                                    color: dialog.theme.textFaint
                                    font.pixelSize: 11
                                    font.family: dialog.theme.mono
                                    elide: Text.ElideMiddle
                                }
                            }

                            // 等级标记
                            Text {
                                Layout.alignment: Qt.AlignTop
                                text: modelData.level
                                color: modelData.level === "DANGER"
                                       ? dialog.theme.text
                                       : dialog.theme.textFaint
                                font.pixelSize: 10
                                font.family: dialog.theme.mono
                            }
                        }
                    }
                }
            }

            // ── 警告 ──────────────────────────────────────
            Text {
                Layout.fillWidth: true
                visible: dialog.currentPlan !== null
                         && dialog.currentPlan.warnings
                         && dialog.currentPlan.warnings.length > 0
                text: {
                    if (!dialog.currentPlan || !dialog.currentPlan.warnings) return "";
                    return "⚠ " + dialog.currentPlan.warnings.join("\n⚠ ");
                }
                color: dialog.theme.textDim
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            // 危险提示
            Text {
                Layout.fillWidth: true
                visible: dialog.currentPlan !== null && dialog.currentPlan.needsHuman
                text: "这一步会改动你的文件。shuios 默认不真删——被删的文件会进垃圾桶，可以恢复。"
                color: dialog.theme.textFaint
                font.pixelSize: 11
                wrapMode: Text.WordWrap
            }

            // ── 执行结果 ──────────────────────────────────
            Text {
                id: resultText
                Layout.fillWidth: true
                visible: text.length > 0
                color: dialog.theme.textDim
                font.pixelSize: 11
                font.family: dialog.theme.mono
                wrapMode: Text.WordWrap
                text: ""
            }

            Rectangle { Layout.fillWidth: true; height: 1; color: dialog.theme.border }

            // ── 按钮 ──────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Item { Layout.fillWidth: true }

                // 取消
                Button {
                    Layout.preferredWidth: 88
                    Layout.preferredHeight: 36
                    text: "取消"
                    background: Rectangle {
                        color: parent.hovered ? dialog.theme.surfaceHi : "transparent"
                        radius: dialog.theme.radius
                        border.color: dialog.theme.border
                        border.width: 1
                    }
                    contentItem: Text {
                        text: parent.text
                        color: dialog.theme.textDim
                        font.pixelSize: 13
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: {
                        dialog.visible = false;
                        resultText.text = "";
                    }
                }

                // 执行
                Button {
                    id: execBtn
                    Layout.preferredWidth: 100
                    Layout.preferredHeight: 36
                    text: "执行"

                    background: Rectangle {
                        color: parent.hovered ? dialog.theme.textDim : dialog.theme.text
                        radius: dialog.theme.radius
                    }
                    contentItem: Text {
                        text: parent.text
                        color: dialog.theme.bg
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: {
                        // approved = true  —— 这就是"人类点头"
                        const res = Shuios.executePlan(dialog.currentPlanJson, true);
                        const arr = JSON.parse(res);

                        let lines = [];
                        for (let i = 0; i < arr.length; i++) {
                            const r = arr[i];
                            let mark = "·";
                            if (r.status === "OK")          mark = "✓";
                            else if (r.status === "NEEDS_HUMAN") mark = "⏸";
                            else if (r.status === "CAP_DENIED")  mark = "⛔";
                            else if (r.status === "FAILED")      mark = "✗";

                            let line = mark + " " + r.status;
                            if (r.detail) line += "  — " + r.detail;
                            if (r.data && r.data.recoverable_at)
                                line += "  → " + r.data.recoverable_at;
                            if (r.data && r.data.moved !== undefined)
                                line += "  移动了 " + r.data.moved + " 个文件";
                            if (r.data && r.data.count !== undefined)
                                line += "  " + r.data.count + " 项";
                            lines.push(line);
                        }

                        resultText.text = lines.join("\n");
                        execBtn.enabled = false;

                        // 2 秒后自动关闭，让用户看清结果
                        closeTimer.start();
                    }
                }
            }
        }
    }

    Timer {
        id: closeTimer
        interval: 2200
        onTriggered: {
            dialog.visible = false;
            resultText.text = "";
        }
    }
}