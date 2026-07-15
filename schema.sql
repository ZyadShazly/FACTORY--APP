-- ============================================================
-- شغّل الكود ده كله مرة واحدة في Supabase: SQL Editor -> New query -> الصق كله -> Run
-- ============================================================

-- جدول الأدوار (كل مستخدم مسجل بياناته هنا: مدير / محاسب / موظف إنتاج)
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  role text not null check (role in ('manager','accountant','production')),
  created_at timestamptz default now()
);

create table if not exists suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  created_at timestamptz default now()
);

create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  created_at timestamptz default now()
);

create table if not exists materials (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  unit text,
  unit_cost numeric default 0,
  initial_stock numeric default 0,
  created_at timestamptz default now()
);

create table if not exists material_purchases (
  id uuid primary key default gen_random_uuid(),
  material_id uuid references materials(id) on delete cascade,
  supplier_id uuid references suppliers(id) on delete set null,
  qty numeric not null,
  unit_cost numeric not null,
  purchase_date date,
  note text,
  created_at timestamptz default now()
);

create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sku text,
  bom jsonb default '[]',
  labor_cost numeric default 0,
  overhead_cost numeric default 0,
  selling_price numeric default 0,
  created_at timestamptz default now()
);

create table if not exists production_orders (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references products(id) on delete cascade,
  qty numeric not null,
  materials_cost numeric default 0,
  labor_cost numeric default 0,
  overhead_cost numeric default 0,
  total_cost numeric default 0,
  unit_cost numeric default 0,
  order_date date,
  note text,
  created_at timestamptz default now()
);

create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references products(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  qty numeric not null,
  unit_price numeric not null,
  total numeric not null,
  sale_date date,
  note text,
  created_at timestamptz default now()
);

create table if not exists supplier_payments (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid references suppliers(id) on delete cascade,
  amount numeric not null,
  payment_date date,
  note text,
  created_at timestamptz default now()
);

create table if not exists customer_receipts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references customers(id) on delete cascade,
  amount numeric not null,
  receipt_date date,
  note text,
  created_at timestamptz default now()
);

-- ============================================================
-- دالة بسيطة تتأكد هل المستخدم الحالي "مدير" ولا لأ
-- ============================================================
create or replace function is_manager()
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'manager'
  );
$$;

-- ============================================================
-- تفعيل الحماية (Row Level Security) على كل الجداول
-- ============================================================
alter table profiles enable row level security;
alter table suppliers enable row level security;
alter table customers enable row level security;
alter table materials enable row level security;
alter table material_purchases enable row level security;
alter table products enable row level security;
alter table production_orders enable row level security;
alter table sales enable row level security;
alter table supplier_payments enable row level security;
alter table customer_receipts enable row level security;

-- profiles: أي حد مسجل يقدر يشوف كل البروفايلات، ويضيف/يعدّل بروفايله هو بس
create policy "profiles_select_all" on profiles for select using (auth.role() = 'authenticated');
create policy "profiles_insert_own" on profiles for insert
  with check (auth.uid() = id and role in ('accountant','production'));
create policy "profiles_update_own" on profiles for update using (auth.uid() = id);

-- Roles are protected in the database, not only by the signup form. A new user
-- may register as accountant/production; only a manager may change another
-- user's role, and service_role represents system-owner automation.
create or replace function enforce_profile_role_security()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.role() = 'service_role' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if auth.uid() is null
       or new.id is distinct from auth.uid()
       or new.role not in ('accountant', 'production') then
      raise exception using errcode = '42501', message = 'Self-service registration cannot create a protected role';
    end if;
  elsif new.role is distinct from old.role then
    if auth.uid() = old.id then
      raise exception using errcode = '42501', message = 'Users cannot change their own role';
    end if;
    if not is_manager() then
      raise exception using errcode = '42501', message = 'Only a manager or the system owner can change roles';
    end if;
  end if;

  return new;
end
$$;

revoke all on function enforce_profile_role_security() from public, anon, authenticated;
create trigger enforce_profile_role_security
before insert or update of role on profiles
for each row execute function enforce_profile_role_security();

-- باقي الجداول: أي حد مسجل يقدر يشوف ويضيف، والحذف للمدير بس
do $$
declare
  t text;
begin
  foreach t in array array['suppliers','customers','materials','material_purchases','products','production_orders','sales','supplier_payments','customer_receipts']
  loop
    execute format('create policy "%s_select_all" on %I for select using (auth.role() = ''authenticated'')', t, t);
    execute format('create policy "%s_insert_all" on %I for insert with check (auth.role() = ''authenticated'')', t, t);
    execute format('create policy "%s_delete_manager" on %I for delete using (is_manager())', t, t);
  end loop;
end $$;

-- ============================================================
-- تفعيل Realtime عشان أي تحديث يظهر عند الكل فورًا
-- ============================================================
alter publication supabase_realtime add table
  suppliers, customers, materials, material_purchases,
  products, production_orders, sales, supplier_payments, customer_receipts;
