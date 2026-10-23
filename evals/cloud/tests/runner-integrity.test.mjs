import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

// npm executes this suite in evals/cloud. Faults affect only the child runner,
// never product assertions, the parent CLI, or checked-in Playwright files.
const cli=path.resolve('cli.mjs');
const rawReport=status=>({errors:[],suites:[{specs:[{title:'[F1] injected runner result',tests:[{
  results:[{status,duration:1,errors:status==='failed'?[{message:'synthetic assertion failure'}]:[]}]
}]}]}]});
function sandbox(t) {
  const directory=fs.mkdtempSync(path.join(os.tmpdir(),'openbridge-runner-integrity-'));
  t.after(()=>fs.rmSync(directory,{recursive:true,force:true}));
  return directory;
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
function assertBlocked(result) {
  assert.equal(result.execution.status,2,result.execution.stdout);
  assert.equal(result.report.component_status,'blocked');
  assert.equal(result.report.product_baseline.valid,false);
  assert.ok(result.report.counts.blocked>0);
}
test('same output directory cannot reuse a previous pass after an early child failure',t=>{
  const directory=sandbox(t);
  const initial=invoke(directory);
  assert.equal(initial.execution.status,0);
  assert.equal(initial.report.counts.passed,5);
  const result=invoke(directory,'process.exit(78);');
  assertBlocked(result);
  assert.equal(result.report.counts.passed,0);
  assert.equal(result.report.runner.exit_status,78);
  assert.notEqual(result.report.run_id,initial.report.run_id);
  assert.notEqual(result.report.runner.raw_report,initial.report.runner.raw_report);
  assert.equal(fs.existsSync(result.report.runner.raw_report),false);
});
for(const exit of [1,78]) test(`passing report with child exit ${exit} is blocked`,t=>{
  const result=invoke(sandbox(t),`fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,${JSON.stringify(JSON.stringify(rawReport('passed')))});process.exit(${exit});`);
  assertBlocked(result);
  assert.equal(result.report.runner.exit_status,exit);
});
test('failed report with successful child exit is blocked',t=>{
  const result=invoke(sandbox(t),`fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,${JSON.stringify(JSON.stringify(rawReport('failed')))});process.exit(0);`);
  assertBlocked(result);
  assert.ok(result.report.preflight.findings.includes('PLAYWRIGHT_EXIT_REPORT_MISMATCH'));
});
test('signal-terminated runner is blocked',t=>{
  const result=invoke(sandbox(t),"process.kill(process.pid,'SIGTERM');");
  assertBlocked(result);
  assert.equal(result.report.runner.signal,'SIGTERM');
});
test('missing current-run report is blocked even with successful child exit',t=>{
  const result=invoke(sandbox(t),'process.exit(0);');
  assertBlocked(result);
  assert.ok(result.report.preflight.findings.includes('PLAYWRIGHT_REPORT_UNAVAILABLE'));
});
test('truncated JSON is blocked with a retained report rather than an uncaught error',t=>{
  const result=invoke(sandbox(t),"fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,'{');process.exit(0);");
  assertBlocked(result);
  assert.ok(result.report.preflight.findings.includes('PLAYWRIGHT_REPORT_INVALID'));
});
test('invalid report structure is blocked',t=>{
  const result=invoke(sandbox(t),"fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,JSON.stringify({suites:[null]}));process.exit(0);");
  assertBlocked(result);
  assert.ok(result.report.preflight.findings.includes('PLAYWRIGHT_REPORT_INVALID'));
});
test('empty discovery cannot become a passing run',t=>{
  const result=invoke(sandbox(t),"fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,JSON.stringify({suites:[],errors:[]}));process.exit(0);");
  assertBlocked(result);
  assert.ok(result.report.preflight.findings.includes('RUNNER_SETUP_OR_DISCOVERY_FAILURE'));
});
test('runner setup errors block otherwise passing test output',t=>{
  const raw=rawReport('passed');raw.errors=[{message:'synthetic runner setup error'}];
  const result=invoke(sandbox(t),`fs.writeFileSync(process.env.OPENBRIDGE_EVAL_RAW_REPORT,${JSON.stringify(JSON.stringify(raw))});process.exit(1);`);
  assertBlocked(result);
});
