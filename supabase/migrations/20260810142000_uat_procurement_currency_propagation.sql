-- UAT-006 closure: new documents receive a complete currency contract and preserve it quote -> PO.
begin;

create or replace function public.save_supplier_quote(payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
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
  insert into public.supplier_quotes(purchase_request_id,supplier_id,supplier_reference,quote_date,valid_until,currency,base_currency,exchange_rate,rate_date,status,payment_terms,delivery_days,notes,created_by)
  values((payload->>'purchase_request_id')::uuid,(payload->>'supplier_id')::uuid,payload->>'supplier_reference',coalesce(nullif(payload->>'quote_date','')::date,current_date),nullif(payload->>'valid_until','')::date,document_currency,base_currency,rate,coalesce(rate_on,current_date),'received',payload->>'payment_terms',nullif(payload->>'delivery_days','')::int,payload->>'notes',actor) returning * into q;
  for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
    if (item->>'quantity')::numeric<=0 or (item->>'unit_price')::numeric<=0 then raise exception using errcode='22023',message='Quote quantity and unit price must be positive'; end if;
    insert into public.supplier_quote_items(supplier_quote_id,purchase_request_item_id,quantity,unit_price,discount_amount,tax_amount,notes)
    values(q.id,(item->>'purchase_request_item_id')::uuid,(item->>'quantity')::numeric,(item->>'unit_price')::numeric,coalesce((item->>'discount_amount')::numeric,0),coalesce((item->>'tax_amount')::numeric,0),item->>'notes');
  end loop;
  select coalesce(sum(line_total),0) into quote_total from public.supplier_quote_items where supplier_quote_id=q.id;
  if quote_total<=0 then raise exception 'Quote items with positive total are required'; end if;
  update public.supplier_quotes set base_total_amount=round(quote_total*rate,2),updated_at=now() where id=q.id returning * into q;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('supplier_quotes',q.id::text,'supplier_quote_currency_contract',actor,to_jsonb(q),jsonb_build_object('document_total',quote_total,'currency',document_currency,'base_currency',base_currency,'exchange_rate',rate,'rate_date',q.rate_date));
  return to_jsonb(q);
end $$;

create or replace function public.create_purchase_order_draft_from_quote(target_quote uuid,order_display_name text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); q public.supplier_quotes%rowtype; req public.purchase_requests%rowtype; po public.purchase_orders%rowtype; effective_name text;
begin
  if actor is null or public.current_identity_role() not in('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  select * into q from public.supplier_quotes where id=target_quote for update;
  if not found or q.status not in('received','selected') then raise exception 'Received quote required'; end if;
  if q.base_currency is null or q.exchange_rate is null or q.exchange_rate<=0 or q.rate_date is null or q.base_total_amount is null then raise exception 'Quote currency conversion contract is incomplete'; end if;
  if q.currency=q.base_currency and q.exchange_rate<>1 then raise exception 'Exchange rate must equal 1 when currencies match'; end if;
  select * into req from public.purchase_requests where id=q.purchase_request_id for update;
  if req.status<>'approved' then raise exception 'Approved request required'; end if;
  if exists(select 1 from public.purchase_orders where selected_quote_id=q.id and status<>'cancelled') then raise exception 'Purchase order already exists for this quote'; end if;
  effective_name:=coalesce(nullif(btrim(order_display_name),''),nullif(btrim(req.display_name),''),req.request_number);
  insert into public.purchase_orders(purchase_request_id,selected_quote_id,supplier_id,project_id,currency,base_currency,exchange_rate,rate_date,status,payment_terms,created_by,display_name)
  values(req.id,q.id,q.supplier_id,req.project_id,q.currency,q.base_currency,q.exchange_rate,q.rate_date,'draft',q.payment_terms,actor,effective_name) returning * into po;
  insert into public.purchase_order_items(purchase_order_id,purchase_request_item_id,material_id,description,quantity,unit,unit_price,discount_amount,tax_amount,budget_item_id,milestone_id,cost_center_reference,sequence)
  select po.id,ri.id,ri.material_id,ri.description,qi.quantity,ri.unit,qi.unit_price,qi.discount_amount,qi.tax_amount,ri.budget_item_id,ri.milestone_id,ri.cost_center_reference,ri.sequence
  from public.supplier_quote_items qi join public.purchase_request_items ri on ri.id=qi.purchase_request_item_id where qi.supplier_quote_id=q.id;
  update public.purchase_orders p set subtotal=x.subtotal,discount_amount=x.discount_amount,tax_amount=x.tax_amount,total_amount=x.total_amount,base_total_amount=round(x.total_amount*q.exchange_rate,2),updated_at=now()
  from(select coalesce(sum(quantity*unit_price),0) subtotal,coalesce(sum(discount_amount),0) discount_amount,coalesce(sum(tax_amount),0) tax_amount,coalesce(sum(line_total),0) total_amount from public.purchase_order_items where purchase_order_id=po.id)x
  where p.id=po.id returning p.* into po;
  if po.total_amount<=0 then raise exception 'Purchase order total must be positive'; end if;
  update public.supplier_quotes set status=case when id=q.id then 'selected' else 'rejected' end where purchase_request_id=req.id and status in('received','selected');
  update public.purchase_requests set status='converted',updated_at=now() where id=req.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('purchase_orders',po.id::text,'purchase_order_draft_created',actor,to_jsonb(po),jsonb_build_object('quote_id',q.id,'request_id',req.id,'currency_contract_preserved',true));
  return to_jsonb(po);
end $$;

revoke all on function public.save_supplier_quote(jsonb), public.create_purchase_order_draft_from_quote(uuid,text) from public,anon;
grant execute on function public.save_supplier_quote(jsonb), public.create_purchase_order_draft_from_quote(uuid,text) to authenticated;

commit;
