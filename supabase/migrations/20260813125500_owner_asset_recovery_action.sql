-- UI-friendly wrapper for the Owner break-glass asset assignment recovery.
-- Keeps the existing audited recovery implementation as the single source of truth.

create or replace function public.owner_recover_asset_assignment(target_id uuid, reason text)
returns jsonb
language sql
security definer
set search_path='public','pg_temp'
as $$
  select public.owner_recover_asset_assignment_state(target_id,btrim(reason));
$$;

grant execute on function public.owner_recover_asset_assignment(uuid,text) to authenticated;
