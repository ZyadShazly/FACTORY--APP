-- Actual Cost Engine hardening after foundation migration 006.
-- Fixes accountant access, protected project total updates, and cross-project references.

begin;

alter table public.project_actual_cost_entries
  add constraint project_actual_cost_reference_key_not_blank
  check (btrim(source_reference_key) <> '') not valid;

alter table public.project_actual_cost_entries
  validate constraint project_actual_cost_reference_key_not_blank;

create or replace function private.actual_cost_has_permission(permission_name text)
returns boolean
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  select case public.current_identity_role()
    when 'owner' then true
    when 'manager' then true
    when 'accountant' then
      permission_name = any(array[
        'project_actual_cost_view',
        'project_actual_cost_create',
        'project_actual_cost_submit'
      ])
      or public.has_permission(permission_name)
    else public.has_permission(permission_name)
  end
$$;

create or replace function private.validate_actual_cost_links()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  linked_project uuid;
begin
  if new.milestone_id is not null then
    select project_id into linked_project
    from public.project_milestones
    where id = new.milestone_id;

    if linked_project is distinct from new.project_id then
      raise exception 'Milestone does not belong to the selected project';
    end if;
  end if;

  if new.budget_item_id is not null then
    select v.project_id into linked_project
    from public.project_budget_items i
    join public.project_budget_versions v on v.id = i.budget_version_id
    where i.id = new.budget_item_id;

    if linked_project is distinct from new.project_id then
      raise exception 'Budget item does not belong to the selected project';
    end if;
  end if;

  return new;
end
$$;

revoke all on function private.validate_actual_cost_links() from public, anon, authenticated;

drop trigger if exists validate_actual_cost_links on public.project_actual_cost_entries;
create trigger validate_actual_cost_links
before insert or update of project_id, milestone_id, budget_item_id
on public.project_actual_cost_entries
for each row execute function private.validate_actual_cost_links();

create or replace function public.approve_project_actual_cost(target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.project_actual_cost_entries%rowtype;
  allocated numeric;
begin
  select * into saved
  from public.project_actual_cost_entries
  where id = target_id
  for update;

  if not found then
    raise exception 'Actual cost not found';
  end if;

  if actor is null or not private.actual_cost_has_permission('project_actual_cost_approve') then
    raise exception 'project_actual_cost_approve permission required';
  end if;

  perform private.actual_cost_assert_mutable(saved.project_id, saved.cost_date);

  if saved.status <> 'submitted' then
    raise exception 'Only submitted cost may be approved';
  end if;

  select coalesce(sum(allocated_amount), 0)
  into allocated
  from public.project_actual_cost_allocations
  where cost_entry_id = target_id;

  if allocated not in (0, saved.amount) then
    raise exception 'Allocations must equal the source amount';
  end if;

  update public.project_actual_cost_entries
  set status = 'approved',
      approved_by = actor,
      approved_at = now(),
      updated_by = actor,
      updated_at = now()
  where id = target_id
  returning * into saved;

  perform set_config('app.project_workspace_rpc', 'on', true);

  update public.projects p
  set actual_cost = coalesce((
        select sum(c.amount)
        from public.project_actual_cost_entries c
        where c.project_id = p.id
          and c.status = 'approved'
      ), 0),
      updated_by = actor
  where p.id = saved.project_id;

  return to_jsonb(saved);
end
$$;

revoke all on function public.approve_project_actual_cost(uuid) from public, anon;
grant execute on function public.approve_project_actual_cost(uuid) to authenticated;

commit;
