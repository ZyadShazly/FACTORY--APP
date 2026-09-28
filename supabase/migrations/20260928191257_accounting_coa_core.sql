create or replace function private.accounting_permission_allowed(permission_name text)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select case
    when auth.uid() is null then false
    when not public.is_current_profile_active() then false
    when public.current_identity_role()='owner' then true
    when permission_name in ('accounting_journal_edit_posted','accounting_settings_manage','accounting_period_manage') then false
    when public.current_identity_role()='accountant' then
      coalesce(
        (
          select (p.permissions->>permission_name)::boolean
          from public.profiles p
          where p.id=auth.uid() and p.status='active'
        ),
        permission_name = any(array[
          'accounting_view',
          'accounting_accounts_manage',
          'accounting_journal_create',
          'accounting_journal_post',
          'accounting_journal_reverse',
          'accounting_reports_view'
        ])
      )
    when public.current_identity_role()='manager' then
      coalesce(
        (
          select (p.permissions->>permission_name)::boolean
          from public.profiles p
          where p.id=auth.uid() and p.status='active'
        ),
        false
      )
    else false
  end
$$;

revoke all on function private.accounting_permission_allowed(text) from public,anon,authenticated;

create or replace function private.accounting_guard_account_hierarchy()
returns trigger
language plpgsql
set search_path=''
as $$
declare parent_type text;
begin
  if new.parent_id is null then return new; end if;
  if new.parent_id = new.id then
    raise exception using errcode='23514',message='Account cannot be its own parent';
  end if;

  select account_type into parent_type
  from public.accounting_accounts
  where id=new.parent_id;

  if not found then
    raise exception using errcode='23503',message='Parent account was not found';
  end if;
  if parent_type<>new.account_type then
    raise exception using errcode='23514',message='Child account type must match its parent account type';
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

create or replace function private.accounting_guard_account_state()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.is_posting and exists(
    select 1 from public.accounting_accounts child where child.parent_id=new.id
  ) then
    raise exception using errcode='23514',message='Account with subaccounts must remain a group account';
  end if;

  if not new.is_active and exists(
    select 1 from public.accounting_accounts child
    where child.parent_id=new.id and child.is_active
  ) then
    raise exception using errcode='23514',message='Deactivate active subaccounts before deactivating their parent';
  end if;

  if new.account_type is distinct from old.account_type
     or new.is_contra is distinct from old.is_contra then
    if exists(select 1 from public.accounting_journal_lines l where l.account_id=new.id) then
      raise exception using errcode='23514',message='Account type or contra status cannot change after journal activity';
    end if;
    if exists(select 1 from public.accounting_accounts child where child.parent_id=new.id) then
      raise exception using errcode='23514',message='Account type or contra status cannot change while subaccounts exist';
    end if;
  end if;

  if new.parent_id is not null and exists(
    select 1 from public.accounting_accounts p
    where p.id=new.parent_id and p.account_type<>new.account_type
  ) then
    raise exception using errcode='23514',message='Child account type must match its parent account type';
  end if;

  return new;
end
$$;

drop trigger if exists accounting_accounts_state_guard on public.accounting_accounts;
create trigger accounting_accounts_state_guard
before update of is_posting,is_active,account_type,is_contra on public.accounting_accounts
for each row execute function private.accounting_guard_account_state();

insert into public.accounting_settings(id,enabled,activation_date,base_currency)
values(
  true,
  false,
  null,
  coalesce((select s.currency_code from public.system_settings s where s.id=true),'SAR')
)
on conflict(id) do nothing;

do $$
declare
  assets_id uuid;
  current_assets_id uuid;
  liabilities_id uuid;
  current_liabilities_id uuid;
  equity_id uuid;
  revenue_id uuid;
  cos_id uuid;
  expenses_id uuid;
