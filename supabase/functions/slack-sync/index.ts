// slack-sync (11-21, SIMAS: "we need to implement slack into the crm"): mirrors #claude-sync and #red-alert into
// public.slack_messages every 2 minutes (pg_cron calls it with the x-cron-secret header, like ops-sync), so the CRM shows
// Slack with every Mac off. The first run takes the last 3 days; later runs take everything since the newest stored
// message minus 30 minutes (re-reading that window picks up edits). Thread replies are read for parents seen in the
// window. The insert trigger on slack_messages raises a CRM event (kind 'slack') for @Simas / @Benas, 🔴, and #red-alert.
// Secret: SLACK_TOKEN (the watcher bot; needs channels:history + groups:history, and must be a member of each channel).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const TOKEN = Deno.env.get("SLACK_TOKEN") ?? "";
const CHANNELS = [{ id: "C0C5UD86XFX", name: "claude-sync" }, { id: "C0CHQ5LV7L4", name: "red-alert" }];
// Slack user ids are not secret; the bot has no users:read scope, so the few people in these channels are named here.
const PEOPLE: Record<string, string> = { U0C55SK8MN0: "Simas", U0C528KBKKL: "Benas", U0C54B324JD: "claude", U0C64Q4TYDP: "simaswatcher" };
const WORKSPACE = "https://bejucld.slack.com";
const FIRST_DAYS = 3, OVERLAP_S = 1800;

async function slack(method: string, params: Record<string, string>) {
  const r = await fetch(`https://slack.com/api/${method}?${new URLSearchParams(params)}`, { headers: { Authorization: `Bearer ${TOKEN}` } });
  if (r.status === 429) throw new Error(`rate limited (retry after ${r.headers.get("retry-after")} s)`);
  const d = await r.json();
  if (!d.ok) throw new Error(`${method}: ${d.error}${d.needed ? ` (needs ${d.needed})` : ""}`);
  return d;
}
// Agents post as a founder's user with a prefix ("[Benas's Claude] …"); posts from the CRM carry "[Simas via CRM]".
function nameOf(m: any): string {
  const pre = /^\s*\[([^\]]{1,40})\]/.exec(m.text || "");
  if (pre && /claude|codex|via crm/i.test(pre[1])) return pre[1];
  return PEOPLE[m.user] ?? m.bot_profile?.name ?? m.username ?? m.user ?? "unknown";
}
function readable(t: string): string {
  return t.replace(/<@([A-Z0-9]+)(\|[^>]*)?>/g, (_m, id) => "@" + (PEOPLE[id] ?? id))
    .replace(/<#[A-Z0-9]+\|([^>]*)>/g, "#$1")
    .replace(/<!(here|channel|everyone)[^>]*>/g, "@$1")
    .replace(/<mailto:[^|>]+\|([^>]+)>/g, "$1")
    .replace(/<(https?:[^|>]+)\|([^>]+)>/g, "$2 ($1)")
    .replace(/<(https?:[^>]+)>/g, "$1")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}
function row(ch: { id: string; name: string }, m: any) {
  const raw: string = m.text || (m.attachments || []).map((a: any) => a.fallback || a.text || "").join("\n");
  const mentions = [...new Set([...raw.matchAll(/<@([A-Z0-9]+)/g)].map((x) => PEOPLE[x[1]] ?? x[1]))];
  const reply = m.thread_ts && m.thread_ts !== m.ts;
  return {
    ts: m.ts, channel_id: ch.id, channel_name: ch.name, user_name: nameOf(m), text: readable(raw).slice(0, 40000),
    at: new Date(parseFloat(m.ts) * 1000).toISOString(), thread_ts: m.thread_ts ?? null,
    permalink: `${WORKSPACE}/archives/${ch.id}/p${m.ts.replace(".", "")}${reply ? `?thread_ts=${m.thread_ts}&cid=${ch.id}` : ""}`, mentions,
  };
}

async function syncChannel(ch: { id: string; name: string }) {
  const { data: last, error } = await sb.from("slack_messages").select("ts").eq("channel_id", ch.id).order("at", { ascending: false }).limit(1);
  if (error) throw new Error(error.message);
  const oldest = last?.length ? (parseFloat(last[0].ts) - OVERLAP_S).toFixed(6) : (Date.now() / 1000 - FIRST_DAYS * 86400).toFixed(6);
  const msgs: any[] = [];
  let cursor = "";
  for (let p = 0; p < 10; p++) {
    const d = await slack("conversations.history", { channel: ch.id, oldest, limit: "200", ...(cursor ? { cursor } : {}) });
    msgs.push(...(d.messages || []));
    cursor = d.response_metadata?.next_cursor || "";
    if (!cursor) break;
  }
  for (const m of msgs.filter((m) => m.reply_count && parseFloat(m.latest_reply || "0") > parseFloat(oldest)).slice(0, 5)) {
    const d = await slack("conversations.replies", { channel: ch.id, ts: m.ts, oldest, limit: "200" });
    msgs.push(...(d.messages || []).filter((x: any) => x.ts !== m.ts));
  }
  const byTs = new Map<string, any>();
  for (const m of msgs) if (m.ts && !["channel_join", "channel_leave"].includes(m.subtype)) byTs.set(m.ts, row(ch, m));
  const rows = [...byTs.values()].sort((a, b) => parseFloat(a.ts) - parseFloat(b.ts));
  for (let i = 0; i < rows.length; i += 200) {
    const { error: e } = await sb.from("slack_messages").upsert(rows.slice(i, i + 200), { onConflict: "channel_id,ts" });
    if (e) throw new Error(e.message);
  }
  return rows.length;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) return new Response("forbidden", { status: 403 });
  const out: Record<string, unknown> = {}, errors: string[] = [];
  if (!TOKEN) errors.push("SLACK_TOKEN is not set");
  else for (const ch of CHANNELS) {
    try { out[ch.name] = await syncChannel(ch); } catch (e) { errors.push(`#${ch.name}: ${e instanceof Error ? e.message : String(e)}`); }
  }
  await sb.from("sync_status").upsert({ name: "slack", ran_at: new Date().toISOString(), ok: errors.length === 0,
    detail: JSON.stringify({ ...out, ...(errors.length ? { errors } : {}) }).slice(0, 500) });
  return new Response(JSON.stringify({ ok: errors.length === 0, ...out, errors }), { headers: { "Content-Type": "application/json" } });
});
