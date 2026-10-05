-- Protect cash custody chronology: settlement/return dates cannot predate the issue date.

begin;

create or replace function public.record_employee_cash_custody_settlement(
  target_custody uuid,
  expense_amount numeric,
  expense_category text,
  settled_on date default current_date,
  expense_notes text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare custody public.employee_cash_custodies%rowtype; saved public.employee_cash_custody_settlements%rowtype;
  remaining numeric; actual_entry jsonb; actor uuid:=auth.uid();
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if expense_amount is null or expense_amount<=0 then
    raise exception using errcode='22023',message='Settlement expense amount must be positive';
  end if;
  if nullif(btrim(expense_category),'') is null then
    raise exception using errcode='22023',message='Expense category is required';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;

  select * into saved from public.employee_cash_custody_settlements
  where employee_cash_custody_settlements.command_id=record_employee_cash_custody_settlement.command_id;
  if found then return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(saved.custody_id)); end if;

  select * into custody from public.employee_cash_custodies where id=target_custody for update;
  if not found then raise exception using errcode='P0002',message='Cash custody was not found'; end if;
  if custody.status='settled' then raise exception using errcode='23514',message='Cash custody is already settled'; end if;
  if coalesce(settled_on,current_date)<custody.issued_on then
    raise exception using errcode='23514',message='Settlement date cannot be before cash custody issue date';
  end if;

  remaining:=private.employee_cash_custody_remaining(custody.id);
  if round(expense_amount,2)>remaining then
    raise exception using errcode='23514',message='Settlement exceeds remaining cash custody balance';
  end if;

  insert into public.employee_cash_custody_settlements(
    custody_id,expense_category,amount,settled_on,notes,command_id,approved_by,created_by
  ) values(
    custody.id,btrim(expense_category),round(expense_amount,2),coalesce(settled_on,current_date),
    nullif(btrim(expense_notes),''),command_id,actor,actor
  ) returning * into saved;

  if custody.project_id is not null then
    actual_entry:=public.save_project_actual_cost(jsonb_build_object(
      'project_id',custody.project_id,
      'cost_category','employee_cash_custody',
      'source_type','employee_cash_custody_settlement_line',
      'source_id',saved.id,
      'source_line_reference','main',
      'source_revision',1,
      'source_reference_key','employee_cash_custody_settlement_line:'||saved.id::text||':main:1',
      'description',concat('تسوية عهدة ',custody.custody_number,' — ',saved.expense_category),
      'quantity',1,'unit','تسوية','unit_cost',saved.amount,'cost_date',saved.settled_on,
      'metadata',jsonb_build_object('custody_id',custody.id,'employee_id',custody.employee_id)
    ));
    perform public.submit_project_actual_cost((actual_entry->>'id')::uuid);
    perform public.approve_project_actual_cost((actual_entry->>'id')::uuid);
    update public.employee_cash_custody_settlements set actual_cost_entry_id=(actual_entry->>'id')::uuid where id=saved.id returning * into saved;
  end if;

  perform private.refresh_employee_cash_custody_status(custody.id);

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('employee_cash_custody_settlements',saved.id::text,'employee_cash_custody_settlement_approved',actor,to_jsonb(saved),
    jsonb_build_object('custody_id',custody.id,'remaining_amount',private.employee_cash_custody_remaining(custody.id)));

  return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(custody.id));
end
$$;
revoke all on function public.record_employee_cash_custody_settlement(uuid,numeric,text,date,text,uuid) from public,anon;
grant execute on function public.record_employee_cash_custody_settlement(uuid,numeric,text,date,text,uuid) to authenticated;

create or replace function public.record_employee_cash_custody_return(
  target_custody uuid,
  return_amount numeric,
  returned_on date default current_date,
  cash_bank_account uuid default null,
  return_notes text default null,
  command_id uuid default gen_random_uuid()
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare custody public.employee_cash_custodies%rowtype; saved public.employee_cash_custody_returns%rowtype; remaining numeric;
begin
  if not private.commercial_payment_allowed() then
    raise exception using errcode='42501',message='Finance payment permission required';
  end if;
  if return_amount is null or return_amount<=0 then
    raise exception using errcode='22023',message='Return amount must be positive';
  end if;
  if cash_bank_account is null then
    raise exception using errcode='22023',message='Cash or bank account is required';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;

  select * into saved from public.employee_cash_custody_returns
  where employee_cash_custody_returns.command_id=record_employee_cash_custody_return.command_id;
  if found then return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(saved.custody_id)); end if;

  select * into custody from public.employee_cash_custodies where id=target_custody for update;
  if not found then raise exception using errcode='P0002',message='Cash custody was not found'; end if;
  if custody.status='settled' then raise exception using errcode='23514',message='Cash custody is already settled'; end if;
  if coalesce(returned_on,current_date)<custody.issued_on then
    raise exception using errcode='23514',message='Return date cannot be before cash custody issue date';
  end if;

  perform private.accounting_assert_cash_bank_posting_account(cash_bank_account);
  remaining:=private.employee_cash_custody_remaining(custody.id);
  if round(return_amount,2)>remaining then
    raise exception using errcode='23514',message='Return exceeds remaining cash custody balance';
  end if;

  insert into public.employee_cash_custody_returns(
    custody_id,amount,returned_on,cash_bank_account_id,notes,command_id,created_by
  ) values(
    custody.id,round(return_amount,2),coalesce(returned_on,current_date),cash_bank_account,
    nullif(btrim(return_notes),''),command_id,auth.uid()
  ) returning * into saved;

  perform private.refresh_employee_cash_custody_status(custody.id);

  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('employee_cash_custody_returns',saved.id::text,'employee_cash_custody_returned',auth.uid(),to_jsonb(saved),
    jsonb_build_object('custody_id',custody.id,'remaining_amount',private.employee_cash_custody_remaining(custody.id)));

  return to_jsonb(saved)||jsonb_build_object('remaining_amount',private.employee_cash_custody_remaining(custody.id));
end
$$;
revoke all on function public.record_employee_cash_custody_return(uuid,numeric,date,uuid,text,uuid) from public,anon;
grant execute on function public.record_employee_cash_custody_return(uuid,numeric,date,uuid,text,uuid) to authenticated;

commit;
