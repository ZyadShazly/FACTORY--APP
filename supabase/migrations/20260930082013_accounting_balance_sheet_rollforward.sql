-- Fix Balance Sheet fiscal-year roll-forward when prior P/L has not yet
-- been closed into retained earnings.
-- Reporting only: no operational rows or journal lines are changed.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,
  suggested_account_code,description,required_for_auto_posting,sort_order
)
values(
  'retained_earnings',
  'الأرباح المبقاة',
  'Retained Earnings',
  'reports',
  array['equity']::text[],
  '3.2',
  'حساب عرض الأرباح المبقاة؛ يستقبل عرض prior unclosed P/L بدون إنشاء قيد تلقائي.',
  false,
  191
)
on conflict(mapping_key) do update set
  label_ar=excluded.label_ar,
  label_en=excluded.label_en,
  module=excluded.module,
  expected_account_types=excluded.expected_account_types,
  suggested_account_code=excluded.suggested_account_code,
  description=excluded.description,
  required_for_auto_posting=excluded.required_for_auto_posting,
  sort_order=excluded.sort_order,
  is_active=true;

insert into public.accounting_account_mappings(
  mapping_key,scope_type,scope_value,account_id,is_active
)
select
  'retained_earnings','global','',a.id,true
from public.accounting_accounts a
where lower(btrim(a.account_code))='3.2'
  and a.account_type='equity'
  and a.is_active
  and a.is_posting
  and not exists(
    select 1
    from public.accounting_account_mappings m
    where lower(btrim(m.mapping_key))='retained_earnings'
      and lower(btrim(m.scope_type))='global'
      and btrim(m.scope_value)=''
      and m.is_active
  );

do $$
declare
  mapped_account public.accounting_accounts%rowtype;
begin
  select a.*
  into mapped_account
  from public.accounting_account_mappings m
  join public.accounting_accounts a on a.id=m.account_id
  where lower(btrim(m.mapping_key))='retained_earnings'
    and lower(btrim(m.scope_type))='global'
    and btrim(m.scope_value)=''
    and m.is_active
  order by m.updated_at desc
  limit 1;

  if not found
     or mapped_account.account_type<>'equity'
     or not mapped_account.is_active
     or not mapped_account.is_posting then
    raise exception using
      errcode='23514',
      message='Retained earnings reporting mapping is missing or invalid';
  end if;
end
$$;

