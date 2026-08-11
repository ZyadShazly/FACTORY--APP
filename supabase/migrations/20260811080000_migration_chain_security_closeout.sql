-- Close permissions that only became visible after replaying the complete
-- repository chain on an empty Supabase project. Trigger execution does not
-- require API roles to have EXECUTE on the trigger function.
--
-- Production may legitimately lack one of these historical helpers because
-- older deployments were applied through a drifted migration history. Revoke
-- EXECUTE only when the helper exists so this closeout remains safe on both a
-- fresh replay and an aligned legacy database.

begin;

drop policy if exists profiles_update_own on public.profiles;

do $$
begin
  if to_regprocedure('private.apply_inventory_movement()') is not null then
    execute 'revoke all on function private.apply_inventory_movement() from public, anon, authenticated';
  end if;

  if to_regprocedure('private.record_purchase_request_status_change()') is not null then
    execute 'revoke all on function private.record_purchase_request_status_change() from public, anon, authenticated';
  end if;

  if to_regprocedure('private.complete_purchase_request_from_order()') is not null then
    execute 'revoke all on function private.complete_purchase_request_from_order() from public, anon, authenticated';
  end if;
end
$$;

commit;
