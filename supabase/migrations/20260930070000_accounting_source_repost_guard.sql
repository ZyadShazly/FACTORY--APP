-- Guard against silently reusing a reversed source journal.
-- A repeated active source event remains idempotent, but a repost after reversal
-- must not return the old reversed journal as if it were posted.

create or replace function private.accounting_post_source_journal(
  target_module text,
  target_event text,
  target_record_id text,
  target_date date,
  target_description text,
  target_reference text,
  target_project uuid,
  target_lines jsonb,
  actor uuid
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  existing_entry uuid;
  existing_link_status text;
  existing_journal_status text;
  saved public.accounting_journal_entries%rowtype;
  lock_key text;
begin
  if actor is null then
    raise exception using errcode='42501',
      message='Authenticated actor required for accounting auto-posting';
  end if;
  if nullif(btrim(target_module),'') is null
     or nullif(btrim(target_event),'') is null
     or nullif(btrim(target_record_id),'') is null then
    raise exception using errcode='22023',
      message='Accounting source identity is required';
  end if;
  if nullif(btrim(target_description),'') is null then
    raise exception using errcode='22023',
      message='Accounting journal description is required';
  end if;
  if target_date is null then
    raise exception using errcode='22023',
      message='Accounting source date is required';
  end if;

  lock_key:=lower(btrim(target_module))||':'||
            lower(btrim(target_event))||':'||
            btrim(target_record_id)||':1';
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(lock_key,0)
  );

  select l.journal_entry_id,l.link_status,j.status
  into existing_entry,existing_link_status,existing_journal_status
  from public.accounting_source_links l
  join public.accounting_journal_entries j on j.id=l.journal_entry_id
  where lower(btrim(l.source_module))=lower(btrim(target_module))
    and lower(btrim(l.source_event))=lower(btrim(target_event))
    and l.source_record_id=btrim(target_record_id)
    and l.source_line_id is null
    and l.source_revision=1
  order by l.created_at desc
  limit 1;

  if existing_entry is not null then
    if existing_link_status='active'
       and existing_journal_status='posted' then
      return existing_entry;
    end if;

    if existing_link_status='reversed'
       or existing_journal_status='reversed' then
      raise exception using
        errcode='23514',
        message='Accounting source event was previously reversed and cannot be reposted with the same source identity';
    end if;

    raise exception using
      errcode='23514',
      message='Existing accounting source link is not in a reusable posted state';
  end if;

  perform private.accounting_assert_date_open(target_date);

  insert into public.accounting_journal_entries(
    entry_number,entry_date,reference,description,status,entry_origin,
    source_module,source_event,source_record_id,source_revision,project_id,
    created_by
  ) values(
    private.next_accounting_entry_number('system',target_date),
    target_date,
    nullif(btrim(target_reference),''),
    btrim(target_description),
    'draft',
    'system',
    btrim(target_module),
    btrim(target_event),
    btrim(target_record_id),
    1,
    target_project,
    actor
  )
  returning * into saved;

  perform private.accounting_replace_lines(
    saved.id,target_lines,false,'[]'::jsonb
  );

  update public.accounting_journal_entries
  set status='posted',
      posted_by=actor,
      posted_at=now(),
      updated_at=now()
  where id=saved.id
  returning * into saved;

  perform private.accounting_assert_entry_balanced(saved.id);

  insert into public.accounting_source_links(
    source_module,source_event,source_record_id,source_line_id,
    source_revision,journal_entry_id,link_status
  ) values(
    btrim(target_module),
    btrim(target_event),
    btrim(target_record_id),
    null,
    1,
    saved.id,
    'active'
  );

  insert into public.audit_log(
    table_name,record_id,action,actor_id,new_data,metadata
  )
  values(
    'accounting_journal_entries',
    saved.id::text,
    'accounting_system_journal_posted',
    actor,
    private.accounting_journal_snapshot(saved.id),
    jsonb_build_object(
      'source_module',btrim(target_module),
      'source_event',btrim(target_event),
      'source_record_id',btrim(target_record_id)
    )
  );

  return saved.id;
end
$$;

revoke all on function private.accounting_post_source_journal(
  text,text,text,date,text,text,uuid,jsonb,uuid
) from public,anon,authenticated;
