-- Rollback-safe smoke coverage for system UX hardening.
begin;

do $$
declare
  v_return uuid;
  v_preview jsonb;
begin
  select id into v_return
  from public.asset_return_events
  where status='pending_receiver_confirmation'
  limit 1
  for update;

  v_preview := public.asset_return_confirmation_preview(gen_random_uuid(),'not-a-real-secret');
  if v_preview->>'status' <> 'not_found' then
    raise exception 'Expected explicit not_found status, got %',v_preview;
  end if;

  if v_return is not null then
    update public.asset_return_events
    set status='confirmed',confirmed_at=now(),confirmation_used_at=now(),
        confirmation_token_hash=null,confirmation_method='bearer_link',confirmed_by_user_id=null
    where id=v_return;
    if not exists(select 1 from public.asset_return_events where id=v_return and status='confirmed' and confirmation_token_hash is null) then
      raise exception 'Completed return could not clear token';
    end if;
  end if;

  update public.system_settings set currency_symbol='TEST',updated_at=now() where id=true;
  if (select currency_symbol from public.system_settings where id=true) <> 'TEST' then
    raise exception 'Currency settings update failed';
  end if;
end $$;

rollback;
