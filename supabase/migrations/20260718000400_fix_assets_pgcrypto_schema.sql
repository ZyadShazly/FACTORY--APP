-- Hotfix for Supabase installations where pgcrypto lives in the extensions schema.
-- 202607180003 may already be applied, so repair both stored defaults and RPC bodies.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Fail the migration immediately if the expected Supabase pgcrypto schema is unavailable.
do $$
begin
 perform extensions.gen_random_bytes(1);
 perform extensions.digest('assets-pgcrypto-probe','sha256');
end $$;

alter table public.asset_assignments alter column assignment_code set default
 ('CST-'||to_char(clock_timestamp(),'YYMMDD')||'-'||upper(substr(encode(extensions.gen_random_bytes(5),'hex'),1,8)));

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

comment on function public.create_asset(jsonb) is 'Assets RPC with explicitly qualified pgcrypto calls.';
comment on function public.issue_asset_assignment(jsonb) is 'Assignment issue RPC with explicitly qualified pgcrypto calls.';
comment on function public.create_asset_return(jsonb) is 'Return event RPC with explicitly qualified pgcrypto calls.';
