-- Auditable correction workflow for rejected daily-labor shifts.
begin;

alter table public.daily_labor
  add column if not exists correction_count integer not null default 0,
  add column if not exists last_correction_reason text,
  add column if not exists last_corrected_by uuid references public.profiles(id) on delete set null,
  add column if not exists last_corrected_at timestamptz;

alter table public.daily_labor
  drop constraint if exists daily_labor_correction_count_check,
  add constraint daily_labor_correction_count_check check (correction_count >= 0);

create table if not exists public.daily_labor_corrections (
  id uuid primary key default gen_random_uuid(),
  daily_labor_id uuid not null references public.daily_labor(id) on delete restrict,
  correction_number integer not null check (correction_number > 0),
  correction_reason text not null check (nullif(btrim(correction_reason),'') is not null),
  changed_fields text[] not null default '{}',
  before_snapshot jsonb not null,
  after_snapshot jsonb not null,
  corrected_by uuid references public.profiles(id) on delete set null,
  corrected_at timestamptz not null default now(),
  unique (daily_labor_id, correction_number)
);

create index if not exists daily_labor_corrections_shift_time_idx
  on public.daily_labor_corrections(daily_labor_id, corrected_at desc);

alter table public.daily_labor_corrections enable row level security;
revoke all on table public.daily_labor_corrections from public, anon, authenticated;
drop policy if exists daily_labor_corrections_no_direct_access on public.daily_labor_corrections;
create policy daily_labor_corrections_no_direct_access
on public.daily_labor_corrections as restrictive
for all to authenticated
using (false)
with check (false);

create or replace function public.calculate_daily_labor()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  minutes_worked numeric;
  normal_hours numeric;
  settlement_cap numeric;
begin
  minutes_worked := extract(epoch from (
    (new.work_date + new.end_time + case when new.end_time <= new.start_time then interval '1 day' else interval '0 day' end)
    - (new.work_date + new.start_time)
  )) / 60 - new.break_minutes;
  new.total_hours := greatest(round(minutes_worked / 60,2),0);
  normal_hours := greatest(new.total_hours - new.overtime_hours,0);
  new.total_amount := round(normal_hours * new.hourly_rate + new.overtime_hours * new.overtime_rate,2);
  settlement_cap := greatest(new.total_amount + coalesce(new.addition_amount,0) - coalesce(new.deduction_amount,0),0);
  new.paid_amount := least(greatest(new.paid_amount,0),settlement_cap);
  return new;
end $$;

revoke all on function public.calculate_daily_labor()
  from public,anon,authenticated;

create or replace function private.guard_daily_labor_settlement()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  correction_call boolean := coalesce(current_setting('app.daily_labor_correction',true),'') = 'on';
  review_call boolean := coalesce(current_setting('app.daily_labor_review',true),'') = 'on';
  payment_call boolean := coalesce(current_setting('app.daily_labor_payment',true),'') = 'on';
begin
  if old.review_status <> 'draft' and not correction_call and (
    new.worker_name is distinct from old.worker_name
    or new.phone is distinct from old.phone
    or new.trade is distinct from old.trade
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
    or new.notes is distinct from old.notes
  ) then
    raise exception using errcode='23514',
      message='Reviewed daily labor settlement is immutable; use correction workflow';
  end if;

  if not (review_call or correction_call) and (
    new.review_status is distinct from old.review_status
    or new.reviewed_by is distinct from old.reviewed_by
    or new.reviewed_at is distinct from old.reviewed_at
    or new.rejection_reason is distinct from old.rejection_reason
  ) then
    raise exception using errcode='42501',
      message='Daily labor review fields can only change through review workflow';
  end if;

  if not payment_call and (
    new.payment_status is distinct from old.payment_status
    or new.paid_amount is distinct from old.paid_amount
    or new.payment_reference is distinct from old.payment_reference
    or new.payment_notes is distinct from old.payment_notes
    or new.paid_by is distinct from old.paid_by
    or new.paid_at is distinct from old.paid_at
  ) then
    raise exception using errcode='42501',
      message='Daily labor payment fields can only change through payment workflow';
  end if;

  if not correction_call and (
    new.correction_count is distinct from old.correction_count
    or new.last_correction_reason is distinct from old.last_correction_reason
    or new.last_corrected_by is distinct from old.last_corrected_by
    or new.last_corrected_at is distinct from old.last_corrected_at
  ) then
    raise exception using errcode='42501',
      message='Daily labor correction audit fields are immutable';
  end if;

  return new;
