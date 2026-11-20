-- CRM "On hold" + "In production" cards (SIMAS 11-21: "figure out what things I ask the most ... improve the CRM").
-- He keeps asking the same two things in chat: "don't send X anything" (a hold) and "have you adjusted her vids / who is
-- building what" (production). Both lived only in chat and memory files. One small table holds them, the CRM shows them.
-- Additive only. Same protection as the other founder tables: row-level security with is_admin(), no anon access.
-- Written ONLY by the service role (scripts/crm_desk.py in the Dashboard repo); founders read.

create table if not exists public.desk_items (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('hold', 'production')),
  client      text not null check (char_length(client) between 1 and 120),
  emails      text[] not null default '{}',          -- every address the hold covers / the client's addresses (lower case)
  title       text not null check (char_length(title) between 1 and 300),   -- hold: the rule · production: the piece of work
  detail      text check (detail is null or char_length(detail) <= 2000),
  stage       text check (stage is null or stage in ('queued', 'building', 'review', 'founder_check', 'client_check', 'ready')),
  builder     text,                                  -- production: who builds it ('f4', 'd0', 'Benas''s EDITOR')
  set_by      text,                                  -- hold: the founder who ordered it · production: who it waits on
  link        text,
  job         text,                                  -- video_jobs slug when the row comes from the job queue
  status      text not null default 'open' check (status in ('open', 'closed')),
  closed_note text,
  created_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  closed_at   timestamptz
);
create index if not exists desk_items_open on public.desk_items (kind, status);
create unique index if not exists desk_items_job on public.desk_items (job) where job is not null;

alter table public.desk_items enable row level security;
drop policy if exists "founders read" on public.desk_items;
create policy "founders read" on public.desk_items for select using (public.is_admin());
revoke all on public.desk_items from anon;
revoke insert, update, delete, truncate, references, trigger on public.desk_items from authenticated;
grant select on public.desk_items to authenticated;

create or replace function public.desk_items_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists desk_items_touch on public.desk_items;
create trigger desk_items_touch before update on public.desk_items for each row execute function public.desk_items_touch();

-- Check after applying: a founder login can select from desk_items; a client login gets 0 rows; anon gets "permission denied".