begin
  if exists(select 1 from public.accounting_accounts) then
    return;
  end if;

  insert into public.accounting_accounts(account_code,name_ar,name_en,account_type,normal_balance,is_posting)
  values('1','الأصول','Assets','asset','debit',false)
  returning id into assets_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values('1.1','الأصول المتداولة','Current Assets',assets_id,'asset','debit',false)
  returning id into current_assets_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values
    ('1.1.01','النقدية','Cash',current_assets_id,'asset','debit',true),
    ('1.1.02','البنك','Bank',current_assets_id,'asset','debit',true),
    ('1.1.03','العملاء / الذمم المدينة','Accounts Receivable',current_assets_id,'asset','debit',true),
    ('1.1.04','المخزون','Inventory',current_assets_id,'asset','debit',true),
    ('1.1.05','سلف وعهد الموظفين','Employee Advances',current_assets_id,'asset','debit',true),
    ('1.1.06','دفعات مقدمة للموردين','Supplier Advances',current_assets_id,'asset','debit',true),
    ('1.1.07','ضريبة قيمة مضافة مدخلات','VAT Input',current_assets_id,'asset','debit',true);

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values('1.2','الأصول الثابتة','Fixed Assets',assets_id,'asset','debit',false);

  insert into public.accounting_accounts(account_code,name_ar,name_en,account_type,normal_balance,is_posting)
  values('2','الالتزامات','Liabilities','liability','credit',false)
  returning id into liabilities_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values('2.1','الالتزامات المتداولة','Current Liabilities',liabilities_id,'liability','credit',false)
  returning id into current_liabilities_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values
    ('2.1.01','الموردون / الذمم الدائنة','Accounts Payable',current_liabilities_id,'liability','credit',true),
    ('2.1.02','بضاعة مستلمة غير مفوترة','GRNI',current_liabilities_id,'liability','credit',true),
    ('2.1.03','رواتب مستحقة','Payroll Payable',current_liabilities_id,'liability','credit',true),
    ('2.1.04','عمالة يومية مستحقة','Daily Labor Payable',current_liabilities_id,'liability','credit',true),
    ('2.1.05','دفعات مقدمة من العملاء','Customer Advances',current_liabilities_id,'liability','credit',true),
    ('2.1.06','مصروفات مستحقة','Accrued Expenses',current_liabilities_id,'liability','credit',true),
    ('2.1.07','ضريبة قيمة مضافة مخرجات','VAT Output',current_liabilities_id,'liability','credit',true);

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values('2.2','الالتزامات طويلة الأجل','Long-Term Liabilities',liabilities_id,'liability','credit',false);

  insert into public.accounting_accounts(account_code,name_ar,name_en,account_type,normal_balance,is_posting)
  values('3','حقوق الملكية','Equity','equity','credit',false)
  returning id into equity_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values
    ('3.1','رأس المال','Capital',equity_id,'equity','credit',true),
    ('3.2','الأرباح المبقاة','Retained Earnings',equity_id,'equity','credit',true),
    ('3.3','ربح / خسارة العام الحالي','Current Year Profit / Loss',equity_id,'equity','credit',true),
    ('3.4','حقوق ملكية الأرصدة الافتتاحية','Opening Balance Equity',equity_id,'equity','credit',true);

  insert into public.accounting_accounts(account_code,name_ar,name_en,account_type,normal_balance,is_posting)
  values('4','الإيرادات','Revenue','revenue','credit',false)
  returning id into revenue_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values
    ('4.1','إيرادات المبيعات','Sales Revenue',revenue_id,'revenue','credit',true),
    ('4.2','إيرادات الإيجار','Rental Revenue',revenue_id,'revenue','credit',true),
    ('4.3','إيرادات أخرى','Other Revenue',revenue_id,'revenue','credit',true);

  insert into public.accounting_accounts(account_code,name_ar,name_en,account_type,normal_balance,is_posting)
  values('5','تكلفة المبيعات','Cost of Sales','cost_of_sales','debit',false)
  returning id into cos_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values
    ('5.1','تكلفة البضاعة المباعة','Cost of Goods Sold',cos_id,'cost_of_sales','debit',true),
    ('5.2','تكلفة الإنتاج','Production Cost',cos_id,'cost_of_sales','debit',true);

  insert into public.accounting_accounts(account_code,name_ar,name_en,account_type,normal_balance,is_posting)
  values('6','المصروفات','Expenses','expense','debit',false)
  returning id into expenses_id;

  insert into public.accounting_accounts(account_code,name_ar,name_en,parent_id,account_type,normal_balance,is_posting)
  values
    ('6.1','الرواتب','Salaries',expenses_id,'expense','debit',true),
    ('6.2','العمالة اليومية','Daily Labor',expenses_id,'expense','debit',true),
    ('6.3','الإيجار','Rent',expenses_id,'expense','debit',true),
    ('6.4','المرافق','Utilities',expenses_id,'expense','debit',true),
    ('6.5','النقل','Transportation',expenses_id,'expense','debit',true),
    ('6.6','التسويق','Marketing',expenses_id,'expense','debit',true),
    ('6.7','الصيانة','Maintenance',expenses_id,'expense','debit',true),
    ('6.8','المصاريف البنكية','Bank Charges',expenses_id,'expense','debit',true),
    ('6.9','مصروفات أخرى','Other Expenses',expenses_id,'expense','debit',true);
end
$$;

