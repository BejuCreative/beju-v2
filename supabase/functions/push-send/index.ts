// push-send (Benas's Claude, 2026-11-25): Web Push ("iPhone notifications") for the founder CRM. Needs crm_push1.sql.
// Deployed with --no-verify-jwt; the two callers are checked here:
//   1) DRAIN (pg_cron, every minute): header x-cron-secret = CRON_SECRET. Claims rows from public.push_outbox (written by DB
//      triggers on payments / tasks / pipeline / client_items), sends each to every live device that turned that event on,
//      marks the rows. More than 3 waiting rows of one event in one run are folded into ONE summary notification (no flood).
//   2) TEST (the "Send test" button): Authorization = a founder session (auth.getUser, profiles.is_admin, aal2, like slack-post),
//      body {test: true, endpoint?}. Sends one test notification to the caller's own live devices (or only `endpoint`).
// Devices that answer 404/410 are disabled at once (disabled_at); any other failure counts up failed_count, disabled at 10.
// Lock-screen text is written by the triggers: a first name or an amount, nothing more.
// Secrets (Supabase function secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (mailto:ops@example.com style; use a real
// ops mailbox when setting it), plus the existing CRON_SECRET. SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-actor": "push-send", "x-source": "cron" } }, auth: { persistSession: false } });
const ORIGINS = ["https://bejucreative.github.io", "https://bejucreative.digital", "https://www.bejucreative.digital"];
const MAX_FAILS = 10;
const SUMMARY: Record<string, (n: number) => string> = {
  money: (n) => `💰 ${n} payments in`,
  reply: (n) => `${n} new replies waiting`,
  sample_yes: (n) => `${n} new sample yeses`,
  client_changes: (n) => `${n} clients asked for changes`,
};

type Row = { id: number; event: string; ref: string; title: string; body: string; url: string; tag: string };
type Sub = { id: number; endpoint: string; p256dh: string; auth: string; events: string[]; failed_count: number };
type Msg = { title: string; body: string; url: string; tag: string; event: string };

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return { "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0], "Vary": "Origin",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret", "Access-Control-Allow-Methods": "POST, OPTIONS" };
}
function claims(jwt: string): Record<string, unknown> {
  try { const p = jwt.split(".")[1]; return JSON.parse(atob(p.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(p.length / 4) * 4, "="))); }
  catch { return {}; }
}

let VAPID_OK = false;
function vapid(): string | null {   // null = ready, else what is missing (never the values)
  if (VAPID_OK) return null;
  const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY"), subj = Deno.env.get("VAPID_SUBJECT");
  if (!pub || !priv || !subj) return "VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY and VAPID_SUBJECT must all be set";
  try { webpush.setVapidDetails(subj, pub, priv); VAPID_OK = true; return null; }
  catch (e) { return `VAPID keys rejected: ${(e as Error).message}`; }
}

// one push to one device; returns "ok" | "gone" | "fail"
async function sendOne(s: Sub, m: Msg): Promise<{ r: "ok" | "gone" | "fail"; why?: string }> {
  try {
    await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(m), { TTL: 6 * 3600, urgency: "high", timeout: 15000 });
    return { r: "ok" };
  } catch (e) {
    const code = (e as { statusCode?: number }).statusCode ?? 0;
    if (code === 404 || code === 410) return { r: "gone", why: String(code) };
    return { r: "fail", why: code ? String(code) : (e as Error).message.slice(0, 100) };
  }
}

// send a message to a list of devices and record each device's health
async function deliver(subs: Sub[], m: Msg): Promise<{ ok: number; gone: number; fail: number; last?: string }> {
  const out = { ok: 0, gone: 0, fail: 0, last: undefined as string | undefined };
  await Promise.all(subs.map(async (s) => {
    const x = await sendOne(s, m);
    if (x.r === "ok") { out.ok++; await sb.from("push_subs").update({ last_ok_at: new Date().toISOString(), failed_count: 0 }).eq("id", s.id); }
    else if (x.r === "gone") { out.gone++; await sb.from("push_subs").update({ disabled_at: new Date().toISOString() }).eq("id", s.id); }
    else { out.fail++; out.last = x.why; const n = (s.failed_count ?? 0) + 1;
      await sb.from("push_subs").update(n >= MAX_FAILS ? { failed_count: n, disabled_at: new Date().toISOString() } : { failed_count: n }).eq("id", s.id); }
  }));
  return out;
}

async function liveSubs(event: string): Promise<Sub[]> {
  const { data, error } = await sb.from("push_subs").select("id,endpoint,p256dh,auth,events,failed_count").is("disabled_at", null).contains("events", [event]);
  if (error) throw error;
  return (data ?? []) as Sub[];
}

