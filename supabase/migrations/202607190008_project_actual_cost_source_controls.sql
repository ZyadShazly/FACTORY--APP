-- Source-specific controls for Project Actual Cost.

begin;

create or replace function private.validate_actual_cost_source_controls()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor_role text := public.current_identity_role();
begin
  if new.source_type = 'manual_adjustment'
     and auth.uid() is not null
     and actor_role <> 'owner' then
    raise exception 'Only Owner may create manual actual cost adjustments';
  end if;

  if new.source_type = 'warehouse_issue_line'
     and new.cost_category <> 'material' then
    raise exception 'Warehouse issue costs must use the material category';
  end if;

  if new.source_type = 'factory_labor_allocation'
     and new.cost_category <> 'labor' then
    raise exception 'Factory labor allocations must use the labor category';
  end if;

  if new.source_type = 'asset_consumption_line'
     and new.cost_category <> 'asset_consumption' then
    raise exception 'Asset consumption costs must use the asset_consumption category';
  end if;

  if new.source_type = 'employee_cash_custody_settlement_line'
     and new.cost_category <> 'employee_cash_custody' then
    raise exception 'Employee cash custody settlements must use the employee_cash_custody category';
  end if;

  if new.source_type = 'petty_cash_settlement_line'
     and new.cost_category <> 'petty_cash' then
    raise exception 'Petty cash settlements must use the petty_cash category';
  end if;

  return new;
end
$$;

revoke all on function private.validate_actual_cost_source_controls() from public, anon, authenticated;

drop trigger if exists validate_actual_cost_source_controls on public.project_actual_cost_entries;
create trigger validate_actual_cost_source_controls
before insert or update of source_type, cost_category
on public.project_actual_cost_entries
for each row execute function private.validate_actual_cost_source_controls();

commit;
