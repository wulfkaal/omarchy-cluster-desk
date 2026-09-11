import QtQuick
import QtQuick.Window
import qs.Commons
import ".."

Window {
  id: window
  width: 1920; height: 1080; visible: true; color: "#10161c"
  QtObject {
    id: model
    property var cluster: ({})
    property string title: "CLUSTER DESK · DEMO"
    property string error: ""
    property double fetchedAtMs: Date.now()
    property double nowMs: Date.now()
    property color themeForeground: "#e2e8ed"
    property color green: "#9bc788"
    property color red: "#ed8585"
    property color yellow: "#e8bb77"
    property color cyan: "#83caca"
    property color magenta: "#ba9ed2"
    function bytes(n) { return (Number(n) / Math.pow(1024, 3)).toFixed(1) + "G" }
  }
  ClusterView { id: view; anchors.fill: parent; desk: model }
  Component.onCompleted: {
    var request = new XMLHttpRequest()
    request.open("GET", Qt.resolvedUrl("../examples/cluster.json"), false)
    request.send()
    model.cluster = JSON.parse(request.responseText)
    check.start()
  }
  Timer {
    id: check; interval: 500
    onTriggered: {
      if (view.nodeRows().length !== 3 || view.agentRows.length !== 100) Qt.exit(1)
      view.selectAgent("agent-001")
      if (!view.selectedAgent || view.detailFields().length === 0 || !view.dismissSelection()) Qt.exit(2)
      model.nowMs = model.fetchedAtMs + 31000
      if (view.freshness.indexOf("STALE") < 0) Qt.exit(3)
      model.nowMs = model.fetchedAtMs
      if (Qt.application.arguments.indexOf("--capture") >= 0) {
        window.contentItem.grabToImage(function(result) {
          if (!result.saveToFile(Qt.resolvedUrl("../docs/preview.png").toString().replace("file://", ""))) Qt.exit(4)
          console.log("CLUSTER_DESK_RENDER_OK")
          Qt.quit()
        })
      } else { console.log("CLUSTER_DESK_RENDER_OK"); Qt.quit() }
    }
  }
}
