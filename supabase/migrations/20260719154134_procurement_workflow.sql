-- Protected Procure-to-Pay workflow on top of 202607190012.
begin;

create or replace function public.save_purchase_request(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); target uuid; saved public.purchase_requests%rowtype; item jsonb;
begin
 if actor is null or role_name not in('owner','manager','accountant','production') then raise exception 'Procurement access required'; end if;
 target:=nullif(payload->>'id','')::uuid;
 if target is null then
  insert into public.purchase_requests(project_id,requested_by,department_id,required_date,priority,justification)
  values(nullif(payload->>'project_id','')::uuid,actor,nullif(payload->>'department_id','')::uuid,nullif(payload->>'required_date','')::date,coalesce(nullif(payload->>'priority',''),'normal'),payload->>'justification') returning * into saved;
 else
  select * into saved from public.purchase_requests where id=target for update;
  if not found or saved.status<>'draft' then raise exception 'Only draft purchase requests can be edited'; end if;
  if saved.requested_by<>actor and role_name not in('owner','manager') then raise exception 'Request access denied'; end if;
  update public.purchase_requests set project_id=nullif(payload->>'project_id','')::uuid,department_id=nullif(payload->>'department_id','')::uuid,required_date=nullif(payload->>'required_date','')::date,priority=coalesce(nullif(payload->>'priority',''),priority),justification=payload->>'justification',updated_at=now() where id=target returning * into saved;
  delete from public.purchase_request_items where purchase_request_id=target;
 end if;
 for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
  insert into public.purchase_request_items(purchase_request_id,material_id,description,quantity,unit,estimated_unit_cost,budget_item_id,milestone_id,cost_center_reference,notes,sequence)
  values(saved.id,nullif(item->>'material_id','')::uuid,item->>'description',(item->>'quantity')::numeric,coalesce(nullif(item->>'unit',''),'وحدة'),coalesce((item->>'estimated_unit_cost')::numeric,0),nullif(item->>'budget_item_id','')::uuid,nullif(item->>'milestone_id','')::uuid,item->>'cost_center_reference',item->>'notes',coalesce((item->>'sequence')::int,0));
 end loop;
 if not exists(select 1 from public.purchase_request_items where purchase_request_id=saved.id) then raise exception 'At least one request item is required'; end if;
 return to_jsonb(saved);
end $$;

