-- EP05-B: immutable sales and rental lifecycle with reversible cancellation.
begin;

alter table public.sales
  add column if not exists status text not null default 'posted',
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete set null,
  add column if not exists cancellation_reason text;

alter table public.rentals
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete set null,
  add column if not exists cancellation_reason text,
  add column if not exists returned_at timestamptz,
  add column if not exists returned_by uuid references public.profiles(id) on delete set null;

alter table public.rentals drop constraint if exists rentals_status_check;
alter table public.rentals
  add constraint rentals_status_check check (status in ('active','returned','cancelled'));

do $constraints$
begin
  if not exists (select 1 from pg_constraint where conname='sales_status_check' and conrelid='public.sales'::regclass) then
    alter table public.sales add constraint sales_status_check check (status in ('posted','cancelled'));
  end if;
  if not exists (select 1 from pg_constraint where conname='sales_positive_amounts_check' and conrelid='public.sales'::regclass) then
    alter table public.sales add constraint sales_positive_amounts_check check (status='cancelled' or (qty>0 and unit_price>=0 and total>=0)) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='sales_total_consistency_check' and conrelid='public.sales'::regclass) then
    alter table public.sales add constraint sales_total_consistency_check check (status='cancelled' or round(total,2)=round(qty*unit_price,2)) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='sales_required_fields_check' and conrelid='public.sales'::regclass) then
    alter table public.sales add constraint sales_required_fields_check check (status='cancelled' or (product_id is not null and customer_id is not null and sale_date is not null)) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='rentals_positive_amounts_check' and conrelid='public.rentals'::regclass) then
    alter table public.rentals add constraint rentals_positive_amounts_check check (qty>0 and rental_fee>=0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='rentals_date_order_check' and conrelid='public.rentals'::regclass) then
    alter table public.rentals add constraint rentals_date_order_check check (
      (expected_return_date is null or expected_return_date>=start_date)
      and (return_date is null or return_date>=start_date)
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='rentals_required_fields_check' and conrelid='public.rentals'::regclass) then
    alter table public.rentals add constraint rentals_required_fields_check check (product_id is not null and customer_id is not null and start_date is not null) not valid;
  end if;
end;
$constraints$;

alter table public.sales drop constraint if exists sales_customer_id_fkey;
alter table public.sales add constraint sales_customer_id_fkey foreign key (customer_id) references public.customers(id) on delete restrict;
alter table public.sales drop constraint if exists sales_product_id_fkey;
alter table public.sales add constraint sales_product_id_fkey foreign key (product_id) references public.products(id) on delete restrict;
alter table public.rentals drop constraint if exists rentals_customer_id_fkey;
alter table public.rentals add constraint rentals_customer_id_fkey foreign key (customer_id) references public.customers(id) on delete restrict;
alter table public.rentals drop constraint if exists rentals_product_id_fkey;
alter table public.rentals add constraint rentals_product_id_fkey foreign key (product_id) references public.products(id) on delete restrict;

create index if not exists sales_customer_id_idx on public.sales(customer_id) where customer_id is not null;
create index if not exists sales_product_id_idx on public.sales(product_id) where product_id is not null;
create index if not exists sales_cancelled_by_idx on public.sales(cancelled_by) where cancelled_by is not null;
create index if not exists sales_status_date_idx on public.sales(status,sale_date desc);
create index if not exists rentals_customer_id_idx on public.rentals(customer_id) where customer_id is not null;
create index if not exists rentals_product_id_idx on public.rentals(product_id) where product_id is not null;
create index if not exists rentals_cancelled_by_idx on public.rentals(cancelled_by) where cancelled_by is not null;
create index if not exists rentals_returned_by_idx on public.rentals(returned_by) where returned_by is not null;
create index if not exists rentals_status_date_idx on public.rentals(status,start_date desc);
create index if not exists customer_receipts_customer_id_idx on public.customer_receipts(customer_id) where customer_id is not null;
create index if not exists supplier_payments_supplier_id_idx on public.supplier_payments(supplier_id) where supplier_id is not null;

