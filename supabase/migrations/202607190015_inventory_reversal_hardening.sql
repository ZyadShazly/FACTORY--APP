-- Correct reversal signs and narrow the only allowed posted-movement update.
begin;

alter table public.inventory_movements
  drop constraint if exists inventory_movements_check;

alter table public.inventory_movements
  add constraint inventory_movements_direction_check
  check ((movement_type in ('receipt','project_issue_reversal','adjustment_in') and quantity_delta > 0) or
         (movement_type in ('project_issue','receipt_reversal','adjustment_out') and quantity_delta < 0));

create or replace function private.allow_inventory_cost_link()
returns trigger language plpgsql set search_path=public,private,pg_temp as $$
begin
  if tg_op='UPDATE' and old.actual_cost_entry_id is null and new.actual_cost_entry_id is not null and
     (to_jsonb(new)-'actual_cost_entry_id')=(to_jsonb(old)-'actual_cost_entry_id') then
    return new;
  end if;
  raise exception 'Posted inventory movements are immutable; use reversal workflow';
end $$;

create or replace function public.reverse_inventory_movement(target_movement uuid,reason text)
returns jsonb language plpgsql security definer set search_path=public,private,pg_temp as $$
declare actor uuid:=auth.uid(); original public.inventory_movements%rowtype; saved public.inventory_movements%rowtype;
begin
  if actor is null or public.current_identity_role()<>'owner' then raise exception 'Owner role required'; end if;
  if btrim(coalesce(reason,''))='' then raise exception 'Reversal reason required'; end if;
  select * into original from public.inventory_movements where id=target_movement for update;
  if not found or original.movement_type not in ('receipt','project_issue') then raise exception 'Reversible posted movement required'; end if;
  if exists(select 1 from public.inventory_movements where reversed_movement_id=original.id) then raise exception 'Movement already reversed'; end if;
  if original.actual_cost_entry_id is not null then perform public.reverse_project_actual_cost(original.actual_cost_entry_id,reason); end if;
  insert into public.inventory_movements(movement_type,inventory_item_id,warehouse_id,location_id,quantity_delta,unit_cost,project_id,reversed_movement_id,reason,posted_by,metadata)
  values(case original.movement_type when 'receipt' then 'receipt_reversal' else 'project_issue_reversal' end,
         original.inventory_item_id,original.warehouse_id,original.location_id,-original.quantity_delta,
         original.unit_cost,original.project_id,original.id,reason,actor,jsonb_build_object('reversal_of',original.id))
  returning * into saved;
  return to_jsonb(saved);
end $$;

commit;
