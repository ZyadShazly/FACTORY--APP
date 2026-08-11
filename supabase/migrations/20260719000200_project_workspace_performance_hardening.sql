begin;

create index if not exists project_members_profile_idx
  on public.project_members(profile_id) where profile_id is not null;
create index if not exists project_members_employee_idx
  on public.project_members(employee_id) where employee_id is not null;
create index if not exists project_members_added_by_idx
  on public.project_members(added_by) where added_by is not null;
create index if not exists project_milestones_created_by_idx
  on public.project_milestones(created_by) where created_by is not null;
create index if not exists project_milestones_updated_by_idx
  on public.project_milestones(updated_by) where updated_by is not null;
create index if not exists projects_created_by_idx
  on public.projects(created_by) where created_by is not null;
create index if not exists projects_progress_updated_by_idx
  on public.projects(progress_updated_by) where progress_updated_by is not null;
create index if not exists projects_lifecycle_changed_by_idx
  on public.projects(lifecycle_changed_by) where lifecycle_changed_by is not null;
create index if not exists projects_updated_by_idx
  on public.projects(updated_by) where updated_by is not null;

drop policy if exists project_realtime_signal_select on public.project_realtime_signal;
create policy project_realtime_signal_select
on public.project_realtime_signal
for select
to authenticated
using (
  (select private.project_profile_active())
  and (
    (select public.current_identity_role()) in ('owner','manager')
    or exists (
      select 1
      from public.project_members pm
      where pm.active
        and (pm.start_date is null or pm.start_date <= current_date)
        and (pm.end_date is null or pm.end_date >= current_date)
        and (
          pm.profile_id = (select auth.uid())
          or exists (
            select 1
            from public.profiles p
            where p.id = (select auth.uid())
              and p.employee_id = pm.employee_id
          )
        )
    )
  )
);

commit;
