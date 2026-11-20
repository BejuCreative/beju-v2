-- Client performance (SIMAS 11-20): weekly scan of each monthly client's YouTube / TikTok / Instagram,
-- which of our Shorts they posted, what performed best, and the weekly reports we send. Additive; founder-only RLS.
create table if not exists public.client_accounts (
  email text not null, platform text not null check (platform in ('youtube','tiktok','instagram')),
  handle text, url text, ext_id text, followers bigint, posts_count bigint,
  updated_at timestamptz not null default now(), primary key (email, platform));
create table if not exists public.client_posts (
  platform text not null, post_id text not null, email text not null,
  url text, title text, posted_at timestamptz, duration_s numeric, is_short boolean,
  views bigint, likes bigint, comments bigint,
  ours boolean not null default false, our_ref text,           -- our delivered file it matches (e.g. "Short 14")
  first_seen timestamptz not null default now(), updated_at timestamptz not null default now(),
  primary key (platform, post_id));
create index if not exists client_posts_email on public.client_posts (email, posted_at desc);
create table if not exists public.client_post_stats (
  platform text not null, post_id text not null, day date not null default current_date,
  views bigint, likes bigint, comments bigint, primary key (platform, post_id, day));
create table if not exists public.client_reports (
  id bigint generated always as identity primary key, email text not null, week date not null,
  data jsonb not null default '{}'::jsonb,                     -- top posts, why, ideas, what we changed in the edits
  page_url text, status text not null default 'draft' check (status in ('draft','sent','internal')),
  sent_at timestamptz, created_at timestamptz not null default now(), unique (email, week));
alter table public.client_accounts enable row level security; alter table public.client_posts enable row level security;
alter table public.client_post_stats enable row level security; alter table public.client_reports enable row level security;
drop policy if exists "founders read" on public.client_accounts; create policy "founders read" on public.client_accounts for select using (public.is_admin());
drop policy if exists "founders read" on public.client_posts; create policy "founders read" on public.client_posts for select using (public.is_admin());
drop policy if exists "founders read" on public.client_post_stats; create policy "founders read" on public.client_post_stats for select using (public.is_admin());
drop policy if exists "founders read" on public.client_reports; create policy "founders read" on public.client_reports for select using (public.is_admin());
revoke all on public.client_accounts, public.client_posts, public.client_post_stats, public.client_reports from anon;
grant select on public.client_accounts, public.client_posts, public.client_post_stats, public.client_reports to authenticated;
