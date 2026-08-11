-- Payroll V2.3 foundation: versioned work schedules and holiday calendar.
-- No salary, overtime or deduction calculations are introduced here.

create extension if not exists btree_gist;
create sequence if not exists public.payroll_calendar_version_seq start 1;

create or replace function public.normalize_department_name(value text)
returns text language sql immutable parallel safe as $$
  select lower(regexp_replace(btrim(coalesce(value, '')), '\s+', ' ', 'g'))
$$;

create or replace function public.current_payroll_calendar_version()
returns bigint language sql stable security definer set search_path = public as $$
  select last_value from public.payroll_calendar_version_seq
$$;

create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(),
  name text not null check (public.normalize_department_name(name) <> ''),
  normalized_name text generated always as (public.normalize_department_name(name)) stored,
  status text not null default 'active' check (status in ('active','inactive')),
  created_by uuid references public.profiles(id) on delete set null default auth.uid(),
  updated_by uuid references public.profiles(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (normalized_name)
);

insert into public.departments(name, created_by, updated_by)
select min(btrim(e.department)), null, null
from public.employees e
where public.normalize_department_name(e.department) <> ''
group by public.normalize_department_name(e.department)
on conflict (normalized_name) do nothing;

alter table public.employees add column if not exists department_id uuid references public.departments(id) on delete set null;
update public.employees e set department_id = d.id
from public.departments d
where e.department_id is null
  and public.normalize_department_name(e.department) <> ''
  and d.normalized_name = public.normalize_department_name(e.department);

create or replace view public.department_migration_report with (security_invoker=true) as
select e.id employee_id, e.full_name, e.department legacy_department,
       case when public.normalize_department_name(e.department) = '' then 'empty_department'
            when e.department_id is null then 'unmatched_after_normalization'
            else 'linked' end migration_status,
       e.department_id
from public.employees e
where public.has_permission('payroll_calendar_manage');

create table if not exists public.work_schedules (
  id uuid primary key default gen_random_uuid(),
  schedule_family_id uuid not null default gen_random_uuid(),
  revision_number integer not null default 1 check (revision_number > 0),
  supersedes_schedule_id uuid references public.work_schedules(id) on delete restrict,
  name text not null check (btrim(name) <> ''),
  scope_type text not null check (scope_type in ('company','department','employee')),
  department_id uuid references public.departments(id) on delete restrict,
  employee_id uuid references public.employees(id) on delete restrict,
  scope_key text generated always as (case scope_type when 'company' then 'company' when 'department' then 'department:' || department_id::text else 'employee:' || employee_id::text end) stored,
  timezone text not null default 'Asia/Riyadh',
  effective_from date not null,
  effective_to date,
  effective_period daterange generated always as (daterange(effective_from, coalesce(effective_to, 'infinity'::date), '[]')) stored,
  status text not null default 'draft' check (status in ('draft','active','superseded','cancelled')),
  confirmed_no_workdays boolean not null default false,
  valid_from_version bigint,
  valid_to_version bigint,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  updated_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  approved_by uuid references public.profiles(id) on delete restrict,
  cancelled_by uuid references public.profiles(id) on delete restrict,
  approved_at timestamptz,
  cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from),
  check ((scope_type='company' and department_id is null and employee_id is null)
      or (scope_type='department' and department_id is not null and employee_id is null)
      or (scope_type='employee' and employee_id is not null and department_id is null)),
  unique (schedule_family_id, revision_number),
  exclude using gist (scope_key with =, effective_period with &&) where (status='active')
);

create table if not exists public.work_schedule_days (
  id uuid primary key default gen_random_uuid(),
  schedule_id uuid not null references public.work_schedules(id) on delete restrict,
  iso_weekday smallint not null check (iso_weekday between 1 and 7),
  is_working_day boolean not null default false,
  required_start_time time,
  required_end_time time,
  spans_next_day boolean not null default false,
  break_minutes integer not null default 0 check (break_minutes >= 0),
  required_minutes integer not null default 0 check (required_minutes >= 0),
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (schedule_id, iso_weekday)
);

