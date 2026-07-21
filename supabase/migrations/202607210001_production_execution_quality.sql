-- Protected production-floor execution, assignment, pause history, and quality review.
-- Additive only: no historical rewrite and no inventory or Actual Cost posting.
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

do $$ begin
  alter table public.production_order_operations add constraint production_operation_quantities_check
    check (accepted_quantity >= 0 and rejected_quantity >= 0 and rework_quantity >= 0 and total_paused_minutes >= 0);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.production_order_operations add constraint production_operation_quality_status_check
    check (quality_status in ('pending','awaiting_review','approved','rejected'));
exception when duplicate_object then null; end $$;

create table if not exists public.production_operation_events (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null references public.production_order_operations(id) on delete restrict,
  event_type text not null check (event_type in ('assigned','started','paused','resumed','completed','quality_submitted','quality_approved','quality_rejected')),
  reason text,
  event_data jsonb not null default '{}'::jsonb,
  actor_id uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  occurred_at timestamptz not null default now()
);

create index if not exists production_operation_events_operation_idx
  on public.production_operation_events(operation_id,occurred_at desc);

create or replace function private.can_operate_assigned_operation(target_operation uuid)
returns boolean language sql stable security definer set search_path=public,private,pg_temp as $$
  select case
    when auth.uid() is null then false
    when public.current_identity_role() in ('owner','manager') then true
    when public.current_identity_role() <> 'production' then false
    else exists(
      select 1
      from public.production_order_operations o
      join public.profiles p on p.id=auth.uid() and p.status='active'
      where o.id=target_operation and o.assigned_employee_id=p.employee_id
    )
  end;
$$;

create or replace function public.assign_production_operation(target_operation uuid,target_employee uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.production_order_operations%rowtype;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if not exists(select 1 from public.employees where id=target_employee and status not in ('inactive','suspended')) then raise exception 'Active employee required'; end if;
  update public.production_order_operations o
     set assigned_employee_id=target_employee,assigned_by=actor,assigned_at=now()
   where o.id=target_operation
     and o.status not in ('completed','skipped')
     and exists(select 1 from public.production_orders po where po.id=o.production_order_id and po.status in ('planned','released','in_progress'))
   returning * into saved;
  if not found then raise exception 'Assignable production operation required'; end if;
  insert into public.production_operation_events(operation_id,event_type,event_data,actor_id)
  values(saved.id,'assigned',jsonb_build_object('employee_id',target_employee),actor);
  return to_jsonb(saved);
end $$;

create or replace function public.record_production_operation_event(
  target_operation uuid,target_event text,event_reason text default null,
  good_quantity numeric default null,bad_quantity numeric default null,rework_qty numeric default null
)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); current_row record; saved public.production_order_operations%rowtype; paused_minutes numeric:=0;
begin
  if actor is null or not private.can_operate_assigned_operation(target_operation) then raise exception 'Assigned production operation access required'; end if;
  if target_event not in ('start','pause','resume','complete','submit_quality') then raise exception 'Invalid production event'; end if;
  select o.*,po.qty order_quantity,po.status order_status into current_row
  from public.production_order_operations o join public.production_orders po on po.id=o.production_order_id
  where o.id=target_operation for update of o,po;
  if not found or current_row.order_status not in ('released','in_progress') then raise exception 'Released or in-progress production order required'; end if;

  if target_event='start' then
    if current_row.status not in ('ready','in_progress') or current_row.paused_at is not null then raise exception 'Ready operation required'; end if;
    update public.production_order_operations set status='in_progress',started_at=coalesce(started_at,now()) where id=target_operation returning * into saved;
    update public.production_orders set status='in_progress',started_at=coalesce(started_at,now()) where id=current_row.production_order_id and status='released';
  elsif target_event='pause' then
    if current_row.status<>'in_progress' or current_row.paused_at is not null then raise exception 'Running operation required'; end if;
    if btrim(coalesce(event_reason,''))='' then raise exception 'Pause reason required'; end if;
    update public.production_order_operations set paused_at=now() where id=target_operation returning * into saved;
  elsif target_event='resume' then
    if current_row.status<>'in_progress' or current_row.paused_at is null then raise exception 'Paused operation required'; end if;
    paused_minutes:=greatest(extract(epoch from (now()-current_row.paused_at))/60,0);
    update public.production_order_operations set paused_at=null,total_paused_minutes=total_paused_minutes+paused_minutes where id=target_operation returning * into saved;
  elsif target_event='complete' then
    if current_row.status<>'in_progress' or current_row.paused_at is not null then raise exception 'Running operation required'; end if;
    if coalesce(good_quantity,0)<0 or coalesce(bad_quantity,0)<0 or coalesce(rework_qty,0)<0 then raise exception 'Quantities cannot be negative'; end if;
    if coalesce(good_quantity,0)+coalesce(bad_quantity,0)>current_row.order_quantity then raise exception 'Reported quantity exceeds production order quantity'; end if;
    update public.production_order_operations
       set status='completed',completed_at=now(),
           actual_minutes=greatest(extract(epoch from (now()-coalesce(started_at,now())))/60-total_paused_minutes,0),
           accepted_quantity=coalesce(good_quantity,0),rejected_quantity=coalesce(bad_quantity,0),rework_quantity=coalesce(rework_qty,0),
           quality_status='awaiting_review',note=coalesce(event_reason,note)
     where id=target_operation returning * into saved;
  else
    if current_row.status<>'completed' or current_row.quality_status not in ('pending','awaiting_review','rejected') then raise exception 'Completed operation awaiting quality review required'; end if;
    update public.production_order_operations set quality_status='awaiting_review' where id=target_operation returning * into saved;
  end if;

  insert into public.production_operation_events(operation_id,event_type,reason,event_data,actor_id)
  values(target_operation,case target_event when 'start' then 'started' when 'pause' then 'paused' when 'resume' then 'resumed' when 'complete' then 'completed' else 'quality_submitted' end,
    nullif(btrim(coalesce(event_reason,'')),''),jsonb_build_object('accepted_quantity',good_quantity,'rejected_quantity',bad_quantity,'rework_quantity',rework_qty),actor);
  return to_jsonb(saved);
