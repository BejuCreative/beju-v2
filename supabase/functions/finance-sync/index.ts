// finance-sync — the Stripe numbers of the CRM's Expenses page without the Mac (SIMAS 11-25: "it should be tracked based on the API …
// if I'm without you, I could see the CRM is live"). pg_cron 'finance-sync' calls it every 15 minutes with x-cron-secret.
// Stripe is READ ONLY here (GET balance, balance_transactions, charges, refunds, payouts). It writes ONE row: finance_snapshot id='stripe'.
// finance.py --sync (Mac) still writes id='current' (sheet numbers: expenses, bills, transfers, alerts). Each row has one writer, so the two
// never overwrite each other; the CRM shows Stripe numbers from 'stripe' and falls back to 'current' only if 'stripe' is missing.
// Same rules as finance.py: tracking from 2026-09-01; income = succeeded charges (gross) by UTC day, refunds negative; a payout counts as
// withdrawn only when Stripe says "paid" (by arrival day); pending / in_transit = "on the way". USD → EUR uses the sheet rate
// (Settings B2, carried in the 'current' row as fx_usd_eur), so these numbers match the Finance sheet to the cent.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

// Whose bank each payout lands in, by the end of Stripe's destination id. A new bank = one new line here.
const BANKS: Record<string, { who: string; bank: string; currency: string; note?: string }> = {
  U8tN3Y: { who: "Simas", bank: "Revolut ••5438", currency: "EUR" },
  Fu5Pcp: { who: "Simas", bank: "Revolut ••5438", currency: "USD" },
  "1gqgJV": { who: "Simas", bank: "SEB", currency: "EUR", note: "old account, no longer in Stripe" },
  XUmp0U: { who: "Benas", bank: "Currency Cloud ••4216", currency: "USD", note: "removed from Stripe; the next payout goes to a new account id" },
  jnZUKc: { who: "Benas", bank: "Currency Cloud (old)", currency: "USD", note: "removed; its only payout failed" },
};
const MAIN: Record<string, string> = { Simas: "EUR", Benas: "USD" };   // each founder's usual payout currency (the card's first line)
const START = Date.UTC(2026, 8, 1) / 1000;                              // 2026-09-01, like finance.py START

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const KEY = Deno.env.get("STRIPE_SECRET_KEY") || "";
const r2 = (v: number) => Math.round((v || 0) * 100) / 100;
const day = (unix: number) => new Date(unix * 1000).toISOString().slice(0, 10);   // UTC day, like finance.py

async function stripe(path: string, params: Record<string, string> = {}, list = true): Promise<any> {
  const out: any[] = [];
  let after = "";
  for (let page = 0; page < 50; page++) {
    const q = new URLSearchParams({ ...params, ...(list ? { limit: "100" } : {}), ...(after ? { starting_after: after } : {}) });
    const r = await fetch(`https://api.stripe.com/v1/${path}?${q}`, { headers: { Authorization: `Bearer ${KEY}` } });
    const j = await r.json();
    if (!r.ok) throw new Error(`Stripe ${path} ${r.status}: ${j?.error?.message ?? ""}`.slice(0, 200));
    if (!list) return j;
    out.push(...j.data);
    if (!j.has_more) return out;
    after = j.data[j.data.length - 1].id;
  }
  throw new Error(`Stripe ${path}: more than 50 pages`);
}

