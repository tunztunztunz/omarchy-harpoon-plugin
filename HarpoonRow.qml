import QtQuick
import qs.Commons

// One bookmark in the list: slot badge, app and title (or the custom name),
// and the "on screen" / "closed" status.
Rectangle {
  id: row
  required property int index
  required property int slot
  required property string name
  required property string app
  required property bool custom
  required property string address
  required property string cls
  required property string title
  required property bool overlaid
  required property bool noPreview
  required property bool live

  property bool hasCursor: false
  property string slotLabel: String(slot)

  signal hovered(var item, var mouse)
  signal activated()

  readonly property color foreground: Color.menu.text
  readonly property color selectedText: Color.menu.selectedText
  readonly property color dim: Util.alpha(foreground, 0.62)
  readonly property color hairline: Util.alpha(foreground, 0.14)
  readonly property string fontFamily: Style.font.menuFamily
  readonly property color textColor: hasCursor ? selectedText : foreground

  height: Math.max(Style.space(40), Style.font.body + Style.spacing.rowPaddingX)
  radius: Math.min(Style.cornerRadius, Style.space(6))
  color: hasCursor ? Color.menu.selectedBackground : "transparent"
  opacity: live ? 1.0 : 0.5

  Rectangle {
    visible: row.hasCursor
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.topMargin: Style.space(9)
    anchors.bottomMargin: Style.space(9)
    width: Style.space(2)
    radius: width / 2
    color: row.selectedText
  }

  Row {
    anchors.fill: parent
    anchors.leftMargin: Style.space(14)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(10)

    Rectangle {
      id: slotBadge
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      height: Style.space(20)
      radius: row.radius
      color: row.hasCursor ? Util.alpha(row.selectedText, 0.16) : Util.alpha(row.foreground, 0.07)
      border.width: 1
      border.color: row.hasCursor ? Util.alpha(row.selectedText, 0.55) : row.hairline

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: row.slotLabel
        color: row.textColor
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Item {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - slotBadge.width - status.width - Style.space(20)
      height: labelRow.implicitHeight

      Row {
        id: labelRow
        width: parent.width
        spacing: Style.space(8)

        Text {
          id: primaryText
          textFormat: Text.PlainText
          text: row.custom ? row.name : row.app
          width: Math.min(implicitWidth, parent.width)
          color: row.textColor
          font.family: row.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.hasCursor
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: !row.custom && row.title.length > 0
          text: row.title
          width: Math.max(0, parent.width - primaryText.width - parent.spacing)
          color: row.hasCursor ? Util.alpha(row.selectedText, 0.75) : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }
    }

    Row {
      id: status
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      Rectangle {
        visible: row.overlaid
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(7)
        height: width
        radius: width / 2
        color: row.selectedText
      }

      Text {
        textFormat: Text.PlainText
        visible: row.overlaid
        anchors.verticalCenter: parent.verticalCenter
        text: "On screen"
        color: row.selectedText
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        font.capitalization: Font.AllUppercase
      }

      Text {
        textFormat: Text.PlainText
        visible: row.noPreview
        anchors.verticalCenter: parent.verticalCenter
        text: "Private"
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        font.capitalization: Font.AllUppercase
      }

      Text {
        textFormat: Text.PlainText
        visible: !row.live
        anchors.verticalCenter: parent.verticalCenter
        text: "Closed"
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1
        font.capitalization: Font.AllUppercase
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: function(mouse) { row.hovered(row, mouse) }
    onClicked: row.activated()
  }
}
