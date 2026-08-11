-- Production pilot completion and repository reconciliation for the live
-- production_execution_quality migration. Additive and history preserving.
begin;

alter table public.production_order_operations
  add column if not exists assigned_employee_id uuid references public.employees(id) on delete restrict,
  add column if not exists assigned_by uuid references public.profiles(id) on delete restrict,
  add column if not exists assigned_at timestamptz,
  add column if not exists paused_at timestamptz,
  add column if not exists total_paused_minutes numeric not null default 0,
  add column if not exists accepted_quantity numeric not null default 0,
  add column if not exists rejected_quantity numeric not null default 0,
  add column if not exists rework_quantity numeric not null default 0,
  add column if not exists quality_status text not null default 'pending';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.production_order_operations'::regclass
      and conname='production_operation_quantities_check'
  ) then
    alter table public.production_order_operations
      add constraint production_operation_quantities_check
      check (
        accepted_quantity>=0 and rejected_quantity>=0 and
        rework_quantity>=0 and total_paused_minutes>=0
      );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.production_order_operations'::regclass
      and conname='production_operation_quality_status_check'
  ) then
    alter table public.production_order_operations
      add constraint production_operation_quality_status_check
      check (quality_status in ('pending','awaiting_review','approved','rejected'));
  end if;
end $$;

create table if not exists public.production_operation_events (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null references public.production_order_operations(id) on delete restrict,
  event_type text not null check (
    event_type in (
      'assigned','started','paused','resumed','completed',
      'quality_submitted','quality_approved','quality_rejected'
    )
  ),
  reason text,
  event_data jsonb not null default '{}'::jsonb,
  actor_id uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  occurred_at timestamptz not null default now()
);

create index if not exists production_operations_assigned_employee_idx
  on public.production_order_operations(assigned_employee_id)
  where assigned_employee_id is not null;
create index if not exists production_operations_assigned_by_idx
  on public.production_order_operations(assigned_by)
  where assigned_by is not null;
create index if not exists production_operations_quality_queue_idx
  on public.production_order_operations(production_order_id,completed_at)
  where quality_status='awaiting_review';
create index if not exists production_operation_events_operation_idx
  on public.production_operation_events(operation_id,occurred_at desc);
create index if not exists production_operation_events_actor_idx
  on public.production_operation_events(actor_id)
  where actor_id is not null;

alter table public.production_operation_events enable row level security;
revoke all on public.production_operation_events from public,anon,authenticated;

create or replace function private.protect_production_operation_event()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  raise exception 'Production operation history is immutable';
end $$;

drop trigger if exists production_operation_event_immutable on public.production_operation_events;
create trigger production_operation_event_immutable
before update or delete on public.production_operation_events
for each row execute function private.protect_production_operation_event();

create or replace function private.production_action_allowed(requested_action text)
returns boolean
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  profile_role text;
  profile_permissions jsonb;
  explicit_value text;
begin
  if actor is null then return false; end if;
  select p.role,p.permissions into profile_role,profile_permissions
  from public.profiles p
  where p.id=actor and coalesce(p.status,'active')='active';
  if not found then return false; end if;
  if profile_role in ('owner','manager') then return true; end if;
  if profile_role<>'production' then return false; end if;
  explicit_value:=profile_permissions->>requested_action;
  if explicit_value is not null then return explicit_value::boolean; end if;
  return requested_action in ('production_view','production_operation_update');
end $$;

create or replace function private.can_operate_assigned_operation(target_operation uuid)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select case
    when (select auth.uid()) is null then false
    when public.current_identity_role() in ('owner','manager') then true
    when public.current_identity_role()<>'production' then false
    else exists(
      select 1
      from public.production_order_operations o
      join public.profiles p
        on p.id=(select auth.uid())
       and coalesce(p.status,'active')='active'
      where o.id=target_operation
        and o.assigned_employee_id=p.employee_id
    )
  end
$$;

