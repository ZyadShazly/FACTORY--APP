-- Canonical project/base-currency contract.
-- This migration does not rewrite historical monetary rows. It makes future
-- project budgets and actual-cost entries use system_settings.currency_code,
-- rejects mixed-currency writes, and exposes historical mismatches for review.

begin;

create or replace function private.current_base_currency()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select upper(coalesce((select currency_code from public.system_settings where id = true), 'EGP'))
$$;

revoke all on function private.current_base_currency() from public, anon, authenticated;

create or replace function private.enforce_project_base_currency()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare base_currency text := private.current_base_currency();
begin
  new.currency := upper(coalesce(nullif(btrim(new.currency), ''), base_currency));
  if new.currency <> base_currency then
    raise exception 'Project monetary records must use the configured base currency (%)', base_currency
      using errcode = '23514';
  end if;
  return new;
end
$$;

revoke all on function private.enforce_project_base_currency() from public, anon, authenticated;

drop trigger if exists enforce_project_budget_base_currency on public.project_budget_versions;
create trigger enforce_project_budget_base_currency
before insert or update of currency on public.project_budget_versions
for each row execute function private.enforce_project_base_currency();

drop trigger if exists enforce_project_budget_template_base_currency on public.project_budget_templates;
create trigger enforce_project_budget_template_base_currency
before insert or update of currency on public.project_budget_templates
for each row execute function private.enforce_project_base_currency();

drop trigger if exists enforce_project_actual_cost_base_currency on public.project_actual_cost_entries;
create trigger enforce_project_actual_cost_base_currency
before insert or update of currency on public.project_actual_cost_entries
for each row execute function private.enforce_project_base_currency();