end $$;

create or replace function public.review_production_operation_quality(target_operation uuid,approve boolean,review_reason text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.production_order_operations%rowtype;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if not coalesce(approve,false) and btrim(coalesce(review_reason,''))='' then raise exception 'Rejection reason required'; end if;
  update public.production_order_operations
     set quality_status=case when approve then 'approved' else 'rejected' end,
         note=case when approve then note else concat_ws(E'\n',note,'Quality rejection: '||btrim(review_reason)) end
   where id=target_operation and status='completed' and quality_status='awaiting_review'
   returning * into saved;
  if not found then raise exception 'Operation awaiting quality review required'; end if;
  insert into public.production_operation_events(operation_id,event_type,reason,actor_id)
  values(target_operation,case when approve then 'quality_approved' else 'quality_rejected' end,nullif(btrim(coalesce(review_reason,'')),''),actor);
  return to_jsonb(saved);
end $$;

alter table public.production_operation_events enable row level security;
revoke all on public.production_operation_events from anon,authenticated;
revoke all on function private.can_operate_assigned_operation(uuid) from public,anon,authenticated;
revoke all on function public.assign_production_operation(uuid,uuid) from public,anon;
revoke all on function public.record_production_operation_event(uuid,text,text,numeric,numeric,numeric) from public,anon;
revoke all on function public.review_production_operation_quality(uuid,boolean,text) from public,anon;
grant execute on function public.assign_production_operation(uuid,uuid) to authenticated;
grant execute on function public.record_production_operation_event(uuid,text,text,numeric,numeric,numeric) to authenticated;
grant execute on function public.review_production_operation_quality(uuid,boolean,text) to authenticated;

commit;