-- Accounting reports core.
-- Additive read/report layer over the accounting GL only.
-- Operational modules remain disconnected until later integration migrations.

insert into public.accounting_account_mappings(
  mapping_key,scope_type,scope_value,account_id,is_active
)
select
  'current_year_profit_loss','global','',a.id,true
from public.accounting_accounts a
where a.account_code='3.3'
  and not exists(
    select 1
    from public.accounting_account_mappings m
    where lower(btrim(m.mapping_key))='current_year_profit_loss'
      and lower(btrim(m.scope_type))='global'
      and lower(btrim(m.scope_value))=''
      and m.is_active
  );

create or replace function private.accounting_report_assert_access()
returns void
language plpgsql
security definer
set search_path=''
as $$
begin
  if not private.accounting_permission_allowed('accounting_reports_view') then
    raise exception using errcode='42501',message='Accounting reports permission required';
  end if;
end
$$;
revoke all on function private.accounting_report_assert_access() from public,anon,authenticated;

create or replace function public.get_accounting_account_ledger(
  target_account uuid,
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
  account_row public.accounting_accounts%rowtype;
  settings_row public.accounting_settings%rowtype;
  from_date date;
  to_date date;
  opening_raw numeric(18,2):=0;
  result jsonb;
begin
  perform private.accounting_report_assert_access();

  if target_account is null then
    raise exception using errcode='22023',message='Account is required';
  end if;

  select * into account_row
  from public.accounting_accounts
  where id=target_account;

  if not found then
    raise exception using errcode='P0002',message='Accounting account was not found';
  end if;

  select * into settings_row
  from public.accounting_settings
  where id=true;

  to_date:=coalesce(date_to,current_date);
  from_date:=coalesce(
    date_from,
    settings_row.activation_date,
    (select min(j.entry_date) from public.accounting_journal_entries j where j.status in ('posted','reversed')),
    to_date
  );

  if from_date>to_date then
    raise exception using errcode='22007',message='Invalid ledger date range';
  end if;

  select coalesce(sum(l.debit-l.credit),0)
  into opening_raw
  from public.accounting_journal_lines l
  join public.accounting_journal_entries j on j.id=l.journal_entry_id
  where l.account_id=target_account
    and j.status in ('posted','reversed')
    and j.entry_date<from_date
    and (target_project is null or coalesce(l.project_id,j.project_id)=target_project);

  with ordered as (
    select
      l.id as line_id,
      l.line_number,
      j.id as journal_entry_id,
      j.entry_number,
      j.entry_date,
      j.description as journal_description,
      j.reference as journal_reference,
      j.entry_origin,
      j.source_module,
      j.source_event,
      j.source_record_id,
      j.revision_number,
      j.master_overridden,
      l.description as line_description,
      l.reference as line_reference,
      l.debit,
      l.credit,
      l.partner_type,
      l.partner_id,
      coalesce(l.project_id,j.project_id) as project_id,
      l.department_id,
      l.cost_center_reference,
      opening_raw
        + sum(l.debit-l.credit) over(
            order by j.entry_date,j.entry_number,l.line_number,l.id
            rows between unbounded preceding and current row
          ) as running_raw
    from public.accounting_journal_lines l
    join public.accounting_journal_entries j on j.id=l.journal_entry_id
    where l.account_id=target_account
      and j.status in ('posted','reversed')
      and j.entry_date between from_date and to_date
      and (target_project is null or coalesce(l.project_id,j.project_id)=target_project)
  )
  select jsonb_build_object(
    'account',to_jsonb(account_row),
    'period',jsonb_build_object('from',from_date,'to',to_date),
    'project_id',target_project,
    'opening_raw',opening_raw,
    'opening_balance',case when account_row.normal_balance='debit' then opening_raw else -opening_raw end,
    'opening_side',case when opening_raw>0 then 'debit' when opening_raw<0 then 'credit' else 'zero' end,
    'transactions',coalesce(
      (
        select jsonb_agg(
          to_jsonb(o)
          || jsonb_build_object(
            'running_balance',
              case when account_row.normal_balance='debit' then o.running_raw else -o.running_raw end,
            'running_side',
              case when o.running_raw>0 then 'debit' when o.running_raw<0 then 'credit' else 'zero' end
          )
          order by o.entry_date,o.entry_number,o.line_number,o.line_id
        )
        from ordered o
      ),
      '[]'::jsonb
    ),
    'closing_raw',opening_raw+coalesce((select sum(o.debit-o.credit) from ordered o),0),
    'closing_balance',
      case
        when account_row.normal_balance='debit'
          then opening_raw+coalesce((select sum(o.debit-o.credit) from ordered o),0)
        else -(opening_raw+coalesce((select sum(o.debit-o.credit) from ordered o),0))
      end
  )
  into result;

  return result;
end
$$;

create or replace function public.get_accounting_trial_balance(
  date_from date default null,
  date_to date default null,
  target_account uuid default null,
  target_account_type text default null,
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

  if target_account_type is not null
     and target_account_type not in ('asset','liability','equity','revenue','cost_of_sales','expense') then
    raise exception using errcode='22023',message='Invalid account type filter';
  end if;

  if target_account is not null
     and not exists(select 1 from public.accounting_accounts where id=target_account) then
    raise exception using errcode='P0002',message='Accounting account was not found';
  end if;

  select * into settings_row from public.accounting_settings where id=true;
  to_date:=coalesce(date_to,current_date);
  from_date:=coalesce(
    date_from,
    settings_row.activation_date,
    (select min(j.entry_date) from public.accounting_journal_entries j where j.status in ('posted','reversed')),
    to_date
  );

  if from_date>to_date then
    raise exception using errcode='22007',message='Invalid trial balance date range';
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
  target_scope as (
    select a.id
    from public.accounting_accounts a
    where (target_account_type is null or a.account_type=target_account_type)
      and (
        target_account is null
        or a.id in (
          select d.descendant_id
          from descendants d
          where d.ancestor_id=target_account
        )
      )
  ),
  direct as (
    select
      l.account_id,
      coalesce(sum(l.debit) filter(where j.entry_date<from_date),0)::numeric(18,2) as opening_debit_activity,
      coalesce(sum(l.credit) filter(where j.entry_date<from_date),0)::numeric(18,2) as opening_credit_activity,
      coalesce(sum(l.debit) filter(where j.entry_date between from_date and to_date),0)::numeric(18,2) as period_debit,
      coalesce(sum(l.credit) filter(where j.entry_date between from_date and to_date),0)::numeric(18,2) as period_credit
    from public.accounting_journal_lines l
    join public.accounting_journal_entries j on j.id=l.journal_entry_id
    where j.status in ('posted','reversed')
      and j.entry_date<=to_date
      and l.account_id in (select id from target_scope)
      and (target_project is null or coalesce(l.project_id,j.project_id)=target_project)
    group by l.account_id
  ),
  aggregated as (
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
      a.is_active,
      coalesce(dt.depth,1) as depth,
      coalesce(sum(coalesce(x.opening_debit_activity,0)-coalesce(x.opening_credit_activity,0)),0)::numeric(18,2) as opening_net,
      coalesce(sum(coalesce(x.period_debit,0)),0)::numeric(18,2) as period_debit,
      coalesce(sum(coalesce(x.period_credit,0)),0)::numeric(18,2) as period_credit
    from public.accounting_accounts a
    join target_scope s on s.id=a.id
    left join depth_tree dt on dt.id=a.id
    left join descendants d on d.ancestor_id=a.id and d.descendant_id in (select id from target_scope)
    left join direct x on x.account_id=d.descendant_id
    group by a.id,a.account_code,a.name_ar,a.name_en,a.parent_id,a.account_type,a.normal_balance,
             a.is_contra,a.is_posting,a.is_active,dt.depth
  ),
  rows as (
    select
      ag.*,
      ag.opening_net+ag.period_debit-ag.period_credit as closing_net
    from aggregated ag
  ),
  scope_totals as (
    select
      coalesce(sum(d.opening_debit_activity),0)::numeric(18,2) as opening_debit_activity,
      coalesce(sum(d.opening_credit_activity),0)::numeric(18,2) as opening_credit_activity,
      coalesce(sum(d.period_debit),0)::numeric(18,2) as period_debit,
      coalesce(sum(d.period_credit),0)::numeric(18,2) as period_credit
    from direct d
  )
  select jsonb_build_object(
    'period',jsonb_build_object('from',from_date,'to',to_date),
    'filters',jsonb_build_object(
      'account_id',target_account,
      'account_type',target_account_type,
      'project_id',target_project
    ),
    'rows',coalesce(
      (
        select jsonb_agg(
          to_jsonb(r)
          || jsonb_build_object(
            'opening_debit',case when r.opening_net>=0 then r.opening_net else 0 end,
            'opening_credit',case when r.opening_net<0 then -r.opening_net else 0 end,
            'closing_debit',case when r.closing_net>=0 then r.closing_net else 0 end,
            'closing_credit',case when r.closing_net<0 then -r.closing_net else 0 end
          )
          order by string_to_array(r.account_code,'.')::text[]
        )
        from rows r
      ),
      '[]'::jsonb
    ),
    'totals',(
      select jsonb_build_object(
        'opening_debit_activity',t.opening_debit_activity,
        'opening_credit_activity',t.opening_credit_activity,
        'period_debit',t.period_debit,
        'period_credit',t.period_credit,
        'closing_debit_activity',t.opening_debit_activity+t.period_debit,
        'closing_credit_activity',t.opening_credit_activity+t.period_credit,
        'period_balanced',abs(t.period_debit-t.period_credit)<0.005
      )
      from scope_totals t
    ),
    'full_gl_balanced',coalesce(
      (
        select abs(coalesce(sum(l.debit),0)-coalesce(sum(l.credit),0))<0.005
        from public.accounting_journal_lines l
        join public.accounting_journal_entries j on j.id=l.journal_entry_id
        where j.status in ('posted','reversed') and j.entry_date<=to_date
      ),
      true
    )
  )
  into result;

  return result;
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
  revenue_total numeric(18,2):=0;
  cost_total numeric(18,2):=0;
  expense_total numeric(18,2):=0;
  current_profit numeric(18,2):=0;
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

  fiscal_year_value:=coalesce(fiscal_year_value,extract(year from report_date)::integer);

  select min(p.period_start)
  into fiscal_start
  from public.accounting_periods p
  where p.fiscal_year=fiscal_year_value
    and p.period_start<=report_date;

  fiscal_start:=coalesce(fiscal_start,date_trunc('year',report_date)::date);

  select m.account_id
  into cypl_account
  from public.accounting_account_mappings m
  where lower(btrim(m.mapping_key))='current_year_profit_loss'
    and lower(btrim(m.scope_type))='global'
    and lower(btrim(m.scope_value))=''
    and m.is_active
  order by m.created_at desc
  limit 1;

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

  with recursive cypl_tree as (
    select a.id from public.accounting_accounts a where a.id=cypl_account
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

  total_equity:=ledger_equity_excluding_cypl+current_profit;

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
    select a.id from public.accounting_accounts a where a.id=cypl_account
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
          coalesce(sum(case when da.account_id=d.descendant_id then da.raw_balance else 0 end),0)
        when a.account_type='liability' then
          -coalesce(sum(case when da.account_id=d.descendant_id then da.raw_balance else 0 end),0)
        when a.account_type='equity' then
          (
            -coalesce(sum(
              case
                when da.account_id=d.descendant_id
                 and (cypl_account is null or d.descendant_id not in (select id from cypl_tree))
                then da.raw_balance
                else 0
              end
            ),0)
            + case
                when cypl_account is not null
                 and exists(
                   select 1 from descendants x
                   where x.ancestor_id=a.id and x.descendant_id=cypl_account
                 )
                then current_profit
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
    group by a.id,a.account_code,a.name_ar,a.name_en,a.parent_id,a.account_type,
             a.normal_balance,a.is_contra,a.is_posting,dt.depth
  ),
  cypl_direct as (
    select coalesce(sum(d.raw_balance),0)::numeric(18,2) as raw_balance
    from direct d
    where cypl_account is not null and d.account_id in (select id from cypl_tree)
  )
  select jsonb_build_object(
    'as_of_date',report_date,
    'fiscal_year',fiscal_year_value,
    'fiscal_start',fiscal_start,
    'rows',coalesce(
      (
        select jsonb_agg(to_jsonb(r) order by string_to_array(r.account_code,'.')::text[])
        from statement_rows r
      ),
      '[]'::jsonb
    ),
    'profit_loss',jsonb_build_object(
      'revenue',revenue_total,
      'cost_of_sales',cost_total,
      'expenses',expense_total,
      'current_period_profit_loss',current_profit
    ),
    'summary',jsonb_build_object(
      'total_assets',total_assets,
      'total_liabilities',total_liabilities,
      'ledger_equity_excluding_current_year_profit_loss',ledger_equity_excluding_cypl,
      'current_period_profit_loss',current_profit,
      'total_equity',total_equity,
      'total_liabilities_and_equity',total_liabilities+total_equity,
      'difference',total_assets-(total_liabilities+total_equity),
      'is_balanced',abs(total_assets-(total_liabilities+total_equity))<0.005
    ),
    'current_year_profit_loss_mapping',jsonb_build_object(
      'account_id',cypl_account,
      'direct_raw_balance',coalesce((select raw_balance from cypl_direct),0),
      'presentation_is_derived',true
    )
  )
  into result;

  return result;
end
$$;

revoke all on function public.get_accounting_account_ledger(uuid,date,date,uuid) from public,anon;
revoke all on function public.get_accounting_trial_balance(date,date,uuid,text,uuid) from public,anon;
revoke all on function public.get_accounting_balance_sheet(date) from public,anon;

grant execute on function public.get_accounting_account_ledger(uuid,date,date,uuid) to authenticated;
grant execute on function public.get_accounting_trial_balance(date,date,uuid,text,uuid) to authenticated;
grant execute on function public.get_accounting_balance_sheet(date) to authenticated;
