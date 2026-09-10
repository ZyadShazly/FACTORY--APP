-- Pilot blocker: the browser export joined projects directly and failed under RLS.
-- Return the same export shape through a permission-checked security-definer RPC.

create or replace function public.get_external_labor_export(
  date_from date,
  date_to date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
begin
  if auth.uid() is null or not public.has_permission('daily_labor_view') then
    raise exception using errcode='42501',message='Daily labor view permission required';
  end if;
  if date_from is null or date_to is null or date_to < date_from then
    raise exception using errcode='22023',message='Valid report date range required';
  end if;

  return coalesce((
    select jsonb_agg(
      to_jsonb(labor_row)
      || jsonb_build_object(
        'project',case when project_row.id is null then null else jsonb_build_object(
          'project_code',project_row.project_code,
          'project_name',project_row.project_name
        ) end
      )
      order by labor_row.work_date,labor_row.created_at,labor_row.id
    )
    from public.daily_labor labor_row
    left join public.projects project_row on project_row.id=labor_row.project_id
    where labor_row.work_date between date_from and date_to
  ),'[]'::jsonb);
end
$$;

revoke all on function public.get_external_labor_export(date,date) from public,anon;
grant execute on function public.get_external_labor_export(date,date) to authenticated;
