-- crm_orders4.sql (Benas's side, 11-21): founders fix pack size / kind / status from the CRM Clients page
-- (BENAS: "pack status should be in the client's page"). Writes go straight to `orders` under is_admin() (MFA), only
-- these columns. Replaces the API's order_set (removed in review) and, once the Clients page reads order_progress,
-- the old pack_overrides table.
drop policy if exists "founders fix" on public.orders;
create policy "founders fix" on public.orders for update using (public.is_admin()) with check (public.is_admin());
revoke update on public.orders from authenticated;
grant update (shorts_bought, size_source, kind, status, note, updated_at) on public.orders to authenticated;

-- carry the one pack_overrides row (Simas 11-19: Ben Kump "5-Long form Video pack" delivered in full, 5 of 5)
update public.orders o set status = 'complete', note = coalesce(o.note || ' · ', '') || 'pack_overrides 11-19 (Simas): delivered in full, all 5', updated_at = now()
from public.pack_overrides p
where p.client_id = o.client_id and p.order_name = o.folder and p.status = 'finished' and o.status <> 'complete';
