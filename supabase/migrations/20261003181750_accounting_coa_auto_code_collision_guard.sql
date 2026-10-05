-- Harden automatic COA allocation against historical code/hierarchy mismatches.
-- Account codes are globally unique, so generated candidates must skip codes already
-- used anywhere in the tree even if that row is not a direct child of the parent.

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
  candidate text;
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

    next_value:=max_value+1;
    loop
      candidate:=next_value::text;
      exit when not exists(
        select 1
        from public.accounting_accounts a
        where lower(btrim(a.account_code))=lower(candidate)
      );
      next_value:=next_value+1;
    end loop;
    return candidate;
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
  loop
    segment_width:=greatest(segment_width,length(next_value::text));
    candidate:=parent_code||'.'||lpad(next_value::text,segment_width,'0');
    exit when not exists(
      select 1
      from public.accounting_accounts a
      where lower(btrim(a.account_code))=lower(candidate)
    );
    next_value:=next_value+1;
  end loop;

  return candidate;
end
$$;

revoke all on function private.accounting_next_account_code(uuid)
  from public,anon,authenticated;
