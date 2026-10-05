create or replace function private.guard_sale_history()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  expected_net numeric(18,2);
  expected_tax numeric(18,2);
  expected_total numeric(18,2);
begin
  if tg_op='DELETE' then
    raise exception using errcode='23514',message='Sale history cannot be deleted; use cancel_sale';
  end if;

  if tg_op='INSERT' then
    if new.status<>'posted'
       or new.cancelled_at is not null
       or new.cancelled_by is not null
       or new.cancellation_reason is not null then
      raise exception using errcode='22023',message='New sales must start posted';
    end if;

    if new.qty is null or new.qty<=0
       or new.unit_price is null or new.unit_price<=0
       or new.total is null or new.total<=0 then
      raise exception using errcode='22023',message='Sale quantity, unit price and total must be positive';
    end if;

    if new.tax_rate is null
       or new.tax_rate<0
       or new.tax_rate>100
       or new.tax_amount is null
       or new.tax_amount<0 then
      raise exception using errcode='22023',message='Sale tax rate and amount are invalid';
    end if;

    expected_net:=round(new.qty*new.unit_price,2);
    expected_tax:=round(expected_net*new.tax_rate/100,2);
    expected_total:=round(expected_net+expected_tax,2);

    if round(new.tax_amount,2)<>expected_tax then
      raise exception using errcode='22023',message='Sale tax amount does not match quantity, unit price and tax rate';
    end if;

    if round(new.total,2)<>expected_total then
      raise exception using errcode='22023',message='Sale total must equal net amount plus tax';
    end if;

    return new;
  end if;

  if old.status='cancelled' and new is distinct from old then
    raise exception using errcode='23514',message='Cancelled sale is immutable';
  end if;

  if new.product_id is distinct from old.product_id
     or new.customer_id is distinct from old.customer_id
     or new.qty is distinct from old.qty
     or new.unit_price is distinct from old.unit_price
     or new.total is distinct from old.total
     or new.tax_rate is distinct from old.tax_rate
     or new.tax_amount is distinct from old.tax_amount
     or new.sale_date is distinct from old.sale_date
     or new.note is distinct from old.note then
    raise exception using errcode='23514',message='Posted sale is immutable; cancel it and record a corrected sale';
  end if;

  if new.status is distinct from old.status then
    if old.status<>'posted'
       or new.status<>'cancelled'
       or new.cancelled_at is null
       or new.cancelled_by is null
       or nullif(btrim(new.cancellation_reason),'') is null then
      raise exception using errcode='23514',message='Invalid sale lifecycle transition';
    end if;
  elsif new.cancelled_at is distinct from old.cancelled_at
     or new.cancelled_by is distinct from old.cancelled_by
     or new.cancellation_reason is distinct from old.cancellation_reason then
    raise exception using errcode='23514',message='Sale cancellation metadata requires the lifecycle action';
  end if;

  return new;
end
$$;

revoke all on function private.guard_sale_history()
  from public,anon,authenticated;
