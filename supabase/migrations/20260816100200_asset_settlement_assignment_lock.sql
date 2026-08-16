create or replace function public.approve_asset_settlement(target_id uuid, approve boolean, decision_notes text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  s public.asset_settlements%rowtype;
  ai public.asset_assignment_items%rowtype;
  a public.assets%rowtype;
  remaining numeric;
  returned_total numeric;
  pending_count integer;
  next_assignment_status text;
begin
  if not public.has_permission('assets_approve_loss') then raise exception using errcode='42501',message='assets_approve_loss permission required'; end if;
  select * into s from public.asset_settlements where id=target_id and status='pending_approval' for update;
  if s.id is null then raise exception 'Pending settlement not found'; end if;
  if public.current_identity_role()='accountant' and s.created_by=auth.uid() then raise exception 'Maker-checker: accountant cannot approve own settlement'; end if;
  select * into ai from public.asset_assignment_items where id=s.assignment_item_id for update;
  if ai.id is null then raise exception 'Assignment item not found'; end if;

  perform 1 from public.asset_assignments where id=ai.assignment_id for update;
  if not found then raise exception 'Asset assignment not found'; end if;

  if not approve then
    update public.asset_settlements
    set status='rejected',rejected_by=auth.uid(),rejected_at=now(),notes=concat_ws(E'\n',notes,decision_notes),updated_at=now()
    where id=s.id;

    select count(*) into pending_count
    from public.asset_settlements x
    join public.asset_assignment_items xai on xai.id=x.assignment_item_id
    where xai.assignment_id=ai.assignment_id and x.status='pending_approval' and x.id<>s.id;

    select coalesce(sum(quantity-returned_quantity-settled_quantity),0),coalesce(sum(returned_quantity),0)
      into remaining,returned_total
    from public.asset_assignment_items where assignment_id=ai.assignment_id;

    next_assignment_status:=case
      when pending_count>0 then 'settlement_pending'
      when remaining<=0 then 'closed'
      when returned_total>0 then 'partially_returned'
      else 'issued'
    end;
    update public.asset_assignments set status=next_assignment_status,updated_at=now() where id=ai.assignment_id;

    insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
    values('asset_settlements',s.id::text,'asset_settlement_rejected',auth.uid(),
      jsonb_build_object('status','rejected','assignment_id',ai.assignment_id,'assignment_status',next_assignment_status),
      jsonb_build_object('decision_notes',decision_notes));
    return jsonb_build_object('ok',true,'status','rejected','assignment_status',next_assignment_status);
  end if;

  select * into a from public.assets where id=ai.asset_id for update;
  insert into public.asset_movements(asset_id,movement_type,quantity,total_delta,assigned_delta,assignment_id,settlement_id,reason)
  values(a.id,case when s.settlement_type in ('lost','stolen','damaged') then s.settlement_type else 'adjusted' end,
         s.quantity,-s.quantity,-s.quantity,ai.assignment_id,s.id,s.reason);
  update public.asset_assignment_items
  set settled_quantity=settled_quantity+s.quantity,
      is_active=(returned_quantity+settled_quantity+s.quantity<quantity)
  where id=ai.id;
  update public.asset_settlements
  set status='approved',approved_by=auth.uid(),approved_at=now(),notes=concat_ws(E'\n',notes,decision_notes),updated_at=now()
  where id=s.id;
  if a.tracking_mode='serialized' then
    update public.assets set operational_status=case when s.settlement_type in ('lost','stolen','damaged') then s.settlement_type else 'retired' end where id=a.id;
  end if;
  select coalesce(sum(quantity-returned_quantity-settled_quantity),0) into remaining
  from public.asset_assignment_items where assignment_id=ai.assignment_id;
  update public.asset_assignments set status=case when remaining=0 then 'closed' else 'settlement_pending' end,updated_at=now()
  where id=ai.assignment_id;
  return jsonb_build_object('ok',true,'status','approved');
end
$$;
