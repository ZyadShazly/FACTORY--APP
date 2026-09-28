create table private.accounting_journal_counters (
  fiscal_year integer primary key check (fiscal_year between 2000 and 9999),
  next_number bigint not null default 1 check (next_number > 0)
);
revoke all on table private.accounting_journal_counters from public,anon,authenticated;

create or replace function private.next_accounting_entry_number(target_origin text,target_date date)
returns text
language plpgsql
set search_path=''
as $$
declare
  target_year integer:=extract(year from target_date)::integer;
  allocated bigint;
  prefix text:=case target_origin when 'opening' then 'OB' when 'reversal' then 'RV' else 'JE' end;
begin
  insert into private.accounting_journal_counters(fiscal_year,next_number)
  values(target_year,1)
  on conflict(fiscal_year) do nothing;

  update private.accounting_journal_counters
  set next_number=next_number+1
  where fiscal_year=target_year
  returning next_number-1 into allocated;

  return prefix||'-'||target_year::text||'-'||lpad(allocated::text,6,'0');
end
$$;
revoke all on function private.next_accounting_entry_number(text,date) from public,anon,authenticated;

create or replace function private.accounting_guard_posting_account()
returns trigger
language plpgsql
set search_path=''
as $$
declare target public.accounting_accounts%rowtype;
begin
  select * into target
  from public.accounting_accounts
  where id=new.account_id;

  if not found then
    raise exception using errcode='23503',message='Posting account was not found';
  end if;

  if current_setting('app.accounting_allow_legacy_posting_account',true)='on' then
    return new;
  end if;

  if not target.is_active then
    raise exception using errcode='23514',message='Inactive account cannot receive journal postings';
  end if;
  if not target.is_posting then
    raise exception using errcode='23514',message='Group account cannot receive journal postings';
  end if;
  return new;
end
$$;

create or replace function private.accounting_lines_json(target_entry uuid)
returns jsonb
language sql
stable
set search_path=''
as $$
  select coalesce(
    jsonb_agg(to_jsonb(l) order by l.line_number),
    '[]'::jsonb
  )
  from public.accounting_journal_lines l
  where l.journal_entry_id=target_entry
$$;
revoke all on function private.accounting_lines_json(uuid) from public,anon,authenticated;

create or replace function private.accounting_assert_date_open(target_date date)
returns void
language plpgsql
stable
set search_path=''
as $$
declare
  settings_row public.accounting_settings%rowtype;
  open_count integer;
begin
  select * into settings_row
  from public.accounting_settings
  where id=true;

  if not found or not settings_row.enabled then
    raise exception using errcode='23514',message='Accounting is not enabled';
  end if;
  if settings_row.activation_date is null then
    raise exception using errcode='23514',message='Accounting activation date is required';
  end if;
  if target_date<settings_row.activation_date then
    raise exception using errcode='23514',message='Journal date cannot precede the accounting activation date';
  end if;

  select count(*) into open_count
  from public.accounting_periods p
  where target_date between p.period_start and p.period_end
    and p.status='open';

  if open_count=0 then
    raise exception using errcode='23514',message='An open accounting period is required for this journal date';
  end if;
  if open_count>1 then
    raise exception using errcode='23514',message='Journal date matches multiple open accounting periods';
  end if;
end
$$;
revoke all on function private.accounting_assert_date_open(date) from public,anon,authenticated;

create or replace function private.accounting_replace_lines(
  target_entry uuid,
  target_lines jsonb,
  allow_legacy_accounts boolean default false,
  legacy_lines jsonb default '[]'::jsonb
)
returns void
language plpgsql
set search_path=''
as $$
declare
  line jsonb;
  line_no integer:=0;
  account_value uuid;
  account_row public.accounting_accounts%rowtype;
  debit_value numeric(18,2);
  credit_value numeric(18,2);
  currency_value text;
  foreign_value numeric(18,4);
  rate_value numeric(18,8);
