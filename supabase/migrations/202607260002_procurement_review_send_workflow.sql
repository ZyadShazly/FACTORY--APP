-- Complete the review / approve / send lifecycle without rewriting historical procurement data.
begin;

alter table public.purchase_requests
  add column if not exists display_name text;

alter table public.purchase_orders
  add column if not exists display_name text,
  add column if not exists sent_by uuid references public.profiles(id) on delete set null,
  add column if not exists sent_at timestamptz,
  add column if not exists supplier_send_reference text;

update public.purchase_requests r
set display_name=coalesce(nullif(btrim(r.display_name),''),
  (select nullif(btrim(i.description),'') from public.purchase_request_items i where i.purchase_request_id=r.id order by i.sequence,i.created_at limit 1),
  r.request_number)
where display_name is null or btrim(display_name)='';

update public.purchase_orders o
set display_name=coalesce(nullif(btrim(o.display_name),''),
  (select nullif(btrim(i.description),'') from public.purchase_order_items i where i.purchase_order_id=o.id order by i.sequence limit 1),
  o.order_number)
where display_name is null or btrim(display_name)='';

alter table public.purchase_requests alter column display_name set not null;
alter table public.purchase_orders alter column display_name set not null;

create or replace function public.set_purchase_request_display_name(target_id uuid,new_display_name text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.purchase_requests%rowtype;
begin
  if actor is null then raise exception using errcode='42501',message='Authentication required'; end if;
  if btrim(coalesce(new_display_name,''))='' then raise exception 'Purchase request name required'; end if;
  select * into saved from public.purchase_requests where id=target_id for update;
  if not found then raise exception 'Purchase request not found'; end if;
  if saved.requested_by<>actor and public.current_identity_role() not in('owner','manager') then raise exception using errcode='42501',message='Request access denied'; end if;
  update public.purchase_requests set display_name=btrim(new_display_name),updated_at=now() where id=target_id returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('purchase_requests',saved.id::text,'purchase_request_renamed',actor,to_jsonb(saved),jsonb_build_object('source','procurement_workflow'));
  return to_jsonb(saved);
end $$;

create or replace function public.create_purchase_order_draft_from_quote(target_quote uuid,order_display_name text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); q public.supplier_quotes%rowtype; req public.purchase_requests%rowtype; po public.purchase_orders%rowtype; effective_name text;
begin
  if public.current_identity_role() not in('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  select * into q from public.supplier_quotes where id=target_quote for update;
  if not found or q.status not in('received','selected') then raise exception 'Received quote required'; end if;
  select * into req from public.purchase_requests where id=q.purchase_request_id for update;
  if req.status<>'approved' then raise exception 'Approved request required'; end if;
  if exists(select 1 from public.purchase_orders where selected_quote_id=q.id and status<>'cancelled') then raise exception 'Purchase order already exists for this quote'; end if;
  effective_name:=coalesce(nullif(btrim(order_display_name),''),nullif(btrim(req.display_name),''),req.request_number);
  insert into public.purchase_orders(purchase_request_id,selected_quote_id,supplier_id,project_id,currency,status,payment_terms,created_by,display_name)
  values(req.id,q.id,q.supplier_id,req.project_id,q.currency,'draft',q.payment_terms,actor,effective_name) returning * into po;
  insert into public.purchase_order_items(purchase_order_id,purchase_request_item_id,material_id,description,quantity,unit,unit_price,discount_amount,tax_amount,budget_item_id,milestone_id,cost_center_reference,sequence)
  select po.id,ri.id,ri.material_id,ri.description,qi.quantity,ri.unit,qi.unit_price,qi.discount_amount,qi.tax_amount,ri.budget_item_id,ri.milestone_id,ri.cost_center_reference,ri.sequence
  from public.supplier_quote_items qi join public.purchase_request_items ri on ri.id=qi.purchase_request_item_id where qi.supplier_quote_id=q.id;
  update public.purchase_orders p set subtotal=x.subtotal,discount_amount=x.discount_amount,tax_amount=x.tax_amount,total_amount=x.total_amount,updated_at=now()
  from (select coalesce(sum(quantity*unit_price),0) subtotal,coalesce(sum(discount_amount),0) discount_amount,coalesce(sum(tax_amount),0) tax_amount,coalesce(sum(line_total),0) total_amount from public.purchase_order_items where purchase_order_id=po.id)x
  where p.id=po.id returning p.* into po;
  update public.supplier_quotes set status=case when id=q.id then 'selected' else 'rejected' end where purchase_request_id=req.id and status in('received','selected');
  update public.purchase_requests set status='converted',updated_at=now() where id=req.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('purchase_orders',po.id::text,'purchase_order_draft_created',actor,to_jsonb(po),jsonb_build_object('quote_id',q.id,'request_id',req.id));
  return to_jsonb(po);
end $$;

create or replace function public.approve_purchase_order(target_order uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.purchase_orders%rowtype;
begin
  if public.current_identity_role() not in('owner','manager') then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  select * into saved from public.purchase_orders where id=target_order for update;
  if not found or saved.status<>'draft' then raise exception 'Draft purchase order required'; end if;
  if not exists(select 1 from public.purchase_order_items where purchase_order_id=target_order) then raise exception 'Purchase order has no items'; end if;
  update public.purchase_orders set status='approved',approved_by=actor,approved_at=now(),updated_at=now() where id=target_order returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('purchase_orders',saved.id::text,'purchase_order_approved',actor,to_jsonb(saved),jsonb_build_object('source','procurement_workflow'));
  return to_jsonb(saved);
end $$;

create or replace function public.mark_purchase_order_sent(target_order uuid,send_reference text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.purchase_orders%rowtype;
begin
  if public.current_identity_role() not in('owner','manager','accountant') then raise exception using errcode='42501',message='Procurement sending access required'; end if;
  select * into saved from public.purchase_orders where id=target_order for update;
  if not found or saved.status<>'approved' then raise exception 'Approved purchase order required'; end if;
  update public.purchase_orders set status='sent',sent_by=actor,sent_at=now(),supplier_send_reference=nullif(btrim(send_reference),''),updated_at=now() where id=target_order returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('purchase_orders',saved.id::text,'purchase_order_sent',actor,to_jsonb(saved),jsonb_build_object('send_reference',saved.supplier_send_reference,'source','procurement_workflow'));
  return to_jsonb(saved);
end $$;

revoke all on function public.set_purchase_request_display_name(uuid,text) from public,anon;
revoke all on function public.create_purchase_order_draft_from_quote(uuid,text) from public,anon;
revoke all on function public.approve_purchase_order(uuid) from public,anon;
revoke all on function public.mark_purchase_order_sent(uuid,text) from public,anon;
grant execute on function public.set_purchase_request_display_name(uuid,text) to authenticated;
grant execute on function public.create_purchase_order_draft_from_quote(uuid,text) to authenticated;
grant execute on function public.approve_purchase_order(uuid) to authenticated;
grant execute on function public.mark_purchase_order_sent(uuid,text) to authenticated;

commit;