async function build() {
  const { data: cur, error } = await sb.from("finance_snapshot").select("data").eq("id", "current").maybeSingle();
  if (error) throw new Error(`finance_snapshot: ${error.message}`);
  const fx = Number(cur?.data?.fx_usd_eur);
  if (!(fx > 0)) throw new Error("no fx_usd_eur in the 'current' row (finance.py has never run)");
  // only EUR and USD exist today; any other currency is left out and flagged, never converted at the USD rate
  const warnings: string[] = [];
  const eur = (amt: number, c: string) => { const u = c.toUpperCase(); if (u === "EUR") return amt; if (u === "USD") return amt * fx;
    warnings.push(`${amt} ${u} left out: no rate for ${u}`); return 0; };
  const now = new Date(), today = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Vilnius" }).format(now), ym = today.slice(0, 7);

  const [bal, txs, charges, refunds, payouts] = await Promise.all([
    stripe("balance", {}, false),
    stripe("balance_transactions", { "created[gte]": String(Math.floor(now.getTime() / 1000) - 21 * 86400) }),
    stripe("charges", { "created[gte]": String(START), "expand[]": "data.balance_transaction" }),
    stripe("refunds", { "created[gte]": String(START) }),
    stripe("payouts"),   // all of them: the ones before START are shown as "before tracking", not counted
  ]);

  // money in, per month (EUR)
  const months: Record<string, { income: number; fees: number; paid_out: number }> = {};
  const m = (k: string) => (months[k] ||= { income: 0, fees: 0, paid_out: 0 });
  const ours = new Set<string>();
  for (const c of charges) {
    if (c.status !== "succeeded") continue;
    ours.add(c.id);
    const k = day(c.created).slice(0, 7), cc = String(c.currency);
    m(k).income += eur(c.amount / 100, cc);
    const bt = c.balance_transaction || {};
    m(k).fees += eur((bt.fee || 0) / 100, String(bt.currency || cc));
  }
  for (const rf of refunds) {
    if (rf.status !== "succeeded" || !ours.has(rf.charge)) continue;
    m(day(rf.created).slice(0, 7)).income -= eur(rf.amount / 100, String(rf.currency));
  }

  // withdrawn to each founder's banks
  const founders: Record<string, any> = {};
  const F = (who: string) => (founders[who] ||= { bank: "", currency: MAIN[who] || "EUR", all_time_eur: 0, month_eur: 0, all_time: {}, month: {},
    count: 0, last: null, banks: [], on_the_way: [] });
  for (const who of Object.keys(MAIN)) F(who);
  const bankRow = (f: any, b: { bank: string; currency: string; note?: string }) => {
    let x = f.banks.find((y: any) => y.bank === b.bank && y.currency === b.currency);
    if (!x) f.banks.push(x = { bank: b.bank, currency: b.currency, note: b.note || "", all_time: 0, all_time_eur: 0, month: 0, month_eur: 0, count: 0, last: null,
      before: { amount: 0, eur: 0, count: 0, from: null, to: null } });
    return x;
  };
  const unknown: any[] = [];
  for (const p of payouts.slice().sort((a: any, b: any) => a.arrival_date - b.arrival_date || a.created - b.created)) {
    const dest = String(p.destination || ""), hit = Object.keys(BANKS).find((k) => dest.endsWith(k));
    const amt = p.amount / 100, c = String(p.currency).toUpperCase(), d = day(p.arrival_date);
    if (!hit) {
      if (p.created >= START && ["paid", "pending", "in_transit"].includes(p.status)) unknown.push({ id: p.id, date: d, amount: amt, currency: c, status: p.status, dest_end: dest.slice(-6) });
      continue;
    }
    const b = BANKS[hit], f = F(b.who);
    if (p.created < START) {                                // before tracking: shown on the bank line, not in any total
      if (p.status === "paid") { const x = bankRow(f, b), bf = x.before; bf.amount += amt; bf.eur += eur(amt, c); bf.count++; bf.from = bf.from && bf.from < d ? bf.from : d; bf.to = bf.to && bf.to > d ? bf.to : d; }
      continue;
    }
    if (p.status === "pending" || p.status === "in_transit") {
      f.on_the_way.push({ date: d, amount: amt, currency: c, bank: b.bank, status: p.status });
      continue;
    }
    if (p.status !== "paid") continue;                     // failed / canceled never landed
    const e = eur(amt, c), x = bankRow(f, b), thisM = d.slice(0, 7) === ym;
    m(d.slice(0, 7)).paid_out += e;
    f.all_time_eur += e; f.count++; f.all_time[c] = (f.all_time[c] || 0) + amt;
    x.all_time += amt; x.all_time_eur += e; x.count++;
    if (thisM) { f.month_eur += e; f.month[c] = (f.month[c] || 0) + amt; x.month += amt; x.month_eur += e; }
    f.last = x.last = { date: d, amount: amt, currency: c, bank: b.bank };
  }
  for (const f of Object.values(founders)) {
    f.all_time_eur = r2(f.all_time_eur); f.month_eur = r2(f.month_eur);
    for (const o of [f.all_time, f.month]) for (const k of Object.keys(o)) o[k] = r2(o[k]);
    for (const x of f.banks) { x.all_time = r2(x.all_time); x.all_time_eur = r2(x.all_time_eur); x.month = r2(x.month); x.month_eur = r2(x.month_eur);
      x.before.amount = r2(x.before.amount); x.before.eur = r2(x.before.eur); if (!x.before.count) x.before = null; }
    f.banks = f.banks.filter((x: any) => x.count || x.before);
    f.banks.sort((a: any, b: any) => b.all_time_eur - a.all_time_eur);
    f.bank = [...new Set(f.banks.map((x: any) => x.bank))].join(" + ");
  }
  const all_time = { income: 0, fees: 0, paid_out: 0 };
  for (const v of Object.values(months)) {
    all_time.income += v.income; all_time.fees += v.fees; all_time.paid_out += v.paid_out;
    v.income = r2(v.income); v.fees = r2(v.fees); v.paid_out = r2(v.paid_out);
  }

  // Stripe balance + when pending money lands (same shape as finance.py's "stripe" box)
  const byCur = (parts: any[]) => Object.fromEntries(parts.map((x) => [String(x.currency).toUpperCase(), r2(x.amount / 100)]));
  const pend: Record<string, Record<string, number>> = {};
  for (const t of txs) if (t.status === "pending") {
    const d = day(t.available_on), c = String(t.currency).toUpperCase();
    (pend[d] ||= {})[c] = r2((pend[d][c] || 0) + t.net / 100);
  }
  const toEur = (o: Record<string, number>): number => r2(Object.entries(o).reduce((a, [k, v]) => a + eur(v, k), 0));
  const available = byCur(bal.available), pending = byCur(bal.pending), dates = Object.keys(pend).sort();

  return {
    version: 1, source: "Stripe API (finance-sync, server)", generated_at: now.toISOString(), today, fx_usd_eur: fx, since: "2026-09-01",
    months, all_time: { income: r2(all_time.income), fees: r2(all_time.fees), paid_out: r2(all_time.paid_out) },
    stripe: { available, pending, available_eur: toEur(available), pending_eur: toEur(pending),
      pending_by_date: dates.map((d) => ({ date: d, ...pend[d] })), next_pending_date: dates[0] || null },
    payouts: founders, unknown_payouts: unknown, warnings: [...new Set(warnings)].slice(0, 20),
    counts: { charges: charges.length, refunds: refunds.length, payouts: payouts.length },
  };
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) return new Response("forbidden", { status: 403 });
  try {
    if (!KEY) throw new Error("secret STRIPE_SECRET_KEY missing");
    const snap = await build();
    const { error } = await sb.from("finance_snapshot").upsert({ id: "stripe", data: snap, updated_at: snap.generated_at }, { onConflict: "id" });
    if (error) throw new Error(`upsert: ${error.message}`);
    const p = snap.payouts as Record<string, any>;
    return Response.json({ ok: true, at: snap.generated_at, counts: snap.counts, unknown_payouts: snap.unknown_payouts.length,
      withdrawn_eur: Object.fromEntries(Object.entries(p).map(([k, v]) => [k, v.all_time_eur])) });
  } catch (e) {
    // the old 'stripe' row stays as it was; the CRM shows its age, so a failing sync is visible as "updated N h ago"
    return Response.json({ ok: false, error: String((e as Error).message || e).slice(0, 300) }, { status: 500 });
  }
});