begin
  if target_lines is null or jsonb_typeof(target_lines)<>'array' then
    raise exception using errcode='22023',message='Journal lines must be an array';
  end if;

  if allow_legacy_accounts then
    perform set_config('app.accounting_allow_legacy_posting_account','on',true);
  else
    perform set_config('app.accounting_allow_legacy_posting_account','off',true);
  end if;

  delete from public.accounting_journal_lines
  where journal_entry_id=target_entry;

  for line in select value from jsonb_array_elements(target_lines)
  loop
    line_no:=line_no+1;
    account_value:=nullif(line->>'account_id','')::uuid;
    if account_value is null then
      raise exception using errcode='22023',message='Every journal line requires an account';
    end if;

    select * into account_row
    from public.accounting_accounts
    where id=account_value;

    if not found then
      raise exception using errcode='23503',message='Journal line account was not found';
    end if;

    if not account_row.is_active or not account_row.is_posting then
      if not allow_legacy_accounts or not exists(
        select 1
        from jsonb_array_elements(coalesce(legacy_lines,'[]'::jsonb)) previous
        where previous->>'account_id'=account_value::text
      ) then
        raise exception using errcode='23514',message='Inactive or group account cannot receive a new journal posting';
      end if;
    end if;

    debit_value:=coalesce(nullif(line->>'debit','')::numeric,0);
    credit_value:=coalesce(nullif(line->>'credit','')::numeric,0);
    currency_value:=nullif(upper(btrim(line->>'transaction_currency')),'');
    foreign_value:=nullif(line->>'foreign_amount','')::numeric;
    rate_value:=nullif(line->>'exchange_rate','')::numeric;

    insert into public.accounting_journal_lines(
      journal_entry_id,line_number,account_id,debit,credit,description,
      partner_type,partner_id,project_id,department_id,cost_center_reference,
      source_line_id,reference,transaction_currency,foreign_amount,exchange_rate
    ) values(
      target_entry,line_no,account_value,debit_value,credit_value,
      nullif(btrim(line->>'description'),''),
      nullif(btrim(line->>'partner_type'),''),
      nullif(line->>'partner_id','')::uuid,
      nullif(line->>'project_id','')::uuid,
      nullif(line->>'department_id','')::uuid,
      nullif(btrim(line->>'cost_center_reference'),''),
      nullif(btrim(line->>'source_line_id'),''),
      nullif(btrim(line->>'reference'),''),
      currency_value,foreign_value,rate_value
    );
  end loop;

  perform set_config('app.accounting_allow_legacy_posting_account','off',true);
end
$$;
revoke all on function private.accounting_replace_lines(uuid,jsonb,boolean,jsonb) from public,anon,authenticated;

create or replace function private.accounting_journal_snapshot(target_entry uuid)
returns jsonb
language sql
stable
set search_path=''
as $$
  select to_jsonb(j)
    || jsonb_build_object(
      'lines',private.accounting_lines_json(j.id),
      'total_debit',coalesce((select sum(l.debit) from public.accounting_journal_lines l where l.journal_entry_id=j.id),0),
      'total_credit',coalesce((select sum(l.credit) from public.accounting_journal_lines l where l.journal_entry_id=j.id),0)
    )
  from public.accounting_journal_entries j
  where j.id=target_entry
$$;
revoke all on function private.accounting_journal_snapshot(uuid) from public,anon,authenticated;

