-- UAT-004/UAT-005: explicit, auditable customer and supplier advances.
-- Existing rows remain unclassified legacy evidence; all new rows must use protected RPCs.
begin;

alter table public.customer_receipts
  add column if not exists transaction_classification text,
  add column if not exists settlement_amount numeric,
  add column if not exists advance_amount numeric,
  add column if not exists allocated_advance_amount numeric not null default 0,
  add column if not exists status text not null default 'posted',
  add column if not exists command_id uuid,
  add column if not exists reversed_at timestamptz,
  add column if not exists reversed_by uuid references public.profiles(id) on delete set null,
  add column if not exists reversal_reason text;

alter table public.supplier_payments
  add column if not exists transaction_classification text,
  add column if not exists settlement_amount numeric,
  add column if not exists advance_amount numeric,
  add column if not exists allocated_advance_amount numeric not null default 0,
  add column if not exists status text not null default 'posted',
  add column if not exists command_id uuid,
  add column if not exists reversed_at timestamptz,
  add column if not exists reversed_by uuid references public.profiles(id) on delete set null,
  add column if not exists reversal_reason text;

do $constraints$
begin
  if not exists (select 1 from pg_constraint where conname='customer_receipts_advance_contract') then
    alter table public.customer_receipts add constraint customer_receipts_advance_contract check (
      transaction_classification is null or (
        transaction_classification in ('settlement','advance','mixed') and amount > 0
        and settlement_amount >= 0 and advance_amount >= 0
        and settlement_amount + advance_amount = amount
        and allocated_advance_amount between 0 and advance_amount
        and ((transaction_classification='settlement' and settlement_amount=amount and advance_amount=0)
          or (transaction_classification='advance' and settlement_amount=0 and advance_amount=amount)
          or (transaction_classification='mixed' and settlement_amount>0 and advance_amount>0))
      )
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='supplier_payments_advance_contract') then
    alter table public.supplier_payments add constraint supplier_payments_advance_contract check (
      transaction_classification is null or (
        transaction_classification in ('settlement','advance','mixed') and amount > 0
        and settlement_amount >= 0 and advance_amount >= 0
        and settlement_amount + advance_amount = amount
        and allocated_advance_amount between 0 and advance_amount
        and ((transaction_classification='settlement' and settlement_amount=amount and advance_amount=0)
          or (transaction_classification='advance' and settlement_amount=0 and advance_amount=amount)
          or (transaction_classification='mixed' and settlement_amount>0 and advance_amount>0))
      )
    ) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='customer_receipts_status_check') then
    alter table public.customer_receipts add constraint customer_receipts_status_check check (status in ('posted','reversed')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname='supplier_payments_status_check') then
    alter table public.supplier_payments add constraint supplier_payments_status_check check (status in ('posted','reversed')) not valid;
  end if;
end
$constraints$;

create unique index if not exists customer_receipts_command_uidx on public.customer_receipts(command_id) where command_id is not null;
create unique index if not exists supplier_payments_command_uidx on public.supplier_payments(command_id) where command_id is not null;
create index if not exists customer_receipts_advance_idx on public.customer_receipts(customer_id,status) where advance_amount > 0;
create index if not exists supplier_payments_advance_idx on public.supplier_payments(supplier_id,status) where advance_amount > 0;
create index if not exists customer_receipts_reversed_by_idx on public.customer_receipts(reversed_by) where reversed_by is not null;
create index if not exists supplier_payments_reversed_by_idx on public.supplier_payments(reversed_by) where reversed_by is not null;

create table if not exists public.customer_advance_allocations (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.customer_receipts(id) on delete restrict,
  customer_id uuid not null references public.customers(id) on delete restrict,
  target_type text not null check (target_type in ('sale','rental')),
  target_id uuid not null,
  amount numeric not null check (amount > 0),
  status text not null default 'allocated' check (status in ('allocated','reversed')),
  command_id uuid not null unique,
  allocated_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  allocated_at timestamptz not null default now(),
  reversed_by uuid references public.profiles(id) on delete set null,
  reversed_at timestamptz,
  reversal_reason text
);

create table if not exists public.supplier_advance_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.supplier_payments(id) on delete restrict,
  supplier_id uuid not null references public.suppliers(id) on delete restrict,
  target_type text not null check (target_type in ('material_purchase','supplier_invoice')),
  target_id uuid not null,
  amount numeric not null check (amount > 0),
  status text not null default 'allocated' check (status in ('allocated','reversed')),
  command_id uuid not null unique,
  allocated_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  allocated_at timestamptz not null default now(),
  reversed_by uuid references public.profiles(id) on delete set null,
  reversed_at timestamptz,
  reversal_reason text
);

