-- Permit exactly one internal actual-cost link while preserving every immutable ledger field.
begin;

create or replace function private.allow_inventory_cost_link()
returns trigger language plpgsql set search_path=public,private,pg_temp as $$
begin
  if tg_op='UPDATE'
     and old.actual_cost_entry_id is null
     and new.actual_cost_entry_id is not null
     and new.id=old.id
     and new.movement_number=old.movement_number
     and new.movement_type=old.movement_type
     and new.inventory_item_id=old.inventory_item_id
     and new.warehouse_id=old.warehouse_id
     and new.location_id is not distinct from old.location_id
     and new.quantity_delta=old.quantity_delta
     and new.unit_cost=old.unit_cost
     and new.value_delta=old.value_delta
     and new.project_id is not distinct from old.project_id
     and new.goods_receipt_item_id is not distinct from old.goods_receipt_item_id
     and new.reversed_movement_id is not distinct from old.reversed_movement_id
     and new.reason is not distinct from old.reason
     and new.posted_by=old.posted_by
     and new.posted_at=old.posted_at
     and new.metadata=old.metadata then
    return new;
  end if;
  raise exception 'Posted inventory movements are immutable; use reversal workflow';
end $$;

commit;
