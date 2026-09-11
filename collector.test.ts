import { afterAll, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, symlinkSync, rmSync } from "fs";
import { join } from "path";
import { parseClusterTelemetry, readClusterTelemetry, frameSnapshot, structureWithinBudget } from "./collector";
const root = mkdtempSync(join(import.meta.dir, ".cluster-test-"));
afterAll(() => rmSync(root, { recursive: true, force: true }));
// Entirely invented validation data, unrelated to any deployed fleet.
const fixture = () => ({ v: 1, producedAt: "2000-01-01T00:00:00Z", fetchedAt: "2000-01-01T00:00:01.123456Z",
  host: { load1: 0, load5: .5, load15: .5, procs: 100, cores: 20, memUsedBytes: 8*1024**3, memTotalBytes: 32*1024**3 },
  gpu: { name: "Example GPU", utilPct: 0, memUtilPct: 0, tempC: 50, powerW: 20, smClockMhz: 1000 },
  workloads: [{ name: "<b>example-worker</b>", cpuPct: 2, memPct: 2 }],
  gpuProcs: [{ pid: 123, usedBytes: 1024**3, name: "example-runtime" }],
  models: [{ name: "example-model", vram: 1024**3, ctx: 1024, params: "1B", quant: "Q4" }],
  fleet: {total:100, tiers:{standard:100}, nodes:{node1:34,node2:33,node3:33}, models:4,
    residentAgents:3, residentModels:["example-model"],
    metrics:{asOf:"2000-01-01T00:00:00Z",agents:100,
      top:Array.from({length:4},(_,i)=>({id:`agent-00${i+1}`,model:"example-model",tier:"standard",node:"node1",correctRate:.5,latencyS:1}))}}
});
function decode(frame: string) { return JSON.parse(frame.trim().split("\n").map(s => JSON.parse(s)).filter(f => f.type === "chunk").map(f => f.data).join("")); }
function v2fixture(): any {
  const f = fixture();
  const nodes = [1, 2, 3].map(i => ({name: `node${i}`, address: ["node1.example.invalid", "node2.example.invalid", "node3.example.invalid"][i-1],
    reachable: true, host: `host${i}`, sys: {...f.host, cores: 19+i, memUsedBytes: i*1024},
    gpu: {...f.gpu, utilPct: i===1 ? 17 : 0}, gpuProcs: f.gpuProcs, workloads: f.workloads,
    models: f.models, residentModelCount: 1, agents: i===1 ? 34 : 33, residentAgents: 1}));
  return {v:2, producedAt:f.producedAt, fetchedAt:f.fetchedAt, nodes,
    cluster:{nodes:3,nodesUp:3,cores:63,memUsedBytes:6144,memTotalBytes:f.host.memTotalBytes*3,gpusBusy:1},
    fleet:{...f.fleet,residentByNode:{node1:1,node2:1,node3:1}}};
}
test("strict telemetry schema and receiver epoch", () => {
  const doc = fixture();
  expect(parseClusterTelemetry(JSON.stringify(doc))).toEqual({ ...doc, fetchedAtMs: Date.parse(doc.fetchedAt) });
  for (const mutate of [
    d => d.v = true, d => d.extra = 1, d => d.gpu = null, d => delete d.gpu.powerW,
    d => d.host.procs = 1.5, d => d.host.procs = true, d => d.host.load1 = "0", d => d.host.load1 = -1,
    d => d.workloads[0].cpuPct = 2001, d => delete d.host.cores,
    d => { d.workloads = []; delete d.host.cores; },
    d => d.host.cores = 0, d => d.host.cores = 1.5, d => d.host.cores = true,
    d => d.host.cores = null, d => d.host.cores = "20", d => d.host.cores = -1,
    d => d.workloads[0].cpuPct = -1, d => d.workloads[0].cpuPct = true,
    d => d.workloads[0].memPct = 101, d => d.gpu.utilPct = 101, d => d.gpu.memUtilPct = 101, d => d.gpu.name = "😀".repeat(33), d => d.models[0].extra = 1,
    d => d.fleet.metrics.top[0].model = "x\n", d => d.fleet.residentAgents = .5, d => d.fleet.extra = 0,
    d => delete d.fleet.metrics.asOf, d => d.fleet.metrics.asOf = "2000-01-01", d => d.fleet.metrics = null,
    d => d.fleet.residentAgents = 101, d => d.fleet.tiers.standard = 99,
    d => d.fleet.metrics.top[0].correctRate = 1.1, d => d.fleet.metrics.top[0].latencyS = -1,
    d => d.fleet.metrics.top.reverse(), d => d.fleet.residentModels = Array(9).fill("x"),
    d => { delete d.fleet; d.agents = {}; },
    d => d.fetchedAt = null, d => d.fetchedAt = "2026-02-30T00:00:00Z", d => d.workloads = Array(9).fill(d.workloads[0]),
    d => d.models = [{ ...d.models[0], vram: 1 }, d.models[0]],
  ] as ((d: any) => void)[]) {
    const bad = fixture(); mutate(bad); expect(parseClusterTelemetry(JSON.stringify(bad))).toBeUndefined();
  }
  for (const text of ["{", "{}", " ".repeat(65537), JSON.stringify(doc).replace('"load1":0', '"load1":1e999')]) expect(parseClusterTelemetry(text)).toBeUndefined();
});

