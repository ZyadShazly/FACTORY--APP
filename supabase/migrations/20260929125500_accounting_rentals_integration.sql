-- NextEP accounting integration: rental customer charge and cancellation reversal.
-- Rental inventory issue/return is operational custody of owned inventory, not a sale-cost event.
-- Existing historical rentals are not backfilled.

create or replace function private.accounting_rental_gl_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=coalesce(auth.uid(),new.cancelled_by);
  event_date date:=coalesce(new.start_date,current_date);
  ar_account uuid;
  revenue_account uuid;
  amount_base numeric(18,2);
  reference_value text;
begin
  if tg_op='INSERT'
     and new.status='active'
     and new.cancelled_at is null then

    amount_base:=round(coalesce(new.rental_fee,0),2);

    if amount_base<0 then
      raise exception using errcode='23514',
        message='Negative rental fee is not allowed for accounting posting';
    end if;

    -- Zero-fee rentals carry no financial value.
    if amount_base=0 then
      return new;
    end if;

    if not private.accounting_source_event_in_scope(event_date) then
      return new;
    end if;

    ar_account:=private.accounting_resolve_mapping(
      'accounts_receivable','global',''
    );
    revenue_account:=private.accounting_resolve_mapping(
      'rental_revenue','global',''
    );
    reference_value:='rental:'||new.id::text;

    perform private.accounting_post_source_journal(
      'rentals',
      'rental_customer_charge_posted',
      new.id::text,
      event_date,
      'إثبات إيراد إيجار — '||new.id::text,
      reference_value,
      null,
      jsonb_build_array(
        jsonb_build_object(
          'account_id',ar_account,
          'debit',amount_base,
          'credit',0,
          'description','ذمة عميل عن إيجار',
          'partner_type','customer',
          'partner_id',new.customer_id,
          'source_line_id','accounts_receivable',
          'reference',reference_value
        ),
        jsonb_build_object(
          'account_id',revenue_account,
          'debit',0,
          'credit',amount_base,
          'description','إيراد إيجار',
          'partner_type','customer',
          'partner_id',new.customer_id,
          'source_line_id','rental_revenue',
          'reference',reference_value
        )
      ),
      actor
    );

    return new;
  end if;

  if tg_op='UPDATE'
     and old.status='active'
     and new.status='cancelled'
     and old.status is distinct from new.status then

    perform private.accounting_reverse_source_journal(
      'rentals',
      'rental_customer_charge_posted',
      new.id::text,
      coalesce(new.cancelled_at::date,current_date),
      coalesce(nullif(btrim(new.cancellation_reason),''),'إلغاء الإيجار'),
      coalesce(auth.uid(),new.cancelled_by)
    );

    return new;
  end if;

  return new;
end
$$;

revoke all on function private.accounting_rental_gl_trigger()
  from public,anon,authenticated;

create trigger accounting_rentals_gl
after insert or update of status on public.rentals
for each row execute function private.accounting_rental_gl_trigger();
