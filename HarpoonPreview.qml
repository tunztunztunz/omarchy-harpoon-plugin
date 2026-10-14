import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The preview pane and everything that feeds it.
//
// Live mode prefers Quickshell's per-window screencopy: the selected
// bookmark is matched to a wlr-foreign-toplevel handle by appId+title for
// ScreencopyView, a compositor capture that works for windows on inactive
// workspaces and isn't occluded by the list. Toplevel exposes no stable id,
// so two windows sharing appId+title are ambiguous -> a grim shot of the
// window's on-screen area instead, which only shows anything if it's
// actually visible. Thumbnail mode captures one frozen frame per bookmark
// up front and keeps them, so changing the selection is a visibility toggle.
// A private bookmark (noPreview) is never captured in any mode.
Item {
  id: root
  property string mode: "live"        // "live" | "thumbnail" | "off"
  property var row: null              // the selected bookmark's row, or null
  property var rows: null             // the list model, for thumbnail mode
  property int selectedIndex: 0
  property int contentMargin: Style.spacing.panelPadding

  property var matchedToplevel: null
  property var rowToplevels: []
  property string previewPath: ""
  property string previewPlaceholder: ""

  readonly property color foreground: Color.menu.text
  readonly property color dim: Util.alpha(foreground, 0.62)
  readonly property color hairline: Util.alpha(foreground, 0.14)
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int softRadius: Math.min(Style.cornerRadius, Style.space(6))

  function findToplevel(cls, title) {
    var matches = ToplevelManager.toplevels.values.filter(function(t) {
      return t.appId === cls && t.title === title
    })
    return matches.length === 1 ? matches[0] : null
  }

  // Call whenever the selection, the mode or the rows change.
  function reload() {
    var next = (mode === "live" && row && !row.noPreview) ? findToplevel(row.cls, row.title) : null
    if (next !== matchedToplevel) {
      // Go through null so the live Loader's `active` binding cycles
      // false-then-true and creates a fresh ScreencopyView: rebinding
      // captureSource on a live instance briefly blends the previous
      // window's texture with the new one.
      matchedToplevel = null
      Qt.callLater(function() { root.matchedToplevel = next })
    }
    // one lookup per row for thumbnail mode, not while browsing
    if (mode !== "thumbnail" || !rows) { rowToplevels = []; return }
    var arr = []
    for (var i = 0; i < rows.count; i++) {
      var r = rows.get(i)
      arr.push(r.noPreview ? null : findToplevel(r.cls, r.title))
    }
    rowToplevels = arr
  }

  // The grim fallback, from a fresh `hyprctl -j clients` read (shared with
  // the list's liveness check, see Harpoon.qml).
  function refreshGeometry(clientsJsonText) {
    if (!row || mode !== "live" || matchedToplevel) {
      previewPath = ""
      previewPlaceholder = ""
      return
    }
    if (row.noPreview) {
      previewPath = ""
      previewPlaceholder = row.name + "\nPreview off for this bookmark"
      return
    }
    var geo = visibleGeometry(clientsJsonText, row.address)
    if (!geo) {
      previewPath = ""
      previewPlaceholder = row.name + "\nNo live preview"
      return
    }
    // Keyed by address: harpoon-logic.lua's write_state deletes it by that name.
    var out = Quickshell.env("HOME") + "/.local/state/omarchy/harpoon/previews/" + row.address + ".png"
    var tmp = out + ".tmp"
    grimProc.outPath = out
    grimProc.address = row.address
    // Capture to a temp file and rename into place: the Image's async load
    // otherwise races the still-writing file and fails to decode it.
    grimProc.command = ["bash", "-lc",
      "umask 077 && grim -g " + Util.shellQuote(geo.x + "," + geo.y + " " + geo.w + "x" + geo.h) + " " + Util.shellQuote(tmp) +
      " && mv " + Util.shellQuote(tmp) + " " + Util.shellQuote(out)]
    grimProc.running = true
  }

  // A window's geometry from a `hyprctl -j clients` dump, by address; null
  // if not found or not mapped+visible (grim can only capture what's on screen).
  function visibleGeometry(clientsJsonText, address) {
    try {
      var clients = JSON.parse(clientsJsonText)
      for (var i = 0; i < clients.length; i++) {
        var c = clients[i]
        if (c && c.address === address) {
          if (!c.mapped || !c.visible) return null
          return { x: c.at[0], y: c.at[1], w: c.size[0], h: c.size[1] }
        }
      }
    } catch (e) {
      // fall through
    }
    return null
  }

  Process {
    id: grimProc
    property string outPath: ""
    property string address: ""
    onExited: function(exitCode, exitStatus) {
      // The bookmark can go private, or the mode change, mid-capture.
      var wanted = root.mode === "live" && root.row && root.row.address === grimProc.address && !root.row.noPreview
      if (!wanted) {
        Util.execArgv(["rm", "-f", "--", grimProc.outPath])
        return
      }
      if (exitCode === 0) {
        root.previewPath = Util.fileUrl(grimProc.outPath) + "?t=" + Date.now()
        root.previewPlaceholder = ""
      } else {
        root.previewPath = ""
        root.previewPlaceholder = root.row ? (root.row.name + "\nNo live preview") : ""
      }
    }
  }

  clip: true

  Rectangle {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: Style.normalBorderWidth
    color: root.hairline
  }

  PanelSectionHeader {
    id: header
    anchors.left: parent.left
    anchors.leftMargin: root.contentMargin
    anchors.top: parent.top
    text: (root.row ? (root.row.custom ? root.row.name : root.row.app) : "Preview").toUpperCase()
    foreground: root.foreground
    fontFamily: root.fontFamily
    font.letterSpacing: 1.2
  }

  Item {
    anchors.fill: parent
    anchors.leftMargin: root.contentMargin
    anchors.topMargin: header.height + Style.space(8)
    clip: true

    // live: a fresh ScreencopyView per selection change, see reload()
    Loader {
      anchors.fill: parent
      active: root.mode === "live" && root.matchedToplevel !== null
      sourceComponent: ScreencopyView {
        captureSource: root.matchedToplevel
        live: true
        paintCursor: false
      }
    }

    // thumbnails: one view per bookmark, each freezing on its first frame
    Repeater {
      model: root.mode === "thumbnail" && root.rows ? root.rows.count : 0

      ScreencopyView {
        required property int index
        visible: index === root.selectedIndex && hasContent
        anchors.fill: parent
        captureSource: root.rowToplevels[index] || null
        live: true
        paintCursor: false
        onHasContentChanged: if (hasContent && live) live = false
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.mode === "thumbnail" && root.row !== null && !root.rowToplevels[root.selectedIndex]
      anchors.fill: parent
      anchors.margins: Style.space(8)
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: (root.row ? root.row.name : "") + (root.row && root.row.noPreview ? "\nPreview off for this bookmark" : "\nNo thumbnail available")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Image {
      visible: root.mode === "live" && root.matchedToplevel === null && root.previewPath.length > 0
      anchors.fill: parent
      source: root.previewPath
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
    }

    Text {
      textFormat: Text.PlainText
      visible: root.mode === "live" && root.matchedToplevel === null && root.previewPath.length === 0
      anchors.fill: parent
      anchors.margins: Style.space(8)
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: root.previewPlaceholder
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Rectangle {
      anchors.fill: parent
      color: "transparent"
      radius: root.softRadius
      border.width: 1
      border.color: root.hairline
    }
  }
}
