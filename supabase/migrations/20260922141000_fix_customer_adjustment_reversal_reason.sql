-- Fix PL/pgSQL parameter ambiguity in customer adjustment reversal.
create or replace function public.reverse_customer_adjustment(
  target_adjustment uuid,
  reason text
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  saved public.customer_adjustments%rowtype;
begin
  if auth.uid() is null or public.current_identity_role() not in ('owner','manager') then
    raise exception using errcode='42501',message='Owner or manager role required';
  end if;
  if nullif(btrim(reverse_customer_adjustment.reason),'') is null then
    raise exception using errcode='22023',message='Reversal reason is required';
  end if;

  update public.customer_adjustments ca
  set status='reversed',
      reversed_by=auth.uid(),
      reversed_at=now(),
      reversal_reason=btrim(reverse_customer_adjustment.reason)
  where ca.id=target_adjustment
    and ca.status='posted'
  returning ca.* into saved;

  if not found then
    raise exception using errcode='P0002',message='Posted customer adjustment was not found';
  end if;

  insert into public.audit_log(table_name,record_id,action,actor_id,old_data,new_data,metadata)
  values(
    'customer_adjustments',saved.id::text,'customer_adjustment_reversed',auth.uid(),
    null,to_jsonb(saved),jsonb_build_object('non_cash',true,'reversal_reason',saved.reversal_reason)
  );

  return to_jsonb(saved);
end
$$;

revoke all on function public.reverse_customer_adjustment(uuid,text) from public,anon;
grant execute on function public.reverse_customer_adjustment(uuid,text) to authenticated;
