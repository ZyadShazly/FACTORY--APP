-- Complete the Project pilot workflow without rewriting existing project history.
-- Additive, backward compatible, and safe to review without applying to production.
begin;

alter table public.projects
  add column if not exists project_approved_by uuid references public.profiles(id) on delete restrict,
  add column if not exists project_approved_at timestamptz,
  add column if not exists execution_started_by uuid references public.profiles(id) on delete restrict,
  add column if not exists execution_started_at timestamptz,
  add column if not exists project_completed_by uuid references public.profiles(id) on delete restrict,
  add column if not exists project_completed_at timestamptz,
  add column if not exists project_closed_by uuid references public.profiles(id) on delete restrict,
  add column if not exists project_closed_at timestamptz;

create index if not exists projects_project_approved_by_idx
  on public.projects(project_approved_by) where project_approved_by is not null;
create index if not exists projects_execution_started_by_idx
  on public.projects(execution_started_by) where execution_started_by is not null;
create index if not exists projects_project_completed_by_idx
  on public.projects(project_completed_by) where project_completed_by is not null;
create index if not exists projects_project_closed_by_idx
  on public.projects(project_closed_by) where project_closed_by is not null;

create or replace function private.project_approval_readiness(target_project uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  p public.projects%rowtype;
  approved public.project_budget_versions%rowtype;
  valid_lines integer:=0;
  details_ready boolean;
  budget_ready boolean;
  override_ready boolean;
begin
  select * into p from public.projects where id=target_project;
  if not found then raise exception 'Project not found'; end if;

  select * into approved
  from public.project_budget_versions
  where project_id=target_project and status='approved'
  order by approved_at desc
  limit 1;

  if approved.id is not null then
    select count(*) into valid_lines
    from public.project_budget_items
    where budget_version_id=approved.id and total_with_waste>0;
  end if;

  details_ready:=btrim(coalesce(p.project_name,''))<>''
    and p.customer_id is not null
    and p.start_date is not null
    and (p.delivery_date is null or p.delivery_date>=p.start_date);
  budget_ready:=approved.id is not null
    and approved.expected_total_cost>0
    and valid_lines>0;
  override_ready:=p.budget_activation_override_at is not null
    and btrim(coalesce(p.budget_activation_override_reason,''))<>'';

  return jsonb_build_object(
    'ready',details_ready and (
      budget_ready or p.legacy_activation_exempt or override_ready
    ),
    'details_ready',details_ready,
    'budget_ready',budget_ready,
    'legacy_activation_exempt',p.legacy_activation_exempt,
    'override_ready',override_ready,
    'approved_budget_version_id',approved.id,
    'checks',jsonb_build_array(
      jsonb_build_object(
        'key','required_details','label','بيانات المشروع والعميل والتواريخ',
        'passed',details_ready,'blocking',true
      ),
      jsonb_build_object(
        'key','approved_budget','label','ميزانية تقديرية موجبة ومعتمدة',
        'passed',budget_ready,'blocking',
        not p.legacy_activation_exempt and not override_ready
      ),
      jsonb_build_object(
        'key','legacy_exemption','label','إعفاء مشروع قديم محفوظ',
        'passed',p.legacy_activation_exempt,'blocking',false
      ),
      jsonb_build_object(
        'key','owner_override','label','تجاوز مالك موثق وموجود مسبقًا',
        'passed',override_ready,'blocking',false
      )
    )
  );
end $$;

create or replace function private.project_completion_readiness(target_project uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  milestone_count integer:=0;
  request_count integer:=0;
  order_count integer:=0;
  invoice_count integer:=0;
  production_count integer:=0;
  custody_count integer:=0;
  first_milestone jsonb;
  first_request jsonb;
  first_order jsonb;
  first_invoice jsonb;
  first_production jsonb;
  first_custody jsonb;
begin
  if not exists(select 1 from public.projects where id=target_project) then
    raise exception 'Project not found';
  end if;

  select count(*),(
    select jsonb_build_object(
      'id',m.id,'name',m.title,'status',m.status
    )
    from public.project_milestones m
    where m.project_id=target_project
      and m.status not in ('completed','cancelled')
    order by m.sequence,m.created_at
    limit 1
  ) into milestone_count,first_milestone
  from public.project_milestones m
  where m.project_id=target_project
    and m.status not in ('completed','cancelled');

  select count(*),(
    select jsonb_build_object(
      'id',r.id,'number',r.request_number,
      'name',r.display_name,'status',r.status
    )
    from public.purchase_requests r
    where r.project_id=target_project
      and r.status in ('draft','submitted','approved')
    order by r.created_at
    limit 1
  ) into request_count,first_request
  from public.purchase_requests r
  where r.project_id=target_project
    and r.status in ('draft','submitted','approved');

  select count(*),(
    select jsonb_build_object(
      'id',o.id,'number',o.order_number,
      'name',o.display_name,'status',o.status
    )
    from public.purchase_orders o
    where o.project_id=target_project
      and o.status in (
        'draft','approved','sent','partially_received','fully_received'
      )
    order by o.created_at
    limit 1
  ) into order_count,first_order
  from public.purchase_orders o
  where o.project_id=target_project
    and o.status in (
      'draft','approved','sent','partially_received','fully_received'
    );

  select count(*),(
    select jsonb_build_object(
      'id',i.id,'number',i.invoice_number,
      'name',i.invoice_number,'status',i.status
    )
    from public.supplier_invoices i
    left join public.purchase_orders invoice_order
      on invoice_order.id=i.purchase_order_id
    where coalesce(i.project_id,invoice_order.project_id)=target_project
      and i.status in ('draft','submitted','matched')
    order by i.created_at
    limit 1
  ) into invoice_count,first_invoice
  from public.supplier_invoices i
  left join public.purchase_orders invoice_order
    on invoice_order.id=i.purchase_order_id
  where coalesce(i.project_id,invoice_order.project_id)=target_project
    and i.status in ('draft','submitted','matched');

  select count(*),(
    select jsonb_build_object(
      'id',o.id,'number','PROD-'||upper(left(o.id::text,8)),
      'name',p.name,'status',o.status
    )
    from public.production_orders o
    left join public.products p on p.id=o.product_id
    where o.project_id=target_project
      and o.status not in ('completed','cancelled')
    order by o.created_at
    limit 1
  ) into production_count,first_production
  from public.production_orders o
  where o.project_id=target_project
    and o.status not in ('completed','cancelled');

  select count(*),(
    select jsonb_build_object(
      'id',a.id,'number',a.assignment_code,
      'name',coalesce(a.receiver_name_snapshot,'عهدة مشروع'),
      'status',a.status
    )
    from public.asset_assignments a
    where a.project_id=target_project
      and a.status in (
        'pending_receiver_confirmation','issued','partially_returned',
        'settlement_pending'
      )
    order by a.created_at
    limit 1
  ) into custody_count,first_custody
  from public.asset_assignments a
  where a.project_id=target_project
    and a.status in (
      'pending_receiver_confirmation','issued','partially_returned',
      'settlement_pending'
    );

  return jsonb_build_object(
    'ready',
      milestone_count=0 and request_count=0 and order_count=0
      and invoice_count=0 and production_count=0 and custody_count=0,
    'checks',jsonb_build_array(
      jsonb_build_object(
        'key','milestones','label','مراحل تنفيذ غير مكتملة',
        'count',milestone_count,'first_record',first_milestone,
        'safe_alternative','أكمل المرحلة أو ألغها بسبب موثق'
      ),
      jsonb_build_object(
        'key','purchase_requests','label','طلبات شراء نشطة',
        'count',request_count,'first_record',first_request,
        'safe_alternative','أكمل الطلب أو ارفضه أو ألغِه'
      ),
      jsonb_build_object(
        'key','purchase_orders','label','أوامر شراء نشطة',
        'count',order_count,'first_record',first_order,
        'safe_alternative','أكمل الاستلام والفاتورة أو ألغِ الأمر'
      ),
      jsonb_build_object(
        'key','supplier_invoices','label','فواتير موردين غير معتمدة',
        'count',invoice_count,'first_record',first_invoice,
        'safe_alternative','راجع الفاتورة واعتمدها أو ارفضها بسبب موثق'
      ),
      jsonb_build_object(
        'key','production_orders','label','أوامر إنتاج نشطة',
        'count',production_count,'first_record',first_production,
        'safe_alternative','أكمل أمر الإنتاج أو ألغِه واعكس حركاته'
      ),
      jsonb_build_object(
        'key','asset_assignments','label','عهد مفتوحة',
        'count',custody_count,'first_record',first_custody,
        'safe_alternative','أكمل الإرجاع والتأكيد قبل إغلاق المشروع'
      )
    )
  );
end $$;

create or replace function private.assert_project_downstream_allowed(
  target_project uuid,
  requested_action text
)
returns void
language plpgsql
stable
security definer
set search_path=''
as $$
declare p public.projects%rowtype;
begin
  if target_project is null then return; end if;
  select * into p from public.projects where id=target_project;
  if not found then raise exception 'Project not found'; end if;
  if p.lifecycle<>'active' then
    raise exception using
      errcode='P0001',
      message=format(
        'Project downstream workflow blocked|%s|%s|%s|%s|%s',
        p.id,p.project_code,p.project_name,p.lifecycle,requested_action
      );
  end if;
end $$;

create or replace function private.guard_downstream_project_state()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  target_project uuid;
  target_status text:=to_jsonb(new)->>'status';
  previous_status text:=case
    when tg_op='UPDATE' then to_jsonb(old)->>'status'
    else null
  end;
begin
  if tg_table_name in (
    'purchase_requests','purchase_orders','production_orders'
  ) then
    target_project:=nullif(to_jsonb(new)->>'project_id','')::uuid;
  elsif tg_table_name='supplier_invoices' then
    target_project:=nullif(to_jsonb(new)->>'project_id','')::uuid;
    if target_project is null then
      select o.project_id into target_project
      from public.purchase_orders o
      where o.id=nullif(to_jsonb(new)->>'purchase_order_id','')::uuid;
    end if;
  elsif tg_table_name='supplier_quotes' then
    select r.project_id into target_project
    from public.purchase_requests r
    where r.id=nullif(to_jsonb(new)->>'purchase_request_id','')::uuid;
  elsif tg_table_name='goods_receipts' then
    select o.project_id into target_project
    from public.purchase_orders o
    where o.id=nullif(to_jsonb(new)->>'purchase_order_id','')::uuid;
  elsif tg_table_name='production_material_requirements' then
    select o.project_id into target_project
    from public.production_orders o
    where o.id=nullif(to_jsonb(new)->>'production_order_id','')::uuid;
  elsif tg_table_name='production_order_operations' then
    select o.project_id into target_project
    from public.production_order_operations op
    join public.production_orders o on o.id=op.production_order_id
    where op.id=nullif(to_jsonb(new)->>'id','')::uuid;
    if target_project is null then
      select o.project_id into target_project
      from public.production_orders o
      where o.id=nullif(to_jsonb(new)->>'production_order_id','')::uuid;
    end if;
  end if;

  if tg_op='UPDATE'
     and target_status is distinct from previous_status
     and target_status in (
       'cancelled','rejected','reversed','paid','closed'
     ) then
    return new;
  end if;

  perform private.assert_project_downstream_allowed(
    target_project,tg_table_name||':'||coalesce(target_status,tg_op)
  );
  return new;
end $$;

create or replace function private.protect_project_manager_assignment()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if coalesce(
    current_setting('app.project_manager_rpc',true),'off'
  )<>'on' then
    if tg_op='INSERT' and new.active
       and new.project_role='project_manager' then
      raise exception 'Use the protected project manager assignment workflow';
    elsif tg_op='UPDATE' and (
      (old.active and old.project_role='project_manager')
      or (new.active and new.project_role='project_manager')
    ) then
      raise exception 'Use the protected project manager assignment workflow';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists protect_project_manager_assignment
  on public.project_members;
create trigger protect_project_manager_assignment
before insert or update on public.project_members
for each row execute function private.protect_project_manager_assignment();

do $$
declare table_name text;
begin
  foreach table_name in array array[
    'purchase_requests','supplier_quotes','purchase_orders','goods_receipts',
    'supplier_invoices','production_orders',
    'production_material_requirements','production_order_operations'
  ] loop
    execute format(
      'drop trigger if exists project_downstream_state_guard on public.%I',
      table_name
    );
    execute format(
      'create trigger project_downstream_state_guard
       before insert or update on public.%I
       for each row execute function private.guard_downstream_project_state()',
      table_name
    );
  end loop;
end $$;

create or replace function public.transition_project_lifecycle(
  target_project uuid,
  next_lifecycle text,
  reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  p public.projects%rowtype;
  actor uuid:=(select auth.uid());
  actor_role text;
  allowed boolean:=false;
  readiness jsonb;
  from_lifecycle text;
begin
  if actor is null
     or not private.project_can_manage(
       target_project,'projects_manage_lifecycle'
     ) then
    raise exception using
      errcode='42501',
      message='projects_manage_lifecycle permission required';
  end if;
  select * into p from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found'; end if;
  from_lifecycle:=p.lifecycle;
  actor_role:=public.current_identity_role();
  if p.lifecycle in ('closed','cancelled') then
    raise exception 'Final project lifecycle cannot change';
  end if;
  allowed:=case p.lifecycle
    when 'draft' then next_lifecycle in ('planning','cancelled')
    when 'planning' then
      next_lifecycle in ('draft','ready_for_activation','cancelled')
    when 'ready_for_activation' then
      next_lifecycle in ('planning','active','cancelled')
    when 'active' then next_lifecycle in ('on_hold','completed')
    when 'on_hold' then next_lifecycle in ('active','cancelled')
    when 'completed' then next_lifecycle in ('active','closed')
    else false
  end;
  if not allowed then
    raise exception
      'Invalid project lifecycle transition: % -> %',
      p.lifecycle,next_lifecycle;
  end if;
  if next_lifecycle in ('cancelled','closed')
     or (p.lifecycle='completed' and next_lifecycle='active') then
    if btrim(coalesce(reason,''))='' then
      raise exception 'A mandatory reason is required for this transition';
    end if;
  end if;
  if p.lifecycle='completed' and next_lifecycle='active'
     and (
       actor_role<>'owner'
       or not private.project_has_permission('projects_override')
     ) then
    raise exception 'Only Owner may reopen a completed project';
  end if;
  if next_lifecycle='closed'
     and not private.project_has_permission('projects_close') then
    raise exception 'projects_close permission required';
  end if;
  if p.lifecycle='planning' and next_lifecycle='ready_for_activation' then
    readiness:=private.project_approval_readiness(target_project);
    if not coalesce((readiness->>'ready')::boolean,false) then
      raise exception 'Project approval readiness checks are incomplete';
    end if;
  elsif p.lifecycle='ready_for_activation' and next_lifecycle='active' then
    readiness:=public.project_activation_readiness(target_project);
    if not coalesce((readiness->>'ready')::boolean,false) then
      raise exception 'Project execution readiness checks are incomplete';
    end if;
  elsif p.lifecycle='active' and next_lifecycle='completed' then
    readiness:=private.project_completion_readiness(target_project);
    if not coalesce((readiness->>'ready')::boolean,false) then
      raise exception 'Project completion dependencies remain open';
    end if;
  elsif p.lifecycle='completed' and next_lifecycle='closed' then
    readiness:=private.project_completion_readiness(target_project);
    if not coalesce((readiness->>'ready')::boolean,false) then
      raise exception 'Project closure dependencies remain open';
    end if;
  end if;

  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects
  set lifecycle=next_lifecycle,
      lifecycle_reason=nullif(btrim(reason),''),
      lifecycle_changed_by=actor,
      lifecycle_changed_at=now(),
      project_approved_by=case
        when from_lifecycle='planning'
         and next_lifecycle='ready_for_activation' then actor
        else project_approved_by
      end,
      project_approved_at=case
        when from_lifecycle='planning'
         and next_lifecycle='ready_for_activation' then now()
        else project_approved_at
      end,
      execution_started_by=case
        when next_lifecycle='active'
         and from_lifecycle='ready_for_activation' then actor
        else execution_started_by
      end,
      execution_started_at=case
        when next_lifecycle='active'
         and from_lifecycle='ready_for_activation' then now()
        else execution_started_at
      end,
      project_completed_by=case
        when next_lifecycle='completed' then actor
        else project_completed_by
      end,
      project_completed_at=case
        when next_lifecycle='completed' then now()
        else project_completed_at
      end,
      project_closed_by=case
        when next_lifecycle='closed' then actor
        else project_closed_by
      end,
      project_closed_at=case
        when next_lifecycle='closed' then now()
        else project_closed_at
      end,
      execution_stage=case
        when next_lifecycle='active'
         and execution_stage in ('design','approval') then 'manufacturing'
        when next_lifecycle in ('completed','closed') then 'delivered'
        when next_lifecycle='on_hold' then 'on_hold'
        else execution_stage
      end,
      status=case
        when next_lifecycle='active'
         and status in ('design','approval','on_hold') then 'manufacturing'
        when next_lifecycle in ('completed','closed') then 'delivered'
        when next_lifecycle='on_hold' then 'on_hold'
        else status
      end,
      updated_by=actor
  where id=target_project
  returning * into p;

  insert into public.project_activities(
    project_id,actor_id,action_type,description,metadata
  ) values(
    target_project,actor,
    case next_lifecycle
      when 'ready_for_activation' then 'project_approved'
      when 'active' then
        case when from_lifecycle='on_hold'
          then 'project_resumed' else 'project_execution_started' end
      when 'completed' then 'project_completed'
      when 'closed' then 'project_closed'
      else 'lifecycle_changed'
    end,
    case next_lifecycle
      when 'ready_for_activation' then 'تم اعتماد المشروع'
      when 'active' then
        case when from_lifecycle='on_hold'
          then 'تم استئناف المشروع' else 'تم بدء تنفيذ المشروع' end
      when 'completed' then 'تم إكمال المشروع'
      when 'closed' then 'تم إغلاق المشروع'
      else 'تم تغيير دورة حياة المشروع'
    end,
    jsonb_build_object(
      'from',from_lifecycle,'to',next_lifecycle,'reason',reason
    )
  );
  return case
    when private.project_has_permission('project_financials_view')
      then to_jsonb(p)
    else to_jsonb(p)-array[
      'expected_cost','actual_cost','revenue','profit'
    ]
  end;
end $$;

create or replace function public.assign_project_manager_secure(
  target_project uuid,
  target_profile uuid,
  change_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  p public.projects%rowtype;
  selected_profile public.profiles%rowtype;
  previous_manager uuid;
  member public.project_members%rowtype;
begin
  if actor is null
     or not private.project_can_manage(target_project,'projects_manage_team')
  then
    raise exception using
      errcode='42501',message='projects_manage_team permission required';
  end if;
  select * into p from public.projects where id=target_project for update;
  if not found then raise exception 'Project not found'; end if;
  if p.lifecycle in ('closed','cancelled') then
    raise exception 'Final projects are immutable';
  end if;
  select * into selected_profile
  from public.profiles
  where id=target_profile and coalesce(status,'active')='active';
  if not found then raise exception 'Active project manager profile required'; end if;
  previous_manager:=p.project_manager_id;
  if previous_manager=target_profile then return to_jsonb(p); end if;
  if previous_manager is not null
     and btrim(coalesce(change_reason,''))='' then
    raise exception 'Project manager change reason required';
  end if;

  perform set_config('app.project_manager_rpc','on',true);
  update public.project_members
  set active=false,end_date=coalesce(end_date,current_date),updated_at=now()
  where project_id=target_project
    and active
    and (
      project_role='project_manager'
      or profile_id=target_profile
      or (
        selected_profile.employee_id is not null
        and employee_id=selected_profile.employee_id
      )
    );

  insert into public.project_members(
    project_id,profile_id,employee_id,project_role,
    active,start_date,added_by
  ) values(
    target_project,target_profile,selected_profile.employee_id,
    'project_manager',true,current_date,actor
  ) returning * into member;

  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects
  set project_manager_id=target_profile,updated_by=actor
  where id=target_project
  returning * into p;

  insert into public.project_activities(
    project_id,actor_id,action_type,description,metadata
  ) values(
    target_project,actor,'project_manager_changed',
    case when previous_manager is null
      then 'تم تعيين مدير المشروع'
      else 'تم تغيير مدير المشروع'
    end,
    jsonb_build_object(
      'previous_profile_id',previous_manager,
      'new_profile_id',target_profile,
      'member_id',member.id,
      'reason',nullif(btrim(change_reason),'')
    )
  );
  return to_jsonb(p);
end $$;

create or replace function public.update_project_execution_stage(
  target_project uuid,
  next_stage text,
  reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  p public.projects%rowtype;
  old_stage text;
  actor uuid:=(select auth.uid());
begin
  if actor is null
     or not private.project_can_manage(
       target_project,'projects_manage_milestones'
     ) then
    raise exception using
      errcode='42501',
      message='projects_manage_milestones permission required';
  end if;
  if next_stage not in (
    'design','approval','manufacturing','painting',
    'installation','delivered','on_hold','cancelled'
  ) then
    raise exception 'Invalid execution stage';
  end if;
  select * into p
  from public.projects
  where id=target_project
  for update;
  if not found then raise exception 'Project not found'; end if;
  if p.lifecycle in ('closed','cancelled') then
    raise exception 'Final projects are immutable';
  end if;
  if next_stage in (
    'manufacturing','painting','installation','delivered'
  ) and p.lifecycle not in ('active','completed') then
    raise exception 'Project execution approval required';
  end if;
  if next_stage='on_hold' and p.lifecycle not in ('active','on_hold') then
    raise exception 'Active project required before placing execution on hold';
  end if;
  old_stage:=p.execution_stage;
  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects
  set execution_stage=next_stage,status=next_stage,updated_by=actor
  where id=target_project
  returning * into p;
  insert into public.project_activities(
    project_id,actor_id,action_type,description,metadata
  ) values(
    target_project,actor,'execution_stage_changed',
    'تم تغيير مرحلة تنفيذ المشروع',
    jsonb_build_object(
      'from',old_stage,'to',next_stage,'reason',reason
    )
  );
  return case
    when private.project_has_permission('project_financials_view')
      then to_jsonb(p)
    else to_jsonb(p)-array[
      'expected_cost','actual_cost','revenue','profit'
    ]
  end;
end $$;

create or replace function public.approve_project_for_execution(
  target_project uuid
)
returns jsonb
language sql
security definer
set search_path=''
as $$
  select public.transition_project_lifecycle(
    target_project,'ready_for_activation',null
  )
$$;

create or replace function public.start_project_execution(
  target_project uuid
)
returns jsonb
language sql
security definer
set search_path=''
as $$
  select public.transition_project_lifecycle(target_project,'active',null)
$$;

create or replace function public.complete_project_execution(
  target_project uuid
)
returns jsonb
language sql
security definer
set search_path=''
as $$
  select public.transition_project_lifecycle(target_project,'completed',null)
$$;

create or replace function public.close_project_secure(
  target_project uuid,
  close_reason text
)
returns jsonb
language sql
security definer
set search_path=''
as $$
  select public.transition_project_lifecycle(
    target_project,'closed',close_reason
  )
$$;

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
        'complete',p.lifecycle in (
          'ready_for_activation','active','on_hold','completed','closed'
        ),
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

revoke all on function private.project_approval_readiness(uuid)
  from public,anon,authenticated;
revoke all on function private.project_completion_readiness(uuid)
  from public,anon,authenticated;
revoke all on function private.assert_project_downstream_allowed(uuid,text)
  from public,anon,authenticated;
revoke all on function private.guard_downstream_project_state()
  from public,anon,authenticated;
revoke all on function private.protect_project_manager_assignment()
  from public,anon,authenticated;

revoke all on function public.transition_project_lifecycle(uuid,text,text)
  from public,anon,authenticated;
revoke all on function public.assign_project_manager_secure(uuid,uuid,text)
  from public,anon,authenticated;
revoke all on function public.update_project_execution_stage(uuid,text,text)
  from public,anon,authenticated;
revoke all on function public.approve_project_for_execution(uuid)
  from public,anon,authenticated;
revoke all on function public.start_project_execution(uuid)
  from public,anon,authenticated;
revoke all on function public.complete_project_execution(uuid)
  from public,anon,authenticated;
revoke all on function public.close_project_secure(uuid,text)
  from public,anon,authenticated;
revoke all on function public.get_project_pilot_workflow(uuid)
  from public,anon,authenticated;

grant execute on function public.transition_project_lifecycle(uuid,text,text)
  to authenticated;
grant execute on function public.assign_project_manager_secure(uuid,uuid,text)
  to authenticated;
grant execute on function public.update_project_execution_stage(uuid,text,text)
  to authenticated;
grant execute on function public.approve_project_for_execution(uuid)
  to authenticated;
grant execute on function public.start_project_execution(uuid)
  to authenticated;
grant execute on function public.complete_project_execution(uuid)
  to authenticated;
grant execute on function public.close_project_secure(uuid,text)
  to authenticated;
grant execute on function public.get_project_pilot_workflow(uuid)
  to authenticated;

commit;
