-- Protect expense history and provide an auditable cancellation path.
-- Existing expense rows are preserved unchanged.
begin;

alter table public.expenses
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.profiles(id) on delete set null,
  add column if not exists cancellation_reason text;

create index if not exists expenses_cancelled_by_idx
  on public.expenses(cancelled_by) where cancelled_by is not null;

drop policy if exists active_profile_restriction on public.expenses;
drop policy if exists expenses_active_profile_restriction on public.expenses;
create policy expenses_active_profile_restriction
on public.expenses as restrictive
for all to authenticated
using (public.is_current_profile_active())
with check (public.is_current_profile_active());

drop policy if exists expenses_delete_manager on public.expenses;

create or replace function private.guard_expense_financial_history()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='DELETE' then
    raise exception using errcode='23514',
      message='Expense history cannot be deleted; use cancel_expense';
  end if;

  if old.cancelled_at is not null and new is distinct from old then
    raise exception using errcode='23514',message='Cancelled expense is immutable';
  end if;

  if old.actual_cost_entry_id is not null and (
    new.project_id is distinct from old.project_id
    or new.amount is distinct from old.amount
    or new.expense_date is distinct from old.expense_date
    or new.category is distinct from old.category
  ) then
    raise exception using errcode='23514',
      message='Posted expense financial fields are immutable; reverse it first';
  end if;
  return new;
end $$;

revoke all on function private.guard_expense_financial_history()
  from public,anon,authenticated;

drop trigger if exists guard_expense_financial_history on public.expenses;
create trigger guard_expense_financial_history
before update or delete on public.expenses
for each row execute function private.guard_expense_financial_history();

create or replace function public.cancel_expense(
  target_expense_id uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid := auth.uid();
  actor_role text := public.current_identity_role();
  expense_row public.expenses%rowtype;
  cost_status text;
begin
  if actor is null or actor_role not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if btrim(coalesce(reason,''))='' then
    raise exception using errcode='22023',message='Cancellation reason is required';
  end if;

  select * into expense_row
  from public.expenses
  where id=target_expense_id
  for update;
  if not found then raise exception 'Expense not found'; end if;
  if expense_row.cancelled_at is not null then return to_jsonb(expense_row); end if;

  if expense_row.actual_cost_entry_id is not null then
    select status into cost_status
    from public.project_actual_cost_entries
    where id=expense_row.actual_cost_entry_id
    for update;

    if cost_status='approved' then
      if actor_role <> 'owner' then
        raise exception using errcode='42501',
          message='Owner role required to reverse an approved expense';
      end if;
      perform public.reverse_project_actual_cost(
        expense_row.actual_cost_entry_id,btrim(reason)
      );
    elsif cost_status='submitted' then
      perform public.reject_project_actual_cost(
        expense_row.actual_cost_entry_id,btrim(reason)
      );
    elsif cost_status not in ('rejected','reversed') then
      raise exception 'Expense Actual Cost state cannot be cancelled';
    end if;
  end if;

  update public.expenses
  set cancelled_at=now(),cancelled_by=actor,cancellation_reason=btrim(reason),
      cost_posting_status=case
        when actual_cost_entry_id is null then 'reversed'
        else cost_posting_status
      end
  where id=target_expense_id
  returning * into expense_row;

  return to_jsonb(expense_row);
end $$;

revoke all on function public.cancel_expense(uuid,text)
  from public,anon,authenticated;
grant execute on function public.cancel_expense(uuid,text) to authenticated;

commit;
