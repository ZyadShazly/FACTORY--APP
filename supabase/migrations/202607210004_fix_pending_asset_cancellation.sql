-- Fix cancellation of pending asset assignments.
--
-- Root cause: the PL/pgSQL record variable `item` was shadowed by a SQL alias
-- with the same name inside the settlement guard. PostgreSQL attempted to read
-- the unassigned record variable before the item loop started.
--
-- This replacement is additive and data preserving. It keeps the same public
-- function signature and permissions, locks the assignment and active items,
-- and refuses incomplete historical records without changing quantities.

create or replace function public.cancel_pending_asset_assignment(target_id uuid, reason text)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare
  actor uuid := auth.uid();
  assignment public.asset_assignments%rowtype;
  assignment_item public.asset_assignment_items%rowtype;
  affected numeric := 0;
  active_item_count integer := 0;
begin
  if actor is null or not exists(
    select 1
    from public.profiles
    where id=actor and role='owner' and status='active'
  ) then
    raise exception 'Owner authorization required' using errcode='42501';
  end if;

  if btrim(coalesce(reason,''))='' then
    raise exception 'Emergency reason is required';
  end if;

  select * into assignment
  from public.asset_assignments
  where id=target_id
  for update;

  if assignment.id is null or assignment.status<>'pending_receiver_confirmation' then
    raise exception 'Only a pending assignment can be cancelled';
  end if;

  if exists(
      select 1
      from public.asset_return_events
      where assignment_id=assignment.id
        and status not in ('cancelled','expired')
    )
    or exists(
      select 1
      from public.asset_settlements settlement
      join public.asset_assignment_items linked_item
        on linked_item.id=settlement.assignment_item_id
      where linked_item.assignment_id=assignment.id
        and settlement.status<>'rejected'
    )
  then
    raise exception 'Later return or settlement activity prevents cancellation';
  end if;

  select count(*) into active_item_count
  from public.asset_assignment_items
  where assignment_id=assignment.id
    and is_active;

  if active_item_count=0 then
    raise exception 'Pending assignment has no active items; no quantities were changed';
  end if;

  for assignment_item in
    select *
    from public.asset_assignment_items
    where assignment_id=assignment.id
      and is_active
    order by id
    for update
  loop
    if assignment_item.returned_quantity<>0 or assignment_item.settled_quantity<>0 then
      raise exception 'Assignment quantities are no longer reversible';
    end if;

    insert into public.asset_movements(
      asset_id,movement_type,quantity,available_delta,assigned_delta,
      assignment_id,reason,metadata
    )
    values(
      assignment_item.asset_id,'reversed',assignment_item.quantity,
      assignment_item.quantity,-assignment_item.quantity,
      assignment.id,btrim(reason),
      jsonb_build_object(
        'source','admin_override',
        'override_type','pending_issue_cancelled',
        'actor_id',actor
      )
    );

    update public.asset_assignment_items
    set is_active=false
    where id=assignment_item.id;

    affected:=affected+assignment_item.quantity;
  end loop;

  update public.asset_assignments
  set status='reversed',
      reversed_at=now(),
      reversal_reason=btrim(reason),
      confirmation_token_hash=null,
      override_type='pending_issue_cancelled',
      override_actor_id=actor,
      override_at=now(),
      override_reason=btrim(reason),
      override_source='admin_override',
      updated_by=actor,
      updated_at=now()
  where id=assignment.id;

  insert into public.audit_log(
    table_name,record_id,action,actor_id,old_data,new_data,metadata
  )
  values(
    'asset_assignments',assignment.id::text,'pending_issue_cancelled',actor,
    to_jsonb(assignment),
    (select to_jsonb(current_assignment)
     from public.asset_assignments current_assignment
     where current_assignment.id=assignment.id),
    jsonb_build_object(
      'source','admin_override',
      'reason',btrim(reason),
      'affected_quantity',affected,
      'affected_items',active_item_count
    )
  );

  return jsonb_build_object(
    'ok',true,
    'status','reversed',
    'affected_quantity',affected,
    'affected_items',active_item_count
  );
end
$$;

revoke all on function public.cancel_pending_asset_assignment(uuid,text) from public, anon;
grant execute on function public.cancel_pending_asset_assignment(uuid,text) to authenticated;
