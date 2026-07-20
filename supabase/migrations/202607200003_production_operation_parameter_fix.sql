-- Fix ambiguous PL/pgSQL parameter references without changing the public RPC signature.
begin;

create or replace function public.update_production_operation_status(
  target_operation uuid,
  target_status text,
  actual_minutes numeric default null,
  operation_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  actor uuid:=auth.uid();
  role_name text:=public.current_identity_role();
  current_row record;
  saved public.production_order_operations%rowtype;
  v_actual_minutes numeric:=$3;
  v_operation_note text:=$4;
begin
  if actor is null or role_name not in ('owner','manager','production') then
    raise exception 'Production operation access required';
  end if;
  if target_status not in ('ready','in_progress','completed','skipped') then
    raise exception 'Invalid operation status';
  end if;
  if target_status='skipped' and role_name not in ('owner','manager') then
    raise exception 'Owner or manager role required to skip an operation';
  end if;
  if v_actual_minutes is not null and v_actual_minutes<0 then
    raise exception 'Actual minutes cannot be negative';
  end if;

  select o.*,po.status as order_status
  into current_row
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

  update public.production_order_operations p
  set status=target_status,
      started_at=case when target_status='in_progress' then coalesce(p.started_at,now()) else p.started_at end,
      completed_at=case when target_status in ('completed','skipped') then now() else p.completed_at end,
      actual_minutes=coalesce(v_actual_minutes,p.actual_minutes),
      note=coalesce(v_operation_note,p.note)
  where p.id=target_operation
  returning p.* into saved;

  if target_status='in_progress' then
    update public.production_orders
    set status='in_progress',started_at=coalesce(started_at,now())
    where id=saved.production_order_id and status='released';
  end if;

  return to_jsonb(saved);
end $$;

revoke all on function public.update_production_operation_status(uuid,text,numeric,text) from public,anon;
grant execute on function public.update_production_operation_status(uuid,text,numeric,text) to authenticated;

commit;
