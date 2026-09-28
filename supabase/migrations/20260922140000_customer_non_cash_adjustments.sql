-- Final V1: non-cash customer deductions/adjustments.
-- Adjustments reduce customer receivables without being misclassified as cash receipts or advances.

create table if not exists public.customer_adjustments (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id),
  adjustment_date date not null default current_date,
  adjustment_type text not null check (adjustment_type in (
    'commercial_discount','withholding_tax','retention','bank_charge','other'
  )),
  amount numeric(18,2) not null check (amount > 0),
  reason text not null check (length(btrim(reason)) > 0),
  status text not null default 'posted' check (status in ('posted','reversed')),
  command_id uuid,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  reversed_by uuid references public.profiles(id),
  reversed_at timestamptz,
  reversal_reason text
);

create unique index if not exists customer_adjustments_command_uidx
  on public.customer_adjustments(command_id)
  where command_id is not null;
create index if not exists customer_adjustments_customer_status_idx
  on public.customer_adjustments(customer_id,status,adjustment_date desc);

alter table public.customer_adjustments enable row level security;

drop policy if exists customer_adjustments_select on public.customer_adjustments;
create policy customer_adjustments_select
on public.customer_adjustments
for select
to authenticated
using (
  public.is_current_profile_active()
  and public.current_identity_role() in ('owner','manager','accountant')
);

revoke insert,update,delete on public.customer_adjustments from anon,authenticated;
grant select on public.customer_adjustments to authenticated;

create or replace function private.customer_due(target_customer uuid)
returns numeric
language sql
stable
security invoker
set search_path=''
as $$
  select greatest(0,
    coalesce((
      select sum(s.total)
      from public.sales s
      where s.customer_id=target_customer
        and coalesce(s.status,'posted')<>'cancelled'
    ),0)
    + coalesce((
      select sum(r.rental_fee)
      from public.rentals r
      where r.customer_id=target_customer
        and coalesce(r.status,'active')<>'cancelled'
    ),0)
    + coalesce((
      select sum(p.revenue)
      from public.projects p
      where p.customer_id=target_customer
        and p.lifecycle='closed'
        and coalesce(p.revenue,0)>0
    ),0)
    - coalesce((
      select sum(
        case when cr.transaction_classification is null
          then cr.amount
          else cr.settlement_amount + cr.allocated_advance_amount
        end
      )
      from public.customer_receipts cr
      where cr.customer_id=target_customer
        and cr.status='posted'
    ),0)
    - coalesce((
      select sum(ca.amount)
      from public.customer_adjustments ca
      where ca.customer_id=target_customer
        and ca.status='posted'
    ),0)
  )
$$;

create or replace function public.record_customer_adjustment(
  target_customer uuid,
  adjustment_amount numeric,
  adjustment_kind text,
  adjustment_reason text,
  adjusted_on date default current_date,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  due numeric;
  saved public.customer_adjustments%rowtype;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if adjustment_amount is null or adjustment_amount<=0 or adjustment_amount='NaN'::numeric then
    raise exception using errcode='22023',message='Adjustment amount must be positive';
  end if;
  if adjustment_kind not in ('commercial_discount','withholding_tax','retention','bank_charge','other') then
    raise exception using errcode='22023',message='Unsupported customer adjustment type';
  end if;
  if nullif(btrim(adjustment_reason),'') is null then
    raise exception using errcode='22023',message='Adjustment reason is required';
  end if;
  if command_id is null then
    raise exception using errcode='22023',message='Command id is required';
  end if;

  select * into saved
  from public.customer_adjustments ca
  where ca.command_id=record_customer_adjustment.command_id;
  if found then return to_jsonb(saved); end if;

  perform 1
  from public.customers c
  where c.id=target_customer and c.archived_at is null
  for update;
  if not found then
    raise exception using errcode='23503',message='Active customer required';
  end if;

  due:=private.customer_due(target_customer);
  if due<=0 then
    raise exception using errcode='23514',message='Customer has no outstanding balance to adjust';
  end if;
  if adjustment_amount>due then
    raise exception using errcode='23514',message='Adjustment cannot exceed current customer due';
  end if;

  insert into public.customer_adjustments(
    customer_id,adjustment_date,adjustment_type,amount,reason,status,command_id,created_by
  ) values(
    target_customer,coalesce(adjusted_on,current_date),adjustment_kind,round(adjustment_amount,2),
    btrim(adjustment_reason),'posted',command_id,auth.uid()
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'customer_adjustments',saved.id::text,'customer_adjustment_posted',auth.uid(),to_jsonb(saved),
    jsonb_build_object('non_cash',true,'customer_due_before',due,'customer_due_after',greatest(0,due-saved.amount))
  );

  return to_jsonb(saved);
end
$$;

create or replace function public.reverse_customer_adjustment(
  target_adjustment uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  saved public.customer_adjustments%rowtype;
begin
  if auth.uid() is null or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception using errcode='22023',message='Reversal reason is required';
  end if;

  update public.customer_adjustments
  set status='reversed',
      reversed_by=auth.uid(),
      reversed_at=now(),
      reversal_reason=btrim(reason)
  where id=target_adjustment
    and status='posted'
  returning * into saved;

  if not found then
    raise exception using errcode='P0002',message='Posted customer adjustment was not found';
  end if;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'customer_adjustments',saved.id::text,'customer_adjustment_reversed',auth.uid(),
    null,to_jsonb(saved),jsonb_build_object('non_cash',true,'reversal_reason',saved.reversal_reason)
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.record_customer_adjustment(uuid,numeric,text,text,date,uuid) from public,anon;
grant execute on function public.record_customer_adjustment(uuid,numeric,text,text,date,uuid) to authenticated;
revoke all on function public.reverse_customer_adjustment(uuid,text) from public,anon;
grant execute on function public.reverse_customer_adjustment(uuid,text) to authenticated;

do $$
begin
  if exists(select 1 from pg_publication where pubname='supabase_realtime')
     and not exists(
       select 1 from pg_publication_tables
       where pubname='supabase_realtime'
         and schemaname='public'
         and tablename='customer_adjustments'
     ) then
    alter publication supabase_realtime add table public.customer_adjustments;
  end if;
end
$$;