create index if not exists customer_advance_allocations_receipt_idx on public.customer_advance_allocations(receipt_id,status);
create index if not exists customer_advance_allocations_customer_idx on public.customer_advance_allocations(customer_id,status);
create index if not exists supplier_advance_allocations_payment_idx on public.supplier_advance_allocations(payment_id,status);
create index if not exists supplier_advance_allocations_supplier_idx on public.supplier_advance_allocations(supplier_id,status);

alter table public.customer_advance_allocations enable row level security;
alter table public.supplier_advance_allocations enable row level security;
revoke all on public.customer_advance_allocations, public.supplier_advance_allocations from public, anon, authenticated;

create or replace function private.commercial_payment_allowed()
returns boolean language sql stable security invoker set search_path='' as $$
  select auth.uid() is not null and public.current_identity_role() in ('owner','manager','accountant')
$$;

create or replace function private.customer_due(target_customer uuid)
returns numeric language sql stable security invoker set search_path='' as $$
  select greatest(0,
    coalesce((select sum(s.total) from public.sales s where s.customer_id=target_customer and coalesce(s.status,'posted')<>'cancelled'),0)
    + coalesce((select sum(r.rental_fee) from public.rentals r where r.customer_id=target_customer and coalesce(r.status,'active')<>'cancelled'),0)
    - coalesce((select sum(case when cr.transaction_classification is null then cr.amount else cr.settlement_amount + cr.allocated_advance_amount end)
      from public.customer_receipts cr where cr.customer_id=target_customer and cr.status='posted'),0)
  )
$$;

create or replace function private.supplier_due(target_supplier uuid)
returns numeric language sql stable security invoker set search_path='' as $$
  select greatest(0,
    coalesce((select sum(mp.qty*mp.unit_cost) from public.material_purchases mp where mp.supplier_id=target_supplier),0)
    - coalesce((select sum(case when sp.transaction_classification is null then sp.amount else sp.settlement_amount + sp.allocated_advance_amount end)
      from public.supplier_payments sp where sp.supplier_id=target_supplier and sp.status='posted'),0)
  )
$$;

revoke all on function private.commercial_payment_allowed(), private.customer_due(uuid), private.supplier_due(uuid) from public,anon,authenticated;

create or replace function private.guard_classified_cash_history()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
  if tg_op='DELETE' then raise exception using errcode='23514',message='Posted cash history cannot be deleted; use reversal'; end if;
  if coalesce(current_setting('app.commercial_advance_rpc',true),'')<>'on' then
    raise exception using errcode='42501',message='Use the protected classified payment workflow';
  end if;
  return new;
end
$$;
revoke all on function private.guard_classified_cash_history() from public,anon,authenticated;

drop trigger if exists customer_receipts_classified_history on public.customer_receipts;
create trigger customer_receipts_classified_history before insert or update or delete on public.customer_receipts for each row execute function private.guard_classified_cash_history();
drop trigger if exists supplier_payments_classified_history on public.supplier_payments;
create trigger supplier_payments_classified_history before insert or update or delete on public.supplier_payments for each row execute function private.guard_classified_cash_history();