create or replace function public.submit_purchase_request(target_id uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.purchase_requests%rowtype;
begin
 select * into saved from public.purchase_requests where id=target_id for update;
 if not found or saved.status<>'draft' then raise exception 'Draft request required'; end if;
 if saved.requested_by<>actor and public.current_identity_role() not in('owner','manager') then raise exception 'Request access denied'; end if;
 if not exists(select 1 from public.purchase_request_items where purchase_request_id=target_id) then raise exception 'Request has no items'; end if;
 update public.purchase_requests set status='submitted',submitted_at=now(),updated_at=now() where id=target_id returning * into saved;
 return to_jsonb(saved);
end $$;

create or replace function public.decide_purchase_request(target_id uuid, approve boolean, reason text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.purchase_requests%rowtype;
begin
 if public.current_identity_role() not in('owner','manager') then raise exception 'Owner or manager role required'; end if;
 select * into saved from public.purchase_requests where id=target_id for update;
 if not found or saved.status<>'submitted' then raise exception 'Submitted request required'; end if;
 if approve then
  update public.purchase_requests set status='approved',approved_by=actor,approved_at=now(),rejection_reason=null,updated_at=now() where id=target_id returning * into saved;
 else
  if btrim(coalesce(reason,''))='' then raise exception 'Rejection reason required'; end if;
  update public.purchase_requests set status='rejected',rejected_by=actor,rejected_at=now(),rejection_reason=reason,updated_at=now() where id=target_id returning * into saved;
 end if;
 return to_jsonb(saved);
end $$;

create or replace function public.save_supplier_quote(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); q public.supplier_quotes%rowtype; item jsonb; req_status text;
begin
 if public.current_identity_role() not in('owner','manager','accountant') then raise exception 'Procurement access required'; end if;
 select status into req_status from public.purchase_requests where id=(payload->>'purchase_request_id')::uuid;
 if req_status<>'approved' then raise exception 'Approved purchase request required'; end if;
 insert into public.supplier_quotes(purchase_request_id,supplier_id,supplier_reference,quote_date,valid_until,currency,status,payment_terms,delivery_days,notes,created_by)
 values((payload->>'purchase_request_id')::uuid,(payload->>'supplier_id')::uuid,payload->>'supplier_reference',coalesce(nullif(payload->>'quote_date','')::date,current_date),nullif(payload->>'valid_until','')::date,coalesce(nullif(payload->>'currency',''),'SAR'),'received',payload->>'payment_terms',nullif(payload->>'delivery_days','')::int,payload->>'notes',actor) returning * into q;
 for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
  insert into public.supplier_quote_items(supplier_quote_id,purchase_request_item_id,quantity,unit_price,discount_amount,tax_amount,notes)
  values(q.id,(item->>'purchase_request_item_id')::uuid,(item->>'quantity')::numeric,(item->>'unit_price')::numeric,coalesce((item->>'discount_amount')::numeric,0),coalesce((item->>'tax_amount')::numeric,0),item->>'notes');
 end loop;
 if not exists(select 1 from public.supplier_quote_items where supplier_quote_id=q.id) then raise exception 'Quote items required'; end if;
 return to_jsonb(q);
end $$;

create or replace function public.create_purchase_order_from_quote(target_quote uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); q public.supplier_quotes%rowtype; req public.purchase_requests%rowtype; po public.purchase_orders%rowtype;
begin
 if public.current_identity_role() not in('owner','manager') then raise exception 'Owner or manager role required'; end if;
 select * into q from public.supplier_quotes where id=target_quote for update;
 if not found or q.status not in('received','selected') then raise exception 'Received quote required'; end if;
 select * into req from public.purchase_requests where id=q.purchase_request_id for update;
 if req.status<>'approved' then raise exception 'Approved request required'; end if;
 insert into public.purchase_orders(purchase_request_id,selected_quote_id,supplier_id,project_id,currency,status,payment_terms,created_by)
 values(req.id,q.id,q.supplier_id,req.project_id,q.currency,'approved',q.payment_terms,actor) returning * into po;
 insert into public.purchase_order_items(purchase_order_id,purchase_request_item_id,material_id,description,quantity,unit,unit_price,discount_amount,tax_amount,budget_item_id,milestone_id,cost_center_reference,sequence)
 select po.id,ri.id,ri.material_id,ri.description,qi.quantity,ri.unit,qi.unit_price,qi.discount_amount,qi.tax_amount,ri.budget_item_id,ri.milestone_id,ri.cost_center_reference,ri.sequence
 from public.supplier_quote_items qi join public.purchase_request_items ri on ri.id=qi.purchase_request_item_id where qi.supplier_quote_id=q.id;
 update public.purchase_orders p set subtotal=x.subtotal,discount_amount=x.discount_amount,tax_amount=x.tax_amount,total_amount=x.total_amount,approved_by=actor,approved_at=now() from (select coalesce(sum(quantity*unit_price),0) subtotal,coalesce(sum(discount_amount),0) discount_amount,coalesce(sum(tax_amount),0) tax_amount,coalesce(sum(line_total),0) total_amount from public.purchase_order_items where purchase_order_id=po.id)x where p.id=po.id returning p.* into po;
 update public.supplier_quotes set status=case when id=q.id then 'selected' else 'rejected' end where purchase_request_id=req.id and status in('received','selected');
 update public.purchase_requests set status='converted',updated_at=now() where id=req.id;
 return to_jsonb(po);
end $$;

create or replace function public.confirm_goods_receipt(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); gr public.goods_receipts%rowtype; item jsonb; po_id uuid:=(payload->>'purchase_order_id')::uuid;
begin
 if public.current_identity_role() not in('owner','manager','accountant','production') then raise exception 'Receiving access required'; end if;
 if not exists(select 1 from public.purchase_orders where id=po_id and status in('approved','sent','partially_received')) then raise exception 'Receivable purchase order required'; end if;
 insert into public.goods_receipts(purchase_order_id,received_by,status,supplier_delivery_reference,notes,confirmed_by,confirmed_at)
 values(po_id,actor,'confirmed',payload->>'supplier_delivery_reference',payload->>'notes',actor,now()) returning * into gr;
 for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
  insert into public.goods_receipt_items(goods_receipt_id,purchase_order_item_id,quantity_received,accepted_quantity,condition,notes)
  values(gr.id,(item->>'purchase_order_item_id')::uuid,(item->>'quantity_received')::numeric,coalesce((item->>'accepted_quantity')::numeric,(item->>'quantity_received')::numeric),coalesce(nullif(item->>'condition',''),'accepted'),item->>'notes');
  update public.purchase_order_items set received_quantity=received_quantity+coalesce((item->>'accepted_quantity')::numeric,(item->>'quantity_received')::numeric) where id=(item->>'purchase_order_item_id')::uuid and purchase_order_id=po_id;
 end loop;
 if not exists(select 1 from public.goods_receipt_items where goods_receipt_id=gr.id) then raise exception 'Receipt items required'; end if;
 update public.purchase_orders set status=case when not exists(select 1 from public.purchase_order_items where purchase_order_id=po_id and received_quantity<quantity) then 'fully_received' else 'partially_received' end,updated_at=now() where id=po_id;
 return to_jsonb(gr);
end $$;

create or replace function public.approve_supplier_invoice(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); inv public.supplier_invoices%rowtype; item jsonb; line_id uuid; entry jsonb; po public.purchase_orders%rowtype;
begin
 if public.current_identity_role() not in('owner','manager') then raise exception 'Owner or manager role required'; end if;
 select * into po from public.purchase_orders where id=(payload->>'purchase_order_id')::uuid;
 if not found or po.status not in('fully_received','partially_received','approved','sent') then raise exception 'Valid purchase order required'; end if;
 insert into public.supplier_invoices(invoice_number,supplier_id,purchase_order_id,project_id,invoice_date,due_date,currency,status,notes,created_by)
 values(payload->>'invoice_number',po.supplier_id,po.id,po.project_id,(payload->>'invoice_date')::date,nullif(payload->>'due_date','')::date,po.currency,'submitted',payload->>'notes',actor) returning * into inv;
 for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
  insert into public.supplier_invoice_lines(supplier_invoice_id,purchase_order_item_id,goods_receipt_item_id,description,quantity,unit_price,discount_amount,tax_amount,budget_item_id,milestone_id,cost_center_reference)
  values(inv.id,(item->>'purchase_order_item_id')::uuid,nullif(item->>'goods_receipt_item_id','')::uuid,item->>'description',(item->>'quantity')::numeric,(item->>'unit_price')::numeric,coalesce((item->>'discount_amount')::numeric,0),coalesce((item->>'tax_amount')::numeric,0),nullif(item->>'budget_item_id','')::uuid,nullif(item->>'milestone_id','')::uuid,item->>'cost_center_reference') returning id into line_id;
  entry:=public.save_project_actual_cost(jsonb_build_object('project_id',po.project_id,'cost_category','purchase_invoice','source_type','purchase_invoice_line','source_id',line_id,'source_line_reference','main','source_revision',1,'source_reference_key','purchase_invoice_line:'||line_id::text||':main:1','description',item->>'description','quantity',(item->>'quantity')::numeric,'unit','وحدة','unit_cost',(item->>'unit_price')::numeric,'cost_date',(payload->>'invoice_date')::date,'budget_item_id',nullif(item->>'budget_item_id','')::uuid,'milestone_id',nullif(item->>'milestone_id','')::uuid,'metadata',jsonb_build_object('supplier_invoice_id',inv.id)));
  perform public.submit_project_actual_cost((entry->>'id')::uuid);
  perform public.approve_project_actual_cost((entry->>'id')::uuid);
  update public.supplier_invoice_lines set actual_cost_entry_id=(entry->>'id')::uuid where id=line_id;
 end loop;
 if not exists(select 1 from public.supplier_invoice_lines where supplier_invoice_id=inv.id) then raise exception 'Invoice lines required'; end if;
 update public.supplier_invoices s set subtotal=x.subtotal,discount_amount=x.discount_amount,tax_amount=x.tax_amount,total_amount=x.total_amount,status='approved',match_status='matched',approved_by=actor,approved_at=now(),updated_at=now() from (select coalesce(sum(quantity*unit_price),0) subtotal,coalesce(sum(discount_amount),0) discount_amount,coalesce(sum(tax_amount),0) tax_amount,coalesce(sum(line_total),0) total_amount from public.supplier_invoice_lines where supplier_invoice_id=inv.id)x where s.id=inv.id returning s.* into inv;
 update public.purchase_orders set status='invoiced',updated_at=now() where id=po.id;
 return to_jsonb(inv);
end $$;

create or replace function public.get_procurement_workspace(target_project uuid default null)
returns jsonb language sql security definer set search_path=public,private,pg_temp as $$
 select jsonb_build_object(
  'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from public.purchase_requests r where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.purchase_orders o where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'receipts',coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at desc) from public.goods_receipts g join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'invoices',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.supplier_invoices i where target_project is null or i.project_id=target_project),'[]'::jsonb)
 ) where auth.uid() is not null and (target_project is null or private.project_can_view(target_project));
$$;

create index if not exists purchase_request_items_budget_item_idx on public.purchase_request_items(budget_item_id) where budget_item_id is not null;
create index if not exists purchase_request_items_milestone_idx on public.purchase_request_items(milestone_id) where milestone_id is not null;
create index if not exists purchase_order_items_budget_item_idx on public.purchase_order_items(budget_item_id) where budget_item_id is not null;
create index if not exists purchase_order_items_milestone_idx on public.purchase_order_items(milestone_id) where milestone_id is not null;
create index if not exists goods_receipt_items_order_item_idx on public.goods_receipt_items(purchase_order_item_id);
create index if not exists supplier_invoice_lines_order_item_idx on public.supplier_invoice_lines(purchase_order_item_id) where purchase_order_item_id is not null;
create index if not exists supplier_invoice_lines_receipt_item_idx on public.supplier_invoice_lines(goods_receipt_item_id) where goods_receipt_item_id is not null;

revoke all on function public.save_purchase_request(jsonb) from public,anon;
revoke all on function public.submit_purchase_request(uuid) from public,anon;
revoke all on function public.decide_purchase_request(uuid,boolean,text) from public,anon;
revoke all on function public.save_supplier_quote(jsonb) from public,anon;
revoke all on function public.create_purchase_order_from_quote(uuid) from public,anon;
revoke all on function public.confirm_goods_receipt(jsonb) from public,anon;
revoke all on function public.approve_supplier_invoice(jsonb) from public,anon;
revoke all on function public.get_procurement_workspace(uuid) from public,anon;
grant execute on function public.save_purchase_request(jsonb),public.submit_purchase_request(uuid),public.decide_purchase_request(uuid,boolean,text),public.save_supplier_quote(jsonb),public.create_purchase_order_from_quote(uuid),public.confirm_goods_receipt(jsonb),public.approve_supplier_invoice(jsonb),public.get_procurement_workspace(uuid) to authenticated;
commit;