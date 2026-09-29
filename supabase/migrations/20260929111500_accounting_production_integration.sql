-- NextEP accounting integration: production material issues and production completion.
-- Production-linked project inventory issues are classified as Production WIP, not generic project material cost.
-- Existing historical production rows are not backfilled.
-- Completed production is currently operationally immutable; no artificial completion-reversal path is introduced here.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,
  description,required_for_auto_posting,sort_order
) values
(
  'production_labor_clearing',
  'مقاصة تكلفة عمالة الإنتاج',
  'Production Labor Clearing',
  'production',
  array['liability','expense','cost_of_sales']::text[],
  null,
  'الحساب الدائن عند تحميل تكلفة العمالة القياسية/المثبتة على الإنتاج تحت التشغيل لحظة إتمام الإنتاج.',
  true,
  171
),
(
  'production_overhead_clearing',
  'مقاصة التكاليف غير المباشرة للإنتاج',
  'Production Overhead Clearing',
  'production',
  array['liability','expense','cost_of_sales']::text[],
  null,
  'الحساب الدائن عند تحميل التكاليف غير المباشرة المثبتة على الإنتاج تحت التشغيل لحظة إتمام الإنتاج.',
  true,
  172
),
(
  'production_cost_variance',
  'فروق إقفال تكلفة الإنتاج',
  'Production Cost Variance',
  'production',
  array['expense','cost_of_sales','revenue','equity']::text[],
  null,
  'فرق التقريب أو فرق التعديل اليدوي بين رصيد WIP الحالي وقيمة استلام المنتج التام.',
  true,
  173
)
on conflict(mapping_key) do nothing;

-- Preserve the existing operational function as the implementation core.
alter function public.issue_production_material(uuid,numeric,text)
  rename to issue_production_material_core;

revoke all on function public.issue_production_material_core(uuid,numeric,text)
  from public,anon,authenticated;

-- Public wrapper keeps the exact existing API signature while marking nested
-- project_issue movements as production-originated for the accounting boundary.
create or replace function public.issue_production_material(
  target_requirement uuid,
  issue_quantity numeric,
  issue_description text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  result jsonb;
begin
  perform set_config('app.accounting_production_material_issue','on',true);

  result:=public.issue_production_material_core(
    target_requirement,
    issue_quantity,
    issue_description
  );

  perform set_config('app.accounting_production_material_issue','off',true);
  return result;
exception
  when others then
    perform set_config('app.accounting_production_material_issue','off',true);
    raise;
end
$$;

revoke all on function public.issue_production_material(uuid,numeric,text)
  from public,anon;
grant execute on function public.issue_production_material(uuid,numeric,text)
  to authenticated;

-- Recreate only the trigger contract, not the Inventory GL implementation.
-- Generic project issues still post through Inventory; project_issue rows created
-- inside issue_production_material are skipped and later posted once from
-- production_material_issues.
drop trigger accounting_inventory_gl on public.inventory_movements;
create trigger accounting_inventory_gl
after insert on public.inventory_movements
for each row
when (
  new.movement_type<>'project_issue'
  or coalesce(
    pg_catalog.current_setting('app.accounting_production_material_issue',true),
    'off'
  )<>'on'
)
execute function private.accounting_inventory_gl_trigger();

create or replace function private.accounting_production_material_issue_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.issued_by);
  requirement public.production_material_requirements%rowtype;
  production_order public.production_orders%rowtype;
  movement public.inventory_movements%rowtype;
  event_date date;
  wip_account uuid;
  inventory_account uuid;
  amount_base numeric(18,2);
  reference_value text;
