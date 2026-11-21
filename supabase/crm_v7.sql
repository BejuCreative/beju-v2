-- BEJÚ CRM v7 (SIMAS 2026-11-21: big tasks the founders write themselves, opportunities for bigger work, a Leads page).
-- Founders only (public.is_admin()), same pattern as todo_cards in crm_sidebar1.sql. Safe to run again.

-- 1) To-dos: a card can be a BIG task (shown large at the top of the To-dos page).
alter table public.todo_cards add column if not exists big boolean not null default false;

-- 2) Opportunities: a lead or client who could buy bigger work than Shorts (websites, running their socials, funnels ...).
create table if not exists public.opportunities (
  id          bigint generated always as identity primary key,
  client      text not null check (char_length(client) between 1 and 200),
  email       text,                                     -- pipeline / client address, when there is one
  what        text not null check (char_length(what) between 1 and 600),   -- the bigger work, one line
  kinds       text[] not null default '{}',             -- website | socials | funnels | emails | long-form | system | other
  value_usd   numeric,                                  -- what it could be worth
  monthly     boolean not null default false,
  stage       text not null default 'spotted' check (stage in ('spotted', 'talking', 'scope ready', 'scope sent', 'won', 'lost')),
  next_step   text check (next_step is null or char_length(next_step) <= 600),
  link        text,
  owner       text not null default 'Both' check (owner in ('Simas', 'Benas', 'Both')),
  created_by  text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  closed_at   timestamptz
);
alter table public.opportunities enable row level security;
drop policy if exists "founders read" on public.opportunities;
drop policy if exists "founders add" on public.opportunities;
drop policy if exists "founders edit" on public.opportunities;
drop policy if exists "founders delete" on public.opportunities;
create policy "founders read"   on public.opportunities for select using (public.is_admin());
create policy "founders add"    on public.opportunities for insert with check (public.is_admin());
create policy "founders edit"   on public.opportunities for update using (public.is_admin()) with check (public.is_admin());
create policy "founders delete" on public.opportunities for delete using (public.is_admin());
revoke all on public.opportunities from anon;
revoke truncate, references, trigger on public.opportunities from authenticated;
grant select, insert, update, delete on public.opportunities to authenticated;

create or replace function public.opportunities_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists opportunities_touch on public.opportunities;
create trigger opportunities_touch before update on public.opportunities for each row execute function public.opportunities_touch();

do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'opportunities') then
    execute 'alter publication supabase_realtime add table public.opportunities';
  end if;
end $$;

-- 3) Seed: only what the scopes table and the client notes support (2026-11-21).
insert into public.opportunities (client, email, what, kinds, value_usd, monthly, stage, next_step, link, owner, created_by)
select * from (values
  ('Dr. Judy Rosenberg', 'drjudyrosenberg@gmail.com', 'Run her whole business online: four websites, daily posting on four channels, four lead magnet funnels, emails and the book launch',
   array['website','socials','funnels','emails'], 2500::numeric, true, 'scope ready',
   'Scope BEJ-2026-0122 is live but NOT sent: Simas''s hold. He lifts it, then the scope email goes to Judy only.', 'https://bejucreative.digital/scope/dr-judy/', 'Both', 'simas-claude'),
  ('Motion Edits (Aman)', 'video@motionedits.com', 'Build their outreach system', array['system'], 1100::numeric, false, 'scope sent',
   'Scope sent Nov 19. They worry about paying upfront without a trial.', 'https://bejucreative.digital/scope/motionedits/', 'Benas', 'simas-claude'),
  ('MyoProcess', null, 'Run and grow their social media (Max Growth plan)', array['socials'], null::numeric, true, 'scope sent',
   'Scope sent Nov 18. No answer logged yet.', 'https://bejucreative.digital/scope/myoprocess/', 'Both', 'simas-claude')
) as v(client, email, what, kinds, value_usd, monthly, stage, next_step, link, owner, created_by)
where not exists (select 1 from public.opportunities o where o.client = v.client);