create table if not exists public.holiday_calendar (
  id uuid primary key default gen_random_uuid(),
  holiday_id uuid not null default gen_random_uuid(),
  revision_number integer not null default 1 check (revision_number > 0),
  supersedes_revision_id uuid references public.holiday_calendar(id) on delete restrict,
  name text not null check (btrim(name) <> ''),
  start_date date not null, end_date date not null,
  holiday_type text not null check (holiday_type in ('official_holiday','company_holiday','weekly_off_override','half_day','working_day_override')),
  is_paid boolean not null default true,
  half_day_mode text check (half_day_mode in ('first_half','second_half','custom_hours')),
  required_start_time time, required_end_time time,
  spans_next_day boolean not null default false,
  required_minutes integer check (required_minutes >= 0),
  notes text,
  status text not null default 'draft' check (status in ('draft','active','superseded','cancelled')),
  valid_from_version bigint, valid_to_version bigint,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  updated_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  approved_by uuid references public.profiles(id) on delete restrict,
  cancelled_by uuid references public.profiles(id) on delete restrict,
  approved_at timestamptz, cancelled_at timestamptz,
  cancellation_reason text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (end_date >= start_date),
  check ((holiday_type in ('half_day','working_day_override') and required_start_time is not null and required_end_time is not null and required_minutes > 0)
      or (holiday_type not in ('half_day','working_day_override') and half_day_mode is null and required_start_time is null and required_end_time is null and required_minutes is null)),
  check (holiday_type <> 'half_day' or half_day_mode is not null),
  unique (holiday_id, revision_number)
);

create table if not exists public.holiday_scopes (
  id uuid primary key default gen_random_uuid(),
  holiday_revision_id uuid not null references public.holiday_calendar(id) on delete restrict,
  scope_type text not null check (scope_type in ('company','department','employee')),
  department_id uuid references public.departments(id) on delete restrict,
  employee_id uuid references public.employees(id) on delete restrict,
  scope_key text generated always as (case scope_type when 'company' then 'company' when 'department' then 'department:' || department_id::text else 'employee:' || employee_id::text end) stored,
  start_date date not null, end_date date not null,
  effective_period daterange generated always as (daterange(start_date, end_date, '[]')) stored,
  calendar_status text not null default 'draft' check (calendar_status in ('draft','active','superseded','cancelled')),
  valid_from_version bigint, valid_to_version bigint,
  created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_date >= start_date),
  check ((scope_type='company' and department_id is null and employee_id is null)
      or (scope_type='department' and department_id is not null and employee_id is null)
      or (scope_type='employee' and employee_id is not null and department_id is null)),
  exclude using gist (scope_key with =, effective_period with &&) where (calendar_status='active')
);

alter table public.payroll add column if not exists calendar_version bigint;
alter table public.payroll add column if not exists calendar_stale boolean not null default false;
alter table public.payroll add column if not exists calendar_recalculated_by uuid references public.profiles(id) on delete set null;
alter table public.payroll add column if not exists calendar_recalculated_at timestamptz;
alter table public.payroll add column if not exists calendar_stale_acknowledged_by uuid references public.profiles(id) on delete set null;
alter table public.payroll add column if not exists calendar_stale_acknowledged_at timestamptz;
update public.payroll set calendar_version = public.current_payroll_calendar_version() where calendar_version is null;
alter table public.payroll alter column calendar_version set default public.current_payroll_calendar_version();
alter table public.payroll alter column calendar_version set not null;

create or replace function public.calendar_shift_minutes(start_value time, end_value time, next_day boolean)
returns integer language sql immutable parallel safe as $$
 select case when start_value is null or end_value is null then 0 else
   (extract(epoch from (end_value - start_value))/60)::integer + case when next_day then 1440 else 0 end end
$$;

