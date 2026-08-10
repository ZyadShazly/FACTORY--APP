-- Post only quality-accepted finished output and capitalize the full order cost across that output.
begin;

create or replace function private.align_production_receipt_with_quality()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  order_row public.production_orders%rowtype;
  accepted_output numeric;
  actual_material_cost numeric:=0;
  total_output_cost numeric:=0;
begin
  if new.movement_type<>'production_receipt' then return new; end if;
  if new.production_order_id is null then raise exception using errcode='23514',message='Production receipt requires an order'; end if;

  select * into order_row from public.production_orders where id=new.production_order_id for update;
  if not found then raise exception using errcode='23503',message='Production order not found'; end if;

  select operation.accepted_quantity into accepted_output
  from public.production_order_operations operation
  where operation.production_order_id=new.production_order_id
    and operation.status='completed' and operation.quality_status='approved'
  order by operation.sequence_no desc
  limit 1;

  if accepted_output is null or accepted_output<=0 or accepted_output>order_row.qty then
    raise exception using errcode='23514',message='A positive quality-approved final output is required';
  end if;

  select coalesce(sum(abs(movement.quantity_delta)*movement.unit_cost),0)
  into actual_material_cost
  from public.production_material_issues issue
  join public.production_material_requirements requirement on requirement.id=issue.requirement_id
  join public.inventory_movements movement on movement.id=issue.inventory_movement_id
  where requirement.production_order_id=new.production_order_id
    and not exists(select 1 from public.inventory_movements reversal where reversal.reversed_movement_id=movement.id);

  total_output_cost:=actual_material_cost+coalesce(order_row.labor_cost,0)+coalesce(order_row.overhead_cost,0);
  new.quantity_delta:=accepted_output;
  new.unit_cost:=round(total_output_cost/accepted_output,4);
  new.metadata:=coalesce(new.metadata,'{}'::jsonb)||jsonb_build_object(
    'planned_quantity',order_row.qty,
    'quality_accepted_quantity',accepted_output,
    'quality_rejected_quantity',order_row.qty-accepted_output,
    'capitalized_total_cost',total_output_cost,
    'cost_basis','actual_material_plus_order_labor_overhead'
  );
  return new;
end
$$;

drop trigger if exists production_receipt_quality_alignment on public.inventory_movements;
create trigger production_receipt_quality_alignment
before insert on public.inventory_movements
for each row when (new.movement_type='production_receipt')
execute function private.align_production_receipt_with_quality();

revoke all on function private.align_production_receipt_with_quality() from public,anon,authenticated;

commit;
