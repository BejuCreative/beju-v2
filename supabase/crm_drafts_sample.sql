-- 11-23 (SIMAS): sample delivery emails go through the drafts flow; a founder sends them from the Samples tab (Ready column).
alter table public.drafts drop constraint drafts_category_check;
alter table public.drafts add constraint drafts_category_check check (category in ('big_deal', 'client_problem', 'new_terms', 'big_name', 'other', 'sample'));
-- rollback: same with the 'sample' entry removed (only once no row uses it)
