-- Automatic sequential chart-of-accounts codes with unlimited numeric growth.
-- Existing explicit codes remain backward-compatible; new UI creates omit account_code
-- so the server allocates the next safe code under the selected parent.

create or replace function private.accounting_next_account_code(target_parent uuid default null)
returns text
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  parent_code text;
  sibling record;
  last_segment text;
  max_value bigint:=0;
  next_value bigint;
  segment_width integer:=2;
begin
  if target_parent is null then
    for sibling in
      select a.account_code
      from public.accounting_accounts a
      where a.parent_id is null
        and btrim(a.account_code) ~ '^[0-9]+$'
    loop
      if sibling.account_code::bigint>max_value then
        max_value:=sibling.account_code::bigint;
      end if;
    end loop;
    return (max_value+1)::text;
  end if;

  select a.account_code
  into parent_code
  from public.accounting_accounts a
  where a.id=target_parent;

  if not found then
    raise exception using errcode='23503',message='Parent account was not found';
  end if;

  for sibling in
    select a.account_code
    from public.accounting_accounts a
    where a.parent_id=target_parent
  loop
    last_segment:=substring(btrim(sibling.account_code) from '([^.]+)$');
    if last_segment ~ '^[0-9]+$' then
      if last_segment::bigint>max_value then
        max_value:=last_segment::bigint;
      end if;
      segment_width:=greatest(segment_width,length(last_segment));
    end if;
  end loop;

  next_value:=max_value+1;
  segment_width:=greatest(segment_width,length(next_value::text));

  return parent_code||'.'||lpad(next_value::text,segment_width,'0');
end
$$;

revoke all on function private.accounting_next_account_code(uuid)
  from public,anon,authenticated;

create or replace function public.get_next_accounting_account_code(target_parent uuid default null)
returns text
language plpgsql
stable
security definer
set search_path=''
as $$
begin
  if not private.accounting_permission_allowed('accounting_accounts_manage') then
    raise exception using errcode='42501',message='Accounting account management permission required';
  end if;

  if target_parent is not null and not exists(
    select 1
    from public.accounting_accounts a
    where a.id=target_parent and a.is_active
  ) then
    raise exception using errcode='23503',message='Active parent account was not found';
  end if;

  return private.accounting_next_account_code(target_parent);
end
$$;

revoke all on function public.get_next_accounting_account_code(uuid)
  from public,anon;
grant execute on function public.get_next_accounting_account_code(uuid)
  to authenticated;

create or replace function public.create_accounting_account(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  requested_code text:=nullif(btrim(coalesce(payload->>'account_code','')),'');
  code_value text;
  name_ar_value text:=btrim(coalesce(payload->>'name_ar',''));
  name_en_value text:=nullif(btrim(payload->>'name_en'),'');
  type_value text:=btrim(coalesce(payload->>'account_type',''));
  contra_value boolean:=coalesce((payload->>'is_contra')::boolean,false);
  posting_value boolean:=coalesce((payload->>'is_posting')::boolean,true);
  parent_value uuid:=nullif(payload->>'parent_id','')::uuid;
  normal_value text;
  parent_row public.accounting_accounts%rowtype;
  saved public.accounting_accounts%rowtype;
begin
  if not private.accounting_permission_allowed('accounting_accounts_manage') then
    raise exception using errcode='42501',message='Accounting account management permission required';
  end if;
  if name_ar_value='' then
    raise exception using errcode='22023',message='Arabic account name is required';
  end if;
  if type_value not in ('asset','liability','equity','revenue','cost_of_sales','expense') then
    raise exception using errcode='22023',message='Valid account type is required';
  end if;

  -- Serialize allocation per parent namespace so concurrent account creation
  -- cannot receive the same automatically generated code.
  perform pg_advisory_xact_lock(
    hashtext('accounting_account_code:'||coalesce(parent_value::text,'root'))::bigint
  );

  if parent_value is not null then
    select * into parent_row
    from public.accounting_accounts
    where id=parent_value
    for update;

    if not found then
      raise exception using errcode='23503',message='Parent account was not found';
    end if;
    if not parent_row.is_active then
      raise exception using errcode='23514',message='Cannot add a subaccount under an inactive account';
    end if;
    if parent_row.account_type<>type_value then
      raise exception using errcode='23514',message='Child account type must match its parent account type';
    end if;

    if parent_row.is_posting then
      if exists(select 1 from public.accounting_journal_lines l where l.account_id=parent_row.id) then
        raise exception using errcode='23514',message='Parent account has journal activity; Owner must convert it to a group account before adding subaccounts';
      end if;
      update public.accounting_accounts
      set is_posting=false,updated_by=actor,updated_at=now()
      where id=parent_row.id;
    end if;
  end if;

  code_value:=coalesce(requested_code,private.accounting_next_account_code(parent_value));

  normal_value:=case
    when type_value in ('asset','cost_of_sales','expense')
      then case when contra_value then 'credit' else 'debit' end
    else case when contra_value then 'debit' else 'credit' end
  end;

  insert into public.accounting_accounts(
    account_code,name_ar,name_en,parent_id,account_type,normal_balance,
    is_contra,is_posting,is_active,description,created_by,updated_by
  ) values(
    code_value,name_ar_value,name_en_value,parent_value,type_value,normal_value,
    contra_value,posting_value,true,nullif(btrim(payload->>'description'),''),actor,actor
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'accounting_accounts',saved.id::text,'accounting_account_created',actor,to_jsonb(saved),
    jsonb_build_object(
      'account_code',saved.account_code,
      'parent_id',saved.parent_id,
      'code_source',case when requested_code is null then 'automatic' else 'explicit' end
    )
  );

  return to_jsonb(saved);
exception when unique_violation then
  raise exception using errcode='23505',message='Account code already exists';
end
$$;

revoke all on function public.create_accounting_account(jsonb)
  from public,anon;
grant execute on function public.create_accounting_account(jsonb)
  to authenticated;
