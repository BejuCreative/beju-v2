// draft-sender (Benas's side, 11-21; v2 after Simas's Claude's review 17:37): the PLAIN sender for founder-approved drafts
// (crm_drafts1.sql). No AI in here. Every minute (pg_cron, x-cron-secret):
//   SEND (max 2 a run): claim one approved draft atomically (draft_claim -> 'sending'; a second run can't take it), then
//     1. hold check, failing CLOSED (a lookup error = no send)
//     2. layout / hard-pass flags from drafting block the send
//     3. the thread must be exactly as drafted: its latest email is reply_to_id (any newer email, also from a colleague
//        on CC, = 'stale'), that email arrived in the draft's inbox, the inbox is ours, and the recipients (to + cc) are
//        the ones stored on the draft
//     4. reply-all like send_reply.py, never CC-ing our own addresses; links clickable
//     -> 'sent' with the Instantly id. A known refusal (4xx) = 'failed' (re-approvable); an unclear result (timeout, 5xx,
//        network) = 'unknown' (a founder checks Instantly; it can't be re-approved, so no second send). Instantly busy
//        (429 after retries) = the claim is released back to 'approved' for the next minute.
//   ALERTS: each new draft -> #red-alert with the exact text + CRM link; nudges at 1 h and 3 h; morning list 08:00 Vilnius;
//     every send is announced. Slack problems never block or cause a send.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { global: { headers: { "x-actor": "draft-sender", "x-source": "cron" } }, auth: { persistSession: false } });
const IKEY = Deno.env.get("INSTANTLY_API_KEY")!;
const OURS = /@([a-z0-9-]+\.)*[a-z0-9-]*beju[a-z0-9-]*\.(com|org|digital|net|co|io)$/i;   // every BEJÚ sending domain
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const lc = (s: unknown) => String(s ?? "").trim().toLowerCase();