create or replace function public.assign_production_operation(
  target_operation uuid,
  target_employee uuid
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  saved public.production_order_operations%rowtype;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if not exists(
    select 1 from public.employees e
    where e.id=target_employee and e.status='active'
  ) then
    raise exception 'Active employee required';
  end if;
  select o.* into saved
  from public.production_order_operations o
  where o.id=target_operation
  for update;
  if not found or saved.status in ('completed','skipped') or not exists(
    select 1 from public.production_orders po
    where po.id=saved.production_order_id
      and po.status in ('planned','released','in_progress')
  ) then
    raise exception 'Assignable production operation required';
  end if;
  update public.production_order_operations
  set assigned_employee_id=target_employee,
      assigned_by=actor,
      assigned_at=now()
  where id=target_operation
  returning * into saved;
  insert into public.production_operation_events(
    operation_id,event_type,event_data,actor_id
  ) values(
    saved.id,'assigned',jsonb_build_object('employee_id',target_employee),actor
  );
  return to_jsonb(saved);
end $$;

create or replace function public.record_production_operation_event(
  target_operation uuid,
  target_event text,
  event_reason text default null,
  good_quantity numeric default null,
  bad_quantity numeric default null,
  rework_qty numeric default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  current_row record;
  saved public.production_order_operations%rowtype;
  paused_minutes numeric:=0;
begin
  if actor is null or not private.can_operate_assigned_operation(target_operation) then
    raise exception using errcode='42501',message='Assigned production operation access required';
  end if;
  if target_event not in ('start','pause','resume','complete','submit_quality') then
    raise exception 'Invalid production event';
  end if;
  select o.*,po.qty order_quantity,po.status order_status
  into current_row
  from public.production_order_operations o
  join public.production_orders po on po.id=o.production_order_id
  where o.id=target_operation
  for update of o,po;
  if not found or current_row.order_status not in ('released','in_progress') then
    raise exception 'Released or in-progress production order required';
  end if;

  if target_event='start' then
    if current_row.status<>'ready' or current_row.paused_at is not null then
      raise exception 'Ready operation required';
    end if;
    update public.production_order_operations
    set status='in_progress',started_at=coalesce(started_at,now())
    where id=target_operation returning * into saved;
    update public.production_orders
    set status='in_progress',started_at=coalesce(started_at,now())
    where id=current_row.production_order_id and status='released';
  elsif target_event='pause' then
    if current_row.status<>'in_progress' or current_row.paused_at is not null then
      raise exception 'Running operation required';
    end if;
    if btrim(coalesce(event_reason,''))='' then
      raise exception 'Pause reason required';
    end if;
    update public.production_order_operations
    set paused_at=now()
    where id=target_operation returning * into saved;
  elsif target_event='resume' then
    if current_row.status<>'in_progress' or current_row.paused_at is null then
      raise exception 'Paused operation required';
    end if;
    paused_minutes:=greatest(
      extract(epoch from (now()-current_row.paused_at))/60,0
    );
    update public.production_order_operations
    set paused_at=null,
        total_paused_minutes=total_paused_minutes+paused_minutes
    where id=target_operation returning * into saved;
  elsif target_event='complete' then
    if current_row.status<>'in_progress' or current_row.paused_at is not null then
      raise exception 'Running operation required';
    end if;
    if coalesce(good_quantity,-1)<0 or coalesce(bad_quantity,-1)<0
       or coalesce(rework_qty,-1)<0 then
      raise exception 'Valid production quantities required';
    end if;
    if good_quantity+bad_quantity<>current_row.order_quantity then
      raise exception 'Accepted and rejected quantities must equal production order quantity';
    end if;
    if rework_qty>bad_quantity then
      raise exception 'Rework quantity cannot exceed rejected quantity';
    end if;
    if (bad_quantity>0 or rework_qty>0)
       and btrim(coalesce(event_reason,''))='' then
      raise exception 'Rejection or rework reason required';
    end if;
    update public.production_order_operations
    set status='completed',
        completed_at=now(),
        actual_minutes=greatest(
          extract(epoch from (now()-coalesce(started_at,now())))/60
          -total_paused_minutes,0
        ),
        accepted_quantity=good_quantity,
        rejected_quantity=bad_quantity,
        rework_quantity=rework_qty,
        quality_status='awaiting_review',
        note=coalesce(nullif(btrim(event_reason),''),note)
    where id=target_operation returning * into saved;
  else
    if current_row.status<>'completed'
       or current_row.quality_status not in ('pending','rejected') then
      raise exception 'Completed operation requiring quality submission required';
    end if;
    update public.production_order_operations
    set quality_status='awaiting_review'
    where id=target_operation returning * into saved;
  end if;

  insert into public.production_operation_events(
    operation_id,event_type,reason,event_data,actor_id
  ) values(
    target_operation,
    case target_event
      when 'start' then 'started'
      when 'pause' then 'paused'
      when 'resume' then 'resumed'
      when 'complete' then 'completed'
      else 'quality_submitted'
    end,
    nullif(btrim(coalesce(event_reason,'')),''),
    jsonb_build_object(
      'accepted_quantity',good_quantity,
      'rejected_quantity',bad_quantity,
      'rework_quantity',rework_qty
    ),
    actor
  );
  return to_jsonb(saved);
end $$;

create or replace function public.review_production_operation_quality(
  target_operation uuid,
  approve boolean,
  review_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  saved public.production_order_operations%rowtype;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if not coalesce(approve,false)
     and btrim(coalesce(review_reason,''))='' then
    raise exception 'Quality rejection reason required';
  end if;
  update public.production_order_operations
  set quality_status=case when approve then 'approved' else 'rejected' end,
      note=case
        when approve then note
        else concat_ws(E'\n',note,'Quality rejection: '||btrim(review_reason))
      end
  where id=target_operation
    and status='completed'
    and quality_status='awaiting_review'
  returning * into saved;
  if not found then
    raise exception 'Operation awaiting quality review required';
  end if;
  insert into public.production_operation_events(
    operation_id,event_type,reason,actor_id
  ) values(
    target_operation,
    case when approve then 'quality_approved' else 'quality_rejected' end,
    nullif(btrim(coalesce(review_reason,'')),''),
    actor
  );
  return to_jsonb(saved);
end $$;

create or replace function public.update_production_operation_status(
  target_operation uuid,
  target_status text,
  actual_minutes numeric default null,
  operation_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  current_row record;
  saved public.production_order_operations%rowtype;
begin
  if not private.can_operate_assigned_operation(target_operation) then
    raise exception using errcode='42501',message='Assigned production operation access required';
  end if;
  if target_status not in ('ready','in_progress','completed','skipped') then
    raise exception 'Invalid operation status';
  end if;
  if target_status='skipped' then
    if public.current_identity_role() not in ('owner','manager') then
      raise exception 'Owner or manager role required to skip an operation';
    end if;
    if btrim(coalesce(operation_note,''))='' then
      raise exception 'Skip reason required';
    end if;
  end if;
  if actual_minutes is not null and actual_minutes<0 then
    raise exception 'Actual minutes cannot be negative';
  end if;
  select o.*,po.status order_status into current_row
  from public.production_order_operations o
  join public.production_orders po on po.id=o.production_order_id
  where o.id=target_operation
  for update of o,po;
  if not found or current_row.order_status not in ('released','in_progress') then
    raise exception 'Released or in-progress production order required';
  end if;
  if current_row.status in ('completed','skipped') then
    if current_row.status=target_status then return to_jsonb(current_row); end if;
    raise exception 'Finalized operation is immutable';
  end if;
  if (current_row.status='pending' and target_status not in ('ready','skipped'))
     or (current_row.status='ready' and target_status not in ('in_progress','skipped'))
     or (current_row.status='in_progress' and target_status not in ('completed','skipped')) then
    raise exception 'Invalid operation status transition';
  end if;
  update public.production_order_operations
  set status=target_status,
      started_at=case
        when target_status='in_progress' then coalesce(started_at,now())
        else started_at
      end,
      completed_at=case
        when target_status in ('completed','skipped') then now()
        else completed_at
      end,
      actual_minutes=coalesce($3,public.production_order_operations.actual_minutes),
      note=coalesce($4,public.production_order_operations.note),
      quality_status=case
        when target_status='completed' then 'awaiting_review'
        else quality_status
      end
  where id=target_operation
  returning * into saved;
  if target_status='in_progress' then
    update public.production_orders
    set status='in_progress',started_at=coalesce(started_at,now())
    where id=saved.production_order_id and status='released';
  end if;
  if target_status in ('in_progress','completed') then
    insert into public.production_operation_events(
      operation_id,event_type,reason,event_data,actor_id
    ) values(
      saved.id,
      case when target_status='in_progress' then 'started' else 'completed' end,
      nullif(btrim(coalesce(operation_note,'')),''),
      jsonb_build_object('legacy_status_entry',true),
      (select auth.uid())
    );
  elsif target_status='skipped' then
    insert into public.audit_log(
      table_name,record_id,action,actor_id,old_data,new_data,metadata
    ) values(
      'production_order_operations',saved.id::text,'production_operation_skipped',
      (select auth.uid()),to_jsonb(current_row),to_jsonb(saved),
      jsonb_build_object('reason',btrim(operation_note))
    );
  end if;
  return to_jsonb(saved);
end $$;

create or replace function public.complete_production_order(target_order uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  saved public.production_orders%rowtype;
begin
  if not private.production_action_allowed('production_complete') then
    raise exception using errcode='42501',message='Production completion access required';
  end if;
  select * into saved
  from public.production_orders
  where id=target_order
  for update;
  if not found then raise exception 'Production order not found'; end if;
  if saved.status='completed' then return to_jsonb(saved); end if;
  if saved.status<>'in_progress' then
    raise exception 'In-progress production order required';
  end if;
  if exists(
    select 1 from public.production_material_requirements
    where production_order_id=target_order
      and issued_quantity<required_quantity
  ) then
    raise exception 'All required materials must be issued before completion';
  end if;
  if exists(
    select 1 from public.production_order_operations
    where production_order_id=target_order
      and status not in ('completed','skipped')
  ) then
    raise exception 'All operations must be completed or skipped';
  end if;
  if exists(
    select 1 from public.production_order_operations
    where production_order_id=target_order
      and status='completed'
      and quality_status<>'approved'
  ) then
    raise exception 'All completed operations require approved quality review';
  end if;
  update public.production_orders
  set status='completed',completed_at=now(),completed_by=actor
  where id=target_order returning * into saved;
  insert into public.audit_log(
    table_name,record_id,action,actor_id,new_data
  ) values(
    'production_orders',saved.id::text,'production_order_completed',
    actor,to_jsonb(saved)
  );
  return to_jsonb(saved);
end $$;

create or replace function public.cancel_production_order(
  target_order uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=(select auth.uid());
  saved public.production_orders%rowtype;
  old_row public.production_orders%rowtype;
  movement_id uuid;
begin
  if actor is null or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required';
  end if;
  if btrim(coalesce(reason,''))='' then
    raise exception 'Cancellation reason required';
  end if;
  select * into old_row
  from public.production_orders
  where id=target_order
  for update;
  if not found or old_row.status in ('completed','cancelled') then
    raise exception 'Cancellable production order required';
  end if;
  for movement_id in
    select distinct x.inventory_movement_id
    from (
      select i.inventory_movement_id
      from public.production_material_issues i
      join public.production_material_requirements r on r.id=i.requirement_id
      where r.production_order_id=target_order
      union all
      select r.inventory_movement_id
      from public.production_material_requirements r
      where r.production_order_id=target_order
        and r.inventory_movement_id is not null
    ) x
    where x.inventory_movement_id is not null
  loop
    if not exists(
      select 1 from public.inventory_movements
      where reversed_movement_id=movement_id
    ) then
      perform public.reverse_inventory_movement(movement_id,reason);
    end if;
  end loop;
  update public.production_orders
  set status='cancelled',
      cancelled_at=now(),
      cancelled_by=actor,
      cancellation_reason=btrim(reason)
  where id=target_order
  returning * into saved;
  insert into public.audit_log(
    table_name,record_id,action,actor_id,old_data,new_data,metadata
  ) values(
    'production_orders',saved.id::text,'production_order_cancelled',
    actor,to_jsonb(old_row),to_jsonb(saved),
    jsonb_build_object('reason',btrim(reason))
  );
  return to_jsonb(saved);
end $$;

create or replace function public.get_production_workspace()
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  role_name text:=public.current_identity_role();
  actor_employee uuid;
  can_finance boolean:=role_name in ('owner','manager','accountant');
begin
  if not private.production_action_allowed('production_view') then
    raise exception using errcode='42501',message='Production access required';
  end if;
  select p.employee_id into actor_employee
  from public.profiles p
  where p.id=(select auth.uid()) and coalesce(p.status,'active')='active';
  return jsonb_build_object(
    'orders',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at desc)
      from (
        select o.*,p.name product_name,p.sku product_sku,pr.project_name,
          case when can_finance then coalesce((
            select sum(abs(m.quantity_delta)*m.unit_cost)
            from public.production_material_issues i
            join public.production_material_requirements r on r.id=i.requirement_id
            join public.inventory_movements m on m.id=i.inventory_movement_id
            where r.production_order_id=o.id
              and not exists(
                select 1 from public.inventory_movements rev
                where rev.reversed_movement_id=m.id
              )
          ),0) else null end actual_material_cost
        from public.production_orders o
        left join public.products p on p.id=o.product_id
        left join public.projects pr on pr.id=o.project_id
        where role_name<>'production' or exists(
          select 1 from public.production_order_operations visible_op
          where visible_op.production_order_id=o.id
            and visible_op.assigned_employee_id=actor_employee
        )
      ) x
    ),'[]'::jsonb),
    'operations',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.production_order_id,x.sequence_no)
      from (
        select o.*,e.full_name assigned_employee_name
        from public.production_order_operations o
        left join public.employees e on e.id=o.assigned_employee_id
        where role_name<>'production' or o.assigned_employee_id=actor_employee
      ) x
    ),'[]'::jsonb),
    'requirements',coalesce((
      select jsonb_agg(to_jsonb(x) order by x.production_order_id,x.created_at)
      from (
        select r.*,i.name inventory_item_name,i.unit inventory_item_unit,
          w.name warehouse_name
        from public.production_material_requirements r
        join public.inventory_items i on i.id=r.inventory_item_id
        join public.inventory_warehouses w on w.id=r.warehouse_id
        where role_name<>'production' or exists(
          select 1 from public.production_order_operations visible_op
          where visible_op.production_order_id=r.production_order_id
            and visible_op.assigned_employee_id=actor_employee
        )
      ) x
    ),'[]'::jsonb),
    'events',coalesce((
      select jsonb_agg(to_jsonb(ev) order by ev.occurred_at)
      from public.production_operation_events ev
      join public.production_order_operations op on op.id=ev.operation_id
      where role_name<>'production' or op.assigned_employee_id=actor_employee
    ),'[]'::jsonb),
    'employees',case when role_name in ('owner','manager') then coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',e.id,'full_name',e.full_name,'job_title',e.job_title
      ) order by e.full_name)
      from public.employees e
      where e.status='active'
    ),'[]'::jsonb) else '[]'::jsonb end,
    'capabilities',jsonb_build_object(
      'create',private.production_action_allowed('production_create'),
      'plan',private.production_action_allowed('production_plan'),
      'release',private.production_action_allowed('production_release'),
      'issue',private.production_action_allowed('production_material_issue'),
      'operate',private.production_action_allowed('production_operation_update'),
      'complete',private.production_action_allowed('production_complete'),
      'assign',role_name in ('owner','manager'),
      'quality',role_name in ('owner','manager'),
      'cancel',role_name='owner',
      'view_financials',can_finance
    )
  );
