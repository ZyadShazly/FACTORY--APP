-- Dedicated Profit & Loss report derived from the posted general ledger.
-- Additive reporting RPC only; no operational data is mutated.

create or replace function public.get_accounting_profit_loss(
  date_from date default null,
  date_to date default null,
  target_project uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  settings_row public.accounting_settings%rowtype;
  from_date date;
  to_date date;
  result jsonb;
begin
  perform private.accounting_report_assert_access();

  select *
  into settings_row
  from public.accounting_settings
  where id=true;

  to_date:=coalesce(date_to,current_date);
  from_date:=coalesce(
    date_from,
    settings_row.activation_date,
    (select min(j.entry_date)
       from public.accounting_journal_entries j
      where j.status in ('posted','reversed')),
    to_date
  );

  if from_date>to_date then
    raise exception using
      errcode='22007',
      message='Invalid profit and loss date range';
  end if;

  with recursive
  depth_tree as (
    select a.id,a.parent_id,1 as depth
    from public.accounting_accounts a
    where a.parent_id is null

    union all

    select c.id,c.parent_id,p.depth+1
    from public.accounting_accounts c
    join depth_tree p on p.id=c.parent_id
  ),
  descendants as (
    select a.id as ancestor_id,a.id as descendant_id
    from public.accounting_accounts a

    union all

    select d.ancestor_id,c.id
    from descendants d
    join public.accounting_accounts c on c.parent_id=d.descendant_id
  ),
  pnl_accounts as (
    select a.id
    from public.accounting_accounts a
    where a.account_type in ('revenue','cost_of_sales','expense')
  ),
  direct as (
    select
      l.account_id,
      coalesce(sum(l.debit),0)::numeric(18,2) as debit,
      coalesce(sum(l.credit),0)::numeric(18,2) as credit,
      coalesce(sum(
        case
          when a.account_type='revenue' then l.credit-l.debit
          when a.account_type in ('cost_of_sales','expense') then l.debit-l.credit
          else 0
        end
      ),0)::numeric(18,2) as amount
    from public.accounting_journal_lines l
    join public.accounting_journal_entries j on j.id=l.journal_entry_id
    join public.accounting_accounts a on a.id=l.account_id
    where j.status in ('posted','reversed')
      and j.entry_date between from_date and to_date
      and a.account_type in ('revenue','cost_of_sales','expense')
      and (target_project is null or coalesce(l.project_id,j.project_id)=target_project)
    group by l.account_id
  ),
  rows as (
    select
      a.id,
      a.account_code,
      a.name_ar,
      a.name_en,
      a.parent_id,
      a.account_type,
      a.is_posting,
      a.is_active,
      coalesce(dt.depth,1) as depth,
      coalesce(sum(d.amount),0)::numeric(18,2) as amount
    from public.accounting_accounts a
    join pnl_accounts p on p.id=a.id
    left join depth_tree dt on dt.id=a.id
    left join descendants x
      on x.ancestor_id=a.id
     and x.descendant_id in (select id from pnl_accounts)
    left join direct d on d.account_id=x.descendant_id
    group by
      a.id,a.account_code,a.name_ar,a.name_en,a.parent_id,
      a.account_type,a.is_posting,a.is_active,dt.depth
  ),
  totals as (
    select
      coalesce(sum(
        case when a.account_type='revenue' then l.credit-l.debit else 0 end
      ),0)::numeric(18,2) as revenue,
      coalesce(sum(
        case when a.account_type='cost_of_sales' then l.debit-l.credit else 0 end
      ),0)::numeric(18,2) as cost_of_sales,
      coalesce(sum(
        case when a.account_type='expense' then l.debit-l.credit else 0 end
      ),0)::numeric(18,2) as expenses
    from public.accounting_journal_lines l
    join public.accounting_journal_entries j on j.id=l.journal_entry_id
    join public.accounting_accounts a on a.id=l.account_id
    where j.status in ('posted','reversed')
      and j.entry_date between from_date and to_date
      and a.account_type in ('revenue','cost_of_sales','expense')
      and (target_project is null or coalesce(l.project_id,j.project_id)=target_project)
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',from_date,'to',to_date),
    'project_id',target_project,
    'rows',coalesce(
      (
        select jsonb_agg(
          to_jsonb(r)
          order by string_to_array(r.account_code,'.')::text[]
        )
        from rows r
        where abs(r.amount)>=0.005
      ),
      '[]'::jsonb
    ),
    'summary',(
      select jsonb_build_object(
        'revenue',t.revenue,
        'cost_of_sales',t.cost_of_sales,
        'gross_profit',t.revenue-t.cost_of_sales,
        'expenses',t.expenses,
        'profit_loss',t.revenue-t.cost_of_sales-t.expenses
      )
      from totals t
    )
  )
  into result;

  return result;
end
$$;

revoke all on function public.get_accounting_profit_loss(date,date,uuid)
  from public,anon;
grant execute on function public.get_accounting_profit_loss(date,date,uuid)
  to authenticated;