test("per-core CPU round-trips through file and snapshot at host capacity", () => {
  const path = join(root, "multicore.json");
  for (const cores of [1, 2, 20]) {
    const doc = fixture(); doc.host.cores = cores; doc.workloads[0].cpuPct = 100 * cores;
    writeFileSync(path, JSON.stringify(doc));
    const cluster = readClusterTelemetry(path);
    expect(cluster).toEqual({ ...doc, fetchedAtMs: Date.parse(doc.fetchedAt) });
    expect(decode(frameSnapshot({ cluster })).cluster.workloads[0].cpuPct).toBe(100 * cores);
    doc.workloads[0].cpuPct += .01;
    expect(parseClusterTelemetry(JSON.stringify(doc))).toBeUndefined();
  }
});

test("bounded file reader rejects absent, symlink, directory and oversize", () => {
  const path = join(root, "cluster.json"); writeFileSync(path, JSON.stringify(fixture()));
  expect(readClusterTelemetry(path)?.gpu.name).toBe("Example GPU");
  symlinkSync(path, join(root, "link"));
  for (const path of [join(root, "missing"), join(root, "link"), root]) expect(readClusterTelemetry(path)).toBeUndefined();
  writeFileSync(path, "x".repeat(65537)); expect(readClusterTelemetry(path)).toBeUndefined();
});

test("cluster sheds before snapshot byte budget throw", () => {
  const near: any = { padding: [Array(954).fill("x".repeat(512)), Array(954).fill("x".repeat(512))] };
  const size = Buffer.byteLength(JSON.stringify(decode(frameSnapshot(near))));
  near.tail = "x".repeat(960 * 1024 - size - 12);
  expect(frameSnapshot({ ...near, cluster: parseClusterTelemetry(JSON.stringify(fixture())) })).toBe(frameSnapshot(near));
  expect(decode(frameSnapshot({ cluster: parseClusterTelemetry(JSON.stringify(fixture())) })).cluster.fetchedAtMs).toBe(Date.parse(fixture().fetchedAt));
});

test("cluster sheds before structure budget throw", () => {
  const near = { padding: Array.from({ length: 49 }, () => Array(1019).fill(0)) };
  expect(structureWithinBudget(near)).toBe(true);
  const withCluster = { ...near, cluster: parseClusterTelemetry(JSON.stringify(fixture())) };
  expect(structureWithinBudget(withCluster)).toBe(false);
  expect(frameSnapshot(withCluster)).toBe(frameSnapshot(near));
  expect(withCluster.cluster).toBeDefined();
  expect(() => frameSnapshot({ padding: Array.from({ length: 50 }, () => Array(1024).fill(0)) })).toThrow("structure");
});