end $$;

revoke all on function private.protect_production_operation_event() from public,anon,authenticated;
revoke all on function private.production_action_allowed(text) from public,anon,authenticated;
revoke all on function private.can_operate_assigned_operation(uuid) from public,anon,authenticated;
revoke all on function public.assign_production_operation(uuid,uuid) from public,anon,authenticated;
revoke all on function public.record_production_operation_event(uuid,text,text,numeric,numeric,numeric) from public,anon,authenticated;
revoke all on function public.review_production_operation_quality(uuid,boolean,text) from public,anon,authenticated;
revoke all on function public.update_production_operation_status(uuid,text,numeric,text) from public,anon,authenticated;
revoke all on function public.complete_production_order(uuid) from public,anon,authenticated;
revoke all on function public.cancel_production_order(uuid,text) from public,anon,authenticated;
revoke all on function public.get_production_workspace() from public,anon,authenticated;

grant execute on function public.assign_production_operation(uuid,uuid) to authenticated;
grant execute on function public.record_production_operation_event(uuid,text,text,numeric,numeric,numeric) to authenticated;
grant execute on function public.review_production_operation_quality(uuid,boolean,text) to authenticated;
grant execute on function public.update_production_operation_status(uuid,text,numeric,text) to authenticated;
grant execute on function public.complete_production_order(uuid) to authenticated;
grant execute on function public.cancel_production_order(uuid,text) to authenticated;
grant execute on function public.get_production_workspace() to authenticated;

commit;