create or replace function public.get_accounting_journal_workspace(
  date_from date default null,
  date_to date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  result jsonb;
begin
  if not private.accounting_permission_allowed('accounting_view') then
    raise exception using errcode='42501',message='Accounting view permission required';
  end if;

  select jsonb_build_object(
    'settings',coalesce(
      (select to_jsonb(s) from public.accounting_settings s where s.id=true),
      '{}'::jsonb
    ),
    'periods',coalesce(
      (select jsonb_agg(to_jsonb(p) order by p.period_start desc) from public.accounting_periods p),
      '[]'::jsonb
    ),
    'journals',coalesce(
      (
        select jsonb_agg(
          to_jsonb(j)
          || jsonb_build_object(
            'lines',private.accounting_lines_json(j.id),
            'total_debit',coalesce((select sum(l.debit) from public.accounting_journal_lines l where l.journal_entry_id=j.id),0),
            'total_credit',coalesce((select sum(l.credit) from public.accounting_journal_lines l where l.journal_entry_id=j.id),0)
          )
          order by j.entry_date desc,j.entry_number desc
        )
        from public.accounting_journal_entries j
        where (date_from is null or j.entry_date>=date_from)
          and (date_to is null or j.entry_date<=date_to)
      ),
      '[]'::jsonb
    )
  ) into result;

  return result;
end
$$;

create or replace function public.create_accounting_journal(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  origin_value text:=coalesce(nullif(btrim(payload->>'entry_origin'),''),'manual');
  date_value date:=coalesce(nullif(payload->>'entry_date','')::date,current_date);
  description_value text:=btrim(coalesce(payload->>'description',''));
  project_value uuid:=nullif(payload->>'project_id','')::uuid;
  saved public.accounting_journal_entries%rowtype;
begin
  if not private.accounting_permission_allowed('accounting_journal_create') then
    raise exception using errcode='42501',message='Accounting journal create permission required';
  end if;
  if origin_value not in ('manual','opening') then
    raise exception using errcode='22023',message='Only manual or opening journal drafts may be created here';
  end if;
  if origin_value='opening' and public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required for opening journals';
  end if;
  if description_value='' then
    raise exception using errcode='22023',message='Journal description is required';
  end if;

  insert into public.accounting_journal_entries(
    entry_number,entry_date,reference,description,status,entry_origin,project_id,created_by
  ) values(
    private.next_accounting_entry_number(origin_value,date_value),
    date_value,nullif(btrim(payload->>'reference'),''),description_value,
    'draft',origin_value,project_value,actor
  )
  returning * into saved;

  if payload ? 'lines' then
    perform private.accounting_replace_lines(saved.id,payload->'lines',false,'[]'::jsonb);
  end if;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'accounting_journal_entries',saved.id::text,'accounting_journal_draft_created',actor,
    private.accounting_journal_snapshot(saved.id),
    jsonb_build_object('entry_number',saved.entry_number,'entry_origin',saved.entry_origin)
  );

  return private.accounting_journal_snapshot(saved.id);
end
$$;

create or replace function public.update_accounting_journal_draft(target_id uuid,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  current_row public.accounting_journal_entries%rowtype;
  before_snapshot jsonb;
  saved public.accounting_journal_entries%rowtype;
begin
  if not private.accounting_permission_allowed('accounting_journal_create') then
    raise exception using errcode='42501',message='Accounting journal create permission required';
  end if;

  select * into current_row
  from public.accounting_journal_entries
  where id=target_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting journal was not found';
  end if;
  if current_row.status<>'draft' then
    raise exception using errcode='23514',message='Only draft journals can be edited with this action';
  end if;
  if current_row.entry_origin='opening' and public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required for opening journals';
  end if;

  before_snapshot:=private.accounting_journal_snapshot(target_id);

  update public.accounting_journal_entries
  set entry_date=case when payload ? 'entry_date' then nullif(payload->>'entry_date','')::date else entry_date end,
      reference=case when payload ? 'reference' then nullif(btrim(payload->>'reference'),'') else reference end,
      description=case when payload ? 'description' then btrim(coalesce(payload->>'description','')) else description end,
      project_id=case when payload ? 'project_id' then nullif(payload->>'project_id','')::uuid else project_id end,
      updated_at=now()
  where id=target_id
  returning * into saved;

  if btrim(saved.description)='' then
    raise exception using errcode='22023',message='Journal description is required';
  end if;

  if payload ? 'lines' then
    perform private.accounting_replace_lines(target_id,payload->'lines',false,'[]'::jsonb);
  end if;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_journal_entries',target_id::text,'accounting_journal_draft_updated',actor,
    before_snapshot,private.accounting_journal_snapshot(target_id),
    jsonb_build_object('entry_number',saved.entry_number)
  );

  return private.accounting_journal_snapshot(target_id);
end
$$;

create or replace function public.post_accounting_journal(target_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  saved public.accounting_journal_entries%rowtype;
begin
  if not private.accounting_permission_allowed('accounting_journal_post') then
    raise exception using errcode='42501',message='Accounting journal post permission required';
  end if;

  select * into saved
  from public.accounting_journal_entries
  where id=target_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting journal was not found';
  end if;
  if saved.status<>'draft' then
    raise exception using errcode='23514',message='Only a draft journal can be posted';
  end if;

  perform private.accounting_assert_date_open(saved.entry_date);

  update public.accounting_journal_entries
  set status='posted',posted_by=actor,posted_at=now(),updated_at=now()
  where id=target_id
  returning * into saved;

  perform private.accounting_assert_entry_balanced(target_id);

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'accounting_journal_entries',target_id::text,'accounting_journal_posted',actor,
    private.accounting_journal_snapshot(target_id),
    jsonb_build_object('entry_number',saved.entry_number)
  );

  return private.accounting_journal_snapshot(target_id);
end
$$;

create or replace function public.owner_edit_posted_accounting_journal(
  target_id uuid,
  payload jsonb,
  edit_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  current_row public.accounting_journal_entries%rowtype;
  saved public.accounting_journal_entries%rowtype;
  before_header jsonb;
  before_lines jsonb;
  after_header jsonb;
  after_lines jsonb;
  new_date date;
  new_revision integer;
begin
  if actor is null
     or not public.is_current_profile_active()
     or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required to edit a posted journal';
  end if;
  if nullif(btrim(edit_reason),'') is null then
    raise exception using errcode='22023',message='Edit reason is required';
  end if;

  select * into current_row
  from public.accounting_journal_entries
  where id=target_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting journal was not found';
  end if;
  if current_row.status<>'posted' then
    raise exception using errcode='23514',message='Only a currently posted journal can be master-edited';
  end if;

  perform private.accounting_assert_date_open(current_row.entry_date);

  new_date:=case
    when payload ? 'entry_date' then nullif(payload->>'entry_date','')::date
    else current_row.entry_date
  end;
  perform private.accounting_assert_date_open(new_date);

  before_header:=to_jsonb(current_row);
  before_lines:=private.accounting_lines_json(target_id);

  if payload ? 'lines' then
    perform private.accounting_replace_lines(target_id,payload->'lines',true,before_lines);
  end if;

  new_revision:=current_row.revision_number+1;

  update public.accounting_journal_entries
  set entry_date=new_date,
      reference=case when payload ? 'reference' then nullif(btrim(payload->>'reference'),'') else reference end,
      description=case when payload ? 'description' then btrim(coalesce(payload->>'description','')) else description end,
      project_id=case when payload ? 'project_id' then nullif(payload->>'project_id','')::uuid else project_id end,
      revision_number=new_revision,
      master_overridden=true,
      last_edited_by=actor,
      last_edited_at=now(),
      last_edit_reason=btrim(edit_reason),
      updated_at=now()
  where id=target_id
  returning * into saved;

  if btrim(saved.description)='' then
    raise exception using errcode='22023',message='Journal description is required';
  end if;

  perform private.accounting_assert_entry_balanced(target_id);

  after_header:=to_jsonb(saved);
  after_lines:=private.accounting_lines_json(target_id);

  insert into public.accounting_journal_revisions(
    journal_entry_id,revision_number,header_before,lines_before,
    header_after,lines_after,edit_reason,edited_by
  ) values(
    target_id,new_revision,before_header,before_lines,
    after_header,after_lines,btrim(edit_reason),actor
  );

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_journal_entries',target_id::text,'accounting_posted_journal_master_edited',actor,
    before_header||jsonb_build_object('lines',before_lines),
    after_header||jsonb_build_object('lines',after_lines),
    jsonb_build_object('entry_number',saved.entry_number,'revision_number',new_revision,'reason',btrim(edit_reason))
  );

  return private.accounting_journal_snapshot(target_id);
end
$$;

create or replace function private.reverse_accounting_journal_current_lines(
  target_id uuid,
  reversal_date date,
  reason text,
  actor uuid
)
returns jsonb
language plpgsql
set search_path=''
as $$
declare
  current_row public.accounting_journal_entries%rowtype;
  reversal_row public.accounting_journal_entries%rowtype;
begin
  if actor is null then
    raise exception using errcode='42501',message='Authenticated actor required';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception using errcode='22023',message='Reversal reason is required';
  end if;

  select * into current_row
  from public.accounting_journal_entries
  where id=target_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting journal was not found';
  end if;
  if current_row.status<>'posted' then
    raise exception using errcode='23514',message='Only a posted journal can be reversed';
  end if;

  perform private.accounting_assert_date_open(reversal_date);

  insert into public.accounting_journal_entries(
    entry_number,entry_date,reference,description,status,entry_origin,
    source_module,source_event,source_record_id,source_revision,project_id,
    reversal_of_entry_id,created_by
  ) values(
    private.next_accounting_entry_number('reversal',reversal_date),
    reversal_date,
    current_row.entry_number,
    'عكس القيد '||current_row.entry_number||' — '||btrim(reason),
    'draft','reversal',
    current_row.source_module,
    case when current_row.source_event is null then null else current_row.source_event||'_reversal' end,
    current_row.source_record_id,current_row.source_revision,current_row.project_id,
    current_row.id,actor
  )
  returning * into reversal_row;

  perform set_config('app.accounting_allow_legacy_posting_account','on',true);

  insert into public.accounting_journal_lines(
    journal_entry_id,line_number,account_id,debit,credit,description,
    partner_type,partner_id,project_id,department_id,cost_center_reference,
    source_line_id,reference,transaction_currency,foreign_amount,exchange_rate
  )
  select
    reversal_row.id,l.line_number,l.account_id,l.credit,l.debit,
    coalesce(l.description,'')||case when l.description is null then 'عكس القيد' else ' — عكس' end,
    l.partner_type,l.partner_id,l.project_id,l.department_id,l.cost_center_reference,
    l.source_line_id,l.reference,l.transaction_currency,l.foreign_amount,l.exchange_rate
  from public.accounting_journal_lines l
  where l.journal_entry_id=current_row.id
  order by l.line_number;

  perform set_config('app.accounting_allow_legacy_posting_account','off',true);

  update public.accounting_journal_entries
  set status='posted',posted_by=actor,posted_at=now(),updated_at=now()
  where id=reversal_row.id
  returning * into reversal_row;

  perform private.accounting_assert_entry_balanced(reversal_row.id);

  update public.accounting_journal_entries
  set status='reversed',reversed_by_entry_id=reversal_row.id,updated_at=now()
  where id=current_row.id;

  update public.accounting_source_links
  set link_status='reversed'
  where journal_entry_id=current_row.id and link_status='active';

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_journal_entries',current_row.id::text,'accounting_journal_reversed',actor,
    to_jsonb(current_row),
    private.accounting_journal_snapshot(current_row.id),
    jsonb_build_object(
      'entry_number',current_row.entry_number,
      'reversal_entry_id',reversal_row.id,
      'reversal_entry_number',reversal_row.entry_number,
      'reason',btrim(reason)
    )
  );

  return jsonb_build_object(
    'original',private.accounting_journal_snapshot(current_row.id),
    'reversal',private.accounting_journal_snapshot(reversal_row.id)
  );