create or replace function public.get_accounting_balance_sheet(
  as_of_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  report_date date:=coalesce(as_of_date,current_date);
  fiscal_year_value integer;
  fiscal_start date;
  cypl_account uuid;
  retained_account uuid;
  revenue_total numeric(18,2):=0;
  cost_total numeric(18,2):=0;
  expense_total numeric(18,2):=0;
  current_profit numeric(18,2):=0;
  cumulative_revenue numeric(18,2):=0;
  cumulative_cost numeric(18,2):=0;
  cumulative_expense numeric(18,2):=0;
  cumulative_profit numeric(18,2):=0;
  prior_unclosed_profit numeric(18,2):=0;
  total_assets numeric(18,2):=0;
  total_liabilities numeric(18,2):=0;
  ledger_equity_excluding_cypl numeric(18,2):=0;
  total_equity numeric(18,2):=0;
  result jsonb;
begin
  perform private.accounting_report_assert_access();

  select p.fiscal_year
  into fiscal_year_value
  from public.accounting_periods p
  where report_date between p.period_start and p.period_end
  order by p.period_start desc
  limit 1;

  fiscal_year_value:=coalesce(
    fiscal_year_value,
    extract(year from report_date)::integer
  );

  select min(p.period_start)
  into fiscal_start
  from public.accounting_periods p
  where p.fiscal_year=fiscal_year_value
    and p.period_start<=report_date;

  fiscal_start:=coalesce(
    fiscal_start,
    date_trunc('year',report_date)::date
  );

  select m.account_id
  into cypl_account
  from public.accounting_account_mappings m
  where lower(btrim(m.mapping_key))='current_year_profit_loss'
    and lower(btrim(m.scope_type))='global'
    and lower(btrim(m.scope_value))=''
    and m.is_active
  order by m.updated_at desc
  limit 1;

  select m.account_id
  into retained_account
  from public.accounting_account_mappings m
  where lower(btrim(m.mapping_key))='retained_earnings'
    and lower(btrim(m.scope_type))='global'
    and lower(btrim(m.scope_value))=''
    and m.is_active
  order by m.updated_at desc
  limit 1;

  if retained_account is null then
    raise exception using
      errcode='23514',
      message='Retained earnings reporting mapping is required';
  end if;

  -- Current fiscal-period P/L.
  select
    coalesce(sum(case when a.account_type='revenue' then l.credit-l.debit else 0 end),0),
    coalesce(sum(case when a.account_type='cost_of_sales' then l.debit-l.credit else 0 end),0),
    coalesce(sum(case when a.account_type='expense' then l.debit-l.credit else 0 end),0)
  into revenue_total,cost_total,expense_total
  from public.accounting_journal_lines l
  join public.accounting_journal_entries j on j.id=l.journal_entry_id
  join public.accounting_accounts a on a.id=l.account_id
  where j.status in ('posted','reversed')
    and j.entry_date between fiscal_start and report_date;

  current_profit:=revenue_total-cost_total-expense_total;

  -- Cumulative unclosed P/L through the report date.
  -- If prior years were closed through journal entries, those closing entries
  -- zero the historical P/L accounts and this derived amount naturally drops.
  select
    coalesce(sum(case when a.account_type='revenue' then l.credit-l.debit else 0 end),0),
    coalesce(sum(case when a.account_type='cost_of_sales' then l.debit-l.credit else 0 end),0),
    coalesce(sum(case when a.account_type='expense' then l.debit-l.credit else 0 end),0)
  into cumulative_revenue,cumulative_cost,cumulative_expense
  from public.accounting_journal_lines l
  join public.accounting_journal_entries j on j.id=l.journal_entry_id
  join public.accounting_accounts a on a.id=l.account_id
  where j.status in ('posted','reversed')
    and j.entry_date<=report_date;

  cumulative_profit:=
    cumulative_revenue-cumulative_cost-cumulative_expense;
  prior_unclosed_profit:=cumulative_profit-current_profit;

  with recursive cypl_tree as (
    select a.id
    from public.accounting_accounts a
    where a.id=cypl_account
    union all
    select c.id
    from public.accounting_accounts c
    join cypl_tree p on c.parent_id=p.id
  )
  select
    coalesce(sum(case when a.account_type='asset' then l.debit-l.credit else 0 end),0),
    coalesce(sum(case when a.account_type='liability' then l.credit-l.debit else 0 end),0),
    coalesce(sum(
      case
        when a.account_type='equity'
         and (cypl_account is null or a.id not in (select id from cypl_tree))
        then l.credit-l.debit
        else 0
      end
    ),0)
  into total_assets,total_liabilities,ledger_equity_excluding_cypl
  from public.accounting_journal_lines l
  join public.accounting_journal_entries j on j.id=l.journal_entry_id
  join public.accounting_accounts a on a.id=l.account_id
  where j.status in ('posted','reversed')
    and j.entry_date<=report_date;

  total_equity:=
    ledger_equity_excluding_cypl+cumulative_profit;

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
  cypl_tree as (
    select a.id
    from public.accounting_accounts a
    where a.id=cypl_account
    union all
    select c.id
    from public.accounting_accounts c
    join cypl_tree p on c.parent_id=p.id
  ),
  direct as (
    select
      l.account_id,
      coalesce(sum(l.debit-l.credit),0)::numeric(18,2) as raw_balance
    from public.accounting_journal_lines l
    join public.accounting_journal_entries j on j.id=l.journal_entry_id
    where j.status in ('posted','reversed')
      and j.entry_date<=report_date
    group by l.account_id
  ),
  statement_rows as (
    select
      a.id,
      a.account_code,
      a.name_ar,
      a.name_en,
      a.parent_id,
      a.account_type,
      a.normal_balance,
      a.is_contra,
      a.is_posting,
      coalesce(dt.depth,1) as depth,
      case
        when a.account_type='asset' then
          coalesce(sum(
            case
              when da.account_id=d.descendant_id then da.raw_balance
              else 0
            end
          ),0)
        when a.account_type='liability' then
          -coalesce(sum(
            case
              when da.account_id=d.descendant_id then da.raw_balance
              else 0
            end
          ),0)
        when a.account_type='equity' then
          (
            -coalesce(sum(
              case
                when da.account_id=d.descendant_id
                 and (
                   cypl_account is null
                   or d.descendant_id not in (select id from cypl_tree)
                 )
                then da.raw_balance
                else 0
              end
            ),0)
            + case
                when cypl_account is not null
                 and exists(
                   select 1
                   from descendants x
                   where x.ancestor_id=a.id
                     and x.descendant_id=cypl_account
                 )
                then current_profit
                else 0
              end
            + case
                when retained_account is not null
                 and exists(
                   select 1
                   from descendants x
                   where x.ancestor_id=a.id
                     and x.descendant_id=retained_account
                 )
                then prior_unclosed_profit
                else 0
              end
          )
        else 0
      end::numeric(18,2) as amount
    from public.accounting_accounts a
    left join depth_tree dt on dt.id=a.id
    left join descendants d on d.ancestor_id=a.id
    left join direct da on da.account_id=d.descendant_id
    where a.account_type in ('asset','liability','equity')
    group by
      a.id,a.account_code,a.name_ar,a.name_en,a.parent_id,
      a.account_type,a.normal_balance,a.is_contra,a.is_posting,dt.depth
  ),
  cypl_direct as (
    select coalesce(sum(d.raw_balance),0)::numeric(18,2) as raw_balance
    from direct d
    where cypl_account is not null
      and d.account_id in (select id from cypl_tree)
  ),
  retained_direct as (
    select coalesce(d.raw_balance,0)::numeric(18,2) as raw_balance
    from direct d
    where d.account_id=retained_account
  )
  select jsonb_build_object(
    'as_of_date',report_date,
    'fiscal_year',fiscal_year_value,
    'fiscal_start',fiscal_start,
    'rows',coalesce(
      (
        select jsonb_agg(
          to_jsonb(r)
          order by string_to_array(r.account_code,'.')::text[]
        )
        from statement_rows r
      ),
      '[]'::jsonb
    ),
    'profit_loss',jsonb_build_object(
      'revenue',revenue_total,
      'cost_of_sales',cost_total,
      'expenses',expense_total,
      'current_period_profit_loss',current_profit,
      'prior_unclosed_profit_loss',prior_unclosed_profit,
      'cumulative_unclosed_profit_loss',cumulative_profit
    ),
    'summary',jsonb_build_object(
      'total_assets',total_assets,
      'total_liabilities',total_liabilities,
      'ledger_equity_excluding_current_year_profit_loss',
        ledger_equity_excluding_cypl,
      'prior_unclosed_profit_loss',prior_unclosed_profit,
      'current_period_profit_loss',current_profit,
      'cumulative_unclosed_profit_loss',cumulative_profit,
      'total_equity',total_equity,
      'total_liabilities_and_equity',total_liabilities+total_equity,
      'difference',total_assets-(total_liabilities+total_equity),
      'is_balanced',
        abs(total_assets-(total_liabilities+total_equity))<0.005
    ),
    'current_year_profit_loss_mapping',jsonb_build_object(
      'account_id',cypl_account,
      'direct_raw_balance',
        coalesce((select raw_balance from cypl_direct),0),
      'presentation_is_derived',true
    ),
    'retained_earnings_mapping',jsonb_build_object(
      'account_id',retained_account,
      'direct_raw_balance',
        coalesce((select raw_balance from retained_direct),0),
      'presentation_adjustment',prior_unclosed_profit,
      'presentation_is_derived',true
    )
  )
  into result;

  return result;
end
$$;

revoke all on function public.get_accounting_balance_sheet(date)
  from public,anon;
grant execute on function public.get_accounting_balance_sheet(date)
  to authenticated;
