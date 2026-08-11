begin;

create or replace function public.pay_daily_labor(
  target_shift_id uuid,
  reference text default null,
  notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  current_row public.daily_labor%rowtype;
  result_row public.daily_labor%rowtype;
begin
  if actor_id is null or not public.has_permission('daily_labor_pay') then
    raise exception using errcode='42501', message='Daily labor payment permission required';
  end if;

  select * into current_row
  from public.daily_labor
  where id = target_shift_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Daily labor shift was not found';
  end if;
  if current_row.review_status <> 'approved' then
    raise exception using errcode='23514', message='Daily labor shift must be approved before payment';
  end if;
  if current_row.payment_status = 'paid' then
    raise exception using errcode='23514', message='Daily labor shift is already paid';
  end if;

  update public.daily_labor
  set payment_status='paid',
      paid_amount=total_amount,
      payment_reference=nullif(btrim($2), ''),
      payment_notes=nullif(btrim($3), ''),
      paid_by=actor_id,
      paid_at=now()
  where id=target_shift_id
  returning * into result_row;

  return jsonb_build_object('ok', true, 'shift', to_jsonb(result_row));
end
$$;

revoke all on function public.pay_daily_labor(uuid, text, text) from public, anon;
grant execute on function public.pay_daily_labor(uuid, text, text) to authenticated;

commit;
