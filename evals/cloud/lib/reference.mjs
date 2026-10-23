import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { pack, fingerprint, validID, materializeFacts, canonicalJSON, sha256 } from './fixtures.mjs';
// Disposable in-memory test double. No provider, Firestore, IAM, OAuth or native implementation.
export async function createReferenceService({ absent=false } = {}) {
  let release, signalProcessing;
  const barrier=new Promise(resolve=>{release=resolve;});
  const processing=new Promise(resolve=>{signalProcessing=resolve;});
  const state={namespace:randomUUID(),ready:false,receipt:null,originals:[],vectors:[],facts:[],
    revisionCount:0,notificationIntent:null,lastQuery:null,lastInvocation:null,persistedLiveSnapshots:0};
  const jobs=new Map();
  const server=http.createServer(async (req,res)=>{
    const send=(status,body)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(body));};
    try {
      if (req.url==='/health') return send(200,{service:'openbridge-eval-reference-v1',reference_only:true,clock:pack.clock});
      if (absent) { signalProcessing();return send(501,{code:'NOT_IMPLEMENTED',target:'absent-reference',reference_only:true}); }
      if (req.headers.authorization!=='Fixture uid_alex') return send(403,{code:'FIXTURE_IDENTITY_DENIED'});
      const chunks=[];let size=0;
      for await (const chunk of req) {size+=chunk.length;if(size>8*1024*1024)return send(413,{code:'OVERSIZED'});chunks.push(chunk);}
      let body;try{body=JSON.parse(Buffer.concat(chunks).toString('utf8'));}catch{return send(400,{code:'INVALID_JSON'});}
      if (req.method==='POST' && req.url==='/v1/meetings/ingest') {
        if (!Array.isArray(body.segments) || !body.segments.length
          || body.segments.some(s=>!validID(s.id) || !s.isFinal || s.meetingID!==body.session_id)
          || body.source_fingerprint!==fingerprint(body.segments)
          || body.original_revision_id!==`sha256:${body.source_fingerprint}`) return send(422,{code:'INVALID_ORIGINAL'});
        const key=req.headers['idempotency-key'] || `${body.session_id}/${body.original_revision_id}`;
        const digest=sha256(canonicalJSON(body));
        if (jobs.has(key)) {
          const job=jobs.get(key);if(job.digest!==digest)return send(409,{code:'IDEMPOTENCY_CONFLICT'});
          return send(200,await job.completion);
        }
        const completion=(async()=>{
          signalProcessing();await barrier;
          state.originals=structuredClone(body.segments);
          state.vectors=body.segments.map(()=>[1,...Array(767).fill(0)]);
          state.facts=materializeFacts('F1');state.ready=true;state.revisionCount++;
          state.receipt={schema_version:1,session_id:body.session_id,original_revision_id:body.original_revision_id,
            status:'ready',receipt_id:`fixture_receipt_${state.namespace}`,ready_at:pack.clock};
          state.notificationIntent={receipt_id:state.receipt.receipt_id,text:'Insights from the latest meeting are available through MCP.'};
          return structuredClone(state.receipt);
        })();
        jobs.set(key,{digest,completion});return send(200,await completion);
      }
      if (req.method==='POST' && req.url==='/v1/meetings/live_today/query') {
        state.lastQuery=structuredClone(body);
        return send(200,{facts:materializeFacts('F2'),answer:materializeFacts('F2').map(f=>f.text).join(' '),historical_date:'2026-10-09'});
      }
      if (req.method==='POST' && req.url==='/mcp') {
        state.lastInvocation=structuredClone(body);
        if (body.method!=='tools/call' || body.params?.name!=='search_meetings') return send(405,{code:'READ_ONLY_REFERENCE'});
        return send(200,{jsonrpc:'2.0',id:body.id,result:{facts:materializeFacts('F3')}});
      }
      return send(404,{code:'UNKNOWN_REFERENCE_ROUTE'});
    } catch {if(!res.headersSent)send(503,{code:'REFERENCE_FAILURE'});else res.end();}
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  return {url:`http://127.0.0.1:${server.address().port}`,release,processing:()=>processing,
    snapshot:()=>structuredClone(state),close:async()=>{release();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));jobs.clear();state.originals=[];state.vectors=[];state.facts=[];} };
}
