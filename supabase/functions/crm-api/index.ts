// crm-api v1 (11-21): a small, scoped write path into the founders' CRM for the Claudes and scripts.
// Each caller has its OWN key. public.api_keys stores only its SHA-256 hash plus the actions it may run, so a key
// can do only what it was given and can be switched off alone (revoked_at). Every call is logged in public.api_log
// with the caller's name. The rules mirror scripts/crm.py (set_stage), crm_desk.py and founder_tasks.py.
//
//   POST https://<project>.supabase.co/functions/v1/crm-api
//   headers: x-api-key: <key>, Content-Type: application/json
//   body:    {"action": "<name>", "args": {...}}
//
// Deployed with verify_jwt = false: the x-api-key check below IS the authentication.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const FU_STAGES = ["asked_price", "sample_sent", "said_yes", "thinking", "parked", "none"];       // crm.py FU_STAGES
const DESK_STAGES = ["queued", "building", "review", "founder_check", "client_check", "ready"];  // crm_desk.py STAGES
const WHO = ["Simas", "Benas", "Both"];
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

class Bad extends Error { constructor(public status: number, msg: string) { super(msg); } }
const bad = (msg: string): never => { throw new Bad(400, msg); };
const json = (status: number, obj: unknown) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });

async function sha256hex(s: string) {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function str(a: any, k: string, { req = false, max = 2000 } = {}): string | null {
  const v = a?.[k];
  if (v === undefined || v === null || v === "") return req ? bad(`${k} is required`) : null;
  if (typeof v !== "string") bad(`${k} must be text`);
  const t = (v as string).trim();
  if (req && !t) bad(`${k} is required`);
  if (t.length > max) bad(`${k} is longer than ${max} characters`);
  return t || null;
}
function oneOf(v: string | null, allowed: string[], k: string) {
  if (v !== null && !allowed.includes(v)) bad(`${k} must be one of: ${allowed.join(", ")}`);
  return v;
}
function intId(a: any, k = "id") {
  const n = Number(a?.[k]);
  if (!Number.isInteger(n) || n <= 0) bad(`${k} must be a positive whole number`);
  return n;
}
function email(a: any, k: string, req = true): string | null {
  const v = str(a, k, { req, max: 254 });
  if (v === null) return null;
  const e = v.toLowerCase();
  if (!EMAIL.test(e)) bad(`${k} is not an email address`);
  return e;
}
function emails(a: any, k = "emails"): string[] | null {
  const v = a?.[k];
  if (v === undefined || v === null || v === "") return null;
  const list = (Array.isArray(v) ? v : String(v).split(",")).map((x: any) => String(x).trim().toLowerCase()).filter(Boolean);
  if (list.length > 20) bad(`${k}: at most 20 addresses`);
  for (const e of list) if (!EMAIL.test(e)) bad(`${k}: "${e}" is not an email address`);
  return list;
}
// 'YYYY-MM-DD HH:MM' in Europe/Vilnius -> ISO (DST-safe): the same input crm.py and founder_tasks.py take.
function offsetMin(utcMs: number) {
  const p = new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Vilnius", hourCycle: "h23", year: "numeric", month: "2-digit",
    day: "2-digit", hour: "2-digit", minute: "2-digit" }).formatToParts(new Date(utcMs));
  const g = (t: string) => Number(p.find((x) => x.type === t)!.value);
  return (Date.UTC(g("year"), g("month") - 1, g("day"), g("hour"), g("minute")) - utcMs) / 60000;
}
function vilnius(a: any, k: string): string | null {
  const v = str(a, k, { max: 16 });
  if (v === null) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})$/.exec(v);
  if (!m) bad(`${k} must be "YYYY-MM-DD HH:MM" (Vilnius time)`);
  const [y, mo, d, h, mi] = m!.slice(1).map(Number);
  const wall = Date.UTC(y, mo - 1, d, h, mi);
  let utc = wall;
  for (let i = 0; i < 2; i++) utc = wall - offsetMin(utc) * 60000;
  return new Date(utc).toISOString();
}
async function must<T = any>(p: PromiseLike<{ data: any; error: any }>): Promise<T> {
  const { data, error } = await p;
  if (error) throw new Bad(500, error.message);
  return data as T;
}
async function closeDesk(id: number, note: string, actor: string, kind: "hold" | "production") {
  const rows = await must<any[]>(sb.from("desk_items")
    .update({ status: "closed", closed_note: `${note} (${actor})`, closed_at: new Date().toISOString() })
    .eq("id", id).eq("kind", kind).eq("status", "open").select());
  if (!rows.length) throw new Bad(404, `no open ${kind} with id ${id}`);
  return rows[0];
}

