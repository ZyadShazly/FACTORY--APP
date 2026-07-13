-- Accountants can view bonus-derived values only after payroll approval.
drop policy if exists payroll_select on public.payroll;
create policy payroll_select_manager on public.payroll for select using (public.current_app_role() = 'manager');

create or replace function public.get_payroll_visible()
returns setof jsonb language sql stable security definer set search_path = public as $$
  select case
    when public.current_app_role() = 'manager' or p.status <> 'draft' then to_jsonb(p)
    else to_jsonb(p) - array['bonuses','net_salary']
  end
  from public.payroll p
  where public.has_permission('payroll_view')
  order by p.created_at;
$$;

grant execute on function public.get_payroll_visible() to authenticated;
