-- Pilot blockers: customer/supplier advance and cash reversals failed because
-- target_id was ambiguous inside PL/pgSQL statements that also referenced
-- allocation tables containing a target_id column. Copy the argument into a
-- distinctly named local variable and use that variable in every statement.

create or replace function public.reverse_advance_allocation(
  allocation_type text,
  target_id uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  requested_id uuid:=target_id;
  allocation jsonb;
  source_id uuid;
  allocation_value numeric;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception 'Allocation reversal reason required';
  end if;

  perform set_config('app.commercial_advance_rpc','on',true);

  if allocation_type='customer' then
    update public.customer_advance_allocations
    set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=requested_id and status='allocated'
    returning receipt_id,amount,to_jsonb(customer_advance_allocations.*)
      into source_id,allocation_value,allocation;

    if allocation is not null then
      update public.customer_receipts
      set allocated_advance_amount=greatest(0,allocated_advance_amount-allocation_value)
      where id=source_id;
    end if;
  elsif allocation_type='supplier' then
    update public.supplier_advance_allocations
    set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=requested_id and status='allocated'
    returning payment_id,amount,to_jsonb(supplier_advance_allocations.*)
      into source_id,allocation_value,allocation;

    if allocation is not null then
      update public.supplier_payments
      set allocated_advance_amount=greatest(0,allocated_advance_amount-allocation_value)
      where id=source_id;
    end if;
  else
    raise exception 'Unsupported advance allocation type';
  end if;

  if allocation is null then
    raise exception 'Active allocation not found or already reversed';
  end if;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    allocation_type||'_advance_allocations',requested_id::text,
    'advance_allocation_reversed',actor,allocation,
    jsonb_build_object('reason',btrim(reason),'source_id',source_id)
  );

  return allocation;
end
$$;

create or replace function public.reverse_classified_cash_transaction(
  transaction_type text,
  target_id uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  requested_id uuid:=target_id;
  result jsonb;
begin
  if actor is null or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception 'Reversal reason required';
  end if;

  perform set_config('app.commercial_advance_rpc','on',true);

  if transaction_type='customer_receipt' then
    if exists(
      select 1 from public.customer_advance_allocations a
      where a.receipt_id=requested_id and a.status='allocated'
    ) then
      raise exception 'Reverse customer advance allocations first';
    end if;

    update public.customer_receipts
    set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=requested_id and status='posted'
    returning to_jsonb(customer_receipts.*) into result;
  elsif transaction_type='supplier_payment' then
    if exists(
      select 1 from public.supplier_advance_allocations a
      where a.payment_id=requested_id and a.status='allocated'
    ) then
      raise exception 'Reverse supplier advance allocations first';
    end if;

    update public.supplier_payments
    set status='reversed',reversed_at=now(),reversed_by=actor,reversal_reason=btrim(reason)
    where id=requested_id and status='posted'
    returning to_jsonb(supplier_payments.*) into result;
  else
    raise exception 'Unsupported cash transaction type';
  end if;

  if result is null then
    raise exception 'Posted transaction not found or already reversed';
  end if;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    transaction_type,requested_id::text,'cash_transaction_reversed',actor,result,
    jsonb_build_object('reason',btrim(reason))
  );

  return result;
end
$$;

revoke all on function public.reverse_advance_allocation(text,uuid,text) from public,anon;
revoke all on function public.reverse_classified_cash_transaction(text,uuid,text) from public,anon;
grant execute on function public.reverse_advance_allocation(text,uuid,text) to authenticated;
grant execute on function public.reverse_classified_cash_transaction(text,uuid,text) to authenticated;