class Busy extends Error {}
class Refused extends Error {}
class Unknown extends Error {}   // only while the reply itself is being sent
async function ig(method: string, path: string, body?: unknown) {
  for (let attempt = 0; ; attempt++) {
    const r = await fetch("https://api.instantly.ai/api/v2" + path, { method, signal: AbortSignal.timeout(25000),
      headers: { Authorization: `Bearer ${IKEY}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    if (r.ok) return r.json();
    const msg = `Instantly ${r.status} ${path.split("?")[0]}: ${(await r.text()).slice(0, 160)}`;
    if (r.status === 429) { if (attempt >= 2) throw new Busy(msg); await sleep(4000 * 2 ** attempt); continue; }
    if (r.status >= 400 && r.status < 500) throw new Refused(msg);
    throw new Error(msg);
  }
}
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#x27;");
function toHtml(text: string) {   // same as send_reply.py
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
function wall(text: string) {     // send_reply.py's layout rule: 4+ text lines without a blank line
  let run = 0;
  for (const ln of text.split("\n")) { const s = ln.trim(); if (!s) { run = 0; continue; } if (/^(- |• |http)/.test(s)) continue; if (++run >= 4) return true; }
  return false;
}

// set the outcome on a draft WE claimed; throws if the row wasn't ours any more (never log a send that didn't happen)
async function finish(id: number, status: string, extra: Record<string, unknown>) {
  const { data, error } = await sb.from("drafts").update({ status, ...extra }).eq("id", id).eq("status", "sending").select("id");
  if (error) throw new Error(`finish ${status}: ${error.message}`);
  if (!data || !data.length) throw new Error(`finish ${status}: draft ${id} was not in 'sending'`);
  return `#${id} ${status}${extra.error ? ": " + extra.error : ""}`;
}

async function sendOne(d: any): Promise<string> {
  const lead = lc(d.lead_email), inbox = lc(d.inbox);
  // 1. holds, failing closed
  const { data: holds, error: hErr } = await sb.from("desk_items").select("id,title").eq("kind", "hold").eq("status", "open")
    .overlaps("emails", [lead, lc(d.to_email)]);
  if (hErr) throw new Refused("hold check failed, not sending: " + hErr.message);
  if (holds && holds.length) throw new Refused(`on hold: #${holds[0].id} ${holds[0].title}`.slice(0, 300));
  // 2. flags from drafting
  const block = (d.warnings || []).filter((w: string) => /^block:/i.test(w));
  if (block.length) throw new Refused("blocked at drafting: " + block.join("; "));
  if (wall(d.body)) throw new Refused("layout: 4+ text lines without a blank line");
  if (!OURS.test(inbox)) throw new Refused(`inbox ${inbox} is not one of ours`);
  // 3. the thread must be exactly as drafted
  const thread = ((await ig("GET", `/emails?lead=${encodeURIComponent(lead)}&limit=100`)).items || [])
    .sort((a: any, b: any) => (a.timestamp_email || "").localeCompare(b.timestamp_email || ""));
  const latest = thread[thread.length - 1];
  if (!latest) throw new Refused("thread not found in Instantly");
  if (latest.id !== d.reply_to_id) return await finish(d.id, "stale", { error: `thread moved since the draft: newer email ${latest.id} (${latest.timestamp_email})` });
  const inbound = thread.filter((m: any) => lc(m.from_address_email) !== lc(m.eaccount));
  const last = inbound[inbound.length - 1];
  if (!last) throw new Refused("no email from the lead to reply to");
  if (lc(last.eaccount) !== inbox) throw new Refused(`the lead wrote to ${lc(last.eaccount)}, the draft is from ${inbox}`);
  if (lc(last.from_address_email) !== lc(d.to_email)) throw new Refused(`recipient changed: the latest email is from ${lc(last.from_address_email)}, the draft is to ${lc(d.to_email)}`);
  const cc = [...new Set(`${last.cc_address_email_list || ""},${last.to_address_email_list || ""}`.split(",").map(lc).filter(Boolean))]
    .filter((a) => !OURS.test(a) && a !== lc(last.from_address_email)).sort();
  const stored = [...(d.cc_list || [])].map(lc).sort();
  if (cc.join(",") !== stored.join(",")) throw new Refused(`CC changed since the draft: now [${cc.join(", ")}], approved [${stored.join(", ")}]`);
  // 4. send
  let subj = last.subject || ""; if (!/^re:/i.test(subj)) subj = "Re: " + subj;
  const payload: Record<string, unknown> = { reply_to_uuid: last.id, eaccount: d.inbox, subject: subj, body: { text: d.body, html: toHtml(d.body) } };
  if (cc.length) payload.cc_address_email_list = cc.join(",");
  let r: any;
  try { r = await ig("POST", "/emails/reply", payload); }
  catch (e) { if (e instanceof Busy || e instanceof Refused) throw e; throw new Unknown(String((e as Error).message || e)); }
  return await finish(d.id, "sent", { sent_at: new Date().toISOString(), sent_email_id: r?.id ?? null, error: null });
}

// ---- founder alerts in #red-alert. reminders: 0 = not posted yet, 1 = posted, 2 = 1-h nudge, 3 = 3-h nudge.
const SLACK = Deno.env.get("SLACK_TOKEN") ?? "", RED_ALERT = "C0CHQ5LV7L4", CRM = "https://bejucreative.digital/crm/";
const FOUNDERS = "<@U0C55SK8MN0> <@U0C528KBKKL>";
const CAT: Record<string, string> = { big_deal: "Big deal / scope", client_problem: "Client problem", new_terms: "New terms", big_name: "Big name (50k+)", other: "Needs a founder" };
async function slack(text: string) {
  if (!SLACK) throw new Error("SLACK_TOKEN not set");
  const r = await (await fetch("https://slack.com/api/chat.postMessage", { method: "POST", signal: AbortSignal.timeout(15000),
    headers: { Authorization: `Bearer ${SLACK}`, "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify({ channel: RED_ALERT, text, unfurl_links: false }) })).json();
  if (!r.ok) throw new Error("slack " + r.error);
}
async function remind(): Promise<string[]> {
  const out: string[] = [];
  const { data, error } = await sb.from("drafts").select("*").in("status", ["pending", "held"]).order("created_at").limit(50);
  if (error) return [`reminders: ${error.message}`];
  const now = Date.now();
  for (const d of data || []) {
    const age = (now - Date.parse(d.created_at)) / 60000, head = `${CAT[d.category] || d.category} · ${d.lead_email} · from ${d.inbox}`;
    let step = 0, text = "";
    if (d.reminders === 0) {
      step = 1;
      text = `:red_circle: *APPROVAL NEEDED* (draft #${d.id}) ${FOUNDERS}\n${head}\n_Why:_ ${d.reason || "-"}` +
        (d.lead_last_snippet ? `\n_They wrote:_ ${d.lead_last_snippet.slice(0, 300)}` : "") +
        (d.warnings?.length ? `\n_Flags:_ ${d.warnings.join("; ")}` : "") +
        `\n\`\`\`${d.body}\`\`\`\nApprove / Edit / Hold in the CRM: ${CRM} (nothing sends until a founder approves).`;
    } else if (d.status === "pending" && d.reminders === 1 && age >= 60) { step = 2; text = `:hourglass: Still waiting 1 h: draft #${d.id} · ${head} ${FOUNDERS}`; }
    else if (d.status === "pending" && d.reminders === 2 && age >= 180) { step = 3; text = `:hourglass: Still waiting 3 h: draft #${d.id} · ${head} ${FOUNDERS}. It stays on the morning list until a founder answers.`; }
    if (!step) continue;
    try { await slack(text); await sb.from("drafts").update({ reminders: step, last_reminded_at: new Date().toISOString() }).eq("id", d.id); out.push(`#${d.id} alert ${step}`); }
    catch (e) { out.push(`#${d.id} alert failed: ${String(e).slice(0, 80)}`); }
  }
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
  const done: string[] = [];
  const { data: ready, error } = await sb.from("drafts").select("id").eq("status", "approved").order("decided_at").limit(2);
  if (error) return new Response(error.message, { status: 500 });
  for (const { id } of ready || []) {
    const { data: claimed, error: cErr } = await sb.rpc("draft_claim", { p_id: id });
    const d = Array.isArray(claimed) ? claimed[0] : claimed;
    if (cErr || !d || !d.id) { done.push(`#${id} not claimed${cErr ? ": " + cErr.message : ""}`); continue; }
    await slack(`:outbox_tray: Sending draft #${d.id} to ${d.to_email} from ${d.inbox} (approved by ${d.decided_by}).`).catch(() => {});
    try { done.push(await sendOne(d)); }
    catch (e) {
      const why = String((e as Error).message || e).slice(0, 300);
      if (e instanceof Busy) {   // Instantly busy: give the claim back for the next minute
        await sb.from("drafts").update({ status: "approved", error: why }).eq("id", d.id).eq("status", "sending");
        done.push(`#${d.id} released (Instantly busy)`);
      } else {
        // unknown ONLY if the send call itself had an unclear result; anything before it = definitely not sent = failed
        done.push(await finish(d.id, e instanceof Unknown ? "unknown" : "failed", { error: why }).catch((x) => `#${d.id} finish failed: ${x}`));
      }
    }
    await sleep(3000);
  }
  done.push(...await remind().catch((e) => [`reminders failed: ${String(e).slice(0, 100)}`]));
  await sb.from("sync_status").upsert({ name: "draft_sender", ran_at: new Date().toISOString(), ok: !done.some((x) => / (failed|unknown)/.test(x)),
                                         detail: (done.join(" · ") || "nothing to do").slice(0, 200) });
  return new Response(JSON.stringify({ ok: true, done }), { headers: { "Content-Type": "application/json" } });
});
