begin;

alter table public.daily_labor
  add column if not exists review_status text not null default 'draft',
  add column if not exists reviewed_by uuid references public.profiles(id) on delete set null,
  add column if not exists reviewed_at timestamptz,
  add column if not exists rejection_reason text,
  add column if not exists payment_reference text,
  add column if not exists payment_notes text,
  add column if not exists paid_by uuid references public.profiles(id) on delete set null,
  add column if not exists paid_at timestamptz;

alter table public.daily_labor drop constraint if exists daily_labor_review_status_check;
alter table public.daily_labor add constraint daily_labor_review_status_check
  check (review_status in ('draft','rejected','approved'));

update public.daily_labor
set review_status = 'approved',
    reviewed_at = coalesce(reviewed_at, updated_at, created_at),
    paid_at = coalesce(paid_at, updated_at, created_at)
where payment_status = 'paid'
  and review_status <> 'approved';

create or replace function public.review_daily_labor(
  target_shift_id uuid,
  approve boolean,
  reason text default null
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
  decision_reason text := nullif(btrim(reason), '');
begin
  if actor_id is null or not (
    public.current_identity_role() in ('owner','manager')
    or public.has_permission('daily_labor_edit')
  ) then
    raise exception using errcode='42501', message='Daily labor review permission required';
  end if;

  select * into current_row
  from public.daily_labor
  where id = target_shift_id
  for update;

  if not found then
    raise exception using errcode='P0002', message='Daily labor shift was not found';
  end if;

  if current_row.payment_status = 'paid' then
    raise exception using errcode='23514', message='Paid daily labor shift cannot be reviewed again';
  end if;

  if approve then
    update public.daily_labor
    set review_status='approved', reviewed_by=actor_id, reviewed_at=now(), rejection_reason=null
    where id=target_shift_id
    returning * into result_row;
  else
    if decision_reason is null then
      raise exception using errcode='23514', message='Rejection reason is required';
    end if;
    update public.daily_labor
    set review_status='rejected', reviewed_by=actor_id, reviewed_at=now(), rejection_reason=decision_reason
    where id=target_shift_id
    returning * into result_row;
  end if;

  return jsonb_build_object('ok', true, 'shift', to_jsonb(result_row));
end
$$;

revoke all on function public.review_daily_labor(uuid, boolean, text) from public, anon;
grant execute on function public.review_daily_labor(uuid, boolean, text) to authenticated;

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
      payment_reference=nullif(btrim(reference), ''),
      payment_notes=nullif(btrim(notes), ''),
      paid_by=actor_id,
      paid_at=now()
  where id=target_shift_id
  returning * into result_row;

  return jsonb_build_object('ok', true, 'shift', to_jsonb(result_row));
end
$$;

revoke all on function public.pay_daily_labor(uuid, text, text) from public, anon;
grant execute on function public.pay_daily_labor(uuid, text, text) to authenticated;

create or replace function public.protect_daily_labor_history()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if old.payment_status = 'paid'
     or old.review_status = 'approved'
     or old.cost_posting_status not in ('not_posted','pending')
     or old.actual_cost_entry_id is not null then
    raise exception using errcode='23503', message='Reviewed, paid, or posted daily labor cannot be deleted';
  end if;
  return old;
end
$$;

revoke all on function public.protect_daily_labor_history() from public, anon, authenticated;
drop trigger if exists protect_daily_labor_history_trigger on public.daily_labor;
create trigger protect_daily_labor_history_trigger
before delete on public.daily_labor
for each row execute function public.protect_daily_labor_history();

commit;
