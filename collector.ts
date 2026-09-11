#!/usr/bin/env bun
// Read one explicitly configured local telemetry file. No network or subprocesses.
import { closeSync, constants, fstatSync, openSync, readSync, readFileSync } from "fs";
const MAX_FILE_BYTES = 128 * 1024;
const MAX_COLLECTION_ITEMS = 256;
const MAX_JSON_NODES = 50_000;
const MAX_JSON_DEPTH = 24;
const MAX_SNAPSHOT_BYTES = 960 * 1024;
const OUTPUT_FRAME_CHARS = 12 * 1024;
const COERCION_TRAPS = ["__proto__", "constructor", "prototype", "toString", "valueOf", "toJSON"];
export function readRegularFileLimited(p: string, maxBytes = MAX_FILE_BYTES, maxMs = 75): string | null {
  let fd = -1;
  try {
    fd = openSync(p, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const opened = fstatSync(fd);
    // FIFOs, sockets and devices are rejected before reading. procfs/sysfs
    // pseudo-files report as regular files and are safe with O_NONBLOCK.
    if (!opened.isFile() || opened.size > maxBytes) return null;
    const started = performance.now();
    const chunks: Buffer[] = [];
    let total = 0;
    while (true) {
      if (performance.now() - started > maxMs) return null;
      const room = maxBytes - total;
      const buffer = Buffer.allocUnsafe(Math.min(64 * 1024, room + 1));
      const bytes = readSync(fd, buffer, 0, buffer.byteLength, null);
      if (bytes === 0) break;
      total += bytes;
      if (total > maxBytes) return null;
      chunks.push(buffer.subarray(0, bytes));
    }
    return Buffer.concat(chunks, total).toString("utf8");
  } catch { return null; }
  finally { if (fd >= 0) try { closeSync(fd); } catch {} }
}
export function structureWithinBudget(value: unknown, maxNodes = MAX_JSON_NODES, maxDepth = MAX_JSON_DEPTH, sanitize = true): boolean {
  const stack: Array<{ value: any; depth: number }> = [{ value, depth: 0 }];
  let nodes = 0;
  while (stack.length) {
    const item = stack.pop()!;
    if (++nodes > maxNodes || item.depth > maxDepth) return false;
    if (!item.value || typeof item.value !== "object") continue;
    if (sanitize && !Array.isArray(item.value))
      for (const trap of COERCION_TRAPS) if (Object.prototype.hasOwnProperty.call(item.value, trap)) delete item.value[trap];
    const values = Array.isArray(item.value) ? item.value : Object.values(item.value);
    if (values.length > MAX_COLLECTION_ITEMS * 8) return false;
    for (const child of values) stack.push({ value: child, depth: item.depth + 1 });
  }
  return true;
}
function uiString(value: unknown, limit = 512): string {
  // Objects and arrays from external JSON are never text; "[object Object]"
  // on a card is a bug, and a shadowed toString used to throw here.
  if (value === null || value === undefined || typeof value === "object" || typeof value === "function") return "";
  // Every Text in the dashboard is textFormat: PlainText, so markup needs no
  // escaping — and escaping "&" turned ~/R&D into a directory that does not
  // exist when the same string fed Open Project / Resume / the clipboard.
  return String(value).slice(0, limit).replace(/[\u0000-\u001f\u007f]/g, " ");
}
// Arrays carry the recent-prompt rows (up to 1000 for heatmap drill-down);
// a 256 cap here silently threw away 3/4 of them while recentTruncated still
// said false. Byte and node budgets bound the frame regardless.
const MAX_UI_ARRAY_ITEMS = 1024;
function sanitizeForUi(value: any, depth = 0): any {
  if (depth > 12) return null;
  if (typeof value === "string") return uiString(value);
  if (Array.isArray(value)) return value.slice(0, MAX_UI_ARRAY_ITEMS).map(item => sanitizeForUi(item, depth + 1));
  if (value && typeof value === "object") {
    const result: Record<string, any> = {};
    for (const [rawKey, item] of Object.entries(value).slice(0, MAX_COLLECTION_ITEMS)) {
      const key = uiString(rawKey, 128);
      if (!key || key === "__proto__" || key === "constructor" || key === "prototype") continue;
      result[key] = sanitizeForUi(item, depth + 1);
    }
    return result;
  }
  return value;
}

// Cluster telemetry has its own closed contract; malformed data is group-absent.
const CLUSTER_BYTES = 128 * 1024;
const clusterSchemas: Record<string, Record<string, string>> = {
  host: { load1: "n", load5: "n", load15: "n", procs: "i", cores: "i", memUsedBytes: "i", memTotalBytes: "i" },
  gpu: { name: "s", utilPct: "p", memUtilPct: "p", tempC: "n", powerW: "n", smClockMhz: "n" },
  gpuProcs: { pid: "i", usedBytes: "i", name: "s" },
  workloads: { name: "s", cpuPct: "n", memPct: "p" },
  models: { name: "s", vram: "i", ctx: "i", params: "s", quant: "s" },
  fleetTop: { id: "id", model: "s", tier: "s", node: "s", correctRate: "n", latencyS: "n" },
};
function clusterObject(value: any): boolean { return value !== null && typeof value === "object" && !Array.isArray(value); }
function clusterRow(value: any, schema: Record<string, string>): boolean {
  if (!clusterObject(value) || Object.keys(value).length !== Object.keys(schema).length) return false;
  return Object.entries(schema).every(([key, kind]) => {
    const item = value[key];
    if (kind === "b") return item === null || typeof item === "boolean";
    if (["n", "i", "p", "signed"].includes(kind)) return typeof item === "number" && Number.isFinite(item) && (kind === "signed" || item >= 0)
      && (kind !== "i" || Number.isInteger(item)) && (kind !== "p" || item <= 100);
    if (typeof item !== "string" || item.length > (kind === "line" ? 140 : 64)
        || /[\p{Cc}\p{Cs}]/u.test(item) || item.trim().replace(/\s+/gu, " ") !== item) return false;
    return kind !== "id" || /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(item);
  });
}
const taskTypes = ["code", "general", "reasoning"];
function clusterTaskCounts(value: any, limit: number): boolean {
  return clusterObject(value) && Object.keys(value).length === 3 && taskTypes.every(t => {
    const c = value[t];
    return clusterRow(c, {n: "i", wildCorrect: "i", poolCorrect: "i"})
      && c.n <= limit && c.wildCorrect <= c.n && c.poolCorrect <= c.n;
  });
}
function clusterTasks(f: any): boolean {
  const rows = f.roster || [];
  if (!["taskBaselines", "taskAnalysis"].some(k => Object.hasOwn(f, k)) && !rows.some((a: any) => Object.hasOwn(a, "taskTypes"))) return true;
  const m = f.taskAnalysis;
  if (!rows.length || !clusterTaskCounts(f.taskBaselines, 50000) || !clusterObject(m)
      || Object.keys(m).length !== 4 || !clusterStamp(m.analysisDate) || m.analysisDate.length > 35
      || ![m.sourceSha256, m.rosterSha256].every(v => typeof v === "string" && /^[0-9a-f]{64}$/.test(v))
      || !Number.isInteger(m.sourceBytes) || m.sourceBytes <= 0 || m.sourceBytes > 64 * 1024 * 1024) return false;
  const sums: any = Object.fromEntries(taskTypes.map(t => [t, {n: 0, wildCorrect: 0, poolCorrect: 0}]));
  for (const a of rows) {
    if (!clusterTaskCounts(a.taskTypes, 500)) return false;
    const n = taskTypes.reduce((n, t) => n + a.taskTypes[t].n, 0);
    if (n <= 0 || n > 500 || n !== a.pairs || !["wildCorrect", "poolCorrect"].every(k => typeof a[k] === "number"
        && Math.abs(taskTypes.reduce((n, t) => n + a.taskTypes[t][k], 0) / n - a[k]) <= 0.00005 + 1e-12)) return false;
    for (const t of taskTypes) for (const k of Object.keys(sums[t])) sums[t][k] += a.taskTypes[t][k];
  }
  return taskTypes.every(t => Object.keys(sums[t]).every(k => sums[t][k] === f.taskBaselines[t][k]));
}
function clusterStamp(value: any): boolean {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|\+00:00)$/.test(value)) return false;
  const ms = Date.parse(value);
  return Number.isFinite(ms) && new Date(ms).toISOString().slice(0, 19) === value.slice(0, 19);
}
// Validate raw telemetry before any UI sanitiser can delete unknown keys.
function clusterJson(text: string): any {
  const value = JSON.parse(text);
  const tokens = text.match(/"(?:\\.|[^"\\])*"|[{}\[\],:]|[^\s{}\[\],:]+/g) || [];
  let i = 0;
  function visit(depth: number): void {
    if (depth > 8) throw new Error("telemetry depth");
    const token = tokens[i++];
    if (token === "{") {
      const keys = new Set<string>();
      while (tokens[i] !== "}") {
        const key = JSON.parse(tokens[i++]);
        if (keys.has(key)) throw new Error("duplicate telemetry key");
        keys.add(key);
        i++; // colon; JSON.parse already checked grammar
        visit(depth + 1);
        if (tokens[i] !== ",") break;
        i++;
      }
      i++;
    } else if (token === "[") {
      while (tokens[i] !== "]") {
        visit(depth + 1);
        if (tokens[i] !== ",") break;
        i++;
      }
      i++;
    }
  }
  visit(0);
  if (!structureWithinBudget(value, 4096, 8, false)) throw new Error("telemetry structure");
  return value;
}
function clusterV2(doc: any): any | undefined {
  const required = ["v", "producedAt", "fetchedAt", "cluster", "nodes"];
  if (!required.every(k => Object.hasOwn(doc, k)) || Object.keys(doc).some(k => ![...required, "fleet"].includes(k))
      || !clusterStamp(doc.producedAt) || !clusterStamp(doc.fetchedAt)
      || !Array.isArray(doc.nodes) || doc.nodes.length < 1 || doc.nodes.length > 3) return undefined;
  const totals = { nodes: doc.nodes.length, nodesUp: 0, cores: 0, memUsedBytes: 0, memTotalBytes: 0, gpusBusy: 0 };
  for (const [index, n] of doc.nodes.entries()) {
    if (!clusterObject(n) || (index > 0 && doc.nodes[index - 1].name >= n.name) || typeof n.reachable !== "boolean"
        || !clusterRow({name: n.name, address: n.address}, {name: "id", address: "s"})) return undefined;
    if (!n.reachable) {
      if (!clusterRow({name: n.name, address: n.address, reason: n.reason}, {name: "id", address: "s", reason: "id"})
          || Object.keys(n).length !== 4) return undefined;
      continue;
    }
    const requiredNode = ["name", "address", "reachable", "host", "sys", "workloads"];
    if (!requiredNode.every(k => Object.hasOwn(n, k))
        || Object.keys(n).some(k => ![...requiredNode, "gpu", "gpuProcs", "models", "agents", "residentAgents", "residentModelCount"].includes(k))
        || !clusterRow({host: n.host}, {host: "s"})) return undefined;
    const legacy: any = {v: 1, producedAt: doc.producedAt, fetchedAt: doc.fetchedAt, host: n.sys, workloads: n.workloads};
    for (const key of ["gpu", "gpuProcs", "models"]) if (Object.hasOwn(n, key)) legacy[key] = n[key];
    if (!parseClusterTelemetry(JSON.stringify(legacy))) return undefined;
    for (const key of ["agents", "residentAgents", "residentModelCount"]) {
      if (Object.hasOwn(n, key) && (n[key] !== null || key === "agents") && !clusterRow({count: n[key]}, {count: "i"})) return undefined;
    }
    if (n.residentAgents != null && n.agents !== undefined && n.residentAgents > n.agents) return undefined;
    if (n.residentModelCount != null && n.models && n.models.length !== Math.min(8, n.residentModelCount)) return undefined;
    totals.nodesUp++;
    for (const key of ["cores", "memUsedBytes", "memTotalBytes"]) totals[key] += n.sys[key];
    if (n.gpu?.utilPct >= 1) totals.gpusBusy++;
  }
  if (!clusterRow(doc.cluster, Object.fromEntries(Object.keys(totals).map(k => [k, "i"])))
      || Object.keys(totals).some(k => totals[k] !== doc.cluster[k])) return undefined;
  if (Object.hasOwn(doc, "fleet")) {
    if (!clusterObject(doc.fleet) || !Object.hasOwn(doc.fleet, "residentByNode")) return undefined;
    const host = {load1: 0, load5: 0, load15: 0, procs: 0, cores: 1, memUsedBytes: 0, memTotalBytes: 0};
    if (!parseClusterTelemetry(JSON.stringify({v: 1, producedAt: doc.producedAt, fetchedAt: doc.fetchedAt, host, workloads: [], fleet: doc.fleet}))) return undefined;
  }
  return {...doc, fetchedAtMs: Date.parse(doc.fetchedAt)};
}

