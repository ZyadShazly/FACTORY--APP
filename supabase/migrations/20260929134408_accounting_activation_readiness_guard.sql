-- Accounting activation readiness guard.
-- Prevent enabling the integrated GL until all required mappings exist
-- and an open accounting period covers the activation date.
-- Disabling accounting remains always allowed.

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
  missing_mappings text[];
begin
  if actor is null
     or not public.is_current_profile_active()
     or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',
      message='Owner role required to configure accounting';
  end if;

  select * into current_row
  from public.accounting_settings
  where id=true
  for update;

  if not found then
    raise exception using errcode='P0002',
      message='Accounting settings were not found';
  end if;

  select min(entry_date)
  into earliest_posted
  from public.accounting_journal_entries
  where status in ('posted','reversed');

  if coalesce(target_enabled,false)
     and target_activation_date is null then
    raise exception using errcode='22023',
      message='Accounting activation date is required before enabling accounting';
  end if;

  if coalesce(target_enabled,false) then
    select array_agg(d.mapping_key order by d.module,d.sort_order,d.mapping_key)
    into missing_mappings
    from public.accounting_mapping_definitions d
    where d.is_active
      and d.required_for_auto_posting
      and not exists(
        select 1
        from public.accounting_account_mappings m
        join public.accounting_accounts a on a.id=m.account_id
        where lower(btrim(m.mapping_key))=lower(btrim(d.mapping_key))
          and lower(btrim(m.scope_type))='global'
          and btrim(m.scope_value)=''
          and m.is_active
          and a.is_active
          and a.is_posting
      );

    if coalesce(cardinality(missing_mappings),0)>0 then
      raise exception using
        errcode='23514',
        message='Accounting cannot be enabled until all required account mappings are configured',
        detail=array_to_string(missing_mappings,', ');
    end if;

    if not exists(
      select 1
      from public.accounting_periods p
      where p.status='open'
        and target_activation_date between p.period_start and p.period_end
    ) then
      raise exception using
        errcode='23514',
        message='Accounting cannot be enabled until an open accounting period covers the activation date';
    end if;
  end if;

  if earliest_posted is not null then
    if target_activation_date is null then
      raise exception using errcode='23514',
        message='Activation date cannot be removed after journals have been posted';
    end if;

    if target_activation_date>earliest_posted then
      raise exception using errcode='23514',
        message='Activation date cannot be moved after the earliest posted journal';
    end if;
  end if;

  update public.accounting_settings
  set enabled=coalesce(target_enabled,false),
      activation_date=target_activation_date,
      updated_by=actor,
      updated_at=now()
  where id=true
  returning * into saved;

  insert into public.audit_log(
    table_name,record_id,action,actor_id,old_data,new_data,metadata
  )
  values(
    'accounting_settings',
    'true',
    'accounting_settings_updated',
    actor,
    to_jsonb(current_row),
    to_jsonb(saved),
    jsonb_build_object(
      'enabled',saved.enabled,
      'activation_date',saved.activation_date
    )
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.owner_configure_accounting(date,boolean)
  from public,anon;
grant execute on function public.owner_configure_accounting(date,boolean)
  to authenticated;
