create table public.accounting_accounts (
  id uuid primary key default gen_random_uuid(),
  account_code text not null,
  name_ar text not null,
  name_en text,
  parent_id uuid references public.accounting_accounts(id) on delete restrict,
  account_type text not null check (account_type in ('asset','liability','equity','revenue','cost_of_sales','expense')),
  normal_balance text not null check (normal_balance in ('debit','credit')),
  is_contra boolean not null default false,
  is_posting boolean not null default true,
  is_active boolean not null default true,
  description text,
  created_by uuid references public.profiles(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint accounting_accounts_code_not_blank check (btrim(account_code) <> ''),
  constraint accounting_accounts_name_ar_not_blank check (btrim(name_ar) <> ''),
  constraint accounting_accounts_name_en_not_blank check (name_en is null or btrim(name_en) <> ''),
  constraint accounting_accounts_not_own_parent check (parent_id is null or parent_id <> id),
  constraint accounting_accounts_normal_balance_contract check (
    (
      is_contra = false and (
        (account_type in ('asset','cost_of_sales','expense') and normal_balance='debit')
        or (account_type in ('liability','equity','revenue') and normal_balance='credit')
      )
    )
    or
    (
      is_contra = true and (
        (account_type in ('asset','cost_of_sales','expense') and normal_balance='credit')
        or (account_type in ('liability','equity','revenue') and normal_balance='debit')
      )
    )
  )
);

create unique index accounting_accounts_code_uidx
  on public.accounting_accounts (lower(btrim(account_code)));
create index accounting_accounts_parent_idx
  on public.accounting_accounts(parent_id);
create index accounting_accounts_type_active_idx
  on public.accounting_accounts(account_type,is_active);

create table public.accounting_journal_entries (
  id uuid primary key default gen_random_uuid(),
  entry_number text not null,
  entry_date date not null,
  reference text,
  description text not null,
  status text not null default 'draft' check (status in ('draft','posted','reversed')),
  entry_origin text not null default 'manual' check (entry_origin in ('manual','system','opening','reversal')),
  source_module text,
  source_event text,
  source_record_id text,
  source_revision integer not null default 1 check (source_revision > 0),
  project_id uuid references public.projects(id) on delete restrict,
  revision_number integer not null default 1 check (revision_number > 0),
  master_overridden boolean not null default false,
  last_edited_by uuid references public.profiles(id) on delete restrict,
  last_edited_at timestamptz,
  last_edit_reason text,
  reversal_of_entry_id uuid references public.accounting_journal_entries(id) on delete restrict,
  reversed_by_entry_id uuid references public.accounting_journal_entries(id) on delete restrict,
  created_by uuid references public.profiles(id) on delete restrict,
  posted_by uuid references public.profiles(id) on delete restrict,
  posted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint accounting_journal_entries_number_not_blank check (btrim(entry_number) <> ''),
  constraint accounting_journal_entries_description_not_blank check (btrim(description) <> ''),
  constraint accounting_journal_entries_reference_not_blank check (reference is null or btrim(reference) <> ''),
  constraint accounting_journal_entries_source_module_not_blank check (source_module is null or btrim(source_module) <> ''),
  constraint accounting_journal_entries_source_event_not_blank check (source_event is null or btrim(source_event) <> ''),
  constraint accounting_journal_entries_source_record_not_blank check (source_record_id is null or btrim(source_record_id) <> ''),
  constraint accounting_journal_entries_last_edit_reason_not_blank check (last_edit_reason is null or btrim(last_edit_reason) <> ''),
  constraint accounting_journal_entries_reversal_not_self check (
    (reversal_of_entry_id is null or reversal_of_entry_id <> id)
    and (reversed_by_entry_id is null or reversed_by_entry_id <> id)
  ),
  constraint accounting_journal_entries_system_source_contract check (
    entry_origin <> 'system'
    or (source_module is not null and source_event is not null and source_record_id is not null)
  ),
  constraint accounting_journal_entries_posted_timestamp_contract check (
    status = 'draft' or posted_at is not null
  )
);

create unique index accounting_journal_entries_number_uidx
  on public.accounting_journal_entries (upper(btrim(entry_number)));
create unique index accounting_journal_entries_one_reversal_uidx
  on public.accounting_journal_entries(reversal_of_entry_id)
  where reversal_of_entry_id is not null;
create index accounting_journal_entries_date_status_idx
  on public.accounting_journal_entries(entry_date,status);
create index accounting_journal_entries_project_idx
  on public.accounting_journal_entries(project_id)
  where project_id is not null;
create index accounting_journal_entries_source_idx
  on public.accounting_journal_entries(source_module,source_event,source_record_id);

create table public.accounting_journal_lines (
  id uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null references public.accounting_journal_entries(id) on delete restrict,
  line_number integer not null check (line_number > 0),
  account_id uuid not null references public.accounting_accounts(id) on delete restrict,
  debit numeric(18,2) not null default 0 check (debit >= 0),
  credit numeric(18,2) not null default 0 check (credit >= 0),
  description text,
  partner_type text check (partner_type is null or partner_type in ('supplier','customer','employee')),
  partner_id uuid,
  project_id uuid references public.projects(id) on delete restrict,
  department_id uuid references public.departments(id) on delete restrict,
  cost_center_reference text,
  source_line_id text,
  reference text,
  transaction_currency text,
  foreign_amount numeric(18,4) check (foreign_amount is null or foreign_amount >= 0),
  exchange_rate numeric(18,8) check (exchange_rate is null or exchange_rate > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint accounting_journal_lines_amount_side_check check (
    (debit > 0 and credit = 0) or (credit > 0 and debit = 0)
  ),
  constraint accounting_journal_lines_description_not_blank check (description is null or btrim(description) <> ''),
  constraint accounting_journal_lines_cost_center_not_blank check (cost_center_reference is null or btrim(cost_center_reference) <> ''),
  constraint accounting_journal_lines_source_line_not_blank check (source_line_id is null or btrim(source_line_id) <> ''),
  constraint accounting_journal_lines_reference_not_blank check (reference is null or btrim(reference) <> ''),
  constraint accounting_journal_lines_currency_contract check (
    transaction_currency is null or transaction_currency ~ '^[A-Z]{3}$'
  ),
  constraint accounting_journal_lines_foreign_contract check (
    (foreign_amount is null and exchange_rate is null and transaction_currency is null)
    or (foreign_amount is not null and exchange_rate is not null and transaction_currency is not null)
  ),
  unique(journal_entry_id,line_number)
);

create index accounting_journal_lines_entry_idx
  on public.accounting_journal_lines(journal_entry_id);
create index accounting_journal_lines_account_idx
  on public.accounting_journal_lines(account_id,journal_entry_id);
create index accounting_journal_lines_project_idx
  on public.accounting_journal_lines(project_id)
  where project_id is not null;

create table public.accounting_journal_revisions (
  id uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null references public.accounting_journal_entries(id) on delete restrict,
  revision_number integer not null check (revision_number > 0),
  header_before jsonb not null,
  lines_before jsonb not null,
  header_after jsonb not null,
  lines_after jsonb not null,
  edit_reason text not null,
  edited_by uuid not null references public.profiles(id) on delete restrict,
  edited_at timestamptz not null default now(),
  constraint accounting_journal_revisions_reason_not_blank check (btrim(edit_reason) <> ''),
  unique(journal_entry_id,revision_number)
);

create index accounting_journal_revisions_entry_idx
  on public.accounting_journal_revisions(journal_entry_id,revision_number);

create table public.accounting_account_mappings (
  id uuid primary key default gen_random_uuid(),
  mapping_key text not null,
  scope_type text not null default 'global',
  scope_value text not null default '',
  account_id uuid not null references public.accounting_accounts(id) on delete restrict,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint accounting_account_mappings_key_not_blank check (btrim(mapping_key) <> ''),
  constraint accounting_account_mappings_scope_not_blank check (btrim(scope_type) <> '')
);

create unique index accounting_account_mappings_active_uidx
  on public.accounting_account_mappings(
    lower(btrim(mapping_key)),
    lower(btrim(scope_type)),
    lower(btrim(scope_value))
  ) where is_active;
create index accounting_account_mappings_account_idx
  on public.accounting_account_mappings(account_id);

create table public.accounting_source_links (
  id uuid primary key default gen_random_uuid(),
  source_module text not null,
  source_event text not null,
  source_record_id text not null,
  source_line_id text,
  source_revision integer not null default 1 check (source_revision > 0),
  journal_entry_id uuid not null references public.accounting_journal_entries(id) on delete restrict,
  link_status text not null default 'active' check (link_status in ('active','reversed')),
  created_at timestamptz not null default now(),
  constraint accounting_source_links_module_not_blank check (btrim(source_module) <> ''),
  constraint accounting_source_links_event_not_blank check (btrim(source_event) <> ''),
  constraint accounting_source_links_record_not_blank check (btrim(source_record_id) <> ''),
  constraint accounting_source_links_line_not_blank check (source_line_id is null or btrim(source_line_id) <> '')
);

create unique index accounting_source_links_source_uidx
  on public.accounting_source_links(
    lower(btrim(source_module)),
    lower(btrim(source_event)),
    source_record_id,
    coalesce(source_line_id,''),
    source_revision
  );
create index accounting_source_links_journal_idx
  on public.accounting_source_links(journal_entry_id);

create table public.accounting_settings (
  id boolean primary key default true check (id),
  enabled boolean not null default false,
  activation_date date,
  base_currency text not null,
  created_by uuid references public.profiles(id) on delete restrict,
  updated_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint accounting_settings_currency_contract check (base_currency ~ '^[A-Z]{3}$'),
  constraint accounting_settings_activation_contract check (not enabled or activation_date is not null)
);

create table public.accounting_periods (
  id uuid primary key default gen_random_uuid(),
  period_start date not null,
  period_end date not null,
  fiscal_year integer not null,
  status text not null default 'open' check (status in ('open','locked')),
  locked_by uuid references public.profiles(id) on delete restrict,
  locked_at timestamptz,
  lock_reason text,
  reopened_by uuid references public.profiles(id) on delete restrict,
  reopened_at timestamptz,
  reopen_reason text,
  created_at timestamptz not null default now(),
  constraint accounting_periods_date_order check (period_end >= period_start),
  constraint accounting_periods_year_contract check (fiscal_year between 2000 and 9999),
  constraint accounting_periods_lock_contract check (
    status <> 'locked'
    or (locked_by is not null and locked_at is not null and lock_reason is not null and btrim(lock_reason) <> '')
  ),
  constraint accounting_periods_reopen_reason_not_blank check (reopen_reason is null or btrim(reopen_reason) <> ''),
  unique(period_start,period_end)
);

create index accounting_periods_range_idx
  on public.accounting_periods(period_start,period_end,status);

create or replace function private.accounting_guard_account_hierarchy()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.parent_id is null then return new; end if;
  if new.parent_id = new.id then
    raise exception using errcode='23514',message='Account cannot be its own parent';
  end if;
  if exists (
    with recursive ancestors as (
      select a.id,a.parent_id
      from public.accounting_accounts a
      where a.id=new.parent_id
      union all
      select p.id,p.parent_id
      from public.accounting_accounts p
      join ancestors x on x.parent_id=p.id
    )
    select 1 from ancestors where id=new.id
  ) then
    raise exception using errcode='23514',message='Circular account hierarchy is not allowed';
  end if;
  return new;
end
$$;

create trigger accounting_accounts_hierarchy_guard
before insert or update of parent_id on public.accounting_accounts
for each row execute function private.accounting_guard_account_hierarchy();

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
  if not target.is_active then
    raise exception using errcode='23514',message='Inactive account cannot receive journal postings';
  end if;
  if not target.is_posting then
    raise exception using errcode='23514',message='Group account cannot receive journal postings';
  end if;
  return new;
end
$$;

create trigger accounting_journal_lines_posting_account_guard
before insert or update of account_id on public.accounting_journal_lines
for each row execute function private.accounting_guard_posting_account();

create or replace function private.accounting_assert_entry_balanced(target_entry uuid)
returns void
language plpgsql
set search_path=''
as $$
declare
  target_status text;
  line_count integer;
  debit_total numeric(18,2);
  credit_total numeric(18,2);
begin
  select status into target_status
  from public.accounting_journal_entries
  where id=target_entry;

  if not found or target_status='draft' then return; end if;

  select count(*),coalesce(sum(debit),0),coalesce(sum(credit),0)
    into line_count,debit_total,credit_total
  from public.accounting_journal_lines
  where journal_entry_id=target_entry;

  if line_count < 2 or debit_total <= 0 or credit_total <= 0 or debit_total <> credit_total then
    raise exception using
      errcode='23514',
      message='Posted journal entry must contain at least two lines and total debit must equal total credit';
  end if;
end
$$;

create or replace function private.accounting_deferred_balance_guard()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if tg_table_name='accounting_journal_entries' then
    perform private.accounting_assert_entry_balanced(coalesce(new.id,old.id));
  else
    if tg_op='UPDATE' and old.journal_entry_id is distinct from new.journal_entry_id then
      perform private.accounting_assert_entry_balanced(old.journal_entry_id);
    end if;
    perform private.accounting_assert_entry_balanced(
      case when tg_op='DELETE' then old.journal_entry_id else new.journal_entry_id end
    );
  end if;
  return null;
end
$$;

create constraint trigger accounting_journal_entries_balance_guard
after insert or update on public.accounting_journal_entries
deferrable initially deferred
for each row execute function private.accounting_deferred_balance_guard();

create constraint trigger accounting_journal_lines_balance_guard
after insert or update or delete on public.accounting_journal_lines
deferrable initially deferred
for each row execute function private.accounting_deferred_balance_guard();

alter table public.accounting_accounts enable row level security;
alter table public.accounting_journal_entries enable row level security;
alter table public.accounting_journal_lines enable row level security;
alter table public.accounting_journal_revisions enable row level security;
alter table public.accounting_account_mappings enable row level security;
alter table public.accounting_source_links enable row level security;
alter table public.accounting_settings enable row level security;
alter table public.accounting_periods enable row level security;

revoke all on table public.accounting_accounts from anon, authenticated;
revoke all on table public.accounting_journal_entries from anon, authenticated;
revoke all on table public.accounting_journal_lines from anon, authenticated;
revoke all on table public.accounting_journal_revisions from anon, authenticated;
revoke all on table public.accounting_account_mappings from anon, authenticated;
revoke all on table public.accounting_source_links from anon, authenticated;
revoke all on table public.accounting_settings from anon, authenticated;
revoke all on table public.accounting_periods from anon, authenticated;
