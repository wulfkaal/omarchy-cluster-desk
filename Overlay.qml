import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Fullscreen twin when windows cover workspace 10.
Scope {
  id: root
  property bool opened: false

  InfoModel { id: infoModel; refreshMs: 3000; active: root.opened }

  function open(payload) {
    root.opened = true
    infoModel.refresh()
  }
  function close() { root.opened = false }
  function toggle(payload) { if (root.opened) close(); else open(payload) }
  function refresh() { infoModel.refresh() }

  Variants {
    model: Quickshell.screens
    PanelWindow {
      id: panel
      required property var modelData
      screen: modelData
      visible: root.opened && !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "gb10-ai-overlay"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      updatesEnabled: visible

      ScreenMoveRemap {
        id: remapGuard
        window: panel
      }

      Rectangle {
        id: keyCatcher
        anchors.fill: parent
        color: Util.alpha(infoModel.themeBackground, 0.92)
        focus: root.opened
        Keys.onEscapePressed: function(event) {
          if (!clusterView.dismissSelection()) root.close()
          event.accepted = true
        }
        onVisibleChanged: if (visible) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        MouseArea { anchors.fill: parent; onClicked: { if (!clusterView.dismissSelection()) root.close() } }

        ClusterView {
          id: clusterView
          anchors.fill: parent
          desk: infoModel
        }
      }
    }
  }
}
