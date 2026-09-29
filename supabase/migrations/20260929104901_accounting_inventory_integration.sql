-- NextEP accounting integration: project inventory issues and inventory adjustments.
-- Production-specific inventory movements remain reserved for the Production accounting integration.
-- Existing historical inventory movements are not backfilled.

insert into public.accounting_mapping_definitions(
  mapping_key,label_ar,label_en,module,expected_account_types,suggested_account_code,
  description,required_for_auto_posting,sort_order
) values
(
  'project_material_cost',
  'تكلفة مواد المشروع',
  'Project Material Cost',
  'inventory',
  array['cost_of_sales','expense','asset']::text[],
  null,
  'الحساب المدين عند صرف مخزون مباشرة إلى مشروع خارج مسار أوامر الإنتاج. يمكن ربطه بتكلفة مبيعات أو مصروف أو WIP/أصل حسب سياسة الشركة.',
  true,
  82
),
(
  'inventory_adjustment_gain',
  'مكاسب تسوية المخزون',
  'Inventory Adjustment Gain',
  'inventory',
  array['revenue','equity']::text[],
  '4.3',
  'الحساب الدائن عند زيادة قيمة المخزون نتيجة تسوية أو جرد موجب.',
  true,
  83
),
(
  'inventory_adjustment_loss',
  'خسائر تسوية المخزون',
  'Inventory Adjustment Loss',
  'inventory',
  array['expense','cost_of_sales']::text[],
  '6.9',
  'الحساب المدين عند نقص قيمة المخزون نتيجة تسوية أو جرد سالب.',
  true,
  84
)
on conflict(mapping_key) do nothing;

create or replace function private.accounting_inventory_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.posted_by);
  event_date date:=coalesce(new.posted_at::date,current_date);
  inventory_account uuid;
  project_cost_account uuid;
  adjustment_gain_account uuid;
  adjustment_loss_account uuid;
  amount_base numeric(18,2);
  reference_value text;
begin
  if new.movement_type='project_issue'
     and new.project_id is not null then

    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    amount_base:=round(abs(coalesce(new.quantity_delta,0))*coalesce(new.unit_cost,0),2);

    if amount_base<0 then
      raise exception using errcode='23514',message='Negative project inventory issue value is not allowed';
    end if;

    if amount_base=0 then
      return new;
    end if;

    inventory_account:=private.accounting_resolve_mapping('inventory','global','');
    project_cost_account:=private.accounting_resolve_mapping('project_material_cost','global','');
    reference_value:=coalesce(new.movement_number,'project_issue:'||new.id::text);

    perform private.accounting_post_source_journal(
      'inventory',
      'project_inventory_issue_posted',
      new.id::text,
      event_date,
      'صرف مخزون لمشروع — '||new.id::text,
      reference_value,
      new.project_id,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',project_cost_account,
          'debit',amount_base,
          'credit',0,
          'description',coalesce(nullif(btrim(new.reason),''),'تكلفة مواد مشروع'),
          'project_id',new.project_id,
          'source_line_id','project_material_cost',
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',inventory_account,
          'debit',0,
          'credit',amount_base,
          'description','خروج مخزون إلى مشروع',
          'project_id',new.project_id,
          'source_line_id','inventory',
          'reference',reference_value
        )
      ),
      actor
    );

    return new;
  end if;

  if new.movement_type='project_issue_reversal'
     and new.reversed_movement_id is not null then

    perform private.accounting_reverse_source_journal(
      'inventory',
      'project_inventory_issue_posted',
      new.reversed_movement_id::text,
      event_date,
      coalesce(nullif(btrim(new.reason),''),'عكس صرف مخزون لمشروع'),
      actor
    );

    return new;
  end if;

  if new.movement_type in ('adjustment_in','adjustment_out') then
    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    amount_base:=round(abs(coalesce(new.quantity_delta,0))*coalesce(new.unit_cost,0),2);

    if amount_base<0 then
      raise exception using errcode='23514',message='Negative inventory adjustment value is not allowed';
    end if;

    if amount_base=0 then
      return new;
    end if;

    inventory_account:=private.accounting_resolve_mapping('inventory','global','');
    reference_value:=coalesce(new.movement_number,'inventory_adjustment:'||new.id::text);

    if new.movement_type='adjustment_in' then
      adjustment_gain_account:=private.accounting_resolve_mapping('inventory_adjustment_gain','global','');

      perform private.accounting_post_source_journal(
        'inventory',
        'inventory_adjustment_in_posted',
        new.id::text,
        event_date,
        'زيادة تسوية مخزون — '||new.id::text,
        reference_value,
        new.project_id,
        jsonb_build_array(
          jsonb_build_object(
            'account_id',inventory_account,
            'debit',amount_base,
            'credit',0,
            'description',coalesce(nullif(btrim(new.reason),''),'زيادة مخزون'),
            'project_id',new.project_id,
            'source_line_id','inventory',
            'reference',reference_value
          ),
          jsonb_build_object(
            'account_id',adjustment_gain_account,
            'debit',0,
            'credit',amount_base,
            'description','مكسب تسوية مخزون',
            'project_id',new.project_id,
            'source_line_id','adjustment_gain',
            'reference',reference_value
          )
        ),
        actor
      );
    else
      adjustment_loss_account:=private.accounting_resolve_mapping('inventory_adjustment_loss','global','');

      perform private.accounting_post_source_journal(
        'inventory',
        'inventory_adjustment_out_posted',
        new.id::text,
        event_date,
        'نقص تسوية مخزون — '||new.id::text,
        reference_value,
        new.project_id,
        jsonb_build_array(
          jsonb_build_object(
            'account_id',adjustment_loss_account,
            'debit',amount_base,
            'credit',0,
            'description','خسارة تسوية مخزون',
            'project_id',new.project_id,
            'source_line_id','adjustment_loss',
            'reference',reference_value
          ),
          jsonb_build_object(
            'account_id',inventory_account,
            'debit',0,
            'credit',amount_base,
            'description',coalesce(nullif(btrim(new.reason),''),'نقص مخزون'),
            'project_id',new.project_id,
            'source_line_id','inventory',
            'reference',reference_value
          )
        ),
        actor
      );
    end if;

    return new;
  end if;

  -- Transfers are quantity/location movements only while inventory uses one global control account.
  -- Production movements are intentionally ignored here and will be handled by the Production integration.
  return new;
end
$$;
revoke all on function private.accounting_inventory_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_inventory_gl
after insert on public.inventory_movements
for each row execute function private.accounting_inventory_gl_trigger();