create or replace function public.validate_calendar_record()
returns trigger language plpgsql set search_path = public, pg_temp as $$
declare shift_minutes integer;
begin
  if tg_table_name = 'work_schedules' then
    if not exists(select 1 from pg_timezone_names where name = new.timezone) then raise exception 'Invalid IANA timezone'; end if;
  elsif tg_table_name = 'work_schedule_days' then
    if new.is_working_day then
      if new.required_start_time is null or new.required_end_time is null then raise exception 'Working day requires start and end time'; end if;
      if new.required_end_time <= new.required_start_time and not new.spans_next_day then raise exception 'Overnight shift must set spans_next_day'; end if;
      if new.required_end_time > new.required_start_time and new.spans_next_day then raise exception 'spans_next_day does not match shift times'; end if;
      shift_minutes := public.calendar_shift_minutes(new.required_start_time,new.required_end_time,new.spans_next_day);
      if shift_minutes <= 0 or new.break_minutes >= shift_minutes then raise exception 'Break must be shorter than shift'; end if;
      if new.required_minutes <= 0 or new.required_minutes > shift_minutes-new.break_minutes then raise exception 'required_minutes exceeds net shift duration'; end if;
    elsif new.required_start_time is not null or new.required_end_time is not null or new.break_minutes <> 0 or new.required_minutes <> 0 then
      raise exception 'Non-working day cannot contain working hours';
    end if;
  elsif tg_table_name = 'holiday_calendar' and new.holiday_type in ('half_day','working_day_override') then
    if new.required_end_time <= new.required_start_time and not new.spans_next_day then raise exception 'Overnight interval must set spans_next_day'; end if;
    shift_minutes := public.calendar_shift_minutes(new.required_start_time,new.required_end_time,new.spans_next_day);
    if shift_minutes <= 0 or new.required_minutes > shift_minutes then raise exception 'required_minutes exceeds holiday interval'; end if;
  end if;
  return new;
end $$;

create trigger validate_work_schedule before insert or update on public.work_schedules for each row execute function public.validate_calendar_record();
create trigger validate_work_schedule_day before insert or update on public.work_schedule_days for each row execute function public.validate_calendar_record();
create trigger validate_holiday_revision before insert or update on public.holiday_calendar for each row execute function public.validate_calendar_record();

create or replace function public.protect_calendar_history()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
  if tg_op='DELETE' then raise exception 'Calendar records are immutable and cannot be deleted'; end if;
  if old.status in ('active','superseded','cancelled') and current_setting('app.calendar_workflow',true) <> 'on' then
    raise exception 'Approved calendar revisions are immutable; create a new revision';
  end if;
  return new;
end $$;
create trigger protect_work_schedule_history before update or delete on public.work_schedules for each row execute function public.protect_calendar_history();
create trigger protect_holiday_history before update or delete on public.holiday_calendar for each row execute function public.protect_calendar_history();

create or replace function public.mark_payroll_calendar_stale(change_start date, change_end date, new_version bigint)
returns void language sql security definer set search_path=public,pg_temp as $$
 update public.payroll set calendar_stale=true
 where status='draft' and calendar_version < new_version
   and payroll_month <= change_end and (payroll_month + interval '1 month - 1 day')::date >= change_start
$$;

