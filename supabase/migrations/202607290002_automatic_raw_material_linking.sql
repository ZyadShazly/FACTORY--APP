-- Automatically reconcile raw materials with their inventory items.
begin;

create table if not exists public.raw_material_link_reviews (
  material_id uuid primary key references public.materials(id) on delete cascade,
  reason text not null check (reason in ('ambiguous_name')),
  candidate_item_ids uuid[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.raw_material_link_reviews enable row level security;
revoke all on public.raw_material_link_reviews from anon,authenticated;

create or replace function private.ensure_raw_material_inventory_item(target_material uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  material_row public.materials%rowtype;
  linked_item uuid;
  candidates uuid[];
  candidate_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended(target_material::text,0));

  select * into material_row
  from public.materials
  where id=target_material;

  if not found then return null; end if;

  select id into linked_item
  from public.inventory_items
  where material_id=target_material
  limit 1;

  if linked_item is not null then
    update public.inventory_items
    set name=material_row.name,
        unit=coalesce(nullif(btrim(material_row.unit),''),unit),
        active=material_row.active
    where id=linked_item;
    delete from public.raw_material_link_reviews where material_id=target_material;
    return linked_item;
  end if;

  select array_agg(id order by id),count(*)
  into candidates,candidate_count
  from public.inventory_items
  where material_id is null
    and product_id is null
    and lower(btrim(name))=lower(btrim(material_row.name));

  if candidate_count=1 then
    linked_item:=candidates[1];
    update public.inventory_items
    set material_id=target_material,
        name=material_row.name,
        unit=coalesce(nullif(btrim(material_row.unit),''),unit),
        active=material_row.active
    where id=linked_item;
    delete from public.raw_material_link_reviews where material_id=target_material;
    return linked_item;
  elsif candidate_count>1 then
    insert into public.raw_material_link_reviews(material_id,reason,candidate_item_ids,updated_at)
    values(target_material,'ambiguous_name',candidates,now())
    on conflict(material_id) do update
      set reason=excluded.reason,candidate_item_ids=excluded.candidate_item_ids,updated_at=now();
    return null;
  end if;

  insert into public.inventory_items(sku,name,unit,active,material_id)
  values(
    'RM-'||replace(target_material::text,'-',''),
    material_row.name,
    coalesce(nullif(btrim(material_row.unit),''),'وحدة'),
    material_row.active,
    target_material
  )
  returning id into linked_item;

  delete from public.raw_material_link_reviews where material_id=target_material;
  return linked_item;
end $$;

create or replace function private.ensure_raw_material_inventory_item_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  perform private.ensure_raw_material_inventory_item(new.id);
  return new;
end $$;

drop trigger if exists materials_ensure_raw_inventory_item on public.materials;
create trigger materials_ensure_raw_inventory_item
after insert or update of name,unit,active on public.materials
for each row execute function private.ensure_raw_material_inventory_item_trigger();

do $$
declare material_row record;
begin
  for material_row in select id from public.materials loop
    perform private.ensure_raw_material_inventory_item(material_row.id);
  end loop;
end $$;

revoke all on function private.ensure_raw_material_inventory_item(uuid) from public,anon,authenticated;
revoke all on function private.ensure_raw_material_inventory_item_trigger() from public,anon,authenticated;

commit;