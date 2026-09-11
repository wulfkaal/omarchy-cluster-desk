import { expect, test } from "bun:test";
import { existsSync, readdirSync } from "fs";
import { join } from "path";

const lint = "/usr/lib/qt6/bin/qmllint";
for (const file of readdirSync(import.meta.dir).filter(f=>f.endsWith(".qml"))) {
  test(`${file} parses`,()=>{
    expect(existsSync(lint)).toBe(true);
    const r=Bun.spawnSync([lint,join(import.meta.dir,file)]);
    expect((r.stdout.toString()+r.stderr.toString()).split("\n").filter(l=>l.includes("[syntax]"))).toEqual([]);
  });
}
test("view loads, renders and supports selection and stale state", async()=>{
  const r=Bun.spawn(["/usr/lib/qt6/bin/qml","-I",join(import.meta.dir,"tests/qml-fixture"),join(import.meta.dir,"tests/preview.qml")], {env:{...process.env,QT_FORCE_STDERR_LOGGING:"1",QT_QPA_PLATFORM:"offscreen",QT_QUICK_BACKEND:"software",QT_QPA_PLATFORMTHEME:"generic",QML_XHR_ALLOW_FILE_READ:"1"},stdout:"pipe",stderr:"pipe"});
  const timeout=setTimeout(()=>r.kill(),10000);
  try {
    const output=(await Promise.all([new Response(r.stdout).text(),new Response(r.stderr).text()])).join("\n");
    expect(await r.exited,output).toBe(0);
    expect(output).toContain("CLUSTER_DESK_RENDER_OK");
    expect(output).not.toMatch(/ReferenceError|TypeError|is not a type|Cannot assign|Binding loop/);
  } finally {clearTimeout(timeout);}
},15000);
