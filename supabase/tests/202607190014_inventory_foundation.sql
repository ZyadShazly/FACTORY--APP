-- Rollback-safe inventory ledger regression.
begin;

DO $$
DECLARE
  v_user uuid;
  v_project uuid;
  v_wh uuid;
  v_item uuid;
  v_receipt uuid;
  v_issue uuid;
BEGIN
  select id into v_user from public.profiles limit 1;
  select id into v_project from public.projects limit 1;
  if v_user is null or v_project is null then
    raise exception 'Inventory smoke test requires one profile and project';
  end if;

  insert into public.inventory_warehouses(code,name,created_by)
  values('SMOKE-'||substr(gen_random_uuid()::text,1,8),'Rollback warehouse',v_user)
  returning id into v_wh;

  insert into public.inventory_items(sku,name,unit)
  values('SMOKE-'||substr(gen_random_uuid()::text,1,8),'Rollback material','وحدة')
  returning id into v_item;

  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,posted_by)
  values('receipt',v_item,v_wh,10,25,v_user)
  returning id into v_receipt;

  if (select quantity_on_hand from public.inventory_balances where inventory_item_id=v_item and warehouse_id=v_wh) <> 10 then
    raise exception 'Receipt did not update inventory balance';
  end if;
  if (select inventory_value from public.inventory_balances where inventory_item_id=v_item and warehouse_id=v_wh) <> 250 then
    raise exception 'Receipt did not update inventory value';
  end if;

  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,project_id,reason,posted_by)
  values('project_issue',v_item,v_wh,-4,25,v_project,'Rollback issue',v_user)
  returning id into v_issue;

  if (select quantity_on_hand from public.inventory_balances where inventory_item_id=v_item and warehouse_id=v_wh) <> 6 then
    raise exception 'Issue did not update inventory balance';
  end if;

  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,project_id,reversed_movement_id,reason,posted_by)
  values('project_issue_reversal',v_item,v_wh,4,25,v_project,v_issue,'Rollback reversal',v_user);

  if (select quantity_on_hand from public.inventory_balances where inventory_item_id=v_item and warehouse_id=v_wh) <> 10 then
    raise exception 'Reversal did not restore inventory balance';
  end if;

  begin
    update public.inventory_movements set reason='illegal mutation' where id=v_receipt;
    raise exception 'Immutable movement update unexpectedly succeeded';
  exception when others then
    if sqlerrm='Immutable movement update unexpectedly succeeded' then raise; end if;
  end;

  begin
    insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,quantity_delta,unit_cost,project_id,posted_by)
    values('project_issue',v_item,v_wh,-11,25,v_project,v_user);
    raise exception 'Negative-stock issue unexpectedly succeeded';
  exception when others then
    if sqlerrm='Negative-stock issue unexpectedly succeeded' then raise; end if;
  end;
END $$;

rollback;
