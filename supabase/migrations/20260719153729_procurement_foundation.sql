-- Procure-to-Pay foundation: requests, quotes, orders, receipts, and supplier invoices.
-- Additive only. No legacy procurement data is rewritten.

begin;

create table if not exists public.purchase_requests (
  id uuid primary key default gen_random_uuid(),
  request_number text not null unique default ('PR-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8))),
  project_id uuid references public.projects(id) on delete restrict,
  requested_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  department_id uuid references public.departments(id) on delete set null,
  required_date date,
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  status text not null default 'draft' check (status in ('draft','submitted','approved','rejected','cancelled','converted')),
  justification text,
  rejection_reason text,
  submitted_at timestamptz,
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  rejected_by uuid references public.profiles(id) on delete set null,
  rejected_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.purchase_request_items (
  id uuid primary key default gen_random_uuid(),
  purchase_request_id uuid not null references public.purchase_requests(id) on delete cascade,
  material_id uuid references public.materials(id) on delete set null,
  description text not null check (btrim(description)<>''),
  quantity numeric not null check (quantity>0),
  unit text not null default 'وحدة',
  estimated_unit_cost numeric not null default 0 check (estimated_unit_cost>=0),
  estimated_total numeric generated always as (round(quantity*estimated_unit_cost,2)) stored,
  budget_item_id uuid references public.project_budget_items(id) on delete set null,
  milestone_id uuid references public.project_milestones(id) on delete set null,
  cost_center_reference text,
  notes text,
  sequence integer not null default 0 check (sequence>=0),
  created_at timestamptz not null default now()
);

create table if not exists public.supplier_quotes (
  id uuid primary key default gen_random_uuid(),
  quote_number text not null unique default ('RFQ-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8))),
  purchase_request_id uuid not null references public.purchase_requests(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  supplier_reference text,
  quote_date date not null default current_date,
  valid_until date,
  currency text not null default 'SAR' check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'draft' check (status in ('draft','received','selected','rejected','expired','cancelled')),
  payment_terms text,
  delivery_days integer check (delivery_days is null or delivery_days>=0),
  notes text,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(purchase_request_id,supplier_id,supplier_reference)
);

create table if not exists public.supplier_quote_items (
  id uuid primary key default gen_random_uuid(),
  supplier_quote_id uuid not null references public.supplier_quotes(id) on delete cascade,
  purchase_request_item_id uuid not null references public.purchase_request_items(id) on delete restrict,
  quantity numeric not null check (quantity>0),
  unit_price numeric not null check (unit_price>=0),
  discount_amount numeric not null default 0 check (discount_amount>=0),
  tax_amount numeric not null default 0 check (tax_amount>=0),
  line_total numeric generated always as (round((quantity*unit_price)-discount_amount+tax_amount,2)) stored,
  notes text,
  unique(supplier_quote_id,purchase_request_item_id)
);

create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('PO-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8))),
  purchase_request_id uuid references public.purchase_requests(id) on delete restrict,
  selected_quote_id uuid references public.supplier_quotes(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  project_id uuid references public.projects(id) on delete restrict,
  currency text not null default 'SAR' check (currency ~ '^[A-Z]{3}$'),
  order_date date not null default current_date,
  expected_delivery_date date,
  status text not null default 'draft' check (status in ('draft','submitted','approved','sent','partially_received','fully_received','invoiced','closed','cancelled')),
  subtotal numeric not null default 0 check (subtotal>=0),
  discount_amount numeric not null default 0 check (discount_amount>=0),
  tax_amount numeric not null default 0 check (tax_amount>=0),
  total_amount numeric not null default 0 check (total_amount>=0),
  payment_terms text,
  notes text,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  purchase_request_item_id uuid references public.purchase_request_items(id) on delete set null,
  material_id uuid references public.materials(id) on delete set null,
  description text not null check (btrim(description)<>''),
  quantity numeric not null check (quantity>0),
  unit text not null default 'وحدة',
  unit_price numeric not null check (unit_price>=0),
  discount_amount numeric not null default 0 check (discount_amount>=0),
  tax_amount numeric not null default 0 check (tax_amount>=0),
  line_total numeric generated always as (round((quantity*unit_price)-discount_amount+tax_amount,2)) stored,
  received_quantity numeric not null default 0 check (received_quantity>=0 and received_quantity<=quantity),
  budget_item_id uuid references public.project_budget_items(id) on delete set null,
  milestone_id uuid references public.project_milestones(id) on delete set null,
  cost_center_reference text,
  sequence integer not null default 0 check (sequence>=0),
  unique(purchase_order_id,sequence)
);

create table if not exists public.goods_receipts (
  id uuid primary key default gen_random_uuid(),
  receipt_number text not null unique default ('GRN-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8))),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete restrict,
  received_at timestamptz not null default now(),
  received_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  status text not null default 'draft' check (status in ('draft','confirmed','cancelled','reversed')),
  supplier_delivery_reference text,
  notes text,
  confirmed_by uuid references public.profiles(id) on delete set null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.goods_receipt_items (
  id uuid primary key default gen_random_uuid(),
  goods_receipt_id uuid not null references public.goods_receipts(id) on delete cascade,
  purchase_order_item_id uuid not null references public.purchase_order_items(id) on delete restrict,
  quantity_received numeric not null check (quantity_received>0),
  accepted_quantity numeric not null default 0 check (accepted_quantity>=0 and accepted_quantity<=quantity_received),
  rejected_quantity numeric generated always as (quantity_received-accepted_quantity) stored,
  condition text not null default 'accepted' check (condition in ('accepted','partially_rejected','rejected','damaged')),
  notes text,
  unique(goods_receipt_id,purchase_order_item_id)
);

create table if not exists public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  invoice_number text not null,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  purchase_order_id uuid references public.purchase_orders(id) on delete restrict,
  project_id uuid references public.projects(id) on delete restrict,
  invoice_date date not null,
  due_date date,
  currency text not null default 'SAR' check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'draft' check (status in ('draft','submitted','matched','approved','rejected','paid','cancelled','reversed')),
  subtotal numeric not null default 0 check (subtotal>=0),
  discount_amount numeric not null default 0 check (discount_amount>=0),
  tax_amount numeric not null default 0 check (tax_amount>=0),
  total_amount numeric not null default 0 check (total_amount>=0),
  match_status text not null default 'not_matched' check (match_status in ('not_matched','matched','quantity_variance','price_variance','both_variance')),
  notes text,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(supplier_id,invoice_number)
);

create table if not exists public.supplier_invoice_lines (
  id uuid primary key default gen_random_uuid(),
  supplier_invoice_id uuid not null references public.supplier_invoices(id) on delete cascade,
  purchase_order_item_id uuid references public.purchase_order_items(id) on delete set null,
  goods_receipt_item_id uuid references public.goods_receipt_items(id) on delete set null,
  description text not null check (btrim(description)<>''),
  quantity numeric not null check (quantity>0),
  unit_price numeric not null check (unit_price>=0),
  discount_amount numeric not null default 0 check (discount_amount>=0),
  tax_amount numeric not null default 0 check (tax_amount>=0),
  line_total numeric generated always as (round((quantity*unit_price)-discount_amount+tax_amount,2)) stored,
  budget_item_id uuid references public.project_budget_items(id) on delete set null,
  milestone_id uuid references public.project_milestones(id) on delete set null,
  cost_center_reference text,
  actual_cost_entry_id uuid references public.project_actual_cost_entries(id) on delete set null
);

alter table public.purchase_requests enable row level security;
alter table public.purchase_request_items enable row level security;
alter table public.supplier_quotes enable row level security;
alter table public.supplier_quote_items enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.goods_receipts enable row level security;
alter table public.goods_receipt_items enable row level security;
alter table public.supplier_invoices enable row level security;
alter table public.supplier_invoice_lines enable row level security;

revoke all on public.purchase_requests,public.purchase_request_items,public.supplier_quotes,public.supplier_quote_items,
  public.purchase_orders,public.purchase_order_items,public.goods_receipts,public.goods_receipt_items,
  public.supplier_invoices,public.supplier_invoice_lines from anon,authenticated;

create index if not exists purchase_requests_project_idx on public.purchase_requests(project_id) where project_id is not null;
create index if not exists purchase_request_items_request_idx on public.purchase_request_items(purchase_request_id);
create index if not exists supplier_quotes_request_idx on public.supplier_quotes(purchase_request_id);
create index if not exists supplier_quotes_supplier_idx on public.supplier_quotes(supplier_id);
create index if not exists supplier_quote_items_quote_idx on public.supplier_quote_items(supplier_quote_id);
create index if not exists purchase_orders_project_idx on public.purchase_orders(project_id) where project_id is not null;
create index if not exists purchase_orders_supplier_idx on public.purchase_orders(supplier_id);
create index if not exists purchase_order_items_order_idx on public.purchase_order_items(purchase_order_id);
create index if not exists goods_receipts_order_idx on public.goods_receipts(purchase_order_id);
create index if not exists goods_receipt_items_receipt_idx on public.goods_receipt_items(goods_receipt_id);
create index if not exists supplier_invoices_order_idx on public.supplier_invoices(purchase_order_id) where purchase_order_id is not null;
create index if not exists supplier_invoices_project_idx on public.supplier_invoices(project_id) where project_id is not null;
create index if not exists supplier_invoice_lines_invoice_idx on public.supplier_invoice_lines(supplier_invoice_id);

commit;