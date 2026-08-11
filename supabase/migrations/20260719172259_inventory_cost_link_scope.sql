-- Scope the one allowed posted-row mutation to the protected issue RPC transaction.
begin;

create or replace function private.allow_inventory_cost_link()
returns trigger language plpgsql set search_path=public,private,pg_temp as $$
begin
  if tg_op='UPDATE'
     and current_setting('app.inventory_cost_link',true)='on'
     and old.actual_cost_entry_id is null
     and new.actual_cost_entry_id is not null then
    return new;
  end if;
  raise exception 'Posted inventory movements are immutable; use reversal workflow';
end $$;

create or replace function public.issue_inventory_to_project(target_inventory_item uuid,target_warehouse uuid,target_project uuid,issue_quantity numeric,description text,budget_item uuid default null,milestone uuid default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); balance record; movement public.inventory_movements%rowtype; entry jsonb; avg_cost numeric;
begin
  if actor is null or role_name not in ('owner','manager') then raise exception 'Owner or manager role required'; end if;
  if issue_quantity is null or issue_quantity<=0 then raise exception 'Positive issue quantity required'; end if;
  if not exists(select 1 from public.projects where id=target_project) then raise exception 'Project not found'; end if;
  select quantity_on_hand,inventory_value into balance from public.inventory_balances where inventory_item_id=target_inventory_item and warehouse_id=target_warehouse for update;
  if not found or balance.quantity_on_hand<issue_quantity then raise exception 'Insufficient inventory balance'; end if;
  avg_cost:=case when balance.quantity_on_hand=0 then 0 else round(balance.inventory_value/balance.quantity_on_hand,4) end;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,project_id,reason,posted_by)
  values('project_issue',target_inventory_item,target_warehouse,-issue_quantity,avg_cost,target_project,description,actor)
  returning * into movement;
  entry:=public.save_project_actual_cost(jsonb_build_object(
    'project_id',target_project,'cost_category','material','source_type','warehouse_issue_line',
    'source_id',movement.id,'source_line_reference','main','source_revision',1,
    'source_reference_key','warehouse_issue_line:'||movement.id::text||':main:1',
    'description',description,'quantity',issue_quantity,
    'unit',(select unit from public.inventory_items where id=target_inventory_item),
    'unit_cost',avg_cost,'cost_date',current_date,'budget_item_id',budget_item,'milestone_id',milestone,
    'metadata',jsonb_build_object('inventory_movement_id',movement.id)));
  perform public.submit_project_actual_cost((entry->>'id')::uuid);
  perform public.approve_project_actual_cost((entry->>'id')::uuid);
  perform set_config('app.inventory_cost_link','on',true);
  update public.inventory_movements set actual_cost_entry_id=(entry->>'id')::uuid where id=movement.id;
  perform set_config('app.inventory_cost_link','off',true);
  return jsonb_set(to_jsonb(movement),'{actual_cost_entry_id}',to_jsonb((entry->>'id')::uuid));
end $$;

commit;
