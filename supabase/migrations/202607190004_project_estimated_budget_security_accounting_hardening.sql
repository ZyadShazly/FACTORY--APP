-- Final pre-deployment hardening for Project Estimated Budget.
-- Applies after 202607190003_project_estimated_budget.sql.

begin;

do $$
begin
  if to_regclass('public.project_budget_versions') is null
    or to_regprocedure('public.approve_project_budget(uuid)') is null
    or to_regprocedure('public.get_project_budget_visible(uuid,uuid)') is null
    or to_regprocedure('public.compare_project_budget_versions(uuid,uuid)') is null then
    raise exception 'Estimated Budget hardening requires migration 003';
  end if;
end
$$;

drop index if exists public.project_costs_source_revision_unique;
create unique index project_costs_source_revision_unique
  on public.project_costs(source_type, source_id, source_line_reference, allocation_revision)
  where source_type <> 'legacy';

create or replace function public.approve_project_budget(target_version uuid)
returns jsonb
language plpgsql security definer
set search_path = public, private, pg_temp
as $$
declare
  actor uuid := auth.uid();
  v public.project_budget_versions%rowtype;
  item_count integer;
  previous_id uuid;
begin
  select * into v
  from public.project_budget_versions
  where id = target_version
  for update;

  if not found then raise exception 'Budget version not found'; end if;
  if actor is null or not private.project_budget_can(v.project_id,'project_budget_approve') then
    raise exception 'project_budget_approve permission required';
  end if;

  perform 1 from public.projects where id = v.project_id for update;
  if v.status <> 'submitted' then raise exception 'Only a submitted budget may be approved'; end if;

  select count(*) into item_count
  from public.project_budget_items
  where budget_version_id = target_version and total_with_waste > 0;

  select * into v
  from public.project_budget_versions
  where id = target_version
  for update;

  if item_count = 0 or v.expected_total_cost <= 0 or v.subtotal <= 0 then
    raise exception 'Budget approval requires complete positive totals';
  end if;

  select id into previous_id
  from public.project_budget_versions
  where project_id = v.project_id and status = 'approved' and id <> v.id
  for update;

  perform set_config('app.project_budget_rpc','on',true);
  if previous_id is not null then
    update public.project_budget_versions
    set status = 'superseded', updated_by = actor
    where id = previous_id;
  end if;

  update public.project_budget_versions
  set status = 'approved',
      approved_by = actor,
      approved_at = now(),
      rejection_reason = null,
      updated_by = actor
  where id = target_version
  returning * into v;

  perform set_config('app.project_workspace_rpc','on',true);
  update public.projects
  set expected_cost = v.expected_total_cost,
      updated_by = actor
  where id = v.project_id;

  perform private.project_budget_activity(
    v.project_id,
    'budget_approved',
    'تم اعتماد الميزانية التقديرية',
    jsonb_build_object(
      'budget_version_id', v.id,
      'version_number', v.version_number,
      'superseded_version_id', previous_id,
      'expected_total_cost', v.expected_total_cost
    )
  );

  return to_jsonb(v);
end
$$;

create or replace function public.get_project_budget_visible(target_project uuid, target_version uuid default null)
returns jsonb
language plpgsql stable security definer
set search_path = public, private, pg_temp
as $$
declare
  can_view boolean;
  can_finance boolean;
  can_templates boolean;
  versions jsonb;
  sections jsonb;
  items jsonb;
  templates jsonb;
begin
  can_view := private.project_budget_can(target_project,'project_budget_view');
  if not can_view then raise exception 'project_budget_view permission required'; end if;

  can_finance := private.project_budget_has_permission('project_budget_view_financials');
  can_templates := private.project_budget_has_permission('project_budget_create');

  select coalesce(jsonb_agg(
    case when can_finance then to_jsonb(v)
    else to_jsonb(v) - array[
      'subtotal','contingency_amount','contingency_percentage','overhead_amount',
      'overhead_percentage','expected_total_cost','target_profit_amount',
      'target_profit_percentage','target_sale_price'
    ] end
    order by v.version_number desc
  ), '[]'::jsonb)
  into versions
  from public.project_budget_versions v
  where v.project_id = target_project
    and (target_version is null or v.id = target_version);

  select coalesce(jsonb_agg(
    case when can_finance then to_jsonb(s) else to_jsonb(s) - 'subtotal' end
    order by s.sequence, s.id
  ), '[]'::jsonb)
  into sections
  from public.project_budget_sections s
  join public.project_budget_versions v on v.id = s.budget_version_id
  where v.project_id = target_project
    and (target_version is null or v.id = target_version);

  select coalesce(jsonb_agg(
    case when can_finance then to_jsonb(i)
    else to_jsonb(i) - array[
      'unit_cost','estimated_cost','waste_percentage','waste_amount','total_with_waste'
    ] end
    order by i.sequence, i.id
  ), '[]'::jsonb)
  into items
  from public.project_budget_items i
  join public.project_budget_versions v on v.id = i.budget_version_id
  where v.project_id = target_project
    and (target_version is null or v.id = target_version);

  if can_templates then
    select coalesce(jsonb_agg(to_jsonb(t) order by t.template_name), '[]'::jsonb)
    into templates
    from public.project_budget_templates t
    where t.active;
  else
    templates := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'versions', versions,
    'sections', sections,
    'items', items,
    'templates', templates,
    'can_view_financials', can_finance
  );
