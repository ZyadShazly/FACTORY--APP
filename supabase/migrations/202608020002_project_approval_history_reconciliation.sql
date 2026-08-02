-- Surface projects whose execution history predates a recorded approval event.
-- No project row or historical activity is rewritten.
begin;

create or replace function public.get_project_pilot_workflow(
  target_project uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  p public.projects%rowtype;
  approval jsonb;
  execution jsonb;
  completion jsonb;
  manager jsonb;
  next_action text;
begin
  if (select auth.uid()) is null
     or not private.project_can_view(target_project) then
    raise exception using
      errcode='42501',message='Project view permission required';
  end if;
  select * into p from public.projects where id=target_project;
  if not found then raise exception 'Project not found'; end if;
  approval:=private.project_approval_readiness(target_project);
  execution:=public.project_activation_readiness(target_project);
  completion:=private.project_completion_readiness(target_project);
  if not private.project_can_manage(
    target_project,'projects_manage_lifecycle'
  ) then
    select jsonb_set(
      completion,'{checks}',
      coalesce(jsonb_agg(check_item-'first_record'),'[]'::jsonb)
    ) into completion
    from jsonb_array_elements(completion->'checks') check_item;
  end if;
  select jsonb_build_object(
    'id',pr.id,'name',coalesce(pr.full_name,pr.email),
    'employee_id',pr.employee_id
  ) into manager
  from public.profiles pr
  where pr.id=p.project_manager_id;

  next_action:=case
    when p.lifecycle in ('active','on_hold','completed','closed')
      and p.project_approved_at is null
      then 'reconcile_project_approval_history'
    when p.lifecycle='draft' then 'prepare_project'
    when p.lifecycle='planning'
      and not coalesce((approval->>'ready')::boolean,false)
      then 'complete_budget_and_details'
    when p.lifecycle='planning' then 'approve_project'
    when p.lifecycle='ready_for_activation'
      and p.project_manager_id is null then 'assign_project_manager'
    when p.lifecycle='ready_for_activation' then 'start_execution'
    when p.lifecycle='active'
      and not coalesce((completion->>'ready')::boolean,false)
      then 'resolve_open_dependencies'
    when p.lifecycle='active' then 'complete_project'
    when p.lifecycle='completed' then 'close_project'
    when p.lifecycle='on_hold' then 'resume_project'
    else 'view_history'
  end;

  return jsonb_build_object(
    'project_id',p.id,
    'lifecycle',p.lifecycle,
    'next_action',next_action,
    'manager',manager,
    'approval_readiness',approval,
    'execution_readiness',execution,
    'completion_readiness',completion,
    'approval_reconciliation',jsonb_build_object(
      'required',p.lifecycle in ('active','on_hold','completed','closed')
        and p.project_approved_at is null,
      'reason','Execution exists without recorded project approval',
      'safe_alternative','راجع سجل النشاط وحدد الاستثناء التاريخي بسبب موثق؛ لا تسجل اعتمادًا بأثر رجعي',
      'execution_started_at',p.execution_started_at,
      'checks',jsonb_build_array(jsonb_build_object(
        'key','project_approval_history',
        'label','سجل اعتماد المشروع غير مكتمل',
        'passed',not (p.lifecycle in ('active','on_hold','completed','closed')
          and p.project_approved_at is null),
        'blocking',true,
        'safe_alternative','راجع سجل النشاط وحدد الاستثناء التاريخي بسبب موثق؛ لا تسجل اعتمادًا بأثر رجعي'
      ))
    ),
    'steps',jsonb_build_array(
      jsonb_build_object(
        'key','project_created','label','إنشاء المشروع',
        'complete',true
      ),
      jsonb_build_object(
        'key','budget_approved','label','اعتماد الميزانية',
        'complete',coalesce((approval->>'budget_ready')::boolean,false)
          or p.legacy_activation_exempt
          or coalesce((approval->>'override_ready')::boolean,false)
      ),
      jsonb_build_object(
        'key','project_approved','label','اعتماد المشروع',
        'complete',p.project_approved_at is not null,
        'at',p.project_approved_at
      ),
      jsonb_build_object(
        'key','manager_assigned','label','تعيين مدير المشروع',
        'complete',p.project_manager_id is not null
      ),
      jsonb_build_object(
        'key','execution_started','label','بدء التنفيذ',
        'complete',p.lifecycle in ('active','on_hold','completed','closed'),
        'at',p.execution_started_at
      ),
      jsonb_build_object(
        'key','project_completed','label','إكمال المشروع',
        'complete',p.lifecycle in ('completed','closed'),
        'at',p.project_completed_at
      ),
      jsonb_build_object(
        'key','project_closed','label','إغلاق المشروع',
        'complete',p.lifecycle='closed','at',p.project_closed_at
      )
    ),
    'capabilities',jsonb_build_object(
      'approve',private.project_can_manage(
        target_project,'projects_manage_lifecycle'
      ),
      'assign_manager',private.project_can_manage(
        target_project,'projects_manage_team'
      ),
      'start',private.project_can_manage(
        target_project,'projects_manage_lifecycle'
      ),
      'complete',private.project_can_manage(
        target_project,'projects_manage_lifecycle'
      ),
      'close',private.project_has_permission('projects_close')
    )
  );
end $$;

revoke all on function public.get_project_pilot_workflow(uuid)
  from public,anon,authenticated;
grant execute on function public.get_project_pilot_workflow(uuid)
  to authenticated;

commit;