async function drain(): Promise<Record<string, number>> {
  const { data, error } = await sb.rpc("push_outbox_claim", { n: 50 });
  if (error) throw error;
  const rows = (data ?? []) as Row[];
  const stat = { claimed: rows.length, sent: 0, skipped: 0, failed: 0 };
  const byEvent = new Map<string, Row[]>();
  for (const r of rows) (byEvent.get(r.event) ?? byEvent.set(r.event, []).get(r.event)!).push(r);
  for (const [event, list] of byEvent) {
    const ids = list.map((r) => r.id);
    try {
      const subs = await liveSubs(event);
      if (!subs.length) { await sb.from("push_outbox").update({ status: "skipped", detail: "no device has this event on" }).in("id", ids); stat.skipped += ids.length; continue; }
      const msgs: Msg[] = list.length > 3
        ? [{ title: SUMMARY[event](list.length), body: "Tap to open the CRM", url: list[0].url.split("&")[0], tag: `${event}:summary`, event }]
        : list.map((r) => ({ title: r.title, body: r.body, url: r.url, tag: r.tag, event }));
      let ok = 0, fail = 0, last = "";
      for (const m of msgs) { const d = await deliver(subs, m); ok += d.ok; fail += d.fail + d.gone; if (d.last) last = d.last; }
      // sent = at least one device took it. Nothing took it = back to 'new' for the next minute (the claim gives up after 3 tries).
      if (ok > 0) { await sb.from("push_outbox").update({ status: "sent", sent_at: new Date().toISOString(), detail: fail ? `${ok} ok, ${fail} failed` : null }).in("id", ids); stat.sent += ids.length; }
      else { await sb.from("push_outbox").update({ status: "new", detail: `no device took it${last ? ` (${last})` : ""}` }).in("id", ids); stat.failed += ids.length; }
    } catch (e) {
      await sb.from("push_outbox").update({ status: "new", detail: `error: ${(e as Error).message.slice(0, 150)}` }).in("id", ids); stat.failed += ids.length;
    }
  }
  return stat;
}

Deno.serve(async (req) => {
  const h = cors(req);
  const out = (status: number, obj: unknown) => new Response(JSON.stringify(obj), { status, headers: { ...h, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  if (req.method !== "POST") return out(405, { ok: false, error: "POST only" });
  try {
    const cron = req.headers.get("x-cron-secret");
    if (cron !== null) {   // 1) drain, from pg_cron
      if (!Deno.env.get("CRON_SECRET") || cron !== Deno.env.get("CRON_SECRET")) return out(403, { ok: false, error: "forbidden" });
      const bad = vapid(); if (bad) return out(500, { ok: false, error: bad });
      return out(200, { ok: true, ...(await drain()) });
    }
    // 2) test, from a signed-in founder
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u, error: uErr } = await sb.auth.getUser(jwt);
    if (uErr || !u?.user) return out(401, { ok: false, error: "sign in first" });
    if (claims(jwt).aal !== "aal2") return out(403, { ok: false, error: "2-step login needed" });
    const { data: prof } = await sb.from("profiles").select("name,is_admin").eq("id", u.user.id).maybeSingle();
    if (!prof?.is_admin) return out(403, { ok: false, error: "founders only" });
    let body: { test?: boolean; endpoint?: string; probe?: boolean } = {};
    try { body = await req.json(); } catch { /* empty body */ }
    const bad = vapid(); if (bad) return out(body?.probe ? 200 : 500, { ok: false, error: bad });
    if (body?.probe === true) return out(200, { ok: true });   // the page asks whether sending is set up; sends nothing
    if (body?.test !== true) return out(400, { ok: false, error: "body must be {test: true}" });
    let q = sb.from("push_subs").select("id,endpoint,p256dh,auth,events,failed_count").eq("user_id", u.user.id).is("disabled_at", null);
    if (typeof body.endpoint === "string" && body.endpoint) q = q.eq("endpoint", body.endpoint);
    const { data: subs, error } = await q;
    if (error) throw error;
    if (!subs?.length) return out(404, { ok: false, error: "no device is turned on for you" });
    const d = await deliver(subs as Sub[], { title: "BEJÚ CRM test", body: "Notifications work on this device.", url: "./", tag: "test", event: "test" });
    return d.ok > 0 ? out(200, { ok: true, devices: d.ok }) : out(502, { ok: false, error: d.gone ? "this device is no longer registered; turn notifications on again" : `push service refused (${d.last ?? "unknown"})` });
  } catch (e) {
    return out(500, { ok: false, error: (e as Error).message.slice(0, 200) });
  }
});
