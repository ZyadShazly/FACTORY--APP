-- Accounting mapping core.
-- Configurable source-to-account mapping foundation only.
-- This migration does not post any existing operational transaction to the GL.

create table public.accounting_mapping_definitions (
  mapping_key text primary key,
  label_ar text not null,
  label_en text,
  module text not null,
  expected_account_types text[] not null,
  suggested_account_code text,
  description text,
  required_for_auto_posting boolean not null default true,
  is_active boolean not null default true,
  sort_order integer not null default 100,
  created_at timestamptz not null default now(),
  constraint accounting_mapping_definitions_key_not_blank check (btrim(mapping_key)<>''),
  constraint accounting_mapping_definitions_label_not_blank check (btrim(label_ar)<>''),
  constraint accounting_mapping_definitions_module_not_blank check (btrim(module)<>''),
  constraint accounting_mapping_definitions_types_not_empty check (cardinality(expected_account_types)>0),
  constraint accounting_mapping_definitions_type_values check (
    expected_account_types <@ array['asset','liability','equity','revenue','cost_of_sales','expense']::text[]
  ),
  constraint accounting_mapping_definitions_suggested_code_not_blank check (
    suggested_account_code is null or btrim(suggested_account_code)<>''
  )
);

alter table public.accounting_mapping_definitions enable row level security;
revoke all on table public.accounting_mapping_definitions from anon,authenticated;

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,description,required_for_auto_posting,sort_order
) values
('default_cash_bank','الحساب الافتراضي للنقدية / البنك','Default Cash / Bank','cash',array['asset'],'1.1.02','الحساب المقابل الافتراضي للتحصيلات والمدفوعات إلى أن يدعم المصدر اختيار حساب بنكي محدد.',true,10),
('accounts_receivable','العملاء / الذمم المدينة','Accounts Receivable','sales',array['asset'],'1.1.03','حساب العملاء المستخدم عند إثبات المبيعات والتحصيلات.',true,20),
('customer_advances','دفعات مقدمة من العملاء','Customer Advances','cash',array['liability'],'2.1.05','التزام الدفعات المقدمة غير المخصصة للعملاء.',true,30),
('sales_revenue','إيرادات المبيعات','Sales Revenue','sales',array['revenue'],'4.1','حساب إيراد المبيعات.',true,40),
('cogs','تكلفة البضاعة المباعة','Cost of Goods Sold','sales',array['cost_of_sales'],'5.1','حساب تكلفة البضاعة المباعة عند خروج المنتج التام.',true,50),
('accounts_payable','الموردون / الذمم الدائنة','Accounts Payable','procurement',array['liability'],'2.1.01','حساب الموردين المستخدم في الفواتير والمدفوعات.',true,60),
('supplier_advances','دفعات مقدمة للموردين','Supplier Advances','cash',array['asset'],'1.1.06','أصل الدفعات المقدمة غير المخصصة للموردين.',true,70),
('inventory','المخزون','Inventory','inventory',array['asset'],'1.1.04','حساب المخزون الافتراضي للحركات المالية على المخزون.',true,80),
('grni','بضاعة مستلمة غير مفوترة','Goods Received Not Invoiced','procurement',array['liability'],'2.1.02','حساب وسيط للاستلام قبل اعتماد فاتورة المورد.',true,90),
('vat_input','ضريبة قيمة مضافة مدخلات','VAT Input','procurement',array['asset'],'1.1.07','حساب ضريبة المدخلات عندما يحتوي المصدر على ضريبة منفصلة.',true,100),
('rental_revenue','إيرادات الإيجار','Rental Revenue','rentals',array['revenue'],'4.2','حساب إيرادات الإيجارات.',true,110),
('expense_default','مصروف افتراضي','Default Expense','expenses',array['expense'],'6.9','حساب fallback للمصروفات التي لا يوجد لها ربط تصنيفي أدق.',true,120),
('payroll_expense','مصروف الرواتب','Payroll Expense','payroll',array['expense'],'6.1','مصروف الرواتب عند اعتماد المسير.',true,130),
('payroll_payable','رواتب مستحقة','Payroll Payable','payroll',array['liability'],'2.1.03','التزام الرواتب بين الاعتماد والدفع.',true,140),
('daily_labor_expense','مصروف العمالة اليومية','Daily Labor Expense','daily_labor',array['expense'],'6.2','مصروف العمالة اليومية عند الاعتماد.',true,150),
('daily_labor_payable','عمالة يومية مستحقة','Daily Labor Payable','daily_labor',array['liability'],'2.1.04','التزام العمالة اليومية قبل الدفع.',true,160),
('production_wip','إنتاج تحت التشغيل','Production WIP','production',array['asset'],null,'حساب WIP للإنتاج. لا يوجد حساب فرعي مفروض مسبقًا؛ أنشئه تحت الأصل المناسب ثم اربطه هنا.',true,170),
('opening_balance_equity','حقوق ملكية الأرصدة الافتتاحية','Opening Balance Equity','opening',array['equity'],'3.4','حساب موازنة الأرصدة الافتتاحية.',false,180),
('current_year_profit_loss','ربح / خسارة العام الحالي','Current Year Profit / Loss','reports',array['equity'],'3.3','حساب العرض المستخدم لربح أو خسارة الفترة المشتقة في قائمة المركز المالي.',false,190)
on conflict(mapping_key) do nothing;

