begin;

-- Preserve the four token-based asset confirmation endpoints that are intentionally
-- callable without an authenticated session. Every other routine in public must
-- require authentication or be internal-only.
do $$
declare
  routine record;
begin
  for routine in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.proname not in (
        'asset_confirmation_preview',
        'asset_return_confirmation_preview',
        'confirm_asset_assignment',
        'confirm_asset_return'
      )
  loop
    execute format('revoke execute on function %s from anon', routine.signature);
  end loop;
end
$$;

-- Trigger functions are never application RPC endpoints. Prevent both anonymous
-- and signed-in clients from invoking them directly while preserving trigger use.
do $$
declare
  routine record;
begin
  for routine in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prorettype = 'pg_catalog.trigger'::regtype
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', routine.signature);
  end loop;
end
$$;

-- Fix the mutable search_path warnings reported by the live Supabase advisor.
alter function public.set_updated_at() set search_path = public, pg_temp;
alter function public.calculate_daily_labor() set search_path = public, pg_temp;
alter function public.normalize_department_name(text) set search_path = public, pg_temp;
alter function public.calendar_shift_minutes(time without time zone, time without time zone, boolean) set search_path = public, pg_temp;

commit;
