-- Protected warehouse operations on top of the immutable inventory ledger.
begin;

alter table public.inventory_movements
  add column if not exists production_order_id uuid references public.production_orders(id) on delete restrict;

alter table public.inventory_movements drop constraint if exists inventory_movements_movement_type_check;
alter table public.inventory_movements drop constraint if exists inventory_movements_direction_check;
alter table public.inventory_movements add constraint inventory_movements_movement_type_check
  check (movement_type in (
    'receipt','project_issue','receipt_reversal','project_issue_reversal',
    'adjustment_in','adjustment_out','transfer_in','transfer_out',
    'production_return','waste_out','damage_out'
  ));
alter table public.inventory_movements add constraint inventory_movements_direction_check
  check (
    (movement_type in ('receipt','project_issue_reversal','adjustment_in','transfer_in','production_return') and quantity_delta>0)
    or
    (movement_type in ('project_issue','receipt_reversal','adjustment_out','transfer_out','waste_out','damage_out') and quantity_delta<0)
  );

create table if not exists public.inventory_count_sessions (
  id uuid primary key default gen_random_uuid(),
  warehouse_id uuid not null references public.inventory_warehouses(id) on delete restrict,
  status text not null default 'draft' check (status in ('draft','submitted','posted','cancelled')),
  count_date date not null default current_date,
  note text,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  submitted_by uuid references public.profiles(id) on delete restrict,
  posted_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  submitted_at timestamptz,
  posted_at timestamptz
);

create table if not exists public.inventory_count_lines (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.inventory_count_sessions(id) on delete restrict,
  inventory_item_id uuid not null references public.inventory_items(id) on delete restrict,
  system_quantity numeric not null check (system_quantity>=0),
  counted_quantity numeric not null check (counted_quantity>=0),
  variance_quantity numeric generated always as (counted_quantity-system_quantity) stored,
  note text,
  unique(session_id,inventory_item_id)
);

alter table public.inventory_count_sessions enable row level security;
alter table public.inventory_count_lines enable row level security;
revoke all on public.inventory_count_sessions,public.inventory_count_lines from anon,authenticated;

create or replace function private.inventory_manage_allowed()
returns boolean language sql stable security definer set search_path=public,private,pg_temp as $$
  select auth.uid() is not null and public.current_identity_role() in ('owner','manager');
$$;
revoke all on function private.inventory_manage_allowed() from public,anon,authenticated;

create or replace function public.transfer_inventory(
  target_inventory_item uuid,
  source_warehouse uuid,
  destination_warehouse uuid,
  transfer_quantity numeric,
  transfer_reason text,
  source_location uuid default null,
  destination_location uuid default null
) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); bal record; avg_cost numeric; transfer_key uuid:=gen_random_uuid(); out_row public.inventory_movements%rowtype; in_row public.inventory_movements%rowtype;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if source_warehouse=destination_warehouse then raise exception 'Source and destination warehouses must differ'; end if;
  if transfer_quantity is null or transfer_quantity<=0 then raise exception 'Positive transfer quantity required'; end if;
  if btrim(coalesce(transfer_reason,''))='' then raise exception 'Transfer reason required'; end if;
  if source_location is not null and not exists(select 1 from public.inventory_locations where id=source_location and warehouse_id=source_warehouse and active) then raise exception 'Source location does not belong to source warehouse'; end if;
  if destination_location is not null and not exists(select 1 from public.inventory_locations where id=destination_location and warehouse_id=destination_warehouse and active) then raise exception 'Destination location does not belong to destination warehouse'; end if;
  select quantity_on_hand,inventory_value into bal from public.inventory_balances where inventory_item_id=target_inventory_item and warehouse_id=source_warehouse for update;
  if not found or bal.quantity_on_hand<transfer_quantity then raise exception 'Insufficient inventory balance'; end if;
  avg_cost:=case when bal.quantity_on_hand=0 then 0 else round(bal.inventory_value/bal.quantity_on_hand,4) end;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,reason,posted_by,metadata)
  values('transfer_out',target_inventory_item,source_warehouse,source_location,-transfer_quantity,avg_cost,transfer_reason,actor,jsonb_build_object('transfer_id',transfer_key,'destination_warehouse_id',destination_warehouse)) returning * into out_row;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,reason,posted_by,metadata)
  values('transfer_in',target_inventory_item,destination_warehouse,destination_location,transfer_quantity,avg_cost,transfer_reason,actor,jsonb_build_object('transfer_id',transfer_key,'source_warehouse_id',source_warehouse,'source_movement_id',out_row.id)) returning * into in_row;
  return jsonb_build_object('transfer_id',transfer_key,'out_movement',to_jsonb(out_row),'in_movement',to_jsonb(in_row));
end $$;

