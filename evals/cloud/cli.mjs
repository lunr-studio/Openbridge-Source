import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { preflight, root, sourceIdentity } from './lib/control.mjs';
import { pack, policy } from './lib/fixtures.mjs';
import { validateReport } from './lib/report.mjs';
const argv=process.argv.slice(2);const opts={lane:'D',target:'reference'};
for(let i=0;i<argv.length;i+=2){
  const key=argv[i]?.replace(/^--/,'');
  if(!['lane','target','out'].includes(key) || !argv[i+1])throw new Error('Use --lane D|R|N|C|A --target reference|absent [--out directory]');
  opts[key]=argv[i+1];
}
if(!['D','R','N','C','A'].includes(opts.lane) || !['reference','absent'].includes(opts.target))throw new Error('Invalid lane/target');
const run_id=randomUUID();const output=path.resolve(opts.out || path.join(root,'.local-evidence/cloud',run_id));
fs.mkdirSync(output,{recursive:true});
const started=new Date().toISOString();const setup=preflight(opts.lane);
const report={schema_version:1,run_id,started_at:started,finished_at:null,lane:opts.lane,
  target:opts.lane==='D'?`${opts.target}-test-double`:'unavailable',
  source:sourceIdentity(),environment:{os:`${os.platform()} ${os.release()} ${os.arch()}`,node:process.version,database:'none; isolated in-memory reference only'},
  fixture_version:pack.fixture_version,grader_version:policy.grader_version,
  clock:pack.clock,timezone:pack.timezone,preflight:setup,
  service_versions:{reference:'openbridge-eval-reference-v1',deployed:null},
  model_versions:{actual:null,documented_targets:['deepseek/deepseek-v4.1-flash','text-embedding-005/768']},
  counts:{passed:0,failed:0,flaky:0,retries:0,skipped:0,blocked:0},checks:[],
  product_status:'blocked',product_baseline:{valid:false,reason:'No implemented Cloud target is supplied by CLOUD-01.'},
  coverage:JSON.parse(fs.readFileSync(new URL('./cases.json',import.meta.url))).cases,
  command:[process.execPath,...process.argv.slice(1)],cwd:process.cwd()};
let exitCode=2;
if(setup.status==='ready') {
  const raw=path.join(output,`playwright-${run_id}.json`);
  const runnerStarted=Date.now();
  const execution=spawnSync(process.execPath,[fileURLToPath(new URL('./node_modules/@playwright/test/cli.js',import.meta.url)),'test','--project=D'],{
    cwd:fileURLToPath(new URL('./',import.meta.url)),encoding:'utf8',timeout:120_000,
    env:{...process.env,OPENBRIDGE_EVAL_RAW_REPORT:raw,OPENBRIDGE_EVAL_REFERENCE:opts.target==='absent'?'absent':'reference'}});
  const runnerFinished=Date.now();
  report.runner={started_at:new Date(runnerStarted).toISOString(),finished_at:new Date(runnerFinished).toISOString(),exit_status:execution.status,signal:execution.signal,
    error:execution.error?.code || null,raw_report:raw};
  const runnerFindings=[];let results;
  if(execution.error || execution.signal || ![0,1].includes(execution.status)) runnerFindings.push('PLAYWRIGHT_PROCESS_FAILURE');
  if(!fs.existsSync(raw)) runnerFindings.push('PLAYWRIGHT_REPORT_UNAVAILABLE');
  else try {results=JSON.parse(fs.readFileSync(raw));}
    catch {runnerFindings.push('PLAYWRIGHT_REPORT_INVALID');}
  if(runnerFindings.length) {
    report.preflight={status:'blocked',findings:runnerFindings};report.counts.blocked++;
  } else try {
    const strip=s=>String(s).replace(/\u001b\[[0-9;]*m/g,'');
    const visit=suites=>{for(const suite of suites || []){
      visit(suite.suites);
      for(const spec of suite.specs || [])for(const t of spec.tests || []){
        const attempts=t.results.map(x=>({status:x.status,duration_ms:x.duration,
          errors:(x.errors || []).map(e=>strip(e.message).slice(0,2000))}));
        const last=attempts.at(-1)?.status;
        const status=last==='passed'?(attempts.length>1?'flaky':'pass'):last==='skipped'?'skipped':'fail';
        const id=spec.title.match(/\[(F\d|N\d{2})\]/)?.[1];
        report.checks.push({case_id:id,title:spec.title,status,attempts});
        report.counts[status==='pass'?'passed':status==='fail'?'failed':status]++;
        report.counts.retries+=Math.max(0,attempts.length-1);
      }
    }};visit(results.suites);
    if(results.errors?.length || !report.checks.length) {
      report.preflight={status:'blocked',findings:['RUNNER_SETUP_OR_DISCOVERY_FAILURE']};report.counts.blocked++;
    }
    if(execution.status!==(report.counts.failed?1:0)) {
      report.preflight={status:'blocked',findings:[...report.preflight.findings,'PLAYWRIGHT_EXIT_REPORT_MISMATCH']};report.counts.blocked++;
    }
    const integrity=validateReport(results,{started:runnerStarted,finished:runnerFinished});
    if(integrity.length) {
      report.preflight={status:'blocked',findings:[...report.preflight.findings,...integrity]};report.counts.blocked++;
    }
    for(const c of report.coverage)c.reference_checks=report.checks.filter(x=>x.case_id===c.id).map(x=>({title:x.title,status:x.status}));
    const failures=report.checks.filter(x=>x.status==='fail');
    report.negative_control={requested:opts.target==='absent',
      demonstrated:opts.target==='absent' && report.preflight.status==='ready' && failures.length===report.checks.length && failures.length>0
        && failures.every(x=>x.attempts.some(a=>a.errors.some(e=>/Received:\s+501/.test(e)))),
      product_baseline:false,scope:'Healthy local reference deliberately lacks API behavior; this tests failure detection only.'};
    exitCode=report.counts.blocked?2:report.counts.failed || report.counts.flaky || report.counts.skipped?1:0;
  } catch {
    report.preflight={status:'blocked',findings:['PLAYWRIGHT_REPORT_INVALID']};report.counts.blocked++;
  }
} else report.counts.blocked=report.coverage.filter(c=>c.required_lanes.includes(opts.lane)).length;
report.component_status=exitCode===0?'pass':exitCode===1?'fail':'blocked';
report.finished_at=new Date().toISOString();
fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({component_status:report.component_status,product_status:report.product_status,lane:opts.lane,
  counts:report.counts,report:path.join(output,'report.json'),negative_control:report.negative_control},null,2));
process.exitCode=exitCode;
