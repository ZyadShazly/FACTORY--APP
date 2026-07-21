begin;

alter table public.inventory_warehouses
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid references public.profiles(id) on delete restrict,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete restrict,
  add column if not exists archive_reason text;

alter table public.inventory_locations
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid references public.profiles(id) on delete restrict,
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete restrict,
  add column if not exists archive_reason text;

create unique index if not exists inventory_warehouses_code_active_unique
  on public.inventory_warehouses(lower(btrim(code))) where active;
create unique index if not exists inventory_locations_code_per_warehouse_active_unique
  on public.inventory_locations(warehouse_id,lower(btrim(code))) where active;

create or replace function public.save_inventory_warehouse(
  target_id uuid,
  warehouse_code text,
  warehouse_name text
) returns jsonb
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.inventory_warehouses%rowtype;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if btrim(coalesce(warehouse_code,''))='' then raise exception 'Warehouse code required'; end if;
  if btrim(coalesce(warehouse_name,''))='' then raise exception 'Warehouse name required'; end if;
  if target_id is null then
    insert into public.inventory_warehouses(code,name,created_by,updated_by)
    values(upper(btrim(warehouse_code)),btrim(warehouse_name),actor,actor)
    returning * into saved;
  else
    update public.inventory_warehouses
      set code=upper(btrim(warehouse_code)),name=btrim(warehouse_name),updated_at=now(),updated_by=actor
      where id=target_id and active
      returning * into saved;
    if not found then raise exception 'Active warehouse not found'; end if;
  end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('inventory_warehouses',saved.id::text,case when target_id is null then 'warehouse_created' else 'warehouse_updated' end,actor,to_jsonb(saved),jsonb_build_object('source','warehouse_management'));
  return to_jsonb(saved);
end $$;

create or replace function public.save_inventory_location(
  target_id uuid,
  target_warehouse uuid,
  location_code text,
  location_name text
) returns jsonb
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.inventory_locations%rowtype;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if not exists(select 1 from public.inventory_warehouses where id=target_warehouse and active) then raise exception 'Active warehouse required'; end if;
  if btrim(coalesce(location_code,''))='' then raise exception 'Location code required'; end if;
  if btrim(coalesce(location_name,''))='' then raise exception 'Location name required'; end if;
  if target_id is null then
    insert into public.inventory_locations(warehouse_id,code,name,updated_by)
    values(target_warehouse,upper(btrim(location_code)),btrim(location_name),actor)
    returning * into saved;
  else
    update public.inventory_locations
      set code=upper(btrim(location_code)),name=btrim(location_name),updated_at=now(),updated_by=actor
      where id=target_id and warehouse_id=target_warehouse and active
      returning * into saved;
    if not found then raise exception 'Active storage location not found'; end if;
  end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('inventory_locations',saved.id::text,case when target_id is null then 'location_created' else 'location_updated' end,actor,to_jsonb(saved),jsonb_build_object('warehouse_id',target_warehouse,'source','warehouse_management'));
  return to_jsonb(saved);
end $$;

create or replace function public.get_inventory_warehouse_detail(target_warehouse uuid)
returns jsonb
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare role_name text:=public.current_identity_role(); warehouse_row public.inventory_warehouses%rowtype;
begin
  if auth.uid() is null or role_name not in ('owner','manager','accountant','production') then raise exception using errcode='42501',message='Inventory access required'; end if;
  select * into warehouse_row from public.inventory_warehouses where id=target_warehouse;
  if not found then raise exception 'Warehouse not found'; end if;
  return jsonb_build_object(
    'warehouse',to_jsonb(warehouse_row),
    'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.active desc,l.name) from public.inventory_locations l where l.warehouse_id=target_warehouse),'[]'::jsonb),
    'balances',coalesce((select jsonb_agg(to_jsonb(x) order by x.item_name) from (select b.*,i.name item_name,i.sku,i.unit from public.inventory_balances b join public.inventory_items i on i.id=b.inventory_item_id where b.warehouse_id=target_warehouse) x),'[]'::jsonb),
    'recent_movements',coalesce((select jsonb_agg(to_jsonb(x) order by x.posted_at desc) from (select m.*,i.name item_name from public.inventory_movements m join public.inventory_items i on i.id=m.inventory_item_id where m.warehouse_id=target_warehouse order by m.posted_at desc limit 50) x),'[]'::jsonb),
    'open_counts',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from public.inventory_count_sessions s where s.warehouse_id=target_warehouse and s.status in ('draft','submitted')),'[]'::jsonb),
    'summary',jsonb_build_object(
      'positive_balance_items',(select count(*) from public.inventory_balances b where b.warehouse_id=target_warehouse and b.quantity_on_hand>0),
      'quantity_on_hand',coalesce((select sum(b.quantity_on_hand) from public.inventory_balances b where b.warehouse_id=target_warehouse),0),
      'inventory_value',coalesce((select sum(b.inventory_value) from public.inventory_balances b where b.warehouse_id=target_warehouse),0),
      'movement_count',(select count(*) from public.inventory_movements m where m.warehouse_id=target_warehouse),
      'receipt_links',(select count(*) from public.inventory_movements m where m.warehouse_id=target_warehouse and m.goods_receipt_item_id is not null),
      'production_links',(select count(*) from public.inventory_movements m where m.warehouse_id=target_warehouse and m.production_order_id is not null),
      'open_count_sessions',(select count(*) from public.inventory_count_sessions s where s.warehouse_id=target_warehouse and s.status in ('draft','submitted'))
    ),
    'capabilities',jsonb_build_object('manage',private.inventory_manage_allowed())
  );
