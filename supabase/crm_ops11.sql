-- Calls (Simas 11-17: "you need to track it through cal.com. And if a client wants a meeting, they have to book it through
-- there"). One row per cal.com booking, filled ONLY from cal.com (scripts/calcom_calls.py reads the booking .ics). The CRM's
-- calls (Do next, Today) come from here and nowhere else, so a "call" written in a next-action note is never a call.
create table if not exists public.calls (
  uid text primary key,                -- cal.com booking uid (ICS UID without @Cal.com)
  name text,                           -- guest name
  email text,                          -- guest email
  title text,                          -- event title, e.g. "Free Brand Content Analysis between Beju Creative and X"
  start_at timestamptz not null,
  end_at timestamptz,
  status text not null default 'booked',   -- booked | cancelled
  meet_url text,
  organizer text,                      -- the cal.com account (bejusipe@gmail.com)
  booked_at timestamptz,               -- DTSTAMP of the booking
  source_msg text,                     -- Gmail message id of the cal.com email
  updated_at timestamptz not null default now()
);
create index if not exists calls_start_idx on public.calls (start_at);
alter table public.calls enable row level security;
drop policy if exists "founders read" on public.calls;
create policy "founders read" on public.calls for select using (public.is_admin());