create or replace function public.calendar_can_approve(creator uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select public.has_permission('payroll_calendar_approve')
   and (public.current_identity_role() in ('owner','manager') or creator <> auth.uid())
$$;

-- JSON RPC keeps the REST surface narrow and validates scope server-side.
create or replace function public.save_holiday_draft(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare old_row public.holiday_calendar%rowtype; new_row public.holiday_calendar%rowtype; rev integer:=1; family uuid:=gen_random_uuid(); s jsonb;
begin
 if not public.has_permission('payroll_calendar_manage') then raise exception 'Calendar manage permission required'; end if;
 if payload->>'source_revision_id' is not null then
   select * into old_row from public.holiday_calendar where id=(payload->>'source_revision_id')::uuid;
   if old_row.id is null then raise exception 'Source holiday revision not found'; end if;
   family:=old_row.holiday_id; select coalesce(max(revision_number),0)+1 into rev from public.holiday_calendar where holiday_id=family;
 end if;
 insert into public.holiday_calendar(holiday_id,revision_number,supersedes_revision_id,name,start_date,end_date,holiday_type,is_paid,half_day_mode,required_start_time,required_end_time,spans_next_day,required_minutes,notes,created_by,updated_by)
 values(family,rev,old_row.id,btrim(payload->>'name'),(payload->>'start_date')::date,(payload->>'end_date')::date,payload->>'holiday_type',coalesce((payload->>'is_paid')::boolean,true),nullif(payload->>'half_day_mode',''),nullif(payload->>'required_start_time','')::time,nullif(payload->>'required_end_time','')::time,coalesce((payload->>'spans_next_day')::boolean,false),nullif(payload->>'required_minutes','')::int,payload->>'notes',auth.uid(),auth.uid()) returning * into new_row;
 for s in select * from jsonb_array_elements(coalesce(payload->'scopes','[]'::jsonb)) loop
   insert into public.holiday_scopes(holiday_revision_id,scope_type,department_id,employee_id,start_date,end_date,created_by)
   values(new_row.id,s->>'scope_type',nullif(s->>'department_id','')::uuid,nullif(s->>'employee_id','')::uuid,new_row.start_date,new_row.end_date,auth.uid());
 end loop;
 if not exists(select 1 from public.holiday_scopes where holiday_revision_id=new_row.id) then raise exception 'At least one holiday scope is required'; end if;
 return jsonb_build_object('ok',true,'revision',to_jsonb(new_row));
end $$;

create or replace function public.approve_holiday_revision(revision_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.holiday_calendar%rowtype; v bigint;
begin
 select * into r from public.holiday_calendar where id=revision_id for update;
 if r.id is null or r.status <> 'draft' then raise exception 'A draft revision is required'; end if;
 if not public.calendar_can_approve(r.created_by) then raise exception 'Maker-checker approval required'; end if;
 v:=nextval('public.payroll_calendar_version_seq'); perform set_config('app.calendar_workflow','on',true);
 update public.holiday_calendar set status='superseded',valid_to_version=v,updated_at=now(),updated_by=auth.uid() where holiday_id=r.holiday_id and status='active';
 update public.holiday_scopes set calendar_status='superseded',valid_to_version=v where holiday_revision_id in (select id from public.holiday_calendar where holiday_id=r.holiday_id and status='superseded' and valid_to_version=v);
 update public.holiday_calendar set status='active',valid_from_version=v,approved_by=auth.uid(),approved_at=now(),updated_at=now(),updated_by=auth.uid() where id=r.id;
 update public.holiday_scopes set calendar_status='active',valid_from_version=v where holiday_revision_id=r.id;
 perform public.mark_payroll_calendar_stale(r.start_date,r.end_date,v);
 return jsonb_build_object('ok',true,'calendar_version',v,'revision_id',r.id);
end $$;

create or replace function public.cancel_holiday_revision(revision_id uuid, reason text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.holiday_calendar%rowtype; v bigint;
begin
 if not public.has_permission('payroll_calendar_approve') then raise exception 'Calendar approval permission required'; end if;
 if btrim(coalesce(reason,''))='' then raise exception 'Cancellation reason is required'; end if;
 select * into r from public.holiday_calendar where id=revision_id and status='active' for update;
 if r.id is null then raise exception 'Active holiday revision not found'; end if;
 v:=nextval('public.payroll_calendar_version_seq'); perform set_config('app.calendar_workflow','on',true);
 update public.holiday_calendar set status='cancelled',valid_to_version=v,cancelled_by=auth.uid(),cancelled_at=now(),cancellation_reason=btrim(reason),updated_by=auth.uid(),updated_at=now() where id=r.id;
 update public.holiday_scopes set calendar_status='cancelled',valid_to_version=v where holiday_revision_id=r.id;
 perform public.mark_payroll_calendar_stale(r.start_date,r.end_date,v);
 return jsonb_build_object('ok',true,'calendar_version',v);
end $$;

create or replace function public.save_work_schedule_draft(payload jsonb)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare old_row public.work_schedules%rowtype; new_row public.work_schedules%rowtype; rev int:=1; family uuid:=gen_random_uuid(); d jsonb; working_count int:=0;
begin
 if not public.has_permission('payroll_calendar_manage') then raise exception 'Calendar manage permission required'; end if;
 if payload->>'source_schedule_id' is not null then select * into old_row from public.work_schedules where id=(payload->>'source_schedule_id')::uuid; family:=old_row.schedule_family_id; select coalesce(max(revision_number),0)+1 into rev from public.work_schedules where schedule_family_id=family; end if;
 insert into public.work_schedules(schedule_family_id,revision_number,supersedes_schedule_id,name,scope_type,department_id,employee_id,timezone,effective_from,effective_to,confirmed_no_workdays,created_by,updated_by)
 values(family,rev,old_row.id,btrim(payload->>'name'),payload->>'scope_type',nullif(payload->>'department_id','')::uuid,nullif(payload->>'employee_id','')::uuid,coalesce(nullif(payload->>'timezone',''),'Asia/Riyadh'),(payload->>'effective_from')::date,nullif(payload->>'effective_to','')::date,coalesce((payload->>'confirmed_no_workdays')::boolean,false),auth.uid(),auth.uid()) returning * into new_row;
 for d in select * from jsonb_array_elements(coalesce(payload->'days','[]'::jsonb)) loop
   if coalesce((d->>'is_working_day')::boolean,false) then working_count:=working_count+1; end if;
   insert into public.work_schedule_days(schedule_id,iso_weekday,is_working_day,required_start_time,required_end_time,spans_next_day,break_minutes,required_minutes)
   values(new_row.id,(d->>'iso_weekday')::int,coalesce((d->>'is_working_day')::boolean,false),nullif(d->>'required_start_time','')::time,nullif(d->>'required_end_time','')::time,coalesce((d->>'spans_next_day')::boolean,false),coalesce((d->>'break_minutes')::int,0),coalesce((d->>'required_minutes')::int,0));
 end loop;
 if working_count=0 and not new_row.confirmed_no_workdays then raise exception 'A schedule without working days requires explicit confirmation'; end if;
 return jsonb_build_object('ok',true,'schedule',to_jsonb(new_row));
end $$;

create or replace function public.approve_work_schedule(schedule_revision_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.work_schedules%rowtype; v bigint;
begin
 select * into r from public.work_schedules where id=schedule_revision_id for update;
 if r.id is null or r.status<>'draft' then raise exception 'A draft schedule is required'; end if;
 if not public.calendar_can_approve(r.created_by) then raise exception 'Maker-checker approval required'; end if;
 v:=nextval('public.payroll_calendar_version_seq'); perform set_config('app.calendar_workflow','on',true);
 update public.work_schedules set status='superseded',valid_to_version=v,updated_by=auth.uid(),updated_at=now() where schedule_family_id=r.schedule_family_id and status='active';
 update public.work_schedules set status='active',valid_from_version=v,approved_by=auth.uid(),approved_at=now(),updated_by=auth.uid(),updated_at=now() where id=r.id;
 perform public.mark_payroll_calendar_stale(r.effective_from,coalesce(r.effective_to,'9999-12-31'),v);
 return jsonb_build_object('ok',true,'calendar_version',v,'schedule_id',r.id);
end $$;

create or replace function public.resolve_work_calendar(target_employee uuid, date_from date, date_to date, as_of_version bigint default null)
returns table(work_date date,calendar_version bigint,resolved_scope text,schedule_id uuid,holiday_id uuid,holiday_revision_id uuid,resolution_reason text,required_start_time time,required_end_time time,required_minutes integer,is_paid_holiday boolean,is_unpaid_holiday boolean,worked_on_holiday_eligible boolean,overridden_events jsonb)
language sql stable security definer set search_path=public,pg_temp as $$
with args as (select coalesce(as_of_version,public.current_payroll_calendar_version()) v where public.has_permission('payroll_calendar_view')), emp as (select e.id,e.department_id from public.employees e where e.id=target_employee), days as (select d::date work_date from generate_series(date_from,date_to,'1 day') d),
base as (select days.work_date,s.id schedule_id,s.scope_type,wd.is_working_day,wd.required_start_time,wd.required_end_time,wd.required_minutes,
 row_number() over(partition by days.work_date order by case s.scope_type when 'employee' then 3 when 'department' then 2 else 1 end desc,s.revision_number desc) rn
 from days cross join emp cross join args join public.work_schedules s on days.work_date <@ s.effective_period and s.valid_from_version<=args.v and (s.valid_to_version is null or s.valid_to_version>args.v) and (s.scope_type='company' or s.scope_type='department' and s.department_id=emp.department_id or s.scope_type='employee' and s.employee_id=emp.id)
 left join public.work_schedule_days wd on wd.schedule_id=s.id and wd.iso_weekday=extract(isodow from days.work_date)),
events as (select days.work_date,h.id revision_id,h.holiday_id,h.holiday_type,h.is_paid,h.required_start_time,h.required_end_time,h.required_minutes,sc.scope_type,
 case sc.scope_type when 'employee' then 3 when 'department' then 2 else 1 end priority
 from days cross join emp cross join args join public.holiday_scopes sc on days.work_date <@ sc.effective_period and sc.valid_from_version<=args.v and (sc.valid_to_version is null or sc.valid_to_version>args.v) and (sc.scope_type='company' or sc.scope_type='department' and sc.department_id=emp.department_id or sc.scope_type='employee' and sc.employee_id=emp.id)
 join public.holiday_calendar h on h.id=sc.holiday_revision_id),
winner as (select *,row_number() over(partition by work_date order by priority desc) rn from events),
overridden as (select work_date,jsonb_agg(jsonb_build_object('holiday_revision_id',revision_id,'holiday_type',holiday_type,'scope',scope_type) order by priority desc) filter(where rn>1) items from winner group by work_date)
select d.work_date,a.v,w.scope_type,b.schedule_id,w.holiday_id,w.revision_id,
 case when w.holiday_type='working_day_override' then 'working_day_override' when w.holiday_type='half_day' then 'half_day' when w.holiday_type is not null then w.holiday_type when coalesce(b.is_working_day,false) then 'scheduled_workday' else 'weekly_rest_day' end,
 case when w.holiday_type in ('half_day','working_day_override') then w.required_start_time when w.holiday_type is null then b.required_start_time end,
 case when w.holiday_type in ('half_day','working_day_override') then w.required_end_time when w.holiday_type is null then b.required_end_time end,
 case when w.holiday_type in ('half_day','working_day_override') then w.required_minutes when w.holiday_type is null then coalesce(b.required_minutes,0) else 0 end,
 coalesce(w.is_paid and w.holiday_type not in ('working_day_override'),false),coalesce(not w.is_paid and w.holiday_type not in ('working_day_override'),false),
 coalesce(w.holiday_type in ('official_holiday','company_holiday','weekly_off_override'),false),coalesce(o.items,'[]'::jsonb)
from days d cross join args a left join base b on b.work_date=d.work_date and b.rn=1 left join winner w on w.work_date=d.work_date and w.rn=1 left join overridden o on o.work_date=d.work_date order by d.work_date
$$;

create or replace function public.mark_payroll_calendar_recalculated(payroll_id uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v bigint:=public.current_payroll_calendar_version();
begin
 if not public.has_permission('payroll_edit') then raise exception 'Payroll edit permission required'; end if;
 update public.payroll set calendar_version=v,calendar_stale=false,calendar_recalculated_by=auth.uid(),calendar_recalculated_at=now(),calendar_stale_acknowledged_by=null,calendar_stale_acknowledged_at=null where id=payroll_id and status='draft';
 if not found then raise exception 'Draft payroll not found'; end if;
 return jsonb_build_object('ok',true,'calendar_version',v);
end $$;

create or replace function public.protect_stale_payroll_approval()
returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if new.status='approved' and old.status is distinct from 'approved' and old.calendar_stale then
   if not public.has_permission('payroll_calendar_stale_override') or new.calendar_stale_acknowledged_by is distinct from auth.uid() then raise exception 'Payroll calendar is stale; recalculate before approval'; end if;
   new.calendar_stale_acknowledged_at:=now();
 end if; return new;
end $$;
create trigger protect_stale_payroll_approval before update on public.payroll for each row execute function public.protect_stale_payroll_approval();

alter table public.departments enable row level security;
alter table public.work_schedules enable row level security;
alter table public.work_schedule_days enable row level security;
alter table public.holiday_calendar enable row level security;
alter table public.holiday_scopes enable row level security;
create policy departments_calendar_select on public.departments for select to authenticated using (public.has_permission('payroll_calendar_view'));
create policy schedules_calendar_select on public.work_schedules for select to authenticated using (public.has_permission('payroll_calendar_view'));
create policy schedule_days_calendar_select on public.work_schedule_days for select to authenticated using (public.has_permission('payroll_calendar_view'));
create policy holidays_calendar_select on public.holiday_calendar for select to authenticated using (public.has_permission('payroll_calendar_view'));
create policy holiday_scopes_calendar_select on public.holiday_scopes for select to authenticated using (public.has_permission('payroll_calendar_view'));
-- No client write policies: all mutations pass through the audited SECURITY DEFINER workflow RPCs.

grant select on public.department_migration_report to authenticated;
grant select on public.departments, public.work_schedules, public.work_schedule_days, public.holiday_calendar, public.holiday_scopes to authenticated;
revoke all on function public.mark_payroll_calendar_stale(date,date,bigint) from public, anon, authenticated;
revoke all on function public.calendar_can_approve(uuid) from public, anon, authenticated;
revoke all on function public.protect_calendar_history() from public, anon, authenticated;
revoke all on function public.validate_calendar_record() from public, anon, authenticated;
revoke all on function public.save_holiday_draft(jsonb) from public, anon;
revoke all on function public.approve_holiday_revision(uuid) from public, anon;
revoke all on function public.cancel_holiday_revision(uuid,text) from public, anon;
revoke all on function public.save_work_schedule_draft(jsonb) from public, anon;
revoke all on function public.approve_work_schedule(uuid) from public, anon;
revoke all on function public.resolve_work_calendar(uuid,date,date,bigint) from public, anon;
revoke all on function public.mark_payroll_calendar_recalculated(uuid) from public, anon;
grant execute on function public.current_payroll_calendar_version() to authenticated;
grant execute on function public.save_holiday_draft(jsonb) to authenticated;
grant execute on function public.approve_holiday_revision(uuid) to authenticated;
grant execute on function public.cancel_holiday_revision(uuid,text) to authenticated;
grant execute on function public.save_work_schedule_draft(jsonb) to authenticated;
grant execute on function public.approve_work_schedule(uuid) to authenticated;
grant execute on function public.resolve_work_calendar(uuid,date,date,bigint) to authenticated;
grant execute on function public.mark_payroll_calendar_recalculated(uuid) to authenticated;

do $$ declare t text; begin
 foreach t in array array['departments','work_schedules','work_schedule_days','holiday_calendar','holiday_scopes'] loop
   execute format('drop trigger if exists audit_%I on public.%I',t,t);
   execute format('create trigger audit_%I after insert or update or delete on public.%I for each row execute function public.audit_row_change()',t,t);
 end loop;
end $$;

do $$ begin
 alter publication supabase_realtime add table public.departments;
 alter publication supabase_realtime add table public.work_schedules;
 alter publication supabase_realtime add table public.work_schedule_days;
 alter publication supabase_realtime add table public.holiday_calendar;
 alter publication supabase_realtime add table public.holiday_scopes;
exception when duplicate_object then null; end $$;
