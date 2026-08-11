-- Final release validation: remove SECURITY DEFINER view exposure while preserving
-- the intended reconciliation workflows. Schema-only; no application data changes.

begin;

-- Material reconciliation is safe to execute as the caller because materials already
-- has RLS and authenticated read policies for the allowed operational roles.
alter view public.material_duplicate_candidates set (security_invoker = true);
alter view public.material_identity_reconciliation set (security_invoker = true);

revoke all on public.material_duplicate_candidates, public.material_identity_reconciliation
  from public, anon;
grant select on public.material_duplicate_candidates, public.material_identity_reconciliation
  to authenticated;

-- Procurement source tables intentionally have no direct authenticated access.
-- Make the view invoker-safe and remove direct Data API access; expose the report
-- only through an owner-authorized SECURITY DEFINER RPC.
alter view public.procurement_currency_reconciliation set (security_invoker = true);
revoke all on public.procurement_currency_reconciliation from public, anon, authenticated;

create or replace function public.get_procurement_currency_reconciliation()
returns setof jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null or not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.status = 'active'
      and p.role = 'owner'
  ) then
    raise exception using errcode = '42501', message = 'Owner authorization required';
  end if;

  return query
  select to_jsonb(r)
  from public.procurement_currency_reconciliation r;
end
$$;

revoke all on function public.get_procurement_currency_reconciliation() from public, anon;
grant execute on function public.get_procurement_currency_reconciliation() to authenticated;

comment on function public.get_procurement_currency_reconciliation() is
  'Owner-only reconciliation read for procurement currency metadata. The underlying view is not directly exposed to API roles.';

commit;
