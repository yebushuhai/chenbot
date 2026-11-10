/** Server-side OpenAI-compatible vision adapter. Never put API keys on a client. */
const MAX_BYTES = 8 * 1024 * 1024;
export function validateResult(data) {
  if (!data || !Array.isArray(data.items) || data.items.length < 1 || data.items.length > 8) throw new Error('Invalid number of items');
  if (data.items.some((item) => item?.kind === 'adjective') && (data.items.length !== 1 || data.items[0].kind !== 'adjective')) throw new Error('Invalid adjective fallback');
  return { items: data.items.map((item) => {
    if (!item || !['object', 'adjective'].includes(item.kind)) throw new Error('Invalid item kind');
    const required = ['word', 'reading', 'zh', 'en_definition', 'example', 'example_zh'];
    for (const field of required) if (typeof item[field] !== 'string' || item[field].length > 500 || (field !== 'reading' && !item[field].trim())) throw new Error(`Invalid ${field}`);
    if (item.kind === 'object') {
      if (!Array.isArray(item.box) || item.box.length !== 4 || item.box.some((v) => typeof v !== 'number' || !Number.isFinite(v) || v < 0 || v > 1) || item.box[0] >= item.box[2] || item.box[1] >= item.box[3]) throw new Error('Invalid object bounding box');
    } else if (item.box !== null) throw new Error('Adjectives must not have a bounding box');
    return Object.fromEntries([...required, 'kind', 'box'].map((key) => [key, item[key]]));
  }) };
}
export async function recognizeImage({bytes, mimeType, language, apiKey, baseUrl, model = 'deepseek-flash', fetchImpl = fetch}) {
  if (!Buffer.isBuffer(bytes) || bytes.length === 0 || bytes.length > MAX_BYTES) throw new Error('Image size is invalid');
  const jpeg = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes.length >= 8 && bytes.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10]));
  if (!((mimeType === 'image/jpeg' && jpeg) || (mimeType === 'image/png' && png))) throw new Error('Unsupported or mismatched image type');
  if (!['en','ja'].includes(language)) throw new Error('Unsupported language');
  if (!apiKey || !baseUrl) throw new Error('Vision service is not configured');
  const endpoint = new URL(baseUrl);
  if (endpoint.protocol !== 'https:') throw new Error('Vision endpoint must use HTTPS');
  endpoint.pathname = endpoint.pathname.replace(/\/$/, '') + '/chat/completions';
  const prompt = `Identify up to 8 clearly visible, useful vocabulary objects in this image. Return only JSON: {"items":[{"kind":"object","word":"...","reading":"...","zh":"...","en_definition":"...","example":"...","example_zh":"...","box":[x1,y1,x2,y2]}]}. box coordinates normalized 0 to 1, corresponding to the unrotated displayed image. word and example must be in ${language === 'ja' ? 'Japanese; include kana reading' : 'English; reading may be empty'}. zh and example_zh in Chinese; en_definition in English. If no clear object exists, return exactly one useful descriptive adjective with kind adjective and box null. Do not identify people or infer sensitive attributes.`;
  const response = await fetchImpl(endpoint, {method:'POST', headers:{authorization:`Bearer ${apiKey}`, 'content-type':'application/json'}, signal:AbortSignal.timeout(60000), body:JSON.stringify({model, messages:[{role:'user',content:[{type:'image_url', image_url:{url:`data:${mimeType};base64,${bytes.toString('base64')}`}},{type:'text',text:prompt}]}]})});
  if (!response.ok) throw new Error(`Vision provider returned HTTP ${response.status}`);
  const json = await response.json();
  const content = json?.choices?.[0]?.message?.content;
  if (typeof content !== 'string' || content.length > 20000) throw new Error('Invalid provider response');
  let result;
  try { result = JSON.parse(content.replace(/^```(?:json)?\s*/i,'').replace(/\s*```$/,'')); } catch { throw new Error('Provider returned invalid JSON'); }
  return validateResult(result);
}
