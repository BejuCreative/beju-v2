// Performance tab v2 — daily client numbers without the Mac (11-23). pg_cron 'perf-sync' calls it at 04:00 UTC with x-cron-secret.
// YouTube (official Data API, key = secret YOUTUBE_API_KEY): channel stats → channel_stats_daily; uploads of the last 120 days
// (paged) → client_posts + client_post_stats (today); every YouTube id in our_posts re-read directly (50 per call) so old ours
// keep updating; ids that vanished keep their last stats and get removed=true.
// Instagram: Business Discovery with secrets META_PAGE_TOKEN + META_IG_USER_ID. If it fails, perf_health instagram ok=false with
// Meta's reason, and nothing is written as fresh. TikTok stays on the Mac (yt-dlp), so it is not touched here.
// Then rpc perf_after_sync(): auto-link (our_posts / link_suggestions), derive client_posts.ours, freeze baselines, flag events.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const YT = Deno.env.get("YOUTUBE_API_KEY") || "";
const DAY = new Date().toISOString().slice(0, 10);
const NOW = () => new Date().toISOString();

function isoDur(s: string): number {
  const m = /P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/.exec(s || "") || [];
  return (+(m[1] || 0)) * 86400 + (+(m[2] || 0)) * 3600 + (+(m[3] || 0)) * 60 + (+(m[4] || 0));
}
async function yt(path: string, p: Record<string, string>) {
  const r = await fetch(`https://www.googleapis.com/youtube/v3/${path}?` + new URLSearchParams({ ...p, key: YT }));
  const j = await r.json();
  if (!r.ok) throw new Error(`YouTube ${path} ${r.status}: ${j?.error?.message ?? ""}`.slice(0, 200));
  return j;
}
async function up(table: string, rows: any[], onConflict: string) {
  for (let i = 0; i < rows.length; i += 500) {
    const { error } = await sb.from(table).upsert(rows.slice(i, i + 500), { onConflict });
    if (error) throw new Error(`${table}: ${error.message}`);
  }
}
function postRow(v: any, email: string) {
  const d = isoDur(v.contentDetails?.duration), st = v.statistics || {};
  return { platform: "youtube", post_id: v.id, email, title: (v.snippet?.title || "").slice(0, 300),
    url: `https://www.youtube.com/${d <= 180 ? "shorts/" : "watch?v="}${v.id}`, posted_at: v.snippet?.publishedAt, duration_s: d,
    is_short: d <= 180, views: +(st.viewCount ?? 0), likes: st.likeCount != null ? +st.likeCount : null,
    comments: st.commentCount != null ? +st.commentCount : null, removed: false, removed_at: null, updated_at: NOW() };
}
const statRow = (p: any) => ({ platform: p.platform, post_id: p.post_id, day: DAY, views: p.views, likes: p.likes, comments: p.comments });

async function youtube() {
  const errs: string[] = []; let posts = 0;
  if (!YT) return { errs: ["secret YOUTUBE_API_KEY missing"], posts };
  const { data: accts, error } = await sb.from("client_accounts").select("email, ext_id").eq("platform", "youtube");
  if (error) throw new Error(error.message);
  const seen = new Set<string>();
  const since = Date.now() - 120 * 864e5;
  for (const a of accts || []) {
    try {
      if (!a.ext_id) throw new Error("no channel id");
      const ch = (await yt("channels", { part: "statistics,contentDetails,snippet", id: a.ext_id })).items?.[0];
      if (!ch) throw new Error("channel not found");
      const st = ch.statistics || {};
      await up("channel_stats_daily", [{ client_email: a.email, platform: "youtube", day: DAY, followers: +(st.subscriberCount ?? 0),
        total_views: +(st.viewCount ?? 0), video_count: +(st.videoCount ?? 0) }], "client_email,platform,day");
      await sb.from("client_accounts").update({ followers: +(st.subscriberCount ?? 0), posts_count: +(st.videoCount ?? 0),
        handle: ch.snippet?.customUrl ?? null, updated_at: NOW() }).eq("email", a.email).eq("platform", "youtube");
      // uploads of the last 120 days, paged (the playlist is newest-first; stop once a page is entirely older)
      const ids: string[] = []; let tok = "";
      for (let page = 0; page < 40; page++) {
        const pl = await yt("playlistItems", { part: "contentDetails", playlistId: ch.contentDetails.relatedPlaylists.uploads, maxResults: "50", ...(tok ? { pageToken: tok } : {}) });
        const items = pl.items || [];
        const fresh = items.filter((i: any) => Date.parse(i.contentDetails.videoPublishedAt || "1970") >= since);
        ids.push(...fresh.map((i: any) => i.contentDetails.videoId));
        tok = pl.nextPageToken;
        if (!tok || fresh.length === 0) break;
      }
      const rows: any[] = [];
      for (let i = 0; i < ids.length; i += 50) {
        for (const v of (await yt("videos", { part: "snippet,contentDetails,statistics", id: ids.slice(i, i + 50).join(",") })).items || []) {
          rows.push(postRow(v, a.email)); seen.add(v.id);
        }
      }
      await up("client_posts", rows, "platform,post_id");
      await up("client_post_stats", rows.map(statRow), "platform,post_id,day");
      posts += rows.length;
    } catch (e) { errs.push(`${a.email}: ${(e as Error).message}`); }
  }
  // every YouTube post we made, re-read directly (it may be older than 120 days)
  try {
    const { data: ours } = await sb.from("our_posts").select("post_id, client_email").eq("platform", "youtube");
    const rest = (ours || []).filter((o: any) => !seen.has(o.post_id));
    for (let i = 0; i < rest.length; i += 50) {
      const chunk = rest.slice(i, i + 50);
      const got = (await yt("videos", { part: "snippet,contentDetails,statistics", id: chunk.map((o: any) => o.post_id).join(",") })).items || [];
      const rows = got.map((v: any) => postRow(v, chunk.find((o: any) => o.post_id === v.id)!.client_email));
      await up("client_posts", rows, "platform,post_id");
      await up("client_post_stats", rows.map(statRow), "platform,post_id,day");
      const gone = chunk.map((o: any) => o.post_id).filter((id: string) => !got.some((v: any) => v.id === id));
      if (gone.length) await sb.from("client_posts").update({ removed: true, removed_at: NOW() }).eq("platform", "youtube").in("post_id", gone).eq("removed", false);
    }
  } catch (e) { errs.push(`our_posts re-read: ${(e as Error).message}`); }
  return { errs, posts };
}

