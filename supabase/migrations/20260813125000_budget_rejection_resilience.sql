-- Keep the rejection decision authoritative even if the secondary project activity feed cannot be written.
-- The row-change audit trigger remains mandatory and records the state transition.

create or replace function public.reject_project_budget(target_version uuid, rejection_reason text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare
  actor uuid:=auth.uid();
  role_name text:=public.current_identity_role();
  v public.project_budget_versions%rowtype;
begin
  if actor is null or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Active authenticated profile required';
  end if;

  select * into v
  from public.project_budget_versions
  where id=target_version
  for update;

  if not found then raise exception using errcode='P0002',message='Budget version not found'; end if;

  if role_name<>'owner' and not private.project_budget_can(v.project_id,'project_budget_reject') then
    raise exception using errcode='42501',message='project_budget_reject permission required';
  end if;

  if v.status<>'submitted' then
    raise exception using errcode='23514',message='Only a submitted budget may be rejected';
  end if;

  if btrim(coalesce(rejection_reason,''))='' then
    raise exception using errcode='22023',message='A rejection reason is required';
  end if;

  perform set_config('app.project_budget_rpc','on',true);

  update public.project_budget_versions
  set status='rejected',
      rejection_reason=btrim(rejection_reason),
      rejected_by=actor,
      rejected_at=now(),
      updated_by=actor,
      updated_at=now()
  where id=target_version
  returning * into v;

  -- Secondary timeline only. Do not rollback the valid rejection if this auxiliary feed fails.
  begin
    perform private.project_budget_activity(
      v.project_id,
      'budget_rejected',
      'تم رفض الميزانية التقديرية',
      jsonb_build_object(
        'budget_version_id',v.id,
        'version_number',v.version_number,
        'reason',btrim(rejection_reason)
      )
    );
  exception when others then
    null;
  end;

  return to_jsonb(v);
end
$$;

grant execute on function public.reject_project_budget(uuid,text) to authenticated;
