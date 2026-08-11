-- Make expense creation permission-safe, immutable and retry-safe.
begin;

alter table public.expenses add column if not exists command_id uuid;

create unique index if not exists expenses_command_uidx
  on public.expenses(command_id) where command_id is not null;

create or replace function public.post_expense(
  expense_category text,
  expense_amount numeric,
  spent_on date default current_date,
  expense_notes text default null,
  target_project uuid default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare saved public.expenses%rowtype;
begin
  if not private.commercial_page_allowed('expenses') then
    raise exception using errcode='42501',message='Expense access required';
  end if;
  if nullif(btrim(expense_category),'') is null then
    raise exception using errcode='22023',message='Expense category is required';
  end if;
  if expense_amount is null or expense_amount<=0 or expense_amount='NaN'::numeric then
    raise exception using errcode='22023',message='Expense amount must be positive';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;

  select * into saved from public.expenses where expenses.command_id=post_expense.command_id;
  if found then return to_jsonb(saved); end if;

  if target_project is not null then
    perform 1 from public.projects
    where id=target_project and lifecycle not in ('closed','cancelled')
    for update;
    if not found then
      raise exception using errcode='23503',message='An active project is required for a project expense';
    end if;
  end if;

  insert into public.expenses(category,amount,expense_date,notes,project_id,created_by,command_id)
  values(
    btrim(expense_category),expense_amount,coalesce(spent_on,current_date),
    nullif(btrim(expense_notes),''),target_project,auth.uid(),command_id
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'expenses',saved.id::text,'expense_posted',auth.uid(),to_jsonb(saved),
    jsonb_build_object('project_id',target_project,'amount',expense_amount)
  );
  return to_jsonb(saved);
end
$$;

revoke all on function public.post_expense(text,numeric,date,text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.post_expense(text,numeric,date,text,uuid,uuid) to authenticated;

drop policy if exists expenses_insert_all on public.expenses;
drop policy if exists expenses_insert_permission on public.expenses;
drop policy if exists expenses_update_permission on public.expenses;
revoke insert,update,delete on table public.expenses from anon,authenticated;

commit;
