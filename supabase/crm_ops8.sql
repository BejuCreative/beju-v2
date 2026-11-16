-- Client notes for the CRM pages (Simas 11-16: "see all of our paid clients, what are the next steps and important
-- info ... hot leads all of them, what are we pitching them"). public.client_notes already exists (crm_ops5.sql,
-- founder-only RLS via is_admin(), unique on lead_email + kind + note). Two columns are added:
--   noted_at = the date on the line in docs/clients/<email>.md (created_at is only when the row reached the database)
--   name     = the file's "# ..." title (the client's name / brand)
-- Filled by scripts/client_notes_sync.py (Dashboard repo, hourly from crm_sync.py) and by client_notes.py add().
alter table public.client_notes add column if not exists noted_at date;
alter table public.client_notes add column if not exists name text;
create index if not exists client_notes_noted on public.client_notes (lead_email, noted_at desc);
