-- Canonical pre-migration baseline reconstructed from the original schema,
-- the application contract at 2026-07-13, and read-only production metadata.
-- Schema only: this migration intentionally creates no application data.

create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null check (role in ('manager','accountant','production')),
  created_at timestamptz default now()
);

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  created_at timestamptz default now()
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  created_at timestamptz default now()
);

create table public.materials (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  unit text,
  unit_cost numeric default 0,
  initial_stock numeric default 0,
  created_at timestamptz default now()
);

create table public.material_purchases (
  id uuid primary key default gen_random_uuid(),
  material_id uuid references public.materials(id) on delete cascade,
  supplier_id uuid references public.suppliers(id) on delete set null,
  qty numeric not null,
  unit_cost numeric not null,
  purchase_date date,
  note text,
  created_at timestamptz default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sku text,
  bom jsonb default '[]'::jsonb,
  labor_cost numeric default 0,
  overhead_cost numeric default 0,
  selling_price numeric default 0,
  created_at timestamptz default now(),
  item_type text not null default 'sale'
    check (item_type in ('sale','rental','both'))
);

create table public.production_orders (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete cascade,
  qty numeric not null,
  materials_cost numeric default 0,
  labor_cost numeric default 0,
  overhead_cost numeric default 0,
  total_cost numeric default 0,
  unit_cost numeric default 0,
  order_date date,
  note text,
  created_at timestamptz default now(),
  waste_percentage numeric not null default 0
    check (waste_percentage >= 0)
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  qty numeric not null,
  unit_price numeric not null,
  total numeric not null,
  sale_date date,
  note text,
  created_at timestamptz default now()
);

create table public.rentals (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.products(id) on delete cascade,
  customer_id uuid references public.customers(id) on delete set null,
  qty numeric not null,
  rental_fee numeric not null default 0,
  start_date date,
  expected_return_date date,
  return_date date,
  status text not null default 'active'
    check (status in ('active','returned')),
  note text,
  created_at timestamptz default now()
);

create table public.supplier_payments (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid references public.suppliers(id) on delete cascade,
  amount numeric not null,
  payment_date date,
  note text,
  created_at timestamptz default now()
);

create table public.customer_receipts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete cascade,
  amount numeric not null,
  receipt_date date,
  note text,
  created_at timestamptz default now()
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  amount numeric not null check (amount > 0),
  expense_date date not null default current_date,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create or replace function public.is_manager()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.profiles
    where id = (select auth.uid())
      and role = 'manager'
  )
$$;

revoke all on function public.is_manager() from public, anon;
grant execute on function public.is_manager() to authenticated;

do $$
declare
  target_table text;
begin
  foreach target_table in array array[
    'profiles','suppliers','customers','materials','material_purchases',
    'products','production_orders','sales','rentals','supplier_payments',
    'customer_receipts','expenses'
  ] loop
    execute format('alter table public.%I enable row level security', target_table);
    execute format('revoke all on table public.%I from anon, authenticated', target_table);
    execute format(
      'grant select, insert, update, delete on table public.%I to authenticated',
      target_table
    );
  end loop;
end
$$;

create policy profiles_select_all
on public.profiles for select to authenticated
using ((select auth.uid()) is not null);

create policy profiles_insert_own
on public.profiles for insert to authenticated
with check ((select auth.uid()) = id);

create policy profiles_update_own
on public.profiles for update to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

do $$
declare
  target_table text;
begin
  foreach target_table in array array[
    'suppliers','customers','materials','material_purchases','products',
    'production_orders','sales','rentals','supplier_payments',
    'customer_receipts','expenses'
  ] loop
    execute format(
      'create policy %I on public.%I for select to authenticated using ((select auth.uid()) is not null)',
      target_table || '_select_all', target_table
    );
    execute format(
      'create policy %I on public.%I for insert to authenticated with check ((select auth.uid()) is not null)',
      target_table || '_insert_all', target_table
    );
    execute format(
      'create policy %I on public.%I for delete to authenticated using (public.is_manager())',
      target_table || '_delete_manager', target_table
    );
  end loop;
end
$$;

-- Supabase owns the publication. Add each table once without assuming that a
-- project template has already added it.
do $$
declare
  target_table text;
begin
  foreach target_table in array array[
    'suppliers','customers','materials','material_purchases','products',
    'production_orders','sales','rentals','supplier_payments',
    'customer_receipts','expenses'
  ] loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = target_table
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        target_table
      );
    end if;
  end loop;
end
$$;
