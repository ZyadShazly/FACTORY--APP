-- Allow production for stock when no project is linked, while preserving project cost posting when a project exists.
begin;

alter table public.inventory_movements
  drop constraint if exists inventory_movements_movement_type_check,
  drop constraint if exists inventory_movements_direction_check,
  drop constraint if exists inventory_movements_check2;

alter table public.inventory_movements
  add constraint inventory_movements_movement_type_check check (
    movement_type in (
      'receipt','project_issue','production_issue','receipt_reversal',
      'project_issue_reversal','production_issue_reversal','adjustment_in',
      'adjustment_out','transfer_in','transfer_out','production_return',
      'waste_out','damage_out','opening_balance'
    )
  ),
  add constraint inventory_movements_direction_check check (
    (
      movement_type in (
        'receipt','project_issue_reversal','production_issue_reversal',
        'adjustment_in','transfer_in','production_return','opening_balance'
      ) and quantity_delta>0
    ) or (
      movement_type in (
        'project_issue','production_issue','receipt_reversal','adjustment_out',
        'transfer_out','waste_out','damage_out'
      ) and quantity_delta<0
    )
  ),
  add constraint inventory_movements_check2 check (
    (
      movement_type in (
        'receipt_reversal','project_issue_reversal','production_issue_reversal'
      ) and reversed_movement_id is not null
    ) or (
      movement_type not in (
        'receipt_reversal','project_issue_reversal','production_issue_reversal'
      ) and reversed_movement_id is null
    )
  );

create or replace function public.release_production_order(target_order uuid)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare actor uuid:=auth.uid(); saved public.production_orders%rowtype;
begin
  if not private.production_action_allowed('production_release') then
    raise exception using errcode='42501',message='Production release access required';
  end if;
  if not exists(
    select 1 from public.production_material_requirements
    where production_order_id=target_order
  ) then raise exception 'At least one material requirement is required'; end if;
  update public.production_orders
  set status='released',released_at=coalesce(released_at,now()),released_by=coalesce(released_by,actor)
  where id=target_order and status='planned'
  returning * into saved;
  if not found then raise exception 'Planned production order required'; end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'production_orders',saved.id::text,'production_order_released',actor,
    to_jsonb(saved),jsonb_build_object(
      'production_mode',case when saved.project_id is null then 'stock' else 'project' end
    )
  );
  return to_jsonb(saved);
end $$;

