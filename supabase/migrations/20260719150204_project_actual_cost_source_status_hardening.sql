-- Keep operational source rows synchronized with Actual Cost workflow state.
-- This closes the generic reversal path so a source cannot remain marked posted
-- after its approved Actual Cost entry is reversed.

begin;

create or replace function private.sync_operational_source_actual_cost_status()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  next_status text;
begin
  if new.source_type not in ('material_purchase','daily_labor','payroll_allocation','approved_expense') then
    return new;
  end if;

  next_status := case new.status
    when 'submitted' then 'submitted'
    when 'approved' then 'posted'
    when 'rejected' then 'rejected'
    when 'reversed' then 'reversed'
    else 'not_posted'
  end;

  if new.source_type = 'material_purchase' then
    update public.material_purchases
       set actual_cost_entry_id = new.id,
           cost_posting_status = next_status,
           cost_posted_at = case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
           cost_posted_by = case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
     where id = new.source_id;
  elsif new.source_type = 'daily_labor' then
    update public.daily_labor
       set actual_cost_entry_id = new.id,
           cost_posting_status = next_status,
           cost_posted_at = case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
           cost_posted_by = case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
     where id = new.source_id;
  elsif new.source_type = 'payroll_allocation' then
    update public.payroll
       set actual_cost_entry_id = new.id,
           cost_posting_status = next_status,
           cost_posted_at = case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
           cost_posted_by = case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
     where id = new.source_id;
  else
    update public.expenses
       set actual_cost_entry_id = new.id,
           cost_posting_status = next_status,
           cost_posted_at = case when new.status='approved' then coalesce(cost_posted_at,now()) else cost_posted_at end,
           cost_posted_by = case when new.status='approved' then coalesce(new.approved_by,cost_posted_by) else cost_posted_by end
     where id = new.source_id;
  end if;

  return new;
end $$;

revoke all on function private.sync_operational_source_actual_cost_status() from public,anon,authenticated;

drop trigger if exists sync_operational_source_actual_cost_status on public.project_actual_cost_entries;
create trigger sync_operational_source_actual_cost_status
after insert or update of status on public.project_actual_cost_entries
for each row execute function private.sync_operational_source_actual_cost_status();

commit;