import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
const cli=path.resolve('cli.mjs');
function sandbox(t) {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'openbridge exact evidence '));
  t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));return directory;
}
function invoke(directory,args,fault) {
  const env={...process.env};
  if(fault) {
    const preload=path.join(directory,'child-fault.mjs');
    fs.writeFileSync(preload,`import fs from 'node:fs';if(process.argv[1]?.endsWith('/@playwright/test/cli.js')){${fault}}`);
    env.NODE_OPTIONS=`${env.NODE_OPTIONS || ''} --import=${pathToFileURL(preload).href}`.trim();
  }
  const argv=[cli,...args,'--out',directory];
  const execution=spawnSync(process.execPath,argv,{env,encoding:'utf8',timeout:30_000});
  assert.equal(execution.error,undefined,execution.stderr);
  const report=JSON.parse(fs.readFileSync(path.join(directory,'report.json')));
  return {execution,report,argv};
}
test('retained invocation preserves executable, output path, duplicate arguments and cwd',t=>{
  const result=invoke(sandbox(t),['--lane','R','--lane','D','--target','reference']);
  assert.equal(result.execution.status,0,result.execution.stdout);
  assert.deepEqual(result.report.command,[process.execPath,...result.argv]);
  assert.equal(result.report.cwd,process.cwd());
});
test('setup blocker survives secondary exit/report and inventory findings',t=>{
  const result=invoke(sandbox(t),['--lane','D'],`const raw={errors:[{message:'synthetic discovery setup failure'}],suites:[],stats:{startTime:new Date().toISOString(),duration:0,expected:0,unexpected:0,flaky:0,skipped:0}};fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,JSON.stringify(raw));process.exit(1);`);
  assert.equal(result.execution.status,2,result.execution.stdout);
  assert.equal(result.report.component_status,'blocked');
  for(const finding of ['RUNNER_SETUP_OR_DISCOVERY_FAILURE','PLAYWRIGHT_EXIT_REPORT_MISMATCH','PLAYWRIGHT_CONTRACT_INVENTORY_MISMATCH']) {
    assert.ok(result.report.preflight.findings.includes(finding),JSON.stringify(result.report.preflight));
  }
  assert.equal(result.report.product_baseline.valid,false);
});
