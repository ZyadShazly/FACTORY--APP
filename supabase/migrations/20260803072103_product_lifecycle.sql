-- EP05-C: preserve product and production history through reversible archive.
begin;

alter table public.products
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null,
  add column if not exists archived_reason text;

create index if not exists products_archived_at_idx on public.products(archived_at) where archived_at is not null;
create index if not exists products_archived_by_idx on public.products(archived_by) where archived_by is not null;

alter table public.production_orders drop constraint if exists production_orders_product_id_fkey;
alter table public.production_orders add constraint production_orders_product_id_fkey
  foreign key(product_id) references public.products(id) on delete restrict;
alter table public.finished_goods_link_reviews drop constraint if exists finished_goods_link_reviews_product_id_fkey;
alter table public.finished_goods_link_reviews add constraint finished_goods_link_reviews_product_id_fkey
  foreign key(product_id) references public.products(id) on delete restrict;

create index if not exists production_orders_product_id_idx on public.production_orders(product_id) where product_id is not null;
create index if not exists finished_goods_link_reviews_product_id_idx on public.finished_goods_link_reviews(product_id);

create or replace function private.guard_product_lifecycle()
returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='23503',message='Product history cannot be deleted; archive it instead';
  end if;
  if tg_op='INSERT' then
    if new.archived_at is not null or new.archived_by is not null or new.archived_reason is not null then
      raise exception using errcode='22023',message='New products must start active';
    end if;
    return new;
  end if;
  if old.archived_at is not null and new.archived_at is not distinct from old.archived_at then
    raise exception using errcode='55000',message='Restore the archived product before editing it';
  end if;
  if new.archived_at is distinct from old.archived_at then
    if not public.can_delete_rows() then
      raise exception using errcode='42501',message='Only an authorized manager can archive or restore products';
    end if;
    if new.archived_at is not null then
      if nullif(btrim(new.archived_reason),'') is null then
        raise exception using errcode='22023',message='Archive reason is required';
      end if;
      new.archived_at:=statement_timestamp();
      new.archived_by:=auth.uid();
      new.archived_reason:=btrim(new.archived_reason);
    else
      new.archived_by:=null;
      new.archived_reason:=null;
    end if;
  elsif new.archived_by is distinct from old.archived_by or new.archived_reason is distinct from old.archived_reason then
    raise exception using errcode='42501',message='Archive metadata is managed by the lifecycle action';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_product_lifecycle() from public,anon,authenticated;
drop trigger if exists products_lifecycle_guard on public.products;
create trigger products_lifecycle_guard before insert or update or delete on public.products
for each row execute function private.guard_product_lifecycle();

drop trigger if exists require_active_product on public.sales;
create trigger require_active_product before insert or update of product_id on public.sales
for each row execute function private.require_active_commercial_party('products','product_id');
drop trigger if exists require_active_product on public.rentals;
create trigger require_active_product before insert or update of product_id on public.rentals
for each row execute function private.require_active_commercial_party('products','product_id');
drop trigger if exists require_active_product on public.production_orders;
create trigger require_active_product before insert or update of product_id on public.production_orders
for each row execute function private.require_active_commercial_party('products','product_id');

drop policy if exists products_delete_permission on public.products;
drop policy if exists products_delete_manager on public.products;
revoke delete on table public.products from anon,authenticated;

commit;