async function instagram() {
  const tok = Deno.env.get("META_PAGE_TOKEN"), uid = Deno.env.get("META_IG_USER_ID");
  const { data: accts } = await sb.from("client_accounts").select("email, handle").eq("platform", "instagram");
  if (!accts?.length) return { errs: [], posts: 0, skipped: true };
  if (!tok || !uid) return { errs: ["no Instagram token stored (secrets META_PAGE_TOKEN / META_IG_USER_ID)"], posts: 0 };
  const errs: string[] = []; let posts = 0;
  for (const a of accts) {
    const fields = `business_discovery.username(${(a.handle || "").toLowerCase()}){followers_count,media_count,media.limit(50){id,caption,media_product_type,timestamp,permalink,like_count,comments_count,view_count}}`;
    const j = await (await fetch(`https://graph.facebook.com/v23.0/${uid}?` + new URLSearchParams({ fields, access_token: tok }))).json();
    if (!j.business_discovery) { errs.push(`${a.email}: ${j?.error?.message ?? "no business_discovery"}`.slice(0, 200)); continue; }
    const bd = j.business_discovery;
    await up("channel_stats_daily", [{ client_email: a.email, platform: "instagram", day: DAY, followers: bd.followers_count ?? null,
      total_views: null, video_count: bd.media_count ?? null }], "client_email,platform,day");
    await sb.from("client_accounts").update({ followers: bd.followers_count, posts_count: bd.media_count, updated_at: NOW() })
      .eq("email", a.email).eq("platform", "instagram");
    const rows = (bd.media?.data || []).map((m: any) => ({ platform: "instagram", post_id: m.id, email: a.email, url: m.permalink,
      title: (m.caption || "").slice(0, 300), posted_at: m.timestamp, is_short: m.media_product_type === "REELS", views: m.view_count ?? null,
      likes: m.like_count ?? null, comments: m.comments_count ?? null, removed: false, updated_at: NOW() }));
    await up("client_posts", rows, "platform,post_id");
    await up("client_post_stats", rows.map(statRow), "platform,post_id,day");
    posts += rows.length;
  }
  return { errs, posts };
}

async function health(platform: string, errs: string[], extra = "") {
  const { data } = await sb.from("client_post_stats").select("day").eq("platform", platform).order("day", { ascending: false }).limit(1);
  const last = data?.[0]?.day ?? null;
  const ok = errs.length === 0 && last === DAY;
  const row: any = { platform, last_day: last, ok, updated_at: NOW(),
    detail: (ok ? `ok ${extra}` : errs.join(" | ") || `no fresh rows (last ${last})`).slice(0, 500) };
  if (ok) row.last_ok_at = NOW();
  await up("perf_health", [row], "platform");
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) return new Response("forbidden", { status: 403 });
  const out: any = {};
  try {
    const y = await youtube(); out.youtube = y; await health("youtube", y.errs, `${y.posts} posts`);
    const i = await instagram(); out.instagram = i; if (!(i as any).skipped) await health("instagram", i.errs, `${i.posts} posts`);
    const { data, error } = await sb.rpc("perf_after_sync"); out.after = error ? { error: error.message } : data;
    const ok = !y.errs.length && !error;
    await up("sync_status", [{ name: "perf_sync", ran_at: NOW(), ok, detail: JSON.stringify({ yt: y.posts, yt_err: y.errs.length,
      ig: i.posts, ig_err: i.errs[0] ?? null, after: out.after }).slice(0, 300), max_age_min: 1560 }], "name");
    return new Response(JSON.stringify(out), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    await up("sync_status", [{ name: "perf_sync", ran_at: NOW(), ok: false, detail: String((e as Error).message).slice(0, 300) }], "name").catch(() => {});
    return new Response(JSON.stringify({ error: (e as Error).message, out }), { status: 500 });
  }
});
