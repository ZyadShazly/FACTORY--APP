begin;

drop policy if exists profiles_select_all on public.profiles;
drop policy if exists profiles_select_scoped on public.profiles;
create policy profiles_select_scoped
on public.profiles
for select
to authenticated
using (
  id = auth.uid()
  or public.current_identity_role() in ('owner','manager')
);

commit;