create or replace function public.create_project_budget_draft(target_project uuid, currency_code text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  next_version integer;
  created public.project_budget_versions%rowtype;
  base_currency text := private.current_base_currency();
  requested_currency text := upper(nullif(btrim(currency_code), ''));
begin
  if actor is null or not private.project_budget_can(target_project, 'project_budget_create') then
    raise exception 'project_budget_create permission required' using errcode = '42501';
  end if;
  if requested_currency is not null and requested_currency <> base_currency then
    raise exception 'Budget currency must match the configured base currency (%)', base_currency
      using errcode = '23514';
  end if;
  perform 1 from public.projects where id = target_project for update;
  if not found then raise exception 'Project not found'; end if;
  select coalesce(max(version_number), 0) + 1 into next_version
  from public.project_budget_versions where project_id = target_project;
  perform set_config('app.project_budget_rpc', 'on', true);
  insert into public.project_budget_versions(project_id, version_number, currency, created_by, updated_by)
  values(target_project, next_version, base_currency, actor, actor)
  returning * into created;
  insert into public.project_budget_sections(budget_version_id, section_key, section_name, sequence)
  values(created.id, 'general', 'عام', 0);
  perform private.project_budget_activity(
    target_project,
    'budget_created',
    'تم إنشاء مسودة ميزانية تقديرية',
    jsonb_build_object('budget_version_id', created.id, 'version_number', created.version_number, 'currency', base_currency)
  );
  return to_jsonb(created);
end
$$;

revoke all on function public.create_project_budget_draft(uuid, text) from public, anon;
grant execute on function public.create_project_budget_draft(uuid, text) to authenticated;

create or replace function public.save_project_actual_cost(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  saved public.project_actual_cost_entries%rowtype;
  target_id uuid := nullif(payload->>'id', '')::uuid;
  target_project uuid := (payload->>'project_id')::uuid;
  target_date date := coalesce(nullif(payload->>'cost_date', '')::date, current_date);
  base_currency text := private.current_base_currency();
  requested_currency text := upper(nullif(btrim(payload->>'currency'), ''));
begin
  if actor is null or not private.actual_cost_has_permission('project_actual_cost_create') then
    raise exception 'project_actual_cost_create permission required' using errcode = '42501';
  end if;
  if not private.project_can_view(target_project) then
    raise exception 'Project access denied' using errcode = '42501';
  end if;
  if requested_currency is not null and requested_currency <> base_currency then
    raise exception 'Actual cost currency must match the configured base currency (%)', base_currency
      using errcode = '23514';
  end if;
  perform private.actual_cost_assert_mutable(target_project, target_date);
  if coalesce(nullif(payload->>'quantity', '')::numeric, 0) < 0
    or coalesce(nullif(payload->>'unit_cost', '')::numeric, 0) < 0 then
    raise exception 'Invalid cost values';
  end if;
  if btrim(coalesce(payload->>'description', '')) = '' then raise exception 'Description is required'; end if;

  if target_id is null then
    insert into public.project_actual_cost_entries(
      project_id, milestone_id, budget_item_id, cost_category, source_type, source_id, source_line_reference,
      source_revision, source_reference_key, description, quantity, unit, unit_cost, currency, cost_date, notes,
      created_by, updated_by, metadata
    ) values (
      target_project, nullif(payload->>'milestone_id', '')::uuid, nullif(payload->>'budget_item_id', '')::uuid,
      payload->>'cost_category', payload->>'source_type', (payload->>'source_id')::uuid,
      coalesce(nullif(payload->>'source_line_reference', ''), 'main'), coalesce(nullif(payload->>'source_revision', '')::integer, 1),
      payload->>'source_reference_key', btrim(payload->>'description'), coalesce(nullif(payload->>'quantity', '')::numeric, 0),
      coalesce(nullif(payload->>'unit', ''), 'وحدة'), coalesce(nullif(payload->>'unit_cost', '')::numeric, 0),
      base_currency, target_date, nullif(btrim(payload->>'notes'), ''), actor, actor,
      coalesce(payload->'metadata', '{}'::jsonb)
    ) returning * into saved;
  else
    update public.project_actual_cost_entries set
      milestone_id = nullif(payload->>'milestone_id', '')::uuid,
      budget_item_id = nullif(payload->>'budget_item_id', '')::uuid,
      cost_category = payload->>'cost_category', description = btrim(payload->>'description'),
      quantity = coalesce(nullif(payload->>'quantity', '')::numeric, quantity),
      unit = coalesce(nullif(payload->>'unit', ''), unit),
      unit_cost = coalesce(nullif(payload->>'unit_cost', '')::numeric, unit_cost),
      cost_date = target_date, notes = nullif(btrim(payload->>'notes'), ''), updated_by = actor, updated_at = now()
    where id = target_id and project_id = target_project and status = 'draft'
    returning * into saved;
    if not found then raise exception 'Draft actual cost not found'; end if;
    if saved.currency <> base_currency then
      raise exception 'Historical actual cost currency differs from the current base currency; reconcile it before editing'
        using errcode = '23514';
    end if;
  end if;
  return to_jsonb(saved);
end
$$;

revoke all on function public.save_project_actual_cost(jsonb) from public, anon;
grant execute on function public.save_project_actual_cost(jsonb) to authenticated;

create or replace function private.protect_system_base_currency()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.currency_code is distinct from old.currency_code and (
    exists(select 1 from public.project_budget_versions limit 1)
    or exists(select 1 from public.project_actual_cost_entries limit 1)
    or exists(select 1 from public.sales limit 1)
    or exists(select 1 from public.material_purchases limit 1)
    or exists(select 1 from public.expenses limit 1)
  ) then
    raise exception 'Base currency cannot be changed after monetary history exists; use a reviewed currency migration and reconciliation'
      using errcode = '23514';
  end if;
  return new;
end
$$;

revoke all on function private.protect_system_base_currency() from public, anon, authenticated;
drop trigger if exists protect_system_base_currency on public.system_settings;
create trigger protect_system_base_currency
before update of currency_code on public.system_settings
for each row execute function private.protect_system_base_currency();

create or replace function public.get_project_currency_reconciliation()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  base_currency text := private.current_base_currency();
begin
  if actor is null or not exists(
    select 1 from public.profiles where id = actor and role = 'owner' and status = 'active'
  ) then
    raise exception 'Owner authorization required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'base_currency', base_currency,
    'budget_mismatch_count', (select count(*) from public.project_budget_versions where currency <> base_currency),
    'actual_cost_mismatch_count', (select count(*) from public.project_actual_cost_entries where currency <> base_currency),
    'template_mismatch_count', (select count(*) from public.project_budget_templates where currency <> base_currency),
    'result_limit', 200,
    'budget_mismatches', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'project_id', project_id, 'version_number', version_number, 'status', status, 'currency', currency) order by created_at)
      from (select * from public.project_budget_versions where currency <> base_currency order by created_at limit 200) mismatches
    ), '[]'::jsonb),
    'actual_cost_mismatches', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'project_id', project_id, 'source_type', source_type, 'source_id', source_id, 'status', status, 'currency', currency) order by created_at)
      from (select * from public.project_actual_cost_entries where currency <> base_currency order by created_at limit 200) mismatches
    ), '[]'::jsonb),
    'template_mismatches', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'template_name', template_name, 'currency', currency) order by created_at)
      from (select * from public.project_budget_templates where currency <> base_currency order by created_at limit 200) mismatches
    ), '[]'::jsonb)
  );
end
$$;

revoke all on function public.get_project_currency_reconciliation() from public, anon, authenticated;
grant execute on function public.get_project_currency_reconciliation() to authenticated;

comment on function public.get_project_currency_reconciliation() is
  'Owner-only, read-only inventory of historical project monetary rows whose currency differs from system base currency. Does not reclassify data.';

commit;