begin
  select * into requirement
  from public.production_material_requirements
  where id=new.requirement_id;

  if not found then
    raise exception using errcode='23503',message='Production material requirement was not found';
  end if;

  select * into production_order
  from public.production_orders
  where id=requirement.production_order_id;

  if not found then
    raise exception using errcode='23503',message='Production order was not found for material issue';
  end if;

  select * into movement
  from public.inventory_movements
  where id=new.inventory_movement_id;

  if not found then
    raise exception using errcode='23503',message='Inventory movement was not found for production material issue';
  end if;

  event_date:=coalesce(new.issued_at::date,movement.posted_at::date,current_date);

  if not private.accounting_source_event_in_scope(event_date) then
    return new;
  end if;

  amount_base:=round(abs(coalesce(movement.quantity_delta,0))*coalesce(movement.unit_cost,0),2);

  if amount_base<0 then
    raise exception using errcode='23514',message='Negative production material issue value is not allowed';
  end if;

  if amount_base=0 then
    return new;
  end if;

  wip_account:=private.accounting_resolve_mapping('production_wip','global','');
  inventory_account:=private.accounting_resolve_mapping('inventory','global','');
  reference_value:=coalesce(
    movement.movement_number,
    'production_issue:'||new.id::text
  );

  perform private.accounting_post_source_journal(
    'production',
    'production_material_issue_posted',
    new.id::text,
    event_date,
    'صرف خامات للإنتاج — '||new.id::text,
    reference_value,
    production_order.project_id,
    jsonb_build_array(
      jsonb_build_object(
        'account_id',wip_account,
        'debit',amount_base,
        'credit',0,
        'description',coalesce(nullif(btrim(new.description),''),'صرف خامات للإنتاج'),
        'project_id',production_order.project_id,
        'source_line_id','production_wip',
        'reference',reference_value
      ),
      jsonb_build_object(
        'account_id',inventory_account,
        'debit',0,
        'credit',amount_base,
        'description','خروج مخزون إلى الإنتاج',
        'project_id',production_order.project_id,
        'source_line_id','inventory',
        'reference',reference_value
      )
    ),
    actor
  );

  return new;
end
$$;
revoke all on function private.accounting_production_material_issue_gl_trigger()
  from public,anon,authenticated;

create or replace function private.accounting_production_issue_reversal_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.posted_by);
  issue_id uuid;
  event_date date:=coalesce(new.posted_at::date,current_date);
begin
  if new.movement_type not in ('production_issue_reversal','project_issue_reversal')
     or new.reversed_movement_id is null then
    return new;
  end if;

  select issue.id
  into issue_id
  from public.production_material_issues issue
  where issue.inventory_movement_id=new.reversed_movement_id
  order by issue.issued_at desc
  limit 1;

  if issue_id is null then
    return new;
  end if;

  perform private.accounting_reverse_source_journal(
    'production',
    'production_material_issue_posted',
    issue_id::text,
    event_date,
    coalesce(nullif(btrim(new.reason),''),'عكس صرف خامات للإنتاج'),
    actor
  );

  return new;
end
$$;
revoke all on function private.accounting_production_issue_reversal_gl_trigger()
  from public,anon,authenticated;

create or replace function private.accounting_production_receipt_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.posted_by);
  production_order public.production_orders%rowtype;
  event_date date:=coalesce(new.posted_at::date,current_date);
  wip_account uuid;
  inventory_account uuid;
  labor_clearing_account uuid;
  overhead_clearing_account uuid;
  variance_account uuid;
  labor_base numeric(18,2);
  overhead_base numeric(18,2);
  absorption_base numeric(18,2);
  material_wip_base numeric(18,2);
  expected_wip_base numeric(18,2);
  receipt_base numeric(18,2);
  variance_base numeric(18,2);
  reference_value text;
  absorption_lines jsonb:='[]'::jsonb;
  completion_lines jsonb:='[]'::jsonb;
