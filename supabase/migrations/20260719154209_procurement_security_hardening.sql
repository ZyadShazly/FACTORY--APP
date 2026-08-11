-- Procurement relationship and visibility hardening.
begin;

create or replace function private.validate_procurement_relationships()
returns trigger language plpgsql set search_path=public,private,pg_temp as $$
declare expected_request uuid; expected_order uuid;
begin
 if tg_table_name='supplier_quote_items' then
  select purchase_request_id into expected_request from public.supplier_quotes where id=new.supplier_quote_id;
  if not exists(select 1 from public.purchase_request_items where id=new.purchase_request_item_id and purchase_request_id=expected_request) then
   raise exception 'Quote item must belong to the same purchase request';
  end if;
 elsif tg_table_name='goods_receipt_items' then
  select purchase_order_id into expected_order from public.goods_receipts where id=new.goods_receipt_id;
  if not exists(select 1 from public.purchase_order_items where id=new.purchase_order_item_id and purchase_order_id=expected_order) then
   raise exception 'Receipt item must belong to the same purchase order';
  end if;
 elsif tg_table_name='supplier_invoice_lines' then
  select purchase_order_id into expected_order from public.supplier_invoices where id=new.supplier_invoice_id;
  if new.purchase_order_item_id is not null and not exists(select 1 from public.purchase_order_items where id=new.purchase_order_item_id and purchase_order_id=expected_order) then
   raise exception 'Invoice line must belong to the same purchase order';
  end if;
  if new.goods_receipt_item_id is not null and not exists(select 1 from public.goods_receipt_items gri join public.goods_receipts gr on gr.id=gri.goods_receipt_id where gri.id=new.goods_receipt_item_id and gr.purchase_order_id=expected_order) then
   raise exception 'Invoice receipt line must belong to the same purchase order';
  end if;
 end if;
 return new;
end $$;

revoke all on function private.validate_procurement_relationships() from public,anon,authenticated;
drop trigger if exists supplier_quote_items_relationship_guard on public.supplier_quote_items;
create trigger supplier_quote_items_relationship_guard before insert or update on public.supplier_quote_items for each row execute function private.validate_procurement_relationships();
drop trigger if exists goods_receipt_items_relationship_guard on public.goods_receipt_items;
create trigger goods_receipt_items_relationship_guard before insert or update on public.goods_receipt_items for each row execute function private.validate_procurement_relationships();
drop trigger if exists supplier_invoice_lines_relationship_guard on public.supplier_invoice_lines;
create trigger supplier_invoice_lines_relationship_guard before insert or update on public.supplier_invoice_lines for each row execute function private.validate_procurement_relationships();

create or replace function public.get_procurement_workspace(target_project uuid default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
begin
 if auth.uid() is null or public.current_identity_role() not in('owner','manager','accountant','production') then raise exception 'Procurement access required'; end if;
 if target_project is not null and not private.project_can_view(target_project) then raise exception 'Project access denied'; end if;
 return jsonb_build_object(
  'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from public.purchase_requests r where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.purchase_orders o where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'receipts',coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at desc) from public.goods_receipts g join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'invoices',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.supplier_invoices i where target_project is null or i.project_id=target_project),'[]'::jsonb)
 );
end $$;
revoke all on function public.get_procurement_workspace(uuid) from public,anon;
grant execute on function public.get_procurement_workspace(uuid) to authenticated;
commit;