test("transition accepts legacy, absent fleet and unknown residency", () => {
  const doc: any = fixture();
  delete doc.fleet;
  expect(parseClusterTelemetry(JSON.stringify(doc))).toBeDefined();
  doc.agents = { busy: 1, idle: 2, offline: 0, lastActivity: [{ id: "a1", line: "working" }] };
  expect(parseClusterTelemetry(JSON.stringify(doc)).agents).toEqual(doc.agents);
  doc.fleet = fixture().fleet;
  expect(parseClusterTelemetry(JSON.stringify(doc))).toBeDefined();
  delete doc.models;
  delete doc.fleet.residentAgents;
  delete doc.fleet.residentModels;
  doc.fleet.residentByNode = { node1: 1, node2: null, node3: 0 };
  const parsed = parseClusterTelemetry(JSON.stringify(doc));
  expect(parsed.fleet.residentAgents).toBeUndefined();
  expect(parsed.fleet.metrics.top).toHaveLength(4);
  expect(decode(frameSnapshot({ cluster: parsed })).cluster.fleet).toEqual(doc.fleet);
  for (const mutate of [
    d => d.fleet.residentByNode.node1 = 49,
    d => d.fleet.residentByNode.node1 = true,
    d => delete d.fleet.residentByNode.node3,
    d => d.fleet.residentByNode.other = 0,
    d => d.fleet.residentByNode.node2 = 0,
    d => d.fleet.residentAgents = 1,
    d => d.fleet.residentModelCount = 1,
    d => d.agents.lastActivity[0].line = "x\n",
  ]) {
    const bad = structuredClone(doc); mutate(bad);
    expect(parseClusterTelemetry(JSON.stringify(bad))).toBeUndefined();
  }
});

test("per-node totals and omitted model counts are validated", () => {
  const doc: any = fixture();
  doc.fleet.residentByNode = { node1: 1, node2: 1, node3: 1 };
  doc.fleet.residentModelCount = 1;
  expect(parseClusterTelemetry(JSON.stringify(doc))).toBeDefined();
  for (const mutate of [d => d.fleet.residentByNode.node2 = 0,
    d => d.fleet.residentModelCount = 2, d => d.fleet.residentModelCount = true]) {
    const bad = structuredClone(doc); mutate(bad);
    expect(parseClusterTelemetry(JSON.stringify(bad))).toBeUndefined();
  }
});

test("v2 strict shapes, totals, independent observations, forward rollout and rollback", () => {
  const doc=v2fixture();
  for (const d of [fixture(), doc, fixture(), doc]) {
    const parsed=parseClusterTelemetry(JSON.stringify(d));
    expect(parsed).toEqual({...d,fetchedAtMs:Date.parse(d.fetchedAt)});
    expect(decode(frameSnapshot({cluster:parsed})).cluster.v).toBe(d.v);
  }
  for (const mutate of [d=>d.host={}, d=>d.nodes.reverse(), d=>d.nodes.pop(), d=>d.nodes[0].reachable=1,
    d=>delete d.nodes[0].sys, d=>delete d.nodes[0].workloads, d=>d.nodes[0].extra=1,
    d=>d.nodes[0].gpu=null, d=>d.nodes[0].agents=true, d=>d.nodes[0].residentModelCount=false,
    d=>d.nodes[0].residentModelCount=2, d=>d.nodes[0].residentAgents=49,
    d=>d.nodes[0].workerContract=1, d=>d.nodes[0].workloads[0].cpuPct=2001,
    d=>d.cluster.cores=60, d=>d.cluster.nodesUp=true, d=>delete d.fleet.residentByNode,
    d=>d.fleet.byNode=d.fleet.residentByNode, d=>d.nodes[1].reachable=false]) {
    const bad=structuredClone(doc); mutate(bad);
    expect(parseClusterTelemetry(JSON.stringify(bad))).toBeUndefined();
  }
  doc.nodes[1]={name:"node2",address:"node2.example.invalid",reachable:false,reason:"timeout"};
  doc.cluster={...doc.cluster,nodesUp:2,cores:42,memUsedBytes:4096,memTotalBytes:fixture().host.memTotalBytes*2};
  expect(parseClusterTelemetry(JSON.stringify(doc))).toBeDefined();
  for (const key of ["host","sys","gpu","gpuProcs","models","agents","residentAgents","residentModelCount","workloads"]) {
    const bad=structuredClone(doc); bad.nodes[1][key]=null;
    expect(parseClusterTelemetry(JSON.stringify(bad))).toBeUndefined();
  }
});