end $$;

create or replace function public.archive_inventory_warehouse(target_warehouse uuid,reason text)
returns jsonb
language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.inventory_warehouses%rowtype;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Archive reason required'; end if;
  perform 1 from public.inventory_warehouses where id=target_warehouse and active for update;
  if not found then raise exception 'Active warehouse not found'; end if;
  if exists(select 1 from public.inventory_balances where warehouse_id=target_warehouse and quantity_on_hand<>0) then raise exception 'Warehouse has stock. Transfer or adjust all balances to zero before archive'; end if;
  if exists(select 1 from public.inventory_count_sessions where warehouse_id=target_warehouse and status in ('draft','submitted')) then raise exception 'Warehouse has an open inventory count'; end if;
  update public.inventory_locations set active=false,archived_at=now(),archived_by=actor,archive_reason=btrim(reason),updated_at=now(),updated_by=actor where warehouse_id=target_warehouse and active;
  update public.inventory_warehouses set active=false,archived_at=now(),archived_by=actor,archive_reason=btrim(reason),updated_at=now(),updated_by=actor where id=target_warehouse returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('inventory_warehouses',saved.id::text,'warehouse_archived',actor,to_jsonb(saved),jsonb_build_object('reason',btrim(reason),'source','warehouse_management'));
  return jsonb_build_object('ok',true,'warehouse',to_jsonb(saved));
end $$;

create or replace function public.get_inventory_workspace()
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or role_name not in ('owner','manager','accountant','production') then raise exception using errcode='42501',message='Inventory access required'; end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.name) from public.inventory_items i where i.active),'[]'::jsonb),
    'warehouses',coalesce((select jsonb_agg(to_jsonb(w) order by w.name) from public.inventory_warehouses w where w.active),'[]'::jsonb),
    'warehouse_admin',coalesce((select jsonb_agg(to_jsonb(w) order by w.active desc,w.name) from public.inventory_warehouses w),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.warehouse_id,l.name) from public.inventory_locations l where l.active),'[]'::jsonb),
    'balances',coalesce((select jsonb_agg(to_jsonb(x) order by x.item_name,x.warehouse_name) from (select b.*,i.name item_name,i.sku,i.unit,w.name warehouse_name,case when b.quantity_on_hand=0 then 0 else b.inventory_value/nullif(b.quantity_on_hand,0) end average_unit_cost from public.inventory_balances b join public.inventory_items i on i.id=b.inventory_item_id join public.inventory_warehouses w on w.id=b.warehouse_id) x),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(to_jsonb(x) order by x.posted_at desc) from (select m.*,i.name item_name,w.name warehouse_name from public.inventory_movements m join public.inventory_items i on i.id=m.inventory_item_id join public.inventory_warehouses w on w.id=m.warehouse_id order by m.posted_at desc limit 100) x),'[]'::jsonb),
    'count_sessions',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from public.inventory_count_sessions s),'[]'::jsonb),
    'count_lines',coalesce((select jsonb_agg(to_jsonb(l) order by l.session_id,i.name) from public.inventory_count_lines l join public.inventory_items i on i.id=l.inventory_item_id),'[]'::jsonb),
    'capabilities',jsonb_build_object('manage',private.inventory_manage_allowed(),'production_event',role_name in ('owner','manager','production'),'view_financials',role_name in ('owner','manager','accountant'))
  );
end $$;

revoke all on function public.save_inventory_warehouse(uuid,text,text) from public,anon;
revoke all on function public.save_inventory_location(uuid,uuid,text,text) from public,anon;
revoke all on function public.get_inventory_warehouse_detail(uuid) from public,anon;
revoke all on function public.archive_inventory_warehouse(uuid,text) from public,anon;
grant execute on function public.save_inventory_warehouse(uuid,text,text) to authenticated;
grant execute on function public.save_inventory_location(uuid,uuid,text,text) to authenticated;
grant execute on function public.get_inventory_warehouse_detail(uuid) to authenticated;
grant execute on function public.archive_inventory_warehouse(uuid,text) to authenticated;

commit;
