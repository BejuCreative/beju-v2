// Instantly → CRM in seconds (Benas's side, 11-21). Instantly calls this on reply_received / lead_interested /
// email_bounced. It ONLY writes CRM rows; it never sends an email or changes anything in Instantly.
//  1. Check the shared secret (?k=… in the webhook URL; Instantly webhooks carry no signature).
//  2. Store the call once in webhook_inbox (unique source + event_key): retries/duplicates are acknowledged and ignored.
//  3. Answer 200 at once; then, in the background, fetch that ONE lead's latest emails from Instantly and refresh
//     reply_queue + threads with the same rules as ops-sync (same keys, so ops-sync's 10-min run never duplicates).
//     The existing reply_queue trigger turns a real reply into a CRM event (bell + Slack).
//  If anything fails (rate limit, bad payload) the row keeps the error and ops-sync picks the reply up within 10 min.
// Deploy with --no-verify-jwt (Instantly can't send a Supabase JWT); the secret check replaces it.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { AUTO, HUMAN, YES, bodyOf, snippet, fullText } from "../_shared/instantly_mail.ts";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const IKEY = Deno.env.get("INSTANTLY_API_KEY")!;
const SECRET = Deno.env.get("INSTANTLY_WEBHOOK_SECRET") || "";
const HANDLED = new Set(["reply_received", "lead_interested", "email_bounced"]);

function sameSecret(a: string, b: string) {            // constant-time compare
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
async function sha256(s: string) {
  const h = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(h)].map(b => b.toString(16).padStart(2, "0")).join("");
}
async function ig(path: string) {
  const r = await fetch("https://api.instantly.ai/api/v2" + path, { headers: { Authorization: `Bearer ${IKEY}` } });
  if (!r.ok) throw new Error(`Instantly ${r.status} ${path.split("?")[0]}`);
  return r.json();
}

// Refresh one lead exactly like ops-sync.replies() does for every lead (7-day window, REAL/AUTO, answered).
async function refreshLead(lead: string) {
  const d = await ig(`/emails?lead=${encodeURIComponent(lead)}&limit=25`);
  const mails: any[] = (d.items || []).filter((m: any) => (m.lead || "").toLowerCase() === lead);
  const isIn = (m: any) => (m.from_address_email || "").toLowerCase() === lead;
  const week = new Date(Date.now() - 7 * 864e5).toISOString();
  const rec = mails.filter(isIn).sort((a, b) => (b.timestamp_email || "").localeCompare(a.timestamp_email || ""));
  const lastOut = mails.filter(m => !isIn(m)).reduce((t, m) => (m.timestamp_email > t ? m.timestamp_email : t), "");
  let out = "no recent reply";
  const e = rec[0];
  if (e && e.timestamp_email >= week) {
    const s = snippet(bodyOf(e));
    const kind = AUTO.test(s) && !YES.test(s) && !HUMAN.test(s) ? "AUTO" : "REAL";
    const { data: prev } = await sb.from("reply_queue").select("received_at,answered,blocklisted").eq("lead_email", lead).maybeSingle();
    const same = prev && Date.parse(prev.received_at) === Date.parse(e.timestamp_email);
    const { error } = await sb.from("reply_queue").upsert({
      lead_email: lead, inbox: e.eaccount, received_at: e.timestamp_email, kind,
      answered: lastOut > e.timestamp_email || !!(same && prev.answered), blocklisted: !!(prev && prev.blocklisted),
      snippet: s.slice(0, 300), synced_at: new Date().toISOString(),
    }, { onConflict: "lead_email" });
    if (error) throw new Error("reply_queue: " + error.message);
    out = `reply_queue ${kind}`;
  }
  // threads: same rule as ops-sync (pipeline leads + Instantly "Interested" leads only)
  const [{ data: p }, { data: i }] = await Promise.all([
    sb.from("pipeline").select("email").eq("email", lead).maybeSingle(),
    sb.from("interested_leads").select("email").eq("email", lead).maybeSingle(),
  ]);
  if (p || i) {
    const th = mails.filter(m => m.id).map(m => ({
      msg_id: m.id, lead_email: lead, at: m.timestamp_email, direction: isIn(m) ? "in" : "out", inbox: m.eaccount,
      subject: (m.subject || "").slice(0, 200), snippet: snippet(bodyOf(m)).slice(0, 600), body: fullText(m) || null,
    }));
    if (th.length) {
      const { error } = await sb.from("threads").upsert(th, { onConflict: "msg_id" });
      if (error) throw new Error("threads: " + error.message);
      out += ` · threads ${th.length}`;
    }
  }
  return out;
}

async function handleEvent(id: number, type: string, lead: string) {
  let result = "", error: string | null = null;
  try {
    result = type === "email_bounced" ? "recorded (bounce)" : await refreshLead(lead);
  } catch (e) {
    error = String(e).slice(0, 300);                     // ops-sync covers it within 10 min
  }
  await sb.from("webhook_inbox").update({ processed_at: new Date().toISOString(), result, error }).eq("id", id);
  await sb.from("sync_status").upsert({ name: "instantly_webhook", ran_at: new Date().toISOString(), ok: !error,
                                        detail: `${type} ${lead}: ${error || result}`.slice(0, 200) });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  if (!sameSecret(new URL(req.url).searchParams.get("k") || "", SECRET)) return new Response("unauthorized", { status: 401 });
  let p: any;
  try { p = await req.json(); } catch (_) { return new Response("bad json", { status: 400 }); }
  const type = String(p.event_type || p.type || "").toLowerCase();
  const lead = String(p.lead_email || p.lead || p.email || "").trim().toLowerCase();
  const key = String(p.email_id || p.id || p.event_id || "") || await sha256(JSON.stringify(p));
  const { data, error } = await sb.from("webhook_inbox")
    .insert({ source: "instantly", event_key: key, event_type: type, lead_email: lead || null, payload: p })
    .select("id").maybeSingle();
  if (error) {
    if (error.code === "23505") return new Response("duplicate", { status: 200 });   // already received: ack, do nothing
    return new Response("store failed", { status: 500 });                            // Instantly retries; ops-sync covers
  }
  if (!HANDLED.has(type) || !lead.includes("@")) {
    await sb.from("webhook_inbox").update({ processed_at: new Date().toISOString(), result: "ignored (type or lead)" }).eq("id", data!.id);
    return new Response("ignored", { status: 200 });
  }
  // @ts-ignore EdgeRuntime exists in Supabase Edge Functions: answer at once, work in the background
  EdgeRuntime.waitUntil(handleEvent(data!.id, type, lead));
  return new Response("ok", { status: 200 });
});