test("raw collector path rejects duplicate escaped keys and unknown coercion keys", () => {
  for (const doc of [fixture(),v2fixture()]) {
    const text=JSON.stringify(doc);
    expect(parseClusterTelemetry(text.replace('"v":','"v":0,"v":'))).toBeUndefined();
    expect(parseClusterTelemetry(text.replace('"v":','"\\u0076":0,"v":'))).toBeUndefined();
    expect(parseClusterTelemetry(text.replace('"load1":0','"load1":3,"load1":0'))).toBeUndefined();
    for (const trap of ["toString","valueOf","__proto__","constructor","prototype","toJSON"]) {
      expect(parseClusterTelemetry(text.replace('{',`{"${trap}":0,`))).toBeUndefined();
    }
    // String content containing apparent JSON syntax is not a duplicate key.
    const good=structuredClone(doc);
    (good.v===2?good.nodes[0]:good).workloads[0].name='"x":1,"x":2';
    expect(parseClusterTelemetry(JSON.stringify(good))).toBeDefined();
  }
});

test("128 KiB cap reaches actual regular-file reader without relaxing structure bounds", () => {
  const doc=v2fixture(), path=join(root,"large-v2.json");
  const text=JSON.stringify(doc);
  const padded=" ".repeat(100*1024-text.length)+text;
  writeFileSync(path,padded);
  expect(readClusterTelemetry(path)?.v).toBe(2);
  writeFileSync(path," ".repeat(128*1024+1-text.length)+text);
  expect(readClusterTelemetry(path)).toBeUndefined();
  const many=v2fixture();
  many.fleet.total=1000; many.fleet.models=0;
  many.fleet.tiers=Object.fromEntries(Array.from({length:1000},(_,i)=>['tier'+i,1]));
  many.fleet.nodes=Object.fromEntries(Array.from({length:1000},(_,i)=>['node'+i,1]));
  many.fleet.residentByNode=Object.fromEntries(Object.keys(many.fleet.nodes).map(k=>[k,null]));
  delete many.fleet.residentAgents; delete many.fleet.residentModels; delete many.fleet.metrics;
  expect(parseClusterTelemetry(JSON.stringify(many))).toBeUndefined();
});

test("v2 uncapped per-node model totals, nullable residency and snapshot shedding", () => {
  const doc=v2fixture();
  doc.nodes[0].models=Array.from({length:8},(_,i)=>({...doc.nodes[0].models[0],name:'m'+i}));
  doc.nodes[0].residentModelCount=12;
  doc.nodes[1].residentModelCount=null; delete doc.nodes[1].models;
  doc.nodes[1].residentAgents=null; doc.fleet.residentByNode.node2=null;
  delete doc.fleet.residentAgents; delete doc.fleet.residentModels;
  const parsed=parseClusterTelemetry(JSON.stringify(doc));
  expect(parsed.nodes[0].residentModelCount).toBe(12);
  expect(parsed.nodes[1].reachable).toBe(true);
  expect(parsed.fleet.metrics.top).toHaveLength(4);
  expect(decode(frameSnapshot({cluster:parsed})).cluster.nodes[1].residentAgents).toBeNull();
  const near={padding:Array.from({length:49},()=>Array(1019).fill(0))};
  expect(frameSnapshot({...near,cluster:parsed})).toBe(frameSnapshot(near));
});
