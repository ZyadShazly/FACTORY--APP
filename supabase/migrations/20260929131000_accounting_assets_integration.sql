-- NextEP accounting integration: financially valued Asset settlement and maintenance events.
-- Asset registry creation, assignments, returns and quantity-only adjustments remain operational only.
-- assets.purchase_cost is registry/master data and never creates an automatic historical accounting entry.
-- Existing historical Asset records are not backfilled.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,
  description,required_for_auto_posting,sort_order
) values
(
  'asset_control',
  'حساب رقابة الأصول',
  'Asset Control',
  'assets',
  array['asset']::text[],
  null,
  'حساب الأصل الذي تنخفض قيمته عند اعتماد تسوية خسارة مالية. لا يتم إنشاء حساب فرعي تلقائيًا؛ يختار الـOwner حساب الحركة المناسب من شجرة الحسابات.',
  true,
  200
),
(
  'asset_loss_expense',
  'خسائر وتسويات الأصول',
  'Asset Loss Expense',
  'assets',
  array['expense','cost_of_sales']::text[],
  '6.9',
  'الحساب المدين عند اعتماد تسوية أصل تحمل قيمة خسارة مالية.',
  true,
  201
),
(
  'asset_maintenance_expense',
  'مصروف صيانة الأصول',
  'Asset Maintenance Expense',
  'assets',
  array['expense']::text[],
  '6.7',
  'الحساب المدين بتكلفة الصيانة الفعلية عند اكتمال أمر الصيانة.',
  true,
  202
),
(
  'asset_maintenance_credit',
  'مقابل تكلفة صيانة الأصول',
  'Asset Maintenance Credit',
  'assets',
  array['liability','asset']::text[],
  null,
  'الحساب الدائن مقابل تكلفة الصيانة الفعلية. يختار الـOwner التزامًا أو بنك/نقدية وفق السياسة لأن مصدر الصيانة الحالي لا يحدد حالة السداد.',
  true,
  203
)
on conflict(mapping_key) do nothing;

create or replace function private.accounting_asset_settlement_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.approved_by,new.created_by);
  event_date date:=coalesce(new.approved_at::date,current_date);
  assignment_item public.asset_assignment_items%rowtype;
  assignment_row public.asset_assignments%rowtype;
  asset_row public.assets%rowtype;
  loss_account uuid;
  asset_account uuid;
  amount_base numeric(18,2);
  reference_value text;
begin
  if old.status<>'approved'
     and new.status='approved'
     and old.status is distinct from new.status then

    amount_base:=round(coalesce(new.estimated_loss,0),2);

    if amount_base<0 then
      raise exception using errcode='23514',
        message='Negative approved asset loss is not allowed';
    end if;

    -- Approval without a financial value is still an operational settlement only.
    if amount_base=0 then
      return new;
    end if;

    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    select * into assignment_item
    from public.asset_assignment_items
    where id=new.assignment_item_id;

    if not found then
      raise exception using errcode='23503',
        message='Asset assignment item was not found for accounting settlement';
    end if;

    select * into assignment_row
    from public.asset_assignments
    where id=assignment_item.assignment_id;

    if not found then
      raise exception using errcode='23503',
        message='Asset assignment was not found for accounting settlement';
    end if;

    select * into asset_row
    from public.assets
    where id=assignment_item.asset_id;

    if not found then
      raise exception using errcode='23503',
        message='Asset was not found for accounting settlement';
    end if;

    loss_account:=private.accounting_resolve_mapping(
      'asset_loss_expense','global',''
    );
    asset_account:=private.accounting_resolve_mapping(
      'asset_control','global',''
    );
    reference_value:='asset_settlement:'||new.id::text;

    perform private.accounting_post_source_journal(
      'assets',
      'asset_loss_settlement_posted',
      new.id::text,
      event_date,
      'خسارة أصل معتمدة — '||asset_row.asset_code,
      reference_value,
      assignment_row.project_id,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',loss_account,
          'debit',amount_base,
          'credit',0,
          'description',coalesce(nullif(btrim(new.reason),''),'خسارة أصل معتمدة'),
          'project_id',assignment_row.project_id,
          'source_line_id','asset_loss_expense',
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',asset_account,
          'debit',0,
          'credit',amount_base,
          'description','تخفيض قيمة أصل — '||asset_row.asset_code,
          'project_id',assignment_row.project_id,
          'source_line_id','asset_control',
          'reference',reference_value
        )
      ),
      actor
    );

    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_asset_settlement_gl_trigger()
  from public,anon,authenticated;

create or replace function private.accounting_asset_maintenance_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.completed_by,new.created_by);
  event_date date:=coalesce(new.completed_at::date,current_date);
  asset_row public.assets%rowtype;
  maintenance_expense_account uuid;
  maintenance_credit_account uuid;
  amount_base numeric(18,2);
  reference_value text;
begin
  if old.status='open'
     and new.status='completed'
     and old.status is distinct from new.status then

    amount_base:=round(coalesce(new.actual_cost,0),2);

    if amount_base<0 then
      raise exception using errcode='23514',
        message='Negative asset maintenance cost is not allowed';
    end if;

    -- Zero-cost maintenance completion has no financial value.
    if amount_base=0 then
      return new;
    end if;

    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    select * into asset_row
    from public.assets
    where id=new.asset_id;

    if not found then
      raise exception using errcode='23503',
        message='Asset was not found for accounting maintenance';
    end if;

    maintenance_expense_account:=private.accounting_resolve_mapping(
      'asset_maintenance_expense','global',''
    );
    maintenance_credit_account:=private.accounting_resolve_mapping(
      'asset_maintenance_credit','global',''
    );
    reference_value:=coalesce(
      nullif(btrim(new.maintenance_code),''),
      'asset_maintenance:'||new.id::text
    );

    perform private.accounting_post_source_journal(
      'assets',
      'asset_maintenance_cost_posted',
      new.id::text,
      event_date,
      'صيانة أصل — '||asset_row.asset_code,
      reference_value,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',maintenance_expense_account,
          'debit',amount_base,
          'credit',0,
          'description','تكلفة صيانة فعلية — '||asset_row.asset_code,
          'source_line_id','asset_maintenance_expense',
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',maintenance_credit_account,
          'debit',0,
          'credit',amount_base,
          'description','مقابل تكلفة صيانة — '||asset_row.asset_code,
          'source_line_id','asset_maintenance_credit',
          'reference',reference_value
        )
      ),
      actor
    );

    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_asset_maintenance_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_asset_settlement_gl
after update of status on public.asset_settlements
for each row execute function private.accounting_asset_settlement_gl_trigger();

create trigger accounting_asset_maintenance_gl
after update of status on public.asset_maintenance_orders
for each row execute function private.accounting_asset_maintenance_gl_trigger();
