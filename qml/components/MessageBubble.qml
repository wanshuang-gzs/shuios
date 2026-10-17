// 消息气泡（供复用，当前 ConversationView 内联实现，
// 保留此组件供 v0.2 的富文本/代码块渲染扩展）
import QtQuick

Rectangle {
    id: bubble
    property var theme
    property string kind: "assistant"   // user / assistant / system
    property alias text: label.text

    color: kind === "user"    ? theme.surfaceHi
         : kind === "system"  ? "transparent"
         : theme.surface
    radius: theme.radius
    border.color: kind === "system" ? "transparent" : theme.border
    border.width: kind === "system" ? 0 : 1

    Text {
        id: label
        anchors.fill: parent
        anchors.margins: 12
        color: kind === "system" ? theme.textFaint : theme.text
        font.pixelSize: kind === "system" ? 12 : 14
        wrapMode: Text.Wrap
        lineHeight: 1.5
    }
}