const ACTIONS: Record<string, (a: any, actor: string) => Promise<unknown>> = {
  // ---- reads
  async lead(a) {   // {email}: the lead's pipeline row + any open hold on that address
    const e = email(a, "email")!;
    const [p, holds] = await Promise.all([
      must<any[]>(sb.from("pipeline").select("*").eq("email", e).limit(1)),
      must<any[]>(sb.from("desk_items").select("id,client,title,set_by,created_at").eq("kind", "hold").eq("status", "open").contains("emails", [e])),
    ]);
    return { pipeline: p[0] ?? null, holds };
  },
  async desk(a) {   // {kind?: "hold"|"production"}: open desk rows
    const kind = oneOf(str(a, "kind", { max: 20 }), ["hold", "production"], "kind");
    let q = sb.from("desk_items").select("*").eq("status", "open").order("created_at");
    if (kind) q = q.eq("kind", kind);
    return await must(q);
  },
  async tasks() {   // open founder tasks
    return await must(sb.from("founder_tasks").select("*").is("done_at", null).order("due_at", { ascending: true, nullsFirst: false }).order("id"));
  },
  // ---- follow-up stage (crm.py set_stage)
  async set_stage(a) {   // {lead, stage, day0?: "YYYY-MM-DD HH:MM", note?}
    const e = email(a, "lead")!;
    const stage = oneOf(str(a, "stage", { req: true, max: 20 }), FU_STAGES, "stage")!;
    const body: Record<string, unknown> = { fu_stage: stage, fu_day0: stage === "none" ? null : (vilnius(a, "day0") ?? new Date().toISOString()) };
    const note = str(a, "note", { max: 1000 });
    if (note !== null) body.fu_note = note;
    const rows = await must<any[]>(sb.from("pipeline").update(body).eq("email", e).select("email,fu_stage,fu_day0,fu_note"));
    if (!rows.length) throw new Bad(404, `no pipeline row for ${e}`);
    return rows[0];
  },
  // ---- desk (crm_desk.py)
  async hold(a, actor) {   // {client, rule, by: Simas|Benas|Both, emails?, detail?}
    const body = { kind: "hold", client: str(a, "client", { req: true, max: 200 }), title: str(a, "rule", { req: true, max: 1000 }),
      detail: str(a, "detail", { max: 2000 }), emails: emails(a) ?? [], set_by: oneOf(str(a, "by", { req: true, max: 10 }), WHO, "by"), created_by: actor };
    return (await must<any[]>(sb.from("desk_items").insert(body).select()))[0];
  },
  async lift(a, actor) { return await closeDesk(intId(a), str(a, "why", { req: true, max: 500 })!, actor, "hold"); },         // {id, why}
  async close(a, actor) { return await closeDesk(intId(a), str(a, "note", { req: true, max: 500 })!, actor, "production"); },  // {id, note}
  async prod(a, actor) {   // {client, title, stage, builder?, link?, detail?, waits?, emails?}: add, or move the open row with the same client + title
    const client = str(a, "client", { req: true, max: 200 })!, title = str(a, "title", { req: true, max: 300 })!;
    const body: Record<string, unknown> = { stage: oneOf(str(a, "stage", { req: true, max: 20 }), DESK_STAGES, "stage") };
    for (const [k, max] of [["builder", 100], ["link", 1000], ["detail", 2000]] as const) { const v = str(a, k, { max }); if (v !== null) body[k] = v; }
    const waits = oneOf(str(a, "waits", { max: 10 }), WHO, "waits");
    if (waits !== null) body.set_by = waits;
    const em = emails(a);
    if (em) body.emails = em;
    const open = await must<any[]>(sb.from("desk_items").select("id,client,title").eq("kind", "production").eq("status", "open"));
    const cur = open.find((x) => x.client.toLowerCase() === client.toLowerCase() && x.title.toLowerCase() === title.toLowerCase());
    if (cur) return (await must<any[]>(sb.from("desk_items").update({ ...body, status: "open", closed_at: null }).eq("id", cur.id).select()))[0];
    return (await must<any[]>(sb.from("desk_items").insert({ ...body, kind: "production", client, title, created_by: actor }).select()))[0];
  },
  // ---- founder tasks (founder_tasks.py)
  async task_add(a, actor) {   // {title, detail?, who?, lead?, due?: "YYYY-MM-DD HH:MM"}
    const body = { title: str(a, "title", { req: true, max: 300 }), detail: str(a, "detail", { max: 2000 }), who: oneOf(str(a, "who", { max: 10 }), WHO, "who"),
      lead_email: email(a, "lead", false), created_by: actor, due_at: vilnius(a, "due") };
    return (await must<any[]>(sb.from("founder_tasks").insert(body).select()))[0];
  },
  async task_done(a) {   // {id}
    const rows = await must<any[]>(sb.from("founder_tasks").update({ done_at: new Date().toISOString() }).eq("id", intId(a)).is("done_at", null).select());
    if (!rows.length) throw new Bad(404, "no open task with that id");
    return rows[0];
  },
};

