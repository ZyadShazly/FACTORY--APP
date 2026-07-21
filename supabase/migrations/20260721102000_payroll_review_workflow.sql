begin;

alter table public.payroll
  add column if not exists deduction_reason text,
  add column if not exists advance_reason text,
  add column if not exists bonus_reason text,
  add column if not exists rejection_reason text,
  add column if not exists rejected_by uuid references public.profiles(id) on delete set null,
  add column if not exists rejected_at timestamptz,
  add column if not exists review_updated_by uuid references public.profiles(id) on delete set null,
  add column if not exists review_updated_at timestamptz;

alter table public.payroll drop constraint if exists payroll_status_check;
alter table public.payroll add constraint payroll_status_check
  check (status in ('draft','rejected','approved','paid'));

create or replace function public.payroll_review_allowed()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.current_identity_role() in ('owner','manager')
    or public.has_permission('payroll_edit')
    or public.has_permission('payroll_approve')
$$;

revoke all on function public.payroll_review_allowed() from public, anon;
grant execute on function public.payroll_review_allowed() to authenticated;

create or replace function public.update_payroll_review(target_payroll_id uuid, payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  current_row public.payroll%rowtype;
  updated_row public.payroll%rowtype;
  deduction_value numeric(14,2);
  advance_value numeric(14,2);
  bonus_value numeric(14,2);
  overtime_hours_value numeric(10,2);
  overtime_rate_value numeric(14,2);
  deduction_text text;
  advance_text text;
  bonus_text text;
begin
  if actor_id is null or not public.payroll_review_allowed() then
    raise exception using errcode='42501', message='Payroll review permission required';
  end if;

  select * into current_row from public.payroll where id = target_payroll_id for update;
  if not found then raise exception using errcode='P0002', message='Payroll record was not found'; end if;
  if current_row.status not in ('draft','rejected') then
    raise exception using errcode='23514', message='Only draft or rejected payroll can be recalculated';
  end if;

  deduction_value := greatest(coalesce((payload->>'deductions')::numeric, current_row.deductions), 0);
  advance_value := greatest(coalesce((payload->>'advances')::numeric, current_row.advances), 0);
  bonus_value := greatest(coalesce((payload->>'bonuses')::numeric, current_row.bonuses), 0);
  overtime_hours_value := greatest(coalesce((payload->>'overtime_hours')::numeric, current_row.overtime_hours), 0);
  overtime_rate_value := greatest(coalesce((payload->>'overtime_rate')::numeric, current_row.overtime_rate), 0);
  deduction_text := nullif(btrim(payload->>'deduction_reason'), '');
  advance_text := nullif(btrim(payload->>'advance_reason'), '');
  bonus_text := nullif(btrim(payload->>'bonus_reason'), '');

  if deduction_value > 0 and deduction_text is null then
    raise exception using errcode='23514', message='Deduction reason is required';
  end if;
  if advance_value > 0 and advance_text is null then
    raise exception using errcode='23514', message='Advance reason is required';
  end if;
  if bonus_value > 0 and bonus_text is null then
    raise exception using errcode='23514', message='Bonus reason is required';
  end if;
  if bonus_value is distinct from current_row.bonuses and not public.has_permission('payroll_bonus_manage') then
    raise exception using errcode='42501', message='Payroll bonus permission required';
  end if;

  update public.payroll set
    overtime_hours = overtime_hours_value,
    overtime_rate = overtime_rate_value,
    deductions = deduction_value,
    advances = advance_value,
    bonuses = bonus_value,
    deduction_reason = deduction_text,
    advance_reason = advance_text,
    bonus_reason = bonus_text,
    notes = nullif(btrim(payload->>'notes'), ''),
    status = 'draft',
    rejection_reason = null,
    rejected_by = null,
    rejected_at = null,
    review_updated_by = actor_id,
    review_updated_at = now()
  where id = target_payroll_id
  returning * into updated_row;

  return jsonb_build_object('ok', true, 'payroll', to_jsonb(updated_row));
end
$$;

revoke all on function public.update_payroll_review(uuid, jsonb) from public, anon;
grant execute on function public.update_payroll_review(uuid, jsonb) to authenticated;

create or replace function public.review_payroll(target_payroll_id uuid, approve boolean, reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  current_row public.payroll%rowtype;
  result_row public.payroll%rowtype;
  decision_reason text := nullif(btrim(reason), '');
begin
  if actor_id is null or not public.has_permission('payroll_approve') then
    raise exception using errcode='42501', message='Payroll approval permission required';
  end if;

  select * into current_row from public.payroll where id = target_payroll_id for update;
  if not found then raise exception using errcode='P0002', message='Payroll record was not found'; end if;
  if current_row.status not in ('draft','rejected') then
    raise exception using errcode='23514', message='Only draft or rejected payroll can be reviewed';
  end if;

  if current_row.deductions > 0 and nullif(btrim(current_row.deduction_reason), '') is null then
    raise exception using errcode='23514', message='Deduction reason is required before approval';
  end if;
  if current_row.advances > 0 and nullif(btrim(current_row.advance_reason), '') is null then
    raise exception using errcode='23514', message='Advance reason is required before approval';
  end if;
  if current_row.bonuses > 0 and nullif(btrim(current_row.bonus_reason), '') is null then
    raise exception using errcode='23514', message='Bonus reason is required before approval';
  end if;

  if approve then
    update public.payroll set
      status='approved', approved_by=actor_id, approved_at=now(),
      rejection_reason=null, rejected_by=null, rejected_at=null
    where id=target_payroll_id returning * into result_row;
  else
    if decision_reason is null then raise exception using errcode='23514', message='Rejection reason is required'; end if;
    update public.payroll set
      status='rejected', rejection_reason=decision_reason,
      rejected_by=actor_id, rejected_at=now(),
      approved_by=null, approved_at=null
    where id=target_payroll_id returning * into result_row;
  end if;

  return jsonb_build_object('ok', true, 'payroll', to_jsonb(result_row));
end
$$;

revoke all on function public.review_payroll(uuid, boolean, text) from public, anon;
grant execute on function public.review_payroll(uuid, boolean, text) to authenticated;

create or replace function public.enforce_payroll_review_reasons()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.status in ('approved','paid') then
    if new.deductions > 0 and nullif(btrim(new.deduction_reason), '') is null then
      raise exception using errcode='23514', message='Deduction reason is required before approval';
    end if;
    if new.advances > 0 and nullif(btrim(new.advance_reason), '') is null then
      raise exception using errcode='23514', message='Advance reason is required before approval';
    end if;
    if new.bonuses > 0 and nullif(btrim(new.bonus_reason), '') is null then
      raise exception using errcode='23514', message='Bonus reason is required before approval';
    end if;
  end if;
  return new;
end
$$;

revoke all on function public.enforce_payroll_review_reasons() from public, anon, authenticated;
drop trigger if exists enforce_payroll_review_reasons_trigger on public.payroll;
create trigger enforce_payroll_review_reasons_trigger
before insert or update on public.payroll
for each row execute function public.enforce_payroll_review_reasons();

commit;
