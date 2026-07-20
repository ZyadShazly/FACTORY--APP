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
  current_row record;
  saved public.production_order_operations%rowtype;
begin
  if not private.production_action_allowed('production_operation_update') then
    raise exception using errcode='42501',message='Production operation access required';
  end if;
  if target_status not in ('ready','in_progress','completed','skipped') then raise exception 'Invalid operation status'; end if;
  if target_status='skipped' and public.current_identity_role() not in ('owner','manager') then raise exception 'Owner or manager role required to skip an operation'; end if;
  if $3 is not null and $3<0 then raise exception 'Actual minutes cannot be negative'; end if;
  select o.*,po.status order_status into current_row
  from public.production_order_operations o
  join public.production_orders po on po.id=o.production_order_id
  where o.id=target_operation for update of o,po;
  if not found or current_row.order_status not in ('released','in_progress') then raise exception 'Released or in-progress production order required'; end if;
  if current_row.status in ('completed','skipped') then
    if current_row.status=target_status then return to_jsonb(current_row); end if;
    raise exception 'Finalized operation is immutable';
  end if;
  if (current_row.status='pending' and target_status not in ('ready','skipped'))
     or (current_row.status='ready' and target_status not in ('in_progress','skipped'))
     or (current_row.status='in_progress' and target_status not in ('completed','skipped')) then
    raise exception 'Invalid operation status transition';
  end if;
  update public.production_order_operations o
  set status=target_status,
      started_at=case when target_status='in_progress' then coalesce(o.started_at,now()) else o.started_at end,
      completed_at=case when target_status in ('completed','skipped') then now() else o.completed_at end,
      actual_minutes=coalesce($3,o.actual_minutes),
      note=coalesce($4,o.note)
  where o.id=target_operation
  returning o.* into saved;
  if target_status='in_progress' then
    update public.production_orders set status='in_progress',started_at=coalesce(started_at,now())
    where id=saved.production_order_id and status='released';
  end if;
  return to_jsonb(saved);
end $$;

revoke all on function public.update_production_operation_status(uuid,text,numeric,text) from public,anon;
grant execute on function public.update_production_operation_status(uuid,text,numeric,text) to authenticated;

commit;