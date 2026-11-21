// draft-sender (Benas's side, 11-21): the PLAIN sender for founder-approved drafts (crm_drafts1.sql). No AI in here.
// Every minute (pg_cron, x-cron-secret) it takes approved drafts whose text still matches the approved fingerprint and:
//   1. refuses if the lead is on an open hold (desk_items) -> 'failed' (a founder sees why)
//   2. re-reads the Instantly thread; if anything newer than the draft's reply_to_id exists -> 'stale' (never answer an old
//      state of the thread; the Claude drafts again)
//   3. replies to the lead's latest email from the draft's inbox, keeping everyone the lead copied (like send_reply.py),
//      links clickable, then marks the draft 'sent' with the Instantly email id. The DB trigger re-checks the fingerprint.
// One draft at a time, max 5 per run, ~3 s apart (Instantly's 20/min is shared with ops-sync).
// It also posts new drafts to #red-alert and nudges at 1 h / 3 h + a morning list (see remind()).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-actor": "draft-sender", "x-source": "cron" } }, auth: { persistSession: false } });
const IKEY = Deno.env.get("INSTANTLY_API_KEY")!;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function ig(method: string, path: string, body?: unknown) {
  for (let attempt = 0; ; attempt++) {
    const r = await fetch("https://api.instantly.ai/api/v2" + path, {
      method, headers: { Authorization: `Bearer ${IKEY}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    if (r.ok) return r.json();
    if (r.status !== 429 || attempt >= 3) throw new Error(`Instantly ${r.status} ${path.split("?")[0]}: ${(await r.text()).slice(0, 200)}`);
    await sleep(4000 * 2 ** attempt);
  }
}
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#x27;");
function toHtml(text: string) {   // same as send_reply.py: one <div> per line, blank line = <div><br /></div>, https links clickable
  return text.split("\n").map((line) => {
    if (!line.trim()) return "<div><br /></div>";
    let out = "", last = 0;
    for (const m of line.matchAll(/https:\/\/\S+/g)) {
      const url = m[0].replace(/[.,;:)!?"']+$/, ""), start = m.index!;
      out += esc(line.slice(last, start)) + `<a href="${esc(url)}">${esc(url)}</a>`; last = start + url.length;
    }
    return `<div>${out + esc(line.slice(last))}</div>`;
  }).join("");
}

async function sendOne(d: any): Promise<string> {
  const lead = d.lead_email.toLowerCase(), inbox = d.inbox.toLowerCase();
  const { data: holds } = await sb.from("desk_items").select("id,title").eq("kind", "hold").eq("status", "open").contains("emails", [lead]);
  if (holds && holds.length) return await mark(d, "failed", { error: `on hold: #${holds[0].id} ${holds[0].title}`.slice(0, 300) });
  const thread = ((await ig("GET", `/emails?lead=${encodeURIComponent(lead)}&limit=100`)).items || [])
    .filter((m: any) => (m.lead || "").toLowerCase() === lead)
    .sort((a: any, b: any) => (a.timestamp_email || "").localeCompare(b.timestamp_email || ""));
  if (!thread.length) return await mark(d, "failed", { error: "thread not found in Instantly" });
  const latest = thread[thread.length - 1];
  if (latest.id !== d.reply_to_id) return await mark(d, "stale", { error: `thread moved since the draft: newer email ${latest.id} (${latest.timestamp_email})` });
  const inbound = thread.filter((m: any) => (m.from_address_email || "").toLowerCase() !== (m.eaccount || "").toLowerCase());
  const last = inbound[inbound.length - 1];
  if (!last) return await mark(d, "failed", { error: "no email from the lead to reply to" });
  let subj = last.subject || ""; if (!/^re:/i.test(subj)) subj = "Re: " + subj;
  const keep = [...new Set(`${last.cc_address_email_list || ""},${last.to_address_email_list || ""}`.split(",").map((a) => a.trim()).filter(Boolean)
    .filter((a) => ![inbox, (last.from_address_email || "").toLowerCase()].includes(a.toLowerCase())))];
  const payload: Record<string, unknown> = { reply_to_uuid: last.id, eaccount: d.inbox, subject: subj, body: { text: d.body, html: toHtml(d.body) } };
  if (keep.length) payload.cc_address_email_list = keep.join(",");
  const r = await ig("POST", "/emails/reply", payload);
  return await mark(d, "sent", { sent_at: new Date().toISOString(), sent_email_id: r.id ?? null, error: null });
}
async function mark(d: any, status: string, extra: Record<string, unknown>) {
  const { error } = await sb.from("drafts").update({ status, ...extra }).eq("id", d.id).eq("status", "approved");
  if (error) throw new Error(`mark ${status}: ${error.message}`);
  return `#${d.id} ${status}${extra.error ? ": " + extra.error : ""}`;
}

// ---- founder alerts in #red-alert (BENAS 11-21: approvals reach founders in Slack + CRM; no answer = it waits, with
// reminders at 1 h and 3 h, then the morning list). reminders: 0 = not posted yet, 1 = posted, 2 = 1-h nudge, 3 = 3-h nudge.
const SLACK = Deno.env.get("SLACK_TOKEN") ?? "", RED_ALERT = "C0CHQ5LV7L4", CRM = "https://bejucreative.digital/crm/";
const FOUNDERS = "<@U0C55SK8MN0> <@U0C528KBKKL>";
const CAT: Record<string, string> = { big_deal: "Big deal / scope", client_problem: "Client problem", new_terms: "New terms", big_name: "Big name (50k+)", other: "Needs a founder" };
async function slack(text: string) {
  if (!SLACK) throw new Error("SLACK_TOKEN not set");
  const r = await (await fetch("https://slack.com/api/chat.postMessage", { method: "POST",
    headers: { Authorization: `Bearer ${SLACK}`, "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify({ channel: RED_ALERT, text, unfurl_links: false }) })).json();
  if (!r.ok) throw new Error("slack " + r.error);
}
async function remind(): Promise<string[]> {
  const out: string[] = [];
  const { data } = await sb.from("drafts").select("*").in("status", ["pending", "held"]).order("created_at").limit(50);
  const now = Date.now();
  for (const d of data || []) {
    const age = (now - Date.parse(d.created_at)) / 60000, head = `${CAT[d.category] || d.category} · ${d.lead_email} · from ${d.inbox}`;
    let step = 0, text = "";
    if (d.reminders === 0) { step = 1; text = `:red_circle: *APPROVAL NEEDED* (draft #${d.id}) ${FOUNDERS}\n${head}\n_Why:_ ${d.reason || "-"}\n\`\`\`${d.body}\`\`\`\nApprove / Edit / Hold in the CRM: ${CRM} (nothing sends until a founder approves).`; }
    else if (d.status === "pending" && d.reminders === 1 && age >= 60) { step = 2; text = `:hourglass: Still waiting 1 h: draft #${d.id} · ${head} ${FOUNDERS}`; }
    else if (d.status === "pending" && d.reminders === 2 && age >= 180) { step = 3; text = `:hourglass: Still waiting 3 h: draft #${d.id} · ${head} ${FOUNDERS}. It stays on the morning list until a founder answers.`; }
    if (!step) continue;
    try { await slack(text); await sb.from("drafts").update({ reminders: step, last_reminded_at: new Date().toISOString() }).eq("id", d.id); out.push(`#${d.id} alert ${step}`); }
    catch (e) { out.push(`#${d.id} alert failed: ${String(e).slice(0, 80)}`); }
  }
  // morning list: once a day at 08:00 Vilnius, every draft still waiting
  const vil = new Intl.DateTimeFormat("en-GB", { timeZone: "Europe/Vilnius", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date());
  if (vil === "08:00") {
    const waiting = (data || []).filter((d: any) => d.reminders >= 1);
    if (waiting.length) {
      await slack(`:sunrise: *Waiting for a founder* (${waiting.length}) ${FOUNDERS}\n` + waiting.map((d: any) =>
        `• #${d.id} ${CAT[d.category] || d.category} · ${d.lead_email} · ${Math.round((now - Date.parse(d.created_at)) / 3600000)} h${d.status === "held" ? " · HELD" : ""}`).join("\n") + `\n${CRM}`).catch(() => {});
      out.push(`morning list ${waiting.length}`);
    }
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) return new Response("forbidden", { status: 403 });
  const { data, error } = await sb.from("drafts").select("*").eq("status", "approved").order("decided_at").limit(5);
  if (error) return new Response(error.message, { status: 500 });
  const done: string[] = [];
  for (const d of (data || []).filter((x: any) => x.approved_sha256 && x.approved_sha256 === x.body_sha256)) {
    try { done.push(await sendOne(d)); }
    catch (e) { done.push(await mark(d, "failed", { error: String(e).slice(0, 300) }).catch((x) => `#${d.id} mark failed: ${x}`)); }
    await sleep(3000);
  }
  done.push(...await remind().catch((e) => [`reminders failed: ${String(e).slice(0, 100)}`]));
  await sb.from("sync_status").upsert({ name: "draft_sender", ran_at: new Date().toISOString(), ok: !done.some((x) => / failed/.test(x)),
                                         detail: (done.join(" · ") || "nothing approved to send").slice(0, 200) });
  return new Response(JSON.stringify({ ok: true, done }), { headers: { "Content-Type": "application/json" } });
});
