-- Protect product, customer and supplier writes behind audited workflows.
begin;

alter table public.products
  add column if not exists item_type text,
  add column if not exists command_id uuid;
alter table public.customers add column if not exists command_id uuid;
alter table public.suppliers add column if not exists command_id uuid;

do $constraints$
begin
  if not exists(select 1 from pg_constraint where conname='products_item_type_check' and conrelid='public.products'::regclass) then
    alter table public.products add constraint products_item_type_check
      check(item_type is null or item_type in ('sale','rental','both')) not valid;
  end if;
end
$constraints$;

create unique index if not exists products_command_uidx on public.products(command_id) where command_id is not null;
create unique index if not exists customers_command_uidx on public.customers(command_id) where command_id is not null;
create unique index if not exists suppliers_command_uidx on public.suppliers(command_id) where command_id is not null;

create or replace function private.master_data_action_allowed(target_page text,target_action text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.profiles p
    where p.id=auth.uid() and p.status='active'
      and (
        p.role in ('owner','manager')
        or (
          p.role='accountant'
          and (jsonb_typeof(p.permissions->'pages') is distinct from 'array' or p.permissions->'pages' ? target_page)
          and case
            when target_page='products' and target_action='create'
              then coalesce((p.permissions->>'can_create_products')::boolean,true)
            when target_page='products' and target_action='edit'
              then coalesce((p.permissions->>'can_edit_products')::boolean,false)
            else true
          end
        )
      )
  )
$$;
revoke all on function private.master_data_action_allowed(text,text) from public,anon,authenticated;

