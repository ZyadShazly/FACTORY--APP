create or replace function public.refresh_project_actual_cost(target_project uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or not public.is_current_profile_active() or role_name not in ('owner','manager','accountant') then
    raise exception using errcode='42501',message='Project financial access required';
  end if;
  if not private.project_can_view(target_project) then
    raise exception using errcode='42501',message='Project access denied';
  end if;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects set actual_cost=private.project_approved_actual_cost(target_project),updated_at=now() where id=target_project;
end $$;