begin
  if new.movement_type<>'production_receipt'
     or new.production_order_id is null then
    return new;
  end if;

  if not private.accounting_source_event_in_scope(event_date) then
    return new;
  end if;

  select * into production_order
  from public.production_orders
  where id=new.production_order_id;

  if not found then
    raise exception using errcode='23503',message='Production order was not found for finished-goods receipt';
  end if;

  wip_account:=private.accounting_resolve_mapping('production_wip','global','');
  inventory_account:=private.accounting_resolve_mapping('inventory','global','');

  labor_base:=round(coalesce(production_order.labor_cost,0),2);
  overhead_base:=round(coalesce(production_order.overhead_cost,0),2);

  if labor_base<0 or overhead_base<0 then
    raise exception using errcode='23514',message='Negative production labor or overhead cost is not allowed';
  end if;

  absorption_base:=labor_base+overhead_base;

  select coalesce(sum(line.debit-line.credit),0)::numeric(18,2)
  into material_wip_base
  from public.production_material_issues issue
  join public.production_material_requirements requirement
    on requirement.id=issue.requirement_id
  join public.accounting_source_links source_link
    on lower(btrim(source_link.source_module))='production'
   and lower(btrim(source_link.source_event))='production_material_issue_posted'
   and source_link.source_record_id=issue.id::text
   and source_link.source_line_id is null
   and source_link.source_revision=1
   and source_link.link_status='active'
  join public.accounting_journal_entries journal
    on journal.id=source_link.journal_entry_id
   and journal.status='posted'
  join public.accounting_journal_lines line
    on line.journal_entry_id=journal.id
   and line.account_id=wip_account
  where requirement.production_order_id=new.production_order_id;

  expected_wip_base:=round(material_wip_base+absorption_base,2);
  receipt_base:=round(abs(coalesce(new.quantity_delta,0))*coalesce(new.unit_cost,0),2);

  if material_wip_base<0 or expected_wip_base<0 then
    raise exception using errcode='23514',message='Production WIP balance cannot be negative at completion';
  end if;
  if receipt_base<=0 then
    raise exception using errcode='23514',message='Positive finished-goods receipt value is required for accounting posting';
  end if;

  reference_value:=coalesce(
    new.movement_number,
    'production_receipt:'||new.id::text
  );

  if absorption_base>0 then
    absorption_lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',wip_account,
        'debit',absorption_base,
        'credit',0,
        'description','تحميل عمالة وتكاليف غير مباشرة على الإنتاج تحت التشغيل',
        'project_id',production_order.project_id,
        'source_line_id','production_wip_absorption',
        'reference',reference_value
      )
    );

    if labor_base>0 then
      labor_clearing_account:=private.accounting_resolve_mapping(
        'production_labor_clearing','global',''
      );
      absorption_lines:=absorption_lines||jsonb_build_array(jsonb_build_object(
        'account_id',labor_clearing_account,
        'debit',0,
        'credit',labor_base,
        'description','مقاصة عمالة الإنتاج',
        'project_id',production_order.project_id,
        'source_line_id','labor_clearing',
        'reference',reference_value
      ));
    end if;

    if overhead_base>0 then
      overhead_clearing_account:=private.accounting_resolve_mapping(
        'production_overhead_clearing','global',''
      );
      absorption_lines:=absorption_lines||jsonb_build_array(jsonb_build_object(
        'account_id',overhead_clearing_account,
        'debit',0,
        'credit',overhead_base,
        'description','مقاصة التكاليف غير المباشرة للإنتاج',
        'project_id',production_order.project_id,
        'source_line_id','overhead_clearing',
        'reference',reference_value
      ));
    end if;

    perform private.accounting_post_source_journal(
      'production',
      'production_labor_overhead_absorbed',
      new.id::text,
      event_date,
      'تحميل تكاليف الإنتاج — '||new.production_order_id::text,
      reference_value,
      production_order.project_id,
      absorption_lines,
      actor
    );
  end if;

  variance_base:=round(receipt_base-expected_wip_base,2);

  completion_lines:=jsonb_build_array(jsonb_build_object(
    'account_id',inventory_account,
    'debit',receipt_base,
    'credit',0,
    'description','استلام منتج تام من الإنتاج',
    'project_id',production_order.project_id,
    'source_line_id','finished_goods_inventory',
    'reference',reference_value
  ));

  if expected_wip_base>0 then
    completion_lines:=completion_lines||jsonb_build_array(jsonb_build_object(
      'account_id',wip_account,
      'debit',0,
      'credit',expected_wip_base,
      'description','إقفال الإنتاج تحت التشغيل',
      'project_id',production_order.project_id,
      'source_line_id','production_wip_close',
      'reference',reference_value
    ));
  end if;

  if variance_base<>0 then
    variance_account:=private.accounting_resolve_mapping(
      'production_cost_variance','global',''
    );
    completion_lines:=completion_lines||jsonb_build_array(jsonb_build_object(
      'account_id',variance_account,
      'debit',case when variance_base<0 then abs(variance_base) else 0 end,
      'credit',case when variance_base>0 then variance_base else 0 end,
      'description','فرق إقفال تكلفة الإنتاج',
      'project_id',production_order.project_id,
      'source_line_id','production_cost_variance',
      'reference',reference_value
    ));
  end if;

  perform private.accounting_post_source_journal(
    'production',
    'production_completion_posted',
    new.id::text,
    event_date,
    'إتمام إنتاج — '||new.production_order_id::text,
    reference_value,
    production_order.project_id,
    completion_lines,
    actor
  );

  return new;
end
$$;
revoke all on function private.accounting_production_receipt_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_production_material_issue_gl
after insert on public.production_material_issues
for each row execute function private.accounting_production_material_issue_gl_trigger();

create trigger accounting_production_issue_reversal_gl
after insert on public.inventory_movements
for each row execute function private.accounting_production_issue_reversal_gl_trigger();

-- Prefix with zz_ so existing production receipt normalization/synchronization triggers
-- run first for the same AFTER INSERT event.
create trigger zz_accounting_production_receipt_gl
after insert on public.inventory_movements
for each row
when (new.movement_type='production_receipt')
execute function private.accounting_production_receipt_gl_trigger();
