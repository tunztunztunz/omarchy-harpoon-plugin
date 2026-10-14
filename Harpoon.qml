import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "HarpoonModel.js" as HarpoonModel

// Harpoon list overlay: state, keys and actions. The visuals are
// HarpoonHeader, HarpoonRow, HarpoonPreview and HarpoonFooter.
//
// It never writes the bookmark file itself: every mutating action goes
// through `hyprctl dispatch "Harpoon.<call>"`, the same Lua the SUPER+H
// submap calls in-process, so the two trigger paths can't disagree about
// state. See README.md, "How it works".
Item {
  id: root

  property bool opened: false
  property int selectedIndex: 0
  property bool renameOpen: false
  property string renameText: ""
  property var slots: HarpoonModel.parseSlots("{}")
  property var liveSet: ({})
  property var pendingFollowSlot: null

  // "live": continuously-updating capture of the selected row only.
  // "thumbnail": one frozen frame per bookmark, captured up front.
  // "off": no capture work of any kind.
  property string previewMode: "live"
  readonly property var previewModeOrder: ["live", "thumbnail", "off"]
  readonly property string previewModeLabel: previewMode.charAt(0).toUpperCase() + previewMode.slice(1)

  property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy/harpoon/list.json"
  property string settingsPath: Quickshell.env("HOME") + "/.local/state/omarchy/harpoon/settings.json"
  property string previewDir: Quickshell.env("HOME") + "/.local/state/omarchy/harpoon/previews"

  // Same [menu] surface every other Omarchy picker uses -- theme-reactive.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int contentSpacing: Style.spacing.md
  readonly property int iconSize: Style.font.display + Style.space(4)
  readonly property int headerHeight: Math.max(iconSize, Style.font.heading + Style.font.caption + Style.space(6)) + Style.space(8)
  readonly property int cardWidth: Math.min(Style.space(860), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(480), panel.height - Style.gapsOut * 2)
  readonly property int footerHeight: Math.max(Style.space(30), Style.font.caption + Style.space(16))

  readonly property var keyHints: [
    { key: "↑↓ jk", label: "Move" },
    { key: "⇧↑↓", label: "Reorder" },
    { key: "⇧0-9", label: "To slot" },
    { key: "⏎", label: "Harpoon" },
    { key: "r", label: "Rename" },
    { key: "d", label: "Delete" },
    { key: "⇧D", label: "Clear" },
    { key: "p", label: "Preview: " + root.previewModeLabel },
    { key: "⇧P", label: "Private" },
    { key: "q", label: "Quit" }
  ]

  function slotLabel(slot) {
    return slot === 10 ? "0" : String(slot)
  }

  function open() {
    root.opened = true
    root.selectedIndex = 0
    root.renameOpen = false
    root.rebuildDisplay()
    Qt.callLater(function() {
      if (root.opened && !root.renameOpen) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  // Short app name from the app's .desktop file ("Ghostty" rather than
  // "com.mitchellh.ghostty"). heuristicLookup rather than byId: a window
  // class doesn't always match the .desktop filename (Thunderbird's class is
  // "org.mozilla.Thunderbird", its desktop entry "thunderbird"). Falls back
  // to the raw class.
  function resolveAppName(cls) {
    if (!cls) return ""
    var entry = DesktopEntries.heuristicLookup(cls)
    return (entry && entry.name) ? entry.name : cls
  }

  function rebuildDisplay() {
    var rows = HarpoonModel.displayRows(root.slots, root.resolveAppName)
    for (var i = 0; i < rows.length; i++) rows[i].live = root.liveSet[rows[i].address] === true

    displayModel.clear()
    for (var j = 0; j < rows.length; j++) displayModel.append(rows[j])

    if (root.pendingFollowSlot !== null) {
      for (var k = 0; k < displayModel.count; k++) {
        if (displayModel.get(k).slot === root.pendingFollowSlot) { root.selectedIndex = k; break }
      }
      root.pendingFollowSlot = null
    } else if (displayModel.count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= displayModel.count) root.selectedIndex = displayModel.count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
    preview.reload()
    // Debounced via the timer only: a direct refreshLiveness() here as well
    // let two grim captures of the same file race and corrupt the PNG.
    previewTimer.restart()
  }

  function currentRow() {
    if (displayModel.count === 0) return null
    return displayModel.get(root.selectedIndex)
  }

  function select(delta) {
    if (displayModel.count === 0) return
    pointerGate.reset()
    root.selectedIndex = (root.selectedIndex + delta + displayModel.count) % displayModel.count
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    preview.reload()
    previewTimer.restart()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.selectedIndex = index
    preview.reload()
    previewTimer.restart()
  }

  function cyclePreviewMode() {
    var idx = root.previewModeOrder.indexOf(root.previewMode)
    root.previewMode = root.previewModeOrder[(idx + 1) % root.previewModeOrder.length]
    settingsFile.setText(JSON.stringify({ previewMode: root.previewMode }, null, 2) + "\n")
    // Only live mode reads captured files.
    if (root.previewMode !== "live") Util.execArgv(["bash", "-c", 'rm -f -- "$1"/*.png', "bash", root.previewDir])
    preview.reload()
    previewTimer.restart()
  }

  function togglePreviewSelected() {
    var row = root.currentRow()
    if (!row) return
    runHarpoon("togglePreview(" + row.slot + ")")
  }

  function runHarpoon(luaCall) {
    Util.execArgv(["hyprctl", "dispatch", "Harpoon." + luaCall])
  }

  function activateSelected() {
    var row = root.currentRow()
    if (!row) return
    runHarpoon("jump(" + row.slot + ")")
    root.close()
  }

  function startRename() {
    var row = root.currentRow()
    if (!row) return
    root.renameText = row.name
    root.renameOpen = true
    Qt.callLater(function() { header.focusRename() })
  }

  function commitRename() {
    var row = root.currentRow()
    root.renameOpen = false
    if (row && root.renameText.length > 0) {
      runHarpoon("rename(" + row.slot + ", " + HarpoonModel.luaStringLiteral(root.renameText) + ")")
    }
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelRename() {
    root.renameOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // No confirm dialog on purpose: this is a productivity tool, deleting a
  // slot or clearing the list is meant to be as fast as adding one. Neither
  // action touches the actual windows -- clear() itself restores anything
  // still overlaid before wiping the list -- so the worst case is
  // re-bookmarking, not losing work.
  function deleteSelected() {
    var row = root.currentRow()
    if (!row) return
    runHarpoon("delete(" + row.slot + ")")
  }

  function clearAll() {
    if (displayModel.count === 0) return
    runHarpoon("clear()")
  }

  function reorderSelected(dir) {
    var row = root.currentRow()
    if (!row) return
    runHarpoon("reorder(" + row.slot + ", \"" + dir + "\")")
    // The FileView reload will re-derive slot contents; nudge the cursor in
    // the same direction so the moved item stays roughly under it until
    // that reload lands.
    root.select(dir === "up" ? -1 : 1)
  }

  // Shift+<digit> as a digit 0-9, or null. `event.key` is only a digit key
  // for the numpad and for layouts where a shifted top-row digit still
  // reports as Key_<digit>; on others it reports the symbol's own key
  // (Key_Exclam for Shift+1), so fall back to the produced character against
  // the standard shifted number row. Bare Shift produces "" -- hence the
  // length check, since "".indexOf("") is 0.
  function shiftDigitFromEvent(event) {
    if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) return event.key - Qt.Key_0
    if (event.text.length !== 1) return null
    var symbols = ")!@#$%^&*("
    var idx = symbols.indexOf(event.text)
    return idx >= 0 ? idx : null
  }

  // Shift+<digit> inside the open list: move the selected bookmark directly
  // to that slot number -- swapping with whatever's already there, or just
  // claiming it if empty (see Harpoon.moveToSlot in harpoon-logic.lua).
  function moveSelectedToSlot(targetSlot) {
    var row = root.currentRow()
    if (!row || row.slot === targetSlot) return
    runHarpoon("moveToSlot(" + row.slot + ", " + targetSlot + ")")
    // The moved bookmark's list *index* changes (it's now sorted under a
    // different slot number); follow it there once the reload lands.
    root.pendingFollowSlot = targetSlot
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.slots = HarpoonModel.parseSlots(text())
      if (root.opened) root.rebuildDisplay()
    }
    onLoadFailed: {
      root.slots = HarpoonModel.parseSlots("{}")
    }
    onFileChanged: reload()
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var doc = JSON.parse(text())
        if (root.previewModeOrder.indexOf(doc.previewMode) >= 0) root.previewMode = doc.previewMode
      } catch (e) {
        // malformed settings file -- keep the current (default "live") mode
      }
      preview.reload()
    }
    onLoadFailed: {
      // no settings file yet -- "live" default already set
    }
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // Single `hyprctl -j clients` read feeds both the per-row "live" flag
  // (greys out a bookmark whose window has since closed) and the preview's
  // grim fallback -- no daemon, re-checked lazily whenever the list opens,
  // the selection settles, or state reloads.
  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.liveSet = HarpoonModel.liveAddressSet(text)
        for (var i = 0; i < displayModel.count; i++) {
          displayModel.setProperty(i, "live", root.liveSet[displayModel.get(i).address] === true)
        }
        preview.refreshGeometry(text)
      }
    }
  }

  function refreshLiveness() {
    clientsProc.running = true
  }

  Timer {
    id: previewTimer
    interval: 200
    repeat: false
    onTriggered: root.refreshLiveness()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-harpoon"
    WlrLayershell.layer: WlrLayer.Overlay
    // OnDemand allows clicking windows behind the card. Mapping alone does
    // not reliably acquire keyboard focus; the grab below requests it.
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore
    // Pointer input only within the card; everything outside stays
    // interactive.
    mask: Region { item: card }

    HyprlandFocusGrab {
      windows: [panel]
      active: root.opened
      // An outside click releases the grab without closing the list.
      // Reopening rearms it; do not regrab when the user focuses a window.
    }

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // During a rename, activeFocus is on the header's field, so this
          // normally doesn't run; defensive.
          if (root.renameOpen) return

          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            root.close(); event.accepted = true
          } else if (event.key === Qt.Key_D && (event.modifiers & Qt.ShiftModifier)) {
            root.clearAll(); event.accepted = true
          } else if (event.key === Qt.Key_D) {
            root.deleteSelected(); event.accepted = true
          } else if (event.key === Qt.Key_R) {
            root.startRename(); event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            if (event.modifiers & Qt.ShiftModifier) root.reorderSelected("up")
            else root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            if (event.modifiers & Qt.ShiftModifier) root.reorderSelected("down")
            else root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activateSelected(); event.accepted = true
          } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ShiftModifier)) {
            root.togglePreviewSelected(); event.accepted = true
          } else if (event.key === Qt.Key_P) {
            root.cyclePreviewMode(); event.accepted = true
          } else if (event.modifiers & Qt.ShiftModifier) {
            var digit = root.shiftDigitFromEvent(event)
            if (digit !== null) {
              root.moveSelectedToSlot(digit === 0 ? 10 : digit)
              event.accepted = true
            }
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        HarpoonHeader {
          id: header
          width: parent.width
          height: root.headerHeight
          iconSize: root.iconSize
          count: displayModel.count
          previewLabel: root.previewModeLabel
          renameOpen: root.renameOpen
          renameText: root.renameText
          renameSlot: root.currentRow() ? root.slotLabel(root.currentRow().slot) : ""
          onRenameEdited: function(text) { root.renameText = text }
          onRenameAccepted: root.commitRename()
          onRenameCancelled: root.cancelRename()
        }

        PanelSeparator { foreground: root.foreground }

        // ---- body: list + preview ----
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - 2 - root.contentSpacing * 4

          Row {
            anchors.fill: parent
            spacing: 0
            visible: displayModel.count > 0

            Item {
              width: root.previewMode === "off" ? parent.width : parent.width / 2
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: displayModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: HarpoonRow {
                  width: ListView.view.width
                  hasCursor: index === root.selectedIndex
                  slotLabel: root.slotLabel(slot)
                  onHovered: function(item, mouse) { root.selectFromPointer(index, item, mouse) }
                  onActivated: { root.selectedIndex = index; root.activateSelected() }
                }
              }
            }

            HarpoonPreview {
              id: preview
              visible: root.previewMode !== "off"
              width: visible ? parent.width / 2 : 0
              height: parent.height
              mode: root.previewMode
              row: root.currentRow()
              rows: displayModel
              selectedIndex: root.selectedIndex
              contentMargin: root.contentMargin
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(10)
            visible: displayModel.count === 0

            HarpoonMark {
              anchors.horizontalCenter: parent.horizontalCenter
              size: Style.font.displayLarge * 2
              tint: Util.alpha(root.foreground, 0.35)
            }

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: "No bookmarks yet"
              color: root.foreground
              opacity: 0.8
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              text: "SUPER+H, A bookmarks the focused window"
              color: Util.alpha(root.foreground, 0.62)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        HarpoonFooter {
          width: parent.width
          height: root.footerHeight
          hints: root.keyHints
        }
      }
    }
  }
}
