-- NextEP accounting integration: classified cash, commercial advances, and source-driven reversals.
-- Additive to the operational model. Existing historical rows are not backfilled.

create or replace function private.accounting_source_event_in_scope(target_date date)
returns boolean
language sql
stable
security definer
set search_path=''
as $$
  select coalesce(
    (
      select s.enabled
         and s.activation_date is not null
         and coalesce(target_date,current_date)>=s.activation_date
      from public.accounting_settings s
      where s.id=true
    ),
    false
  )
$$;
revoke all on function private.accounting_source_event_in_scope(date) from public,anon,authenticated;

create or replace function private.accounting_post_source_journal(
  target_module text,
  target_event text,
  target_record_id text,
  target_date date,
  target_description text,
  target_reference text,
  target_project uuid,
  target_lines jsonb,
  actor uuid
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  existing_entry uuid;
  saved public.accounting_journal_entries%rowtype;
  lock_key text;
begin
  if actor is null then
    raise exception using errcode='42501',message='Authenticated actor required for accounting auto-posting';
  end if;
  if nullif(btrim(target_module),'') is null
     or nullif(btrim(target_event),'') is null
     or nullif(btrim(target_record_id),'') is null then
    raise exception using errcode='22023',message='Accounting source identity is required';
  end if;
  if nullif(btrim(target_description),'') is null then
    raise exception using errcode='22023',message='Accounting journal description is required';
  end if;
  if target_date is null then
    raise exception using errcode='22023',message='Accounting source date is required';
  end if;

  lock_key:=lower(btrim(target_module))||':'||lower(btrim(target_event))||':'||btrim(target_record_id)||':1';
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(lock_key,0));

  select l.journal_entry_id
  into existing_entry
  from public.accounting_source_links l
  where lower(btrim(l.source_module))=lower(btrim(target_module))
    and lower(btrim(l.source_event))=lower(btrim(target_event))
    and l.source_record_id=btrim(target_record_id)
    and l.source_line_id is null
    and l.source_revision=1
  order by l.created_at desc
  limit 1;

  if existing_entry is not null then
    return existing_entry;
  end if;

  perform private.accounting_assert_date_open(target_date);

  insert into public.accounting_journal_entries(
    entry_number,entry_date,reference,description,status,entry_origin,
    source_module,source_event,source_record_id,source_revision,project_id,
    created_by
  ) values(
    private.next_accounting_entry_number('system',target_date),
    target_date,
    nullif(btrim(target_reference),''),
    btrim(target_description),
    'draft',
    'system',
    btrim(target_module),
    btrim(target_event),
    btrim(target_record_id),
    1,
    target_project,
    actor
  )
  returning * into saved;

  perform private.accounting_replace_lines(saved.id,target_lines,false,'[]'::jsonb);

  update public.accounting_journal_entries
  set status='posted',posted_by=actor,posted_at=now(),updated_at=now()
  where id=saved.id
  returning * into saved;

  perform private.accounting_assert_entry_balanced(saved.id);

  insert into public.accounting_source_links(
    source_module,source_event,source_record_id,source_line_id,source_revision,
    journal_entry_id,link_status
  ) values(
    btrim(target_module),btrim(target_event),btrim(target_record_id),null,1,
    saved.id,'active'
  );

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values(
    'accounting_journal_entries',saved.id::text,'accounting_system_journal_posted',actor,
    private.accounting_journal_snapshot(saved.id),
    jsonb_build_object(
      'source_module',btrim(target_module),
      'source_event',btrim(target_event),
      'source_record_id',btrim(target_record_id)
    )
  );

  return saved.id;
end
$$;
revoke all on function private.accounting_post_source_journal(text,text,text,date,text,text,uuid,jsonb,uuid)
  from public,anon,authenticated;

