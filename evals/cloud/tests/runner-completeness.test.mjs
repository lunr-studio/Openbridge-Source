import test,{before} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const cli=path.resolve('cli.mjs');let genuine;
function sandbox(t) {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'openbridge-report-completeness-'));
  t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));return directory;
}
function invoke(directory,fault) {
  const env={...process.env};
  if(fault) {
    const preload=path.join(directory,'child-fault.mjs');
    fs.writeFileSync(preload,`import fs from 'node:fs';\nif(process.argv[1]?.endsWith('/@playwright/test/cli.js')) {\n${fault}\n}\n`);
    env.NODE_OPTIONS=`${env.NODE_OPTIONS || ''} --import=${pathToFileURL(preload).href}`.trim();
  }
  const execution=spawnSync(process.execPath,[cli,'--lane','D','--out',directory],{env,encoding:'utf8',timeout:30_000});
  assert.equal(execution.error,undefined,execution.stderr);
  const report=JSON.parse(fs.readFileSync(path.join(directory,'report.json')));
  return {execution,report};
}
before(t=>{
  const initial=invoke(sandbox(t));assert.equal(initial.execution.status,0,initial.execution.stdout);
  genuine=JSON.parse(fs.readFileSync(initial.report.runner.raw_report));
});
function specifications(raw) {
  const result=[];const visit=suites=>{for(const suite of suites){visit(suite.suites || []);result.push(...suite.specs || []);}};
  visit(raw.suites);return result;
}
function blocked(result,finding) {
  assert.equal(result.execution.status,2,result.execution.stdout);
  assert.equal(result.report.component_status,'blocked');
  assert.equal(result.report.product_baseline.valid,false);
  assert.ok(result.report.preflight.findings.includes(finding),JSON.stringify(result.report.preflight));
}
test('genuine filtered one-contract execution cannot satisfy the fixed five-contract run',t=>{
  const result=invoke(sandbox(t),String.raw`process.argv.push('--grep','\\[F1\\]');`);
  blocked(result,'PLAYWRIGHT_CONTRACT_INVENTORY_MISMATCH');
  assert.equal(result.report.counts.passed,1);
});
const cases=[
  ['duplicated contract',r=>{const s=specifications(r);Object.assign(s[1],structuredClone(s[0]));},'PLAYWRIGHT_CONTRACT_INVENTORY_MISMATCH'],
  ['unknown contract',r=>{specifications(r)[0].title='[F1] unknown contract';},'PLAYWRIGHT_CONTRACT_INVENTORY_MISMATCH'],
  ['wrong project',r=>{specifications(r)[0].tests[0].projectName='other';},'PLAYWRIGHT_CONTRACT_INVENTORY_MISMATCH'],
  ['contradictory stats',r=>{r.stats.unexpected=1;},'PLAYWRIGHT_STATS_MISMATCH'],
  ['missing stats',r=>{delete r.stats;},'PLAYWRIGHT_STATS_MISMATCH'],
  ['missing errors array',r=>{delete r.errors;},'PLAYWRIGHT_REPORT_SCHEMA_INVALID'],
  ['passed attempt carrying errors',r=>{specifications(r)[0].tests[0].results[0].errors=[{message:'hidden failure'}];},'PLAYWRIGHT_REPORT_SCHEMA_INVALID'],
  ['contradictory test status',r=>{specifications(r)[0].tests[0].status='unexpected';},'PLAYWRIGHT_AGGREGATE_MISMATCH'],
  ['contradictory spec status',r=>{specifications(r)[0].ok=false;},'PLAYWRIGHT_AGGREGATE_MISMATCH'],
  ['negative attempt duration',r=>{specifications(r)[0].tests[0].results[0].duration=-1;},'PLAYWRIGHT_REPORT_SCHEMA_INVALID'],
  ['invalid retry ordinal',r=>{specifications(r)[0].tests[0].results[0].retry=7;},'PLAYWRIGHT_REPORT_SCHEMA_INVALID'],
  ['old attempt timestamp',r=>{specifications(r)[0].tests[0].results[0].startTime='2000-01-01T00:00:00Z';},'PLAYWRIGHT_REPORT_OUTSIDE_CURRENT_RUN']
];
for(const [name,mutate,finding] of cases) test(`${name} cannot become passing execution evidence`,t=>{
  const raw=structuredClone(genuine);mutate(raw);
  // Stamp otherwise-valid metadata in the current child window so each control
  // isolates its named defect rather than merely failing stale-input detection.
  const stamp=`const now=new Date().toISOString();if(raw.stats){raw.stats.startTime=now;raw.stats.duration=0;}const visit=suites=>{for(const suite of suites){visit(suite.suites || []);for(const spec of suite.specs || [])for(const item of spec.tests)for(const result of item.results){if(result.startTime!=='2000-01-01T00:00:00Z')result.startTime=now;if(result.duration>=0)result.duration=0;}}};visit(raw.suites);`;
  const result=invoke(sandbox(t),`const raw=${JSON.stringify(raw)};${stamp}fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,JSON.stringify(raw));process.exit(0);`);
  blocked(result,finding);
});
test('genuine old raw bytes copied to a fresh UUID path remain stale evidence',t=>{
  const result=invoke(sandbox(t),`fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,${JSON.stringify(JSON.stringify(genuine))});process.exit(0);`);
  blocked(result,'PLAYWRIGHT_REPORT_OUTSIDE_CURRENT_RUN');
});
