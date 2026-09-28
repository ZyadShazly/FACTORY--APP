create or replace function private.accounting_guard_period_overlap()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if exists(
    select 1
    from public.accounting_periods p
    where p.id<>new.id
      and daterange(p.period_start,p.period_end,'[]') && daterange(new.period_start,new.period_end,'[]')
  ) then
    raise exception using errcode='23514',message='Accounting periods cannot overlap';
  end if;
  return new;
end
$$;

drop trigger if exists accounting_periods_overlap_guard on public.accounting_periods;
create trigger accounting_periods_overlap_guard
before insert or update of period_start,period_end on public.accounting_periods
for each row execute function private.accounting_guard_period_overlap();

create or replace function public.owner_configure_accounting(
  target_activation_date date,
  target_enabled boolean
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  current_row public.accounting_settings%rowtype;
  saved public.accounting_settings%rowtype;
  earliest_posted date;
begin
  if actor is null or not public.is_current_profile_active() or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required to configure accounting';
  end if;

  select * into current_row
  from public.accounting_settings
  where id=true
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting settings were not found';
  end if;

  select min(entry_date) into earliest_posted
  from public.accounting_journal_entries
  where status in ('posted','reversed');

  if coalesce(target_enabled,false) and target_activation_date is null then
    raise exception using errcode='22023',message='Accounting activation date is required before enabling accounting';
  end if;

  if earliest_posted is not null then
    if target_activation_date is null then
      raise exception using errcode='23514',message='Activation date cannot be removed after journals have been posted';
    end if;
    if target_activation_date>earliest_posted then
      raise exception using errcode='23514',message='Activation date cannot be moved after the earliest posted journal';
    end if;
  end if;

  update public.accounting_settings
  set enabled=coalesce(target_enabled,false),
      activation_date=target_activation_date,
      updated_by=actor,
      updated_at=now()
  where id=true
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_settings','true','accounting_settings_updated',actor,
    to_jsonb(current_row),to_jsonb(saved),
    jsonb_build_object('enabled',saved.enabled,'activation_date',saved.activation_date)
  );

  return to_jsonb(saved);
end
$$;

create or replace function public.owner_create_accounting_period(
  target_start date,
  target_end date
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  settings_row public.accounting_settings%rowtype;
  saved public.accounting_periods%rowtype;
begin
  if actor is null or not public.is_current_profile_active() or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required to manage accounting periods';
  end if;
  if target_start is null or target_end is null or target_end<target_start then
    raise exception using errcode='22023',message='Valid accounting period dates are required';
  end if;

  select * into settings_row from public.accounting_settings where id=true;
  if settings_row.activation_date is not null and target_end<settings_row.activation_date then
    raise exception using errcode='23514',message='Accounting period cannot end before the accounting activation date';
  end if;

  insert into public.accounting_periods(
    period_start,period_end,fiscal_year,status
  ) values(
    target_start,target_end,extract(year from target_start)::integer,'open'
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'accounting_periods',saved.id::text,'accounting_period_created',actor,to_jsonb(saved),
    jsonb_build_object('period_start',saved.period_start,'period_end',saved.period_end)
  );

  return to_jsonb(saved);
end
$$;

create or replace function public.owner_lock_accounting_period(
  target_id uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  current_row public.accounting_periods%rowtype;
  saved public.accounting_periods%rowtype;
begin
  if actor is null or not public.is_current_profile_active() or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required to manage accounting periods';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception using errcode='22023',message='Period lock reason is required';
  end if;

  select * into current_row
  from public.accounting_periods
  where id=target_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting period was not found';
  end if;
  if current_row.status='locked' then
    return to_jsonb(current_row);
  end if;

  update public.accounting_periods
  set status='locked',
      locked_by=actor,
      locked_at=now(),
      lock_reason=btrim(reason)
  where id=target_id
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_periods',saved.id::text,'accounting_period_locked',actor,
    to_jsonb(current_row),to_jsonb(saved),
    jsonb_build_object('reason',btrim(reason))
  );

  return to_jsonb(saved);
end
$$;

create or replace function public.owner_reopen_accounting_period(
  target_id uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  current_row public.accounting_periods%rowtype;
  saved public.accounting_periods%rowtype;
begin
  if actor is null or not public.is_current_profile_active() or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required to manage accounting periods';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception using errcode='22023',message='Period reopen reason is required';
  end if;

  select * into current_row
  from public.accounting_periods
  where id=target_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting period was not found';
  end if;
  if current_row.status='open' then
    return to_jsonb(current_row);
  end if;

  update public.accounting_periods
  set status='open',
      reopened_by=actor,
      reopened_at=now(),
      reopen_reason=btrim(reason)
  where id=target_id
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_periods',saved.id::text,'accounting_period_reopened',actor,
    to_jsonb(current_row),to_jsonb(saved),
    jsonb_build_object('reason',btrim(reason))
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.owner_configure_accounting(date,boolean) from public,anon;
revoke all on function public.owner_create_accounting_period(date,date) from public,anon;
revoke all on function public.owner_lock_accounting_period(uuid,text) from public,anon;
revoke all on function public.owner_reopen_accounting_period(uuid,text) from public,anon;

grant execute on function public.owner_configure_accounting(date,boolean) to authenticated;
grant execute on function public.owner_create_accounting_period(date,date) to authenticated;
grant execute on function public.owner_lock_accounting_period(uuid,text) to authenticated;
grant execute on function public.owner_reopen_accounting_period(uuid,text) to authenticated;
