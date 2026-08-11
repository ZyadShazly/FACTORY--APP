begin;

-- SECURITY DEFINER routines inherit EXECUTE from PUBLIC unless it is revoked.
-- Keep only the four token-based asset confirmation endpoints public; all other
-- definer routines require an authenticated grant or remain internal-only.
do $$
declare
  routine record;
begin
  for routine in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef
      and p.proname not in (
        'asset_confirmation_preview',
        'asset_return_confirmation_preview',
        'confirm_asset_assignment',
        'confirm_asset_return'
      )
  loop
    execute format('revoke execute on function %s from public, anon', routine.signature);
  end loop;
end
$$;

-- Trigger functions are internal implementation details and must not be callable
-- through the API by either anonymous or authenticated clients.
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

commit;
