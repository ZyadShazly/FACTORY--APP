-- Keep raw materials and finished goods explicitly classified, independent of links.
begin;

alter table public.inventory_items
  add column if not exists item_type text;

update public.inventory_items
set item_type=case
  when product_id is not null then 'finished_good'
  when material_id is not null then 'raw_material'
  when sku like 'FG-%' then 'finished_good'
  else 'raw_material'
end
where item_type is null;

alter table public.inventory_items
  alter column item_type set default 'raw_material',
  alter column item_type set not null;

alter table public.inventory_items
  drop constraint if exists inventory_items_item_type_check,
  drop constraint if exists inventory_items_link_type_check,
  add constraint inventory_items_item_type_check
    check (item_type in ('raw_material','finished_good')),
  add constraint inventory_items_link_type_check
    check (
      not (material_id is not null and product_id is not null)
      and (material_id is null or item_type='raw_material')
      and (product_id is null or item_type='finished_good')
    );

create or replace function private.normalize_inventory_item_type()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.material_id is not null then
    new.item_type:='raw_material';
  elsif new.product_id is not null then
    new.item_type:='finished_good';
  elsif new.item_type is null then
    new.item_type:=case when new.sku like 'FG-%' then 'finished_good' else 'raw_material' end;
  end if;
  return new;
end $$;

drop trigger if exists inventory_items_normalize_type on public.inventory_items;
create trigger inventory_items_normalize_type
before insert or update of material_id,product_id,item_type,sku on public.inventory_items
for each row execute function private.normalize_inventory_item_type();

create or replace function public.create_inventory_item(
  item_sku text,
  item_name text,
  item_unit text,
  target_material uuid default null,
  item_active boolean default true
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  saved public.inventory_items%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if btrim(coalesce(item_sku,''))='' then raise exception 'Inventory SKU is required'; end if;
  if btrim(coalesce(item_name,''))='' then raise exception 'Inventory item name is required'; end if;
  if btrim(coalesce(item_unit,''))='' then raise exception 'Inventory item unit is required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(lower(btrim(item_sku)),0));
  if exists(select 1 from public.inventory_items i where lower(btrim(i.sku))=lower(btrim(item_sku))) then
    raise exception 'Inventory SKU already exists';
  end if;
  if target_material is not null and not exists(select 1 from public.materials m where m.id=target_material and m.active) then
    raise exception 'Active raw material is required';
  end if;
  if target_material is not null and exists(select 1 from public.inventory_items i where i.material_id=target_material) then
    raise exception 'Material is already linked to another inventory item';
  end if;

  insert into public.inventory_items(sku,name,unit,material_id,active,item_type)
  values(
    btrim(item_sku),btrim(item_name),btrim(item_unit),target_material,coalesce(item_active,true),
    case when target_material is null then 'finished_good' else 'raw_material' end
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'inventory_items',saved.id::text,'inventory_item_created',actor,to_jsonb(saved),
    jsonb_build_object('source','inventory_setup','created_from_material',target_material is not null,'item_type',saved.item_type)
  );
  return to_jsonb(saved);
exception
  when unique_violation then
    if exists(select 1 from public.inventory_items i where lower(btrim(i.sku))=lower(btrim(item_sku))) then
      raise exception 'Inventory SKU already exists';
    end if;
    raise exception 'Material is already linked to another inventory item';
end $$;

create or replace function public.create_inventory_item_typed(
  item_sku text,
  item_name text,
  item_unit text,
  item_type text,
  target_material uuid default null,
  item_active boolean default true
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=auth.uid();
  normalized_type text:=lower(btrim(coalesce(item_type,'')));
  saved public.inventory_items%rowtype;
begin
  if not private.inventory_manage_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if normalized_type not in ('raw_material','finished_good') then raise exception 'Valid inventory item type is required'; end if;
  if normalized_type='finished_good' and target_material is not null then raise exception 'Finished goods cannot be linked to raw materials'; end if;
  if btrim(coalesce(item_sku,''))='' then raise exception 'Inventory SKU is required'; end if;
  if btrim(coalesce(item_name,''))='' then raise exception 'Inventory item name is required'; end if;
  if btrim(coalesce(item_unit,''))='' then raise exception 'Inventory item unit is required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(lower(btrim(item_sku)),0));
  if exists(select 1 from public.inventory_items i where lower(btrim(i.sku))=lower(btrim(item_sku))) then raise exception 'Inventory SKU already exists'; end if;
  if target_material is not null and not exists(select 1 from public.materials m where m.id=target_material and m.active) then raise exception 'Active raw material is required'; end if;
  if target_material is not null and exists(select 1 from public.inventory_items i where i.material_id=target_material) then raise exception 'Material is already linked to another inventory item'; end if;

  insert into public.inventory_items(sku,name,unit,material_id,active,item_type)
  values(btrim(item_sku),btrim(item_name),btrim(item_unit),target_material,coalesce(item_active,true),normalized_type)
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('inventory_items',saved.id::text,'inventory_item_created',actor,to_jsonb(saved),jsonb_build_object('source','inventory_setup','item_type',saved.item_type));
  return to_jsonb(saved);
end $$;

grant execute on function public.create_inventory_item_typed(text,text,text,text,uuid,boolean) to authenticated;
revoke all on function private.normalize_inventory_item_type() from public,anon,authenticated;

commit;