create or replace function public.get_accounting_accounts()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare result jsonb;
begin
  if not private.accounting_permission_allowed('accounting_view') then
    raise exception using errcode='42501',message='Accounting view permission required';
  end if;

  with recursive tree as (
    select a.*,1 as account_level,array[a.account_code]::text[] as sort_path
    from public.accounting_accounts a
    where a.parent_id is null
    union all
    select child.*,parent.account_level+1,parent.sort_path||child.account_code
    from public.accounting_accounts child
    join tree parent on parent.id=child.parent_id
  )
  select coalesce(jsonb_agg(
    to_jsonb(t)
    || jsonb_build_object(
      'child_count',(select count(*) from public.accounting_accounts c where c.parent_id=t.id),
      'has_activity',exists(select 1 from public.accounting_journal_lines l where l.account_id=t.id)
    )
    order by t.sort_path
  ),'[]'::jsonb)
  into result
  from tree t;

  return result;
end
$$;

create or replace function public.create_accounting_account(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  code_value text:=btrim(coalesce(payload->>'account_code',''));
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
  if code_value='' or name_ar_value='' then
    raise exception using errcode='22023',message='Account code and Arabic name are required';
  end if;
  if type_value not in ('asset','liability','equity','revenue','cost_of_sales','expense') then
    raise exception using errcode='22023',message='Valid account type is required';
  end if;

  normal_value:=case
    when type_value in ('asset','cost_of_sales','expense')
      then case when contra_value then 'credit' else 'debit' end
    else case when contra_value then 'debit' else 'credit' end
  end;

  if parent_value is not null then
    select * into parent_row from public.accounting_accounts where id=parent_value for update;
    if not found then raise exception using errcode='23503',message='Parent account was not found'; end if;
    if not parent_row.is_active then raise exception using errcode='23514',message='Cannot add a subaccount under an inactive account'; end if;
    if parent_row.account_type<>type_value then raise exception using errcode='23514',message='Child account type must match its parent account type'; end if;

    if parent_row.is_posting then
      if exists(select 1 from public.accounting_journal_lines l where l.account_id=parent_row.id) then
        raise exception using errcode='23514',message='Parent account has journal activity; Owner must convert it to a group account before adding subaccounts';
      end if;
      update public.accounting_accounts set is_posting=false,updated_by=actor,updated_at=now() where id=parent_row.id;
    end if;
  end if;

  insert into public.accounting_accounts(
    account_code,name_ar,name_en,parent_id,account_type,normal_balance,
    is_contra,is_posting,is_active,description,created_by,updated_by
  ) values(
    code_value,name_ar_value,name_en_value,parent_value,type_value,normal_value,
    contra_value,posting_value,true,nullif(btrim(payload->>'description'),''),actor,actor
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('accounting_accounts',saved.id::text,'accounting_account_created',actor,to_jsonb(saved),
    jsonb_build_object('account_code',saved.account_code,'parent_id',saved.parent_id));

  return to_jsonb(saved);
exception when unique_violation then
  raise exception using errcode='23505',message='Account code already exists';
end
$$;

create or replace function public.update_accounting_account(target_id uuid,payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  current_row public.accounting_accounts%rowtype;
  parent_row public.accounting_accounts%rowtype;
  saved public.accounting_accounts%rowtype;
  code_value text;
  name_ar_value text;
  name_en_value text;
  type_value text;
  contra_value boolean;
  posting_value boolean;
  active_value boolean;
  parent_value uuid;
  normal_value text;
  has_activity boolean;
  has_children boolean;
begin
  if not private.accounting_permission_allowed('accounting_accounts_manage') then
    raise exception using errcode='42501',message='Accounting account management permission required';
  end if;

  select * into current_row from public.accounting_accounts where id=target_id for update;
  if not found then raise exception using errcode='P0002',message='Accounting account was not found'; end if;

  code_value:=case when payload ? 'account_code' then btrim(coalesce(payload->>'account_code','')) else current_row.account_code end;
  name_ar_value:=case when payload ? 'name_ar' then btrim(coalesce(payload->>'name_ar','')) else current_row.name_ar end;
  name_en_value:=case when payload ? 'name_en' then nullif(btrim(payload->>'name_en'),'') else current_row.name_en end;
  type_value:=case when payload ? 'account_type' then btrim(coalesce(payload->>'account_type','')) else current_row.account_type end;
  contra_value:=case when payload ? 'is_contra' then (payload->>'is_contra')::boolean else current_row.is_contra end;
  posting_value:=case when payload ? 'is_posting' then (payload->>'is_posting')::boolean else current_row.is_posting end;
  active_value:=case when payload ? 'is_active' then (payload->>'is_active')::boolean else current_row.is_active end;
  parent_value:=case when payload ? 'parent_id' then nullif(payload->>'parent_id','')::uuid else current_row.parent_id end;

  if code_value='' or name_ar_value='' then raise exception using errcode='22023',message='Account code and Arabic name are required'; end if;
  if type_value not in ('asset','liability','equity','revenue','cost_of_sales','expense') then raise exception using errcode='22023',message='Valid account type is required'; end if;

  select exists(select 1 from public.accounting_journal_lines l where l.account_id=target_id) into has_activity;
  select exists(select 1 from public.accounting_accounts c where c.parent_id=target_id) into has_children;

  if (type_value is distinct from current_row.account_type or contra_value is distinct from current_row.is_contra)
     and (has_activity or has_children) then
    raise exception using errcode='23514',message='Account type or contra status cannot change after activity or while subaccounts exist';
  end if;
  if posting_value and has_children then raise exception using errcode='23514',message='Account with subaccounts must remain a group account'; end if;
  if not active_value and exists(select 1 from public.accounting_accounts c where c.parent_id=target_id and c.is_active) then
    raise exception using errcode='23514',message='Deactivate active subaccounts before deactivating their parent';
  end if;

  normal_value:=case
    when type_value in ('asset','cost_of_sales','expense')
      then case when contra_value then 'credit' else 'debit' end
    else case when contra_value then 'debit' else 'credit' end
  end;

  if parent_value is not null then
    select * into parent_row from public.accounting_accounts where id=parent_value for update;
    if not found then raise exception using errcode='23503',message='Parent account was not found'; end if;
    if not parent_row.is_active then raise exception using errcode='23514',message='Cannot move an account under an inactive parent'; end if;
    if parent_row.account_type<>type_value then raise exception using errcode='23514',message='Child account type must match its parent account type'; end if;
    if parent_row.is_posting and parent_row.id<>target_id then
      if exists(select 1 from public.accounting_journal_lines l where l.account_id=parent_row.id) then
        raise exception using errcode='23514',message='Parent account has journal activity; Owner must convert it to a group account before adding subaccounts';
      end if;
      update public.accounting_accounts set is_posting=false,updated_by=actor,updated_at=now() where id=parent_row.id;
    end if;
  end if;

  update public.accounting_accounts
  set account_code=code_value,name_ar=name_ar_value,name_en=name_en_value,parent_id=parent_value,
      account_type=type_value,normal_balance=normal_value,is_contra=contra_value,is_posting=posting_value,
      is_active=active_value,
      description=case when payload ? 'description' then nullif(btrim(payload->>'description'),'') else current_row.description end,
      updated_by=actor,updated_at=now()
  where id=target_id
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('accounting_accounts',saved.id::text,'accounting_account_updated',actor,
    to_jsonb(current_row),to_jsonb(saved),jsonb_build_object('account_code',saved.account_code));

  return to_jsonb(saved);
exception when unique_violation then
  raise exception using errcode='23505',message='Account code already exists';
end
$$;

create or replace function public.owner_convert_account_to_group(target_id uuid,reason text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  current_row public.accounting_accounts%rowtype;
  saved public.accounting_accounts%rowtype;
begin
  if actor is null or not public.is_current_profile_active() or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required';
  end if;
  if nullif(btrim(reason),'') is null then raise exception using errcode='22023',message='Conversion reason is required'; end if;

  select * into current_row from public.accounting_accounts where id=target_id for update;
  if not found then raise exception using errcode='P0002',message='Accounting account was not found'; end if;
  if not current_row.is_posting then return to_jsonb(current_row); end if;

  update public.accounting_accounts set is_posting=false,updated_by=actor,updated_at=now()
  where id=target_id returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values('accounting_accounts',saved.id::text,'accounting_account_converted_to_group',actor,
    to_jsonb(current_row),to_jsonb(saved),
    jsonb_build_object('reason',btrim(reason),'had_activity',
      exists(select 1 from public.accounting_journal_lines l where l.account_id=saved.id)));

  return to_jsonb(saved);
end
$$;

revoke all on function public.get_accounting_accounts() from public,anon;
revoke all on function public.create_accounting_account(jsonb) from public,anon;
revoke all on function public.update_accounting_account(uuid,jsonb) from public,anon;
revoke all on function public.owner_convert_account_to_group(uuid,text) from public,anon;

grant execute on function public.get_accounting_accounts() to authenticated;
grant execute on function public.create_accounting_account(jsonb) to authenticated;
grant execute on function public.update_accounting_account(uuid,jsonb) to authenticated;
grant execute on function public.owner_convert_account_to_group(uuid,text) to authenticated;
