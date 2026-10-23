import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { sha256 } from './fixtures.mjs';
export const root = fileURLToPath(new URL('../../../', import.meta.url));
const lockPath = new URL('../contract-lock.json', import.meta.url);
export function checkLock(overrides = {}) {
  if (!fs.existsSync(lockPath)) return ['CONTRACT_LOCK_MISSING'];
  const lock=JSON.parse(fs.readFileSync(lockPath));const findings=[];
  for (const [name,hash] of Object.entries(lock.files)) {
    const file=path.join(root,name);
    if (!fs.existsSync(file) || sha256(Object.hasOwn(overrides,name)?overrides[name]:fs.readFileSync(file))!==hash) findings.push(`PROTECTED_INPUT_CHANGED:${name}`);
  }
  return findings;
}
export function preflight(lane) {
  const findings=checkLock();
  if (Number(process.versions.node.split('.')[0])<20) findings.push('NODE_20_REQUIRED');
  const audioFile=path.join(root,'evals/fixtures/cloud/v1/audio.json');
  try {
    const audio=JSON.parse(fs.readFileSync(audioFile));
    if(sha256(fs.readFileSync(path.join(path.dirname(audioFile),audio.asset)))!==audio.sha256) findings.push('SPEECH_ASSET_CHANGED');
  } catch {findings.push('SPEECH_ASSET_UNAVAILABLE');}
  const missing={R:['STAGING_ADAPTER_NOT_IMPLEMENTED','APP_MCP_AUTH_SETUP_REQUIRED','APPROVED_PROVIDER_LEDGER_AND_CONFIG_REQUIRED'],
    N:['NATIVE_AUTOMATION_OR_NAMED_OPERATOR_EVIDENCE_REQUIRED'],
    C:['ALEX_ACTUAL_CODEX_OAUTH_INVOCATION_EVIDENCE_REQUIRED'],
    A:['EXACT_SIGNED_CANDIDATE_ALEX_QA_TRISHAN_ACCEPTANCE_REQUIRED']};
  if(missing[lane])findings.push(...missing[lane]);
  if(!['D','R','N','C','A'].includes(lane))findings.push('UNKNOWN_LANE');
  return {status:findings.length?'blocked':'ready',findings};
}
export function sourceIdentity() {
  const git=(...args)=>execFileSync('git',args,{cwd:root});
  const names=git('ls-files','--cached','--others','--exclude-standard','-z').toString().split('\0').filter(Boolean).sort();
  const files={},tree=[];
  for(const name of names) {
    const file=path.join(root,name);if(!fs.existsSync(file) || !fs.statSync(file).isFile())continue;
    const hash=sha256(fs.readFileSync(file));tree.push(name+'\0'+hash+'\0');
    if(name.startsWith('evals/'))files[name]=hash;
  }
  return {git_revision:git('rev-parse','HEAD').toString().trim(),dirty:!!git('status','--porcelain').length,
    tree_sha256:sha256(tree.join('')),files};
}
