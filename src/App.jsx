alter table products add column if not exists item_type text not null default 'sale'
  check (item_type in ('sale','rental','both'));

create table if not exists rentals (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references products(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  qty numeric not null,
  rental_fee numeric not null default 0,
  start_date date,
  expected_return_date date,
  return_date date,
  status text not null default 'active' check (status in ('active','returned')),
  note text,
  created_at timestamptz default now()
);

alter table rentals enable row level security;

create policy "rentals_select_all" on rentals for select using (auth.role() = 'authenticated');
create policy "rentals_insert_all" on rentals for insert with check (auth.role() = 'authenticated');
create policy "rentals_update_all" on rentals for update using (auth.role() = 'authenticated');
create policy "rentals_delete_manager" on rentals for delete using (is_manager());

alter publication supabase_realtime add table rentals;

create policy "profiles_update_manager" on profiles for update using (is_manager());

create policy "materials_update_all" on materials for update using (auth.role() = 'authenticated');
create policy "products_update_all" on products for update using (auth.role() = 'authenticated');
create policy "suppliers_update_all" on suppliers for update using (auth.role() = 'authenticated');
create policy "customers_update_all" on customers for update using (auth.role() = 'authenticated');
