-- Complete the customer/supplier advance workflow introduced by 202608101210.
-- Additive only: exposes a protected workspace, caps allocations per document,
-- and prevents cancelling a document while an active allocation points to it.
begin;

create or replace function private.customer_advance_target_remaining(target_type text,target_id uuid,target_customer uuid)
returns numeric
language sql
stable
security invoker
set search_path=''
as $$
  select greatest(0, coalesce(case
    when target_type='sale' then (
      select s.total from public.sales s
      where s.id=target_id and s.customer_id=target_customer and s.status='posted'
    )
    when target_type='rental' then (
      select r.rental_fee from public.rentals r
      where r.id=target_id and r.customer_id=target_customer and r.status<>'cancelled'
    )
  end,0) - coalesce((
    select sum(a.amount) from public.customer_advance_allocations a
    where a.target_type=customer_advance_target_remaining.target_type
      and a.target_id=customer_advance_target_remaining.target_id
      and a.status='allocated'
  ),0))
$$;

create or replace function private.supplier_advance_target_remaining(target_type text,target_id uuid,target_supplier uuid)
returns numeric
language sql
stable
security invoker
set search_path=''
as $$
  select greatest(0, coalesce(case
    when target_type='material_purchase' then (
      select mp.qty*mp.unit_cost from public.material_purchases mp
      where mp.id=target_id and mp.supplier_id=target_supplier
    )
    when target_type='supplier_invoice' then (
      select si.total_amount from public.supplier_invoices si
      where si.id=target_id and si.supplier_id=target_supplier and si.status in ('approved','paid')
    )
  end,0) - coalesce((
    select sum(a.amount) from public.supplier_advance_allocations a
    where a.target_type=supplier_advance_target_remaining.target_type
      and a.target_id=supplier_advance_target_remaining.target_id
      and a.status='allocated'
  ),0))
$$;

revoke all on function private.customer_advance_target_remaining(text,uuid,uuid),
  private.supplier_advance_target_remaining(text,uuid,uuid) from public,anon,authenticated;

