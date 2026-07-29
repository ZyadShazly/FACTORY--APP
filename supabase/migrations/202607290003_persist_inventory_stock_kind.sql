begin;

alter table public.inventory_items
  add column if not exists stock_kind text;

update public.inventory_items
set stock_kind=case
  when material_id is not null then 'raw'
  when product_id is not null then 'finished'
  when exists (
    select 1 from public.materials m
    where lower(btrim(m.name))=lower(btrim(public.inventory_items.name))
  ) then 'raw'
  else 'finished'
end
where stock_kind is null;

alter table public.inventory_items
  alter column stock_kind set default 'finished',
  alter column stock_kind set not null;

alter table public.inventory_items
  drop constraint if exists inventory_items_stock_kind_check;

alter table public.inventory_items
  add constraint inventory_items_stock_kind_check
  check (stock_kind in ('raw','finished'));

create or replace function private.set_inventory_item_stock_kind()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.material_id is not null then
    new.stock_kind:='raw';
  elsif new.product_id is not null then
    new.stock_kind:='finished';
  elsif tg_op='INSERT' and new.stock_kind is null then
    new.stock_kind:='finished';
  elsif tg_op='UPDATE' and new.stock_kind is null then
    new.stock_kind:=old.stock_kind;
  end if;
  return new;
end $$;

drop trigger if exists inventory_items_set_stock_kind on public.inventory_items;
create trigger inventory_items_set_stock_kind
before insert or update of material_id,product_id,stock_kind on public.inventory_items
for each row execute function private.set_inventory_item_stock_kind();

-- Reconnect a raw item only when the material name has one exact case-sensitive candidate.
update public.inventory_items i
set material_id=m.id,
    stock_kind='raw'
from public.materials m
where i.stock_kind='raw'
  and i.material_id is null
  and i.product_id is null
  and btrim(i.name)=btrim(m.name)
  and 1=(select count(*) from public.materials m2 where btrim(m2.name)=btrim(i.name));

revoke all on function private.set_inventory_item_stock_kind() from public,anon,authenticated;

commit;