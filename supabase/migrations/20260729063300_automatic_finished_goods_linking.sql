-- Automatically reconcile products with their finished-goods inventory items.
begin;

create table if not exists public.finished_goods_link_reviews (
  product_id uuid primary key references public.products(id) on delete cascade,
  reason text not null check (reason in ('ambiguous_sku','ambiguous_name')),
  candidate_item_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.finished_goods_link_reviews enable row level security;
revoke all on public.finished_goods_link_reviews from anon,authenticated;

create or replace function private.ensure_finished_goods_inventory_item(target_product uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  product_row public.products%rowtype;
  linked_item uuid;
  candidates uuid[];
  candidate_count integer;
begin
  select * into product_row
  from public.products
  where id=target_product;

  if not found then return null; end if;

  select id into linked_item
  from public.inventory_items
  where product_id=target_product
  limit 1;

  if linked_item is not null then
    delete from public.finished_goods_link_reviews where product_id=target_product;
    return linked_item;
  end if;

  if nullif(btrim(coalesce(product_row.sku,'')),'') is not null then
    select array_agg(id order by id),count(*)
    into candidates,candidate_count
    from public.inventory_items
    where product_id is null
      and material_id is null
      and lower(btrim(sku))=lower(btrim(product_row.sku));

    if candidate_count=1 then
      linked_item:=candidates[1];
      update public.inventory_items set product_id=target_product where id=linked_item;
      delete from public.finished_goods_link_reviews where product_id=target_product;
      return linked_item;
    elsif candidate_count>1 then
      insert into public.finished_goods_link_reviews(product_id,reason,candidate_item_ids,updated_at)
      values(target_product,'ambiguous_sku',candidates,now())
      on conflict(product_id) do update set reason=excluded.reason,candidate_item_ids=excluded.candidate_item_ids,updated_at=now();
      return null;
    end if;
  end if;

  select array_agg(id order by id),count(*)
  into candidates,candidate_count
  from public.inventory_items
  where product_id is null
    and material_id is null
    and lower(btrim(name))=lower(btrim(product_row.name));

  if candidate_count=1 then
    linked_item:=candidates[1];
    update public.inventory_items set product_id=target_product where id=linked_item;
    delete from public.finished_goods_link_reviews where product_id=target_product;
    return linked_item;
  elsif candidate_count>1 then
    insert into public.finished_goods_link_reviews(product_id,reason,candidate_item_ids,updated_at)
    values(target_product,'ambiguous_name',candidates,now())
    on conflict(product_id) do update set reason=excluded.reason,candidate_item_ids=excluded.candidate_item_ids,updated_at=now();
    return null;
  end if;

  insert into public.inventory_items(sku,name,unit,active,product_id)
  values(
    'FG-'||replace(target_product::text,'-',''),
    product_row.name,
    'وحدة',
    true,
    target_product
  )
  returning id into linked_item;

  delete from public.finished_goods_link_reviews where product_id=target_product;
  return linked_item;
end $$;

create or replace function private.ensure_finished_goods_inventory_item_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  perform private.ensure_finished_goods_inventory_item(new.id);
  return new;
end $$;

drop trigger if exists products_ensure_finished_goods_item on public.products;
create trigger products_ensure_finished_goods_item
after insert or update of name,sku on public.products
for each row execute function private.ensure_finished_goods_inventory_item_trigger();

do $$
declare product_row record;
begin
  for product_row in select id from public.products loop
    perform private.ensure_finished_goods_inventory_item(product_row.id);
  end loop;
end $$;

revoke all on function private.ensure_finished_goods_inventory_item(uuid) from public,anon,authenticated;
revoke all on function private.ensure_finished_goods_inventory_item_trigger() from public,anon,authenticated;

commit;