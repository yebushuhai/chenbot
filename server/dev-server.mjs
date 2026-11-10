// Local developer-only bridge: no authentication, accounting, billing or
// production safeguards. Never bind this to a public interface or deploy it.
import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { recognizeImage } from './vision.mjs';
const token = process.env.CHENBOT_DEV_TOKEN;
const apiKey = process.env.DEEPSEEK_API_KEY;
if (!apiKey || !token || token.length < 24) throw new Error('Set DEEPSEEK_API_KEY and a random CHENBOT_DEV_TOKEN (at least 24 characters)');
const port = Number(process.env.PORT || 3218);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid port');
const json = (res, status, body) => { res.writeHead(status, {'content-type':'application/json', 'cache-control':'no-store', 'x-content-type-options':'nosniff'}); res.end(JSON.stringify(body)); };
http.createServer(async (req, res) => {
  if (req.method !== 'POST' || req.url !== '/v1/recognize') return json(res,404,{error:'Not found'});
  const supplied = Buffer.from(req.headers['x-chenbot-dev-token'] || ''); const expected = Buffer.from(token);
  if (supplied.length !== expected.length || !timingSafeEqual(supplied,expected)) return json(res,401,{error:'Unauthorized'});
  let raw = ''; let exceeded = false;
  for await (const chunk of req) { raw += chunk; if (Buffer.byteLength(raw)>12*1024*1024) { exceeded = true; break; } }
  if (exceeded) return json(res,413,{error:'Image too large'});
  try {
    const {image, mimeType, language} = JSON.parse(raw);
    if (typeof image !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(image)) return json(res,400,{error:'Invalid image'});
    const result = await recognizeImage({bytes:Buffer.from(image,'base64'),mimeType,language,apiKey,baseUrl:'https://api.deepseek.com'});
    return json(res,200,result);
  } catch (err) { console.error('Local recognition failed:', err.message); return json(res,502,{error:'Recognition failed'}); }
}).listen(port,'127.0.0.1',()=>console.log(`Chenbot development bridge listening on 127.0.0.1:${port}; never expose publicly.`));