create or replace function private.accounting_resolve_mapping(
  target_key text,
  target_scope_type text default 'global',
  target_scope_value text default ''
)
returns uuid
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  resolved uuid;
begin
  if nullif(btrim(target_key),'') is null then
    raise exception using errcode='22023',message='Accounting mapping key is required';
  end if;

  select m.account_id
  into resolved
  from public.accounting_account_mappings m
  join public.accounting_accounts a on a.id=m.account_id
  where lower(btrim(m.mapping_key))=lower(btrim(target_key))
    and m.is_active
    and a.is_active
    and a.is_posting
    and (
      (
        lower(btrim(m.scope_type))=lower(btrim(coalesce(nullif(target_scope_type,''),'global')))
        and lower(btrim(m.scope_value))=lower(btrim(coalesce(target_scope_value,'')))
      )
      or (
        lower(btrim(m.scope_type))='global'
        and btrim(m.scope_value)=''
      )
    )
  order by
    case
      when lower(btrim(m.scope_type))=lower(btrim(coalesce(nullif(target_scope_type,''),'global')))
       and lower(btrim(m.scope_value))=lower(btrim(coalesce(target_scope_value,'')))
      then 0 else 1
    end,
    m.updated_at desc
  limit 1;

  if resolved is null then
    raise exception using
      errcode='23514',
      message=format('Accounting mapping is missing or unavailable: %s',btrim(target_key));
  end if;

  return resolved;
end
$$;
revoke all on function private.accounting_resolve_mapping(text,text,text) from public,anon,authenticated;

create or replace function private.accounting_mapping_keys_ready(target_keys text[])
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(bool_and(exists(
    select 1
    from public.accounting_account_mappings m
    join public.accounting_accounts a on a.id=m.account_id
    where lower(btrim(m.mapping_key))=lower(btrim(k.key))
      and lower(btrim(m.scope_type))='global'
      and btrim(m.scope_value)=''
      and m.is_active
      and a.is_active
      and a.is_posting
  )),true)
  from unnest(coalesce(target_keys,'{}'::text[])) k(key)
$$;
revoke all on function private.accounting_mapping_keys_ready(text[]) from public,anon,authenticated;

create or replace function public.get_accounting_mapping_workspace()
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
    'definitions',coalesce(
      (
        select jsonb_agg(
          to_jsonb(d)
          || jsonb_build_object(
            'mapping',(
              select to_jsonb(m)
                || jsonb_build_object(
                  'account',jsonb_build_object(
                    'id',a.id,
                    'account_code',a.account_code,
                    'name_ar',a.name_ar,
                    'name_en',a.name_en,
                    'account_type',a.account_type,
                    'is_active',a.is_active,
                    'is_posting',a.is_posting
                  )
                )
              from public.accounting_account_mappings m
              join public.accounting_accounts a on a.id=m.account_id
              where lower(btrim(m.mapping_key))=lower(btrim(d.mapping_key))
                and lower(btrim(m.scope_type))='global'
                and btrim(m.scope_value)=''
                and m.is_active
              order by m.updated_at desc
              limit 1
            ),
            'configured',exists(
              select 1
              from public.accounting_account_mappings m
              join public.accounting_accounts a on a.id=m.account_id
              where lower(btrim(m.mapping_key))=lower(btrim(d.mapping_key))
                and lower(btrim(m.scope_type))='global'
                and btrim(m.scope_value)=''
                and m.is_active
                and a.is_active
                and a.is_posting
            ),
            'suggested_account',(
              select jsonb_build_object(
                'id',a.id,'account_code',a.account_code,'name_ar',a.name_ar,
                'account_type',a.account_type,'is_active',a.is_active,'is_posting',a.is_posting
              )
              from public.accounting_accounts a
              where d.suggested_account_code is not null
                and a.account_code=d.suggested_account_code
              limit 1
            )
          )
          order by d.sort_order,d.mapping_key
        )
        from public.accounting_mapping_definitions d
        where d.is_active
      ),
      '[]'::jsonb
    ),
    'auto_posting_readiness',coalesce(
      (
        select jsonb_object_agg(x.module,x.ready)
        from (
          select
            d.module,
            bool_and(
              not d.required_for_auto_posting
              or exists(
                select 1
                from public.accounting_account_mappings m
                join public.accounting_accounts a on a.id=m.account_id
                where lower(btrim(m.mapping_key))=lower(btrim(d.mapping_key))
                  and lower(btrim(m.scope_type))='global'
                  and btrim(m.scope_value)=''
                  and m.is_active
                  and a.is_active
                  and a.is_posting
              )
            ) as ready
          from public.accounting_mapping_definitions d
          where d.is_active
          group by d.module
        ) x
      ),
      '{}'::jsonb
    )
  )
  into result;

  return result;
