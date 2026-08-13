-- PM-BUD-02: avoid PL/pgSQL ambiguity between the rejection_reason parameter
-- and the project_budget_versions.rejection_reason column.

create or replace function public.reject_project_budget(target_version uuid, rejection_reason text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare
  actor uuid:=auth.uid();
  role_name text:=public.current_identity_role();
  reason_text text:=btrim(coalesce(rejection_reason,''));
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

  if reason_text='' then
    raise exception using errcode='22023',message='A rejection reason is required';
  end if;

  perform set_config('app.project_budget_rpc','on',true);

  update public.project_budget_versions as pbv
  set status='rejected',
      rejection_reason=reason_text,
      rejected_by=actor,
      rejected_at=now(),
      updated_by=actor,
      updated_at=now()
  where pbv.id=target_version
  returning pbv.* into v;

  begin
    perform private.project_budget_activity(
      v.project_id,
      'budget_rejected',
      'تم رفض الميزانية التقديرية',
      jsonb_build_object(
        'budget_version_id',v.id,
        'version_number',v.version_number,
        'reason',reason_text
      )
    );
  exception when others then
    null;
  end;

  return to_jsonb(v);
end
$$;

grant execute on function public.reject_project_budget(uuid,text) to authenticated;
