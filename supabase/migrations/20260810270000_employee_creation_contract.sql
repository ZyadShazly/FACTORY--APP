-- Route employee master-data creation through the controlled employee lifecycle.
begin;

alter table public.employees add column if not exists command_id uuid;
create unique index if not exists employees_command_uidx on public.employees(command_id) where command_id is not null;

create or replace function public.create_employee_record(payload jsonb,command_id uuid default gen_random_uuid())
returns jsonb language plpgsql security definer set search_path='' as $$
declare saved public.employees%rowtype; normalized_phone text; employee_name text:=nullif(btrim(payload->>'full_name'),'');
  base_salary numeric:=coalesce(nullif(payload->>'base_salary','')::numeric,0);
  housing numeric:=coalesce(nullif(payload->>'housing_allowance','')::numeric,0);
  transport numeric:=coalesce(nullif(payload->>'transport_allowance','')::numeric,0);
  other_pay numeric:=coalesce(nullif(payload->>'other_allowance','')::numeric,0);
begin
  if auth.uid() is null or not public.is_current_profile_active() or not public.employee_admin_allowed() then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if command_id is null then raise exception using errcode='22023',message='Command id is required'; end if;
  select * into saved from public.employees where employees.command_id=create_employee_record.command_id;
  if found then return jsonb_build_object('ok',true,'employee',to_jsonb(saved)); end if;
  if employee_name is null then raise exception using errcode='23514',message='Employee name is required'; end if;
  normalized_phone:=public.normalize_employee_phone(payload->>'phone');
  if normalized_phone is null then raise exception using errcode='23514',message='Valid international WhatsApp number is required'; end if;
  if least(base_salary,housing,transport,other_pay)<0 then raise exception using errcode='23514',message='Employee compensation cannot be negative'; end if;
  insert into public.employees(full_name,phone,job_title,department,department_id,base_salary,housing_allowance,
    transport_allowance,other_allowance,hire_date,status,created_by,command_id)
  values(employee_name,normalized_phone,nullif(btrim(payload->>'job_title'),''),nullif(btrim(payload->>'department'),''),
    nullif(payload->>'department_id','')::uuid,base_salary,housing,transport,other_pay,
    nullif(payload->>'hire_date','')::date,'active',auth.uid(),command_id)
  returning * into saved;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('employees',saved.id::text,'employee_created',auth.uid(),to_jsonb(saved),jsonb_build_object('command_id',command_id));
  return jsonb_build_object('ok',true,'employee',to_jsonb(saved));
end $$;

revoke all on function public.create_employee_record(jsonb,uuid) from public,anon,authenticated;
grant execute on function public.create_employee_record(jsonb,uuid) to authenticated;
revoke insert,update,delete on table public.employees from anon,authenticated;

commit;
