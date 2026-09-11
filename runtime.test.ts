import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { collect, parseClusterTelemetry } from "./collector";

const fixture = () => JSON.parse(readFileSync(new URL("./examples/cluster.json", import.meta.url), "utf8"));
test("one to three named nodes validate with reconciled totals", () => {
  const doc = fixture();
  delete doc.fleet;
  doc.nodes = doc.nodes.slice(0, 1);
  doc.nodes[0].name = "workstation";
  doc.cluster = {nodes:1, nodesUp:1, cores:20, memUsedBytes:16*1024**3, memTotalBytes:128*1024**3, gpusBusy:1};
  expect(parseClusterTelemetry(JSON.stringify(doc))?.nodes[0].name).toBe("workstation");
  doc.nodes = [];
  expect(parseClusterTelemetry(JSON.stringify(doc))).toBeUndefined();
});
test("full 100-agent roster survives the reader and preserves optional metrics", () => {
  const doc = fixture();
  const f = doc.fleet;
  f.total = 100; f.residentAgents = 100; f.tiers = {standard:100};
  f.nodes = f.residentByNode = {node1:34,node2:33,node3:33};
  f.roster = Array.from({length:100}, (_, i) => ({id:`agent-${String(i+1).padStart(3,"0")}`, model:"example-model",tier:"standard",node:`node${i%3+1}`,resident:true,pairs:10,wildCorrect:.8,poolCorrect:.9,consensus:.7,dissent:3,ties:0,burn:-1,mint:2,wildLatencyS:5,poolElapsedS:6}));
  doc.nodes.forEach(n => n.agents = n.residentAgents = f.nodes[n.name]);
  expect(parseClusterTelemetry(JSON.stringify(doc))?.fleet.roster).toEqual(f.roster);
});
test("collector emits only the local feed with network and child processes forbidden", async () => {
  const dir = mkdtempSync(join(tmpdir(), "cluster-desk-"));
  try {
    const input = join(dir, "cluster.json");
    writeFileSync(input, JSON.stringify(fixture()));
    const preload = join(dir, "deny.ts");
    writeFileSync(preload, `const deny = () => { throw Error("Unexpected network or subprocess"); }; globalThis.fetch = deny; Bun.spawn = deny; Bun.spawnSync = deny;`);
    const proc = Bun.spawn([process.execPath,"--preload",preload,join(import.meta.dir,"collector.ts")], {env:{PATH:"/nonexistent",CLUSTER_DESK_TELEMETRY:input},stdout:"pipe",stderr:"pipe"});
    const output = await new Response(proc.stdout).text();
    expect(await proc.exited).toBe(0);
    const frames = output.trim().split("\n").map(s=>JSON.parse(s));
    const data = JSON.parse(frames.filter(f=>f.type==="chunk").map(f=>f.data).join(""));
    expect(Object.keys(data).sort()).toEqual(["cluster","error"]);
    expect(data.cluster.fleet.total).toBe(100);
    expect(readFileSync(input,"utf8")).toBe(JSON.stringify(fixture()));
    expect(collect("").error).toContain("CLUSTER_DESK_TELEMETRY");
    expect(collect(join(dir,"absent")).cluster).toBeNull();
  } finally { rmSync(dir,{recursive:true,force:true}); }
});