create or replace function public.record_customer_receipt(target_customer uuid,receipt_amount numeric,received_on date,receipt_note text default null,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare due numeric; settled numeric; advanced numeric; class text; saved public.customer_receipts%rowtype;
begin
  if not private.commercial_payment_allowed() then raise exception using errcode='42501',message='Finance payment permission required'; end if;
  if receipt_amount is null or receipt_amount<=0 or receipt_amount='NaN'::numeric then raise exception using errcode='22023',message='Receipt amount must be positive'; end if;
  select * into saved from public.customer_receipts where customer_receipts.command_id=record_customer_receipt.command_id;
  if found then return to_jsonb(saved); end if;
  perform 1 from public.customers where id=target_customer and archived_at is null for update;
  if not found then raise exception using errcode='23503',message='Active customer required'; end if;
  due:=private.customer_due(target_customer); settled:=least(receipt_amount,due); advanced:=receipt_amount-settled;
  class:=case when settled=0 then 'advance' when advanced=0 then 'settlement' else 'mixed' end;
  perform set_config('app.commercial_advance_rpc','on',true);
  insert into public.customer_receipts(customer_id,amount,receipt_date,note,transaction_classification,settlement_amount,advance_amount,command_id,status)
  values(target_customer,receipt_amount,coalesce(received_on,current_date),nullif(btrim(receipt_note),''),class,settled,advanced,command_id,'posted') returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('customer_receipts',saved.id::text,'customer_receipt_classified',auth.uid(),to_jsonb(saved),jsonb_build_object('due_before',due,'classification',class));
  return to_jsonb(saved);
end $$;

create or replace function public.record_supplier_payment(target_supplier uuid,payment_amount numeric,paid_on date,payment_note text default null,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare due numeric; settled numeric; advanced numeric; class text; saved public.supplier_payments%rowtype;
begin
  if not private.commercial_payment_allowed() then raise exception using errcode='42501',message='Finance payment permission required'; end if;
  if payment_amount is null or payment_amount<=0 or payment_amount='NaN'::numeric then raise exception using errcode='22023',message='Payment amount must be positive'; end if;
  select * into saved from public.supplier_payments where supplier_payments.command_id=record_supplier_payment.command_id;
  if found then return to_jsonb(saved); end if;
  perform 1 from public.suppliers where id=target_supplier and archived_at is null for update;
  if not found then raise exception using errcode='23503',message='Active supplier required'; end if;
  due:=private.supplier_due(target_supplier); settled:=least(payment_amount,due); advanced:=payment_amount-settled;
  class:=case when settled=0 then 'advance' when advanced=0 then 'settlement' else 'mixed' end;
  perform set_config('app.commercial_advance_rpc','on',true);
  insert into public.supplier_payments(supplier_id,amount,payment_date,note,transaction_classification,settlement_amount,advance_amount,command_id,status)
  values(target_supplier,payment_amount,coalesce(paid_on,current_date),nullif(btrim(payment_note),''),class,settled,advanced,command_id,'posted') returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('supplier_payments',saved.id::text,'supplier_payment_classified',auth.uid(),to_jsonb(saved),jsonb_build_object('due_before',due,'classification',class));
  return to_jsonb(saved);
end $$;

create or replace function public.allocate_customer_advance(source_receipt uuid,target_type text,target_id uuid,allocation_amount numeric,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare source public.customer_receipts%rowtype; saved public.customer_advance_allocations%rowtype;
begin
  if not private.commercial_payment_allowed() then raise exception using errcode='42501',message='Finance payment permission required'; end if;
  select * into saved from public.customer_advance_allocations where customer_advance_allocations.command_id=allocate_customer_advance.command_id;
  if found then return to_jsonb(saved); end if;
  select * into source from public.customer_receipts where id=source_receipt for update;
  if not found or source.status<>'posted' or source.transaction_classification not in ('advance','mixed') then raise exception 'Posted customer advance required'; end if;
  if allocation_amount is null or allocation_amount<=0 or allocation_amount>source.advance_amount-source.allocated_advance_amount then raise exception 'Allocation exceeds available customer advance'; end if;
  if allocation_amount>private.customer_due(source.customer_id) then raise exception 'Allocation exceeds customer due'; end if;
  if (target_type='sale' and not exists(select 1 from public.sales where id=target_id and customer_id=source.customer_id and status='posted'))
    or (target_type='rental' and not exists(select 1 from public.rentals where id=target_id and customer_id=source.customer_id and status<>'cancelled'))
    or target_type not in ('sale','rental') then raise exception 'Valid customer document required'; end if;
  insert into public.customer_advance_allocations(receipt_id,customer_id,target_type,target_id,amount,command_id)
  values(source.id,source.customer_id,target_type,target_id,allocation_amount,command_id) returning * into saved;
  perform set_config('app.commercial_advance_rpc','on',true);
  update public.customer_receipts set allocated_advance_amount=allocated_advance_amount+allocation_amount where id=source.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('customer_advance_allocations',saved.id::text,'customer_advance_allocated',auth.uid(),to_jsonb(saved),jsonb_build_object('receipt_id',source.id));
  return to_jsonb(saved);
end $$;

create or replace function public.allocate_supplier_advance(source_payment uuid,target_type text,target_id uuid,allocation_amount numeric,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare source public.supplier_payments%rowtype; saved public.supplier_advance_allocations%rowtype;
begin
  if not private.commercial_payment_allowed() then raise exception using errcode='42501',message='Finance payment permission required'; end if;
  select * into saved from public.supplier_advance_allocations where supplier_advance_allocations.command_id=allocate_supplier_advance.command_id;
  if found then return to_jsonb(saved); end if;
  select * into source from public.supplier_payments where id=source_payment for update;
  if not found or source.status<>'posted' or source.transaction_classification not in ('advance','mixed') then raise exception 'Posted supplier advance required'; end if;
  if allocation_amount is null or allocation_amount<=0 or allocation_amount>source.advance_amount-source.allocated_advance_amount then raise exception 'Allocation exceeds available supplier advance'; end if;
  if allocation_amount>private.supplier_due(source.supplier_id) then raise exception 'Allocation exceeds supplier due'; end if;
  if (target_type='material_purchase' and not exists(select 1 from public.material_purchases where id=target_id and supplier_id=source.supplier_id))
    or (target_type='supplier_invoice' and not exists(select 1 from public.supplier_invoices where id=target_id and supplier_id=source.supplier_id and status in ('approved','paid')))
    or target_type not in ('material_purchase','supplier_invoice') then raise exception 'Valid supplier document required'; end if;
  insert into public.supplier_advance_allocations(payment_id,supplier_id,target_type,target_id,amount,command_id)
  values(source.id,source.supplier_id,target_type,target_id,allocation_amount,command_id) returning * into saved;
  perform set_config('app.commercial_advance_rpc','on',true);
  update public.supplier_payments set allocated_advance_amount=allocated_advance_amount+allocation_amount where id=source.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('supplier_advance_allocations',saved.id::text,'supplier_advance_allocated',auth.uid(),to_jsonb(saved),jsonb_build_object('payment_id',source.id));
  return to_jsonb(saved);
end $$;

create or replace function public.reverse_classified_cash_transaction(transaction_type text,target_id uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); result jsonb;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if nullif(btrim(reason),'') is null then raise exception 'Reversal reason required'; end if;
  perform set_config('app.commercial_advance_rpc','on',true);
  if transaction_type='customer_receipt' then
    if exists(select 1 from public.customer_advance_allocations where receipt_id=target_id and status='allocated') then raise exception 'Reverse customer advance allocations first'; end if;
    update public.customer_receipts set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=target_id and status='posted' returning to_jsonb(customer_receipts.*) into result;
  elsif transaction_type='supplier_payment' then
    if exists(select 1 from public.supplier_advance_allocations where payment_id=target_id and status='allocated') then raise exception 'Reverse supplier advance allocations first'; end if;
    update public.supplier_payments set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=target_id and status='posted' returning to_jsonb(supplier_payments.*) into result;
  else raise exception 'Unsupported cash transaction type'; end if;
  if result is null then raise exception 'Posted transaction not found or already reversed'; end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(transaction_type,target_id::text,'cash_transaction_reversed',actor,result,jsonb_build_object('reason',btrim(reason)));
  return result;
end $$;

create or replace function public.reverse_advance_allocation(allocation_type text,target_id uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); allocation jsonb; source_id uuid; allocation_value numeric;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if nullif(btrim(reason),'') is null then raise exception 'Allocation reversal reason required'; end if;
  perform set_config('app.commercial_advance_rpc','on',true);
  if allocation_type='customer' then
    update public.customer_advance_allocations set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=target_id and status='allocated'
    returning receipt_id,amount,to_jsonb(customer_advance_allocations.*) into source_id,allocation_value,allocation;
    if allocation is not null then
      update public.customer_receipts set allocated_advance_amount=greatest(0,allocated_advance_amount-allocation_value) where id=source_id;
    end if;
  elsif allocation_type='supplier' then
    update public.supplier_advance_allocations set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=target_id and status='allocated'
    returning payment_id,amount,to_jsonb(supplier_advance_allocations.*) into source_id,allocation_value,allocation;
    if allocation is not null then
      update public.supplier_payments set allocated_advance_amount=greatest(0,allocated_advance_amount-allocation_value) where id=source_id;
    end if;
  else raise exception 'Unsupported advance allocation type'; end if;
  if allocation is null then raise exception 'Active allocation not found or already reversed'; end if;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(allocation_type||'_advance_allocations',target_id::text,'advance_allocation_reversed',actor,allocation,jsonb_build_object('reason',btrim(reason),'source_id',source_id));
  return allocation;
end $$;

revoke all on function public.record_customer_receipt(uuid,numeric,date,text,uuid), public.record_supplier_payment(uuid,numeric,date,text,uuid),
  public.allocate_customer_advance(uuid,text,uuid,numeric,uuid), public.allocate_supplier_advance(uuid,text,uuid,numeric,uuid),
  public.reverse_classified_cash_transaction(text,uuid,text), public.reverse_advance_allocation(text,uuid,text) from public,anon;
grant execute on function public.record_customer_receipt(uuid,numeric,date,text,uuid), public.record_supplier_payment(uuid,numeric,date,text,uuid),
  public.allocate_customer_advance(uuid,text,uuid,numeric,uuid), public.allocate_supplier_advance(uuid,text,uuid,numeric,uuid),
  public.reverse_classified_cash_transaction(text,uuid,text), public.reverse_advance_allocation(text,uuid,text) to authenticated;

comment on column public.customer_receipts.transaction_classification is 'NULL denotes preserved legacy data; every new protected receipt is settlement, advance, or mixed.';
comment on column public.supplier_payments.transaction_classification is 'NULL denotes preserved legacy data; every new protected payment is settlement, advance, or mixed.';

commit;