create or replace function private.accounting_reverse_source_journal(
  target_module text,
  target_event text,
  target_record_id text,
  reversal_date date,
  reason text,
  actor uuid
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  linked_entry uuid;
  linked_status text;
  reversal_payload jsonb;
  reversal_id uuid;
  lock_key text;
begin
  if actor is null then
    raise exception using errcode='42501',message='Authenticated actor required for accounting reversal';
  end if;
  if nullif(btrim(reason),'') is null then
    raise exception using errcode='22023',message='Accounting source reversal reason is required';
  end if;

  lock_key:=lower(btrim(target_module))||':'||lower(btrim(target_event))||':'||btrim(target_record_id)||':1';
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(lock_key,0));

  select l.journal_entry_id,j.status
  into linked_entry,linked_status
  from public.accounting_source_links l
  join public.accounting_journal_entries j on j.id=l.journal_entry_id
  where lower(btrim(l.source_module))=lower(btrim(target_module))
    and lower(btrim(l.source_event))=lower(btrim(target_event))
    and l.source_record_id=btrim(target_record_id)
    and l.source_line_id is null
    and l.source_revision=1
    and l.link_status='active'
  order by l.created_at desc
  limit 1;

  if linked_entry is null then
    return null;
  end if;

  if linked_status<>'posted' then
    raise exception using
      errcode='23514',
      message='Linked accounting journal is not in a reversible posted state';
  end if;

  reversal_payload:=private.reverse_accounting_journal_current_lines(
    linked_entry,coalesce(reversal_date,current_date),btrim(reason),actor
  );
  reversal_id:=nullif(reversal_payload#>>'{reversal,id}','')::uuid;
  return reversal_id;
end
$$;
revoke all on function private.accounting_reverse_source_journal(text,text,text,date,text,uuid)
  from public,anon,authenticated;

create or replace function private.accounting_cash_source_insert_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  event_date date;
  actor uuid:=auth.uid();
  lines jsonb:='[]'::jsonb;
  bank_account uuid;
  ar_account uuid;
  ap_account uuid;
  customer_advance_account uuid;
  supplier_advance_account uuid;
  target_project uuid;
begin
  if tg_table_name='customer_receipts' then
    if new.status<>'posted' then return new; end if;
    event_date:=coalesce(new.receipt_date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;
    if new.transaction_classification is null then
      raise exception using errcode='23514',message='Classified customer receipt required for accounting auto-posting';
    end if;

    bank_account:=private.accounting_resolve_mapping('default_cash_bank','global','');
    lines:=jsonb_build_array(jsonb_build_object(
      'account_id',bank_account,'debit',new.amount,'credit',0,
      'description','تحصيل عميل','source_line_id','cash'
    ));

    if coalesce(new.settlement_amount,0)>0 then
      ar_account:=private.accounting_resolve_mapping('accounts_receivable','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',ar_account,'debit',0,'credit',new.settlement_amount,
        'description','تسوية ذمة عميل','partner_type','customer','partner_id',new.customer_id,
        'source_line_id','settlement'
      ));
    end if;

    if coalesce(new.advance_amount,0)>0 then
      customer_advance_account:=private.accounting_resolve_mapping('customer_advances','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',customer_advance_account,'debit',0,'credit',new.advance_amount,
        'description','دفعة مقدمة من عميل','partner_type','customer','partner_id',new.customer_id,
        'source_line_id','advance'
      ));
    end if;

    perform private.accounting_post_source_journal(
      'customers','customer_receipt_classified',new.id::text,event_date,
      'تحصيل عميل — '||new.id::text,
      'customer_receipt:'||new.id::text,
      null,lines,actor
    );
    return new;
  end if;

  if tg_table_name='supplier_payments' then
    if new.status<>'posted' then return new; end if;
    event_date:=coalesce(new.payment_date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;
    if new.transaction_classification is null then
      raise exception using errcode='23514',message='Classified supplier payment required for accounting auto-posting';
    end if;

    lines:='[]'::jsonb;

    if coalesce(new.settlement_amount,0)>0 then
      ap_account:=private.accounting_resolve_mapping('accounts_payable','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',ap_account,'debit',new.settlement_amount,'credit',0,
        'description','تسوية ذمة مورد','partner_type','supplier','partner_id',new.supplier_id,
        'source_line_id','settlement'
      ));
    end if;

    if coalesce(new.advance_amount,0)>0 then
      supplier_advance_account:=private.accounting_resolve_mapping('supplier_advances','global','');
      lines:=lines||jsonb_build_array(jsonb_build_object(
        'account_id',supplier_advance_account,'debit',new.advance_amount,'credit',0,
        'description','دفعة مقدمة لمورد','partner_type','supplier','partner_id',new.supplier_id,
        'source_line_id','advance'
      ));
    end if;

    bank_account:=private.accounting_resolve_mapping('default_cash_bank','global','');
    lines:=lines||jsonb_build_array(jsonb_build_object(
      'account_id',bank_account,'debit',0,'credit',new.amount,
      'description','دفع لمورد','source_line_id','cash'
    ));

    perform private.accounting_post_source_journal(
      'suppliers','supplier_payment_classified',new.id::text,event_date,
      'دفع لمورد — '||new.id::text,
      'supplier_payment:'||new.id::text,
      null,lines,actor
    );
    return new;
  end if;

  if tg_table_name='customer_advance_allocations' then
    if new.status<>'allocated' then return new; end if;
    event_date:=coalesce(new.allocated_at::date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;

    if new.target_type='project' then
      target_project:=new.target_id;
    else
      target_project:=null;
    end if;

    customer_advance_account:=private.accounting_resolve_mapping('customer_advances','global','');
    ar_account:=private.accounting_resolve_mapping('accounts_receivable','global','');

    lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',customer_advance_account,'debit',new.amount,'credit',0,
        'description','تخصيص دفعة مقدمة من عميل','partner_type','customer','partner_id',new.customer_id,
        'project_id',target_project,'source_line_id','advance_release'
      ),
      jsonb_build_object(
        'account_id',ar_account,'debit',0,'credit',new.amount,
        'description','تسوية ذمة عميل من دفعة مقدمة','partner_type','customer','partner_id',new.customer_id,
        'project_id',target_project,'source_line_id','receivable_settlement'
      )
    );

    perform private.accounting_post_source_journal(
      'customers','customer_advance_allocated',new.id::text,event_date,
      'تخصيص دفعة مقدمة من عميل — '||new.id::text,
      new.target_type||':'||new.target_id::text,
      target_project,lines,actor
    );
    return new;
  end if;

  if tg_table_name='supplier_advance_allocations' then
    if new.status<>'allocated' then return new; end if;
    event_date:=coalesce(new.allocated_at::date,current_date);
    if not private.accounting_source_event_in_scope(event_date) then return new; end if;

    if new.target_type='supplier_invoice' then
      select si.project_id into target_project
      from public.supplier_invoices si where si.id=new.target_id;
    elsif new.target_type='material_purchase' then
      select mp.project_id into target_project
      from public.material_purchases mp where mp.id=new.target_id;
    end if;

    ap_account:=private.accounting_resolve_mapping('accounts_payable','global','');
    supplier_advance_account:=private.accounting_resolve_mapping('supplier_advances','global','');

    lines:=jsonb_build_array(
      jsonb_build_object(
        'account_id',ap_account,'debit',new.amount,'credit',0,
        'description','تسوية ذمة مورد من دفعة مقدمة','partner_type','supplier','partner_id',new.supplier_id,
        'project_id',target_project,'source_line_id','payable_settlement'
      ),
      jsonb_build_object(
        'account_id',supplier_advance_account,'debit',0,'credit',new.amount,
        'description','تخصيص دفعة مقدمة لمورد','partner_type','supplier','partner_id',new.supplier_id,
        'project_id',target_project,'source_line_id','advance_release'
      )
    );

    perform private.accounting_post_source_journal(
      'suppliers','supplier_advance_allocated',new.id::text,event_date,
      'تخصيص دفعة مقدمة لمورد — '||new.id::text,
      new.target_type||':'||new.target_id::text,
      target_project,lines,actor
    );
    return new;
  end if;

  return new;
