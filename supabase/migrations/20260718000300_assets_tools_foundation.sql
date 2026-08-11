-- Assets & Tools Management — phase 1.
-- asset_movements is the accounting source of truth. Balances on assets are caches only.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create sequence if not exists public.asset_code_seq start 1000;

create table public.asset_categories(
 id uuid primary key default gen_random_uuid(), name text not null, normalized_name text generated always as (lower(regexp_replace(btrim(name),'\s+',' ','g'))) stored,
 is_active boolean not null default true, is_default boolean not null default false,
 created_by uuid references public.profiles(id) on delete set null default auth.uid(), updated_by uuid references public.profiles(id) on delete set null default auth.uid(),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(normalized_name)
);
insert into public.asset_categories(name,is_default,created_by,updated_by) values
 ('نجارة',true,null,null),('كهرباء',true,null,null),('دهانات',true,null,null),('تركيب',true,null,null),('IT',true,null,null),('إدارة',true,null,null),('نقل',true,null,null),('سلامة',true,null,null)
on conflict(normalized_name) do nothing;

create table public.asset_locations(
 id uuid primary key default gen_random_uuid(), name text not null check(btrim(name)<>''), location_type text not null check(location_type in ('factory','warehouse','shelf','project','external','quarantine')),
 parent_id uuid references public.asset_locations(id) on delete restrict, project_id uuid references public.projects(id) on delete restrict,
 is_active boolean not null default true, notes text,
 created_by uuid references public.profiles(id) on delete set null default auth.uid(), updated_by uuid references public.profiles(id) on delete set null default auth.uid(),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table public.asset_settings(
 id boolean primary key default true check(id), receiver_confirmation_hours integer not null default 24 check(receiver_confirmation_hours between 1 and 336),
 return_confirmation_hours integer not null default 24 check(return_confirmation_hours between 1 and 336), outside_factory_alert_days integer not null default 14 check(outside_factory_alert_days between 1 and 365),
 warranty_alert_days integer not null default 30 check(warranty_alert_days between 1 and 365), whatsapp_template text not null default 'لديك عهدة من NEXTEP تحتاج تأكيد الاستلام: {{url}}',
 updated_by uuid references public.profiles(id) on delete set null, updated_at timestamptz not null default now()
);
insert into public.asset_settings(id) values(true) on conflict(id) do nothing;

create table public.assets(
 id uuid primary key default gen_random_uuid(), asset_code text not null default ('AST-'||lpad(nextval('public.asset_code_seq')::text,6,'0')),
 name text not null check(btrim(name)<>''), description text, asset_type text not null check(asset_type in ('tool','equipment','asset','device','key','vehicle','other')),
 category_id uuid not null references public.asset_categories(id) on delete restrict, tracking_mode text not null check(tracking_mode in ('serialized','quantity')),
 brand text, model text, serial_number text, qr_value text, barcode_value text, unit text not null default 'قطعة',
 total_quantity numeric(14,3) not null default 0 check(total_quantity>=0), available_quantity numeric(14,3) not null default 0 check(available_quantity>=0), assigned_quantity numeric(14,3) not null default 0 check(assigned_quantity>=0),
 purchase_date date, purchase_cost numeric(14,2) check(purchase_cost>=0), supplier_id uuid references public.suppliers(id) on delete set null, warranty_until date,
 operational_status text not null default 'working' check(operational_status in ('working','needs_maintenance','under_maintenance','damaged','lost','stolen','retired')),
 availability_status text not null default 'available' check(availability_status in ('available','assigned','partially_assigned','outside_factory','in_factory')),
 current_location_id uuid references public.asset_locations(id) on delete restrict, warehouse text, shelf text, notes text,
 created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(), updated_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check((tracking_mode='serialized' and total_quantity in (0,1)) or tracking_mode='quantity'),
 check(available_quantity+assigned_quantity<=total_quantity), unique(asset_code)
);
create unique index assets_serial_unique on public.assets(lower(serial_number)) where serial_number is not null and btrim(serial_number)<>'';
create unique index assets_qr_unique on public.assets(qr_value) where qr_value is not null and btrim(qr_value)<>'';
create unique index assets_barcode_unique on public.assets(barcode_value) where barcode_value is not null and btrim(barcode_value)<>'';

create table public.asset_assignments(
 id uuid primary key default gen_random_uuid(), assignment_code text not null unique default ('CST-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8))),
 status text not null default 'draft' check(status in ('draft','cancelled','pending_receiver_confirmation','issued','partially_returned','fully_returned','settlement_pending','closed','reversed')),
 receiver_employee_id uuid not null references public.employees(id) on delete restrict, receiver_profile_id uuid references public.profiles(id) on delete set null,
 receiver_name_snapshot text not null, receiver_phone_snapshot text, issued_by uuid references public.profiles(id) on delete restrict,
 project_id uuid references public.projects(id) on delete restrict, department_id uuid references public.departments(id) on delete restrict,
 issue_location_id uuid references public.asset_locations(id) on delete restrict, purpose text not null check(btrim(purpose)<>''), expected_return_at timestamptz, issued_at timestamptz,
 confirmation_token_hash text, confirmation_expires_at timestamptz, confirmation_used_at timestamptz, confirmation_failed_attempts integer not null default 0,
 confirmation_locked_until timestamptz, confirmed_at timestamptz, reversed_at timestamptz, reversal_reason text, notes text,
 created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(), updated_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table public.asset_assignment_items(
 id uuid primary key default gen_random_uuid(), assignment_id uuid not null references public.asset_assignments(id) on delete restrict,
 asset_id uuid not null references public.assets(id) on delete restrict, quantity numeric(14,3) not null check(quantity>0), returned_quantity numeric(14,3) not null default 0 check(returned_quantity>=0),
 settled_quantity numeric(14,3) not null default 0 check(settled_quantity>=0), is_serialized boolean not null, is_active boolean not null default true,
 condition_at_issue text not null default 'working', notes text, created_at timestamptz not null default now(),
 check(returned_quantity+settled_quantity<=quantity), unique(assignment_id,asset_id)
);
create unique index one_active_assignment_per_serialized_asset on public.asset_assignment_items(asset_id) where is_serialized and is_active;

create table public.asset_return_events(
 id uuid primary key default gen_random_uuid(), assignment_id uuid not null references public.asset_assignments(id) on delete restrict,
 status text not null default 'pending_receiver_confirmation' check(status in ('pending_receiver_confirmation','confirmed','expired','disputed')),
 received_by uuid not null references public.profiles(id) on delete restrict default auth.uid(), received_at timestamptz not null default now(), notes text,
 confirmation_token_hash text not null, confirmation_expires_at timestamptz not null, confirmation_used_at timestamptz,
 confirmation_failed_attempts integer not null default 0, confirmation_locked_until timestamptz, confirmed_at timestamptz,
 created_at timestamptz not null default now()
);
create table public.asset_return_items(
 id uuid primary key default gen_random_uuid(), return_event_id uuid not null references public.asset_return_events(id) on delete restrict,
 assignment_item_id uuid not null references public.asset_assignment_items(id) on delete restrict, quantity numeric(14,3) not null check(quantity>0),
 condition_at_return text not null check(condition_at_return in ('working','needs_maintenance','damaged','lost','stolen')),
 shortage_quantity numeric(14,3) not null default 0 check(shortage_quantity>=0), notes text, created_at timestamptz not null default now(),
 check(shortage_quantity<=quantity), unique(return_event_id,assignment_item_id)
);

create table public.asset_settlements(
 id uuid primary key default gen_random_uuid(), assignment_item_id uuid not null references public.asset_assignment_items(id) on delete restrict,
 settlement_type text not null check(settlement_type in ('lost','stolen','damaged','not_returned','written_off')), quantity numeric(14,3) not null check(quantity>0),
 status text not null default 'pending_approval' check(status in ('pending_approval','approved','rejected')), reason text not null check(btrim(reason)<>''), notes text,
 estimated_loss numeric(14,2) check(estimated_loss>=0), created_by uuid not null references public.profiles(id) on delete restrict default auth.uid(),
 approved_by uuid references public.profiles(id) on delete restrict, approved_at timestamptz, rejected_by uuid references public.profiles(id) on delete restrict, rejected_at timestamptz,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table public.asset_movements(
 id uuid primary key default gen_random_uuid(), asset_id uuid not null references public.assets(id) on delete restrict,
 movement_type text not null check(movement_type in ('created','transferred','issued','confirmed','partially_returned','returned','maintenance_started','maintenance_completed','lost','stolen','damaged','retired','adjusted','reversed')),
 quantity numeric(14,3) not null check(quantity>=0), total_delta numeric(14,3) not null default 0, available_delta numeric(14,3) not null default 0, assigned_delta numeric(14,3) not null default 0,
 assignment_id uuid references public.asset_assignments(id) on delete restrict, return_event_id uuid references public.asset_return_events(id) on delete restrict,
 settlement_id uuid references public.asset_settlements(id) on delete restrict, from_location_id uuid references public.asset_locations(id) on delete restrict, to_location_id uuid references public.asset_locations(id) on delete restrict,
 reason text, metadata jsonb not null default '{}'::jsonb, actor_id uuid references public.profiles(id) on delete set null default auth.uid(), created_at timestamptz not null default now()
);

create table public.asset_attachments(
 id uuid primary key default gen_random_uuid(), asset_id uuid references public.assets(id) on delete restrict, assignment_id uuid references public.asset_assignments(id) on delete restrict,
 return_event_id uuid references public.asset_return_events(id) on delete restrict, settlement_id uuid references public.asset_settlements(id) on delete restrict,
 file_name text not null, file_path text not null, file_type text, file_size bigint check(file_size>=0), bucket_name text not null default 'asset-attachments',
 uploaded_by uuid references public.profiles(id) on delete set null default auth.uid(), created_at timestamptz not null default now(),
 check(num_nonnulls(asset_id,assignment_id,return_event_id,settlement_id)=1)
);

create or replace function public.asset_refresh_availability(a public.assets) returns text language sql immutable as $$
 select case when a.assigned_quantity=0 then 'available' when a.available_quantity=0 then 'assigned' else 'partially_assigned' end
$$;
create or replace function public.apply_asset_movement_balance() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype; nt numeric; na numeric; ns numeric;
begin
 select * into a from public.assets where id=new.asset_id for update;
 nt:=a.total_quantity+new.total_delta; na:=a.available_quantity+new.available_delta; ns:=a.assigned_quantity+new.assigned_delta;
 if nt<0 or na<0 or ns<0 or na+ns>nt then raise exception 'Asset ledger movement would create an invalid balance'; end if;
 perform set_config('app.asset_balance_update','on',true);
 update public.assets set total_quantity=nt,available_quantity=na,assigned_quantity=ns,
 availability_status=case when ns=0 then 'available' when na=0 then 'assigned' else 'partially_assigned' end,updated_at=now(),updated_by=coalesce(auth.uid(),updated_by) where id=new.asset_id;
 return new;
end $$;
create trigger asset_movement_apply_balance after insert on public.asset_movements for each row execute function public.apply_asset_movement_balance();

create or replace function public.protect_asset_integrity() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if tg_op='DELETE' then raise exception 'Assets cannot be deleted; retire them'; end if;
 if new.tracking_mode is distinct from old.tracking_mode and exists(select 1 from public.asset_movements where asset_id=old.id) then raise exception 'tracking_mode cannot change after movements exist'; end if;
 if (new.total_quantity is distinct from old.total_quantity or new.available_quantity is distinct from old.available_quantity or new.assigned_quantity is distinct from old.assigned_quantity) and current_setting('app.asset_balance_update',true)<>'on' then raise exception 'Cached balances may only be changed by ledger movements'; end if;
 return new;
end $$;
create trigger protect_assets before update or delete on public.assets for each row execute function public.protect_asset_integrity();
create or replace function public.immutable_asset_ledger() returns trigger language plpgsql as $$ begin raise exception 'Asset movement ledger is immutable'; end $$;
create trigger immutable_asset_movements before update or delete on public.asset_movements for each row execute function public.immutable_asset_ledger();
create or replace function public.protect_assignment_state() returns trigger language plpgsql as $$
begin if old.status not in ('draft') and new.status='cancelled' then raise exception 'Issued or reserved assignments require documented reversal movements'; end if; return new; end $$;
create trigger protect_assignment_state before update on public.asset_assignments for each row execute function public.protect_assignment_state();

-- Production may receive only the explicitly granted safe asset permissions.
create or replace function public.has_permission(permission_name text) returns boolean language sql stable security definer set search_path=public as $$
 select case public.current_identity_role()
  when 'owner' then true when 'manager' then true
  when 'production' then permission_name=any(array['assets_view','assets_issue','assets_return']) and coalesce((select (permissions->>permission_name)::boolean from public.profiles where id=auth.uid() and status='active'),false)
  when 'accountant' then coalesce((select (permissions->>permission_name)::boolean from public.profiles where id=auth.uid() and status='active'),false)
    or permission_name=any(array['projects_view','projects_create','project_financials_view','project_files_view','project_files_upload','payroll_view','payroll_create','payroll_edit','payroll_mark_paid','daily_labor_view','daily_labor_create','daily_labor_edit','daily_labor_pay'])
  else false end
$$;

create or replace function public.create_asset(payload jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype; qty numeric:=coalesce((payload->>'quantity')::numeric,1); qr text:=coalesce(nullif(payload->>'qr_value',''),'NXT-A-'||upper(encode(extensions.gen_random_bytes(8),'hex')));
begin
 if not public.has_permission('assets_manage') then raise exception 'assets_manage permission required'; end if;
 if payload->>'tracking_mode'='serialized' then qty:=1; end if;
 insert into public.assets(name,description,asset_type,category_id,tracking_mode,brand,model,serial_number,qr_value,barcode_value,unit,purchase_date,purchase_cost,supplier_id,warranty_until,operational_status,current_location_id,warehouse,shelf,notes,created_by,updated_by)
 values(btrim(payload->>'name'),payload->>'description',payload->>'asset_type',(payload->>'category_id')::uuid,payload->>'tracking_mode',payload->>'brand',payload->>'model',nullif(payload->>'serial_number',''),qr,nullif(payload->>'barcode_value',''),coalesce(nullif(payload->>'unit',''),'قطعة'),nullif(payload->>'purchase_date','')::date,nullif(payload->>'purchase_cost','')::numeric,nullif(payload->>'supplier_id','')::uuid,nullif(payload->>'warranty_until','')::date,coalesce(nullif(payload->>'operational_status',''),'working'),nullif(payload->>'current_location_id','')::uuid,payload->>'warehouse',payload->>'shelf',payload->>'notes',auth.uid(),auth.uid()) returning * into a;
 insert into public.asset_movements(asset_id,movement_type,quantity,total_delta,available_delta,to_location_id,reason) values(a.id,'created',qty,qty,qty,a.current_location_id,'Initial registry balance');
 select * into a from public.assets where id=a.id; return jsonb_build_object('ok',true,'asset',to_jsonb(a));
end $$;

create or replace function public.adjust_asset_quantity(target_asset_id uuid, quantity_delta numeric, adjustment_reason text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype;
begin
 if not public.has_permission('assets_adjust') then raise exception 'assets_adjust permission required'; end if;
 if quantity_delta=0 or btrim(coalesce(adjustment_reason,''))='' then raise exception 'A non-zero adjustment and reason are required'; end if;
 select * into a from public.assets where id=target_asset_id for update;
 if a.tracking_mode='serialized' then raise exception 'Serialized assets cannot be quantity-adjusted'; end if;
 if quantity_delta<0 and a.available_quantity<abs(quantity_delta) then raise exception 'Cannot reduce below assigned or pending quantities'; end if;
 insert into public.asset_movements(asset_id,movement_type,quantity,total_delta,available_delta,reason) values(a.id,'adjusted',abs(quantity_delta),quantity_delta,quantity_delta,adjustment_reason);
 return jsonb_build_object('ok',true);
end $$;

create or replace function public.issue_asset_assignment(payload jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare ass public.asset_assignments%rowtype; emp public.employees%rowtype; item jsonb; a public.assets%rowtype; qty numeric; secret text:=encode(extensions.gen_random_bytes(24),'hex'); hours int;
begin
 if not public.has_permission('assets_issue') then raise exception 'assets_issue permission required'; end if;
 select receiver_confirmation_hours into hours from public.asset_settings where id=true;
 select * into emp from public.employees where id=(payload->>'receiver_employee_id')::uuid;
 if emp.id is null then raise exception 'Receiver not found'; end if;
 insert into public.asset_assignments(status,receiver_employee_id,receiver_profile_id,receiver_name_snapshot,receiver_phone_snapshot,issued_by,project_id,department_id,issue_location_id,purpose,expected_return_at,issued_at,confirmation_token_hash,confirmation_expires_at,notes,created_by,updated_by)
 values('pending_receiver_confirmation',emp.id,nullif(payload->>'receiver_profile_id','')::uuid,emp.full_name,emp.phone,auth.uid(),nullif(payload->>'project_id','')::uuid,nullif(payload->>'department_id','')::uuid,nullif(payload->>'issue_location_id','')::uuid,btrim(payload->>'purpose'),nullif(payload->>'expected_return_at','')::timestamptz,now(),encode(extensions.digest(secret,'sha256'),'hex'),now()+make_interval(hours=>hours),payload->>'notes',auth.uid(),auth.uid()) returning * into ass;
 for item in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
  qty:=(item->>'quantity')::numeric; select * into a from public.assets where id=(item->>'asset_id')::uuid for update;
  if a.id is null or a.operational_status<>'working' then raise exception 'Only working assets can be issued'; end if;
  if a.tracking_mode='serialized' and qty<>1 then raise exception 'Serialized asset quantity must be one'; end if;
  if qty<=0 or a.available_quantity<qty then raise exception 'Requested quantity exceeds available ledger balance'; end if;
  insert into public.asset_assignment_items(assignment_id,asset_id,quantity,is_serialized,condition_at_issue,notes) values(ass.id,a.id,qty,a.tracking_mode='serialized',a.operational_status,item->>'notes');
  insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,from_location_id,to_location_id,reason) values(a.id,'issued',qty,-qty,qty,ass.id,a.current_location_id,ass.issue_location_id,ass.purpose);
 end loop;
 if not exists(select 1 from public.asset_assignment_items where assignment_id=ass.id) then raise exception 'At least one assignment item is required'; end if;
 return jsonb_build_object('ok',true,'assignment_id',ass.id,'assignment_code',ass.assignment_code,'confirmation_token',ass.id::text||'.'||secret,'expires_at',ass.confirmation_expires_at);
end $$;

create or replace function public.mask_asset_receiver_name(value text) returns text language sql immutable as $$ select case when value is null then null else split_part(value,' ',1)||' '||left(split_part(value,' ',2),1)||'…' end $$;
create or replace function public.mask_asset_phone(value text) returns text language sql immutable as $$ select case when value is null then null else repeat('•',greatest(length(value)-2,0))||right(value,2) end $$;

create or replace function public.asset_confirmation_preview(target_id uuid, secret text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.asset_assignments%rowtype;
begin
 select * into a from public.asset_assignments where id=target_id for update;
 if a.id is null or a.confirmation_used_at is not null or a.confirmation_expires_at<=now() then return jsonb_build_object('status','expired'); end if;
 if a.confirmation_locked_until>now() then return jsonb_build_object('status','rate_limited'); end if;
 if a.confirmation_token_hash<>encode(extensions.digest(secret,'sha256'),'hex') then
  update public.asset_assignments set confirmation_failed_attempts=confirmation_failed_attempts+1,confirmation_locked_until=case when confirmation_failed_attempts+1>=5 then now()+interval '15 minutes' else null end where id=a.id;
  return jsonb_build_object('status','invalid','attempts_remaining',greatest(4-a.confirmation_failed_attempts,0));
 end if;
 return jsonb_build_object('status','valid','assignment_code',a.assignment_code,'receiver_name',public.mask_asset_receiver_name(a.receiver_name_snapshot),'receiver_phone',public.mask_asset_phone(a.receiver_phone_snapshot),'expires_at',a.confirmation_expires_at,
  'items',(select jsonb_agg(jsonb_build_object('name',s.name,'quantity',i.quantity,'unit',s.unit)) from public.asset_assignment_items i join public.assets s on s.id=i.asset_id where i.assignment_id=a.id));
end $$;

create or replace function public.confirm_asset_assignment(target_id uuid, secret text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p jsonb; a public.asset_assignments%rowtype; i record;
begin
 p:=public.asset_confirmation_preview(target_id,secret); if p->>'status'<>'valid' then return p; end if;
 select * into a from public.asset_assignments where id=target_id for update;
 update public.asset_assignments set status='issued',confirmed_at=now(),confirmation_used_at=now(),confirmation_token_hash=null,updated_at=now() where id=a.id;
 for i in select * from public.asset_assignment_items where assignment_id=a.id loop insert into public.asset_movements(asset_id,movement_type,quantity,assignment_id,reason) values(i.asset_id,'confirmed',i.quantity,a.id,'Receiver confirmed issue'); end loop;
 return jsonb_build_object('status','confirmed','assignment_code',a.assignment_code);
end $$;

create or replace function public.cancel_draft_asset_assignment(target_id uuid, reason text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if not public.has_permission('assets_issue') then raise exception 'assets_issue permission required'; end if;
 update public.asset_assignments set status='cancelled',reversal_reason=btrim(reason),updated_by=auth.uid(),updated_at=now() where id=target_id and status='draft';
 if not found then raise exception 'Only draft assignments can be cancelled directly'; end if; return jsonb_build_object('ok',true);
end $$;

create or replace function public.reverse_asset_assignment(target_id uuid, reason text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare ass public.asset_assignments%rowtype; i record; remaining numeric;
begin
 if not public.has_permission('assets_adjust') or btrim(coalesce(reason,''))='' then raise exception 'assets_adjust and a reason are required'; end if;
 select * into ass from public.asset_assignments where id=target_id and status in ('pending_receiver_confirmation','issued') for update;
 if ass.id is null then raise exception 'Assignment cannot be reversed from its current state'; end if;
 for i in select * from public.asset_assignment_items where assignment_id=ass.id for update loop
  remaining:=i.quantity-i.returned_quantity-i.settled_quantity;
  if remaining>0 then insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,reason) values(i.asset_id,'reversed',remaining,remaining,-remaining,ass.id,reason); end if;
  update public.asset_assignment_items set is_active=false,returned_quantity=returned_quantity+remaining where id=i.id;
 end loop;
 update public.asset_assignments set status='reversed',reversed_at=now(),reversal_reason=reason,updated_by=auth.uid(),updated_at=now() where id=ass.id;
 return jsonb_build_object('ok',true);
end $$;

create or replace function public.create_asset_return(payload jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare ev public.asset_return_events%rowtype; i jsonb; ai public.asset_assignment_items%rowtype; qty numeric; pending numeric; secret text:=encode(extensions.gen_random_bytes(24),'hex'); hours int; ass public.asset_assignments%rowtype;
begin
 if not public.has_permission('assets_return') then raise exception 'assets_return permission required'; end if;
 select return_confirmation_hours into hours from public.asset_settings where id=true;
 select * into ass from public.asset_assignments where id=(payload->>'assignment_id')::uuid and status in ('issued','partially_returned') for update;
 if ass.id is null then raise exception 'Confirmed active assignment required'; end if;
 insert into public.asset_return_events(assignment_id,notes,confirmation_token_hash,confirmation_expires_at) values(ass.id,payload->>'notes',encode(extensions.digest(secret,'sha256'),'hex'),now()+make_interval(hours=>hours)) returning * into ev;
 for i in select * from jsonb_array_elements(coalesce(payload->'items','[]'::jsonb)) loop
  select * into ai from public.asset_assignment_items where id=(i->>'assignment_item_id')::uuid and assignment_id=ass.id for update;
  qty:=(i->>'quantity')::numeric; select coalesce(sum(ri.quantity),0) into pending from public.asset_return_items ri join public.asset_return_events re on re.id=ri.return_event_id where ri.assignment_item_id=ai.id and re.status='pending_receiver_confirmation';
  if qty<=0 or qty>ai.quantity-ai.returned_quantity-ai.settled_quantity-pending then raise exception 'Return quantity exceeds outstanding quantity'; end if;
  insert into public.asset_return_items(return_event_id,assignment_item_id,quantity,condition_at_return,shortage_quantity,notes) values(ev.id,ai.id,qty,i->>'condition_at_return',coalesce((i->>'shortage_quantity')::numeric,0),i->>'notes');
 end loop;
 if not exists(select 1 from public.asset_return_items where return_event_id=ev.id) then raise exception 'At least one return item is required'; end if;
 return jsonb_build_object('ok',true,'return_event_id',ev.id,'confirmation_token',ev.id::text||'.'||secret,'expires_at',ev.confirmation_expires_at);
end $$;

create or replace function public.confirm_asset_return(target_id uuid, secret text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare ev public.asset_return_events%rowtype; ri record; ai public.asset_assignment_items%rowtype; ass public.asset_assignments%rowtype; remaining numeric; all_remaining numeric;
begin
 select * into ev from public.asset_return_events where id=target_id for update;
 if ev.id is null or ev.confirmation_used_at is not null or ev.confirmation_expires_at<=now() then return jsonb_build_object('status','expired'); end if;
 if ev.confirmation_locked_until>now() then return jsonb_build_object('status','rate_limited'); end if;
 if ev.confirmation_token_hash<>encode(extensions.digest(secret,'sha256'),'hex') then update public.asset_return_events set confirmation_failed_attempts=confirmation_failed_attempts+1,confirmation_locked_until=case when confirmation_failed_attempts+1>=5 then now()+interval '15 minutes' end where id=ev.id; return jsonb_build_object('status','invalid'); end if;
 select * into ass from public.asset_assignments where id=ev.assignment_id for update;
 for ri in select r.*,i.asset_id from public.asset_return_items r join public.asset_assignment_items i on i.id=r.assignment_item_id where r.return_event_id=ev.id loop
  select * into ai from public.asset_assignment_items where id=ri.assignment_item_id for update;
  update public.asset_assignment_items set returned_quantity=returned_quantity+ri.quantity,is_active=(returned_quantity+ri.quantity+settled_quantity<quantity) where id=ai.id;
  insert into public.asset_movements(asset_id,movement_type,quantity,available_delta,assigned_delta,assignment_id,return_event_id,reason) values(ri.asset_id,case when ri.quantity<ai.quantity-ai.returned_quantity-ai.settled_quantity then 'partially_returned' else 'returned' end,ri.quantity,case when ri.condition_at_return='working' then ri.quantity else 0 end,-ri.quantity,ass.id,ev.id,'Receiver confirmed return');
  if ri.condition_at_return<>'working' then update public.assets set operational_status=ri.condition_at_return,updated_at=now() where id=ri.asset_id; end if;
 end loop;
 select coalesce(sum(quantity-returned_quantity-settled_quantity),0) into all_remaining from public.asset_assignment_items where assignment_id=ass.id;
 update public.asset_return_events set status='confirmed',confirmed_at=now(),confirmation_used_at=now(),confirmation_token_hash=null where id=ev.id;
 update public.asset_assignments set status=case when all_remaining=0 then 'fully_returned' else 'partially_returned' end,updated_at=now() where id=ass.id;
 return jsonb_build_object('status','confirmed','assignment_status',case when all_remaining=0 then 'fully_returned' else 'partially_returned' end);
end $$;

create or replace function public.asset_return_confirmation_preview(target_id uuid, secret text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare ev public.asset_return_events%rowtype; ass public.asset_assignments%rowtype;
begin
 select * into ev from public.asset_return_events where id=target_id for update;
 if ev.id is null or ev.confirmation_used_at is not null or ev.confirmation_expires_at<=now() then return jsonb_build_object('status','expired'); end if;
 if ev.confirmation_locked_until>now() then return jsonb_build_object('status','rate_limited'); end if;
 if ev.confirmation_token_hash<>encode(extensions.digest(secret,'sha256'),'hex') then update public.asset_return_events set confirmation_failed_attempts=confirmation_failed_attempts+1,confirmation_locked_until=case when confirmation_failed_attempts+1>=5 then now()+interval '15 minutes' end where id=ev.id; return jsonb_build_object('status','invalid','attempts_remaining',greatest(4-ev.confirmation_failed_attempts,0)); end if;
 select * into ass from public.asset_assignments where id=ev.assignment_id;
 return jsonb_build_object('status','valid','assignment_code',ass.assignment_code,'receiver_name',public.mask_asset_receiver_name(ass.receiver_name_snapshot),'receiver_phone',public.mask_asset_phone(ass.receiver_phone_snapshot),'expires_at',ev.confirmation_expires_at,'items',(select jsonb_agg(jsonb_build_object('name',a.name,'quantity',ri.quantity,'unit',a.unit,'condition',ri.condition_at_return)) from public.asset_return_items ri join public.asset_assignment_items ai on ai.id=ri.assignment_item_id join public.assets a on a.id=ai.asset_id where ri.return_event_id=ev.id));
end $$;

create or replace function public.create_asset_settlement(payload jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare ai public.asset_assignment_items%rowtype; qty numeric:=(payload->>'quantity')::numeric; pending numeric; s public.asset_settlements%rowtype;
begin
 if not public.has_permission('assets_adjust') then raise exception 'assets_adjust permission required'; end if;
 select * into ai from public.asset_assignment_items where id=(payload->>'assignment_item_id')::uuid for update;
 select coalesce(sum(quantity),0) into pending from public.asset_settlements where assignment_item_id=ai.id and status='pending_approval';
 if qty<=0 or qty>ai.quantity-ai.returned_quantity-ai.settled_quantity-pending then raise exception 'Settlement quantity exceeds outstanding quantity'; end if;
 insert into public.asset_settlements(assignment_item_id,settlement_type,quantity,reason,notes,estimated_loss) values(ai.id,payload->>'settlement_type',qty,btrim(payload->>'reason'),payload->>'notes',nullif(payload->>'estimated_loss','')::numeric) returning * into s;
 update public.asset_assignments set status='settlement_pending',updated_at=now() where id=ai.assignment_id;
 return jsonb_build_object('ok',true,'settlement',to_jsonb(s));
end $$;

create or replace function public.approve_asset_settlement(target_id uuid, approve boolean, decision_notes text default null) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s public.asset_settlements%rowtype; ai public.asset_assignment_items%rowtype; a public.assets%rowtype; remaining numeric;
begin
 if not public.has_permission('assets_approve_loss') then raise exception 'assets_approve_loss permission required'; end if;
 select * into s from public.asset_settlements where id=target_id and status='pending_approval' for update;
 if s.id is null then raise exception 'Pending settlement not found'; end if;
 if public.current_identity_role()='accountant' and s.created_by=auth.uid() then raise exception 'Maker-checker: accountant cannot approve own settlement'; end if;
 if not approve then update public.asset_settlements set status='rejected',rejected_by=auth.uid(),rejected_at=now(),notes=concat_ws(E'\n',notes,decision_notes),updated_at=now() where id=s.id; return jsonb_build_object('ok',true,'status','rejected'); end if;
 select * into ai from public.asset_assignment_items where id=s.assignment_item_id for update; select * into a from public.assets where id=ai.asset_id for update;
 insert into public.asset_movements(asset_id,movement_type,quantity,total_delta,assigned_delta,assignment_id,settlement_id,reason) values(a.id,case when s.settlement_type in ('lost','stolen','damaged') then s.settlement_type else 'adjusted' end,s.quantity,-s.quantity,-s.quantity,ai.assignment_id,s.id,s.reason);
 update public.asset_assignment_items set settled_quantity=settled_quantity+s.quantity,is_active=(returned_quantity+settled_quantity+s.quantity<quantity) where id=ai.id;
 update public.asset_settlements set status='approved',approved_by=auth.uid(),approved_at=now(),notes=concat_ws(E'\n',notes,decision_notes),updated_at=now() where id=s.id;
 if a.tracking_mode='serialized' then update public.assets set operational_status=case when s.settlement_type in ('lost','stolen','damaged') then s.settlement_type else 'retired' end where id=a.id; end if;
 select coalesce(sum(quantity-returned_quantity-settled_quantity),0) into remaining from public.asset_assignment_items where assignment_id=ai.assignment_id;
 update public.asset_assignments set status=case when remaining=0 then 'closed' else 'settlement_pending' end,updated_at=now() where id=ai.assignment_id;
 return jsonb_build_object('ok',true,'status','approved');
end $$;

create or replace function public.asset_balance_reconciliation() returns table(asset_id uuid,asset_code text,cached_total numeric,ledger_total numeric,cached_available numeric,ledger_available numeric,cached_assigned numeric,ledger_assigned numeric,is_balanced boolean) language sql stable security definer set search_path=public as $$
 select a.id,a.asset_code,a.total_quantity,coalesce(sum(m.total_delta),0),a.available_quantity,coalesce(sum(m.available_delta),0),a.assigned_quantity,coalesce(sum(m.assigned_delta),0),
 a.total_quantity=coalesce(sum(m.total_delta),0) and a.available_quantity=coalesce(sum(m.available_delta),0) and a.assigned_quantity=coalesce(sum(m.assigned_delta),0)
 from public.assets a left join public.asset_movements m on m.asset_id=a.id where public.has_permission('assets_adjust') group by a.id
$$;

create or replace function public.get_assets_visible() returns setof jsonb language sql stable security definer set search_path=public as $$
 select case when public.current_identity_role() in ('owner','manager') or public.has_permission('assets_reports') then to_jsonb(a) else to_jsonb(a)-array['purchase_cost','supplier_id'] end from public.assets a where public.has_permission('assets_view') order by a.created_at
$$;
create or replace function public.save_asset_category(target_id uuid,name_value text,active_value boolean default true) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.asset_categories%rowtype;
begin
 if not public.has_permission('assets_manage') then raise exception 'assets_manage permission required'; end if;
 if btrim(coalesce(name_value,''))='' then raise exception 'Category name is required'; end if;
 if target_id is null then insert into public.asset_categories(name,is_active) values(btrim(name_value),active_value) returning * into r;
 else update public.asset_categories set name=btrim(name_value),is_active=active_value,updated_by=auth.uid(),updated_at=now() where id=target_id returning * into r; end if;
 return jsonb_build_object('ok',true,'category',to_jsonb(r));
end $$;
create or replace function public.save_asset_location(payload jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare r public.asset_locations%rowtype; target uuid:=nullif(payload->>'id','')::uuid;
begin
 if not public.has_permission('assets_manage') then raise exception 'assets_manage permission required'; end if;
 if target is null then insert into public.asset_locations(name,location_type,parent_id,project_id,notes) values(btrim(payload->>'name'),payload->>'location_type',nullif(payload->>'parent_id','')::uuid,nullif(payload->>'project_id','')::uuid,payload->>'notes') returning * into r;
 else update public.asset_locations set name=btrim(payload->>'name'),location_type=payload->>'location_type',parent_id=nullif(payload->>'parent_id','')::uuid,project_id=nullif(payload->>'project_id','')::uuid,notes=payload->>'notes',is_active=coalesce((payload->>'is_active')::boolean,true),updated_by=auth.uid(),updated_at=now() where id=target returning * into r; end if;
 return jsonb_build_object('ok',true,'location',to_jsonb(r));
end $$;
create or replace function public.update_asset_record(target_id uuid,payload jsonb) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a public.assets%rowtype;
begin
 if not public.has_permission('assets_manage') then raise exception 'assets_manage permission required'; end if;
 update public.assets set asset_code=coalesce(nullif(payload->>'asset_code',''),asset_code),name=coalesce(nullif(payload->>'name',''),name),description=coalesce(payload->>'description',description),
  category_id=coalesce(nullif(payload->>'category_id','')::uuid,category_id),brand=coalesce(payload->>'brand',brand),model=coalesce(payload->>'model',model),serial_number=coalesce(nullif(payload->>'serial_number',''),serial_number),
  qr_value=coalesce(nullif(payload->>'qr_value',''),qr_value),barcode_value=coalesce(nullif(payload->>'barcode_value',''),barcode_value),operational_status=coalesce(nullif(payload->>'operational_status',''),operational_status),
  current_location_id=coalesce(nullif(payload->>'current_location_id','')::uuid,current_location_id),warehouse=coalesce(payload->>'warehouse',warehouse),shelf=coalesce(payload->>'shelf',shelf),notes=coalesce(payload->>'notes',notes),updated_by=auth.uid(),updated_at=now()
 where id=target_id returning * into a;
 if a.id is null then raise exception 'Asset not found'; end if; return jsonb_build_object('ok',true,'asset',to_jsonb(a));
end $$;
create or replace view public.asset_alerts with(security_invoker=true) as
 select 'assignment_overdue' alert_type,a.id reference_id,a.assignment_code title,a.expected_return_at due_at,'high' severity,a.created_at from public.asset_assignments a where a.expected_return_at<now() and a.status in ('issued','partially_returned','settlement_pending')
 union all select 'confirmation_pending',a.id,a.assignment_code,a.confirmation_expires_at,'medium',a.created_at from public.asset_assignments a where a.status='pending_receiver_confirmation' and a.confirmation_used_at is null
 union all select 'warranty_expiring',s.id,s.asset_code,s.warranty_until::timestamptz,'low',s.created_at from public.assets s,public.asset_settings cfg where s.warranty_until between current_date and current_date+cfg.warranty_alert_days
 union all select 'asset_risk',s.id,s.asset_code,null,'high',s.created_at from public.assets s where s.operational_status in ('lost','stolen','under_maintenance');

alter table public.asset_categories enable row level security; alter table public.asset_locations enable row level security; alter table public.asset_settings enable row level security; alter table public.assets enable row level security;
alter table public.asset_assignments enable row level security; alter table public.asset_assignment_items enable row level security; alter table public.asset_return_events enable row level security; alter table public.asset_return_items enable row level security;
alter table public.asset_settlements enable row level security; alter table public.asset_movements enable row level security; alter table public.asset_attachments enable row level security;
create policy asset_categories_read on public.asset_categories for select to authenticated using(public.has_permission('assets_view'));
create policy asset_locations_read on public.asset_locations for select to authenticated using(public.has_permission('assets_view'));
create policy asset_settings_read on public.asset_settings for select to authenticated using(public.has_permission('assets_manage'));
create policy asset_assignments_read on public.asset_assignments for select to authenticated using(public.has_permission('assets_view'));
create policy asset_assignment_items_read on public.asset_assignment_items for select to authenticated using(public.has_permission('assets_view'));
create policy asset_returns_read on public.asset_return_events for select to authenticated using(public.has_permission('assets_view'));
create policy asset_return_items_read on public.asset_return_items for select to authenticated using(public.has_permission('assets_view'));
create policy asset_settlements_read on public.asset_settlements for select to authenticated using(public.has_permission('assets_adjust') or public.has_permission('assets_approve_loss'));
create policy asset_movements_read on public.asset_movements for select to authenticated using(public.has_permission('assets_view'));
create policy asset_attachments_read on public.asset_attachments for select to authenticated using(public.has_permission('assets_view'));
create policy asset_attachments_insert on public.asset_attachments for insert to authenticated with check(public.has_permission('assets_manage') or public.has_permission('assets_issue') or public.has_permission('assets_return') or public.has_permission('assets_adjust'));
-- Business mutations are RPC-only; attachment metadata has a narrow insert policy.
grant select on public.asset_categories,public.asset_locations,public.asset_assignments,public.asset_assignment_items,public.asset_return_events,public.asset_return_items,public.asset_movements,public.asset_alerts to authenticated;
grant select on public.asset_settings to authenticated; grant select on public.asset_settlements to authenticated;
revoke all on public.assets from authenticated,anon; revoke all on public.asset_settlements from anon;

do $$ declare f text; begin foreach f in array array['create_asset(jsonb)','adjust_asset_quantity(uuid,numeric,text)','issue_asset_assignment(jsonb)','cancel_draft_asset_assignment(uuid,text)','reverse_asset_assignment(uuid,text)','create_asset_return(jsonb)','create_asset_settlement(jsonb)','approve_asset_settlement(uuid,boolean,text)','asset_balance_reconciliation()','get_assets_visible()','save_asset_category(uuid,text,boolean)','save_asset_location(jsonb)','update_asset_record(uuid,jsonb)'] loop execute 'revoke all on function public.'||f||' from public,anon'; execute 'grant execute on function public.'||f||' to authenticated'; end loop; end $$;
revoke all on function public.asset_confirmation_preview(uuid,text) from public; revoke all on function public.asset_return_confirmation_preview(uuid,text) from public; revoke all on function public.confirm_asset_assignment(uuid,text) from public; revoke all on function public.confirm_asset_return(uuid,text) from public;
grant execute on function public.asset_confirmation_preview(uuid,text) to anon,authenticated; grant execute on function public.asset_return_confirmation_preview(uuid,text) to anon,authenticated; grant execute on function public.confirm_asset_assignment(uuid,text) to anon,authenticated; grant execute on function public.confirm_asset_return(uuid,text) to anon,authenticated;
revoke all on function public.apply_asset_movement_balance() from public,anon,authenticated; revoke all on function public.immutable_asset_ledger() from public,anon,authenticated; revoke all on function public.protect_asset_integrity() from public,anon,authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('asset-attachments','asset-attachments',false,52428800,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy asset_storage_read on storage.objects for select to authenticated using(bucket_id='asset-attachments' and public.has_permission('assets_view'));
create policy asset_storage_upload on storage.objects for insert to authenticated with check(bucket_id='asset-attachments' and (public.has_permission('assets_manage') or public.has_permission('assets_issue') or public.has_permission('assets_return') or public.has_permission('assets_adjust')));

do $$ declare t text; begin foreach t in array array['asset_categories','asset_locations','asset_settings','assets','asset_assignments','asset_assignment_items','asset_return_events','asset_return_items','asset_settlements','asset_movements','asset_attachments'] loop execute format('create trigger audit_%I after insert or update or delete on public.%I for each row execute function public.audit_row_change()',t,t); end loop; end $$;
do $$ begin alter publication supabase_realtime add table public.asset_categories; alter publication supabase_realtime add table public.asset_locations; alter publication supabase_realtime add table public.assets; alter publication supabase_realtime add table public.asset_assignments; alter publication supabase_realtime add table public.asset_assignment_items; alter publication supabase_realtime add table public.asset_return_events; alter publication supabase_realtime add table public.asset_return_items; alter publication supabase_realtime add table public.asset_settlements; alter publication supabase_realtime add table public.asset_movements; exception when duplicate_object then null; end $$;
