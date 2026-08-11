create or replace function public.get_asset_alerts_visible()
returns table(alert_type text, reference_id uuid, title text, due_at timestamptz, severity text, created_at timestamptz)
language plpgsql
security definer
set search_path=public,pg_temp
as $$
begin
  if auth.uid() is null or not public.is_current_profile_active() or not public.has_permission('assets_view') then
    raise exception 'Asset alerts authorization required' using errcode='42501';
  end if;
  return query
  select a.alert_type,a.reference_id,a.title,a.due_at,a.severity,a.created_at
  from public.asset_alerts a
  order by a.due_at nulls last,a.created_at desc;
end
$$;
revoke all on function public.get_asset_alerts_visible() from public,anon;
grant execute on function public.get_asset_alerts_visible() to authenticated;