end $$;

revoke all on function private.guard_daily_labor_settlement()
  from public,anon,authenticated;

create or replace function public.review_daily_labor(
  target_shift_id uuid,
  approve boolean,
  reason text default null
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
  decision_reason text := nullif(btrim(reason),'');
begin
  if actor_id is null or not public.is_current_profile_active() or not (
    public.current_identity_role() in ('owner','manager')
    or public.has_permission('daily_labor_edit')
  ) then
    raise exception using errcode='42501',message='Daily labor review permission required';
  end if;

  select * into current_row from public.daily_labor
  where id=target_shift_id for update;
  if not found then raise exception using errcode='P0002',message='Daily labor shift was not found'; end if;
  if current_row.payment_status='paid' then
    raise exception using errcode='23514',message='Paid daily labor shift cannot be reviewed again';
  end if;
  if current_row.review_status='rejected' then
    raise exception using errcode='23514',message='Rejected daily labor shift must be corrected before review';
  end if;
  if current_row.review_status <> 'draft' then
    raise exception using errcode='23514',message='Only draft daily labor shifts can be reviewed';
  end if;
  if not approve and decision_reason is null then
    raise exception using errcode='23514',message='Rejection reason is required';
  end if;

  perform set_config('app.daily_labor_review','on',true);
  update public.daily_labor
  set review_status=case when approve then 'approved' else 'rejected' end,
      reviewed_by=actor_id,
      reviewed_at=now(),
      rejection_reason=case when approve then null else decision_reason end
  where id=target_shift_id returning * into result_row;

  return jsonb_build_object('ok',true,'shift',to_jsonb(result_row));
end $$;

revoke all on function public.review_daily_labor(uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.review_daily_labor(uuid,boolean,text) to authenticated;

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
  if actor_id is null or not public.is_current_profile_active()
     or not public.has_permission('daily_labor_pay') then
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

  perform set_config('app.daily_labor_payment','on',true);
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

create or replace function public.correct_daily_labor(
  target_shift_id uuid,
  correction_reason text,
  payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor_id uuid := auth.uid();
  actor_role text := public.current_identity_role();
  clean_reason text := nullif(btrim(correction_reason),'');
  current_row public.daily_labor%rowtype;
  result_row public.daily_labor%rowtype;
  changed text[];
  next_number integer;
begin
  if actor_id is null or not public.is_current_profile_active()
     or actor_role='production'
     or not (actor_role in ('owner','manager') or public.has_permission('daily_labor_edit')) then
    raise exception using errcode='42501',message='Daily labor correction permission required';
  end if;
  if clean_reason is null then
    raise exception using errcode='23514',message='Correction reason is required';
  end if;
  if payload is null or jsonb_typeof(payload) <> 'object' or not (payload ?& array[
    'worker_name','phone','trade','project_id','work_date','start_time','end_time',
    'break_minutes','hourly_rate','overtime_hours','overtime_rate','addition_amount',
    'addition_reason','deduction_amount','deduction_reason','notes'
  ]) then
    raise exception using errcode='22023',message='Complete corrected shift details are required';
  end if;

  select * into current_row from public.daily_labor
  where id=target_shift_id for update;
  if not found then raise exception using errcode='P0002',message='Daily labor shift was not found'; end if;
  if current_row.review_status <> 'rejected' then
    raise exception using errcode='23514',message='Only rejected daily labor shifts can be corrected';
  end if;
  if current_row.payment_status <> 'unpaid' or current_row.paid_amount <> 0 then
    raise exception using errcode='23514',message='Paid daily labor shift cannot be corrected';
  end if;
  if current_row.actual_cost_entry_id is not null or current_row.cost_posting_status <> 'not_posted' then
    raise exception using errcode='23514',message='Posted daily labor shift cannot be corrected';
  end if;
  if nullif(btrim(payload->>'worker_name'),'') is null then
    raise exception using errcode='23514',message='Worker name is required';
  end if;

  next_number := current_row.correction_count + 1;
  perform set_config('app.daily_labor_correction','on',true);
  update public.daily_labor
  set worker_name=btrim(payload->>'worker_name'),
      phone=nullif(btrim(payload->>'phone'),''),
      trade=nullif(btrim(payload->>'trade'),''),
      project_id=nullif(payload->>'project_id','')::uuid,
      work_date=(payload->>'work_date')::date,
      start_time=(payload->>'start_time')::time,
      end_time=(payload->>'end_time')::time,
      break_minutes=(payload->>'break_minutes')::integer,
      hourly_rate=(payload->>'hourly_rate')::numeric,
      overtime_hours=(payload->>'overtime_hours')::numeric,
      overtime_rate=(payload->>'overtime_rate')::numeric,
      addition_amount=(payload->>'addition_amount')::numeric,
      addition_reason=nullif(btrim(payload->>'addition_reason'),''),
      deduction_amount=(payload->>'deduction_amount')::numeric,
      deduction_reason=nullif(btrim(payload->>'deduction_reason'),''),
      notes=nullif(btrim(payload->>'notes'),''),
      review_status='draft',reviewed_by=null,reviewed_at=null,rejection_reason=null,
      correction_count=next_number,last_correction_reason=clean_reason,
      last_corrected_by=actor_id,last_corrected_at=now()
  where id=target_shift_id returning * into result_row;

  changed := array_remove(array[
    case when current_row.worker_name is distinct from result_row.worker_name then 'worker_name' end,
    case when current_row.phone is distinct from result_row.phone then 'phone' end,
    case when current_row.trade is distinct from result_row.trade then 'trade' end,
    case when current_row.project_id is distinct from result_row.project_id then 'project_id' end,
    case when current_row.work_date is distinct from result_row.work_date then 'work_date' end,
    case when current_row.start_time is distinct from result_row.start_time then 'start_time' end,
    case when current_row.end_time is distinct from result_row.end_time then 'end_time' end,
    case when current_row.break_minutes is distinct from result_row.break_minutes then 'break_minutes' end,
    case when current_row.hourly_rate is distinct from result_row.hourly_rate then 'hourly_rate' end,
    case when current_row.overtime_hours is distinct from result_row.overtime_hours then 'overtime_hours' end,
    case when current_row.overtime_rate is distinct from result_row.overtime_rate then 'overtime_rate' end,
    case when current_row.addition_amount is distinct from result_row.addition_amount then 'addition_amount' end,
    case when current_row.addition_reason is distinct from result_row.addition_reason then 'addition_reason' end,
    case when current_row.deduction_amount is distinct from result_row.deduction_amount then 'deduction_amount' end,
    case when current_row.deduction_reason is distinct from result_row.deduction_reason then 'deduction_reason' end,
    case when current_row.notes is distinct from result_row.notes then 'notes' end
  ],null);

  insert into public.daily_labor_corrections(
    daily_labor_id,correction_number,correction_reason,changed_fields,
    before_snapshot,after_snapshot,corrected_by
  ) values (
    target_shift_id,next_number,clean_reason,changed,
    to_jsonb(current_row),to_jsonb(result_row),actor_id
  );

  return jsonb_build_object(
    'ok',true,'shift',to_jsonb(result_row),
    'correction',jsonb_build_object('number',next_number,'reason',clean_reason,'changed_fields',changed)
  );
end $$;

revoke all on function public.correct_daily_labor(uuid,text,jsonb)
  from public,anon,authenticated;
grant execute on function public.correct_daily_labor(uuid,text,jsonb) to authenticated;

create or replace function public.get_daily_labor_corrections(target_shift_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
stable
as $$
declare
  actor_id uuid := auth.uid();
  result jsonb;
begin
  if actor_id is null or not public.is_current_profile_active()
     or not public.has_permission('daily_labor_view') then
    raise exception using errcode='42501',message='Daily labor view permission required';
  end if;
  if not exists (select 1 from public.daily_labor where id=target_shift_id) then
    raise exception using errcode='P0002',message='Daily labor shift was not found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'number',c.correction_number,
    'reason',c.correction_reason,
    'changed_fields',to_jsonb(c.changed_fields),
    'corrected_at',c.corrected_at,
    'corrected_by_name',coalesce(p.full_name,'مستخدم سابق')
  ) order by c.correction_number desc),'[]'::jsonb)
  into result
  from public.daily_labor_corrections c
  left join public.profiles p on p.id=c.corrected_by
  where c.daily_labor_id=target_shift_id;

  return result;
end $$;

revoke all on function public.get_daily_labor_corrections(uuid)
  from public,anon,authenticated;
grant execute on function public.get_daily_labor_corrections(uuid) to authenticated;

commit;