end
$$;
revoke all on function private.reverse_accounting_journal_current_lines(uuid,date,text,uuid) from public,anon,authenticated;

create or replace function public.reverse_accounting_journal(
  target_id uuid,
  reversal_date date,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  origin_value text;
begin
  if not private.accounting_permission_allowed('accounting_journal_reverse') then
    raise exception using errcode='42501',message='Accounting journal reversal permission required';
  end if;

  select entry_origin into origin_value
  from public.accounting_journal_entries
  where id=target_id;

  if not found then
    raise exception using errcode='P0002',message='Accounting journal was not found';
  end if;
  if origin_value='system' then
    raise exception using errcode='23514',message='System-generated journal must be reversed from its original NextEP transaction';
  end if;
  if origin_value='reversal' then
    raise exception using errcode='23514',message='A reversal journal cannot be reversed from this action';
  end if;

  return private.reverse_accounting_journal_current_lines(
    target_id,coalesce(reversal_date,current_date),reason,actor
  );
end
$$;

revoke all on function public.get_accounting_journal_workspace(date,date) from public,anon;
revoke all on function public.create_accounting_journal(jsonb) from public,anon;
revoke all on function public.update_accounting_journal_draft(uuid,jsonb) from public,anon;
revoke all on function public.post_accounting_journal(uuid) from public,anon;
revoke all on function public.owner_edit_posted_accounting_journal(uuid,jsonb,text) from public,anon;
revoke all on function public.reverse_accounting_journal(uuid,date,text) from public,anon;

grant execute on function public.get_accounting_journal_workspace(date,date) to authenticated;
grant execute on function public.create_accounting_journal(jsonb) to authenticated;
grant execute on function public.update_accounting_journal_draft(uuid,jsonb) to authenticated;
grant execute on function public.post_accounting_journal(uuid) to authenticated;
grant execute on function public.owner_edit_posted_accounting_journal(uuid,jsonb,text) to authenticated;
grant execute on function public.reverse_accounting_journal(uuid,date,text) to authenticated;
