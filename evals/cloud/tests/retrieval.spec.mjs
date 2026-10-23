import { test, expect, request } from '@playwright/test';
import { createReferenceService } from '../lib/reference.mjs';
import { pack, policy, fingerprint } from '../lib/fixtures.mjs';
import { gradeFacts } from '../lib/grading.mjs';
test('[F2] exact question and provisional snapshot traverse HTTP with historical evidence', async () => {
  const service = await createReferenceService({ absent: process.env.OPENBRIDGE_EVAL_REFERENCE === 'absent' });
  const client = await request.newContext({ baseURL: service.url, timeout: 5_000,
    extraHTTPHeaders: { Authorization: 'Fixture uid_alex' } });
  try {
    expect((await client.get('/health')).status()).toBe(200);
    const live = pack.meetings[2];
    const body = { schema_version: 1, library_id: pack.library_id, query_id: 'fixture_question',
      question: policy.questions.F2, snapshot_at: pack.clock, timezone: pack.timezone,
      transcript_snapshot: { session_id: live.session_id, source_fingerprint: fingerprint(live.segments), segments: live.segments } };
    const response = await client.post('/v1/meetings/live_today/query', { data: body });
    expect(response.status()).toBe(200);
    expect(service.snapshot().lastQuery).toEqual(body);
    const answer = await response.json();
    expect(gradeFacts('F2', answer.facts, answer.answer)).toEqual({ status: 'pass', findings: [] });
    expect(answer.historical_date).toBe('2026-10-09');
    expect(answer.facts.find(f => f.id === 'alex-current').citations[0].provisional).toBe(true);
    expect(service.snapshot().persistedLiveSnapshots).toBe(0);
  } finally { await client.dispose(); await service.close(); }
});
