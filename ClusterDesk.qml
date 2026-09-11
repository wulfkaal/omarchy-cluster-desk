import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

Scope {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || home + "/.local/state"
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"
  property string background: ""
  property real wallpaperOpacity: 0.22
  readonly property int clusterWorkspace: /^[1-9][0-9]?$/.test(Quickshell.env("CLUSTER_DESK_WORKSPACE") || "10") ? Number(Quickshell.env("CLUSTER_DESK_WORKSPACE") || "10") : 10
  property int focusedWorkspaceId: 0
  readonly property bool onClusterWorkspace: root.focusedWorkspaceId === root.clusterWorkspace

  Timer {
    interval: 400
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      var w = Hyprland.focusedWorkspace
      root.focusedWorkspaceId = w ? Number(w.id) : 0
    }
  }

  InfoModel {
    id: infoModel
    refreshMs: root.onClusterWorkspace ? 4000 : 20000
    active: true
  }

  function imageUrl(path) { return Util.fileUrl(path) }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.currentBackgroundLink]
    stdout: StdioCollector { onStreamFinished: root.background = String(text || "").trim() }
  }
  Timer { interval: 8000; running: true; repeat: true; triggeredOnStart: true; onTriggered: if (!readlinkProc.running) readlinkProc.running = true }

  IpcHandler {
    target: "wulfkaal.gb10"
    function refresh(): void { infoModel.refresh() }
    function status(): string { return JSON.stringify({ready: infoModel.ready, error: infoModel.error, version: "0.2.0", workspace: root.clusterWorkspace, fetchedAtMs: infoModel.fetchedAtMs, nodes: (infoModel.cluster.nodes || []).length}) }
    function setDemo(enabled: bool): void { infoModel.demoMode = enabled; infoModel.refresh() }
  }

  Variants {
    model: Quickshell.screens
    PanelWindow {
      required property var modelData
      screen: modelData
      visible: Hyprland.focusedWorkspace && Number(Hyprland.focusedWorkspace.id) === root.clusterWorkspace
      anchors { top: true; bottom: true; left: true; right: true }
      color: infoModel.themeBackground
      WlrLayershell.namespace: "omarchy-gb10-ai"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      updatesEnabled: visible

      Image {
        anchors.fill: parent
        source: root.imageUrl(root.background)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        opacity: root.wallpaperOpacity
      }

      ClusterView {
        anchors.fill: parent
        desk: infoModel
      }
    }
  }
}