end
$$;

create or replace function public.compare_project_budget_versions(left_version uuid, right_version uuid)
returns jsonb
language plpgsql stable security definer
set search_path = public, private, pg_temp
as $$
declare
  left_budget public.project_budget_versions%rowtype;
  right_budget public.project_budget_versions%rowtype;
  can_finance boolean;
  lines jsonb;
begin
  select * into left_budget from public.project_budget_versions where id = left_version;
  select * into right_budget from public.project_budget_versions where id = right_version;

  if left_budget.project_id is null or right_budget.project_id <> left_budget.project_id then
    raise exception 'Budget versions must belong to the same project';
  end if;
  if not private.project_budget_can(left_budget.project_id,'project_budget_view') then
    raise exception 'project_budget_view permission required';
  end if;

  can_finance := private.project_budget_has_permission('project_budget_view_financials');

  with old_items as (
    select coalesce(item_code, description) compare_key, *
    from public.project_budget_items
    where budget_version_id = left_version
  ),
  new_items as (
    select coalesce(item_code, description) compare_key, *
    from public.project_budget_items
    where budget_version_id = right_version
  ),
  compared as (
    select
      coalesce(n.compare_key, o.compare_key) compare_key,
      coalesce(n.description, o.description) description,
      case when o.id is null then 'added' when n.id is null then 'removed' else 'changed' end change_type,
      o.quantity old_quantity,
      n.quantity new_quantity,
      o.unit_cost old_unit_cost,
      n.unit_cost new_unit_cost,
      o.waste_percentage old_waste_percentage,
      n.waste_percentage new_waste_percentage,
      o.total_with_waste old_amount,
      n.total_with_waste new_amount
    from old_items o
    full join new_items n using(compare_key)
  )
  select coalesce(jsonb_agg(
    case when can_finance then
      to_jsonb(c) || jsonb_build_object(
        'variance_amount', coalesce(new_amount,0) - coalesce(old_amount,0),
        'variance_percentage', case
          when coalesce(old_amount,0) = 0 then null
          else round((coalesce(new_amount,0)-old_amount)*100/old_amount,2)
        end
      )
    else
      to_jsonb(c) - array[
        'old_unit_cost','new_unit_cost','old_waste_percentage','new_waste_percentage',
        'old_amount','new_amount'
      ]
    end
    order by compare_key
  ), '[]'::jsonb)
  into lines
  from compared c;

  return jsonb_build_object(
    'left_version', left_budget.version_number,
    'right_version', right_budget.version_number,
    'can_view_financials', can_finance,
    'lines', lines,
    'old_total', case when can_finance then left_budget.expected_total_cost else null end,
    'new_total', case when can_finance then right_budget.expected_total_cost else null end,
    'variance_amount', case when can_finance then right_budget.expected_total_cost-left_budget.expected_total_cost else null end
  );
end
$$;

revoke all on function public.approve_project_budget(uuid) from public, anon;
grant execute on function public.approve_project_budget(uuid) to authenticated;
revoke all on function public.get_project_budget_visible(uuid,uuid) from public, anon;
grant execute on function public.get_project_budget_visible(uuid,uuid) to authenticated;
revoke all on function public.compare_project_budget_versions(uuid,uuid) from public, anon;
grant execute on function public.compare_project_budget_versions(uuid,uuid) to authenticated;

comment on function public.approve_project_budget(uuid) is
  'Approves an immutable Estimated Budget snapshot, updates expected project cost only, and never records target sale price as actual revenue.';

commit;
