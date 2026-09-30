-- Accounting audit drill-down from journal to canonical operational source.
-- Read-only, permission-checked, and limited to the explicit Integration Matrix sources.

create or replace function public.get_accounting_source_trace(target_journal uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  requested public.accounting_journal_entries%rowtype;
  source_journal public.accounting_journal_entries%rowtype;
  source_table text;
  source_uuid uuid;
  source_record jsonb;
begin
  if not private.accounting_permission_allowed('accounting_view') then
    raise exception using errcode='42501',message='Accounting view permission required';
  end if;

  select * into requested
  from public.accounting_journal_entries
  where id=target_journal;

  if not found then
    raise exception using errcode='P0002',message='Accounting journal was not found';
  end if;

  source_journal:=requested;

  if requested.reversal_of_entry_id is not null then
    select * into source_journal
    from public.accounting_journal_entries
    where id=requested.reversal_of_entry_id;

    if not found then
      raise exception using errcode='P0002',message='Original journal for reversal was not found';
    end if;
  end if;

  if source_journal.source_record_id is null
     or source_journal.source_event is null
     or source_journal.source_module is null then
    return jsonb_build_object(
      'available',false,
      'journal_id',requested.id,
      'entry_number',requested.entry_number,
      'entry_origin',requested.entry_origin,
      'reason','Journal has no operational source'
    );
  end if;

  source_table:=case
    when source_journal.source_module='assets'
      and source_journal.source_event='asset_loss_settlement_posted'
      then 'asset_settlements'
    when source_journal.source_module='assets'
      and source_journal.source_event='asset_maintenance_cost_posted'
      then 'asset_maintenance_orders'
    when source_journal.source_module='customers'
      and source_journal.source_event='customer_adjustment_posted'
      then 'customer_adjustments'
    when source_journal.source_module='customers'
      and source_journal.source_event='customer_advance_allocated'
      then 'customer_advance_allocations'
    when source_journal.source_module='customers'
      and source_journal.source_event='customer_receipt_classified'
      then 'customer_receipts'
    when source_journal.source_module='daily_labor'
      and source_journal.source_event in ('daily_labor_accrual_posted','daily_labor_payment_posted')
      then 'daily_labor'
    when source_journal.source_module='expenses'
      and source_journal.source_event='expense_posted'
      then 'expenses'
    when source_journal.source_module='inventory'
      and source_journal.source_event in (
        'project_inventory_issue_posted',
        'inventory_adjustment_in_posted',
        'inventory_adjustment_out_posted'
      )
      then 'inventory_movements'
    when source_journal.source_module='payroll'
      and source_journal.source_event in ('payroll_accrual_posted','payroll_payment_posted')
      then 'payroll'
    when source_journal.source_module='procurement'
      and source_journal.source_event='goods_receipt_inventory_posted'
      then 'inventory_movements'
    when source_journal.source_module='procurement'
      and source_journal.source_event='supplier_invoice_approved'
      then 'supplier_invoices'
    when source_journal.source_module='production'
      and source_journal.source_event='production_material_issue_posted'
      then 'production_material_issues'
    when source_journal.source_module='production'
      and source_journal.source_event in (
        'production_completion_posted',
        'production_labor_overhead_absorbed'
      )
      then 'inventory_movements'
    when source_journal.source_module='rentals'
      and source_journal.source_event='rental_customer_charge_posted'
      then 'rentals'
    when source_journal.source_module='sales'
      and source_journal.source_event='sale_customer_charge_posted'
      then 'sales'
    when source_journal.source_module='sales'
      and source_journal.source_event='sale_inventory_issue_posted'
      then 'inventory_movements'
    when source_journal.source_module='suppliers'
      and source_journal.source_event='supplier_payment_classified'
      then 'supplier_payments'
    when source_journal.source_module='suppliers'
      and source_journal.source_event='supplier_advance_allocated'
      then 'supplier_advance_allocations'
    else null
  end;

  if source_table is null then
    return jsonb_build_object(
      'available',false,
      'journal_id',requested.id,
      'entry_number',requested.entry_number,
      'source_journal_id',source_journal.id,
      'source_module',source_journal.source_module,
      'source_event',source_journal.source_event,
      'source_record_id',source_journal.source_record_id,
      'reason','Operational source type is not registered for drill-down'
    );
  end if;

  begin
    source_uuid:=source_journal.source_record_id::uuid;
  exception when invalid_text_representation then
    return jsonb_build_object(
      'available',false,
      'journal_id',requested.id,
      'entry_number',requested.entry_number,
      'source_journal_id',source_journal.id,
      'source_module',source_journal.source_module,
      'source_event',source_journal.source_event,
      'source_record_id',source_journal.source_record_id,
      'source_table',source_table,
      'reason','Operational source identifier is not a UUID'
    );
  end;

  execute format(
    'select to_jsonb(src) from public.%I src where src.id=$1',
    source_table
  )
  into source_record
  using source_uuid;

  return jsonb_build_object(
    'available',source_record is not null,
    'journal_id',requested.id,
    'entry_number',requested.entry_number,
    'journal_is_reversal',requested.reversal_of_entry_id is not null,
    'source_journal_id',source_journal.id,
    'source_module',source_journal.source_module,
    'source_event',source_journal.source_event,
    'source_record_id',source_journal.source_record_id,
    'source_table',source_table,
    'record_found',source_record is not null,
    'record',coalesce(source_record,'{}'::jsonb),
    'reason',case when source_record is null then 'Operational source record was not found' else null end
  );
end
$$;

revoke all on function public.get_accounting_source_trace(uuid) from public,anon;
grant execute on function public.get_accounting_source_trace(uuid) to authenticated;
