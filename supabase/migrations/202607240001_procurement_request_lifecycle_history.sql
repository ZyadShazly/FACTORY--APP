-- Durable purchase-request lifecycle and audit history.
-- Additive migration: preserves all existing requests and their current statuses.
begin;

alter table public.purchase_requests
  drop constraint if exists purchase_requests_status_check;

alter table public.purchase_requests
  add constraint purchase_requests_status_check
  check (status in ('draft','submitted','approved','rejected','cancelled','converted','completed'));

create table if not exists public.purchase_request_status_history (
  id uuid primary key default gen_random_uuid(),
  purchase_request_id uuid not null references public.purchase_requests(id) on delete restrict,
  from_status text,
  to_status text not null,
  changed_by uuid references public.profiles(id) on delete set null,
  reason text,
  event_type text not null default 'transition' check (event_type in ('created','transition','baseline')),
  metadata jsonb not null default '{}'::jsonb,
  changed_at timestamptz not null default now(),
  check (from_status is null or from_status in ('draft','submitted','approved','rejected','cancelled','converted','completed')),
  check (to_status in ('draft','submitted','approved','rejected','cancelled','converted','completed'))
);

create index if not exists purchase_request_status_history_request_idx
  on public.purchase_request_status_history(purchase_request_id,changed_at desc);

alter table public.purchase_request_status_history enable row level security;
revoke all on public.purchase_request_status_history from anon,authenticated;

create or replace function private.record_purchase_request_status_history()
returns trigger
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
declare
  transition_reason text;
begin
  if tg_op='INSERT' then
    insert into public.purchase_request_status_history(
      purchase_request_id,from_status,to_status,changed_by,event_type,metadata,changed_at
    ) values (
      new.id,null,new.status,auth.uid(),'created',jsonb_build_object('request_number',new.request_number),new.created_at
    );
    return new;
  end if;

  if new.status is distinct from old.status then
    transition_reason:=case
      when new.status='rejected' then new.rejection_reason
      else null
    end;
    insert into public.purchase_request_status_history(
      purchase_request_id,from_status,to_status,changed_by,reason,event_type,metadata
    ) values (
      new.id,old.status,new.status,auth.uid(),transition_reason,'transition',
      jsonb_build_object('request_number',new.request_number)
    );
  end if;
  return new;
end $$;

-- Existing records receive an explicit baseline, not invented historical transitions.
insert into public.purchase_request_status_history(
  purchase_request_id,from_status,to_status,changed_by,event_type,metadata,changed_at
)
select r.id,null,r.status,null,'baseline',
       jsonb_build_object('request_number',r.request_number,'note','Current state when lifecycle history was enabled'),
       r.updated_at
from public.purchase_requests r
where not exists (
  select 1 from public.purchase_request_status_history h where h.purchase_request_id=r.id
);

drop trigger if exists purchase_request_status_history_trigger on public.purchase_requests;
create trigger purchase_request_status_history_trigger
after insert or update of status on public.purchase_requests
for each row execute function private.record_purchase_request_status_history();

create or replace function private.complete_purchase_request_from_order()
returns trigger
language plpgsql
security definer
set search_path=public,private,pg_temp
as $$
begin
  if new.purchase_request_id is not null
     and new.status in ('invoiced','closed')
     and old.status is distinct from new.status then
    update public.purchase_requests
       set status='completed',updated_at=now()
     where id=new.purchase_request_id
       and status='converted';
  end if;
  return new;
end $$;

drop trigger if exists complete_purchase_request_from_order_trigger on public.purchase_orders;
create trigger complete_purchase_request_from_order_trigger
after update of status on public.purchase_orders
for each row execute function private.complete_purchase_request_from_order();

create or replace function public.get_procurement_workspace_v2(target_project uuid default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare role_name text:=public.current_identity_role();
begin
 if auth.uid() is null or role_name not in('owner','manager','accountant','production') then raise exception using errcode='42501',message='Procurement access required'; end if;
 if target_project is not null and not private.project_can_view(target_project) then raise exception using errcode='42501',message='Project access denied'; end if;
 return jsonb_build_object(
  'requests',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from public.purchase_requests r where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'request_items',coalesce((select jsonb_agg(to_jsonb(i) order by i.purchase_request_id,i.sequence) from public.purchase_request_items i join public.purchase_requests r on r.id=i.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'request_history',coalesce((select jsonb_agg(to_jsonb(h) order by h.changed_at desc) from public.purchase_request_status_history h join public.purchase_requests r on r.id=h.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'quotes',coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc) from public.supplier_quotes q join public.purchase_requests r on r.id=q.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'quote_items',coalesce((select jsonb_agg(to_jsonb(i)) from public.supplier_quote_items i join public.supplier_quotes q on q.id=i.supplier_quote_id join public.purchase_requests r on r.id=q.purchase_request_id where target_project is null or r.project_id=target_project),'[]'::jsonb),
  'orders',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.purchase_orders o where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'order_items',coalesce((select jsonb_agg(to_jsonb(i) order by i.purchase_order_id,i.sequence) from public.purchase_order_items i join public.purchase_orders o on o.id=i.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'receipts',coalesce((select jsonb_agg(to_jsonb(g) order by g.created_at desc) from public.goods_receipts g join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'receipt_items',coalesce((select jsonb_agg(to_jsonb(i)) from public.goods_receipt_items i join public.goods_receipts g on g.id=i.goods_receipt_id join public.purchase_orders o on o.id=g.purchase_order_id where target_project is null or o.project_id=target_project),'[]'::jsonb),
  'invoices',coalesce((select jsonb_agg(to_jsonb(i) order by i.created_at desc) from public.supplier_invoices i where target_project is null or i.project_id=target_project),'[]'::jsonb),
  'invoice_lines',coalesce((select jsonb_agg(to_jsonb(l)) from public.supplier_invoice_lines l join public.supplier_invoices i on i.id=l.supplier_invoice_id where target_project is null or i.project_id=target_project),'[]'::jsonb),
  'capabilities',jsonb_build_object('request',true,'approve_request',role_name in('owner','manager'),'quote',role_name in('owner','manager','accountant'),'order',role_name in('owner','manager'),'receive',true,'invoice',role_name in('owner','manager'))
 );
end $$;

revoke all on function public.get_procurement_workspace_v2(uuid) from public,anon;
grant execute on function public.get_procurement_workspace_v2(uuid) to authenticated;

commit;
