-- Pre-application hardening for inventory operations.
-- Production returns/waste remain disabled until their Actual Cost treatment is specified.
begin;

revoke all on function public.record_production_inventory_event(uuid,uuid,uuid,text,numeric,text,uuid) from public,anon,authenticated;
comment on function public.record_production_inventory_event(uuid,uuid,uuid,text,numeric,text,uuid)
  is 'Reserved and disabled. Do not expose until partial Actual Cost reversal/consumption accounting is implemented.';

create or replace function public.post_inventory_count_session(target_session uuid,posting_reason text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); session_row public.inventory_count_sessions%rowtype; line record; current_qty numeric; posted_count int:=0;
begin
  if not private.inventory_manage_allowed() then raise exception using errcode='42501',message='Owner or manager role required'; end if;
  if btrim(coalesce(posting_reason,''))='' then raise exception 'Posting reason required'; end if;
  select * into session_row from public.inventory_count_sessions where id=target_session for update;
  if not found or session_row.status not in ('draft','submitted') then raise exception 'Open count session required'; end if;
  if not exists(select 1 from public.inventory_count_lines where session_id=target_session) then raise exception 'Count session has no lines'; end if;

  -- Refuse to post stale counts. The user must recount if stock changed after capture.
  for line in select * from public.inventory_count_lines where session_id=target_session loop
    select coalesce(quantity_on_hand,0) into current_qty
    from public.inventory_balances
    where inventory_item_id=line.inventory_item_id and warehouse_id=session_row.warehouse_id
    for update;
    current_qty:=coalesce(current_qty,0);
    if current_qty<>line.system_quantity then
      raise exception 'Inventory changed after count capture; refresh and recount item %',line.inventory_item_id;
    end if;
  end loop;

  for line in select * from public.inventory_count_lines where session_id=target_session and variance_quantity<>0 loop
    perform public.adjust_inventory(line.inventory_item_id,session_row.warehouse_id,line.variance_quantity,posting_reason||' — جرد '||target_session::text,null);
    posted_count:=posted_count+1;
  end loop;
  update public.inventory_count_sessions
  set status='posted',submitted_by=coalesce(submitted_by,actor),submitted_at=coalesce(submitted_at,now()),posted_by=actor,posted_at=now()
  where id=target_session;
  return jsonb_build_object('session_id',target_session,'posted_lines',posted_count,'status','posted');
end $$;

revoke all on function public.post_inventory_count_session(uuid,text) from public,anon;
grant execute on function public.post_inventory_count_session(uuid,text) to authenticated;

commit;
