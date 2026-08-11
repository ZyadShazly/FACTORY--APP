-- UAT-007: idempotent production cancellation with complete audit evidence.
begin;

create or replace function public.cancel_production_order(target_order uuid,reason text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid:=(select auth.uid());
  saved public.production_orders%rowtype;
  old_row public.production_orders%rowtype;
  movement_id uuid;
  reversal_ids uuid[]:='{}'::uuid[];
  reversal_result jsonb;
  command_id uuid:=gen_random_uuid();
begin
  if actor is null or public.current_identity_role()<>'owner' then raise exception using errcode='42501',message='Owner role required'; end if;
  if btrim(coalesce(reason,''))='' then raise exception using errcode='22023',message='Cancellation reason required'; end if;
  select * into old_row from public.production_orders where id=target_order for update;
  if not found then raise exception using errcode='P0002',message='Production order not found'; end if;
  if old_row.status='cancelled' then return to_jsonb(old_row); end if;
  if old_row.status='completed' then raise exception using errcode='23514',message='Completed production order cannot be cancelled'; end if;

  for movement_id in
    select distinct x.inventory_movement_id from (
      select i.inventory_movement_id from public.production_material_issues i
      join public.production_material_requirements r on r.id=i.requirement_id where r.production_order_id=target_order
      union all
      select r.inventory_movement_id from public.production_material_requirements r
      where r.production_order_id=target_order and r.inventory_movement_id is not null
    ) x where x.inventory_movement_id is not null
  loop
    if not exists(select 1 from public.inventory_movements where reversed_movement_id=movement_id) then
      reversal_result:=public.reverse_inventory_movement(movement_id,btrim(reason));
      reversal_ids:=array_append(reversal_ids,(reversal_result->>'id')::uuid);
    end if;
  end loop;

  update public.production_orders set status='cancelled',cancelled_at=now(),cancelled_by=actor,cancellation_reason=btrim(reason)
  where id=target_order returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('production_orders',saved.id::text,'production_order_cancelled',actor,to_jsonb(old_row),to_jsonb(saved),
    jsonb_build_object('command_id',command_id,'reason',btrim(reason),'source_status',old_row.status,'final_status',saved.status,'reversal_references',to_jsonb(reversal_ids)));
  return to_jsonb(saved)||jsonb_build_object('command_id',command_id,'reversal_references',to_jsonb(reversal_ids));
end $$;

revoke all on function public.cancel_production_order(uuid,text) from public,anon;
grant execute on function public.cancel_production_order(uuid,text) to authenticated;

commit;
