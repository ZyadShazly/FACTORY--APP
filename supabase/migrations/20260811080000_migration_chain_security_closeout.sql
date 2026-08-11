-- Close permissions that only became visible after replaying the complete
-- repository chain on an empty Supabase project. Trigger execution does not
-- require API roles to have EXECUTE on the trigger function.

begin;

drop policy if exists profiles_update_own on public.profiles;

revoke all on function private.apply_inventory_movement()
  from public, anon, authenticated;
revoke all on function private.record_purchase_request_status_change()
  from public, anon, authenticated;
revoke all on function private.complete_purchase_request_from_order()
  from public, anon, authenticated;

commit;