create or replace function public.issue_production_material(
  target_requirement uuid,
  issue_quantity numeric,
  issue_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  req record;
  remaining numeric;
  movement jsonb;
  movement_row public.inventory_movements%rowtype;
  movement_id uuid;
  saved public.production_material_requirements%rowtype;
  issue_row public.production_material_issues%rowtype;
  balance record;
  avg_cost numeric;
begin
  if not private.production_action_allowed('production_material_issue') then
    raise exception using errcode='42501',message='Production material issue access required';
  end if;

  select r.*,o.project_id,o.status order_status
  into req
  from public.production_material_requirements r
  join public.production_orders o on o.id=r.production_order_id
  where r.id=target_requirement
  for update of r,o;

  if not found or req.order_status not in ('released','in_progress') then
    raise exception 'Released or in-progress production order required';
  end if;
  if issue_quantity is null or issue_quantity<=0 then
    raise exception 'Issue quantity must be greater than zero';
  end if;

  remaining:=req.required_quantity-req.issued_quantity;
  if remaining<=0 then raise exception 'Material requirement is already fully issued'; end if;
  if issue_quantity>remaining then raise exception 'Issue quantity exceeds remaining requirement'; end if;

  if req.project_id is not null then
    movement:=public.issue_inventory_to_project(
      req.inventory_item_id,
      req.warehouse_id,
      req.project_id,
      issue_quantity,
      coalesce(nullif(btrim(issue_description),''),'Production material issue'),
      req.budget_item_id,
      req.milestone_id
    );
    movement_id:=(movement->>'id')::uuid;
  else
    select quantity_on_hand,inventory_value
    into balance
    from public.inventory_balances
    where inventory_item_id=req.inventory_item_id
      and warehouse_id=req.warehouse_id
    for update;
    if not found or balance.quantity_on_hand<issue_quantity then
      raise exception 'Insufficient inventory balance';
    end if;
    avg_cost:=case when balance.quantity_on_hand=0 then 0
      else round(balance.inventory_value/balance.quantity_on_hand,4) end;
    insert into public.inventory_movements(
      movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,
      reason,posted_by,metadata
    ) values(
      'production_issue',req.inventory_item_id,req.warehouse_id,-issue_quantity,
      avg_cost,coalesce(nullif(btrim(issue_description),''),'Stock production material issue'),
      actor,jsonb_build_object(
        'source','production_order',
        'production_mode','stock',
        'production_order_id',req.production_order_id,
        'requirement_id',req.id
      )
    ) returning * into movement_row;
    movement_id:=movement_row.id;
    movement:=to_jsonb(movement_row);
  end if;

  insert into public.production_material_issues(
    requirement_id,inventory_movement_id,quantity,description,issued_by
  ) values(
    req.id,movement_id,issue_quantity,nullif(btrim(issue_description),''),actor
  ) returning * into issue_row;

  update public.production_material_requirements
  set issued_quantity=issued_quantity+issue_quantity,
      consumed_quantity=consumed_quantity+issue_quantity,
      inventory_movement_id=coalesce(inventory_movement_id,movement_id)
  where id=req.id
  returning * into saved;

  update public.production_orders
  set status='in_progress',started_at=coalesce(started_at,now())
  where id=req.production_order_id and status='released';

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'production_material_issues',issue_row.id::text,'production_material_partial_issue',actor,
    to_jsonb(issue_row),
    jsonb_build_object(
      'requirement_id',req.id,
      'production_order_id',req.production_order_id,
      'production_mode',case when req.project_id is null then 'stock' else 'project' end,
      'required_quantity',req.required_quantity,
      'issued_quantity_after',saved.issued_quantity,
      'remaining_quantity',saved.required_quantity-saved.issued_quantity
    )
  );

  return jsonb_build_object(
    'requirement',to_jsonb(saved),
    'issue',to_jsonb(issue_row),
    'inventory_movement',movement,
    'remaining_quantity',saved.required_quantity-saved.issued_quantity
  );
end $$;

create or replace function public.reverse_inventory_movement(target_movement uuid,reason text)
returns jsonb
language plpgsql
security definer
set search_path='public','private','pg_temp'
as $$
declare
  actor uuid:=auth.uid();
  original public.inventory_movements%rowtype;
  saved public.inventory_movements%rowtype;
  reversal_type text;
begin
  if actor is null or public.current_identity_role()<>'owner' then
    raise exception 'Owner role required';
  end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Reversal reason required'; end if;
  select * into original from public.inventory_movements where id=target_movement for update;
  if not found or original.movement_type not in ('receipt','project_issue','production_issue') then
    raise exception 'Reversible posted movement required';
  end if;
  if exists(select 1 from public.inventory_movements where reversed_movement_id=original.id) then
    raise exception 'Movement already reversed';
  end if;
  if original.actual_cost_entry_id is not null then
    perform public.reverse_project_actual_cost(original.actual_cost_entry_id,reason);
  end if;
  reversal_type:=case original.movement_type
    when 'receipt' then 'receipt_reversal'
    when 'project_issue' then 'project_issue_reversal'
    else 'production_issue_reversal'
  end;
  insert into public.inventory_movements(
    movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,
    unit_cost,project_id,reversed_movement_id,reason,posted_by,metadata
  ) values(
    reversal_type,original.inventory_item_id,original.warehouse_id,original.location_id,
    -original.quantity_delta,original.unit_cost,original.project_id,original.id,reason,
    actor,jsonb_build_object('reversal_of',original.id,'source_movement_type',original.movement_type)
  ) returning * into saved;
  return to_jsonb(saved);
end $$;

commit;