create or replace function private.guard_sale_history()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='23514',message='Sale history cannot be deleted; use cancel_sale';
  end if;
  if tg_op='INSERT' then
    if new.status<>'posted' or new.cancelled_at is not null or new.cancelled_by is not null or new.cancellation_reason is not null then
      raise exception using errcode='22023',message='New sales must start posted';
    end if;
    return new;
  end if;
  if old.status='cancelled' and new is distinct from old then
    raise exception using errcode='23514',message='Cancelled sale is immutable';
  end if;
  if new.product_id is distinct from old.product_id or new.customer_id is distinct from old.customer_id
     or new.qty is distinct from old.qty or new.unit_price is distinct from old.unit_price
     or new.total is distinct from old.total or new.sale_date is distinct from old.sale_date
     or new.note is distinct from old.note then
    raise exception using errcode='23514',message='Posted sale is immutable; cancel it and record a corrected sale';
  end if;
  if new.status is distinct from old.status then
    if old.status<>'posted' or new.status<>'cancelled' or new.cancelled_at is null
       or new.cancelled_by is null or nullif(btrim(new.cancellation_reason),'') is null then
      raise exception using errcode='23514',message='Invalid sale lifecycle transition';
    end if;
  elsif new.cancelled_at is distinct from old.cancelled_at or new.cancelled_by is distinct from old.cancelled_by
     or new.cancellation_reason is distinct from old.cancellation_reason then
    raise exception using errcode='23514',message='Sale cancellation metadata requires the lifecycle action';
  end if;
  return new;
end;
$$;

create or replace function private.guard_rental_history()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='23514',message='Rental history cannot be deleted; use the rental lifecycle actions';
  end if;
  if tg_op='INSERT' then
    if new.status<>'active' or new.return_date is not null or new.returned_at is not null or new.returned_by is not null
       or new.cancelled_at is not null or new.cancelled_by is not null or new.cancellation_reason is not null then
      raise exception using errcode='22023',message='New rentals must start active';
    end if;
    return new;
  end if;
  if old.status in ('returned','cancelled') and new is distinct from old then
    raise exception using errcode='23514',message='Terminal rental history is immutable';
  end if;
  if new.product_id is distinct from old.product_id or new.customer_id is distinct from old.customer_id
     or new.qty is distinct from old.qty or new.rental_fee is distinct from old.rental_fee
     or new.start_date is distinct from old.start_date or new.expected_return_date is distinct from old.expected_return_date
     or new.note is distinct from old.note then
    raise exception using errcode='23514',message='Active rental terms are immutable; cancel it and record a corrected rental';
  end if;
  if new.status is distinct from old.status then
    if old.status<>'active' then raise exception using errcode='23514',message='Invalid rental lifecycle transition'; end if;
    if new.status='returned' then
      if new.return_date is null or new.returned_at is null or new.returned_by is null
         or new.cancelled_at is not null or new.cancelled_by is not null or new.cancellation_reason is not null then
        raise exception using errcode='23514',message='Invalid rental return transition';
      end if;
    elsif new.status='cancelled' then
      if new.cancelled_at is null or new.cancelled_by is null or nullif(btrim(new.cancellation_reason),'') is null
         or new.return_date is not null or new.returned_at is not null or new.returned_by is not null then
        raise exception using errcode='23514',message='Invalid rental cancellation transition';
      end if;
    else
      raise exception using errcode='23514',message='Invalid rental lifecycle transition';
    end if;
  elsif new.return_date is distinct from old.return_date or new.returned_at is distinct from old.returned_at
     or new.returned_by is distinct from old.returned_by or new.cancelled_at is distinct from old.cancelled_at
     or new.cancelled_by is distinct from old.cancelled_by or new.cancellation_reason is distinct from old.cancellation_reason then
    raise exception using errcode='23514',message='Rental lifecycle metadata requires a protected action';
  end if;
  return new;
end;
$$;