create or replace function public.get_commercial_advance_workspace(party_type text,target_party uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare result jsonb;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if party_type='customer' then
    if not exists(select 1 from public.customers where id=target_party) then raise exception 'Customer not found'; end if;
    select jsonb_build_object(
      'party_type','customer','party_id',target_party,'due',private.customer_due(target_party),
      'sources',coalesce((select jsonb_agg(jsonb_build_object(
        'id',r.id,'date',r.receipt_date,'amount',r.amount,'classification',r.transaction_classification,
        'advance_amount',r.advance_amount,'allocated_amount',r.allocated_advance_amount,
        'available_amount',r.advance_amount-r.allocated_advance_amount
      ) order by r.receipt_date,r.created_at)
      from public.customer_receipts r where r.customer_id=target_party and r.status='posted'
        and coalesce(r.advance_amount,0)>coalesce(r.allocated_advance_amount,0)),'[]'::jsonb),
      'targets',coalesce((select jsonb_agg(target order by target->>'date',target->>'label') from (
        select jsonb_build_object('type','sale','id',s.id,'date',s.sale_date,'label','بيع · '||coalesce(p.name,'منتج'),
          'document_amount',s.total,'remaining_amount',private.customer_advance_target_remaining('sale',s.id,target_party)) target
        from public.sales s left join public.products p on p.id=s.product_id
        where s.customer_id=target_party and s.status='posted'
          and private.customer_advance_target_remaining('sale',s.id,target_party)>0
        union all
        select jsonb_build_object('type','rental','id',r.id,'date',r.start_date,'label','إيجار · '||coalesce(p.name,'منتج'),
          'document_amount',r.rental_fee,'remaining_amount',private.customer_advance_target_remaining('rental',r.id,target_party)) target
        from public.rentals r left join public.products p on p.id=r.product_id
        where r.customer_id=target_party and r.status<>'cancelled'
          and private.customer_advance_target_remaining('rental',r.id,target_party)>0
      ) targets),'[]'::jsonb),
      'allocations',coalesce((select jsonb_agg(jsonb_build_object(
        'id',a.id,'source_id',a.receipt_id,'target_type',a.target_type,'target_id',a.target_id,
        'amount',a.amount,'status',a.status,'allocated_at',a.allocated_at,
        'reversed_at',a.reversed_at,'reversal_reason',a.reversal_reason,
        'target_label',case when a.target_type='sale' then 'بيع' else 'إيجار' end
      ) order by a.allocated_at desc) from public.customer_advance_allocations a where a.customer_id=target_party),'[]'::jsonb),
      'transactions',coalesce((select jsonb_agg(jsonb_build_object(
        'id',r.id,'date',r.receipt_date,'amount',r.amount,'classification',r.transaction_classification,
        'settlement_amount',r.settlement_amount,'advance_amount',r.advance_amount,'status',r.status,
        'reversed_at',r.reversed_at,'reversal_reason',r.reversal_reason,
        'has_active_allocations',exists(select 1 from public.customer_advance_allocations a where a.receipt_id=r.id and a.status='allocated')
      ) order by r.receipt_date desc,r.created_at desc) from public.customer_receipts r
      where r.customer_id=target_party and r.transaction_classification is not null),'[]'::jsonb)
    ) into result;
  elsif party_type='supplier' then
    if not exists(select 1 from public.suppliers where id=target_party) then raise exception 'Supplier not found'; end if;
    select jsonb_build_object(
      'party_type','supplier','party_id',target_party,'due',private.supplier_due(target_party),
      'sources',coalesce((select jsonb_agg(jsonb_build_object(
        'id',p.id,'date',p.payment_date,'amount',p.amount,'classification',p.transaction_classification,
        'advance_amount',p.advance_amount,'allocated_amount',p.allocated_advance_amount,
        'available_amount',p.advance_amount-p.allocated_advance_amount
      ) order by p.payment_date,p.created_at)
      from public.supplier_payments p where p.supplier_id=target_party and p.status='posted'
        and coalesce(p.advance_amount,0)>coalesce(p.allocated_advance_amount,0)),'[]'::jsonb),
      'targets',coalesce((select jsonb_agg(target order by target->>'date',target->>'label') from (
        select jsonb_build_object('type','material_purchase','id',mp.id,'date',mp.purchase_date,
          'label','شراء مباشر · '||coalesce(m.name,'مادة'),'document_amount',mp.qty*mp.unit_cost,
          'remaining_amount',private.supplier_advance_target_remaining('material_purchase',mp.id,target_party)) target
        from public.material_purchases mp left join public.materials m on m.id=mp.material_id
        where mp.supplier_id=target_party and private.supplier_advance_target_remaining('material_purchase',mp.id,target_party)>0
        union all
        select jsonb_build_object('type','supplier_invoice','id',si.id,'date',si.invoice_date,
          'label','فاتورة · '||si.invoice_number,'document_amount',si.total_amount,
          'remaining_amount',private.supplier_advance_target_remaining('supplier_invoice',si.id,target_party)) target
        from public.supplier_invoices si where si.supplier_id=target_party and si.status in ('approved','paid')
          and private.supplier_advance_target_remaining('supplier_invoice',si.id,target_party)>0
      ) targets),'[]'::jsonb),
      'allocations',coalesce((select jsonb_agg(jsonb_build_object(
        'id',a.id,'source_id',a.payment_id,'target_type',a.target_type,'target_id',a.target_id,
        'amount',a.amount,'status',a.status,'allocated_at',a.allocated_at,
        'reversed_at',a.reversed_at,'reversal_reason',a.reversal_reason,
        'target_label',case when a.target_type='supplier_invoice' then 'فاتورة مورد' else 'شراء مباشر' end
      ) order by a.allocated_at desc) from public.supplier_advance_allocations a where a.supplier_id=target_party),'[]'::jsonb),
      'transactions',coalesce((select jsonb_agg(jsonb_build_object(
        'id',p.id,'date',p.payment_date,'amount',p.amount,'classification',p.transaction_classification,
        'settlement_amount',p.settlement_amount,'advance_amount',p.advance_amount,'status',p.status,
        'reversed_at',p.reversed_at,'reversal_reason',p.reversal_reason,
        'has_active_allocations',exists(select 1 from public.supplier_advance_allocations a where a.payment_id=p.id and a.status='allocated')
      ) order by p.payment_date desc,p.created_at desc) from public.supplier_payments p
      where p.supplier_id=target_party and p.transaction_classification is not null),'[]'::jsonb)
    ) into result;
  else
    raise exception using errcode='22023',message='Unsupported commercial party type';
  end if;
  return result;
end
$$;

create or replace function public.allocate_customer_advance(source_receipt uuid,target_type text,target_id uuid,allocation_amount numeric,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare source public.customer_receipts%rowtype; saved public.customer_advance_allocations%rowtype; target_remaining numeric;
begin
  if not private.commercial_payment_allowed() then raise exception using errcode='42501',message='Finance payment permission required'; end if;
  select * into saved from public.customer_advance_allocations where customer_advance_allocations.command_id=allocate_customer_advance.command_id;
  if found then return to_jsonb(saved); end if;
  select * into source from public.customer_receipts where id=source_receipt for update;
  if not found or source.status<>'posted' or source.transaction_classification not in ('advance','mixed') then raise exception 'Posted customer advance required'; end if;
  if target_type='sale' then perform 1 from public.sales where id=target_id and customer_id=source.customer_id and status='posted' for update;
  elsif target_type='rental' then perform 1 from public.rentals where id=target_id and customer_id=source.customer_id and status<>'cancelled' for update;
  else raise exception 'Valid customer document required'; end if;
  if not found then raise exception 'Valid customer document required'; end if;
  target_remaining:=private.customer_advance_target_remaining(target_type,target_id,source.customer_id);
  if allocation_amount is null or allocation_amount<=0 or allocation_amount>source.advance_amount-source.allocated_advance_amount then raise exception 'Allocation exceeds available customer advance'; end if;
  if allocation_amount>private.customer_due(source.customer_id) then raise exception 'Allocation exceeds customer due'; end if;
  if allocation_amount>target_remaining then raise exception 'Allocation exceeds customer document balance'; end if;
  insert into public.customer_advance_allocations(receipt_id,customer_id,target_type,target_id,amount,command_id)
  values(source.id,source.customer_id,target_type,target_id,allocation_amount,command_id) returning * into saved;
  perform set_config('app.commercial_advance_rpc','on',true);
  update public.customer_receipts set allocated_advance_amount=allocated_advance_amount+allocation_amount where id=source.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('customer_advance_allocations',saved.id::text,'customer_advance_allocated',auth.uid(),to_jsonb(saved),jsonb_build_object('receipt_id',source.id,'target_remaining_before',target_remaining));
  return to_jsonb(saved);
end $$;

create or replace function public.allocate_supplier_advance(source_payment uuid,target_type text,target_id uuid,allocation_amount numeric,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare source public.supplier_payments%rowtype; saved public.supplier_advance_allocations%rowtype; target_remaining numeric;
begin
  if not private.commercial_payment_allowed() then raise exception using errcode='42501',message='Finance payment permission required'; end if;
  select * into saved from public.supplier_advance_allocations where supplier_advance_allocations.command_id=allocate_supplier_advance.command_id;
  if found then return to_jsonb(saved); end if;
  select * into source from public.supplier_payments where id=source_payment for update;
  if not found or source.status<>'posted' or source.transaction_classification not in ('advance','mixed') then raise exception 'Posted supplier advance required'; end if;
  if target_type='material_purchase' then perform 1 from public.material_purchases where id=target_id and supplier_id=source.supplier_id for update;
  elsif target_type='supplier_invoice' then perform 1 from public.supplier_invoices where id=target_id and supplier_id=source.supplier_id and status in ('approved','paid') for update;
  else raise exception 'Valid supplier document required'; end if;
  if not found then raise exception 'Valid supplier document required'; end if;
  target_remaining:=private.supplier_advance_target_remaining(target_type,target_id,source.supplier_id);
  if allocation_amount is null or allocation_amount<=0 or allocation_amount>source.advance_amount-source.allocated_advance_amount then raise exception 'Allocation exceeds available supplier advance'; end if;
  if allocation_amount>private.supplier_due(source.supplier_id) then raise exception 'Allocation exceeds supplier due'; end if;
  if allocation_amount>target_remaining then raise exception 'Allocation exceeds supplier document balance'; end if;
  insert into public.supplier_advance_allocations(payment_id,supplier_id,target_type,target_id,amount,command_id)
  values(source.id,source.supplier_id,target_type,target_id,allocation_amount,command_id) returning * into saved;
  perform set_config('app.commercial_advance_rpc','on',true);
  update public.supplier_payments set allocated_advance_amount=allocated_advance_amount+allocation_amount where id=source.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('supplier_advance_allocations',saved.id::text,'supplier_advance_allocated',auth.uid(),to_jsonb(saved),jsonb_build_object('payment_id',source.id,'target_remaining_before',target_remaining));
  return to_jsonb(saved);
end $$;

create or replace function private.guard_active_advance_target()
returns trigger language plpgsql security definer set search_path='' as $$
declare active_allocation boolean:=false;
begin
  if tg_table_name='sales' and (tg_op='DELETE' or (old.status<>'cancelled' and new.status='cancelled')) then
    select exists(select 1 from public.customer_advance_allocations where target_type='sale' and target_id=old.id and status='allocated') into active_allocation;
  elsif tg_table_name='rentals' and (tg_op='DELETE' or (old.status<>'cancelled' and new.status='cancelled')) then
    select exists(select 1 from public.customer_advance_allocations where target_type='rental' and target_id=old.id and status='allocated') into active_allocation;
  elsif tg_table_name='material_purchases' and tg_op='DELETE' then
    select exists(select 1 from public.supplier_advance_allocations where target_type='material_purchase' and target_id=old.id and status='allocated') into active_allocation;
  elsif tg_table_name='supplier_invoices' and (tg_op='DELETE' or (old.status not in ('cancelled','reversed') and new.status in ('cancelled','reversed'))) then
    select exists(select 1 from public.supplier_advance_allocations where target_type='supplier_invoice' and target_id=old.id and status='allocated') into active_allocation;
  end if;
  if active_allocation then raise exception using errcode='23514',message='Reverse active advance allocations before cancelling or deleting this document'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

revoke all on function private.guard_active_advance_target() from public,anon,authenticated;
drop trigger if exists guard_sale_advance_target on public.sales;
create trigger guard_sale_advance_target before update of status or delete on public.sales for each row execute function private.guard_active_advance_target();
drop trigger if exists guard_rental_advance_target on public.rentals;
create trigger guard_rental_advance_target before update of status or delete on public.rentals for each row execute function private.guard_active_advance_target();
drop trigger if exists guard_material_purchase_advance_target on public.material_purchases;
create trigger guard_material_purchase_advance_target before delete on public.material_purchases for each row execute function private.guard_active_advance_target();
drop trigger if exists guard_supplier_invoice_advance_target on public.supplier_invoices;
create trigger guard_supplier_invoice_advance_target before update of status or delete on public.supplier_invoices for each row execute function private.guard_active_advance_target();

revoke all on function public.get_commercial_advance_workspace(text,uuid),
  public.allocate_customer_advance(uuid,text,uuid,numeric,uuid),
  public.allocate_supplier_advance(uuid,text,uuid,numeric,uuid) from public,anon;
grant execute on function public.get_commercial_advance_workspace(text,uuid),
  public.allocate_customer_advance(uuid,text,uuid,numeric,uuid),
  public.allocate_supplier_advance(uuid,text,uuid,numeric,uuid) to authenticated;

comment on function public.get_commercial_advance_workspace(text,uuid) is
  'Protected operational workspace for advance sources, eligible documents, allocations, reversals, and classified cash history.';

commit;
