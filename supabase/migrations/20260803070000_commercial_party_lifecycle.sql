-- EP05: preserve customer and supplier history with a reversible lifecycle.

alter table public.customers
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null,
  add column if not exists archived_reason text;

alter table public.suppliers
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id) on delete set null,
  add column if not exists archived_reason text;

create index if not exists customers_archived_at_idx
  on public.customers(archived_at) where archived_at is not null;
create index if not exists customers_archived_by_idx
  on public.customers(archived_by) where archived_by is not null;
create index if not exists suppliers_archived_at_idx
  on public.suppliers(archived_at) where archived_at is not null;
create index if not exists suppliers_archived_by_idx
  on public.suppliers(archived_by) where archived_by is not null;

create or replace function private.guard_commercial_party_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using
      errcode = '23503',
      message = format('%s history cannot be deleted; archive it instead', initcap(tg_table_name));
  end if;

  if tg_op = 'INSERT' then
    if new.archived_at is not null or new.archived_by is not null or new.archived_reason is not null then
      raise exception using errcode = '22023', message = 'New commercial parties must start active';
    end if;
    return new;
  end if;

  if old.archived_at is not null
     and new.archived_at is not distinct from old.archived_at then
    raise exception using errcode = '55000', message = 'Restore the archived record before editing it';
  end if;

  if new.archived_at is distinct from old.archived_at then
    if not public.can_delete_rows() then
      raise exception using errcode = '42501', message = 'Only an authorized manager can archive or restore commercial parties';
    end if;

    if new.archived_at is not null then
      if nullif(btrim(new.archived_reason), '') is null then
        raise exception using errcode = '22023', message = 'Archive reason is required';
      end if;
      new.archived_at := statement_timestamp();
      new.archived_by := auth.uid();
      new.archived_reason := btrim(new.archived_reason);
    else
      new.archived_by := null;
      new.archived_reason := null;
    end if;
  elsif new.archived_by is distinct from old.archived_by
     or new.archived_reason is distinct from old.archived_reason then
    raise exception using errcode = '42501', message = 'Archive metadata is managed by the lifecycle action';
  end if;

  return new;
end;
$$;

revoke all on function private.guard_commercial_party_lifecycle() from public, anon, authenticated;

drop trigger if exists customers_lifecycle_guard on public.customers;
create trigger customers_lifecycle_guard
before insert or update or delete on public.customers
for each row execute function private.guard_commercial_party_lifecycle();

drop trigger if exists suppliers_lifecycle_guard on public.suppliers;
create trigger suppliers_lifecycle_guard
before insert or update or delete on public.suppliers
for each row execute function private.guard_commercial_party_lifecycle();

create or replace function private.require_active_commercial_party()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  reference_id uuid;
  reference_was_changed boolean;
  party_is_active boolean;
begin
  reference_id := nullif(to_jsonb(new) ->> tg_argv[1], '')::uuid;
  if tg_op = 'INSERT' then
    reference_was_changed := true;
  else
    reference_was_changed := (to_jsonb(new) ->> tg_argv[1]) is distinct from (to_jsonb(old) ->> tg_argv[1]);
  end if;

  if reference_id is null or not reference_was_changed then
    return new;
  end if;

  execute format('select archived_at is null from public.%I where id = $1', tg_argv[0])
    into party_is_active
    using reference_id;

  if party_is_active is false then
    raise exception using errcode = '23514', message = format('Archived %s cannot be used in new transactions', tg_argv[0]);
  end if;
  return new;
end;
$$;

revoke all on function private.require_active_commercial_party() from public, anon, authenticated;

do $commercial_party_reference_guards$
declare
  target_table text;
begin
  foreach target_table in array array['sales','rentals','customer_receipts','projects'] loop
    execute format('drop trigger if exists require_active_customer on public.%I', target_table);
    execute format(
      'create trigger require_active_customer before insert or update of customer_id on public.%I for each row execute function private.require_active_commercial_party(''customers'',''customer_id'')',
      target_table
    );
  end loop;

  foreach target_table in array array['supplier_payments','material_purchases','project_budget_items','purchase_orders','supplier_invoices','supplier_quotes','assets'] loop
    execute format('drop trigger if exists require_active_supplier on public.%I', target_table);
    execute format(
      'create trigger require_active_supplier before insert or update of supplier_id on public.%I for each row execute function private.require_active_commercial_party(''suppliers'',''supplier_id'')',
      target_table
    );
  end loop;
end;
$commercial_party_reference_guards$;

drop policy if exists customers_delete_permission on public.customers;
drop policy if exists customers_delete_manager on public.customers;
drop policy if exists suppliers_delete_permission on public.suppliers;
drop policy if exists suppliers_delete_manager on public.suppliers;

comment on column public.customers.archived_at is 'When set, excludes the customer from new commercial transactions while preserving history.';
comment on column public.suppliers.archived_at is 'When set, excludes the supplier from new commercial transactions while preserving history.';