revoke all on function private.guard_sale_history() from public,anon,authenticated;
revoke all on function private.guard_rental_history() from public,anon,authenticated;
drop trigger if exists guard_sale_history on public.sales;
create trigger guard_sale_history before insert or update or delete on public.sales for each row execute function private.guard_sale_history();
drop trigger if exists guard_rental_history on public.rentals;
create trigger guard_rental_history before insert or update or delete on public.rentals for each row execute function private.guard_rental_history();

create or replace function public.cancel_sale(target_sale_id uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); actor_role text:=public.current_identity_role(); saved public.sales%rowtype;
begin
  if actor is null or actor_role not in ('owner','manager') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if nullif(btrim(reason),'') is null then raise exception using errcode='22023',message='Cancellation reason is required'; end if;
  select * into saved from public.sales where id=target_sale_id for update;
  if not found then raise exception using errcode='P0002',message='Sale not found'; end if;
  if saved.status='cancelled' then return to_jsonb(saved); end if;
  update public.sales set status='cancelled',cancelled_at=statement_timestamp(),cancelled_by=actor,cancellation_reason=btrim(reason)
  where id=target_sale_id returning * into saved;
  return to_jsonb(saved);
end;
$$;

create or replace function public.mark_rental_returned(target_rental_id uuid,target_return_date date default current_date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); saved public.rentals%rowtype;
begin
  if actor is null or not public.is_current_profile_active() or not public.can_access('rentals') then
    raise exception using errcode='42501',message='Rental access required';
  end if;
  select * into saved from public.rentals where id=target_rental_id for update;
  if not found then raise exception using errcode='P0002',message='Rental not found'; end if;
  if saved.status='returned' then return to_jsonb(saved); end if;
  if saved.status<>'active' then raise exception using errcode='23514',message='Only an active rental can be returned'; end if;
  if target_return_date is null or target_return_date<saved.start_date then
    raise exception using errcode='22023',message='Return date cannot be before rental start';
  end if;
  update public.rentals set status='returned',return_date=target_return_date,returned_at=statement_timestamp(),returned_by=actor
  where id=target_rental_id returning * into saved;
  return to_jsonb(saved);
end;
$$;

create or replace function public.cancel_rental(target_rental_id uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); actor_role text:=public.current_identity_role(); saved public.rentals%rowtype;
begin
  if actor is null or actor_role not in ('owner','manager') or not public.is_current_profile_active() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if nullif(btrim(reason),'') is null then raise exception using errcode='22023',message='Cancellation reason is required'; end if;
  select * into saved from public.rentals where id=target_rental_id for update;
  if not found then raise exception using errcode='P0002',message='Rental not found'; end if;
  if saved.status='cancelled' then return to_jsonb(saved); end if;
  if saved.status<>'active' then raise exception using errcode='23514',message='Only an active rental can be cancelled'; end if;
  update public.rentals set status='cancelled',cancelled_at=statement_timestamp(),cancelled_by=actor,cancellation_reason=btrim(reason)
  where id=target_rental_id returning * into saved;
  return to_jsonb(saved);
end;
$$;

revoke all on function public.cancel_sale(uuid,text) from public,anon,authenticated;
revoke all on function public.mark_rental_returned(uuid,date) from public,anon,authenticated;
revoke all on function public.cancel_rental(uuid,text) from public,anon,authenticated;
grant execute on function public.cancel_sale(uuid,text) to authenticated;
grant execute on function public.mark_rental_returned(uuid,date) to authenticated;
grant execute on function public.cancel_rental(uuid,text) to authenticated;

drop policy if exists sales_delete_permission on public.sales;
drop policy if exists sales_delete_manager on public.sales;
drop policy if exists sales_update_permission on public.sales;
drop policy if exists rentals_delete_permission on public.rentals;
drop policy if exists rentals_delete_manager on public.rentals;
drop policy if exists rentals_update_permission on public.rentals;

revoke update,delete on table public.sales from anon,authenticated;
revoke update,delete on table public.rentals from anon,authenticated;

commit;
