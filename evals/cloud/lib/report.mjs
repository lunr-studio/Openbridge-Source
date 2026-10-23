// Frozen inventory is the five checked-in D contracts, not sixteen product cases.
export const inventory=[
  ['contracts.spec.mjs','[F1] finalized upload is ready only after the controlled storage barrier','D'],
  ['contracts.spec.mjs','[N04] replay retains one revision and receipt; changed payload conflicts','D'],
  ['contracts.spec.mjs','[N05] invalid original segment IDs fail before a content write','D'],
  ['mcp.spec.mjs','[F3] HTTP JSON-RPC tool call returns today’s cited architecture and actions','D'],
  ['retrieval.spec.mjs','[F2] exact question and provisional snapshot traverse HTTP with historical evidence','D']
];
export function validateReport(report,{started,finished}) {
  const findings=new Set();const add=code=>findings.add(code);
  const observed=[];const counts={expected:0,unexpected:0,flaky:0,skipped:0};
  const finite=x=>typeof x==='number' && Number.isFinite(x) && x>=0;
  // Reporter uses milliseconds from two clock sources; allow 100ms rounding skew.
  const inWindow=(time,duration)=>Number.isFinite(Date.parse(time)) && finite(duration)
    && Date.parse(time)>=started && Date.parse(time)+duration<=finished+100;
  try {
    if(!Array.isArray(report.errors) || !Array.isArray(report.suites)) add('PLAYWRIGHT_REPORT_SCHEMA_INVALID');
    const visit=suites=>{
      if(!Array.isArray(suites)) {add('PLAYWRIGHT_REPORT_SCHEMA_INVALID');return;}
      for(const suite of suites) {
        if(suite.suites!==undefined) visit(suite.suites);
        if(suite.specs!==undefined && !Array.isArray(suite.specs)) {add('PLAYWRIGHT_REPORT_SCHEMA_INVALID');continue;}
        for(const spec of suite.specs || []) {
          if(!Array.isArray(spec.tests) || !spec.tests.length) {add('PLAYWRIGHT_REPORT_SCHEMA_INVALID');continue;}
          let specOK=true;
          for(const t of spec.tests) {
            observed.push([spec.file,spec.title,t.projectName]);
            if(t.projectId!=='D' || t.expectedStatus!=='passed') add('PLAYWRIGHT_CONTRACT_INVENTORY_MISMATCH');
            if(!Array.isArray(t.results) || !t.results.length) {add('PLAYWRIGHT_REPORT_SCHEMA_INVALID');continue;}
            for(const [index,result] of t.results.entries()) {
              if(!['passed','failed','timedOut','skipped','interrupted'].includes(result.status)
                || !finite(result.duration) || result.retry!==index || !Array.isArray(result.errors)
                || (result.status==='passed' && result.errors.length)) add('PLAYWRIGHT_REPORT_SCHEMA_INVALID');
              if(!inWindow(result.startTime,result.duration)) add('PLAYWRIGHT_REPORT_OUTSIDE_CURRENT_RUN');
            }
            const last=t.results.at(-1).status;
            const aggregate=last==='passed'?(t.results.length>1?'flaky':'expected'):last==='skipped'?'skipped':'unexpected';
            counts[aggregate]++;if(aggregate==='unexpected')specOK=false;
            if(t.status!==aggregate) add('PLAYWRIGHT_AGGREGATE_MISMATCH');
          }
          if(spec.ok!==specOK) add('PLAYWRIGHT_AGGREGATE_MISMATCH');
        }
      }
    };visit(report.suites);
    const sorted=rows=>rows.map(row=>JSON.stringify(row)).sort();
    if(JSON.stringify(sorted(observed))!==JSON.stringify(sorted(inventory))) add('PLAYWRIGHT_CONTRACT_INVENTORY_MISMATCH');
    const stats=report.stats;
    if(!stats || Object.entries(counts).some(([key,value])=>!Number.isInteger(stats[key]) || stats[key]!==value)) add('PLAYWRIGHT_STATS_MISMATCH');
    if(!stats || !inWindow(stats.startTime,stats.duration)) add('PLAYWRIGHT_REPORT_OUTSIDE_CURRENT_RUN');
  } catch {add('PLAYWRIGHT_REPORT_SCHEMA_INVALID');}
  return [...findings];
}