end
$$;
revoke all on function private.accounting_cash_source_insert_trigger() from public,anon,authenticated;

create or replace function private.accounting_cash_source_reversal_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.reversed_by);
  reversal_date date:=coalesce(new.reversed_at::date,current_date);
begin
  if old.status is not distinct from new.status then
    return new;
  end if;

  if tg_table_name='customer_receipts'
     and old.status='posted' and new.status='reversed' then
    perform private.accounting_reverse_source_journal(
      'customers','customer_receipt_classified',new.id::text,reversal_date,
      new.reversal_reason,actor
    );
    return new;
  end if;

  if tg_table_name='supplier_payments'
     and old.status='posted' and new.status='reversed' then
    perform private.accounting_reverse_source_journal(
      'suppliers','supplier_payment_classified',new.id::text,reversal_date,
      new.reversal_reason,actor
    );
    return new;
  end if;

  if tg_table_name='customer_advance_allocations'
     and old.status='allocated' and new.status='reversed' then
    perform private.accounting_reverse_source_journal(
      'customers','customer_advance_allocated',new.id::text,reversal_date,
      new.reversal_reason,actor
    );
    return new;
  end if;

  if tg_table_name='supplier_advance_allocations'
     and old.status='allocated' and new.status='reversed' then
    perform private.accounting_reverse_source_journal(
      'suppliers','supplier_advance_allocated',new.id::text,reversal_date,
      new.reversal_reason,actor
    );
    return new;
  end if;

  return new;
end
$$;
revoke all on function private.accounting_cash_source_reversal_trigger() from public,anon,authenticated;

create trigger accounting_customer_receipts_post_gl
after insert on public.customer_receipts
for each row execute function private.accounting_cash_source_insert_trigger();

create trigger accounting_supplier_payments_post_gl
after insert on public.supplier_payments
for each row execute function private.accounting_cash_source_insert_trigger();

create trigger accounting_customer_advance_allocations_post_gl
after insert on public.customer_advance_allocations
for each row execute function private.accounting_cash_source_insert_trigger();

create trigger accounting_supplier_advance_allocations_post_gl
after insert on public.supplier_advance_allocations
for each row execute function private.accounting_cash_source_insert_trigger();

create trigger accounting_customer_receipts_reverse_gl
after update of status on public.customer_receipts
for each row execute function private.accounting_cash_source_reversal_trigger();

create trigger accounting_supplier_payments_reverse_gl
after update of status on public.supplier_payments
for each row execute function private.accounting_cash_source_reversal_trigger();

create trigger accounting_customer_advance_allocations_reverse_gl
after update of status on public.customer_advance_allocations
for each row execute function private.accounting_cash_source_reversal_trigger();

create trigger accounting_supplier_advance_allocations_reverse_gl
after update of status on public.supplier_advance_allocations
for each row execute function private.accounting_cash_source_reversal_trigger();
