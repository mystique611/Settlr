// Settlr — receipt OCR proxy.
//
// Called directly from the browser (Bill Split's "Scan Receipt" button)
// with a photo of a receipt. This function's only job is to forward the
// image to Gemini's vision API and hand back a structured item list —
// it never touches trip/bill data itself, so it needs no share token.
//
// Why this has to be an Edge Function rather than a plain client-side
// fetch: the Gemini API key is a secret. Anything shipped inside
// index.html is public to anyone who views source (unlike the Supabase
// anon key, which is safe to expose by design because RLS is the real
// gate) — so the key has to live server-side, as a Supabase secret this
// function reads via Deno.env.get(), never sent to or stored in the
// browser.
//
// Deploy with: supabase functions deploy scan-receipt --project-ref <ref>
// Secret required: supabase secrets set GEMINI_API_KEY=<your key> --project-ref <ref>
// Optional secret: GEMINI_MODEL (defaults to gemini-2.5-flash below) —
// set this if Google renames/retires the default model later, without
// needing a redeploy.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Keeps individual scans fast and cheap, and blocks anyone trying to
// push an oversized payload through this endpoint.
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;

// Per-IP throttle so a single visitor (or a script) can't burn through
// the project's Gemini quota. This is independent of the Postgres-side
// _check_rate_limit (0010) — that one only guards RPC calls that go
// through PostgREST, not this Edge Function.
const RATE_LIMIT_MAX = 15;
const RATE_LIMIT_WINDOW_MINUTES = 60;

const EXTRACTION_PROMPT = `You are reading a photo of a restaurant or shop receipt for a bill-splitting app. Return ONLY strict JSON, no markdown code fences, no commentary, matching exactly this shape:
{
  "items": [ { "description": string, "amount": number } ],
  "currency_guess": string or null,
  "subtotal": number or null,
  "tax": number or null,
  "service_charge": number or null,
  "tip": number or null,
  "total": number or null
}
Rules:
- One entry in "items" per distinct purchasable line. Do not include subtotal, tax, service charge, tip, or total lines as items — report those in the separate fields instead.
- "amount" is that line's printed price as a plain number (no currency symbol, no thousands separators).
- If a line shows a quantity greater than 1 (e.g. "2x Coke  7.00"), still report it as ONE item using the printed line total, not one item per unit.
- "currency_guess" is the ISO 4217 code you infer from symbols or text (e.g. "SGD", "USD"), or null if you can't tell.
- Use null for any field you genuinely cannot read — never guess a number.
- If the image isn't a receipt at all, return { "items": [], "currency_guess": null, "subtotal": null, "tax": null, "service_charge": null, "tip": null, "total": null }.`;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  let body: { image_base64?: string; mime_type?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Invalid request body' }, 400);
  }

  const { image_base64: imageBase64, mime_type: mimeType } = body || {};
  if (!imageBase64 || typeof imageBase64 !== 'string') {
    return jsonResponse({ error: 'Missing image_base64' }, 400);
  }
  if (!mimeType || !String(mimeType).startsWith('image/')) {
    return jsonResponse({ error: 'mime_type must be an image type' }, 400);
  }
  // base64 text is ~4/3 the size of the raw decoded bytes.
  if (imageBase64.length > (MAX_IMAGE_BYTES * 4) / 3) {
    return jsonResponse({ error: 'Image is too large — try a smaller photo (under 8MB).' }, 400);
  }

  const geminiKey = Deno.env.get('GEMINI_API_KEY');
  if (!geminiKey) {
    return jsonResponse({ error: 'Receipt scanning is not configured on this server yet.' }, 500);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const supabase = createClient(supabaseUrl!, serviceRoleKey!);

  const clientIp = (req.headers.get('x-forwarded-for') || 'unknown').split(',')[0].trim();

  if (await isRateLimited(supabase, clientIp)) {
    return jsonResponse({ error: 'Too many receipt scans from this connection — try again in a bit.' }, 429);
  }

  let parsed;
  try {
    parsed = await callGemini(geminiKey, imageBase64, mimeType);
  } catch (err) {
    console.error('Gemini call failed', err);
    return jsonResponse({ error: 'Could not read that receipt — try a clearer, well-lit photo.' }, 502);
  }

  // Log the attempt after a successful parse (not before), so a request
  // that fails validation above never counts against the caller's quota.
  await supabase.from('receipt_scan_log').insert({ client_ip: clientIp });

  return jsonResponse(parsed);
});

async function isRateLimited(supabase: ReturnType<typeof createClient>, ip: string): Promise<boolean> {
  const since = new Date(Date.now() - RATE_LIMIT_WINDOW_MINUTES * 60 * 1000).toISOString();
  const { count, error } = await supabase
    .from('receipt_scan_log')
    .select('id', { count: 'exact', head: true })
    .eq('client_ip', ip)
    .gte('created_at', since);
  if (error) {
    console.warn('Rate limit check failed, allowing the request through', error);
    return false;
  }
  return (count || 0) >= RATE_LIMIT_MAX;
}

async function callGemini(apiKey: string, imageBase64: string, mimeType: string) {
  const model = Deno.env.get('GEMINI_MODEL') || 'gemini-2.5-flash';
  const resp = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [
          {
            parts: [
              { text: EXTRACTION_PROMPT },
              { inlineData: { mimeType, data: imageBase64 } },
            ],
          },
        ],
        generationConfig: { temperature: 0, responseMimeType: 'application/json' },
      }),
    }
  );

  if (!resp.ok) {
    const errText = await resp.text().catch(() => '');
    throw new Error(`Gemini API error ${resp.status}: ${errText}`);
  }

  const data = await resp.json();
  const text = data?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error('Empty response from Gemini');

  // responseMimeType: 'application/json' should return bare JSON, but
  // strip markdown fences defensively in case a model variant wraps it.
  const cleaned = text.trim().replace(/^```json\s*/i, '').replace(/^```\s*/i, '').replace(/```\s*$/i, '');
  const result = JSON.parse(cleaned);

  if (!Array.isArray(result.items)) result.items = [];
  result.items = result.items
    .filter((it: any) => it && typeof it.description === 'string' && it.description.trim() && typeof it.amount === 'number' && it.amount > 0)
    .slice(0, 50)
    .map((it: any) => ({ description: String(it.description).trim(), amount: Math.round(it.amount * 100) / 100 }));

  return {
    items: result.items,
    currency_guess: typeof result.currency_guess === 'string' ? result.currency_guess : null,
    subtotal: typeof result.subtotal === 'number' ? result.subtotal : null,
    tax: typeof result.tax === 'number' ? result.tax : null,
    service_charge: typeof result.service_charge === 'number' ? result.service_charge : null,
    tip: typeof result.tip === 'number' ? result.tip : null,
    total: typeof result.total === 'number' ? result.total : null,
  };
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