end
$$;

create or replace function public.owner_set_accounting_mapping(
  target_key text,
  target_account uuid
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  definition_row public.accounting_mapping_definitions%rowtype;
  account_row public.accounting_accounts%rowtype;
  previous jsonb;
  saved public.accounting_account_mappings%rowtype;
begin
  if actor is null or not public.is_current_profile_active() or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required to configure accounting mappings';
  end if;

  select * into definition_row
  from public.accounting_mapping_definitions
  where lower(btrim(mapping_key))=lower(btrim(target_key))
    and is_active
  for share;

  if not found then
    raise exception using errcode='P0002',message='Accounting mapping definition was not found';
  end if;

  select * into account_row
  from public.accounting_accounts
  where id=target_account
  for update;

  if not found then
    raise exception using errcode='P0002',message='Accounting account was not found';
  end if;
  if not account_row.is_active or not account_row.is_posting then
    raise exception using errcode='23514',message='Accounting mapping requires an active posting account';
  end if;
  if not (account_row.account_type=any(definition_row.expected_account_types)) then
    raise exception using
      errcode='23514',
      message=format('Account type %s is not valid for mapping %s',account_row.account_type,definition_row.mapping_key);
  end if;

  select coalesce(jsonb_agg(to_jsonb(m)),'[]'::jsonb)
  into previous
  from public.accounting_account_mappings m
  where lower(btrim(m.mapping_key))=lower(btrim(definition_row.mapping_key))
    and lower(btrim(m.scope_type))='global'
    and btrim(m.scope_value)=''
    and m.is_active;

  update public.accounting_account_mappings
  set is_active=false,updated_by=actor,updated_at=now()
  where lower(btrim(mapping_key))=lower(btrim(definition_row.mapping_key))
    and lower(btrim(scope_type))='global'
    and btrim(scope_value)=''
    and is_active;

  insert into public.accounting_account_mappings(
    mapping_key,scope_type,scope_value,account_id,is_active,created_by,updated_by
  ) values(
    definition_row.mapping_key,'global','',account_row.id,true,actor,actor
  )
  returning * into saved;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_account_mappings',saved.id::text,'accounting_mapping_set',actor,
    previous,to_jsonb(saved),
    jsonb_build_object(
      'mapping_key',definition_row.mapping_key,
      'account_id',account_row.id,
      'account_code',account_row.account_code
    )
  );

  return to_jsonb(saved)||jsonb_build_object(
    'account',jsonb_build_object(
      'id',account_row.id,'account_code',account_row.account_code,
      'name_ar',account_row.name_ar,'account_type',account_row.account_type
    )
  );
end
$$;

create or replace function public.owner_clear_accounting_mapping(
  target_key text,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  key_value text;
  previous jsonb;
  changed integer:=0;
begin
  if actor is null or not public.is_current_profile_active() or public.current_identity_role()<>'owner' then
    raise exception using errcode='42501',message='Owner role required to configure accounting mappings';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception using errcode='22023',message='Mapping clear reason is required';
  end if;

  select mapping_key into key_value
  from public.accounting_mapping_definitions
  where lower(btrim(mapping_key))=lower(btrim(target_key))
    and is_active;

  if key_value is null then
    raise exception using errcode='P0002',message='Accounting mapping definition was not found';
  end if;

  select coalesce(jsonb_agg(to_jsonb(m)),'[]'::jsonb)
  into previous
  from public.accounting_account_mappings m
  where lower(btrim(m.mapping_key))=lower(btrim(key_value))
    and lower(btrim(m.scope_type))='global'
    and btrim(m.scope_value)=''
    and m.is_active;

  update public.accounting_account_mappings
  set is_active=false,updated_by=actor,updated_at=now()
  where lower(btrim(mapping_key))=lower(btrim(key_value))
    and lower(btrim(scope_type))='global'
    and btrim(scope_value)=''
    and is_active;
  get diagnostics changed=row_count;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'accounting_account_mappings',key_value,'accounting_mapping_cleared',actor,
    previous,jsonb_build_object('active',false),
    jsonb_build_object('mapping_key',key_value,'reason',btrim(reason),'changed_rows',changed)
  );

  return jsonb_build_object('ok',true,'mapping_key',key_value,'changed_rows',changed);
end
$$;

revoke all on function public.get_accounting_mapping_workspace() from public,anon;
revoke all on function public.owner_set_accounting_mapping(text,uuid) from public,anon;
revoke all on function public.owner_clear_accounting_mapping(text,text) from public,anon;

grant execute on function public.get_accounting_mapping_workspace() to authenticated;
grant execute on function public.owner_set_accounting_mapping(text,uuid) to authenticated;
grant execute on function public.owner_clear_accounting_mapping(text,text) to authenticated;
