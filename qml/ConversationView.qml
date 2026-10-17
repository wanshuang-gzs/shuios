// 对话主界面 —— 消息流 + 输入框
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Item {
    id: view
    property var theme
    signal planRequested(string input)

    property bool streaming: false

    // ── 消息模型 ──────────────────────────────────────────
    ListModel { id: msgModel }

    function addUser(text) {
        msgModel.append({ kind: "user", text: text });
        scrollToEnd();
    }
    function addAssistant(text) {
        msgModel.append({ kind: "assistant", text: text });
        scrollToEnd();
    }
    function addSystem(text) {
        msgModel.append({ kind: "system", text: text });
        scrollToEnd();
    }
    function appendToLast(delta) {
        if (msgModel.count === 0) {
            addAssistant(delta);
            view.streaming = true;
            return;
        }
        const i = msgModel.count - 1;
        const cur = msgModel.get(i);
        if (cur.kind !== "assistant") {
            addAssistant(delta);
        } else {
            msgModel.setProperty(i, "text", cur.text + delta);
        }
        view.streaming = true;
        scrollToEnd();
    }
    function finishStreaming() { view.streaming = false; }

    function scrollToEnd() {
        Qt.callLater(function() {
            if (msgModel.count > 0)
                list.positionViewAtEnd();
        });
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── 消息流 ────────────────────────────────────────
        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            model: msgModel
            clip: true
            spacing: 2
            topMargin: 24
            bottomMargin: 24

            // 空状态
            Text {
                anchors.centerIn: parent
                visible: msgModel.count === 0
                text: "氵"
                color: view.theme.textFaint
                font.pixelSize: 96
                opacity: 0.15
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 90
                visible: msgModel.count === 0
                text: "说点什么，或者试试：整理 ~/Downloads"
                color: view.theme.textFaint
                font.pixelSize: 13
            }

            delegate: Item {
                width: ListView.view.width
                height: bubble.height + 16

                Rectangle {
                    id: bubble
                    width: Math.min(parent.width * 0.72, contentText.implicitWidth + 32)
                    height: contentText.implicitHeight + 24
                    radius: view.theme.radius

                    // 用户消息靠右，AI 靠左，系统消息居中
                    x: model.kind === "user"
                       ? parent.width - width - 24
                       : 24

                    color: model.kind === "user"    ? view.theme.surfaceHi
                         : model.kind === "system"  ? "transparent"
                         : view.theme.surface

                    border.color: model.kind === "system" ? "transparent" : view.theme.border
                    border.width: model.kind === "system" ? 0 : 1

                    Text {
                        id: contentText
                        anchors.centerIn: parent
                        width: Math.min(parent.width - 32, implicitWidth)
                        text: model.text
                        color: model.kind === "system" ? view.theme.textFaint : view.theme.text
                        font.pixelSize: model.kind === "system" ? 12 : 14
                        wrapMode: Text.Wrap
                        lineHeight: 1.5
                    }
                }
            }
        }

        // ── 流式指示 ──────────────────────────────────────
        Row {
            Layout.leftMargin: 28
            Layout.bottomMargin: 4
            spacing: 6
            visible: view.streaming
            Text { text: "●"; color: view.theme.textDim; font.pixelSize: 8 }
            Text { text: "正在思考…"; color: view.theme.textFaint; font.pixelSize: 11 }
        }

        // ── 输入区 ────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            color: view.theme.surface

            Rectangle {
                anchors.top: parent.top
                width: parent.width; height: 1
                color: view.theme.border
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                anchors.margins: 12
                spacing: 12

                TextField {
                    id: input
                    Layout.fillWidth: true
                    placeholderText: "输入指令…  （Enter 发送）"
                    color: view.theme.text
                    font.pixelSize: 14
                    selectByMouse: true
                    background: Rectangle {
                        color: view.theme.bg
                        radius: view.theme.radius
                        border.color: input.activeFocus ? view.theme.textDim : view.theme.border
                        border.width: 1
                    }

                    Keys.onReturnPressed: function(event) {
                        if (event.modifiers & Qt.ShiftModifier) {
                            event.accepted = false;   // Shift+Enter 换行
                        } else {
                            view.submit();
                            event.accepted = true;
                        }
                    }
                }

                Button {
                    Layout.preferredWidth: 72
                    Layout.preferredHeight: 40
                    text: "发送"
                    enabled: input.text.trim().length > 0

                    background: Rectangle {
                        color: parent.enabled
                               ? (parent.hovered ? view.theme.accent : view.theme.text)
                               : view.theme.surfaceHi
                        radius: view.theme.radius
                    }
                    contentItem: Text {
                        text: parent.text
                        color: parent.enabled ? view.theme.bg : view.theme.textFaint
                        font.pixelSize: 13
                        font.weight: Font.Medium
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }

                    onClicked: view.submit()
                }
            }
        }
    }

    // ══ 判断输入是「对话」还是「系统指令」 ═════════════════
    //  含路径的 → 走意图解析（弹计划确认框）
    //  否则     → 走 AI 对话
    function looksLikeCommand(text) {
        return /(^|[\s把将])\/[A-Za-z0-9_\-.\/]+/.test(text)
            || /(整理|清理|删除|删除|归纳).{0,8}[\/\w]/.test(text);
    }

    function submit() {
        const text = input.text.trim();
        if (!text) return;
        input.text = "";

        addUser(text);

        if (looksLikeCommand(text)) {
            planRequested(text);
        } else {
            addAssistant("");
            msgModel.remove(msgModel.count - 1);   // 占位，等流式
            Shuios.sendMessage(text);
            view.streaming = true;
        }
    }
}