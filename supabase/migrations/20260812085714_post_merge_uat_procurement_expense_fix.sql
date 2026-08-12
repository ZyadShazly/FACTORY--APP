-- Post-merge UAT blockers: supplier quote posting + owner expense visibility.
begin;

create or replace function public.save_supplier_quote(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid(); q public.supplier_quotes%rowtype; item jsonb; req_status text;
  document_currency text:=upper(nullif(btrim(payload->>'currency'),''));
  base_currency text:=upper(nullif(btrim(payload->>'base_currency'),''));
  rate numeric:=nullif(payload->>'exchange_rate','')::numeric;
  rate_on date:=nullif(payload->>'rate_date','')::date;
  quote_total numeric;
begin
  if actor is null or public.current_identity_role() not in('owner','manager','accountant') then raise exception using errcode='42501',message='Procurement access required'; end if;
  if document_currency !~ '^[A-Z]{3}$' or base_currency !~ '^[A-Z]{3}$' then raise exception using errcode='22023',message='Valid document and base currency codes are required'; end if;
  if rate is null or rate<=0 then raise exception using errcode='22023',message='A positive exchange rate is required'; end if;
  if document_currency=base_currency and rate<>1 then raise exception using errcode='22023',message='Exchange rate must equal 1 when currencies match'; end if;
  if document_currency<>base_currency and rate_on is null then raise exception using errcode='22023',message='Exchange-rate date is required for foreign currency'; end if;
  select status into req_status from public.purchase_requests where id=(payload->>'purchase_request_id')::uuid;
  if req_status<>'approved' then raise exception 'Approved purchase request required'; end if;

  -- The currency conversion check requires base_total_amount at INSERT time.
  -- Start at zero (valid) and replace it atomically after quote items are stored.
  insert into public.supplier_quotes(
    purchase_request_id,supplier_id,supplier_reference,quote_date,valid_until,
    currency,base_currency,exchange_rate,rate_date,base_total_amount,status,
    payment_terms,delivery_days,notes,created_by
  ) values(
    (payload->>'purchase_request_id')::uuid,(payload->>'supplier_id')::uuid,
    payload->>'supplier_reference',coalesce(nullif(payload->>'quote_date','')::date,current_date),
    nullif(payload->>'valid_until','')::date,document_currency,base_currency,rate,
    coalesce(rate_on,current_date),0,'received',payload->>'payment_terms',
    nullif(payload->>'delivery_days','')::int,payload->>'notes',actor
  ) returning * into q;

  for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    if (item->>'quantity')::numeric<=0 or (item->>'unit_price')::numeric<=0 then
      raise exception using errcode='22023',message='Quote quantity and unit price must be positive';
    end if;
    insert into public.supplier_quote_items(
      supplier_quote_id,purchase_request_item_id,quantity,unit_price,discount_amount,tax_amount,notes
    ) values(
      q.id,(item->>'purchase_request_item_id')::uuid,(item->>'quantity')::numeric,
      (item->>'unit_price')::numeric,coalesce((item->>'discount_amount')::numeric,0),
      coalesce((item->>'tax_amount')::numeric,0),item->>'notes'
    );
  end loop;

  select coalesce(sum(line_total),0) into quote_total
  from public.supplier_quote_items where supplier_quote_id=q.id;
  if quote_total<=0 then raise exception 'Quote items with positive total are required'; end if;

  update public.supplier_quotes
  set base_total_amount=round(quote_total*rate,2),updated_at=now()
  where id=q.id returning * into q;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'supplier_quotes',q.id::text,'supplier_quote_currency_contract',actor,to_jsonb(q),
    jsonb_build_object('document_total',quote_total,'currency',document_currency,
      'base_currency',base_currency,'exchange_rate',rate,'rate_date',q.rate_date)
  );
  return to_jsonb(q);
end
$$;

revoke all on function public.save_supplier_quote(jsonb) from public,anon,authenticated;
grant execute on function public.save_supplier_quote(jsonb) to authenticated;

drop policy if exists expenses_select_finance_roles on public.expenses;
create policy expenses_select_finance_roles
on public.expenses
for select
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id=auth.uid()
      and p.role = any (array['owner'::text,'manager'::text,'accountant'::text])
  )
);

commit;
