-- Safe bulk import of manual/opening journal drafts.
-- Imports are atomic: any invalid entry or line rolls the whole batch back.
-- Imported journals remain drafts and must be reviewed/posted through the normal workflow.

create or replace function public.import_accounting_journal_drafts(import_entries jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  entry jsonb;
  line jsonb;
  entry_key text;
  origin_value text;
  date_value date;
  reference_value text;
  description_value text;
  raw_code text;
  compact_code text;
  matched_count integer;
  matched_account uuid;
  debit_value numeric(18,2);
  credit_value numeric(18,2);
  total_debit numeric(18,2);
  total_credit numeric(18,2);
  lines_payload jsonb;
  saved jsonb;
  result jsonb:='[]'::jsonb;
begin
  if not private.accounting_permission_allowed('accounting_journal_create') then
    raise exception using errcode='42501',message='Accounting journal create permission required';
  end if;

  if import_entries is null or jsonb_typeof(import_entries)<>'array' then
    raise exception using errcode='22023',message='Journal import payload must be an array';
  end if;

  if jsonb_array_length(import_entries)=0 then
    raise exception using errcode='22023',message='Journal import payload is empty';
  end if;

  if jsonb_array_length(import_entries)>500 then
    raise exception using errcode='22023',message='Journal import is limited to 500 journals per batch';
  end if;

  for entry in select value from jsonb_array_elements(import_entries)
  loop
    entry_key:=coalesce(nullif(btrim(entry->>'entry_key'),''),'بدون مفتاح');
    origin_value:=coalesce(nullif(btrim(entry->>'entry_origin'),''),'manual');
    date_value:=nullif(entry->>'entry_date','')::date;
    reference_value:=nullif(btrim(entry->>'reference'),'');
    description_value:=btrim(coalesce(entry->>'description',''));

    if origin_value not in ('manual','opening') then
      raise exception using errcode='22023',message=format('Import %s: only manual or opening journals are allowed',entry_key);
    end if;
    if origin_value='opening' and public.current_identity_role()<>'owner' then
      raise exception using errcode='42501',message=format('Import %s: Owner role required for opening journals',entry_key);
    end if;
    if date_value is null then
      raise exception using errcode='22023',message=format('Import %s: entry_date is required',entry_key);
    end if;
    if description_value='' then
      raise exception using errcode='22023',message=format('Import %s: description is required',entry_key);
    end if;
    if entry->'lines' is null or jsonb_typeof(entry->'lines')<>'array' or jsonb_array_length(entry->'lines')<2 then
      raise exception using errcode='22023',message=format('Import %s: at least two journal lines are required',entry_key);
    end if;

    total_debit:=0;
    total_credit:=0;
    lines_payload:='[]'::jsonb;

    for line in select value from jsonb_array_elements(entry->'lines')
    loop
      raw_code:=btrim(coalesce(line->>'account_code',''));
      if raw_code='' then
        raise exception using errcode='22023',message=format('Import %s: every line requires account_code',entry_key);
      end if;

      matched_account:=null;

      select a.id
      into matched_account
      from public.accounting_accounts a
      where lower(btrim(a.account_code))=lower(raw_code)
        and a.is_active
        and a.is_posting
      limit 1;

      if matched_account is null then
        compact_code:=regexp_replace(lower(raw_code),'\.','','g');

        select count(*),min(a.id)
        into matched_count,matched_account
        from public.accounting_accounts a
        where regexp_replace(lower(btrim(a.account_code)),'\.','','g')=compact_code
          and a.is_active
          and a.is_posting;

        if matched_count=0 then
          raise exception using errcode='23503',message=format('Import %s: posting account code %s was not found',entry_key,raw_code);
        end if;
        if matched_count>1 then
          raise exception using errcode='23514',message=format('Import %s: compact account code %s is ambiguous; use the canonical dotted code',entry_key,raw_code);
        end if;
      end if;

      debit_value:=coalesce(nullif(line->>'debit','')::numeric,0);
      credit_value:=coalesce(nullif(line->>'credit','')::numeric,0);

      if debit_value<0 or credit_value<0 then
        raise exception using errcode='22023',message=format('Import %s: debit and credit cannot be negative',entry_key);
      end if;
      if not ((debit_value>0 and credit_value=0) or (credit_value>0 and debit_value=0)) then
        raise exception using errcode='22023',message=format('Import %s: each line must contain debit or credit only',entry_key);
      end if;

      total_debit:=total_debit+debit_value;
      total_credit:=total_credit+credit_value;

      lines_payload:=lines_payload||jsonb_build_array(
        jsonb_build_object(
          'account_id',matched_account,
          'debit',debit_value,
          'credit',credit_value,
          'description',nullif(btrim(line->>'line_description'),'')
        )
      );
    end loop;

    if abs(total_debit-total_credit)>=0.005 then
      raise exception using errcode='23514',message=format(
        'Import %s: journal is not balanced (debit %s / credit %s)',
        entry_key,total_debit,total_credit
      );
    end if;

    saved:=public.create_accounting_journal(
      jsonb_build_object(
        'entry_origin',origin_value,
        'entry_date',date_value,
        'reference',reference_value,
        'description',description_value,
        'lines',lines_payload
      )
    );

    result:=result||jsonb_build_array(
      jsonb_build_object(
        'entry_key',entry_key,
        'entry_number',saved->>'entry_number',
        'id',saved->>'id',
        'status',saved->>'status',
        'total_debit',saved->>'total_debit',
        'total_credit',saved->>'total_credit'
      )
    );
  end loop;

  return result;
end
$$;

revoke all on function public.import_accounting_journal_drafts(jsonb)
  from public,anon;
grant execute on function public.import_accounting_journal_drafts(jsonb)
  to authenticated;
