-- Reconcile the legacy absolute employee-delete guard with the new checked delete RPC.
-- Direct deletes remain blocked. Only delete_employee_if_unused() may proceed after
-- it proves that the employee has no linked account or transaction.

create or replace function public.prevent_employee_delete()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if current_setting('app.employee_admin_rpc', true) = 'on' then
    return old;
  end if;

  raise exception using
    errcode = '23503',
    message = 'Employees cannot be deleted directly; use the checked employee deletion workflow';
end;
$$;

revoke all on function public.prevent_employee_delete() from public, anon, authenticated;
