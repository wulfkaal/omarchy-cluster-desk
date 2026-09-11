import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import qs.Commons

Item {
  id: view
  required property var desk
  property int topInset: Math.round(40 * Style.fontScale)
  readonly property var cluster: desk.cluster || ({})
  readonly property double ageMs: desk.nowMs - desk.fetchedAtMs
  readonly property string freshness: !desk.fetchedAtMs ? "UNAVAILABLE" :
    (ageMs > 30000 ? "STALE · " : "") + Math.max(0, Math.floor(ageMs / 1000)) + "s ago"
  readonly property color textDim: Util.alpha(desk.themeForeground, 0.62)
  readonly property color cardBg: Util.alpha(desk.themeForeground, 0.06)
  readonly property color cardBorder: Util.alpha(desk.themeForeground, 0.12)
  function number(value) { return Number(value).toFixed(1) }
  function nodeRows() {
    if (cluster.v === 2) return cluster.nodes
    var f = cluster.fleet || {}
    return [cluster.host ? { name: "node1", reachable: true, sys: cluster.host, gpu: cluster.gpu,
      gpuProcs: cluster.gpuProcs, workloads: cluster.workloads, models: cluster.models, agents: (f.nodes || {}).node1,
      residentAgents: (f.residentByNode || {}).node1 } : {name: "node1", reachable: false, reason: "unavailable"}]
  }
  function headerText() {
    var c = cluster.cluster
    return desk.title + (c ? " · " + c.nodes + " nodes · " + c.cores + " cores · " + desk.bytes(c.memTotalBytes)
      + (c.nodesUp < c.nodes ? " · " + c.nodesUp + "/" + c.nodes + " up" : "") : (cluster.host ? " · single node" : " · " + (desk.error || "collecting…")))
      + (cluster.fleet ? " · " + (cluster.fleet.residentAgents === undefined ? "residency unknown" : cluster.fleet.residentAgents + " of " + cluster.fleet.total + " agents resident") : "")
  }
  function nodeText(n) {
    if (!n.reachable) return n.name + " · unreachable · " + n.reason
    var g = n.gpu, sys = n.sys, agents = n.residentAgents == null ? "residency unknown" : n.residentAgents + "/" + n.agents + " agents resident"
    var models = n.residentModelCount == null ? (n.models ? n.models.length + " reported" : "models unknown") : n.residentModelCount + " models resident"
    return n.name + " · " + agents
      + "\nRAM " + desk.bytes(sys.memUsedBytes) + " / " + desk.bytes(sys.memTotalBytes) + " · " + sys.cores + " cores"
      + "\nLoad " + number(sys.load1) + "/" + number(sys.load5) + "/" + number(sys.load15) + " · " + count(sys.procs) + " processes"
      + "\n" + (g ? "GPU " + number(g.utilPct) + "% · " + number(g.tempC) + " °C · " + number(g.powerW) + " W" : "GPU unavailable")
      + "\n" + (g ? "Mem activity " + number(g.memUtilPct) + "% · " + count(g.smClockMhz) + " MHz · " : "") + models
  }
  function cpuRows(n) {
    return (n.workloads || []).slice().sort(function(a,b) { return b.cpuPct-a.cpuPct || a.name.localeCompare(b.name) })
  }

  function fleetSummary() {
    var f = cluster.fleet
    if (!f) return "Fleet unavailable"
    function counts(values) { return Object.keys(values).map(function(k) { return k + " " + values[k] }).join(" / ") }
    return f.total + " workers · " + f.models + " models\nTiers " + counts(f.tiers)
  }
  function residencyText() {
    var f = cluster.fleet
    if (!f) return "Fleet unavailable"
    return f.residentAgents === undefined ? "Residency unknown · Ollama unavailable" : f.residentAgents + " of " + f.total + " resident"
  }
  function nodeResidencyText() {
    var f = cluster.fleet
    if (!f || !f.residentByNode) return "Per-node residency unavailable"
    return Object.keys(f.nodes).map(function(node) {
      return node + " " + (f.residentByNode[node] === null ? "unknown" : f.residentByNode[node] + "/" + f.nodes[node])
    }).join(" · ")
  }
  property int residentPage: 0
  readonly property var residentNames: (cluster.fleet || {}).residentModels || []
  readonly property real residentReserved: 4 * captionMeasure.implicitHeight
  function fleetAgreement() {
    if (!agentRows.length || agentRows.some(function(a) { return a.pairs === undefined || a.consensus === undefined || a.dissent === undefined })) return "Fleet alignment / dissent unavailable"
    var pairs=0, aligned=0, dissent=0
    agentRows.forEach(function(a) { pairs+=a.pairs; aligned+=a.consensus*a.pairs; dissent+=a.dissent })
    return pairs ? "Alignment " + percent(aligned/pairs) + " · dissent " + percent(dissent/pairs) : "Fleet alignment / dissent unavailable"
  }
  readonly property real summaryHeight: Math.max(nodesCard.contentHeight, workloadsCard.contentHeight, fleetCard.contentHeight)
  readonly property real agentsHeight: deskLayout.height - clusterHeader.height - 2 * deskLayout.spacing - summaryHeight
  readonly property bool residentOverflow: residentContent.height > residentReserved
  readonly property string agentOverflow: agentsHeight < 300 ? "AGENTS height " + Math.floor(agentsHeight) + "px < 300px"
    : deskLayout.width - 2 * Style.space(14) - detailWidth - Style.space(12) < 200 ? "AGENTS grid width < 200px"
    : agentsHeight - 20 < 21 * captionMeasure.implicitHeight ? "AGENTS detail text exceeds available height" : ""
  readonly property bool degraded: agentOverflow !== ""
  Label { id: captionMeasure; visible: false; text: "Mg" }
  readonly property int detailWidth: 400
  readonly property int cellGutter: 3
  readonly property real gutterBudget: 9 * cellGutter
  readonly property real agentSidePadding: Style.space(14) - gutterBudget / 2
  readonly property color residencyColor: desk.themeForeground
  readonly property int gridColumns: 10
  readonly property int gridCells: 100
  readonly property var agentRows: (cluster.fleet || {}).roster || []
  property string selectedId: ""
  property bool showRecord: false
  onAgentRowsChanged: if (selectedId && !agentRows.some(function(a) { return a.id === selectedId })) selectedId = ""
  readonly property var selectedAgent: agentRows.find(function(a) { return a.id === selectedId }) || null
  function dismissSelection() {
    if (!selectedId) return false
    selectedId = ""
    return true
  }
  function selectAgent(id) { selectedId = selectedId === id ? "" : id }
  function nodeTint(node) {
    var index = nodeRows().findIndex(function(n) { return n.name === node })
    return [desk.yellow, desk.cyan, desk.magenta][Math.max(0, index) % 3]
  }
  function agentFill(agent) {
    return agent.wildCorrect === undefined ? view.cardBg : Util.alpha(desk.green, 0.12 + agent.wildCorrect * 0.6)
  }
  function cellRole(a) {
    var name = a.model.split("/").pop(), parts = name.split(":"), family = parts[0]
    var size = (parts[1] || "").split("-")[0]
    return a.tier + " · " + family + (size && size !== "latest" ? " " + size : "")
  }
  function tierLegend() {
    var t = (cluster.fleet || {}).tierTimeouts
    return "AGENTS · model workers · tier budget " + (t ? Object.keys(t).map(function(k) { return k + " " + t[k] + "s" }).join(" / ") : "unavailable")
  }
  function modelSpec(a) {
    var n = nodeRows().find(function(n) { return n.name === a.node })
    var spec = ((cluster.fleet || {}).modelCatalogue || {})[a.model] || ((n || {}).models || []).find(function(m) { return m.name === a.model })
    return spec ? spec.params + " parameters · " + spec.quant : "Installed model spec unavailable"
  }
  function runtimeSpec(a) {
    var n = nodeRows().find(function(n) { return n.name === a.node })
    var m = ((n || {}).models || []).find(function(m) { return m.name === a.model })
    return m ? "ctx " + count(m.ctx) + " · VRAM " + desk.bytes(m.vram) : "runtime spec unavailable"
  }
  function concurrencyText(a) {
    var f = cluster.fleet, cap = (f.concurrencyCaps || {})[a.node]
    return cap === undefined ? "Concurrency unavailable" : cap + " agent" + (cap === 1 ? "" : "s") + " at a time on " + a.node
  }
  function optionsText(options) {
    if (options === undefined) return "—"
    return "{" + Object.keys(options).map(function(k) {
      var value = options[k]
      return JSON.stringify(k) + ": " + (k === "temperature" && Number.isInteger(value) ? value.toFixed(1) : JSON.stringify(value))
    }).join(", ") + "}"
  }
  function detailFields() {
    var a = selectedAgent
    if (!a) return []
    var f = cluster.fleet
    var n = nodeRows().find(function(n) { return n.name === a.node })
    var resident = a.resident === true ? "resident" : a.resident === false ? "not resident" : a.resident === null ? "unknown" : "unavailable"
    function value(v) { return v === undefined ? "—" : String(v) }
    return [["id", a.id], ["model", a.model], ["tier", a.tier], ["node", a.node],
      ["endpoint", value((f.nodeEndpoints || {})[a.node])], ["timeout", value((f.tierTimeouts || {})[a.tier])],
      ["options", view.optionsText(f.inferenceOptions)],
      ["live", resident + " · " + (n && n.reachable ? "node reachable" : "node unreachable")],
      ["pairs", value(a.pairs)], ["wildCorrect", value(a.wildCorrect)], ["poolCorrect", value(a.poolCorrect)],
      ["consensus", value(a.consensus)], ["dissent", value(a.dissent)], ["ties", value(a.ties)],
      ["burn", value(a.burn)], ["mint", value(a.mint)], ["wildLatencyS", value(a.wildLatencyS)],
      ["poolElapsedS", value(a.poolElapsedS)], ["asOf", f.metrics ? f.metrics.asOf : "unavailable"]]
  }

  function count(v) { return v === undefined ? "—" : Number(v).toLocaleString(Qt.locale("en_US"), 'f', 0) }
  function percent(v) { return v === undefined ? "—" : (v * 100).toFixed(1) + "%" }
  function signed(v) { return v === undefined ? "—" : (v > 0 ? "+" : "") + count(v) }
  function wildRank() {
    if (!selectedAgent || agentRows.some(function(a) { return a.wildCorrect === undefined })) return "rank unavailable"
    var rank = 1 + agentRows.filter(function(a) { return a.wildCorrect > selectedAgent.wildCorrect }).length
    var suffix = rank % 100 >= 11 && rank % 100 <= 13 ? "th" : rank % 10 === 1 ? "st" : rank % 10 === 2 ? "nd" : rank % 10 === 3 ? "rd" : "th"
    return rank + suffix + " of " + agentRows.length
  }
  readonly property bool taskAvailable: !!(selectedAgent && selectedAgent.taskTypes && cluster.fleet.taskBaselines && cluster.fleet.taskAnalysis)
  function detailLines() {
    if (!selectedAgent) return []
    var a = selectedAgent, fields = detailFields(), meta = cluster.fleet.taskAnalysis
    var date = meta ? new Date(meta.analysisDate).toLocaleDateString(Qt.locale("en_US"), "MMM yyyy") : "unavailable"
    function seconds(v) { return v === undefined ? "—" : number(v) + " s" }
    return [["", a.id + " · " + a.tier + " · " + concurrencyText(a)], fields[1], fields[4],
      ["tier budget", fields[5][1] + (fields[5][1] === "—" ? "" : " s per task")], fields[6], fields[7],
      ["pairs", count(a.pairs) + " · Historical · " + date + " · incl. replicates"],
      ["Solo correct", percent(a.wildCorrect) + " · " + (wildRank() === "rank unavailable" ? wildRank() : "rank " + wildRank())], ["Pool accepted", percent(a.poolCorrect)],
      ["Alignment", percent(a.consensus)], ["dissent / ties", count(a.dissent) + " / " + count(a.ties)],
      ["burn / mint", signed(a.burn) + " / " + signed(a.mint)],
      ["", "Solo latency " + seconds(a.wildLatencyS) + " · Pool process elapsed " + seconds(a.poolElapsedS)], fields[18], ["spec", modelSpec(a)], ["runtime", runtimeSpec(a)]]
  }
  function taskExtremes() {
    if (!taskAvailable) return []
    var rows = ["code", "general", "reasoning"].map(function(t) {
      var c = selectedAgent.taskTypes[t], b = cluster.fleet.taskBaselines[t]
      return {type:t, rate:c.n ? c.wildCorrect/c.n : undefined,
        delta:c.n && b.n ? c.wildCorrect/c.n-b.wildCorrect/b.n : undefined}
    })
    // Missing exposure cannot establish a best/worst across all three types.
    if (rows.some(function(r) { return r.delta === undefined })) return []
    return rows.sort(function(a,b) { return b.delta-a.delta || a.type.localeCompare(b.type) })
  }
  function taskVerdict(high) {
    var rows = taskExtremes()
    if (!rows.length) return "Task comparison unavailable"
    var r = rows[high ? 0 : rows.length-1]
    var tied = rows.filter(function(v) { return Math.abs(v.delta-r.delta)<1e-12 }).length > 1
    return r.type + " " + percent(r.rate) + ", " + (r.delta>=0?"+":"") + (100*r.delta).toFixed(1) + "pp" + (tied ? " (tied)" : "")
  }
  function latencyDistribution() {
    var values = agentRows.filter(function(a) { return selectedAgent && a.tier === selectedAgent.tier }).map(function(a) { return a.wildLatencyS }).filter(function(v) { return typeof v === "number" && isFinite(v) })
    values.sort(function(a,b) { return a-b })
    function q(p) { var i=(values.length-1)*p, lo=Math.floor(i); return values[lo]+(values[Math.ceil(i)]-values[lo])*(i-lo) }
    return values.length ? {n:values.length, median:q(.5), low:q(.25), high:q(.75)} : null
  }
  function tierBudget(a) { return ((cluster.fleet || {}).tierTimeouts || {})[a.tier] }
  readonly property var reviewCandidates: agentRows.filter(function(a) {
    return typeof a.wildLatencyS === "number" && isFinite(a.wildLatencyS) && tierBudget(a) > 0 && a.wildLatencyS > tierBudget(a)
  })
  function reviewHeading() {
    var meta = (cluster.fleet || {}).taskAnalysis
    var date = meta ? new Date(meta.analysisDate).toLocaleDateString(Qt.locale("en_US"), "MMM yyyy") : "date unavailable"
    return "Review candidates · historical " + date + " mean Wild / current budget:"
  }
  function reviewText(a) {
    return a.id + " " + number(a.wildLatencyS) + "/" + tierBudget(a) + "s" + (a.resident === true ? " (resident now)" : "")
  }
  function runnableText(a) {
    var n = nodeRows().find(function(n) { return n.name === a.node })
    if (!n || !n.reachable) return "Node unreachable; cannot verify now"
    var m = (n.models || []).find(function(m) { return m.name === a.model })
    if (m) return "Present on " + a.node + " · resident now"
    return a.resident === true ? "Resident reported; runtime spec unavailable"
      : a.resident === false ? "Not resident · installation unverified"
      : "Residency and installation unverified"
  }
  function verdictLines() {
    if (!selectedAgent) return []
    var a=selectedAgent, d=latencyDistribution(), meta=cluster.fleet.taskAnalysis
    var date=meta ? new Date(meta.analysisDate).toLocaleDateString(Qt.locale("en_US"), "MMM yyyy") : "date unavailable"
    return [["", a.id + " · " + a.tier + " · " + a.node], ["model", a.model],
      ["Solo correct", percent(a.wildCorrect) + " · " + wildRank()],
      ["Largest Δ", taskVerdict(true)], ["Smallest Δ", taskVerdict(false)],
      ["", "Solo correctness Δ vs fleet for the same task."],
      ["Mean Wild", a.wildLatencyS === undefined ? "unavailable" : number(a.wildLatencyS) + " s" + (tierBudget(a) > 0 ? " · " + (a.wildLatencyS / tierBudget(a)).toFixed(2) + "x its " + tierBudget(a) + " s budget" : " · budget unavailable")],
      ["Tier " + a.tier, d ? "median " + number(d.median) + " s · n=" + d.n : "latency unavailable"],
      ["Middle half", d ? number(d.low) + "–" + number(d.high) + " s · same tier" : "unavailable"],
      ["Now", runnableText(a)], ["Capacity", concurrencyText(a)],
      ["", "Alignment is agreement, not proof of correctness."],
      ["Evidence", count(a.pairs) + " pairs · " + date],
      ["", meta ? "Historical pairs may include repeated tasks." : "Task analysis unavailable; no task verdict."],
      ["", "One historical analysis; no claim of future skill."],
      ["", "Record → alignment, dissent, settings and model specs."]]
  }
  function fleetTasks() {
    var f=cluster.fleet || {}, b=f.taskBaselines
    return [["Task · historical", "Solo correct", "Pool accepted"]].concat(["code","general","reasoning"].map(function(t) {
      var c=(b || {})[t]
      return [t, c && c.n ? percent(c.wildCorrect/c.n) : "—", c && c.n ? percent(c.poolCorrect/c.n) : "—"]
    }))
  }
  function taskRows() {
    if (!taskAvailable) return []
    return [["Type", "n", "Correct", "Δ pp", "Accept", "Δ pp"]].concat(["code", "general", "reasoning"].map(function(t) {
      var c = selectedAgent.taskTypes[t], b = cluster.fleet.taskBaselines[t]
      function rate(k) { return c.n ? (100 * c[k] / c.n).toFixed(1) : "—" }
      function delta(k) {
        if (!c.n || !b.n) return "—"
        var v = 100 * (c[k] / c.n - b[k] / b.n)
        return (v >= 0 ? "+" : "") + v.toFixed(1)
      }
      return [t, count(c.n), rate("wildCorrect"), delta("wildCorrect"), rate("poolCorrect"), delta("poolCorrect")]
    }))
  }

  // Chrome consumes clicks beneath cell/background handlers, without changing selection.
  MouseArea {
    objectName: "chromeClicks"
    x: deskLayout.x; y: deskLayout.y
    width: deskLayout.width; height: deskLayout.height
    onClicked: {}
  }

  // Historical review uses the existing bottom margin, outside live telemetry cards.
  Item {
    id: reviewLine
    objectName: "reviewLine"
    x: deskLayout.x; y: deskLayout.y + deskLayout.height + 2
    width: deskLayout.width; height: captionMeasure.implicitHeight
    visible: !view.degraded
    readonly property real contentWidth: reviewEntries.width
    FontMetrics { id: reviewMetrics; font.pixelSize: Style.font.caption }
    readonly property var entryWidths: {
      var widths = [], remaining = width - reviewTitle.width - 10, candidates = view.reviewCandidates
      for (var i = 0; i < candidates.length; i++) {
        var more = candidates.length - i - 1
        var reserve = more ? 10 + reviewMetrics.advanceWidth("+" + more + " more") : 0
        var natural = reviewMetrics.advanceWidth(view.reviewText(candidates[i]))
        var available = remaining - reserve
        if (available < reviewMetrics.advanceWidth("…")) break
        widths.push(Math.min(natural, available))
        if (natural > available) break
        remaining -= natural + 10
      }
      return widths
    }
    readonly property int omitted: view.reviewCandidates.length - entryWidths.length
    MouseArea { anchors.fill: parent; onClicked: {} }
    Row {
      id: reviewEntries
      spacing: 10
      Label { id: reviewTitle; text: view.reviewHeading(); color: view.textDim; wrapMode: Text.NoWrap }
      Label { visible: !view.reviewCandidates.length; text: "none with available data"; color: view.textDim; wrapMode: Text.NoWrap }
      Repeater {
        model: reviewLine.entryWidths.length
        Label {
          required property int index
          readonly property var modelData: view.reviewCandidates[index]
          objectName: "reviewEntry"
          width: reviewLine.entryWidths[index]
          text: view.reviewText(modelData); wrapMode: Text.NoWrap; elide: Text.ElideRight
          MouseArea { anchors.fill: parent; onClicked: view.selectAgent(parent.modelData.id) }
        }
      }
      Label {
        objectName: "reviewOverflow"
        visible: reviewLine.omitted > 0
        text: "+" + reviewLine.omitted + " more"; color: view.textDim; wrapMode: Text.NoWrap
      }
    }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: desk.themeForeground
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }
  component HoverTip: Controls.ToolTip {
    id: tip
    contentItem: Text {
      text: tip.text; textFormat: Text.PlainText
      font.pixelSize: Style.font.caption; color: desk.themeForeground
    }
  }
  component Panel: Rectangle {
    id: panel
    property string title
    readonly property real contentHeight: body.y + body.height + Style.space(14)
    default property alias content: body.data
    objectName: title
    color: view.cardBg; border.color: view.cardBorder; radius: Style.cornerRadius
    RowLayout {
      anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
      anchors.margins: Style.space(14)
      Label { text: panel.title; font.pixelSize: Style.font.body; font.bold: true; Layout.fillWidth: true }
      Label { text: view.freshness; color: view.ageMs > 30000 ? desk.red : view.textDim }
    }
    Column {
      id: body
      anchors.top: parent.top; anchors.left: parent.left; anchors.right: parent.right
      anchors.topMargin: Style.space(48); anchors.leftMargin: Style.space(14); anchors.rightMargin: Style.space(14)
      spacing: Style.space(7)
    }
  }
  ColumnLayout {
    id: deskLayout
    anchors.fill: parent
    anchors.topMargin: view.topInset + Style.space(16)
    anchors.leftMargin: Style.space(24); anchors.rightMargin: Style.space(24); anchors.bottomMargin: Style.space(20)
    spacing: Style.space(12)
    Label {
      id: clusterHeader
      objectName: "clusterHeader"
      Layout.minimumHeight: 20 * Style.fontScale
      text: view.headerText(); font.pixelSize: Style.font.body; font.bold: true
      Layout.fillWidth: true
    }
    RowLayout {
      objectName: "summaryRow"
      Layout.fillWidth: true; Layout.minimumHeight: view.summaryHeight; Layout.maximumHeight: view.summaryHeight; spacing: Style.space(12)
      Panel {
        id: nodesCard
        title: "NODES"; Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true
        Repeater {
          model: view.nodeRows()
          delegate: Column {
            required property var modelData
            width: parent.width
            Label {
              objectName: "nodeRow"; width: parent.width
              text: view.nodeText(modelData).split("\n")[0]; font.bold: true
              color: modelData.reachable ? view.nodeTint(modelData.name) : view.textDim
              MouseArea { id: nodeHover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
              HoverTip { visible: nodeHover.containsMouse; text: (modelData.host || "Host unavailable") + " · " + (modelData.address || "address unavailable") }
            }
            Label {
              width: parent.width; visible: modelData.reachable
              text: view.nodeText(modelData).split("\n").slice(1).join("\n")
            }
          }
        }
      }
      Panel {
        id: workloadsCard
        title: "WORKLOADS"; Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 1
        Label { width: parent.width; text: "CPU 100% = 1 core · RAM % · click counts to page"; color: view.textDim }
        Repeater {
          model: view.nodeRows()
          delegate: Column {
            id: workNode
            required property var modelData
            property int cpuPage: 0
            property int gpuPage: 0
            readonly property var cpus: view.cpuRows(modelData)
            readonly property var gpus: modelData.gpuProcs || []
            width: parent.width; spacing: Style.space(2)
            // Stable slots: two CPU processes and one GPU process per node.
            Label {
              objectName: "workloadNodeHeading"
              width: parent.width; height: captionMeasure.implicitHeight
              color: view.nodeTint(workNode.modelData.name); font.bold: true
              text: workNode.modelData.name + (workNode.modelData.reachable ? " · cap " + (((cluster.fleet || {}).concurrencyCaps || {})[workNode.modelData.name] || "—")
                + " · CPU " + (workNode.cpus.length ? (workNode.cpuPage % Math.ceil(workNode.cpus.length/2))*2+1 : 0) + "–" + Math.min(workNode.cpus.length, (workNode.cpuPage % Math.max(1,Math.ceil(workNode.cpus.length/2)))*2+2) + "/" + workNode.cpus.length + " ›" : " · unreachable")
              MouseArea { objectName: "cpuPager"; anchors.fill: parent; onClicked: workNode.cpuPage++ }
            }
            Repeater {
              model: 2
              delegate: Item {
                required property int index
                property var process: workNode.cpus[(workNode.cpuPage % Math.max(1,Math.ceil(workNode.cpus.length/2)))*2+index]
                objectName: "workloadRow"
                width: workNode.width; height: captionMeasure.implicitHeight
                Label { objectName: "processName"; width: parent.width - cpuNumbers.width - 8; height: parent.height
                  text: parent.process ? parent.process.name : "—"; wrapMode: Text.NoWrap; elide: Text.ElideMiddle
                  MouseArea { id: cpuHover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                  HoverTip { visible: cpuHover.containsMouse; text: parent.text }
                }
                Label { id: cpuNumbers; anchors.right: parent.right; height: parent.height
                  text: parent.process ? "CPU " + number(parent.process.cpuPct) + "%  RAM " + number(parent.process.memPct) + "%" : ""
                  wrapMode: Text.NoWrap
                }
              }
            }
            Item {
              objectName: "gpuProcessRow"
              property var process: workNode.gpus[workNode.gpuPage % Math.max(1,workNode.gpus.length)]
              width: parent.width; height: captionMeasure.implicitHeight
              Label { objectName: "processName"; width: parent.width - gpuNumbers.width - 8; height: parent.height
                text: parent.process ? "GPU · " + parent.process.name : (workNode.modelData.gpuProcs === undefined ? "GPU processes unavailable" : "No GPU processes reported")
                wrapMode: Text.NoWrap; elide: Text.ElideMiddle
              }
              Label { id: gpuNumbers; anchors.right: parent.right; height: parent.height; wrapMode: Text.NoWrap
                text: parent.process ? "pid " + parent.process.pid + " · " + desk.bytes(parent.process.usedBytes) + " · " + (workNode.gpuPage % workNode.gpus.length+1) + "/" + workNode.gpus.length + " ›" : ""
              }
              MouseArea { id: gpuHover; objectName: "gpuPager"; anchors.fill: parent; hoverEnabled: true; onClicked: workNode.gpuPage++ }
              HoverTip { visible: gpuHover.containsMouse; text: parent.process ? parent.process.name + " · reported GPU allocation; click to page" : "No per-process GPU allocation available" }
            }
          }
        }
      }
      Panel {
        title: "FLEET"; Layout.fillWidth: true; Layout.preferredWidth: 1; Layout.fillHeight: true
        id: fleetCard
        Label { objectName: "fleetSummary"; width: parent.width; text: view.fleetSummary(); color: view.textDim }
        Label {
          objectName: "fleetResidency"; width: parent.width
          text: view.residencyText(); font.pixelSize: Style.font.body; font.bold: true
          color: cluster.fleet && cluster.fleet.residentAgents !== undefined ? desk.green : view.textDim
        }
        Label { objectName: "fleetNodeResidency"; width: parent.width; text: view.nodeResidencyText(); color: view.textDim }
        Column {
          objectName: "fleetTaskProfile"
          width: parent.width
          Repeater {
            model: view.fleetTasks()
            delegate: Row {
              required property var modelData
              objectName: "fleetTaskRow"
              width: parent.width; height: captionMeasure.implicitHeight
              Label { width: parent.width * .5; text: modelData[0]; wrapMode: Text.NoWrap }
              Label { width: parent.width * .25; text: modelData[1]; wrapMode: Text.NoWrap; horizontalAlignment: Text.AlignRight }
              Label { width: parent.width * .25; text: modelData[2]; wrapMode: Text.NoWrap; horizontalAlignment: Text.AlignRight }
            }
          }
        }
        Item {
          objectName: "residentBlock"
          width: parent.width; height: view.residentReserved
          readonly property real contentHeight: residentContent.height
          Label { objectName: "residentWarning"; width: parent.width; visible: view.residentOverflow
            text: "Resident names exceed reserved space (" + Math.ceil(residentContent.height) + " > " + Math.floor(view.residentReserved) + "px)." }
          clip: view.residentOverflow
          Column {
            id: residentContent
            visible: !view.residentOverflow
            width: parent.width; spacing: 0
            Label {
              objectName: "fleetModelOverflow"
              width: parent.width; height: captionMeasure.implicitHeight; wrapMode: Text.NoWrap
              text: "Resident name " + (view.residentNames.length ? view.residentPage % view.residentNames.length+1 : 0) + "/" + view.residentNames.length + " reported · " + ((cluster.fleet || {}).residentModelCount === undefined ? "total unknown" : cluster.fleet.residentModelCount + " total") + (view.residentNames.length>1 ? " ›" : "")
              MouseArea { objectName: "residentPager"; anchors.fill: parent; onClicked: view.residentPage++ }
            }
            Label {
              objectName: "residentModel"; width: parent.width; height: captionMeasure.implicitHeight
              text: view.residentNames.length ? view.residentNames[view.residentPage % view.residentNames.length] : "No resident names reported"
              wrapMode: Text.NoWrap; elide: Text.ElideMiddle
              MouseArea { id: modelHover; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
              HoverTip { visible: modelHover.containsMouse; text: parent.text }
            }
            Label { objectName: "fleetAgreement"; width: parent.width; height: captionMeasure.implicitHeight; text: view.fleetAgreement(); wrapMode: Text.NoWrap }
            Label { objectName: "fleetMeasureNote"; width: parent.width; height: captionMeasure.implicitHeight; text: "Solo: truth · Pool: votes. Not comparable."; color: view.textDim; wrapMode: Text.NoWrap }

          }
        }
        Label {
          objectName: "fleetHistoryDate"; width: parent.width
          text: cluster.fleet && cluster.fleet.metrics ? "Agent metrics · historical, as of " + cluster.fleet.metrics.asOf.slice(0, 10) : "Historical metrics unavailable"
          color: view.textDim
        }
      }
    }
    Rectangle {
      id: agentsCard
      objectName: "AGENTS"
      Layout.fillWidth: true; Layout.fillHeight: true
      color: view.cardBg; border.color: view.cardBorder; radius: Style.cornerRadius
      Label {
        objectName: "layoutWarning"
        anchors.fill: parent; anchors.margins: Style.space(14)
        visible: view.degraded
        text: "Agent layout needs more space: " + view.agentOverflow + "."
      }
      Item {
        visible: !view.degraded
        objectName: "agentsRegion"
        anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: parent.width - Style.space(14) - view.detailWidth
        MouseArea { objectName: "stripClicks"; anchors.fill: parent; onClicked: view.dismissSelection() }
      }
      Row {
        id: encodingLegend
        objectName: "agentsHeading"
        visible: !view.degraded
        x: view.agentSidePadding
        y: (agentsGrid.y - height) / 2
        spacing: 10
        height: captionMeasure.implicitHeight
        Label { text: "AGENTS · Historical solo correctness"; wrapMode: Text.NoWrap }
        Label { text: "0%"; wrapMode: Text.NoWrap }
        Row {
          height: parent.height
          Repeater {
            model: 21
            Rectangle {
              required property int index
              objectName: "accuracySwatch"
              width: 4; height: encodingLegend.height
              color: view.agentFill({wildCorrect: index / 20})
            }
          }
        }
        Label { text: "100%"; wrapMode: Text.NoWrap }
        Repeater {
          model: view.nodeRows().map(function(n) { return n.name })
          Row {
            required property string modelData
            spacing: 4
            Rectangle { objectName: "nodeSwatch"; width: 3; height: encodingLegend.height; color: view.nodeTint(parent.modelData) }
            Label { text: parent.modelData; wrapMode: Text.NoWrap }
          }
        }
        Row {
          spacing: 4
          Rectangle { objectName: "residentSwatch"; width: 18; height: encodingLegend.height; color: "transparent"; border.width: 2; border.color: view.residencyColor }
          Label { text: "resident now"; wrapMode: Text.NoWrap }
        }
        Row {
          spacing: 4
          Item {
            width: 12; height: encodingLegend.height
            Rectangle { objectName: "unknownSwatch"; anchors.centerIn: parent; width: 6; height: 6; rotation: 45; color: view.residencyColor }
          }
          Label { text: "residency unknown"; wrapMode: Text.NoWrap }
        }
        // Legend is chrome; gaps between agents below dismiss selection.
      }
      MouseArea { anchors.fill: encodingLegend; visible: encodingLegend.visible; onClicked: {} }
      Grid {
        id: agentsGrid
        objectName: "agentsGrid"
        visible: !view.degraded
        x: view.agentSidePadding; y: Style.space(48) - view.gutterBudget
        width: Math.max(200 + view.gutterBudget, agentsCard.width - 2 * view.agentSidePadding - view.detailWidth - Style.space(12))
        height: Math.max(200 + view.gutterBudget, agentsCard.height - y - Style.space(14))
        columns: view.gridColumns; rows: view.gridColumns; spacing: view.cellGutter
        Repeater {
          model: view.agentRows
          delegate: Rectangle {
            required property var modelData
            objectName: "agentCell"
            width: (agentsGrid.width - view.gutterBudget) / view.gridColumns; height: (agentsGrid.height - view.gutterBudget) / view.gridColumns
            color: view.agentFill(modelData)
            readonly property bool twoLines: height >= 2 * captionMeasure.implicitHeight
            readonly property bool empty: modelData.wildCorrect === undefined
            readonly property string residencyMark: modelData.resident === true ? "resident" : modelData.resident === false ? "absent" : modelData.resident === null ? "unknown" : "unavailable"
            Rectangle { objectName: "nodeTint"; width: 3; height: parent.height; color: view.nodeTint(modelData.node) }
            Rectangle {
              objectName: "residentOutline"
              anchors.fill: parent; color: "transparent"
              border.width: modelData.resident === true ? 2 : 0; border.color: view.residencyColor
            }
            Rectangle {
              objectName: "unknownMark"
              visible: modelData.resident === null
              x: 8; y: 8; width: 6; height: 6; rotation: 45; color: view.residencyColor
            }
            Rectangle {
              anchors.fill: parent; anchors.margins: 3; color: "transparent"
              border.width: view.selectedId === modelData.id ? 1 : 0; border.color: desk.yellow
            }
            Text {
              objectName: "cellLabel"
              x: 18; y: (parent.height - (parent.twoLines ? 2 : 1) * captionMeasure.implicitHeight) / 2
              width: parent.width - 23; height: captionMeasure.implicitHeight
              visible: parent.width >= 60
              text: modelData.id.replace(/^.*-/, "") + (modelData.wildCorrect === undefined ? "" : "  " + (modelData.wildCorrect * 100).toFixed(0) + "%")
              textFormat: Text.PlainText; wrapMode: Text.NoWrap; elide: Text.ElideRight
              verticalAlignment: Text.AlignVCenter
              font.pixelSize: Style.font.caption; color: desk.themeForeground
            }
            Text {
              objectName: "cellRole"
              x: 6; y: parent.height / 2; width: parent.width - 11; height: captionMeasure.implicitHeight
              visible: parent.width >= 60 && parent.twoLines
              text: view.cellRole(modelData)
              textFormat: Text.PlainText; wrapMode: Text.NoWrap; elide: Text.ElideMiddle
              font.pixelSize: Style.font.caption; color: desk.themeForeground
            }
            MouseArea {
              objectName: "cellClicks"
              enabled: !view.degraded
              anchors.fill: parent
              onClicked: view.selectAgent(modelData.id)
            }
          }
        }
      }
      Item {
        id: detailPanel
        objectName: "detailBand"
        visible: !view.degraded
        anchors.right: parent.right; anchors.rightMargin: view.agentSidePadding
        y: 10; width: view.detailWidth; height: parent.height - 20
        Label {
          objectName: "detailPrompt"
          width: parent.width; visible: !view.selectedAgent
          text: view.tierLegend() + "\n\nAn agent is a model worker on a node, with a per-task time budget and shared inference options. All workers face code, general and reasoning tasks.\n\nCells: id / solo correctness; tier / model. Fill uses the same scale. No % means unavailable. Historical metrics come from your publisher; solo and pool measurements use different criteria.\n\n" + ((cluster.fleet || {}).concurrencyReason || "Concurrency rationale unavailable.") + "\n\nSelect a worker for its historical verdict; switch to Record for full metrics and settings."
          color: view.textDim
        }
        Column {
          objectName: "detailContent"
          width: parent.width
          Repeater {
            model: view.showRecord ? view.detailLines() : view.verdictLines()
            delegate: Item {
              required property var modelData
              required property int index
              width: detailPanel.width; height: Math.max(captionMeasure.implicitHeight, Math.min(20 * Style.fontScale, detailPanel.height / 21))
              Text {
                id: fieldLabel
                objectName: "detailLabel"
                textFormat: Text.PlainText; wrapMode: Text.NoWrap
                text: modelData[0] ? modelData[0] + ":" : ""
                height: parent.height; font.pixelSize: Style.font.caption
                color: view.textDim
              }
              Text {
                objectName: "detailValue"
                textFormat: Text.PlainText; wrapMode: Text.NoWrap
                x: fieldLabel.text ? fieldLabel.width + 4 : 0; width: parent.width - x - (index === 0 ? 76 : 0); height: parent.height
                text: modelData[1]; elide: Text.ElideMiddle
                font.pixelSize: Style.font.caption; color: desk.themeForeground
              }
              Label {
                objectName: "detailToggle"
                visible: index === 0; anchors.right: parent.right; height: parent.height
                text: view.showRecord ? "Verdict ›" : "Record ›"; wrapMode: Text.NoWrap
                MouseArea { objectName: "detailToggleClicks"; anchors.fill: parent; onClicked: view.showRecord = !view.showRecord }
              }
            }
          }
          Repeater {
            model: view.taskRows()
            delegate: Row {
              required property var modelData
              objectName: "taskRow"
              height: Math.max(captionMeasure.implicitHeight, Math.min(20 * Style.fontScale, detailPanel.height / 21))
              spacing: 8
              Repeater {
                model: modelData
                delegate: Text {
                  required property string modelData
                  required property int index
                  objectName: "taskCell"
                  width: [74, 38, 60, 54, 60, 54][index]; height: parent.height
                  text: modelData; textFormat: Text.PlainText; wrapMode: Text.NoWrap
                  horizontalAlignment: index === 0 ? Text.AlignLeft : Text.AlignRight
                  font.pixelSize: Style.font.caption; color: desk.themeForeground
                }
              }
            }
          }
          Text {
            objectName: "taskExplanation"
            visible: !!view.selectedAgent
            width: parent.width
            height: Math.max(captionMeasure.implicitHeight, Math.min(20 * Style.fontScale, detailPanel.height / 21))
            text: view.taskAvailable ? "% not comparable; Δ vs own fleet task (pp)." : "No task analysis; measures not comparable."
            textFormat: Text.PlainText; wrapMode: Text.NoWrap
            font.pixelSize: Style.font.caption; color: view.textDim
          }
        }
      }
    }
  }
}
