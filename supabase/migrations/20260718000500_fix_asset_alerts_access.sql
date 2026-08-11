-- Restore safe authenticated access to asset alerts without exposing public.assets.
-- The view remains owner-executed and projects non-financial alert metadata only.
create or replace view public.asset_alerts
with (security_barrier=true, security_invoker=false)
as
select alerts.alert_type,
       alerts.reference_id,
       alerts.title,
       alerts.due_at,
       alerts.severity,
       alerts.created_at
from (
  select 'assignment_overdue'::text as alert_type,
         assignment.id as reference_id,
         assignment.assignment_code as title,
         assignment.expected_return_at as due_at,
         'high'::text as severity,
         assignment.created_at
  from public.asset_assignments as assignment
  where assignment.expected_return_at < now()
    and assignment.status in ('issued','partially_returned','settlement_pending')

  union all

  select 'confirmation_pending'::text,
         assignment.id,
         assignment.assignment_code,
         assignment.confirmation_expires_at,
         'medium'::text,
         assignment.created_at
  from public.asset_assignments as assignment
  where assignment.status = 'pending_receiver_confirmation'
    and assignment.confirmation_used_at is null

  union all

  select 'warranty_expiring'::text,
         asset.id,
         asset.asset_code,
         asset.warranty_until::timestamptz,
         'low'::text,
         asset.created_at
  from public.assets as asset
  cross join public.asset_settings as settings
  where asset.warranty_until between current_date and current_date + settings.warranty_alert_days

  union all

  select 'asset_risk'::text,
         asset.id,
         asset.asset_code,
         null::timestamptz,
         'high'::text,
         asset.created_at
  from public.assets as asset
  where asset.operational_status in ('lost','stolen','under_maintenance')
) as alerts
where public.has_permission('assets_view');

revoke all on table public.asset_alerts from public, anon;
grant select on table public.asset_alerts to authenticated;

-- Keep the underlying asset registry inaccessible through PostgREST.
revoke select on table public.assets from public, anon, authenticated;

comment on view public.asset_alerts is
 'Owner-executed security-barrier view exposing only non-financial asset alert metadata after an explicit assets_view permission check; underlying private asset fields remain inaccessible.';