create or replace function public.save_product(target_id uuid,payload jsonb,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  saved public.products%rowtype;
  product_name text:=nullif(btrim(payload->>'name'),'');
  product_sku text:=nullif(btrim(payload->>'sku'),'');
  product_bom jsonb:=coalesce(payload->'bom','[]'::jsonb);
  product_kind text:=coalesce(nullif(payload->>'item_type',''),'sale');
  labor numeric:=coalesce(nullif(payload->>'labor_cost','')::numeric,0);
  overhead numeric:=coalesce(nullif(payload->>'overhead_cost','')::numeric,0);
  price numeric:=coalesce(nullif(payload->>'selling_price','')::numeric,0);
begin
  if not private.master_data_action_allowed('products',case when target_id is null then 'create' else 'edit' end) then
    raise exception using errcode='42501',message='Product create or edit permission required';
  end if;
  if product_name is null then raise exception using errcode='22023',message='Product name is required'; end if;
  if product_kind not in ('sale','rental','both') then raise exception using errcode='22023',message='Invalid product type'; end if;
  if labor<0 or overhead<0 or price<0 then raise exception using errcode='22023',message='Product financial values cannot be negative'; end if;
  if jsonb_typeof(product_bom)<>'array' or jsonb_array_length(product_bom)=0 then
    raise exception using errcode='22023',message='At least one BOM component is required';
  end if;
  if exists(
    select 1 from jsonb_array_elements(product_bom) component
    where nullif(component->>'material_id','') is null
       or nullif(component->>'qty','') is null
       or (component->>'qty')::numeric<=0
       or not exists(select 1 from public.materials m where m.id=(component->>'material_id')::uuid)
  ) then raise exception using errcode='22023',message='Every BOM component requires a valid material and positive quantity'; end if;
  if (select count(*) from jsonb_array_elements(product_bom)) <>
     (select count(distinct component->>'material_id') from jsonb_array_elements(product_bom) component) then
    raise exception using errcode='22023',message='A material cannot appear twice in the same BOM';
  end if;

  if target_id is null then
    if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;
    select * into saved from public.products where products.command_id=save_product.command_id;
    if found then return to_jsonb(saved); end if;
    insert into public.products(name,sku,bom,labor_cost,overhead_cost,selling_price,item_type,command_id)
    values(product_name,product_sku,product_bom,labor,overhead,price,product_kind,command_id)
    returning * into saved;
  else
    update public.products set name=product_name,sku=product_sku,bom=product_bom,labor_cost=labor,
      overhead_cost=overhead,selling_price=price,item_type=product_kind
    where id=target_id and archived_at is null returning * into saved;
    if not found then raise exception using errcode='P0002',message='Active product not found'; end if;
  end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('products',saved.id::text,case when target_id is null then 'product_created' else 'product_updated' end,auth.uid(),to_jsonb(saved),jsonb_build_object('item_type',product_kind));
  return to_jsonb(saved);
end $$;

create or replace function public.set_product_archived(target_id uuid,archive boolean,reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.products%rowtype; changed boolean;
begin
  if auth.uid() is null or not public.is_current_profile_active() or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if archive and nullif(btrim(reason),'') is null then raise exception using errcode='22023',message='Archive reason is required'; end if;
  update public.products set archived_at=case when archive then statement_timestamp() else null end,
    archived_reason=case when archive then btrim(reason) else null end
  where id=target_id and ((archive and archived_at is null) or (not archive and archived_at is not null))
  returning * into saved;
  changed:=found;
  if not changed then
    select * into saved from public.products where id=target_id;
    if not found then raise exception using errcode='P0002',message='Product not found'; end if;
  end if;
  if changed then
    insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
    values('products',saved.id::text,case when archive then 'product_archived' else 'product_restored' end,auth.uid(),to_jsonb(saved),jsonb_build_object('reason',nullif(btrim(reason),'')));
  end if;
  return to_jsonb(saved);
end $$;

create or replace function public.save_customer(target_id uuid,customer_name text,customer_phone text default null,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.customers%rowtype; clean_name text:=nullif(btrim(customer_name),'');
begin
  if not private.master_data_action_allowed('customers',case when target_id is null then 'create' else 'edit' end) then raise exception using errcode='42501',message='Customer access required'; end if;
  if clean_name is null then raise exception using errcode='22023',message='Customer name is required'; end if;
  if target_id is null then
    if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;
    select * into saved from public.customers where customers.command_id=save_customer.command_id;
    if found then return to_jsonb(saved); end if;
    insert into public.customers(name,phone,command_id) values(clean_name,nullif(btrim(customer_phone),''),command_id) returning * into saved;
  else
    update public.customers set name=clean_name,phone=nullif(btrim(customer_phone),'') where id=target_id and archived_at is null returning * into saved;
    if not found then raise exception using errcode='P0002',message='Active customer not found'; end if;
  end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data) values('customers',saved.id::text,case when target_id is null then 'customer_created' else 'customer_updated' end,auth.uid(),to_jsonb(saved));
  return to_jsonb(saved);
end $$;

create or replace function public.save_supplier(target_id uuid,supplier_name text,supplier_phone text default null,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.suppliers%rowtype; clean_name text:=nullif(btrim(supplier_name),'');
begin
  if not private.master_data_action_allowed('suppliers',case when target_id is null then 'create' else 'edit' end) then raise exception using errcode='42501',message='Supplier access required'; end if;
  if clean_name is null then raise exception using errcode='22023',message='Supplier name is required'; end if;
  if target_id is null then
    if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;
    select * into saved from public.suppliers where suppliers.command_id=save_supplier.command_id;
    if found then return to_jsonb(saved); end if;
    insert into public.suppliers(name,phone,command_id) values(clean_name,nullif(btrim(supplier_phone),''),command_id) returning * into saved;
  else
    update public.suppliers set name=clean_name,phone=nullif(btrim(supplier_phone),'') where id=target_id and archived_at is null returning * into saved;
    if not found then raise exception using errcode='P0002',message='Active supplier not found'; end if;
  end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data) values('suppliers',saved.id::text,case when target_id is null then 'supplier_created' else 'supplier_updated' end,auth.uid(),to_jsonb(saved));
  return to_jsonb(saved);
end $$;

create or replace function public.set_commercial_party_archived(party_type text,target_id uuid,archive boolean,reason text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; changed boolean:=false;
begin
  if auth.uid() is null or not public.is_current_profile_active() or public.current_identity_role() not in ('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if party_type not in ('customer','supplier') then raise exception using errcode='22023',message='Invalid party type'; end if;
  if archive and nullif(btrim(reason),'') is null then raise exception using errcode='22023',message='Archive reason is required'; end if;
  if party_type='customer' then
    update public.customers c set archived_at=case when archive then statement_timestamp() else null end,archived_reason=case when archive then btrim(reason) else null end
    where c.id=target_id and ((archive and c.archived_at is null) or (not archive and c.archived_at is not null)) returning to_jsonb(c.*) into result;
    changed:=found;
    if result is null then select to_jsonb(c.*) into result from public.customers c where c.id=target_id; end if;
  else
    update public.suppliers s set archived_at=case when archive then statement_timestamp() else null end,archived_reason=case when archive then btrim(reason) else null end
    where s.id=target_id and ((archive and s.archived_at is null) or (not archive and s.archived_at is not null)) returning to_jsonb(s.*) into result;
    changed:=found;
    if result is null then select to_jsonb(s.*) into result from public.suppliers s where s.id=target_id; end if;
  end if;
  if result is null then raise exception using errcode='P0002',message='Commercial party not found'; end if;
  if changed then
    insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
    values(party_type||'s',target_id::text,party_type||case when archive then '_archived' else '_restored' end,auth.uid(),result,jsonb_build_object('reason',nullif(btrim(reason),'')));
  end if;
  return result;
end $$;

revoke all on function public.save_product(uuid,jsonb,uuid),public.set_product_archived(uuid,boolean,text),
  public.save_customer(uuid,text,text,uuid),public.save_supplier(uuid,text,text,uuid),
  public.set_commercial_party_archived(text,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.save_product(uuid,jsonb,uuid),public.set_product_archived(uuid,boolean,text),
  public.save_customer(uuid,text,text,uuid),public.save_supplier(uuid,text,text,uuid),
  public.set_commercial_party_archived(text,uuid,boolean,text) to authenticated;

drop policy if exists products_insert_all on public.products;
drop policy if exists customers_insert_all on public.customers;
drop policy if exists suppliers_insert_all on public.suppliers;
revoke insert,update,delete on table public.products,public.customers,public.suppliers from anon,authenticated;

commit;
