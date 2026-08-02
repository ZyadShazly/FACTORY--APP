-- Complete the external-labor settlement calculation without rewriting history.
begin;

alter table public.daily_labor
  add column if not exists addition_amount numeric not null default 0,
  add column if not exists addition_reason text,
  add column if not exists deduction_amount numeric not null default 0,
  add column if not exists deduction_reason text;

alter table public.daily_labor
  drop constraint if exists daily_labor_addition_amount_check,
  add constraint daily_labor_addition_amount_check check (addition_amount >= 0),
  drop constraint if exists daily_labor_deduction_amount_check,
  add constraint daily_labor_deduction_amount_check check (deduction_amount >= 0),
  drop constraint if exists daily_labor_settlement_reason_check,
  add constraint daily_labor_settlement_reason_check check (
    (addition_amount = 0 or nullif(btrim(addition_reason),'') is not null)
    and (deduction_amount = 0 or nullif(btrim(deduction_reason),'') is not null)
    and deduction_amount <= total_amount + addition_amount
  );

alter table public.daily_labor
  add column if not exists net_amount numeric generated always as (
    total_amount + addition_amount - deduction_amount
  ) stored;

drop policy if exists active_profile_restriction on public.daily_labor;
drop policy if exists daily_labor_active_profile_restriction on public.daily_labor;
create policy daily_labor_active_profile_restriction
on public.daily_labor as restrictive
for all to authenticated
using (public.is_current_profile_active())
with check (public.is_current_profile_active());

create or replace function private.guard_daily_labor_settlement()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if old.review_status <> 'draft' and (
    new.worker_name is distinct from old.worker_name
    or new.project_id is distinct from old.project_id
    or new.work_date is distinct from old.work_date
    or new.start_time is distinct from old.start_time
    or new.end_time is distinct from old.end_time
    or new.break_minutes is distinct from old.break_minutes
    or new.hourly_rate is distinct from old.hourly_rate
    or new.overtime_hours is distinct from old.overtime_hours
    or new.overtime_rate is distinct from old.overtime_rate
    or new.addition_amount is distinct from old.addition_amount
    or new.addition_reason is distinct from old.addition_reason
    or new.deduction_amount is distinct from old.deduction_amount
    or new.deduction_reason is distinct from old.deduction_reason
  ) then
    raise exception using errcode='23514',
      message='Reviewed daily labor settlement is immutable; use correction workflow';
  end if;
  return new;
end $$;

revoke all on function private.guard_daily_labor_settlement()
  from public,anon,authenticated;
drop trigger if exists guard_daily_labor_settlement on public.daily_labor;
create trigger guard_daily_labor_settlement
before update on public.daily_labor
for each row execute function private.guard_daily_labor_settlement();

create or replace function public.pay_daily_labor(
  target_shift_id uuid,
  reference text default null,
  notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor_id uuid := auth.uid();
  current_row public.daily_labor%rowtype;
  result_row public.daily_labor%rowtype;
begin
  if actor_id is null or not public.has_permission('daily_labor_pay') then
    raise exception using errcode='42501',message='Daily labor payment permission required';
  end if;

  select * into current_row from public.daily_labor
  where id=target_shift_id for update;
  if not found then raise exception using errcode='P0002',message='Daily labor shift was not found'; end if;
  if current_row.review_status <> 'approved' then
    raise exception using errcode='23514',message='Daily labor shift must be approved before payment';
  end if;
  if current_row.payment_status='paid' then
    raise exception using errcode='23514',message='Daily labor shift is already paid';
  end if;
  if current_row.net_amount <= 0 then
    raise exception using errcode='23514',message='Net settlement must be greater than zero';
  end if;

  update public.daily_labor
  set payment_status='paid',paid_amount=net_amount,
      payment_reference=nullif(btrim($2),''),
      payment_notes=nullif(btrim($3),''),
      paid_by=actor_id,paid_at=now()
  where id=target_shift_id returning * into result_row;

  return jsonb_build_object('ok',true,'shift',to_jsonb(result_row));
end $$;

revoke all on function public.pay_daily_labor(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.pay_daily_labor(uuid,text,text) to authenticated;

commit;
