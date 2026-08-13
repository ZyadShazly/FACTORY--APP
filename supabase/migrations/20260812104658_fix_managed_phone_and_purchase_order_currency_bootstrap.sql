begin;

create or replace function public.admin_register_managed_profile(
  target_user_id uuid,
  target_full_name text,
  target_phone text,
  target_role text
)
returns public.profiles
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  actor_id uuid := auth.uid();
  actor_role text;
  requested_phone text := public.normalize_employee_phone(target_phone);
  normalized_phone text;
  auth_user auth.users%rowtype;
  saved public.profiles%rowtype;
begin
  select role into actor_role from public.profiles where id = actor_id and status = 'active';
  if actor_role is null then raise exception 'Active owner or manager authorization required' using errcode = '42501'; end if;
  if not (actor_role = 'owner' or actor_role = 'manager' and target_role in ('accountant', 'production')) then
    perform public.log_identity_security_event(target_user_id, 'managed_account_create_attempt', null, null,
      jsonb_build_object('allowed', false, 'target_role', target_role));
    raise exception 'Your role cannot create the requested account role' using errcode = '42501';
  end if;
  if target_user_id = actor_id then raise exception 'A managed account cannot be created for the caller'; end if;
  if btrim(coalesce(target_full_name, '')) = '' then raise exception 'Full name is required' using errcode = '23514'; end if;
  if requested_phone is null then raise exception 'A valid international phone number is required' using errcode = '23514'; end if;
  if exists(select 1 from public.profiles where id = target_user_id) then raise exception 'The profile already exists' using errcode = '23505'; end if;

  select * into auth_user from auth.users where id = target_user_id for update;
  if not found then raise exception 'Authentication account not found' using errcode = 'P0002'; end if;

  normalized_phone := public.normalize_employee_phone(auth_user.phone);
  if normalized_phone is null then
    raise exception 'Authentication account does not contain a valid phone number' using errcode = '23514';
  end if;
  if exists(select 1 from public.profiles where public.normalize_employee_phone(phone) = normalized_phone) then
    raise exception 'Phone number is already assigned' using errcode = '23505';
  end if;

  perform set_config('app.identity_managed_create_rpc', 'on', true);
  insert into public.profiles(id, full_name, email, phone, role, permissions, status, must_change_password, created_by, created_at)
  values(target_user_id, btrim(target_full_name), auth_user.email, normalized_phone, target_role, '{}'::jsonb, 'active', true, actor_id, now())
  returning * into saved;
  perform set_config('app.identity_managed_create_rpc', 'off', true);

  perform public.log_identity_security_event(target_user_id, 'managed_account_created', null, to_jsonb(saved) - 'password_changed_at',
    jsonb_build_object('allowed', true, 'source', 'admin_register_managed_profile', 'temporary_password_stored', false, 'requested_phone', requested_phone, 'auth_phone', normalized_phone));
  return saved;
end
$$;

create or replace function public.create_purchase_order_draft_from_quote(
  target_quote uuid,
  order_display_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  actor uuid:=auth.uid();
  q public.supplier_quotes%rowtype;
  req public.purchase_requests%rowtype;
  po public.purchase_orders%rowtype;
  effective_name text;
begin
  if actor is null or public.current_identity_role() not in('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  select * into q from public.supplier_quotes where id=target_quote for update;
  if not found or q.status not in('received','selected') then raise exception 'Received quote required'; end if;
  if q.base_currency is null or q.exchange_rate is null or q.exchange_rate<=0 or q.rate_date is null or q.base_total_amount is null then raise exception 'Quote currency conversion contract is incomplete'; end if;
  if q.currency=q.base_currency and q.exchange_rate<>1 then raise exception 'Exchange rate must equal 1 when currencies match'; end if;
  select * into req from public.purchase_requests where id=q.purchase_request_id for update;
  if req.status<>'approved' then raise exception 'Approved request required'; end if;
  if exists(select 1 from public.purchase_orders where selected_quote_id=q.id and status<>'cancelled') then raise exception 'Purchase order already exists for this quote'; end if;
  effective_name:=coalesce(nullif(btrim(order_display_name),''),nullif(btrim(req.display_name),''),req.request_number);

  insert into public.purchase_orders(
    purchase_request_id,selected_quote_id,supplier_id,project_id,currency,base_currency,
    exchange_rate,rate_date,base_total_amount,status,payment_terms,created_by,display_name
  )
  values(
    req.id,q.id,q.supplier_id,req.project_id,q.currency,q.base_currency,
    q.exchange_rate,q.rate_date,0,'draft',q.payment_terms,actor,effective_name
  ) returning * into po;

  insert into public.purchase_order_items(purchase_order_id,purchase_request_item_id,material_id,description,quantity,unit,unit_price,discount_amount,tax_amount,budget_item_id,milestone_id,cost_center_reference,sequence)
  select po.id,ri.id,ri.material_id,ri.description,qi.quantity,ri.unit,qi.unit_price,qi.discount_amount,qi.tax_amount,ri.budget_item_id,ri.milestone_id,ri.cost_center_reference,ri.sequence
  from public.supplier_quote_items qi
  join public.purchase_request_items ri on ri.id=qi.purchase_request_item_id
  where qi.supplier_quote_id=q.id;

  update public.purchase_orders p set
    subtotal=x.subtotal,
    discount_amount=x.discount_amount,
    tax_amount=x.tax_amount,
    total_amount=x.total_amount,
    base_total_amount=round(x.total_amount*q.exchange_rate,2),
    updated_at=now()
  from(
    select coalesce(sum(quantity*unit_price),0) subtotal,
           coalesce(sum(discount_amount),0) discount_amount,
           coalesce(sum(tax_amount),0) tax_amount,
           coalesce(sum(line_total),0) total_amount
    from public.purchase_order_items
    where purchase_order_id=po.id
  )x
  where p.id=po.id returning p.* into po;

  if po.total_amount<=0 then raise exception 'Purchase order total must be positive'; end if;
  update public.supplier_quotes set status=case when id=q.id then 'selected' else 'rejected' end where purchase_request_id=req.id and status in('received','selected');
  update public.purchase_requests set status='converted',updated_at=now() where id=req.id;
  insert into public.audit_log(table_name,record_id,action,actor_id,new_data,metadata)
  values('purchase_orders',po.id::text,'purchase_order_draft_created',actor,to_jsonb(po),jsonb_build_object('quote_id',q.id,'request_id',req.id,'currency_contract_preserved',true));
  return to_jsonb(po);
end
$$;

commit;
