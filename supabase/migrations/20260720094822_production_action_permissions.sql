begin;

create or replace function public.plan_production_order(target_order uuid,start_date date,end_date date default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare saved public.production_orders%rowtype;
begin
  if not private.production_action_allowed('production_plan') then raise exception using errcode='42501',message='Production planning access required'; end if;
  if start_date is null or (end_date is not null and end_date<start_date) then raise exception 'Valid production plan dates required'; end if;
  update public.production_orders set status='planned',planned_start_date=start_date,planned_end_date=end_date,cancellation_reason=null,cancelled_at=null,cancelled_by=null
  where id=target_order and status in ('draft','planned') returning * into saved;
  if not found then raise exception 'Draft or planned production order required'; end if;
  return to_jsonb(saved);
end $$;

create or replace function public.release_production_order(target_order uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.production_orders%rowtype;
begin
  if not private.production_action_allowed('production_release') then raise exception using errcode='42501',message='Production release access required'; end if;
  if not exists(select 1 from public.production_orders where id=target_order and project_id is not null) then raise exception 'Production order must be linked to a project'; end if;
  if not exists(select 1 from public.production_material_requirements where production_order_id=target_order) then raise exception 'At least one material requirement is required'; end if;
  update public.production_orders set status='released',released_at=coalesce(released_at,now()),released_by=coalesce(released_by,actor)
  where id=target_order and status='planned' returning * into saved;
  if not found then raise exception 'Planned production order required'; end if;
  return to_jsonb(saved);
end $$;

create or replace function public.issue_production_material(target_requirement uuid,issue_quantity numeric,issue_description text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare req record; movement jsonb; saved public.production_material_requirements%rowtype;
begin
  if not private.production_action_allowed('production_material_issue') then raise exception using errcode='42501',message='Production material issue access required'; end if;
  select r.*,o.project_id,o.status order_status into req from public.production_material_requirements r join public.production_orders o on o.id=r.production_order_id where r.id=target_requirement for update of r,o;
  if not found or req.order_status not in ('released','in_progress') then raise exception 'Released production order required'; end if;
  if req.project_id is null then raise exception 'Production order must be linked to a project'; end if;
  if req.inventory_movement_id is not null or req.issued_quantity<>0 then raise exception 'Material requirement already issued'; end if;
  if issue_quantity is null or issue_quantity<>req.required_quantity then raise exception 'Full required quantity must be issued exactly once'; end if;
  movement:=public.issue_inventory_to_project(req.inventory_item_id,req.warehouse_id,req.project_id,issue_quantity,coalesce(nullif(btrim(issue_description),''),'Production material issue'),req.budget_item_id,req.milestone_id);
  update public.production_material_requirements set issued_quantity=issue_quantity,consumed_quantity=issue_quantity,inventory_movement_id=(movement->>'id')::uuid where id=target_requirement returning * into saved;
  update public.production_orders set status='in_progress',started_at=coalesce(started_at,now()) where id=req.production_order_id and status='released';
  return jsonb_build_object('requirement',to_jsonb(saved),'inventory_movement',movement);
end $$;

create or replace function public.complete_production_order(target_order uuid)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); saved public.production_orders%rowtype;
begin
  if not private.production_action_allowed('production_complete') then raise exception using errcode='42501',message='Production completion access required'; end if;
  select * into saved from public.production_orders where id=target_order for update;
  if not found then raise exception 'Production order not found'; end if;
  if saved.status='completed' then return to_jsonb(saved); end if;
  if saved.status<>'in_progress' then raise exception 'In-progress production order required'; end if;
  if exists(select 1 from public.production_material_requirements where production_order_id=target_order and issued_quantity<required_quantity) then raise exception 'All required materials must be issued before completion'; end if;
  if exists(select 1 from public.production_order_operations where production_order_id=target_order and status not in ('completed','skipped')) then raise exception 'All operations must be completed or skipped'; end if;
  update public.production_orders set status='completed',completed_at=now(),completed_by=actor where id=target_order returning * into saved;
  return to_jsonb(saved);
end $$;

create or replace function public.update_production_operation_status(target_operation uuid,target_status text,actual_minutes numeric default null,operation_note text default null)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare current_row record; saved public.production_order_operations%rowtype;
begin
  if not private.production_action_allowed('production_operation_update') then raise exception using errcode='42501',message='Production operation access required'; end if;
  if target_status not in ('ready','in_progress','completed','skipped') then raise exception 'Invalid operation status'; end if;
  if target_status='skipped' and public.current_identity_role() not in ('owner','manager') then raise exception 'Owner or manager role required to skip an operation'; end if;
  select o.*,po.status order_status into current_row from public.production_order_operations o join public.production_orders po on po.id=o.production_order_id where o.id=target_operation for update of o,po;
  if not found or current_row.order_status not in ('released','in_progress') then raise exception 'Released or in-progress production order required'; end if;
  if current_row.status in ('completed','skipped') then if current_row.status=target_status then return to_jsonb(current_row); end if; raise exception 'Finalized operation is immutable'; end if;
  if (current_row.status='pending' and target_status not in ('ready','skipped')) or (current_row.status='ready' and target_status not in ('in_progress','skipped')) or (current_row.status='in_progress' and target_status not in ('completed','skipped')) then raise exception 'Invalid operation status transition'; end if;
  update public.production_order_operations set status=target_status,started_at=case when target_status='in_progress' then coalesce(started_at,now()) else started_at end,completed_at=case when target_status in ('completed','skipped') then now() else completed_at end,actual_minutes=coalesce(actual_minutes,public.production_order_operations.actual_minutes),note=coalesce(operation_note,public.production_order_operations.note) where id=target_operation returning * into saved;
  if target_status='in_progress' then update public.production_orders set status='in_progress',started_at=coalesce(started_at,now()) where id=saved.production_order_id and status='released'; end if;
  return to_jsonb(saved);
end $$;

commit;