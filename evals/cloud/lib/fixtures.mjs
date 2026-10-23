import fs from 'node:fs';
import crypto from 'node:crypto';
const directory = new URL('../../fixtures/cloud/v1/', import.meta.url);
export const pack = JSON.parse(fs.readFileSync(new URL('meetings.json', directory)));
export const policy = JSON.parse(fs.readFileSync(new URL('expectations.json', directory)));
export const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
export function validID(id) {
  return typeof id === 'string' && id.length > 0 && Buffer.byteLength(id, 'utf8') <= 128
    && !id.includes('/') && id !== '.' && id !== '..' && !/^__.*__$/s.test(id)
    && !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(id);
}
// Fixture serializer, not the future general-purpose production Swift port.
function fixtureNumber(n) {
  if (n === null) return 'nil';
  if (!Number.isFinite(n) || Math.abs(n) > 3600) throw new Error('Outside frozen fixture numeric domain');
  return Number.isInteger(n) ? (Object.is(n, -0) ? '-0.0' : `${n}.0`) : String(n);
}
export function fingerprint(segments) {
  const parts = [];
  for (const s of [...segments].sort((a,b) => a.sequence-b.sequence || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))) {
    for (const v of [s.id,s.meetingID,String(s.sequence),fixtureNumber(s.startOffset),fixtureNumber(s.endOffset),s.sourceLabel,s.text,String(s.isFinal)]) {
      parts.push(`${Buffer.byteLength(v, 'utf8')}:${v}\0`);
    }
  }
  return sha256(Buffer.from(parts.join(''), 'utf8'));
}
export function upload(id) {
  const meeting = structuredClone(pack.meetings.find(m => m.session_id === id));
  if (!meeting || meeting.timestamp_end === null) throw new Error('Finalized fixture required');
  const source_fingerprint = fingerprint(meeting.segments);
  return { schema_version:1,library_id:pack.library_id,session_id:id,
    original_revision_id:`sha256:${source_fingerprint}`,source_fingerprint,
    device_id:'fixture_mac_alex',user_id:meeting.user_id,timestamp_start:meeting.timestamp_start,
    timestamp_end:meeting.timestamp_end,raw_transcript:meeting.segments.map(s=>s.text).join(' '),segments:meeting.segments,
    consent:{grant_id:`consent_${id}`,purpose:'shared_library_upload',policy_version:'cloud-sharing-v1',
      granted_at:new Date(Date.parse(meeting.timestamp_start)-60_000).toISOString().replace('.000Z','Z')},
    retention:{policy:meeting.retention_policy,expires_at:new Date(Date.parse(meeting.timestamp_end)+7*86400_000).toISOString().replace('.000Z','Z')},
    metadata:{app_version:'fixture-1',audio_source:'synthetic_microphone',language:'en-US'} };
}
export function materializeFacts(flow) {
  return policy.facts[flow].map(f => {
    const meeting = pack.meetings.find(m=>m.session_id===f.meeting_id);
    const segment = meeting.segments.find(s=>s.id===f.segment_id);
    return { id:f.id,text:f.text,citations:[{meeting_id:f.meeting_id,
      original_revision_id:`sha256:${fingerprint(meeting.segments)}`,segment_id:f.segment_id,
      quote:segment.text,provisional:!segment.isFinal}] };
  });
}
export function canonicalJSON(value) {
  if (Array.isArray(value)) return '['+value.map(canonicalJSON).join(',')+']';
  if (value && typeof value === 'object') return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonicalJSON(value[k])).join(',')+'}';
  return JSON.stringify(value);
}