create or replace function public.adjust_inventory(
  target_inventory_item uuid,
  target_warehouse uuid,
  adjustment_quantity numeric,
  adjustment_reason text,
  target_location uuid default null
) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); bal record; avg_cost numeric; saved public.inventory_movements%rowtype;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if adjustment_quantity is null or adjustment_quantity=0 then raise exception 'Non-zero adjustment quantity required'; end if;
  if btrim(coalesce(adjustment_reason,''))='' then raise exception 'Adjustment reason required'; end if;
  if target_location is not null and not exists(select 1 from public.inventory_locations where id=target_location and warehouse_id=target_warehouse and active) then raise exception 'Location does not belong to warehouse'; end if;
  select quantity_on_hand,inventory_value into bal from public.inventory_balances where inventory_item_id=target_inventory_item and warehouse_id=target_warehouse for update;
  if adjustment_quantity<0 and (not found or bal.quantity_on_hand<abs(adjustment_quantity)) then raise exception 'Insufficient inventory balance'; end if;
  avg_cost:=case when coalesce(bal.quantity_on_hand,0)=0 then 0 else round(bal.inventory_value/bal.quantity_on_hand,4) end;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,reason,posted_by,metadata)
  values(case when adjustment_quantity>0 then 'adjustment_in' else 'adjustment_out' end,target_inventory_item,target_warehouse,target_location,adjustment_quantity,avg_cost,adjustment_reason,actor,jsonb_build_object('source','manual_adjustment')) returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.record_production_inventory_event(
  target_production_order uuid,
  target_inventory_item uuid,
  target_warehouse uuid,
  event_type text,
  event_quantity numeric,
  event_reason text,
  target_location uuid default null
) returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); role_name text:=public.current_identity_role(); bal record; avg_cost numeric; saved public.inventory_movements%rowtype; movement_kind text; signed_qty numeric;
begin
  if actor is null or role_name not in ('owner','manager','production') then raise exception using errcode='42501',message='Production inventory access required'; end if;
  if event_type not in ('return','waste','damage') then raise exception 'Unsupported production inventory event'; end if;
  if event_quantity is null or event_quantity<=0 then raise exception 'Positive event quantity required'; end if;
  if btrim(coalesce(event_reason,''))='' then raise exception 'Event reason required'; end if;
  if not exists(select 1 from public.production_orders where id=target_production_order) then raise exception 'Production order not found'; end if;
  if target_location is not null and not exists(select 1 from public.inventory_locations where id=target_location and warehouse_id=target_warehouse and active) then raise exception 'Location does not belong to warehouse'; end if;
  select quantity_on_hand,inventory_value into bal from public.inventory_balances where inventory_item_id=target_inventory_item and warehouse_id=target_warehouse for update;
  if event_type in ('waste','damage') and (not found or bal.quantity_on_hand<event_quantity) then raise exception 'Insufficient inventory balance'; end if;
  avg_cost:=case when coalesce(bal.quantity_on_hand,0)=0 then 0 else round(bal.inventory_value/bal.quantity_on_hand,4) end;
  movement_kind:=case event_type when 'return' then 'production_return' when 'waste' then 'waste_out' else 'damage_out' end;
  signed_qty:=case when event_type='return' then event_quantity else -event_quantity end;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,production_order_id,reason,posted_by,metadata)
  values(movement_kind,target_inventory_item,target_warehouse,target_location,signed_qty,avg_cost,target_production_order,event_reason,actor,jsonb_build_object('source','production_inventory_event','event_type',event_type)) returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.create_inventory_count_session(target_warehouse uuid,session_note text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.inventory_count_sessions%rowtype;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  insert into public.inventory_count_sessions(warehouse_id,note,created_by) values(target_warehouse,nullif(btrim(coalesce(session_note,'')),''),actor) returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.save_inventory_count_line(target_session uuid,target_inventory_item uuid,target_counted_quantity numeric,line_note text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare session_row public.inventory_count_sessions%rowtype; system_qty numeric; saved public.inventory_count_lines%rowtype;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if target_counted_quantity is null or target_counted_quantity<0 then raise exception 'Counted quantity cannot be negative'; end if;
  select * into session_row from public.inventory_count_sessions where id=target_session for update;
  if not found or session_row.status<>'draft' then raise exception 'Draft count session required'; end if;
  select coalesce(quantity_on_hand,0) into system_qty from public.inventory_balances where inventory_item_id=target_inventory_item and warehouse_id=session_row.warehouse_id;
  insert into public.inventory_count_lines(session_id,inventory_item_id,system_quantity,counted_quantity,note)
  values(target_session,target_inventory_item,coalesce(system_qty,0),target_counted_quantity,nullif(btrim(coalesce(line_note,'')),''))
  on conflict(session_id,inventory_item_id) do update set system_quantity=excluded.system_quantity,counted_quantity=excluded.counted_quantity,note=excluded.note returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.post_inventory_count_session(target_session uuid,posting_reason text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); session_row public.inventory_count_sessions%rowtype; line record; posted_count int:=0;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if btrim(coalesce(posting_reason,''))='' then raise exception 'Posting reason required'; end if;
  select * into session_row from public.inventory_count_sessions where id=target_session for update;
  if not found or session_row.status not in ('draft','submitted') then raise exception 'Open count session required'; end if;
  if not exists(select 1 from public.inventory_count_lines where session_id=target_session) then raise exception 'Count session has no lines'; end if;
  for line in select * from public.inventory_count_lines where session_id=target_session and variance_quantity<>0 loop
    perform public.adjust_inventory(line.inventory_item_id,session_row.warehouse_id,line.variance_quantity,posting_reason||' — جرد '||target_session::text,null);
    posted_count:=posted_count+1;
  end loop;
  update public.inventory_count_sessions set status='posted',submitted_by=coalesce(submitted_by,actor),submitted_at=coalesce(submitted_at,now()),posted_by=actor,posted_at=now() where id=target_session;
  return jsonb_build_object('session_id',target_session,'posted_lines',posted_count,'status','posted');
end $$;

create or replace function public.get_inventory_workspace()
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare role_name text:=public.current_identity_role();
begin
  if auth.uid() is null or role_name not in ('owner','manager','accountant','production') then raise exception using errcode='42501',message='Inventory access required'; end if;
  return jsonb_build_object(
    'items',coalesce((select jsonb_agg(to_jsonb(i) order by i.name) from public.inventory_items i where i.active),'[]'::jsonb),
    'warehouses',coalesce((select jsonb_agg(to_jsonb(w) order by w.name) from public.inventory_warehouses w where w.active),'[]'::jsonb),
    'locations',coalesce((select jsonb_agg(to_jsonb(l) order by l.warehouse_id,l.name) from public.inventory_locations l where l.active),'[]'::jsonb),
    'balances',coalesce((select jsonb_agg(to_jsonb(x) order by x.item_name,x.warehouse_name) from (select b.*,i.name item_name,i.sku,i.unit,w.name warehouse_name,case when b.quantity_on_hand=0 then 0 else b.inventory_value/nullif(b.quantity_on_hand,0) end average_unit_cost from public.inventory_balances b join public.inventory_items i on i.id=b.inventory_item_id join public.inventory_warehouses w on w.id=b.warehouse_id) x),'[]'::jsonb),
    'movements',coalesce((select jsonb_agg(to_jsonb(x) order by x.posted_at desc) from (select m.*,i.name item_name,w.name warehouse_name from public.inventory_movements m join public.inventory_items i on i.id=m.inventory_item_id join public.inventory_warehouses w on w.id=m.warehouse_id order by m.posted_at desc limit 100) x),'[]'::jsonb),
    'count_sessions',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from public.inventory_count_sessions s),'[]'::jsonb),
    'count_lines',coalesce((select jsonb_agg(to_jsonb(l) order by l.session_id,i.name) from public.inventory_count_lines l join public.inventory_items i on i.id=l.inventory_item_id),'[]'::jsonb),
    'capabilities',jsonb_build_object('manage',private.inventory_manage_allowed(),'production_event',role_name in ('owner','manager','production'),'view_financials',role_name in ('owner','manager','accountant'))
  );
end $$;

revoke all on function public.transfer_inventory(uuid,uuid,uuid,numeric,text,uuid,uuid) from public,anon;
revoke all on function public.adjust_inventory(uuid,uuid,numeric,text,uuid) from public,anon;
revoke all on function public.record_production_inventory_event(uuid,uuid,uuid,text,numeric,text,uuid) from public,anon;
revoke all on function public.create_inventory_count_session(uuid,text) from public,anon;
revoke all on function public.save_inventory_count_line(uuid,uuid,numeric,text) from public,anon;
revoke all on function public.post_inventory_count_session(uuid,text) from public,anon;
grant execute on function public.transfer_inventory(uuid,uuid,uuid,numeric,text,uuid,uuid) to authenticated;
grant execute on function public.adjust_inventory(uuid,uuid,numeric,text,uuid) to authenticated;
grant execute on function public.record_production_inventory_event(uuid,uuid,uuid,text,numeric,text,uuid) to authenticated;
grant execute on function public.create_inventory_count_session(uuid,text) to authenticated;
grant execute on function public.save_inventory_count_line(uuid,uuid,numeric,text) to authenticated;
grant execute on function public.post_inventory_count_session(uuid,text) to authenticated;

commit;