async function log(key_name: string, action: string, args: unknown, ok: boolean, status: number, error: string | null) {
  try {
    const s = JSON.stringify(args ?? {});
    await sb.from("api_log").insert({ key_name, action, args: s.length > 4000 ? { truncated: s.slice(0, 4000) } : args, ok, status, error });
  } catch { /* the log never blocks the answer */ }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { ok: false, error: "POST only" });
  const key = req.headers.get("x-api-key") ?? "";
  let caller: { id: string; name: string; actions: string[] } | null = null, action = "", args: any = {};
  try {
    if (key.length < 20 || key.length > 200) throw new Bad(401, "missing or bad x-api-key");
    const k = await must<any[]>(sb.from("api_keys").select("id,name,actions,revoked_at").eq("key_hash", await sha256hex(key)).limit(1));
    if (!k.length || k[0].revoked_at) throw new Bad(401, "unknown or revoked key");
    caller = k[0];
    let body: any;
    try { body = await req.json(); } catch { throw new Bad(400, 'body must be JSON: {"action": "...", "args": {...}}'); }
    action = String(body?.action ?? "");
    args = body?.args ?? {};
    if (typeof args !== "object" || Array.isArray(args)) throw new Bad(400, "args must be an object");
    if (!Object.hasOwn(ACTIONS, action)) throw new Bad(400, `unknown action; known: ${Object.keys(ACTIONS).join(", ")}`);
    if (!caller!.actions.includes(action)) throw new Bad(403, `this key may not run ${action}`);
    const result = await ACTIONS[action](args, caller!.name);
    await log(caller!.name, action, args, true, 200, null);
    await sb.from("api_keys").update({ last_used_at: new Date().toISOString() }).eq("id", caller!.id);
    return json(200, { ok: true, result });
  } catch (e) {
    const status = e instanceof Bad ? e.status : 500;
    const msg = e instanceof Error ? e.message : String(e);
    if (caller) await log(caller.name, action, args, false, status, msg);   // calls without a valid key are not logged (no table spam)
    return json(status, { ok: false, error: caller || status !== 500 ? msg : "server error" });
  }
});
