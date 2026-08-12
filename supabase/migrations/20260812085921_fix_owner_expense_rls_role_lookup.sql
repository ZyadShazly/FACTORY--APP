begin;

drop policy if exists expenses_select_finance_roles on public.expenses;
create policy expenses_select_finance_roles
on public.expenses
for select
to authenticated
using (public.current_identity_role() in ('owner','manager','accountant'));

commit;
