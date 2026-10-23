import { pack, policy, fingerprint } from './fixtures.mjs';
// Normalized contract facts are deterministic. Free-form semantic grading is not claimed.
export function gradeFacts(flow, facts, prose = '') {
  const findings = [];
  const expected = policy.facts[flow];
  if (!expected || !Array.isArray(facts)) return { status:'fail',findings:['INVALID_FACT_ENVELOPE'] };
  const seen = new Set();
  for (const fact of facts) {
    const required = expected.find(f=>f.id===fact?.id);
    if (!required || seen.has(fact.id)) { findings.push('UNEXPECTED_OR_DUPLICATE_FACT'); continue; }
    seen.add(fact.id);
    if (fact.text !== required.text) findings.push('UNSUPPORTED_NORMALIZED_FACT');
    const meeting = pack.meetings.find(m=>m.session_id===required.meeting_id);
    const segment = meeting.segments.find(s=>s.id===required.segment_id);
    if (!Array.isArray(fact.citations) || !fact.citations.length) findings.push('MISSING_CITATION');
    else for (const c of fact.citations) {
      if (!c || c.meeting_id!==required.meeting_id || c.segment_id!==segment.id
        || c.original_revision_id!==`sha256:${fingerprint(meeting.segments)}`
        || c.quote!==segment.text || c.provisional!==!segment.isFinal) findings.push('INVALID_ORIGINAL_CITATION');
    }
  }
  for (const fact of expected) if (!seen.has(fact.id)) findings.push('MISSING_REQUIRED_FACT');
  for (const pattern of policy.forbidden_patterns) if (new RegExp(pattern,'iu').test(String(prose))) findings.push('FORBIDDEN_CLAIM');
  return { status:findings.length?'fail':'pass',findings:[...new Set(findings)] };
}
export function classifyResponse({ setupReady, status }) {
  if (!setupReady || ![200,501].includes(status)) return {status:'blocked',baseline:false};
  return status===501 ? {status:'fail',baseline:true} : {status:'pass',baseline:false};
}
export function summarizeAttempts(attempts) {
  if (!attempts.length) return {status:'blocked',retries:0};
  const last=attempts.at(-1);
  return {status:last==='pass' && attempts.slice(0,-1).some(s=>s!=='pass')?'flaky':last,retries:attempts.length-1};
}
