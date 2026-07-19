-- Safe policy cleanup after Project Estimated Budget rollout.
-- Removes only policies whose behavior is fully covered by existing policies.

begin;

-- employees_manage is an ALL policy with the same SELECT predicate as
-- employees_select, so keeping both creates duplicate permissive SELECT checks.
drop policy if exists employees_select on public.employees;

-- profiles_update_manager and profiles_update_manager_v22 are functionally
-- equivalent for owner/manager accounts. Keep the newer v22 policy only.
drop policy if exists profiles_update_manager on public.profiles;

commit;
