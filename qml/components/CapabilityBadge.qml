// 能力等级徽章
import QtQuick

Rectangle {
    id: badge
    property var theme
    property string level: "SAFE"

    width: label.implicitWidth + 16
    height: 20
    radius: 10
    color: "transparent"
    border.width: 1
    border.color: level === "DANGER" || level === "ALWAYS"
                  ? theme.text : theme.border

    Text {
        id: label
        anchors.centerIn: parent
        text: badge.level
        color: theme.textDim
        font.pixelSize: 10
        font.family: theme.mono
    }
}