export function parseClusterTelemetry(text: string): any | undefined {
  if (Buffer.byteLength(text, "utf8") > CLUSTER_BYTES) return undefined;
  try {
    const doc = clusterJson(text);
    if (clusterObject(doc) && doc.v === 2) return clusterV2(doc);
    const required = ["v", "producedAt", "fetchedAt", "host", "workloads"];
    if (!clusterObject(doc) || !required.every(k => Object.hasOwn(doc, k))
        || Object.keys(doc).some(k => ![...required, "gpu", "gpuProcs", "models", "fleet", "agents"].includes(k))
        || doc.v !== 1 || !clusterStamp(doc.producedAt) || !clusterStamp(doc.fetchedAt)
        || !clusterRow(doc.host, clusterSchemas.host) || doc.host.cores < 1) return undefined;
    if (Object.hasOwn(doc, "gpu") && !clusterRow(doc.gpu, clusterSchemas.gpu)) return undefined;
    for (const [key, order] of [["gpuProcs", "usedBytes"], ["workloads", "cpuPct"], ["models", "vram"]]) {
      if (!Object.hasOwn(doc, key)) continue;
      const rows = doc[key];
      if (!Array.isArray(rows) || rows.length > 8 || !rows.every((r: any) => clusterRow(r, clusterSchemas[key]))
          || (key === "workloads" && rows.some((r: any) => r.cpuPct > 100 * doc.host.cores))
          || rows.some((r: any, i: number) => i > 0 && rows[i - 1][order] < r[order])) return undefined;
    }
    if (Object.hasOwn(doc, "agents")) {
      const a = doc.agents;
      if (!clusterObject(a) || Object.keys(a).length !== 4 || !Object.hasOwn(a, "lastActivity")
          || !clusterRow({ busy: a.busy, idle: a.idle, offline: a.offline }, { busy: "i", idle: "i", offline: "i" })
          || !Array.isArray(a.lastActivity) || a.lastActivity.length > 4
          || !a.lastActivity.every((r: any) => clusterRow(r, { id: "id", line: "line" }))
          || a.lastActivity.some((r: any, i: number) => i > 0 && a.lastActivity[i - 1].id >= r.id)) return undefined;
    }
    if (Object.hasOwn(doc, "fleet")) {
      const f = doc.fleet;
      const keys = ["total", "tiers", "nodes", "models"];
      if (!clusterObject(f) || !keys.every(k => Object.hasOwn(f, k))
          || Object.keys(f).some(k => ![...keys, "metrics", "residentAgents", "residentModels", "residentByNode", "residentModelCount", "roster", "nodeEndpoints", "tierTimeouts", "inferenceOptions", "taskBaselines", "taskAnalysis", "modelCatalogue", "concurrencyCaps", "concurrencyReason"].includes(k))
          || !clusterRow({ total: f.total, models: f.models }, { total: "i", models: "i" })
          || f.models > f.total || f.total > 100) return undefined;
      for (const key of ["tiers", "nodes"]) {
        const counts = f[key];
        if (!clusterObject(counts) || !Object.entries(counts).every(([name, count]) => clusterRow({ name, count }, { name: "id", count: "i" }))
            || Object.values(counts).reduce((sum: number, n: any) => sum + n, 0) !== f.total) return undefined;
      }
      for (const [key, distribution, kind] of [["nodeEndpoints", "nodes", "s"], ["tierTimeouts", "tiers", "n"], ["concurrencyCaps", "nodes", "i"]]) {
        if (Object.hasOwn(f, key) && !clusterRow(f[key], Object.fromEntries(Object.keys(f[distribution]).map(k => [k, kind])))) return undefined;
      }
      const config = Object.fromEntries(["modelCatalogue", "concurrencyCaps", "concurrencyReason"].filter(k => Object.hasOwn(f, k)).map(k => [k, f[k]]));
      // Match the producer's ASCII JSON byte budget, including escaped UTF-16 units.
      if (JSON.stringify(config).replace(/[^\x00-\x7f]/g, c => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0")).length > 7000) return undefined;
      if (Object.hasOwn(f, "concurrencyReason") && (!Object.hasOwn(f, "concurrencyCaps")
          || typeof f.concurrencyReason !== "string" || f.concurrencyReason.length > 384
          || /[\p{Cc}\p{Cs}]/u.test(f.concurrencyReason) || f.concurrencyReason.trim().replace(/\s+/gu, " ") !== f.concurrencyReason)) return undefined;
      if (Object.hasOwn(f, "modelCatalogue")) {
        if (!clusterObject(f.modelCatalogue) || Object.keys(f.modelCatalogue).length > 40
            || !Object.entries(f.modelCatalogue).every(([name, spec]: [string, any]) =>
              clusterRow({name}, {name: "s"}) && f.roster?.some((a: any) => a.model === name)
              && clusterRow(spec, {params: "s", quant: "s"})
              && Object.values(spec).every((v: any) => v.length <= 16))) return undefined;
      }
      if (Object.hasOwn(f, "inferenceOptions")) {
        if (!clusterObject(f.inferenceOptions) || !clusterRow(f.inferenceOptions,
            Object.fromEntries(Object.entries({temperature: "n", num_predict: "i"}).filter(([k]) => Object.hasOwn(f.inferenceOptions, k))))) return undefined;
      }
      if (Object.hasOwn(f, "roster")) {
        if (!Array.isArray(f.roster) || f.roster.length !== f.total || f.roster.length > 100) return undefined;
        const requiredAgent = {id: "id", model: "s", tier: "id", node: "id", resident: "b"};
        const metrics = {pairs: "i", wildCorrect: "n", poolCorrect: "n", consensus: "n", dissent: "i", ties: "i",
          burn: "signed", mint: "signed", wildLatencyS: "n", poolElapsedS: "n"};
        if (!f.roster.every((a: any, i: number) => clusterObject(a)
            && clusterRow(Object.fromEntries(Object.entries(a).filter(([k]) => k !== "taskTypes")), {...requiredAgent, ...Object.fromEntries(Object.entries(metrics).filter(([k]) => Object.hasOwn(a, k)))})
            && Object.hasOwn(f.tiers, a.tier) && Object.hasOwn(f.nodes, a.node)
            && ["wildCorrect", "poolCorrect", "consensus"].every(k => !Object.hasOwn(a, k) || a[k] <= 1)
            && (i === 0 || f.roster[i - 1].id < a.id))) return undefined;
      }
      if (!clusterTasks(f)) return undefined;
      if (Object.hasOwn(f, "residentAgents") !== Object.hasOwn(f, "residentModels")) return undefined;
      if (Object.hasOwn(f, "residentByNode")) {
        const counts = f.residentByNode;
        if (!clusterObject(counts) || Object.keys(counts).length !== Object.keys(f.nodes).length
            || !Object.keys(f.nodes).every(node => Object.hasOwn(counts, node))
            || !Object.entries(counts).every(([node, count]) => count === null
              || (clusterRow({ count }, { count: "i" }) && (count as number) <= f.nodes[node]))) return undefined;
        const known = Object.values(counts).every(n => n !== null);
        if (known !== Object.hasOwn(f, "residentAgents")
            || (known && Object.values(counts).reduce((sum: number, n: any) => sum + n, 0) !== f.residentAgents)) return undefined;
      }
      if (Object.hasOwn(f, "residentAgents")) {
        if (!clusterRow({ count: f.residentAgents }, { count: "i" }) || f.residentAgents > f.total) return undefined;
        const names = f.residentModels;
        if (!Array.isArray(names) || names.length > Math.min(8, f.models, f.residentAgents)
            || !names.every((name: any) => clusterRow({ name }, { name: "s" }))
            || names.some((name: string, i: number) => i > 0 && names[i - 1] >= name)
            || Boolean(names.length) !== Boolean(f.residentAgents)) return undefined;
      }
      if (Object.hasOwn(f, "residentModelCount")) {
        if (!clusterRow({ count: f.residentModelCount }, { count: "i" }) || !Array.isArray(f.residentModels)
            || f.residentModelCount > Math.min(f.models, f.residentAgents)
            || f.residentModels.length !== Math.min(8, f.residentModelCount)) return undefined;
      }
      if (Object.hasOwn(f, "metrics")) {
        const m = f.metrics;
        if (!clusterObject(m) || Object.keys(m).length !== 3 || !clusterStamp(m.asOf)
            || !clusterRow({ agents: m.agents }, { agents: "i" }) || m.agents > f.total
            || !Array.isArray(m.top) || m.top.length !== Math.min(4, m.agents)
            || !m.top.every((r: any) => clusterRow(r, clusterSchemas.fleetTop) && r.correctRate <= 1
              && Object.hasOwn(f.tiers, r.tier) && Object.hasOwn(f.nodes, r.node))
            || new Set(m.top.map((r: any) => r.id)).size !== m.top.length
            || m.top.some((r: any, i: number) => i > 0 && (m.top[i - 1].correctRate < r.correctRate
              || (m.top[i - 1].correctRate === r.correctRate && m.top[i - 1].id >= r.id)))) return undefined;
      }
    }
    return { ...doc, fetchedAtMs: Date.parse(doc.fetchedAt) };
  } catch { return undefined; }
}
export function readClusterTelemetry(path = process.env.CLUSTER_DESK_TELEMETRY || process.env.GB10_CLUSTER_TELEMETRY || ""): any | undefined {
  const text = readRegularFileLimited(path, CLUSTER_BYTES);
  return text === null ? undefined : parseClusterTelemetry(text);
}

export function frameSnapshot(value: unknown): string {
  // sanitizeForUi caps depth at 12 and every collection, so an input that
  // passed its own bounds but sits deeper inside the snapshot (a 22-level
  // object smuggled in as a pid) can no longer trip the budget check into
  // replacing the whole desk with an error frame.
  const sanitized = sanitizeForUi(value);
  let payload = JSON.stringify(sanitized);
  if ((!structureWithinBudget(sanitized, MAX_JSON_NODES, MAX_JSON_DEPTH) || Buffer.byteLength(payload, "utf8") > MAX_SNAPSHOT_BYTES) && sanitized && typeof sanitized === "object" && "cluster" in sanitized) {
    delete sanitized.cluster; // Optional telemetry must never break the local desk (T8).
    payload = JSON.stringify(sanitized);
  }
  if (!structureWithinBudget(sanitized, MAX_JSON_NODES, MAX_JSON_DEPTH)) throw new Error("snapshot structure exceeded budget");
  if (Buffer.byteLength(payload, "utf8") > MAX_SNAPSHOT_BYTES) throw new Error("snapshot exceeded byte budget");
  const lines: string[] = [];
  for (let offset = 0; offset < payload.length; offset += OUTPUT_FRAME_CHARS) {
    lines.push(JSON.stringify({ v: 1, type: "chunk", data: payload.slice(offset, offset + OUTPUT_FRAME_CHARS) }));
  }
  lines.push(JSON.stringify({ v: 1, type: "end", chars: payload.length }));
  return lines.join("\n") + "\n";
}

function protocolError(message: string): string {
  return JSON.stringify({ v: 1, type: "error", message: uiString(message, 160) }) + "\n";
}

export function collect(path = process.env.CLUSTER_DESK_TELEMETRY || process.env.GB10_CLUSTER_TELEMETRY || "") {
  const cluster = readClusterTelemetry(path);
  return { cluster: cluster || null, error: !path ? "Set CLUSTER_DESK_TELEMETRY to a local telemetry JSON file" : !cluster ? "Telemetry unavailable: missing, unreadable or invalid file" : "" };
}
if (import.meta.main) {
  try {
    let snapshot;
    if (process.argv.includes("--demo")) {
      const doc = JSON.parse(readFileSync(new URL("./examples/cluster.json", import.meta.url), "utf8"));
      doc.producedAt = doc.fetchedAt = new Date().toISOString();
      snapshot = { cluster: parseClusterTelemetry(JSON.stringify(doc)), error: "" };
    } else snapshot = collect();
    await Bun.write(Bun.stdout, frameSnapshot(snapshot));
  } catch { await Bun.write(Bun.stdout, protocolError("Telemetry reader failed")); process.exitCode = 1; }
}
