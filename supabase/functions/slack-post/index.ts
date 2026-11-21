// slack-post (11-21, SIMAS: "we need to implement slack into the crm"): a founder posts to #claude-sync or #red-alert
// from the CRM page, as the watcher bot, with the prefix "[<founder> via CRM]".
// Deployed with verify_jwt = true (the gateway checks the JWT). Here, the same bar as public.is_admin(): a real user
// (auth.getUser), profiles.is_admin = true, and a session that passed 2-step login (JWT aal = aal2).
//   POST /functions/v1/slack-post   Authorization: Bearer <founder session>   body {channel: 'claude-sync'|'red-alert', text, lead_email?}
//   -> {ok: true, ts, permalink}   or {ok: false, error}
// "@Simas" / "@Benas" in the text become real Slack mentions. Only the two channels below can be posted to.
// Secret: SLACK_TOKEN (needs the chat:write scope; the bot must be a member of the channel).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const TOKEN = Deno.env.get("SLACK_TOKEN") ?? "";
const CHANNELS: Record<string, string> = { "claude-sync": "C0C5UD86XFX", "red-alert": "C0CHQ5LV7L4" };
const MENTION: Record<string, string> = { Simas: "U0C55SK8MN0", Benas: "U0C528KBKKL" };
const WORKSPACE = "https://bejucld.slack.com";
const ORIGINS = ["https://bejucreative.digital", "https://www.bejucreative.digital"];
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function cors(req: Request) {
  const o = req.headers.get("origin") ?? "";
  return { "Access-Control-Allow-Origin": ORIGINS.includes(o) ? o : ORIGINS[0], "Vary": "Origin",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
}
function claims(jwt: string): any {
  try { return JSON.parse(atob(jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(jwt.split(".")[1].length / 4) * 4, "="))); }
  catch { return {}; }
}

Deno.serve(async (req) => {
  const h = cors(req);
  const out = (status: number, obj: unknown) => new Response(JSON.stringify(obj), { status, headers: { ...h, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  if (req.method !== "POST") return out(405, { ok: false, error: "POST only" });
  try {
    // 1) who is this: a founder, signed in with the 2-step code
    const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    const { data: u, error: uErr } = await sb.auth.getUser(jwt);
    if (uErr || !u?.user) return out(401, { ok: false, error: "sign in first" });
    if (claims(jwt).aal !== "aal2") return out(403, { ok: false, error: "2-step login needed" });
    const { data: prof } = await sb.from("profiles").select("name,is_admin").eq("id", u.user.id).maybeSingle();
    if (!prof?.is_admin) return out(403, { ok: false, error: "founders only" });

    // 2) what to post
    let body: any;
    try { body = await req.json(); } catch { return out(400, { ok: false, error: "body must be JSON: {channel, text, lead_email?}" }); }
    const channel = String(body?.channel ?? "");
    if (!Object.hasOwn(CHANNELS, channel)) return out(400, { ok: false, error: `channel must be one of: ${Object.keys(CHANNELS).join(", ")}` });
    const text = typeof body?.text === "string" ? body.text.trim() : "";
    if (!text) return out(400, { ok: false, error: "text is required" });
    if (text.length > 3000) return out(400, { ok: false, error: "text is longer than 3000 characters" });
    const lead = typeof body?.lead_email === "string" && body.lead_email.trim() ? body.lead_email.trim().toLowerCase() : null;
    if (lead && !EMAIL.test(lead)) return out(400, { ok: false, error: "lead_email is not an email address" });
    if (!TOKEN) return out(500, { ok: false, error: "SLACK_TOKEN is not set" });

    // 3) post as the bot
    const name = (prof.name || u.user.email || "Founder").trim();
    const plain = `[${name} via CRM] ${text}${lead ? `\nLead: ${lead}` : ""}`;
    const slackText = plain.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/@(Simas|Benas)\b/g, (_m, n: string) => `<@${MENTION[n]}>`);
    const r = await fetch("https://slack.com/api/chat.postMessage", {
      method: "POST", headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json; charset=utf-8" },
      body: JSON.stringify({ channel: CHANNELS[channel], text: slackText, unfurl_links: false, unfurl_media: false }),
    });
    const d = await r.json();
    if (!d.ok) {
      const hint = d.error === "missing_scope" ? " (add the bot scope chat:write to the Slack app, then reinstall it)"
        : d.error === "not_in_channel" ? ` (invite the bot to #${channel})` : "";
      return out(502, { ok: false, error: `slack: ${d.error}${hint}` });
    }
    const permalink = `${WORKSPACE}/archives/${CHANNELS[channel]}/p${String(d.ts).replace(".", "")}`;
    // 4) show it in the CRM at once (slack-sync would bring it within 2 minutes anyway; same key, so no double)
    await sb.from("slack_messages").upsert({ ts: d.ts, channel_id: CHANNELS[channel], channel_name: channel, user_name: `${name} via CRM`,
      text: plain, at: new Date(parseFloat(d.ts) * 1000).toISOString(), thread_ts: null, permalink,
      mentions: [...new Set([...plain.matchAll(/@(Simas|Benas)\b/g)].map((x) => x[1]))] }, { onConflict: "channel_id,ts" });
    return out(200, { ok: true, ts: d.ts, permalink });
  } catch (e) {
    return out(500, { ok: false, error: e instanceof Error ? e.message : String(e) });
  }
});
